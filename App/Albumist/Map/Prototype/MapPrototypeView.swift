import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// The three views the owner compares (concept 2.0 §13, wave 0).
enum PrototypeTab: String, CaseIterable, Identifiable {
    case ownGlobe, appleGlobe, playback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ownGlobe: "Unser Globus"
        case .appleGlobe: "Apples Globus"
        case .playback: "Reise abspielen"
        }
    }

    /// The view its 60-second test measures.
    var testSource: MetricSource {
        switch self {
        case .ownGlobe: .ownGlobe
        case .appleGlobe: .appleGlobe
        case .playback: .playback
        }
    }
}

/// What the page draws: the fixed demo load, or the user's own trips.
enum PrototypeData: String, CaseIterable, Identifiable {
    case demo, own

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demo: "Demo: 150 Bögen, 60 Stecknadeln"
        case .own: "Deine Reisen"
        }
    }
}

/// The demo load, made once: the same scene and trip on every iPhone, so measurements compare.
enum PrototypeDemo {
    static let scene = GlobeScene.demo(arcCount: 150, pinCount: 60)
    static let trip = DemoTrip.iceland()
    /// Iceland: where the owner judges the Earth image's sharpness just above the handover.
    static let iceland = GeoCoordinate(latitude: 64.9, longitude: -18.6)
    /// Just above the handover (3,000 km): the sharpest the Earth image is ever seen.
    static let icelandCamera = GlobeCamera(center: iceland, widthMeters: 3_200_000)
    /// The handover flight: from about 6,000 km to 2,500 km over Iceland in 3 s.
    static let handoverStart = GlobeCamera(center: iceland, widthMeters: 6_000_000)
    static let handoverEnd = GlobeCamera(center: iceland, widthMeters: 2_500_000)
    static let handoverSeconds = 3.0
}

/// Apple's map over our globe after a handover (`OwnGlobeView.onHandover`).
struct PrototypeHandover: Equatable {
    var camera: GlobeCamera
    /// A new map view for each handover.
    var number: Int
    /// Faded in: Apple's map has rendered fully (`HandoverMapView.onReady`).
    var shown = false
}

/// The globe's layers, switched for comparing their cost.
struct PrototypeLayers: Equatable {
    var showsPins = true
    var showsArcs = true
    var showsTint = true
}

