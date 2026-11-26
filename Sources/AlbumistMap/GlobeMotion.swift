import Foundation
import AlbumistCore

/// One finger turning our globe (concept §7: "Drehen, Ausrollen und Zoomen fühlen sich an wie in
/// Apple Karten"): the point of the Earth grabbed under the finger stays under it. Where the
/// finger holds no point (off the disc, or so close to the horizon that a tiny move would turn the
/// globe a lot), the globe turns in proportion to the drag (`GlobeOptics.rotated`) and grabs the
/// point under the finger again as soon as there is a good one.
public struct GlobeDrag: Hashable, Sendable {
    /// Points closer to the horizon than this (`GlobeScreenPoint.horizonMargin`) are not held.
    public static let minimumHorizonMargin = 0.2

    /// The point held under the finger; nil while the finger holds none.
    public private(set) var grabbed: GeoCoordinate?
    /// Where the finger was at the last move, in points.
    public private(set) var x: Double
    public private(set) var y: Double

    public init(atX x: Double, y: Double, optics: GlobeOptics) {
        self.x = x.isFinite ? x : optics.widthPoints / 2
        self.y = y.isFinite ? y : optics.heightPoints / 2
        grabbed = Self.grab(atX: self.x, y: self.y, optics: optics)
    }

    /// The point of the Earth under (`x`, `y`) if it is far enough from the horizon to hold.
    static func grab(atX x: Double, y: Double, optics: GlobeOptics) -> GeoCoordinate? {
        guard let point = optics.unproject(x: x, y: y) else { return nil }
        return optics.project(point).horizonMargin >= minimumHorizonMargin ? point : nil
    }

    /// The camera with the finger moved to (`x`, `y`): the grabbed point under it if that can
    /// be, else the camera turned by the move since the last one.
    public mutating func move(toX x: Double, y: Double, optics: GlobeOptics) -> GlobeCamera {
        guard x.isFinite, y.isFinite else { return optics.camera }
        let dx = x - self.x, dy = y - self.y
        self.x = x
        self.y = y
        if let grabbed, let placed = optics.cameraPlacing(grabbed, atX: x, y: y, minimumHorizonMargin: Self.minimumHorizonMargin) {
            return placed
        }
        let turned = optics.rotated(byX: dx, y: dy)
        grabbed = Self.grab(atX: x, y: y, optics: GlobeOptics(camera: turned, widthPoints: optics.widthPoints, heightPoints: optics.heightPoints))
        return turned
    }

    /// The coasting after the finger lets go at `velocityX`, `velocityY` points per second: the
    /// globe goes on turning exactly as the drag turned it at that moment (the drag's own rule
    /// applied to the next 1/60 s of the finger's path), so letting go never jerks. Nil for a
    /// finger that came to rest (below `GlobeInertia.minimumStartSpeed`) or broken values.
    public func inertia(velocityX: Double, velocityY: Double, optics: GlobeOptics) -> GlobeInertia? {
        guard velocityX.isFinite, velocityY.isFinite else { return nil }
        let speed = (velocityX * velocityX + velocityY * velocityY).squareRoot()
        guard speed >= GlobeInertia.minimumStartSpeed else { return nil }
        let scale = min(1, GlobeInertia.maximumStartSpeed / speed)
        let step = 1.0 / 60
        var probe = self
        let now = optics.camera
        let ahead = probe.move(toX: x + velocityX * scale * step, y: y + velocityY * scale * step, optics: optics)
        let latitudeSpeed = (ahead.center.latitude - now.center.latitude) / step
        let longitudeSpeed = MapHome.normalizedLongitude(ahead.center.longitude - now.center.longitude) / step
        let inertia = GlobeInertia(latitudeSpeed: latitudeSpeed, longitudeSpeed: longitudeSpeed)
        return inertia.screenSpeed(optics) >= GlobeInertia.stopSpeed ? inertia : nil
    }
}

/// The globe coasting after a flick: its centre's latitude and longitude change at speeds that
/// decay exponentially (`timeConstant`, close to a UIScrollView's normal deceleration), worked
/// out exactly for any frame length, so 60 and 120 frames per second coast the same way. It
/// stops once the turn moves the view by less than `stopSpeed` points per second.
public struct GlobeInertia: Hashable, Sendable {
    /// Seconds for the speed to fall to 1/e.
    public static let timeConstant = 0.45
    /// Below this speed on screen (points per second) the coasting ends.
    public static let stopSpeed = 6.0
    /// A finger slower than this at letting go starts no coasting.
    public static let minimumStartSpeed = 40.0
    /// A faster flick counts as this fast (points per second).
    public static let maximumStartSpeed = 5_000.0

