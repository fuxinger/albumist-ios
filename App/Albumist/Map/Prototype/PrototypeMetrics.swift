import Foundation
import Observation
import QuartzCore
import UIKit
import AlbumistMap

/// Which view a measurement comes from.
enum MetricSource: String, CaseIterable, Sendable {
    case ownGlobe, appleGlobe, handoverMap, playback
}

/// Things that happen once and have a duration in seconds (0 when only the count matters).
enum MetricEvent: String, CaseIterable, Sendable {
    case firstFrame      // from the view's creation to its first presented frame
    case shaderCompile   // compiling the globe's Metal shaders at run time
    case textureLoad     // loading the Earth image into a texture
    case maskBuild       // building the visited-country mask
    case handover        // from the handover's start to Apple's map fully rendered
    case backToGlobe     // from leaving Apple's map to our globe's next presented frame
    case pauseLatency    // from the pause tap to the camera standing still
    case dayJump         // from a tap on a day to the camera at that day's start
    case tileWait        // how long a day waited for Apple's map to be fully rendered
    case tileTimeout     // a day that waited longer than 1.5 s and ran as a slideshow day
    case tileFailure     // Apple's map reported a loading failure
    case memoryWarning   // the system's memory warning arrived
}

extension MetricSource {
    /// The same view in the measurement core (tested on Linux).
    var measured: MapMeasurements.Source {
        switch self {
        case .ownGlobe: .ownGlobe
        case .appleGlobe: .appleGlobe
        case .handoverMap: .handoverMap
        case .playback: .playback
        }
    }
}

extension MetricEvent {
    /// The same event in the measurement core (tested on Linux).
    var measured: MapMeasurements.Event {
        switch self {
        case .firstFrame: .firstFrame
        case .shaderCompile: .shaderCompile
        case .textureLoad: .textureLoad
        case .maskBuild: .maskBuild
        case .handover: .handover
        case .backToGlobe: .backToGlobe
        case .pauseLatency: .pauseLatency
        case .dayJump: .dayJump
        case .tileWait: .tileWait
        case .tileTimeout: .tileTimeout
        case .tileFailure: .tileFailure
        case .memoryWarning: .memoryWarning
        }
    }
}

/// The measurements of the map prototype page (concept 2.0 §9, §13 wave 0): the views call it
/// for every frame, GPU time and event; the HUD reads it at most twice a second; a 60-second
/// test of one view adds heat, battery, memory and the data that went over the network, and
/// leaves a `MapMeasurements.TestResult`, which `MapPrototypeDiagnostics` keeps for the
/// diagnostic report.
///
/// Cheap per frame: a frame is a timestamp appended to an array, nothing is worked out and
/// nothing observed changes (the logs are `@ObservationIgnored`, so no view is drawn again
/// because a frame arrived). The statistics come from `MapMeasurements` when asked. Each log
/// keeps about the last 20,000 frames per view.
@MainActor @Observable final class PrototypeMetrics {
    /// A test that runs now.
    struct RunningTest: Equatable {
        var source: MetricSource
        var startedAt: Date
        var endsAt: Date
        var plannedSeconds: Double
        /// `CACurrentMediaTime()` at the start: the frames from then on belong to the test.
        var startMediaTime: Double
        var thermalStart: MapMeasurements.Thermal
        var batteryStartPercent: Double?
        var chargingAtStart: Bool
        var memoryStartMB: Double?
        /// The view's GPU log count at the start: the GPU times since then belong to the test.
        var gpuMark: Int
        /// The test turned battery monitoring on and turns it off again at its end.
        var enabledBatteryMonitoring: Bool
    }

    @ObservationIgnored private var frameLogs: [MetricSource: MapMeasurements.FrameLog] = [:]
    @ObservationIgnored private var gpuLogs: [MetricSource: MapMeasurements.SampleLog] = [:]
    @ObservationIgnored private var eventLogs: [MetricSource: MapMeasurements.EventLog] = [:]
    @ObservationIgnored private var notes: [MetricSource: [String: String]] = [:]
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var testPeakMB: Double?
    @ObservationIgnored private var testNetwork = MapMeasurements.NetworkLog()

