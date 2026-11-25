import MapKit
import QuartzCore
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// Runs "Reise abspielen" (concept §4.4) over Apple's 3D satellite map: the plan (`PlaybackPlan`)
/// and the player (`PlaybackPlayer`) are pure values tested on Linux; this class only feeds them
/// the display link's clock and MapKit's rendering callbacks, moves the camera, draws the route
/// and the dot, and tells SwiftUI what to show. Every frame reads the camera of the plan at the
/// player's time, so a pause holds the picture from the next frame on. The camera goes through
/// `TripPlaybackCameraDriver`, the clock is `TripPlaybackClock` (TripPlaybackSupport.swift), and
/// what the screen shows is worked out in TripPlaybackModel+Screen.swift.
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
    private let cameraDriver: TripPlaybackCameraDriver
    private let clock: TripPlaybackClock

    @ObservationIgnored private var player: PlaybackPlayer
    @ObservationIgnored private var watch = PlaybackTileWatch()
    @ObservationIgnored private weak var container: TripPlaybackMapContainer?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var routeStops = -1
    @ObservationIgnored private var pauseTappedAt: Double?
    @ObservationIgnored private var jumpTappedAt: Double?
    @ObservationIgnored private var lastDeviceCheck = -Double.infinity
    @ObservationIgnored private var slideshowDays = 0

    init(trip: MapTrip, showsPhotos: Bool, metrics: PrototypeMetrics, onFinished: @escaping () -> Void) {
        let plan = PlaybackPlan(trip: trip)
        self.trip = trip
        self.plan = plan
        self.showsPhotos = showsPhotos
        self.metrics = metrics
        self.onFinished = onFinished
        self.player = PlaybackPlayer(plan: plan)
        self.cameraDriver = TripPlaybackCameraDriver()
        self.clock = TripPlaybackClock(metrics: metrics)
    }

    // MARK: Life cycle

    /// The map view is there: the camera at the current picture, and the clock runs while the
    /// screen is visible.
    func attach(_ container: TripPlaybackMapContainer) {
        self.container = container
        container.onLayout = { [weak self] in self?.containerLaidOut() }
        cameraDriver.forgetCamera()
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
        cameraDriver.restart()
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
        cameraDriver.move(plan: plan, player: player, mode: cameraMode, frameTime: frameTime, on: container?.mapView)
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

    private func setCamera(_ camera: PlaybackCamera) {
        cameraDriver.set(camera, on: container?.mapView)
    }

    /// The map view got its size (or a new one): MapKit needs the camera again for it.
    private func containerLaidOut() {
        guard let mapView = container?.mapView, mapView.bounds.size != cameraDriver.appliedSize else { return }
        setCamera(cameraDriver.applied ?? plan.frame(at: player.time).camera)
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
        guard visible, container != nil else { return }
        clock.start(for: self)
    }

    private func stopClock() {
        clock.stop()
    }
}
