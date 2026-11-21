import Foundation
import AlbumistCore

/// A `GlobeCamera` in Apple's maps, as plain numbers the app hands to MapKit (concept §7): the area
/// `MKMapView` shows after the handover, the camera distance of the SwiftUI `Map`'s satellite globe
/// (Plan B), the way back to our globe, and the globe's 60-second test spin. Kept out of the app so
/// it is tested on Linux; the app only turns the numbers into MapKit's types.
///
/// The shared convention of the prototype: a camera `w` metres wide is the region `w` wide from
/// west to east through its centre and `w × heightPoints / widthPoints` high, as
/// `MKCoordinateRegion(center:latitudinalMeters:longitudinalMeters:)` takes it. Our globe shows
/// exactly `w` across at the handover width, so both views show the same area at that moment.
public enum MapKitCamera {
    /// Metres per degree of latitude, and of longitude on the equator. MapKit's spans and map
    /// points use the WGS 84 equator (6,378,137 m · π / 180 = 111,319.5 m per degree); so does
    /// `GeoMath.metersPerDegreeLatitude`.
    public static let metersPerDegree = GeoMath.metersPerDegreeLatitude
    /// The widest spans MapKit takes (`MKCoordinateSpan`); `MKMapView.setRegion` raises an
    /// exception beyond them.
    public static let maximumLatitudeDelta = 180.0
    public static let maximumLongitudeDelta = 360.0
    /// The narrowest span handed to MapKit (about a metre): a span of 0 is no region.
    public static let minimumDelta = 1e-5
    /// Apple's map hands back to our globe when the user zooms out beyond this width: a tenth over
    /// the handover width, so a view right at the handover does not switch to and fro.
    public static let backToGlobeWidthMeters = 1.1 * GlobeCamera.handoverWidthMeters

    // MARK: Region (the map after the handover)

    /// The region `MKMapView` shows for `camera` in a view of `widthPoints` × `heightPoints`
    /// (the convention above). The camera is clamped first (`GlobeCamera.clamped`); a view size
    /// that is no positive number counts as square. Spans in degrees with the metres per degree
    /// at the centre's latitude, kept within MapKit's limits: near a pole, where a degree of
    /// longitude is almost no metres, the longitude span is the whole 360°.
    public static func region(for camera: GlobeCamera, widthPoints: Double, heightPoints: Double) -> MapKitRegion {
        let camera = camera.clamped
        let usable = widthPoints.isFinite && heightPoints.isFinite && widthPoints > 0 && heightPoints > 0
        let aspect = usable ? heightPoints / widthPoints : 1
        let width = camera.widthMeters
        let height = width * aspect
        let latitudeDelta = clamped(height / metersPerDegree, upTo: maximumLatitudeDelta)
        let cosine = cos(camera.center.latitude * .pi / 180)
        let longitudeDelta = cosine > 1e-12 ? clamped(width / (metersPerDegree * cosine), upTo: maximumLongitudeDelta) : maximumLongitudeDelta
        return MapKitRegion(center: camera.center, latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta,
                            latitudinalMeters: height, longitudinalMeters: width)
    }

    /// The width in metres of a region MapKit reports (`MKMapView.region`, `MapCameraUpdateContext.region`):
    /// its longitude span at its centre's latitude, the inverse of `region(for:widthPoints:heightPoints:)`.
    /// `nil` when either number is not finite. A latitude beyond ±90° counts as the pole (width 0),
    /// a span beyond 360° as 360°.
    public static func widthMeters(centerLatitude: Double, longitudeDelta: Double) -> Double? {
        guard centerLatitude.isFinite, longitudeDelta.isFinite else { return nil }
        let latitude = min(max(centerLatitude, -90), 90)
        let delta = min(max(longitudeDelta, 0), maximumLongitudeDelta)
        return max(0, delta * metersPerDegree * cos(latitude * .pi / 180))
    }

    /// The camera our globe continues from when Apple's map reports this region: its centre and
    /// width, clamped. `nil` for a region that is no numbers.
    public static func camera(center: GeoCoordinate, longitudeDelta: Double) -> GlobeCamera? {
        guard center.latitude.isFinite, center.longitude.isFinite,
              let width = widthMeters(centerLatitude: center.latitude, longitudeDelta: longitudeDelta) else { return nil }
        return GlobeCamera(center: center, widthMeters: width).clamped
    }

    /// Whether Apple's map, now this wide, hands back to our globe (`backToGlobeWidthMeters`).
    /// A width that is not a number does not; an infinite one (zoomed out as far as it goes) does.
    public static func isBackToGlobe(widthMeters: Double) -> Bool {
        !widthMeters.isNaN && widthMeters > backToGlobeWidthMeters
    }

    static func clamped(_ delta: Double, upTo maximum: Double) -> Double {
        guard !delta.isNaN else { return maximum }
        return min(max(delta, minimumDelta), maximum)
    }

    // MARK: Camera distance (Apple's globe, Plan B)

