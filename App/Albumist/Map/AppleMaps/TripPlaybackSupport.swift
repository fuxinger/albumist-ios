import MapKit
import QuartzCore
import UIKit
import AlbumistCore
import AlbumistMap

// The helpers of "Reise abspielen" over Apple's map (TripPlaybackModel): how the camera moves, the
// object that sets it, the clock, and the names of the iPhone's heat levels.

/// How the playback moves Apple's camera (a switch of the prototype, to compare both on the iPhone).
enum TripPlaybackCameraMode: String, CaseIterable, Sendable {
    /// A new camera on every frame, without animation.
    case everyFrame
    /// Every half second MapKit's own animation (`setCamera(_:animated: true)`) to where the dot is
    /// half a second later.
    case steps

    var label: String {
        switch self {
        case .everyFrame: "Bild für Bild"
        case .steps: "Schritte"
        }
    }
}

/// Sets Apple's camera for the playback, unless it already stands there: a camera set again would
/// make MapKit render again, and the wait for the map would never see it at rest. While playing it
/// moves on every frame or in steps that MapKit animates (`TripPlaybackCameraMode`).
@MainActor final class TripPlaybackCameraDriver {
    /// The camera set last, and the map's size then.
    private(set) var applied: PlaybackCamera?
    private(set) var appliedSize: CGSize = .zero
    private var lastStep = -Double.infinity

    /// A new map view: the next camera is set even if it is the same.
    func forgetCamera() {
        applied = nil
    }

    /// Another camera mode: the next camera is set at once, and a step may start at once.
    func restart() {
        lastStep = -.infinity
        applied = nil
    }

    func set(_ camera: PlaybackCamera, on mapView: MKMapView?, animated: Bool = false) {
        guard let mapView else { return }
        let size = mapView.bounds.size
        guard animated || camera != applied || size != appliedSize else { return }
        applied = camera
        appliedSize = size
        mapView.setCamera(Self.mapCamera(camera), animated: animated)
    }

    /// While playing: the plan's camera on every frame, or every `TripPlaybackModel.stepSeconds`
    /// MapKit's animation to where the dot will be then (never past the day's end).
    func move(plan: PlaybackPlan, player: PlaybackPlayer, mode: TripPlaybackCameraMode, frameTime: Double, on mapView: MKMapView?) {
        guard player.state == .playing else { return }
        switch mode {
        case .everyFrame:
            set(plan.frame(at: player.time).camera, on: mapView)
        case .steps:
            guard frameTime - lastStep >= TripPlaybackModel.stepSeconds else { return }
            lastStep = frameTime
            let ahead = min(player.time + TripPlaybackModel.stepSeconds, player.dayEnd(player.day))
            set(plan.frame(at: ahead).camera, on: mapView, animated: true)
        }
    }

    static func mapCamera(_ camera: PlaybackCamera) -> MKMapCamera {
        MKMapCamera(lookingAtCenter: AppleMapsBridge.coordinate(camera.center), fromDistance: camera.distanceMeters,
                    pitch: CGFloat(camera.pitchDegrees), heading: camera.headingDegrees)
    }
}

/// The playback's clock: a display link at 30 to 60 frames a second that calls the model's
/// `tick(_:)`, and the sampler that measures its frames (`DisplayLinkSampler`, made on the first
/// start).
@MainActor final class TripPlaybackClock {
    private let metrics: PrototypeMetrics
    private var link: CADisplayLink?
    private var sampler: DisplayLinkSampler?

    init(metrics: PrototypeMetrics) {
        self.metrics = metrics
    }

    func start(for model: TripPlaybackModel) {
        guard link == nil else { return }
        let link = CADisplayLink(target: TripPlaybackLinkTarget(model: model), selector: #selector(TripPlaybackLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        if sampler == nil { sampler = DisplayLinkSampler(source: .playback, metrics: metrics) }
        sampler?.start()
    }

    func stop() {
        link?.invalidate()
        link = nil
        sampler?.stop()
    }
}

/// The display link's target: a display link keeps its target alive, so this small object stands
/// between it and the model (held weakly) and stops the link once the model is gone.
@MainActor final class TripPlaybackLinkTarget: NSObject {
    private weak var model: TripPlaybackModel?

    init(model: TripPlaybackModel) {
        self.model = model
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let model else {
            link.invalidate()
            return
        }
        model.tick(link)
    }
}

/// The iPhone's heat as the player knows it, and its German name for the measurements.
extension TripPlaybackModel {
    static func heat(_ state: ProcessInfo.ThermalState) -> PlaybackPlayer.Heat {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func heatName(_ heat: PlaybackPlayer.Heat) -> String {
        switch heat {
        case .nominal: "normal"
        case .fair: "erhöht"
        case .serious: "ernst"
        case .critical: "kritisch"
        }
    }
}
