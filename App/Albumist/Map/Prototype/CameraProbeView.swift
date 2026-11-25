import MapKit
import QuartzCore
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// The camera probe over Apple's map (`CameraProbe`), full screen from the prototype's "Reise
/// abspielen" tab, on 3D satellite imagery with realistic elevation, without labels and gestures,
/// as the playback shows it. First it flies the fourth draft's stretch from Jökulsárlón to
/// Dettifoss in real time and says how long Apple's map was not finished, how many frames came,
/// what it loaded and how warm the iPhone got; then one still camera after another, each with
/// what was asked, what MapKit gave back once the map had rendered, and when. "Werte kopieren"
/// puts all of it on the clipboard. The map keeps its full width and Apple's logo and
/// "Rechtliches" stay visible above the bar.
struct CameraProbeView: View {
    let onClose: () -> Void

    @State private var model = CameraProbeModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CameraProbeMap(model: model)
                    .ignoresSafeArea(edges: .top)
                plate
            }
            bar
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.interrupted()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.resumed()
        }
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: model.title)
                .font(.headline)
                .accessibilityIdentifier("probe.title")
            Text(verbatim: model.asked)
                .font(.footnote)
                .accessibilityIdentifier("probe.asked")
            Text(verbatim: model.got)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("probe.got")
            Text(verbatim: model.readiness)
                .font(.footnote)
                .accessibilityIdentifier("probe.state")
            if model.canFlyAgain {
                PrototypeButton(title: "Nochmal fliegen", prominent: false) { model.flyAgain() }
                    .accessibilityIdentifier("probe.fly")
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            PrototypeButton(title: "Zurück", prominent: false) { model.step(by: -1) }
                .accessibilityIdentifier("probe.previous")
            PrototypeButton(title: "Weiter", prominent: true) { model.step(by: 1) }
                .accessibilityIdentifier("probe.next")
            PrototypeButton(title: model.copied ? "Kopiert" : "Werte kopieren", prominent: false) { model.copy() }
                .accessibilityIdentifier("probe.copy")
            PrototypeButton(title: "Schließen", prominent: false) { onClose() }
                .accessibilityIdentifier("probe.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black)
    }
}

/// Runs the probe's steps on the map. A still camera is set and the model waits for MapKit's first
/// fully rendered map after it (or `CameraProbe.waitSeconds`), then reads back the camera MapKit
/// made of it; a rendering counts only when it started after the camera was set, so the end of
/// the previous one never reads as the new one being ready. The flight (`CameraProbeFlightRun`)
/// waits the same way for its first camera, then a display link sets the flight's camera on every
/// frame, and after the landing the model waits until the map rests.
@MainActor @Observable final class CameraProbeModel {
    private(set) var index = 0
    private(set) var results: [Int: CameraProbeResult] = [:]
    private(set) var flights: [CameraProbeFlightResult] = []
    /// The flight's two lines while it starts, flies and lands (a few times a second).
    private(set) var flightGot = ""
    private(set) var flightState = ""
    /// The flight shown last is measured (its result is the last of `flights`).
    private(set) var flightDone = false
    /// The flight shown last was given up: the app left the foreground in the middle.
    private(set) var flightAbandoned = false
    private(set) var copied = false

    @ObservationIgnored private weak var mapView: MKMapView?
    @ObservationIgnored private var shownAt: CFTimeInterval = 0
    @ObservationIgnored private var renderingSinceShown = false
    /// MapKit is rendering now (between its "will start" and its "did finish"), whatever camera.
    @ObservationIgnored private var mapRendering = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wait: Task<Void, Never>?
    @ObservationIgnored private var run: CameraProbeFlightRun?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var network = MapMeasurements.NetworkLog()
    @ObservationIgnored private var lastLineUpdate: CFTimeInterval = 0

    var title: String { CameraProbe.title(index: index) }

    var asked: String {
        switch step {
        case .flight: CameraProbe.flightAsked
        case .still(let shot): CameraProbe.asked(shot)
        }
    }