    /// The view on screen: a memory warning is counted for it.
    @ObservationIgnored var activeSource: MetricSource = .ownGlobe
    /// How long the map summary of the user's own trips took to make, for the HUD.
    @ObservationIgnored var summaryMilliseconds: Int?

    /// The test that runs now, if any.
    private(set) var runningTest: RunningTest?
    /// The latest test of each view: of this page, else the one stored from before.
    private(set) var results: [MetricSource: MapMeasurements.TestResult] = [:]

    init() {
        for result in MapPrototypeDiagnostics.storedResults() {
            if let source = MetricSource(rawValue: result.source.rawValue) { results[source] = result }
        }
    }

    // MARK: What the views report

    /// A frame that reached the screen (our globe: when the GPU finished it, `gpuEndTime`; Apple's
    /// maps: a display link's `targetTimestamp`), in seconds of `CACurrentMediaTime()`'s clock.
    /// Consecutive calls of one source between two `pause(_:)` calls form one run of frames.
    func frame(_ source: MetricSource, presentedAt time: Double) {
        frameLogs[source, default: MapMeasurements.FrameLog()].append(time)
    }

    /// The source stopped drawing (idle, view gone): the next frame starts a new run, so the
    /// gap is no hitch.
    func pause(_ source: MetricSource) {
        frameLogs[source]?.pause()
    }

    /// The GPU time of one frame (`gpuEndTime - gpuStartTime`).
    func gpuTime(_ source: MetricSource, seconds: Double) {
        gpuLogs[source, default: MapMeasurements.SampleLog()].append(seconds)
    }

    func event(_ event: MetricEvent, _ source: MetricSource, seconds: Double) {
        eventLogs[source, default: MapMeasurements.EventLog()].record(event.measured, seconds: seconds)
    }

    /// A free value for the HUD and the report, e.g. note(.ownGlobe, "texture", "5400x2700, 78 MB").
    /// Never a coordinate or a name.
    func note(_ source: MetricSource, _ key: String, _ value: String) {
        notes[source, default: [:]][key] = value
    }

    /// iOS warned that memory runs low (the page forwards `UIApplication.didReceiveMemoryWarningNotification`).
    func memoryWarning() {
        event(.memoryWarning, activeSource, seconds: 0)
    }

    // MARK: The HUD

    /// What the HUD shows for `source` at `now` (`CACurrentMediaTime()`): the frames of the last
    /// second, the pacing of the last five, the GPU time of the last 600 frames, heat and memory now.
    func live(_ source: MetricSource, now: Double) -> MapMeasurements.Live {
        let log = frameLogs[source] ?? MapMeasurements.FrameLog()
        return MapMeasurements.Live(
            source: source.measured,
            framesLastSecond: log.frames(after: now - 1),
            recent: MapMeasurements.FrameStats(runs: log.runs(from: now - 5)),
            gpu: MapMeasurements.TimeStats(seconds: gpuLogs[source]?.last(600) ?? []),
            thermal: Self.thermalNow(),
            memoryMB: PrototypeMemory.footprintMB(),
            events: eventLogs[source]?.allStats ?? [],
            notes: notes[source] ?? [:],
            totalFrames: log.total,
            summaryMilliseconds: summaryMilliseconds)
    }

    // MARK: The 60-second test

