import MapKit
import QuartzCore
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

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

/// Runs "Reise abspielen" (concept §4.4) over Apple's 3D satellite map: the plan (`PlaybackPlan`)
/// and the player (`PlaybackPlayer`) are pure values tested on Linux; this class only feeds them
/// the display link's clock and MapKit's rendering callbacks, moves the camera, draws the route
/// and the dot, and tells SwiftUI what to show. Every frame reads the camera of the plan at the
/// player's time, so a pause holds the picture from the next frame on.
///
/// Measured: `.tileWait` (a day on the map, how long it waited), `.tileTimeout` and `.tileFailure`
/// (a day as a slideshow), `.pauseLatency` (from the tap to the first still frame), `.dayJump`
/// (from the tap to the frame at the day's start), and the frames through `DisplayLinkSampler`.
@MainActor @Observable final class TripPlaybackModel {
    /// How often MapKit's own animation goes on in `TripPlaybackCameraMode.steps`.
    static let stepSeconds = 0.5
    /// How often heat and Low Power Mode are read (concept §9).
    static let deviceCheckSeconds = 0.5
    /// How many photos fan out beside the dot.
    static let stackSize = 3

    let trip: MapTrip
    let plan: PlaybackPlan
    /// False for the demo trip: its photo ids are made up, quiet tiles stand in for photos.
    let showsPhotos: Bool

    private(set) var state: PlaybackPlayer.State = .paused
    private(set) var dayIndex = 0
    /// The place the title names (`PlaybackFrame.titlePlaceIndex`).
    private(set) var titlePlaceIndex: Int?
    /// The place whose photos fan out beside the dot, while the dot is at one.
    private(set) var stackPlaceIndex: Int?
    /// How far the playback is, 0 to 1, for the bar.
    private(set) var progress = 0.0
    /// A card covers Apple's map (`PlaybackPlayer.showsCover(now:)`).
    private(set) var showsCover = true
    private(set) var slideshowReason: PlaybackPlayer.SlideshowReason?
    private(set) var cameraMode: TripPlaybackCameraMode = .everyFrame
    /// The day under the finger while the bar is dragged.
    private(set) var previewDay: Int?

    private let metrics: PrototypeMetrics
    private let onFinished: () -> Void

    @ObservationIgnored private var player: PlaybackPlayer
    @ObservationIgnored private var watch = PlaybackTileWatch()
    @ObservationIgnored private weak var container: TripPlaybackMapContainer?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var sampler: DisplayLinkSampler?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var appliedCamera: PlaybackCamera?
    @ObservationIgnored private var appliedSize: CGSize = .zero
    @ObservationIgnored private var routeStops = -1
    @ObservationIgnored private var pauseTappedAt: Double?
    @ObservationIgnored private var jumpTappedAt: Double?
    @ObservationIgnored private var lastDeviceCheck = -Double.infinity
    @ObservationIgnored private var lastStep = -Double.infinity
    @ObservationIgnored private var slideshowDays = 0

    init(trip: MapTrip, showsPhotos: Bool, metrics: PrototypeMetrics, onFinished: @escaping () -> Void) {
        let plan = PlaybackPlan(trip: trip)
        self.trip = trip
        self.plan = plan
        self.showsPhotos = showsPhotos
        self.metrics = metrics
        self.onFinished = onFinished
        self.player = PlaybackPlayer(plan: plan)
    }

    // MARK: What the screen shows

    var isRunning: Bool { state == .playing || state == .waitingForTiles || state == .slideshowDay }

    /// "Tag 3 von 9 · Skógafoss" (the dragged-to day while the bar is dragged).
    var title: String {
        if let previewDay {
            return PlaybackText.dayTitle(index: previewDay, of: plan.days.count, place: placeName(playbackDay(previewDay)?.placeIndex))
        }
        return PlaybackText.dayTitle(index: dayIndex, of: plan.days.count, place: placeName(titlePlaceIndex))
    }