    var got: String {
        switch step {
        case .flight: flightDone ? flights.last.map(CameraProbe.flightGot) ?? "" : flightGot
        case .still(let shot): results[index].map { CameraProbe.got(shot, $0) } ?? "MapKit: …"
        }
    }

    var readiness: String {
        switch step {
        case .flight: flightDone ? flights.last.map(CameraProbe.flightReadiness) ?? "" : flightState
        case .still: results[index].map(CameraProbe.readiness) ?? "Karte lädt …"
        }
    }

    var canFlyAgain: Bool { step == .flight && (flightDone || flightAbandoned) }

    private var step: CameraProbeStep { CameraProbe.steps[index] }

    func attach(_ mapView: MKMapView) {
        self.mapView = mapView
        show()
    }

    func detach() {
        stopFlight()
        wait?.cancel()
        wait = nil
        mapView = nil
    }

    /// The map got a new size: the camera again, and the wait starts over, unless the step is
    /// measured or its flight already took off.
    func layoutChanged() {
        switch step {
        case .still: if results[index] == nil { show() }
        case .flight: if Self.reshowsFlightOnLayout(phase: run?.phase, abandoned: flightAbandoned) { show() }
        }
    }

    /// A new size starts the flight's wait over only before take-off; never after a flight was
    /// given up (it waits for "Nochmal fliegen").
    nonisolated static func reshowsFlightOnLayout(phase: CameraProbeFlightRun.Phase?, abandoned: Bool) -> Bool {
        guard !abandoned else { return false }
        return phase == nil || phase == .starting
    }

    func step(by delta: Int) {
        let count = CameraProbe.steps.count
        index = ((index + delta) % count + count) % count
        copied = false
        show()
    }

    func flyAgain() {
        guard step == .flight else { return }
        show()
    }

    func renderingStarted() {
        mapRendering = true
        renderingSinceShown = true
        run?.renderingStarted(at: CACurrentMediaTime())
    }

    /// The first fully rendered map after the camera was set ends a still camera's wait and lets
    /// the flight take off.
    func renderingFinished(fully: Bool) {
        let now = CACurrentMediaTime()
        mapRendering = false
        if var run {
            run.renderingFinished(at: now, fully: fully)
            self.run = run
            if run.readyToTakeOff { takeOff(at: now) }
            return
        }
        guard case .still = step, fully, renderingSinceShown, results[index] == nil else { return }
        finish(readySeconds: now - shownAt)
    }

    /// The app leaves the foreground: the display link pauses, so a flight would count the pause.
    /// A flight in the air or landing is given up; a still camera still waiting is measured anew
    /// when the app is back (`resumed`).
    func interrupted() {
        if var run, run.phase != .done {
            generation += 1
            wait?.cancel()
            run.abandon()
            stopFlight()
            flightAbandoned = true
            setFlightLines(got: "Flug abgebrochen: Albumist war nicht mehr im Vordergrund", state: "„Nochmal fliegen“ misst neu")
        } else if case .still = step, results[index] == nil {
            generation += 1
            wait?.cancel()
        }
    }

    /// The app is back in the foreground: a still camera without a result waits anew.
    func resumed() {
        if case .still = step, results[index] == nil { show() }
    }

    func copy() {
        let device = "\(DeviceInfo.model) · \(DeviceInfo.system)"
        UIPasteboard.general.string = CameraProbe.clipboard(device: device, stills: results, flights: flights)
        copied = true
    }