    /// Starts a test of `source` (a test that runs is cancelled first). The page makes the view
    /// move (the globes turn, the trip plays); the test ends by itself after `seconds`.
    func startTest(_ source: MetricSource, seconds: Double = 60) {
        cancelTest()
        let device = UIDevice.current
        // Only for the test, unless something else already watches the battery (`BatteryLog`
        // turns it on at launch and never off).
        let enabled = !device.isBatteryMonitoringEnabled
        if enabled { device.isBatteryMonitoringEnabled = true }
        let memory = PrototypeMemory.footprintMB()
        testPeakMB = memory
        testNetwork = MapMeasurements.NetworkLog()
        sampleNetwork()
        let now = Date()
        runningTest = RunningTest(source: source, startedAt: now, endsAt: now.addingTimeInterval(seconds), plannedSeconds: seconds,
                                  startMediaTime: CACurrentMediaTime(), thermalStart: Self.thermalNow(), batteryStartPercent: Self.batteryPercent(),
                                  chargingAtStart: Self.isCharging(), memoryStartMB: memory, gpuMark: gpuLogs[source]?.total ?? 0,
                                  enabledBatteryMonitoring: enabled)
        testTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let test = self.runningTest, !Task.isCancelled else { return }
                self.sampleMemory()
                self.sampleNetwork()
                if Date() >= test.endsAt {
                    self.finishTest()
                    return
                }
            }
        }
    }

    /// Ends a running test without a result (the page closed, another tab).
    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        if let test = runningTest, test.enabledBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = false }
        runningTest = nil
    }

    /// The seconds left of the running test, for the countdown.
    func secondsLeft(at date: Date) -> Int? {
        guard let test = runningTest else { return nil }
        return max(0, Int(test.endsAt.timeIntervalSince(date).rounded(.up)))
    }

    private func sampleMemory() {
        guard let now = PrototypeMemory.footprintMB() else { return }
        testPeakMB = max(testPeakMB ?? now, now)
    }

    /// A reading of the network counters, about every half second while a test runs.
    private func sampleNetwork() {
        guard let reading = PrototypeNetwork.counters() else { return }
        testNetwork.add(reading)
    }

    private func finishTest() {
        guard let test = runningTest else { return }
        testTask?.cancel()
        testTask = nil
        sampleMemory()
        sampleNetwork()
        let source = test.source
        let result = MapMeasurements.TestResult(
            source: source.measured, startedAt: test.startedAt, plannedSeconds: test.plannedSeconds,
            durationSeconds: Date().timeIntervalSince(test.startedAt),
            frameRuns: frameLogs[source]?.runs(from: test.startMediaTime) ?? [],
            gpuSeconds: gpuLogs[source]?.since(test.gpuMark) ?? [],
            thermalStart: test.thermalStart, thermalEnd: Self.thermalNow(),
            batteryStartPercent: test.batteryStartPercent, batteryEndPercent: Self.batteryPercent(),
            charging: test.chargingAtStart || Self.isCharging(),
            memoryStartMB: test.memoryStartMB, memoryPeakMB: testPeakMB,
            events: eventLogs[source]?.allStats ?? [], notes: notes[source] ?? [:], network: testNetwork.result)
        if test.enabledBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = false }
        runningTest = nil
        results[source] = result
        MapPrototypeDiagnostics.store(result)
    }

    // MARK: The device

    private static func thermalNow() -> MapMeasurements.Thermal {
        MapMeasurements.Thermal(level: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// 0 to 100; nil while iOS does not say (-1, monitoring just turned on).
    private static func batteryPercent() -> Double? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) * 100 : nil
    }

    private static func isCharging() -> Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
}

/// Measures the main thread's frame pacing for views whose drawing we cannot see (Apple's
/// maps): a CADisplayLink feeding `metrics.frame(source, presentedAt: link.targetTimestamp)`.
@MainActor final class DisplayLinkSampler: NSObject {
    private let source: MetricSource
    private let metrics: PrototypeMetrics
    private var link: CADisplayLink?

    init(source: MetricSource, metrics: PrototypeMetrics) {
        self.source = source
        self.metrics = metrics
        super.init()
    }

    /// Idempotent. Asks for up to 120 Hz; iPhones stay at 60 Hz, because the app does not set
    /// `CADisableMinimumFrameDurationOnPhone` (it would change every animation of the app; the
    /// map decides that in wave 1, see docs/IMPROVEMENTS.md).
    func start() {
        guard link == nil else { return }
        let target = DisplayLinkTarget(sampler: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Idempotent; calls metrics.pause(source).
    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        metrics.pause(source)
    }

    fileprivate func tick(_ link: CADisplayLink) {
        metrics.frame(source, presentedAt: link.targetTimestamp)
    }
}

/// The display link's target: a display link keeps its target alive, so it holds the sampler
/// weakly, and a sampler that went away without `stop()` ends its display link at the next tick.
@MainActor private final class DisplayLinkTarget: NSObject {
    weak var sampler: DisplayLinkSampler?

    init(sampler: DisplayLinkSampler) {
        self.sampler = sampler
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let sampler else {
            link.invalidate()
            return
        }
        sampler.tick(link)
    }
}