    /// "Mittwoch, 14. Juni 2023": the day as the clocks where the photos were taken saw it.
    var dateText: String {
        guard let shown = playbackDay(previewDay ?? dayIndex) else { return "" }
        return PlaybackText.date(shown.day)
    }

    /// The photos beside the dot now.
    var stack: [AssetID?] { stackIDs(for: stackPlaceIndex) }

    /// "+46": the day's photos beyond those in the stack.
    var moreText: String? {
        guard let shown = playbackDay(dayIndex) else { return nil }
        return PlaybackText.more(dayPhotos: shown.photoCount, shown: Self.stackSize)
    }

    /// Where each day after the first starts on the bar, 0 to 1.
    var dayFractions: [Double] {
        guard plan.duration > 0 else { return [] }
        return plan.days.dropFirst().map { $0.start / plan.duration }
    }

    /// "9 Tage · 412 Fotos · ca. 1.000 km vor Ort" for the end card.
    var summary: String { PlaybackText.summary(of: trip) }

    /// A place's photos (at most three) when photos are shown and it has some, else three quiet
    /// tiles (`nil`).
    func stackIDs(for placeIndex: Int?) -> [AssetID?] {
        if showsPhotos, let placeIndex, trip.geometry.places.indices.contains(placeIndex) {
            let ids = trip.geometry.places[placeIndex].coverCandidates.prefix(Self.stackSize)
            if !ids.isEmpty { return ids.map { Optional($0) } }
        }
        return Array(repeating: nil, count: Self.stackSize)
    }

    private func placeName(_ index: Int?) -> String? {
        guard let index, trip.geometry.places.indices.contains(index) else { return nil }
        return trip.geometry.places[index].name
    }

    private func playbackDay(_ index: Int) -> PlaybackDay? {
        plan.days.indices.contains(index) ? plan.days[index] : nil
    }

    // MARK: Life cycle

    /// The map view is there: the camera at the current picture, and the clock runs while the
    /// screen is visible.
    func attach(_ container: TripPlaybackMapContainer) {
        self.container = container
        container.onLayout = { [weak self] in self?.containerLaidOut() }
        appliedCamera = nil
        routeStops = -1
        setCamera(plan.frame(at: player.time).camera)
        startClock()
    }

    /// The map view goes away.
    func detach() {
        stopClock()
        container?.onLayout = nil
        container = nil
    }

    /// The screen appeared: the first time it plays at once with `autoplay`; later it goes on with
    /// the day it was at when it disappeared.
    func appeared(autoplay: Bool) {
        visible = true
        startClock()
        let now = CACurrentMediaTime()
        checkDevice(now: now, force: true)
        if !started {
            started = true
            metrics.note(.playback, "Kamera", cameraMode.label)
            if autoplay { send(.play, now: now) }
        } else {
            send(.appActive, now: now)
        }
        publish()
    }

    /// The screen went away (another tab, the page closed): paused like a locked iPhone.
    func disappeared() {
        send(.appInactive, now: CACurrentMediaTime())
        visible = false
        stopClock()
        publish()
    }

    /// Locking the iPhone, another app, a call: pause, and play that day again from its start
    /// when the app is back.
    func sceneChanged(active: Bool) {
        guard visible else { return }
        send(active ? .appActive : .appInactive, now: CACurrentMediaTime())
        publish()
    }

    // MARK: Controls

    /// "Pause" / "Weiter" (and "Nochmal" at the end).
    func togglePlay() {
        let now = CACurrentMediaTime()
        if player.isRunning {
            pauseTappedAt = now
            send(.pause, now: now)
        } else {
            send(.play, now: now)
        }
        publish()
    }

    /// A tap on the bar or the end of a drag: that day from its start.
    func jump(to index: Int) {
        let now = CACurrentMediaTime()
        previewDay = nil
        jumpTappedAt = now
        send(.jump(day: index), now: now)
        // Paused, a jump only moves there: the camera shows where.
        if player.state == .paused { setCamera(plan.frame(at: player.time).camera) }
        publish()
    }

    func jump(atFraction fraction: Double) {
        jump(to: plan.dayIndex(atFraction: fraction))
    }