    /// Degrees per second.
    public private(set) var latitudeSpeed: Double
    public private(set) var longitudeSpeed: Double

    public init(latitudeSpeed: Double, longitudeSpeed: Double) {
        self.latitudeSpeed = latitudeSpeed.isFinite ? latitudeSpeed : 0
        self.longitudeSpeed = longitudeSpeed.isFinite ? longitudeSpeed : 0
    }

    /// The camera `seconds` after `optics.camera`, and whether the coasting has come to rest.
    /// Reaching the latitude limit ends the turn north or south.
    public mutating func advance(_ optics: GlobeOptics, by seconds: Double) -> (camera: GlobeCamera, isFinished: Bool) {
        guard seconds.isFinite, seconds > 0 else { return (optics.camera, screenSpeed(optics) < Self.stopSpeed) }
        let decay = exp(-seconds / Self.timeConstant)
        // ∫ v · e^(−t/τ) dt from 0 to the frame's length.
        let travelled = Self.timeConstant * (1 - decay)
        let center = optics.camera.center
        var latitude = center.latitude + latitudeSpeed * travelled
        if abs(latitude) >= GlobeOptics.latitudeLimit {
            latitude = latitude > 0 ? GlobeOptics.latitudeLimit : -GlobeOptics.latitudeLimit
            latitudeSpeed = 0
        }
        let longitude = MapHome.normalizedLongitude(center.longitude + longitudeSpeed * travelled)
        latitudeSpeed *= decay
        longitudeSpeed *= decay
        let camera = GlobeOptics.sanitized(GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: longitude),
                                                       widthMeters: optics.camera.widthMeters))
        let after = GlobeOptics(camera: camera, widthPoints: optics.widthPoints, heightPoints: optics.heightPoints)
        return (camera, screenSpeed(after) < Self.stopSpeed)
    }

    /// The turn's speed on screen in points per second, measured as the proportional turn
    /// (`GlobeOptics.rotated`) maps angles to points.
    public func screenSpeed(_ optics: GlobeOptics) -> Double {
        let north = latitudeSpeed * .pi / 180
        let east = longitudeSpeed * .pi / 180 * cos(optics.camera.center.latitude * .pi / 180)
        return (north * north + east * east).squareRoot() / optics.radiansPerPoint
    }
}

/// An eased flight of our globe's camera from one view to another (the trip's "Die Kamera fliegt
/// hin", a double tap, the prototype's jumps): the centre moves along the great circle, the
/// width changes evenly in its logarithm (every doubling takes as long), and on a long flight the
/// camera rises in the middle so that both ends fit into the view on the way (up to the whole
/// Earth). Eased in and out (cubic), so it starts and lands softly.
public struct GlobeFlight: Hashable, Sendable {
    public let from: GlobeCamera
    public let to: GlobeCamera
    /// Seconds; 0 lands at once (also for a negative duration or one that is no number).
    public let duration: Double

    public init(from: GlobeCamera, to: GlobeCamera, duration: Double) {
        self.from = GlobeOptics.sanitized(from)
        self.to = GlobeOptics.sanitized(to)
        self.duration = duration.isFinite ? max(duration, 0) : 0
    }

    /// The flight's middle shows at least this many times the distance between the two centres.
    public static let middleRoom = 1.3

    /// The width half way, in metres: the geometric mean of the two widths, or wider when the
    /// centres lie far apart (`middleRoom` times their distance, at most the whole Earth).
    public var middleWidthMeters: Double {
        exp((log(from.widthMeters) + log(to.widthMeters)) / 2 + rise)
    }

    /// How much the logarithm of the width rises above the straight line half way.
    var rise: Double {
        let angle = GlobeVector(from.center).angle(to: GlobeVector(to.center))
        let wanted = min(angle * GeoMath.earthRadiusMeters * Self.middleRoom, GlobeCamera.wholeEarth.widthMeters)
        guard wanted > 0 else { return 0 }
        return max(0, log(wanted) - (log(from.widthMeters) + log(to.widthMeters)) / 2)
    }

