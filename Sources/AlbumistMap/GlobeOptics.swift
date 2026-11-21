import Foundation
import AlbumistCore

/// A point or direction in the space of our own globe: the Earth is the unit sphere round the
/// origin, +y runs through the North Pole, +z through latitude 0° and longitude 0°, +x through
/// 0° N 90° E (right-handed). The globe's vertices, its arcs and its camera all live in it, so the
/// renderer, the pins above it and the gestures agree on every point.
public struct GlobeVector: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// The point of `coordinate` on the unit sphere.
    public init(_ coordinate: GeoCoordinate) {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        self.init(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
    }

    public static let zero = GlobeVector(0, 0, 0)

    /// The latitude and longitude of the direction (longitude in [-180, 180]); the zero vector
    /// gives 0° N 0° E.
    public var coordinate: GeoCoordinate {
        let horizontal = (x * x + z * z).squareRoot()
        return GeoCoordinate(latitude: atan2(y, horizontal) * 180 / .pi, longitude: atan2(x, z) * 180 / .pi)
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    /// The same direction with length 1; the zero vector (or one that is not finite) stays as it is.
    public var normalized: GlobeVector {
        let length = length
        guard length > 0, length.isFinite else { return self }
        return GlobeVector(x / length, y / length, z / length)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public func dot(_ other: GlobeVector) -> Double { x * other.x + y * other.y + z * other.z }

    public func cross(_ other: GlobeVector) -> GlobeVector {
        GlobeVector(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    }

    public static func + (a: GlobeVector, b: GlobeVector) -> GlobeVector { GlobeVector(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: GlobeVector, b: GlobeVector) -> GlobeVector { GlobeVector(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: GlobeVector, s: Double) -> GlobeVector { GlobeVector(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: GlobeVector) -> GlobeVector { GlobeVector(-a.x, -a.y, -a.z) }

    /// The angle between two directions in radians, exact for tiny and nearly opposite angles
    /// (atan2 of the cross and the dot product, not the arc cosine).
    public func angle(to other: GlobeVector) -> Double {
        atan2(cross(other).length, dot(other))
    }
}

/// A 4×4 matrix, column-major like Metal's `float4x4` (`values[column * 4 + row]`), so the app
/// copies `floats` straight into its uniforms or builds a `simd_float4x4` from its columns.
public struct Matrix4: Hashable, Sendable {
    /// Sixteen values, column by column.
    public var values: [Double]

    /// `columns` holds 16 values, column by column; anything else gives the identity.
    public init(columns: [Double]) {
        values = columns.count == 16 ? columns : Matrix4.identity.values
    }

    public static let identity = Matrix4(columns: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public subscript(row: Int, column: Int) -> Double { values[column * 4 + row] }

    public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var result = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += a[row, k] * b[k, column] }
                result[column * 4 + row] = sum
            }
        }
        return Matrix4(columns: result)
    }

    /// The matrix times the column vector (x, y, z, w).
    public func transform(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> (x: Double, y: Double, z: Double, w: Double) {
        (self[0, 0] * x + self[0, 1] * y + self[0, 2] * z + self[0, 3] * w,
         self[1, 0] * x + self[1, 1] * y + self[1, 2] * z + self[1, 3] * w,
         self[2, 0] * x + self[2, 1] * y + self[2, 2] * z + self[2, 3] * w,
         self[3, 0] * x + self[3, 1] * y + self[3, 2] * z + self[3, 3] * w)
    }

    /// The values as 32-bit floats, column by column, for a uniform buffer.
    public var floats: [Float] { values.map { Float($0) } }
}

/// Where a point of the Earth lands on the screen of our globe.
public struct GlobeScreenPoint: Hashable, Sendable {
    /// Points from the view's left edge.
    public var x: Double
    /// Points from the view's top edge (down is positive, as in UIKit).
    public var y: Double
    /// On the side of the Earth facing the camera (in front of the horizon). A point on the far
    /// side still gets the place where it would shine through, but it is hidden.
    public var isVisible: Bool
    /// How far the point is from the horizon: 1 straight below the camera, 0 on the horizon,
    /// below 0 on the far side. Pins fade out over the last bit before the horizon.
    public var horizonMargin: Double

    public init(x: Double, y: Double, isVisible: Bool, horizonMargin: Double) {
        self.x = x
        self.y = y
        self.isVisible = isVisible
        self.horizonMargin = horizonMargin
    }
}

/// The camera model of our own Metal globe (concept §7, plan A), shared by the renderer, the
/// pins above it and the gestures: the Earth is the unit sphere (`GlobeVector`), the camera sits
/// on the ray from the Earth's centre through `GlobeCamera.center`, looks at the centre, and keeps
/// north up. Its distance follows from the camera's width:
///
/// - Up to `limbWidthMeters` (the disc's edge reaching the view's sides) the width is exact: the
///   great-circle distance across the view's horizontal centre line is `widthMeters`, so at the
///   3,000 km handover our globe shows the same area as Apple's map region of that width. A ray
///   at the half field of view α from the view's axis meets the sphere at the central angle
///   `asin(d · sin α) − α`; setting that to `w / 2R` gives `d = sin(w / 2R + α) / sin α`.
/// - Beyond it the disc narrows in proportion: its width on screen is `limbWidthMeters / w` of
///   the view's width (`tan β = f · tan α` for the disc's angular radius β = asin(1/d), so
///   `d = √(1 + 1 / (f · tan α)²)`). Both branches give `d = 1 / sin α` at `limbWidthMeters`, so
///   the distance is continuous and grows with the width throughout. `GlobeCamera` describes
///   this regime against `wholeEarthWidthMeters` (the disc as wide as the view); in perspective
///   the disc touches the sides a little earlier, at `limbWidthMeters` ≈ 0.92 · π · R, so every
///   wider view shows the disc 8 % narrower than that description, in the same proportion.
///
/// The field of view is 15° across, about 32° from top to bottom on a 19.5:9 portrait iPhone:
/// close to the angle the screen itself covers at reading distance, so the Earth looks like a
/// ball seen through a window, not through a fish-eye, and the handover meets Apple's flat map
/// with little curvature at the top and bottom.
///
/// Screen points have their origin at the view's top left, y down (UIKit). Broken input (a
/// camera that is not finite, a view without a size) falls back to something drawable: the whole
/// Earth, a 1 × 1 point view. The centre's latitude stays within ±`latitudeLimit`, so north
/// always points up.
public struct GlobeOptics: Hashable, Sendable {
    /// The horizontal field of view.
    public static let horizontalFieldOfViewDegrees = 15.0
    /// The camera's centre never comes closer to a pole than this, so "north up" stays defined.
    public static let latitudeLimit = 85.0
    /// The camera's half field of view across, α.
    static let halfAngle = horizontalFieldOfViewDegrees / 2 * .pi / 180
    /// Where the disc's edge reaches the view's left and right sides: `(π − 2α) · R`.
    public static let limbWidthMeters = (Double.pi - 2 * halfAngle) * GeoMath.earthRadiusMeters

    /// The camera as drawn (`sanitized`).
    public let camera: GlobeCamera
    public let widthPoints: Double
    public let heightPoints: Double
    /// The eye's distance from the Earth's centre, in Earth radii (always more than 1).
    public let distance: Double
    /// The camera's axes in the globe's space: `right` and `up` on screen, `back` from the
    /// Earth's centre towards the eye (the unit vector of the centre coordinate).
    public let right: GlobeVector
    public let up: GlobeVector
    public let back: GlobeVector
    /// tan of the half field of view across and from top to bottom.
    let tanX: Double
    let tanY: Double

    public init(camera: GlobeCamera, widthPoints: Double, heightPoints: Double) {
        let camera = Self.sanitized(camera)
        self.camera = camera
        self.widthPoints = widthPoints.isFinite && widthPoints > 0 ? widthPoints : 1
        self.heightPoints = heightPoints.isFinite && heightPoints > 0 ? heightPoints : 1
        distance = Self.distance(forWidth: camera.widthMeters)
        back = GlobeVector(camera.center)
        let longitude = camera.center.longitude * .pi / 180
        // up × back, normalized; well defined because the latitude stays below the poles.
        right = GlobeVector(cos(longitude), 0, -sin(longitude))
        up = back.cross(right)
        tanX = tan(Self.halfAngle)
        tanY = tanX * self.heightPoints / self.widthPoints
    }

    // MARK: Camera and distance

    /// `camera` made drawable: a centre or width that is not a number gives the whole Earth's,
    /// then `GlobeCamera.clamped`, then the latitude within ±`latitudeLimit`.
    public static func sanitized(_ camera: GlobeCamera) -> GlobeCamera {
        let whole = GlobeCamera.wholeEarth
        let finiteCenter = camera.center.latitude.isFinite && camera.center.longitude.isFinite
        var result = GlobeCamera(center: finiteCenter ? camera.center : whole.center,
                                 widthMeters: camera.widthMeters.isFinite ? camera.widthMeters : whole.widthMeters).clamped
        result.center.latitude = min(max(result.center.latitude, -latitudeLimit), latitudeLimit)
        return result
    }

    /// The eye's distance from the Earth's centre in Earth radii for a camera `meters` wide (see
    /// the type's description). The width is taken as `GlobeCamera.clamped` takes it.
    public static func distance(forWidth meters: Double) -> Double {
        let width = sanitized(GlobeCamera(center: GlobeCamera.wholeEarth.center, widthMeters: meters)).widthMeters
        if width <= limbWidthMeters {
            return sin(width / (2 * GeoMath.earthRadiusMeters) + halfAngle) / sin(halfAngle)
        }
        let tanBeta = limbWidthMeters / width * tan(halfAngle)
        return (1 + 1 / (tanBeta * tanBeta)).squareRoot()
    }

    /// The width whose camera stands `distance` Earth radii from the centre: the inverse of
    /// `distance(forWidth:)` (a distance of 1 or less, or not a number, gives 0 or the whole
    /// Earth's width).
    public static func width(forDistance distance: Double) -> Double {
        guard distance.isFinite else { return GlobeCamera.wholeEarth.widthMeters }
        guard distance > 1 else { return 0 }
        if distance <= 1 / sin(halfAngle) {
            return 2 * GeoMath.earthRadiusMeters * (asin(min(1, distance * sin(halfAngle))) - halfAngle)
        }
        let beta = asin(1 / distance)
        return limbWidthMeters * tan(halfAngle) / tan(beta)
    }

    /// The disc's width on screen as a share of the view's width (1 when its edge touches the
    /// sides; more when the Earth fills the view).
    public var discWidthFraction: Double {
        tan(asin(1 / distance)) / tanX
    }

    /// The eye in the globe's space.
    public var eye: GlobeVector { back * distance }

    // MARK: Matrices

    /// The near and far planes in Earth radii: in front of the highest arc below the eye, and
    /// behind the farthest point of an arc above the far side.
    public var depthRange: (near: Double, far: Double) {
        let altitude = distance - 1
        let near = max(0.8 * (altitude - GlobeArcGeometry.maximumLift), 0.02 * altitude, 1e-6)
        return (near, distance + 1 + GlobeArcGeometry.maximumLift + 0.01)
    }

    /// World to view space: right-handed, the camera looking down −z, north up.
    public var viewMatrix: Matrix4 {
        Matrix4(columns: [right.x, up.x, back.x, 0,
                          right.y, up.y, back.y, 0,
                          right.z, up.z, back.z, 0,
                          0, 0, -distance, 1])
    }

    /// View to Metal's clip space (depth from 0 at the near plane to 1 at the far plane).
    public var projectionMatrix: Matrix4 {
        let (near, far) = depthRange
        let depth = far / (near - far)
        return Matrix4(columns: [1 / tanX, 0, 0, 0,
                                 0, 1 / tanY, 0, 0,
                                 0, 0, depth, -1,
                                 0, 0, depth * near, 0])
    }

    public var viewProjectionMatrix: Matrix4 { projectionMatrix * viewMatrix }

    /// The projection with the camera's turn only, no move: for the stars, which are infinitely
    /// far (the shader puts them on the far plane).
    public var skyMatrix: Matrix4 {
        let turn = Matrix4(columns: [right.x, up.x, back.x, 0,
                                     right.y, up.y, back.y, 0,
                                     right.z, up.z, back.z, 0,
                                     0, 0, 0, 1])
        return projectionMatrix * turn
    }

    /// How far out the atmosphere's glow reaches, in Earth radii from the centre.
    public static let haloRadius = 1.3

    /// Half the side of the square, through the Earth's centre and facing the camera, that holds
    /// every ray passing the Earth within `haloRadius`: the atmosphere's glow is drawn on it.
    public var haloHalfSize: Double {
        let room = distance * distance - Self.haloRadius * Self.haloRadius
        guard room > 0.0025 else { return 50 }
        return min(50, distance * Self.haloRadius / room.squareRoot() * 1.02)
    }

    // MARK: Screen

    /// Where `coordinate` lands on the screen, and whether it faces the camera. A coordinate
    /// that is not a number lands nowhere: not visible, at the view's top left.
    public func project(_ coordinate: GeoCoordinate) -> GlobeScreenPoint {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return GlobeScreenPoint(x: 0, y: 0, isVisible: false, horizonMargin: -1)
        }
        let p = GlobeVector(coordinate)
        let screen = screenPoint(p) ?? (0, 0)
        let horizon = 1 / distance
        let margin = (p.dot(back) - horizon) / (1 - horizon)
        return GlobeScreenPoint(x: screen.x, y: screen.y, isVisible: margin > 0, horizonMargin: margin)
    }

    /// Where a point of the globe's space lands on the screen, in points; nil when it is not in
    /// front of the camera.
    public func screenPoint(_ p: GlobeVector) -> (x: Double, y: Double)? {
        let depth = distance - p.dot(back)
        guard depth > 1e-9, p.isFinite else { return nil }
        let ndcX = p.dot(right) / depth / tanX
        let ndcY = p.dot(up) / depth / tanY
        return ((ndcX + 1) / 2 * widthPoints, (1 - ndcY) / 2 * heightPoints)
    }

    /// The point of the Earth under the screen point (`x`, `y`), or nil when the ray from the eye
    /// misses the Earth (space round the disc).
    public func unproject(x: Double, y: Double) -> GeoCoordinate? {
        hit(x: x, y: y, distance: distance).map { (right * $0.x + up * $0.y + back * $0.z).coordinate }
    }

    /// Where the ray through the screen point meets the unit sphere seen from `distance`, in the
    /// camera's frame (right, up, back); nil when it misses.
    func hit(x: Double, y: Double, distance: Double) -> GlobeVector? {
        guard x.isFinite, y.isFinite else { return nil }
        let ndcX = 2 * x / widthPoints - 1
        let ndcY = 1 - 2 * y / heightPoints
        let ray = GlobeVector(ndcX * tanX, ndcY * tanY, -1).normalized
        // The eye at (0, 0, distance): |eye + t · ray| = 1.
        let b = distance * ray.z
        let discriminant = b * b - (distance * distance - 1)
        guard discriminant >= 0 else { return nil }
        let t = -b - discriminant.squareRoot()
        return GlobeVector(t * ray.x, t * ray.y, distance + t * ray.z)
    }

    // MARK: Moving the camera

    /// The camera `widthMeters` wide (this camera's width when nil) that shows `coordinate` at the
    /// screen point (`x`, `y`) with north up: the rule that keeps a grabbed point under the
    /// finger (drag, pinch, double tap). Nil when there is none: the screen point is off the
    /// Earth or closer to its horizon than `minimumHorizonMargin` (see `GlobeScreenPoint`), or
    /// north up cannot bring the point there (a point near a pole pulled far sideways). The
    /// result keeps its latitude within ±`latitudeLimit`, so close to that limit the point can
    /// lag behind the finger vertically.
    ///
    /// The ray through the screen point meets the sphere at q in the camera's frame. A centre
    /// (φc, λc) shows the coordinate (φ, λ) there when q.x = cos φ · sin(λ − λc) and (q.z, q.y)
    /// is (cos φ · cos(λ − λc), sin φ) turned by −φc. Of the two solutions for λ − λc the one
    /// keeping the coordinate on its present side of the pole (as seen along the centre's
    /// meridian) is taken, so a drag near a pole never flips the globe over it.
    public func cameraPlacing(_ coordinate: GeoCoordinate, atX x: Double, y: Double, widthMeters: Double? = nil,
                              minimumHorizonMargin: Double = 0) -> GlobeCamera? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let width = Self.sanitized(GlobeCamera(center: self.camera.center, widthMeters: widthMeters ?? self.camera.widthMeters)).widthMeters
        let distance = Self.distance(forWidth: width)
        guard let q = hit(x: x, y: y, distance: distance) else { return nil }
        let horizon = 1 / distance
        guard (q.z - horizon) / (1 - horizon) >= minimumHorizonMargin else { return nil }
        let latitude = coordinate.latitude * .pi / 180, longitude = coordinate.longitude * .pi / 180
        let cosLatitude = cos(latitude)
        guard cosLatitude > 1e-9 else { return nil }
        let s = q.x / cosLatitude
        guard abs(s) <= 1 else { return nil }
        // The solution on the coordinate's present side of the pole as seen from the centre's
        // meridian (cos(λ − λc) keeps its sign): the other one would flip the globe over the pole.
        let present = longitude - self.camera.center.longitude * .pi / 180
        let delta = cos(present) >= 0 ? asin(s) : .pi - asin(s)
        var centerLatitude = atan2(sin(latitude), cosLatitude * cos(delta)) - atan2(q.y, q.z)
        if centerLatitude > .pi { centerLatitude -= 2 * .pi } else if centerLatitude <= -.pi { centerLatitude += 2 * .pi }
        guard abs(centerLatitude) <= .pi / 2 else { return nil }
        let center = GeoCoordinate(latitude: centerLatitude * 180 / .pi, longitude: MapHome.normalizedLongitude((longitude - delta) * 180 / .pi))
        return Self.sanitized(GlobeCamera(center: center, widthMeters: width))
    }

    /// The camera turned as a drag of (`dx`, `dy`) points turns it where the finger has no point
    /// of the Earth to hold (near the horizon, off the disc): in proportion to the drag, the
    /// view's width in Earth angle per view width in points, with north up. A drag down shows
    /// what lies north, a drag right what lies west. Near the poles the longitude turns faster
    /// (at most 5 times), as the parallels there are short.
    public func rotated(byX dx: Double, y dy: Double) -> GlobeCamera {
        guard dx.isFinite, dy.isFinite else { return camera }
        let rate = radiansPerPoint * 180 / .pi
        let latitude = camera.center.latitude + dy * rate
        let parallel = max(cos(camera.center.latitude * .pi / 180), 0.2)
        let longitude = camera.center.longitude - dx * rate / parallel
        return Self.sanitized(GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: MapHome.normalizedLongitude(longitude)),
                                          widthMeters: camera.widthMeters))
    }

    /// Earth angle per screen point for the proportional turn: the camera's width as an angle
    /// over the view's width.
    public var radiansPerPoint: Double { camera.widthMeters / GeoMath.earthRadiusMeters / widthPoints }

    /// The camera after a pinch: `startWidth` divided by `scale` (a scale that is not a positive
    /// number changes nothing), within `GlobeCamera.clamped`; the point `grabbed` under the
    /// fingers' centre (`x`, `y`) stays there when it can, else the centre stays.
    public func pinched(startWidth: Double, scale: Double, grabbed: GeoCoordinate?, atX x: Double, y: Double) -> GlobeCamera {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        let width = Self.sanitized(GlobeCamera(center: camera.center, widthMeters: startWidth / factor)).widthMeters
        if let grabbed, let placed = cameraPlacing(grabbed, atX: x, y: y, widthMeters: width) {
            return placed
        }
        return Self.sanitized(GlobeCamera(center: camera.center, widthMeters: width))
    }

    /// Where a double tap at (`x`, `y`) goes: half the width, the tapped point staying under the
    /// finger (as Apple's maps zoom in); a tap off the Earth or too close to its horizon zooms
    /// in on the centre.
    public func doubleTapTarget(atX x: Double, y: Double) -> GlobeCamera {
        let width = camera.widthMeters / 2
        if let tapped = unproject(x: x, y: y),
           let placed = cameraPlacing(tapped, atX: x, y: y, widthMeters: width, minimumHorizonMargin: GlobeDrag.minimumHorizonMargin) {
            return placed
        }
        return Self.sanitized(GlobeCamera(center: camera.center, widthMeters: width))
    }

    // MARK: Pins

    /// The pins' horizon fade: fully shown from this `GlobeScreenPoint.horizonMargin` on, fading
    /// to nothing at the horizon.
    public static let pinFadeMargin = 0.12

    /// Where the pin groups of `MapPins.onGlobe` stand on screen: each at its pin's coordinate,
    /// hidden behind the horizon, fading out just before it, left out when it lies well outside
    /// the view. Farther pins first, so nearer ones are drawn over them (ties: by id).
    public func place(_ groups: [MapPinGroup], marginPoints: Double = 40) -> [GlobePlacedPin] {
        var placed: [(pin: GlobePlacedPin, depth: Double)] = []
        for group in groups {
            let point = project(group.pin.coordinate)
            guard point.isVisible,
                  point.x >= -marginPoints, point.x <= widthPoints + marginPoints,
                  point.y >= -marginPoints, point.y <= heightPoints + marginPoints else { continue }
            let opacity = Self.smoothstep(0, Self.pinFadeMargin, point.horizonMargin)
            guard opacity > 0.01 else { continue }
            placed.append((GlobePlacedPin(group: group, x: point.x, y: point.y, opacity: opacity), point.horizonMargin))
        }
        placed.sort { a, b in a.depth != b.depth ? a.depth < b.depth : a.pin.id < b.pin.id }
        return placed.map(\.pin)
    }

    /// 0 below `edge0`, 1 above `edge1`, smooth between (Hermite), as in a shader.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard x.isFinite else { return x > 0 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A pin group placed on the screen of our globe (`GlobeOptics.place`).
public struct GlobePlacedPin: Hashable, Sendable, Identifiable {
    public var group: MapPinGroup
    /// Points from the view's top left.
    public var x: Double
    public var y: Double
    /// 1 well in front of the horizon, fading to 0 at it.
    public var opacity: Double

    public init(group: MapPinGroup, x: Double, y: Double, opacity: Double) {
        self.group = group
        self.x = x
        self.y = y
        self.opacity = opacity
    }

    public var id: String { group.id }
}