    /// The assumed ratio of MapKit's camera distance to the width of a small view straight below
    /// it: a horizontal field of view of 30° (`1 / (2 tan 15°)`, about 1.87). MapKit publishes no
    /// field of view, so this is a guess; the app measures the real ratio from what MapKit reports
    /// (`distanceFactor(distance:widthMeters:)`) and passes that to the functions below.
    public static let assumedDistanceFactor = 1 / (2 * tan(15 * Double.pi / 180))
    /// Only views at most this wide calibrate the factor: there MapKit's reported region still
    /// says how wide the view is (on the whole globe its spans mean little).
    public static let calibrationMaximumWidthMeters = GlobeCamera.handoverWidthMeters
    /// The factors a calibration may find; anything outside is a broken report.
    static let factorRange = 0.05...50.0

    /// MapKit's camera distance (`MapCamera.distance`: metres from the centre point, looking
    /// straight down) for a view `widthMeters` wide on Apple's globe.
    ///
    /// The model: a pinhole camera straight above the centre looks at a round Earth
    /// (`GeoMath.earthRadiusMeters`) with a horizontal field of view θ, where `factor` is the
    /// distance per metre of width of a small view, `1 / (2 tan(θ/2))`.
    /// - Small and middle widths: the great-circle distance the view's edges see across its
    ///   horizontal centre line is `widthMeters` (exact for small views; up to the handover width
    ///   within 0.01 %).
    /// - From `GlobeCamera.wholeEarthWidthMeters` on (the Earth's disc no wider than the view) the
    ///   width counts on as `GlobeCamera` does: twice the width is a disc half as wide.
    /// - In between (the horizon close to the view's edges, where a real camera never sees
    ///   `π·R` across), the width is stretched smoothly from the one to the other, so the distance
    ///   grows steadily with the width and `widthMeters(forDistance:factor:)` is its inverse.
    ///
    /// A width that is not a positive number gives 0; a factor that is not one, the assumed one.
    public static func distance(forWidth widthMeters: Double, factor: Double = assumedDistanceFactor) -> Double {
        guard widthMeters.isFinite, widthMeters > 0 else { return widthMeters == .infinity ? .infinity : 0 }
        let lens = GlobeLens(factor: factor)
        let radius = GeoMath.earthRadiusMeters
        if widthMeters >= GlobeCamera.wholeEarthWidthMeters {
            let across = widthMeters / (Double.pi * lens.tanHalf)
            return (radius * radius + across * across).squareRoot() - radius
        }
        // The arc's half angle φ for this width (bisection: `width(arc:)` grows with φ).
        var low = 0.0, high = lens.horizonArc
        for _ in 0..<80 {
            let middle = (low + high) / 2
            if lens.width(arc: middle) < widthMeters { low = middle } else { high = middle }
        }
        let arc = (low + high) / 2
        return max(0, radius * sin(arc + lens.halfAngle) / lens.sinHalf - radius)
    }

    /// The width a view on Apple's globe shows from a camera `distance` metres from its centre
    /// point, looking straight down: the inverse of `distance(forWidth:factor:)`. A distance that
    /// is not a number or below 0 gives 0.
    public static func widthMeters(forDistance distance: Double, factor: Double = assumedDistanceFactor) -> Double {
        guard !distance.isNaN, distance > 0 else { return 0 }
        guard distance.isFinite else { return .infinity }
        let lens = GlobeLens(factor: factor)
        let radius = GeoMath.earthRadiusMeters
        let fromCentre = radius + distance
        if fromCentre >= radius / lens.sinHalf {
            return Double.pi * lens.tanHalf * (fromCentre * fromCentre - radius * radius).squareRoot()
        }
        let arc = asin(min(1, fromCentre * lens.sinHalf / radius)) - lens.halfAngle
        return lens.width(arc: max(0, arc))
    }

    /// The factor (distance per metre of width, see `distance(forWidth:factor:)`) that explains
    /// what MapKit reports: its camera's `distance` while its region says the view is
    /// `widthMeters` wide (`widthMeters(centerLatitude:longitudeDelta:)`). `nil` when the numbers
    /// do not make one: not positive, a view wider than `calibrationMaximumWidthMeters`, or a
    /// factor outside 0.05 to 50.
    public static func distanceFactor(distance: Double, widthMeters: Double) -> Double? {
        guard distance.isFinite, widthMeters.isFinite, distance > 0, widthMeters > 0,
              widthMeters <= calibrationMaximumWidthMeters else { return nil }
        // The width shrinks as the factor grows (a narrower field of view): bisection on its logarithm.
        var low = log(factorRange.lowerBound), high = log(factorRange.upperBound)
        guard self.widthMeters(forDistance: distance, factor: exp(high)) <= widthMeters,
              self.widthMeters(forDistance: distance, factor: exp(low)) >= widthMeters else { return nil }
        for _ in 0..<80 {
            let middle = (low + high) / 2
            if self.widthMeters(forDistance: distance, factor: exp(middle)) > widthMeters { low = middle } else { high = middle }
        }
        return exp((low + high) / 2)
    }