    func preview(atFraction fraction: Double) {
        let index = plan.dayIndex(atFraction: fraction)
        if previewDay != index { previewDay = index }
    }

    func toggleCameraMode() {
        cameraMode = cameraMode == .everyFrame ? .steps : .everyFrame
        lastStep = -.infinity
        appliedCamera = nil
        metrics.note(.playback, "Kamera", cameraMode.label)
    }

    // MARK: MapKit's rendering

    func renderingStarted() {
        watch.willStartRendering(now: CACurrentMediaTime())
    }

    func renderingFinished(fully: Bool) {
        let now = CACurrentMediaTime()
        guard let verdict = watch.didFinishRendering(fully: fully, now: now) else { return }
        tiles(verdict, now: now)
        publish()
    }

    func loadingFailed() {
        let now = CACurrentMediaTime()
        if let verdict = watch.didFail(now: now) {
            tiles(verdict, now: now)
            publish()
        } else {
            // Not while a day waits: counted, the day goes on.
            metrics.event(.tileFailure, .playback, seconds: 0)
        }
    }

    // MARK: Every frame

    /// The display link's frame: measurements due, heat and Low Power Mode, the wait for the map,
    /// the player's clock, the camera, the route, the dot, the screen.
    func tick(_ link: CADisplayLink) {
        let frameTime = link.targetTimestamp
        let now = CACurrentMediaTime()
        if let tapped = pauseTappedAt {
            pauseTappedAt = nil
            metrics.event(.pauseLatency, .playback, seconds: max(0, frameTime - tapped))
        }
        if let tapped = jumpTappedAt {
            jumpTappedAt = nil
            metrics.event(.dayJump, .playback, seconds: max(0, frameTime - tapped))
        }
        checkDevice(now: now, force: false)
        if player.state == .waitingForTiles, let verdict = watch.check(now: now) {
            tiles(verdict, now: now)
        }
        apply(player.tick(now: frameTime))
        moveCamera(frameTime: frameTime)
        let frame = plan.frame(at: player.time)
        updateRoute(frame)
        container?.placeDot(at: frame.position)
        publish(frame, now: now)
    }

    // MARK: Inside

    private func send(_ event: PlaybackPlayer.Event, now: Double) {
        apply(player.handle(event, now: now))
    }

    private func tiles(_ verdict: PlaybackTileWatch.Verdict, now: Double) {
        switch verdict {
        case .rendered: send(.tilesRendered, now: now)
        case .failed: send(.tilesFailed, now: now)
        }
    }

    private func apply(_ notices: [PlaybackPlayer.Notice]) {
        for notice in notices {
            switch notice {
            case .waitingForTiles(let day):
                slideshowReason = nil
                setCamera(plan.frame(at: plan.startTime(ofDay: day)).camera)
                watch.cameraSet(now: CACurrentMediaTime())
            case .mapDay(_, let waited):
                metrics.event(.tileWait, .playback, seconds: waited)
            case .slideshowDay(let day, let reason):
                watch.stop()
                slideshowReason = reason
                record(reason)
                prepareDay(after: day, reason: reason)
            case .paused(let reason):
                watch.stop()
                if reason == .heat { metrics.note(.playback, "Pause", "Hitze kritisch") }
                setCamera(plan.frame(at: player.time).camera)
            case .resumed:
                break
            case .finished:
                onFinished()
            }
        }
    }

    private func record(_ reason: PlaybackPlayer.SlideshowReason) {
        slideshowDays += 1
        metrics.note(.playback, "Bilderfolge-Tage", "\(slideshowDays)")
        switch reason {
        case .timedOut(let waited): metrics.event(.tileTimeout, .playback, seconds: waited)
        case .failed(let waited): metrics.event(.tileFailure, .playback, seconds: waited)
        case .saving: break
        }
    }

    /// While a slideshow day hides the map, the map already goes to the next day's start, so that
    /// day's picture may be ready when it begins. Not while saving: then the map should rest.
    private func prepareDay(after day: Int, reason: PlaybackPlayer.SlideshowReason) {
        guard reason != .saving, day + 1 < plan.days.count else { return }
        setCamera(plan.frame(at: plan.startTime(ofDay: day + 1)).camera)
    }