    private func show() {
        guard let mapView, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        generation += 1
        stopFlight()
        wait?.cancel()
        // A rendering MapKit already runs gets no new "will start" for this camera: its finish counts.
        renderingSinceShown = mapRendering
        shownAt = CACurrentMediaTime()
        let mine = generation
        switch step {
        case .still(let shot):
            results[index] = nil
            mapView.setCamera(TripPlaybackCameraDriver.mapCamera(shot.camera), animated: false)
            wait = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CameraProbe.waitSeconds))
                guard !Task.isCancelled, let self, self.generation == mine else { return }
                self.finish(readySeconds: nil)
            }
        case .flight:
            flightDone = false
            flightAbandoned = false
            run = CameraProbeFlightRun(shownAt: shownAt, renderingInProgress: mapRendering)
            setFlightLines(got: "Der Flug startet, sobald die Karte steht", state: "Karte lädt …")
            mapView.setCamera(TripPlaybackCameraDriver.mapCamera(CameraProbe.flight.camera(at: 0)), animated: false)
            wait = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CameraProbe.waitSeconds))
                guard !Task.isCancelled, let self, self.generation == mine else { return }
                self.takeOff(at: CACurrentMediaTime())
            }
        }
    }

    private func finish(readySeconds: Double?) {
        guard results[index] == nil, let camera = mapView?.camera else { return }
        results[index] = CameraProbeResult(distanceMeters: camera.centerCoordinateDistance, pitchDegrees: Double(camera.pitch),
                                           readySeconds: readySeconds)
    }

    // MARK: The flight

    /// The start map is ready, or the wait for it is over: the display link flies from here.
    private func takeOff(at time: CFTimeInterval) {
        guard var run, run.phase == .starting else { return }
        wait?.cancel()
        run.takeOff(at: time)
        self.run = run
        network = MapMeasurements.NetworkLog()
        if let counters = PrototypeNetwork.counters() { network.add(counters) }
        let link = CADisplayLink(target: CameraProbeLinkTarget(model: self), selector: #selector(CameraProbeLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A frame while flying: the flight's camera at the time flown, until the last one.
    fileprivate func tick(_ link: CADisplayLink) {
        guard var run, run.phase == .flying, let mapView else {
            stopLink()
            return
        }
        let now = link.timestamp
        run.frame(at: now, expected: link.targetTimestamp - link.timestamp)
        let flight = CameraProbe.flight
        let flown = min(run.flown(at: now), flight.seconds)
        mapView.setCamera(TripPlaybackCameraDriver.mapCamera(flight.camera(at: flown)), animated: false)
        if flown >= flight.seconds {
            run.land(at: now)
            self.run = run
            stopLink()
            setFlightLines(got: CameraProbe.flightProgress(seconds: flown), state: "Gelandet, Karte lädt …")
            settleAfterLanding()
            return
        }
        self.run = run
        if now - lastLineUpdate >= 0.25 {
            lastLineUpdate = now
            setFlightLines(got: CameraProbe.flightProgress(seconds: flown), state: "Fliegt …")
        }
    }

    /// After the landing: every tenth of a second, until the map rested or the wait is over.
    private func settleAfterLanding() {
        let mine = generation
        wait?.cancel()
        wait = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.generation == mine else { return }
                if self.settle(at: CACurrentMediaTime()) { return }
            }
        }
    }

    /// Whether the run is over; when it is, its measurement joins `flights`.
    private func settle(at time: CFTimeInterval) -> Bool {
        guard var run else { return true }
        run.settle(at: time)
        self.run = run
        guard run.phase == .done else { return false }
        if let counters = PrototypeNetwork.counters() { network.add(counters) }
        let heat = MapMeasurements.Thermal(level: ProcessInfo.processInfo.thermalState.rawValue)
        if let result = run.result(network: network.result, heat: heat) { flights.append(result) }
        flightDone = true
        return true
    }

    private func setFlightLines(got: String, state: String) {
        if flightGot != got { flightGot = got }
        if flightState != state { flightState = state }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func stopFlight() {
        stopLink()
        run = nil
    }
}

/// The display link's target for the probe's flight: a display link keeps its target alive, so
/// this small object stands between it and the model (held weakly) and stops the link once the
/// model is gone.
@MainActor final class CameraProbeLinkTarget: NSObject {
    private weak var model: CameraProbeModel?

    init(model: CameraProbeModel) {
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