/// The hidden prototype page of the map (concept 2.0 §13, wave 0), opened from the atlas in
/// TestFlight and debug builds (`MapPrototypeGate`): our Metal globe with the handover to Apple's
/// map, Apple's satellite globe, and a piece of "Reise abspielen", each with its measurements, a
/// HUD and a 60-second test. German only, and outside the string catalog (`Text(verbatim:)`):
/// a prototype the owner decides with, not a screen of the app.
struct MapPrototypeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var metrics = PrototypeMetrics()
    @State private var controller = GlobeController()
    @State private var tab: PrototypeTab = .ownGlobe
    @State private var data: PrototypeData = .demo
    @State private var scene: GlobeScene = PrototypeDemo.scene
    /// Counts the scenes shown: a new scene makes new map views.
    @State private var sceneVersion = 0
    @State private var summary: MapSummary?
    @State private var dataNote: String?
    @State private var loadingOwn = false
    @State private var outlines: [AtlasShape] = []
    @State private var handover: PrototypeHandover?
    @State private var layers = PrototypeLayers()
    @State private var hudOpen = true
    /// Counts the playbacks started: a new one gives the playback a new identity.
    @State private var playbackRun = 0
    @State private var autoplay = false
    @State private var tripID: AlbumistID?
    @State private var toolNote: String?

    var body: some View {
        reacting
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                metrics.memoryWarning()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                interrupted()
            }
            .onDisappear { leave() }
    }

    /// The page and what it does when its own state changes.
    private var reacting: some View {
        page
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden()
            .task { outlines = await AtlasOutlines.shared.load(from: model.worldMap) }
            .task(id: data) { await show(data) }
            .onChange(of: tab) { tabChanged() }
            .onChange(of: layers) { applyLayers() }
            .onChange(of: metrics.runningTest == nil) { _, ended in if ended { testEnded() } }
            .onChange(of: hudSource, initial: true) { metrics.activeSource = hudSource }
    }

    /// The HUD has a band of its own between the bar and the map, so it never covers what the
    /// views draw over their maps (the playback's buttons, Apple's compass); folded, it takes
    /// one line.
    private var page: some View {
        VStack(spacing: 0) {
            MapPrototypeHeader(tab: $tab, data: $data, note: dataNote, loading: loadingOwn) { dismiss() }
            MapPrototypeHUD(metrics: metrics, source: hudSource, isOpen: $hudOpen)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            controls
        }
    }

    // MARK: Views

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .ownGlobe:
            MapPrototypeGlobeTab(scene: scene, outlines: outlines, controller: controller, metrics: metrics, handover: $handover)
                .id(sceneVersion)
        case .appleGlobe:
            AppleGlobeView(scene: scene, camera: scene.firstCamera, isAutoRotating: isTesting(.appleGlobe), metrics: metrics)
                .id(sceneVersion)
        case .playback:
            TripPlaybackView(trip: playbackTrip, showsPhotos: showsOwnTrips, autoplay: autoplay, metrics: metrics,
                             onFinished: { playbackFinished() })
                .id(playbackKey)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            tabTools
            actions
            MapPrototypeNotes(metrics: metrics, source: tab.testSource, toolNote: toolNote)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            MapPrototypeTestButton(metrics: metrics, onStart: { startTest() })
            PrototypeButton(title: "Höhen prüfen", prominent: false, action: { checkAltitudes() })
                .accessibilityIdentifier("proto.altitudes")
            PrototypeButton(title: "Messwerte kopieren", prominent: false, action: { copyMeasurements() })
                .accessibilityIdentifier("proto.copy")
        }
    }

    @ViewBuilder
    private var tabTools: some View {
        switch tab {
        case .ownGlobe:
            MapPrototypeGlobeTools(layers: $layers, onIceland: { showIceland() }, onHandover: { flyToHandover() })
        case .appleGlobe:
            Text(verbatim: "Apples Satelliten-Globus mit denselben Bögen (flach) und Stecknadeln.")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        case .playback:
            MapPrototypeTripPicker(trips: ownTripsNewestFirst, selection: $tripID, current: playbackTrip)
        }
    }

    // MARK: State

    /// The view the HUD shows: Apple's map while it covers our globe.
    private var hudSource: MetricSource {
        if tab == .ownGlobe, handover?.shown == true { return .handoverMap }
        return tab.testSource
    }

    private func isTesting(_ source: MetricSource) -> Bool {
        metrics.runningTest?.source == source
    }

    /// The user's own trips are shown (not the demo).
    private var showsOwnTrips: Bool {
        data == .own && !(summary?.trips.isEmpty ?? true)
    }

    private var ownTripsNewestFirst: [MapTrip] {
        guard showsOwnTrips, let summary else { return [] }
        return summary.trips.sorted { $0.geometry.start > $1.geometry.start }
    }

    private var playbackTrip: MapTrip {
        let trips = ownTripsNewestFirst
        return trips.first { $0.id == tripID } ?? trips.first ?? PrototypeDemo.trip
    }

    private var playbackKey: String {
        "\(playbackTrip.id.rawValue)-\(playbackRun)-\(sceneVersion)"
    }

    // MARK: Actions

    /// Shows the demo, or makes the summary of the user's own trips (once) and shows it; without
    /// own trips the demo stays, with a calm note.
    private func show(_ choice: PrototypeData) async {
        guard choice == .own else {
            dataNote = nil
            setScene(PrototypeDemo.scene)
            return
        }
        if summary == nil {
            loadingOwn = true
            if let made = await model.mapPrototypeSummary() {
                summary = made.summary
                metrics.summaryMilliseconds = made.milliseconds
                MapPrototypeDiagnostics.store(summary: made.summary, buildMilliseconds: made.milliseconds)
            }
            loadingOwn = false
        }
        guard let summary, !summary.trips.isEmpty else {
            dataNote = "Noch keine eigenen Reisen gefunden. Die Demo bleibt zu sehen."
            setScene(PrototypeDemo.scene)
            return
        }
        let milliseconds = metrics.summaryMilliseconds.map { " · Zusammenfassung in \($0) ms" } ?? ""
        dataNote = "\(summary.trips.count) Reisen, \(summary.arcs.count) Bögen, \(summary.pins.count) Stecknadeln\(milliseconds)"
        setScene(GlobeScene(summary: summary))
    }

    private func setScene(_ newScene: GlobeScene) {
        guard newScene != scene else { return }
        metrics.cancelTest()
        handover = nil
        scene = newScene
        sceneVersion += 1
        tripID = nil
        controller.jump(to: newScene.firstCamera)
    }

    private func tabChanged() {
        metrics.cancelTest()
        autoplay = false
        controller.isAutoRotating = false
        // Back on our globe later, it must not stand handed over without Apple's map above it.
        if let left = handover {
            handover = nil
            controller.jump(to: GlobeCamera(center: left.camera.center, widthMeters: PrototypeDemo.icelandCamera.widthMeters))
        }
    }

    private func applyLayers() {
        controller.showsPins = layers.showsPins
        controller.showsArcs = layers.showsArcs
        controller.showsTint = layers.showsTint
    }

    private func showIceland() {
        handover = nil
        controller.jump(to: PrototypeDemo.icelandCamera)
    }

    private func flyToHandover() {
        handover = nil
        controller.jump(to: PrototypeDemo.handoverStart)
        controller.fly(to: PrototypeDemo.handoverEnd, duration: PrototypeDemo.handoverSeconds)
    }

    /// The 60-second test of the tab's view: the globes turn, the trip plays from its start.
    /// Our globe's test starts on the whole Earth, without Apple's map over it.
    private func startTest() {
        switch tab {
        case .ownGlobe:
            handover = nil
            controller.jump(to: .wholeEarth)
            controller.isAutoRotating = true
        case .appleGlobe:
            break
        case .playback:
            autoplay = true
            playbackRun += 1
        }
        metrics.startTest(tab.testSource, seconds: Self.testSeconds)
    }

    /// 60 s; 10 s in UI runs, so the UI test sees a test end and leave its result.
    static var testSeconds: Double { UITestSupport.isRunning ? 10 : 60 }

    private func testEnded() {
        controller.isAutoRotating = false
        autoplay = false
    }

    /// A trip played to its end during the test plays again, so the test measures playing.
    private func playbackFinished() {
        guard isTesting(.playback) else { return }
        playbackRun += 1
    }

    private func checkAltitudes() {
        toolNote = "Höhen werden geprüft …"
        Task {
            guard let check = await AltitudeAccuracyCheck.run() else {
                toolNote = "Ohne Zugriff auf deine Fotos lassen sich die Höhen nicht prüfen."
                return
            }
            MapPrototypeDiagnostics.store(check)
            toolNote = MapMeasurements.summary(check)
        }
    }

    /// The report's lines (English, counts and times only) to paste into a message.
    private func copyMeasurements() {
        let lines = MapPrototypeDiagnostics.lines()
        let header = "Albumist map prototype, \(DeviceInfo.model), \(DeviceInfo.system)"
        UIPasteboard.general.string = ([header] + (lines.isEmpty ? ["map prototype: nothing measured yet"] : lines)).joined(separator: "\n")
        toolNote = "Messwerte kopiert (\(lines.count) Zeilen)."
    }

    /// A test measures only what stayed on screen the whole time: leaving the app (Control
    /// Center, a call, the Home Screen) cancels it, and the page says why.
    private func interrupted() {
        guard metrics.runningTest != nil else { return }
        metrics.cancelTest()
        toolNote = "Test abgebrochen: Albumist war nicht mehr im Vordergrund."
    }

    private func leave() {
        metrics.cancelTest()
        controller.isAutoRotating = false
    }
}