    private func moveCamera(frameTime: Double) {
        guard player.state == .playing else { return }
        switch cameraMode {
        case .everyFrame:
            setCamera(plan.frame(at: player.time).camera)
        case .steps:
            guard frameTime - lastStep >= Self.stepSeconds else { return }
            lastStep = frameTime
            let ahead = min(player.time + Self.stepSeconds, player.dayEnd(player.day))
            setCamera(plan.frame(at: ahead).camera, animated: true)
        }
    }

    /// Sets Apple's camera, unless it already stands there (a camera set again would make MapKit
    /// render again, and the wait for the map would never see it at rest).
    private func setCamera(_ camera: PlaybackCamera, animated: Bool = false) {
        guard let mapView = container?.mapView else { return }
        let size = mapView.bounds.size
        guard animated || camera != appliedCamera || size != appliedSize else { return }
        appliedCamera = camera
        appliedSize = size
        mapView.setCamera(Self.mapCamera(camera), animated: animated)
    }

    static func mapCamera(_ camera: PlaybackCamera) -> MKMapCamera {
        MKMapCamera(lookingAtCenter: AppleMapsBridge.coordinate(camera.center), fromDistance: camera.distanceMeters,
                    pitch: CGFloat(camera.pitchDegrees), heading: camera.headingDegrees)
    }

    /// The map view got its size (or a new one): MapKit needs the camera again for it.
    private func containerLaidOut() {
        guard let mapView = container?.mapView, mapView.bounds.size != appliedSize else { return }
        setCamera(appliedCamera ?? plan.frame(at: player.time).camera)
        if player.state == .waitingForTiles { watch.cameraSet(now: CACurrentMediaTime()) }
        routeStops = -1
    }

    private func updateRoute(_ frame: PlaybackFrame) {
        guard frame.reachedStops != routeStops, let container else { return }
        routeStops = frame.reachedStops
        container.showRoute(plan.route(for: frame))
    }

    private func checkDevice(now: Double, force: Bool) {
        guard force || now - lastDeviceCheck >= Self.deviceCheckSeconds else { return }
        lastDeviceCheck = now
        let heat = Self.heat(ProcessInfo.processInfo.thermalState)
        if heat != player.heat {
            send(.heat(heat), now: now)
            metrics.note(.playback, "Wärme", Self.heatName(heat))
        }
        let saving = ProcessInfo.processInfo.isLowPowerModeEnabled
        if saving != player.lowPowerMode {
            send(.lowPowerMode(saving), now: now)
            metrics.note(.playback, "Stromsparmodus", saving ? "an" : "aus")
        }
    }

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

    private func publish() {
        publish(plan.frame(at: player.time), now: CACurrentMediaTime())
    }

    /// Hands SwiftUI what changed (only what changed: this runs every frame).
    private func publish(_ frame: PlaybackFrame, now: Double) {
        if state != player.state { state = player.state }
        if dayIndex != player.day { dayIndex = player.day }
        if titlePlaceIndex != frame.titlePlaceIndex { titlePlaceIndex = frame.titlePlaceIndex }
        let stackPlace = player.state == .finished ? nil : frame.placeIndex
        if stackPlaceIndex != stackPlace { stackPlaceIndex = stackPlace }
        let fraction = plan.fraction(at: player.time)
        if fraction != progress && (abs(fraction - progress) >= 0.001 || fraction == 0 || fraction == 1) { progress = fraction }
        let cover = player.showsCover(now: now)
        if showsCover != cover { showsCover = cover }
    }

    private func startClock() {
        guard link == nil, visible, container != nil else { return }
        let link = CADisplayLink(target: TripPlaybackLinkTarget(model: self), selector: #selector(TripPlaybackLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        if sampler == nil { sampler = DisplayLinkSampler(source: .playback, metrics: metrics) }
        sampler?.start()
    }

    private func stopClock() {
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
