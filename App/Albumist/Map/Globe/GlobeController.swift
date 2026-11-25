import Foundation
import QuartzCore
import AlbumistMap

/// What the page can do with our globe without SwiftUI re-rendering it every frame (shared
/// brief, section 4): jump, fly, the spin of the 60-second test, and what the globe shows. A
/// plain class, not observed: the globe draws on its own (`GlobeRenderer`), the page only tells
/// it what to do.
///
/// The camera's motion lives here (`GlobeMotion`, tested in the package), so a jump or a flight
/// asked for before the globe's view exists is not lost; the renderer advances it frame by frame
/// and turns it with the gestures.
@MainActor
final class GlobeController {
    /// The camera over time: gestures, coasting, flights, spin, handover.
    var motion: GlobeMotion
    /// The globe's renderer while its view is on screen, woken by every change.
    weak var renderer: GlobeRenderer?
    /// When a jump took the globe back from Apple's map (`CACurrentMediaTime()`), until the
    /// globe's next presented frame measures the way back (`MetricEvent.backToGlobe`). Kept
    /// here, so that it also holds when the page makes the globe's view anew for the way back.
    var backToGlobeStart: Double?

    init(camera: GlobeCamera = .wholeEarth) {
        motion = GlobeMotion(camera: camera)
    }

    /// The camera now (clamped), as the last drawn frame showed it; after a jump, the camera
    /// the next frame shows.
    var camera: GlobeCamera { motion.camera }

    /// Jumps at once (also re-arms the handover: a later zoom below 3,000 km hands over again).
    func jump(to camera: GlobeCamera) {
        if motion.isHandedOver { backToGlobeStart = CACurrentMediaTime() }
        motion.jump(to: camera)
        renderer?.controllerJumped()
    }

    /// Flies there with an eased animation of `duration` seconds; zooming below the handover
    /// width during the flight hands over like a pinch would. Ignored while Apple's map has
    /// taken over (only `jump(to:)` brings the globe back).
    func fly(to camera: GlobeCamera, duration: Double) {
        motion.fly(to: camera, duration: duration)
        renderer?.controllerChanged()
    }

    /// A slow constant spin round the north axis (10° per second) for the 60 s test.
    var isAutoRotating: Bool {
        get { motion.isAutoRotating }
        set {
            motion.isAutoRotating = newValue
            renderer?.controllerChanged()
        }
    }

    var showsPins = true {
        didSet { renderer?.controllerChanged() }
    }

    var showsArcs = true {
        didSet { renderer?.controllerChanged() }
    }

    var showsTint = true {
        didSet { renderer?.controllerChanged() }
    }
}