    /// The camera of the model in `distance(forWidth:factor:)`: its half field of view α
    /// (`tan α = 1 / (2 · factor)`), and the widths it sees.
    struct GlobeLens {
        let halfAngle: Double
        let sinHalf: Double
        let tanHalf: Double
        /// The half angle of the arc the view's edges see when they just graze the horizon (the
        /// disc exactly as wide as the view): `π/2 − α`.
        let horizonArc: Double
        /// How far the width at the horizon is stretched to reach `GlobeCamera.wholeEarthWidthMeters`:
        /// `π / (π − 2α)`.
        let stretch: Double

        init(factor: Double) {
            let usable = factor.isFinite && factor > 0 ? factor : MapKitCamera.assumedDistanceFactor
            let factor = min(max(usable, MapKitCamera.factorRange.lowerBound), MapKitCamera.factorRange.upperBound)
            halfAngle = atan(1 / (2 * factor))
            sinHalf = sin(halfAngle)
            tanHalf = tan(halfAngle)
            horizonArc = Double.pi / 2 - halfAngle
            stretch = Double.pi / (Double.pi - 2 * halfAngle)
        }

        /// The width for an arc of half angle `arc` (0 to `horizonArc`) across the view: the arc's
        /// length, stretched more and more towards the horizon (by the sixth power of how close
        /// it is, so a view at the handover width is not stretched by even 0.01 %).
        func width(arc: Double) -> Double {
            let closeness = horizonArc > 0 ? min(max(arc / horizonArc, 0), 1) : 1
            let square = closeness * closeness
            return 2 * GeoMath.earthRadiusMeters * arc * (1 + (stretch - 1) * square * square * square)
        }
    }

    // MARK: The 60-second test spin

    /// One step of Apple's globe's test spin: where the camera's centre longitude goes, and in how
    /// many seconds (0: at once, without animation).
    public struct SpinStep: Hashable, Sendable {
        public var longitude: Double
        public var seconds: Double

        public init(longitude: Double, seconds: Double) {
            self.longitude = longitude
            self.seconds = seconds
        }
    }

    /// How close an animated step comes to the antimeridian before the camera is moved across it
    /// at once: MapKit may animate a longitude from 179.9° to −179.9° the long way round (through
    /// 0°), and the jump of 0.002° in between cannot be seen on the globe.
    public static let antimeridianMargin = 0.001

    /// The steps of the test spin (prototype brief: 60 s, about 10° per second, like our globe's):
    /// the centre turning `degreesPerSecond` like the Earth (the surface moving east, so the
    /// centre's longitude falls; a negative value turns the other way) for `seconds`, in animated
    /// steps of at most `stepSeconds` (linear animations one after another). No animated step
    /// crosses the antimeridian: one that would, ends just before it, the camera jumps across, and
    /// the rest of the step follows. Longitudes stay in −180° to 180°. No steps for a duration,
    /// speed or step length that is not a positive number (a speed of 0 does not turn).
    public static func spin(fromLongitude: Double, degreesPerSecond: Double = 10, seconds: Double = 60, stepSeconds: Double = 2) -> [SpinStep] {
        guard fromLongitude.isFinite, degreesPerSecond.isFinite, degreesPerSecond != 0, seconds.isFinite, seconds > 0,
              stepSeconds.isFinite, stepSeconds > 0 else { return [] }
        let edge = 180 - antimeridianMargin
        let speed = abs(degreesPerSecond)
        let direction: Double = degreesPerSecond > 0 ? -1 : 1
        var longitude = min(max(MapHome.normalizedLongitude(fromLongitude), -edge), edge)
        var steps: [SpinStep] = []
        var remaining = seconds
        // The step length in time: so many steps that each is at most `stepSeconds`.
        let count = max(1, Int((seconds / stepSeconds).rounded(.up)))
        let step = seconds / Double(count)
        while remaining > 1e-9 {
            var time = min(step, remaining)
            remaining -= time
            while time > 1e-12 {
                let target = longitude + direction * speed * time
                if abs(target) <= edge {
                    steps.append(SpinStep(longitude: target, seconds: time))
                    longitude = target
                    break
                }
                // To the edge, across at once, and on with what is left of the step.
                let border = direction * edge
                let part = abs(border - longitude) / speed
                if part > 1e-12 { steps.append(SpinStep(longitude: border, seconds: part)) }
                longitude = -border
                steps.append(SpinStep(longitude: longitude, seconds: 0))
                time -= part
            }
        }
        return steps
    }
}

/// A region for MapKit as plain numbers (`MapKitCamera.region(for:widthPoints:heightPoints:)`):
/// `MKCoordinateRegion(center:span:)` takes the centre and the spans in degrees, and
/// `MKCoordinateRegion(center:latitudinalMeters:longitudinalMeters:)` the metres.
public struct MapKitRegion: Hashable, Sendable {
    public var center: GeoCoordinate
    public var latitudeDelta: Double
    public var longitudeDelta: Double
    /// North to south: the width times the view's height over its width.
    public var latitudinalMeters: Double
    /// West to east through the centre: the camera's width.
    public var longitudinalMeters: Double

    public init(center: GeoCoordinate, latitudeDelta: Double, longitudeDelta: Double, latitudinalMeters: Double, longitudinalMeters: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
        self.latitudinalMeters = latitudinalMeters
        self.longitudinalMeters = longitudinalMeters
    }
}