    /// The camera `elapsed` seconds into the flight (before it: the start; after it, or for an
    /// elapsed time that is no number: the end).
    public func camera(at elapsed: Double) -> GlobeCamera {
        guard duration > 0, elapsed.isFinite else { return to }
        let t = min(max(elapsed / duration, 0), 1)
        if t >= 1 { return to }
        if t <= 0 { return from }
        let e = Self.ease(t)
        let logWidth = (1 - e) * log(from.widthMeters) + e * log(to.widthMeters) + 4 * e * (1 - e) * rise
        let center = GlobeArcGeometry.slerp(GlobeVector(from.center), GlobeVector(to.center), e).coordinate
        return GlobeOptics.sanitized(GlobeCamera(center: center, widthMeters: exp(logWidth)))
    }

    public func isFinished(at elapsed: Double) -> Bool { !(elapsed < duration) }

    /// Cubic ease in and out: 0 → 0, 1 → 1, no speed at either end.
    public static func ease(_ t: Double) -> Double {
        guard t.isFinite else { return 1 }
        let t = min(max(t, 0), 1)
        if t < 0.5 { return 4 * t * t * t }
        let u = -2 * t + 2
        return 1 - u * u * u / 2
    }
}

/// The camera of our globe over time, the state the renderer draws from (concept §7, §9): the
/// gestures (drag, pinch, double tap), the coasting after a flick, flights, the slow spin of the
/// prototype's 60-second test, and the handover to Apple's map below
/// `GlobeCamera.handoverWidthMeters`: the camera that goes below it hands over once (the
/// renderer takes it with `takeHandover()` and stops drawing); nothing moves the globe after
/// that until `jump(to:)` brings it back and arms the handover again.
public struct GlobeMotion: Sendable {
    /// The prototype's spin round the north axis, westwards as the Earth turns seen from space.
    public static let spinDegreesPerSecond = 10.0
    /// A double tap's flight.
    public static let doubleTapSeconds = 0.35
    /// A frame longer than this (the app was busy or in the background) moves as far as this.
    public static let longestStep = 0.25

    public private(set) var camera: GlobeCamera
    /// The view's size in points, for the gestures.
    public var widthPoints: Double = 390
    public var heightPoints: Double = 844
    public var isAutoRotating = false
    /// Apple's map has taken over: nothing moves until `jump(to:)`.
    public private(set) var isHandedOver = false
    private var pendingHandover: GlobeCamera?
    private var activeFlight: GlobeFlight?
    private var flightElapsed = 0.0
    private var activeInertia: GlobeInertia?
    private var activeDrag: GlobeDrag?
    private var activePinch: GlobePinch?

    public init(camera: GlobeCamera = .wholeEarth) {
        self.camera = GlobeOptics.sanitized(camera)
        settle()
    }

    public var optics: GlobeOptics { GlobeOptics(camera: camera, widthPoints: widthPoints, heightPoints: heightPoints) }
    /// A finger is on the globe.
    public var isInteracting: Bool { activeDrag != nil || activePinch != nil }
    public var isFlying: Bool { activeFlight != nil }
    public var isCoasting: Bool { activeInertia != nil }
    /// The camera changes without new input: the renderer draws while it does (or while a
    /// finger is on the globe) and pauses otherwise.
    public var isMoving: Bool { !isHandedOver && (activeFlight != nil || activeInertia != nil || isAutoRotating) }

    /// At once to `camera`, ending every motion; arms the handover again (a camera already below
    /// the handover width hands over at once).
    public mutating func jump(to camera: GlobeCamera) {
        stopAll()
        self.camera = GlobeOptics.sanitized(camera)
        isHandedOver = false
        pendingHandover = nil
        settle()
    }

    /// An eased flight from the present camera; below the handover width on the way it hands
    /// over like a pinch would. Ignored after a handover (only `jump(to:)` brings the globe back).
    public mutating func fly(to camera: GlobeCamera, duration: Double) {
        guard !isHandedOver else { return }
        stopAll()
        let flight = GlobeFlight(from: self.camera, to: camera, duration: duration)
        if flight.duration > 0 {
            activeFlight = flight
            flightElapsed = 0
        } else {
            self.camera = flight.to
        }
        settle()
    }

    public mutating func beginDrag(atX x: Double, y: Double) {
        guard !isHandedOver else { return }
        stopAll()
        activeDrag = GlobeDrag(atX: x, y: y, optics: optics)
    }

    /// A drag that did not begin (a finger lifted from a pinch) begins here.
    public mutating func moveDrag(toX x: Double, y: Double) {
        guard !isHandedOver, activePinch == nil else { return }
        guard var drag = activeDrag else {
            beginDrag(atX: x, y: y)
            return
        }
        camera = drag.move(toX: x, y: y, optics: optics)
        activeDrag = drag
        settle()
    }

    /// The finger lets go at `velocityX`, `velocityY` points per second: the globe coasts on.
    public mutating func endDrag(velocityX: Double, velocityY: Double) {
        defer { activeDrag = nil }
        guard !isHandedOver, let drag = activeDrag else { return }
        activeInertia = drag.inertia(velocityX: velocityX, velocityY: velocityY, optics: optics)
    }

    /// Two fingers at (`x`, `y`), their centre: the point there stays under it while they pinch.
    public mutating func beginPinch(atX x: Double, y: Double) {
        guard !isHandedOver else { return }
        stopAll()
        activePinch = GlobePinch(startWidth: camera.widthMeters, grabbed: GlobeDrag.grab(atX: x, y: y, optics: optics))
    }

    /// `scale` since the pinch began (UIKit's `UIPinchGestureRecognizer.scale`): the width is
    /// the starting width divided by it.
    public mutating func movePinch(scale: Double, atX x: Double, y: Double) {
        guard !isHandedOver, let pinch = activePinch else { return }
        camera = optics.pinched(startWidth: pinch.startWidth, scale: scale, grabbed: pinch.grabbed, atX: x, y: y)
        settle()
    }

    public mutating func endPinch() {
        activePinch = nil
    }

    /// Half the width at the tapped point, as a short flight.
    public mutating func doubleTap(atX x: Double, y: Double) {
        guard !isHandedOver else { return }
        fly(to: optics.doubleTapTarget(atX: x, y: y), duration: Self.doubleTapSeconds)
    }

    /// A tap with two fingers: twice the width round the same centre, as a short flight (Apple's
    /// maps zoom out so), at most `GlobeCamera.maximumWidthMeters`.
    public mutating func zoomOut() {
        guard !isHandedOver else { return }
        fly(to: GlobeCamera(center: camera.center, widthMeters: camera.widthMeters * 2), duration: Self.doubleTapSeconds)
    }

    /// A finger touched the globe: a flight or the coasting stops where it is, as in Apple's maps.
    /// The spin goes on once no finger is on the globe.
    public mutating func halt() {
        activeFlight = nil
        activeInertia = nil
    }

    /// Moves the camera on by a frame of `seconds`: the flight, else the coasting, else the spin
    /// (not while a finger is on the globe).
    public mutating func advance(by seconds: Double) {
        guard !isHandedOver else { return }
        let step = seconds.isFinite ? min(max(seconds, 0), Self.longestStep) : 0
        if let flight = activeFlight {
            flightElapsed += step
            camera = flight.camera(at: flightElapsed)
            if flight.isFinished(at: flightElapsed) { activeFlight = nil }
        } else if var inertia = activeInertia {
            let next = inertia.advance(optics, by: step)
            camera = next.camera
            activeInertia = next.isFinished ? nil : inertia
        } else if isAutoRotating, !isInteracting {
            let longitude = MapHome.normalizedLongitude(camera.center.longitude - Self.spinDegreesPerSecond * step)
            camera = GlobeCamera(center: GeoCoordinate(latitude: camera.center.latitude, longitude: longitude), widthMeters: camera.widthMeters)
        }
        settle()
    }

    /// The camera of a handover that happened since the last call, once.
    public mutating func takeHandover() -> GlobeCamera? {
        defer { pendingHandover = nil }
        return pendingHandover
    }

    private mutating func stopAll() {
        activeFlight = nil
        activeInertia = nil
        activeDrag = nil
        activePinch = nil
    }

    /// The camera in range, and the handover when it went below the handover width.
    private mutating func settle() {
        camera = GlobeOptics.sanitized(camera)
        guard !isHandedOver, camera.isHandedOver else { return }
        isHandedOver = true
        pendingHandover = camera
        stopAll()
    }
}

/// A pinch in progress: the width when it began, and the point held under the fingers' centre.
struct GlobePinch: Hashable, Sendable {
    var startWidth: Double
    var grabbed: GeoCoordinate?
}
