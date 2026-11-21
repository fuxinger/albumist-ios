import Foundation

/// The measurements of the map prototype (concept 2.0 §9 and §13, wave 0): what the HUD of the
/// prototype page shows, what a 60-second test leaves behind and what goes into the diagnostic
/// report. The owner chooses between our own Metal globe and Apple's globe on his iPhone by
/// these numbers, so they are worked out here, in plain Swift tested on Linux, and the app only
/// collects timestamps and durations.
///
/// Frames are the times a frame reached the screen, in seconds of one monotonic clock
/// (`CACurrentMediaTime()` on the iPhone). The frames of one view between two pauses form a
/// run: the gap between two runs is the view standing still on purpose, never a hitch.
///
/// What leaves the device holds counts and times only (concept §8): no coordinate, no place,
/// trip or country name, no country code. Free notes go into the report only through
/// `reportNote(_:)`, which leaves out anything that looks like a coordinate.
public enum MapMeasurements {
    // MARK: - What is measured

    /// Which view a measurement comes from (the app's `MetricSource` with the same raw values).
    public enum Source: String, CaseIterable, Hashable, Sendable, Codable {
        case ownGlobe, appleGlobe, handoverMap, playback

        /// The name in the English diagnostic report.
        public var reportName: String {
            switch self {
            case .ownGlobe: "own globe"
            case .appleGlobe: "apple globe"
            case .handoverMap: "handover map"
            case .playback: "playback"
            }
        }

        /// The name on the German prototype page.
        public var germanName: String {
            switch self {
            case .ownGlobe: "Unser Globus"
            case .appleGlobe: "Apples Globus"
            case .handoverMap: "Apples Karte"
            case .playback: "Reise abspielen"
            }
        }
    }

    /// Things that happen once and have a duration in seconds (the app's `MetricEvent` with the
    /// same raw values).
    public enum Event: String, CaseIterable, Hashable, Sendable, Codable {
        case firstFrame, shaderCompile, textureLoad, maskBuild, handover, backToGlobe, pauseLatency, dayJump, tileWait, tileTimeout,
             tileFailure, memoryWarning

        /// Only how often it happened matters (its duration is 0): the report and the HUD give
        /// no times for it.
        public var countsOnly: Bool {
            switch self {
            case .tileTimeout, .tileFailure, .memoryWarning: true
            default: false
            }
        }

        /// The name in the English diagnostic report.
        public var reportName: String {
            switch self {
            case .firstFrame: "first frame"
            case .shaderCompile: "shader compile"
            case .textureLoad: "texture load"
            case .maskBuild: "mask build"
            case .handover: "handover"
            case .backToGlobe: "back to globe"
            case .pauseLatency: "pause latency"
            case .dayJump: "day jump"
            case .tileWait: "tile wait"
            case .tileTimeout: "tile timeout"
            case .tileFailure: "tile failure"
            case .memoryWarning: "memory warning"
            }
        }

        /// The short name on the German HUD.
        public var germanName: String {
            switch self {
            case .firstFrame: "Erstes Bild"
            case .shaderCompile: "Shader"
            case .textureLoad: "Erdbild"
            case .maskBuild: "Ländermaske"
            case .handover: "Übergabe"
            case .backToGlobe: "Zurück zum Globus"
            case .pauseLatency: "Pause"
            case .dayJump: "Tagsprung"
            case .tileWait: "Kacheln gewartet"
            case .tileTimeout: "Bilderfolge-Tage"
            case .tileFailure: "Ladefehler"
            case .memoryWarning: "Speicherwarnungen"
            }
        }
    }

    /// The device's heat as iOS reports it (`ProcessInfo.ThermalState`).
    public enum Thermal: String, CaseIterable, Hashable, Sendable, Codable, Comparable {
        case nominal, fair, serious, critical

        /// From `ProcessInfo.ThermalState.rawValue` (0 to 3); a value out of range is the
        /// nearest level.
        public init(level: Int) {
            switch level {
            case ...0: self = .nominal
            case 1: self = .fair
            case 2: self = .serious
            default: self = .critical
            }
        }

        /// The words of concept §9 ("ernst", "kritisch").
        public var germanName: String {
            switch self {
            case .nominal: "normal"
            case .fair: "erhöht"
            case .serious: "ernst"
            case .critical: "kritisch"
            }
        }

        public static func < (a: Thermal, b: Thermal) -> Bool { a.rank < b.rank }

        private var rank: Int {
            switch self {
            case .nominal: 0
            case .fair: 1
            case .serious: 2
            case .critical: 3
            }
        }
    }

    // MARK: - Statistics

    /// The `p`-th percentile (0 to 100) of `values`, linearly interpolated between the two
    /// nearest ranks (as spreadsheets' PERCENTILE.INC): the 50th is the median. Values that are
    /// not numbers are left out; `nil` without any value or for a `p` that is not a number.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !p.isNaN else { return nil }
        let sorted = values.filter { !$0.isNaN }.sorted()
        return percentile(sorted: sorted, p)
    }

    /// The median of `values` (the 50th percentile); `nil` without any value.
    public static func median(_ values: [Double]) -> Double? {
        percentile(values, 50)
    }

    /// `percentile` of values already sorted and free of NaN.
    static func percentile(sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty, !p.isNaN else { return nil }
        let position = min(max(p, 0), 100) / 100 * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        guard fraction > 0, upper != lower else { return sorted[lower] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// `value` when it is a number that is not infinite, else `nil`: JSON has no NaN or infinity,
    /// and a stored result must always encode.
    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    // MARK: - Frames

    /// The frame pacing of one view over some runs of frames.
    ///
    /// A frame time is the interval between two frames of one run. A hitch is an interval longer
    /// than `hitchFactor` times its run's median interval; its hitch time is how much longer it
    /// was than that median. The hitch time ratio is all hitch time in milliseconds per second of
    /// the runs (Apple's guide: under 5 ms/s is good, `goodHitchRatio`). Timestamps that are not
    /// numbers are left out, each run is sorted, and frames closer than `sameFrameSeconds` count
    /// as one, so a frame reported twice is no frame of zero duration.
    public struct FrameStats: Hashable, Sendable, Codable {
        /// An interval longer than this many times its run's median is a hitch.
        public static let hitchFactor = 1.5
        /// Apple's guide for the hitch time ratio: below this many ms per second is good.
        public static let goodHitchRatio = 5.0
        /// Timestamps closer than this (a microsecond) are the same frame.
        public static let sameFrameSeconds = 0.000_001

        /// Frames counted, each once.
        public var frames: Int
        /// Runs with at least one frame.
        public var runs: Int
        /// From the first to the last frame of each run, added up.
        public var seconds: Double
        /// 1 / the median frame time.
        public var medianFPS: Double?
        /// Frame intervals per second of the runs.
        public var averageFPS: Double?
        public var p50Ms: Double?
        public var p95Ms: Double?
        public var p99Ms: Double?
        public var longestMs: Double?
        public var hitches: Int
        public var hitchMs: Double
        /// `hitchMs` per second of the runs; `nil` when the runs last no time.
        public var hitchRatio: Double?

        /// No frames.
        public init() {
            self.init(frames: 0, runs: 0, seconds: 0, medianFPS: nil, averageFPS: nil, p50Ms: nil, p95Ms: nil, p99Ms: nil, longestMs: nil,
                      hitches: 0, hitchMs: 0, hitchRatio: nil)
        }

        public init(frames: Int, runs: Int, seconds: Double, medianFPS: Double?, averageFPS: Double?, p50Ms: Double?, p95Ms: Double?, p99Ms: Double?,
                    longestMs: Double?, hitches: Int, hitchMs: Double, hitchRatio: Double?) {
            self.frames = frames
            self.runs = runs
            self.seconds = seconds.isFinite ? seconds : 0
            self.medianFPS = finite(medianFPS)
            self.averageFPS = finite(averageFPS)
            self.p50Ms = finite(p50Ms)
            self.p95Ms = finite(p95Ms)
            self.p99Ms = finite(p99Ms)
            self.longestMs = finite(longestMs)
            self.hitches = hitches
            self.hitchMs = hitchMs.isFinite ? hitchMs : 0
            self.hitchRatio = finite(hitchRatio)
        }

        /// The pacing of `runs`, each a list of presentation timestamps in seconds.
        public init(runs: [[Double]]) {
            var intervals: [Double] = []
            var frames = 0, runCount = 0, hitches = 0
            var seconds = 0.0, hitchSeconds = 0.0
            for run in runs {
                let times = Self.cleaned(run)
                guard !times.isEmpty else { continue }
                frames += times.count
                runCount += 1
                guard times.count >= 2 else { continue }
                seconds += times[times.count - 1] - times[0]
                var gaps: [Double] = []
                gaps.reserveCapacity(times.count - 1)
                for index in 1..<times.count { gaps.append(times[index] - times[index - 1]) }
                let sortedGaps = gaps.sorted()
                if let median = percentile(sorted: sortedGaps, 50), median > 0 {
                    let limit = median * Self.hitchFactor
                    for gap in gaps where gap > limit {
                        hitches += 1
                        hitchSeconds += gap - median
                    }
                }
                intervals += gaps
            }
            intervals.sort()
            let p50 = percentile(sorted: intervals, 50)
            self.init(frames: frames, runs: runCount, seconds: seconds,
                      medianFPS: p50.flatMap { $0 > 0 ? 1 / $0 : nil },
                      averageFPS: seconds > 0 ? Double(intervals.count) / seconds : nil,
                      p50Ms: p50.map { $0 * 1_000 },
                      p95Ms: percentile(sorted: intervals, 95).map { $0 * 1_000 },
                      p99Ms: percentile(sorted: intervals, 99).map { $0 * 1_000 },
                      longestMs: intervals.last.map { $0 * 1_000 },
                      hitches: hitches, hitchMs: hitchSeconds * 1_000,
                      hitchRatio: seconds > 0 ? hitchSeconds * 1_000 / seconds : nil)
        }

        /// The run's timestamps that are numbers, sorted, each frame once.
        static func cleaned(_ run: [Double]) -> [Double] {
            let sorted = run.filter(\.isFinite).sorted()
            var kept: [Double] = []
            kept.reserveCapacity(sorted.count)
            for time in sorted where kept.last.map({ time - $0 >= sameFrameSeconds }) ?? true {
                kept.append(time)
            }
            return kept
        }

        /// The hitch time ratio is below Apple's guide (`goodHitchRatio`); `nil` when unknown.
        public var hitchesAreGood: Bool? { hitchRatio.map { $0 < Self.goodHitchRatio } }
    }

    /// The frames of one view as the app collects them, cheap per frame: a timestamp is appended
    /// to the open run, `pause()` closes it. At most about `capacity` frames are kept (the
    /// oldest go first, a tenth at a time, so trimming costs nothing per frame); `total` counts
    /// every frame ever appended.
    public struct FrameLog: Sendable {
        /// About three minutes at 120 frames per second, for each view.
        public static let defaultCapacity = 20_000

        public private(set) var runs: [[Double]] = []
        /// Frames kept.
        public private(set) var count = 0
        /// Frames appended since the log was made.
        public private(set) var total = 0
        public let capacity: Int
        private var isOpen = false

        public init(capacity: Int = FrameLog.defaultCapacity) {
            self.capacity = max(1, capacity)
        }

        /// A frame that reached the screen at `time`. A time that is not a positive number (a
        /// drawable that was never presented says 0) is left out.
        public mutating func append(_ time: Double) {
            guard time.isFinite, time > 0 else { return }
            if isOpen, !runs.isEmpty {
                runs[runs.count - 1].append(time)
            } else {
                runs.append([time])
                isOpen = true
            }
            count += 1
            total += 1
            if count > capacity + max(1, capacity / 10) { trim() }
        }

        /// The view stopped drawing: the next frame starts a new run.
        public mutating func pause() {
            isOpen = false
        }

        /// Drops the oldest frames down to `capacity`.
        private mutating func trim() {
            var excess = count - capacity
            while excess > 0, !runs.isEmpty {
                if runs[0].count <= excess {
                    excess -= runs[0].count
                    count -= runs[0].count
                    runs.removeFirst()
                } else {
                    runs[0].removeFirst(excess)
                    count -= excess
                    excess = 0
                }
            }
            if runs.isEmpty { isOpen = false }
        }

        /// The kept frames at or after `start`, in their runs (runs left empty are left out).
        public func runs(from start: Double) -> [[Double]] {
            runs.compactMap { run in
                let kept = run.filter { $0 >= start }
                return kept.isEmpty ? nil : kept
            }
        }

        /// Kept frames later than `time` ("fps now": the frames of the last second).
        public func frames(after time: Double) -> Int {
            runs.reduce(0) { found, run in found + run.reduce(0) { $0 + ($1 > time ? 1 : 0) } }
        }
    }

    /// Plain values in arrival order (the GPU time of each frame), at most about `capacity` kept;
    /// `total` counts every value ever appended, so "the values since a mark" survives trimming.
    public struct SampleLog: Sendable {
        public static let defaultCapacity = 20_000

        public private(set) var values: [Double] = []
        public private(set) var total = 0
        public let capacity: Int

        public init(capacity: Int = SampleLog.defaultCapacity) {
            self.capacity = max(1, capacity)
        }

        /// A value that is a number of zero or more; others are left out.
        public mutating func append(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            values.append(value)
            total += 1
            if values.count > capacity + max(1, capacity / 10) { values.removeFirst(values.count - capacity) }
        }

        /// The last `n` values kept.
        public func last(_ n: Int) -> [Double] {
            Array(values.suffix(max(0, n)))
        }

        /// The values appended since `total` was `mark` (as many of them as are still kept).
        public func since(_ mark: Int) -> [Double] {
            last(total - mark)
        }
    }

    // MARK: - Times and events

    /// Durations of one kind, in milliseconds: how many, their median and 95th percentile.
    public struct TimeStats: Hashable, Sendable, Codable {
        public var samples: Int
        public var medianMs: Double?
        public var p95Ms: Double?

        /// From durations in seconds; those that are not numbers of zero or more are left out.
        public init(seconds: [Double]) {
            let valid = seconds.filter { $0.isFinite && $0 >= 0 }.sorted()
            samples = valid.count
            medianMs = finite(percentile(sorted: valid, 50).map { $0 * 1_000 })
            p95Ms = finite(percentile(sorted: valid, 95).map { $0 * 1_000 })
        }
    }

    /// One kind of event of one view: how often, and its median, longest and last duration.
    public struct EventStats: Hashable, Sendable, Codable {
        public var event: Event
        /// Every time it happened, also those whose duration was not a number.
        public var count: Int
        public var medianSeconds: Double?
        public var maxSeconds: Double?
        public var lastSeconds: Double?

        /// `durations` in the order they happened; `count` when more happened than are listed
        /// (an event log keeps only the latest), else their number.
        public init(event: Event, durations: [Double], count: Int? = nil) {
            self.event = event
            self.count = max(count ?? durations.count, durations.count)
            let valid = durations.filter { $0.isFinite && $0 >= 0 }
            medianSeconds = finite(MapMeasurements.median(valid))
            maxSeconds = finite(valid.max())
            lastSeconds = finite(valid.last)
        }
    }

    /// The events of one view: every duration, at most `capacityPerEvent` per kind kept (the
    /// latest), every one counted.
    public struct EventLog: Sendable {
        public static let defaultCapacityPerEvent = 1_000

        public private(set) var durations: [Event: [Double]] = [:]
        public private(set) var counts: [Event: Int] = [:]
        public let capacityPerEvent: Int

        public init(capacityPerEvent: Int = EventLog.defaultCapacityPerEvent) {
            self.capacityPerEvent = max(1, capacityPerEvent)
        }

        public mutating func record(_ event: Event, seconds: Double) {
            counts[event, default: 0] += 1
            durations[event, default: []].append(seconds)
            if let kept = durations[event], kept.count > capacityPerEvent {
                durations[event] = Array(kept.suffix(capacityPerEvent))
            }
        }

        /// `nil` when it never happened.
        public func stats(_ event: Event) -> EventStats? {
            guard let count = counts[event], count > 0 else { return nil }
            return EventStats(event: event, durations: durations[event] ?? [], count: count)
        }

        /// Every kind that happened, in `Event.allCases` order.
        public var allStats: [EventStats] { Event.allCases.compactMap(stats) }
    }

    // MARK: - A 60-second test

    /// What a 60-second test of one view leaves behind (concept §9: frames while it turns or
    /// plays, heat and battery after a minute, memory): stored on the iPhone and written into the
    /// diagnostic report, so it survives a relaunch and reaches the team without a Mac.
    public struct TestResult: Hashable, Sendable, Codable {
        public var source: Source
        public var startedAt: Date
        /// How long the test was meant to run.
        public var plannedSeconds: Double
        /// How long it ran.
        public var durationSeconds: Double
        public var frames: FrameStats
        public var gpu: TimeStats
        public var thermalStart: Thermal
        public var thermalEnd: Thermal
        /// 0 to 100; `nil` when iOS did not say.
        public var batteryStartPercent: Double?
        public var batteryEndPercent: Double?
        /// Plugged in at the start or the end: the battery's use says little then.
        public var charging: Bool
        public var memoryStartMB: Double?
        public var memoryPeakMB: Double?
        /// The view's events so far (first frame, handover, tile waits, ...).
        public var events: [EventStats]
        /// The view's notes so far ("texture": "5400x2700, 78 MB").
        public var notes: [String: String]

        /// `frameRuns`: the view's frames during the test; `gpuSeconds`: its GPU times during the
        /// test. Values out of range (a battery level of -1, a memory peak below the start) are
        /// made sensible here, so a stored result always encodes.
        public init(source: Source, startedAt: Date, plannedSeconds: Double, durationSeconds: Double, frameRuns: [[Double]], gpuSeconds: [Double],
                    thermalStart: Thermal, thermalEnd: Thermal, batteryStartPercent: Double?, batteryEndPercent: Double?, charging: Bool,
                    memoryStartMB: Double?, memoryPeakMB: Double?, events: [EventStats], notes: [String: String]) {
            func percent(_ value: Double?) -> Double? {
                guard let value = finite(value), value >= 0, value <= 100 else { return nil }
                return value
            }
            func megabytes(_ value: Double?) -> Double? {
                guard let value = finite(value), value >= 0 else { return nil }
                return value
            }
            self.source = source
            self.startedAt = startedAt
            self.plannedSeconds = plannedSeconds.isFinite ? max(0, plannedSeconds) : 0
            self.durationSeconds = durationSeconds.isFinite ? max(0, durationSeconds) : 0
            frames = FrameStats(runs: frameRuns)
            gpu = TimeStats(seconds: gpuSeconds)
            self.thermalStart = thermalStart
            self.thermalEnd = thermalEnd
            self.batteryStartPercent = percent(batteryStartPercent)
            self.batteryEndPercent = percent(batteryEndPercent)
            self.charging = charging
            let start = megabytes(memoryStartMB)
            self.memoryStartMB = start
            let peak = megabytes(memoryPeakMB)
            self.memoryPeakMB = [start, peak].compactMap { $0 }.max()
            self.events = events
            self.notes = notes
        }

        /// Battery percentage points used per minute (positive: used); `nil` without both
        /// levels or when the test ran less than `minimumSecondsForBattery`.
        public var batteryPerMinute: Double? {
            guard let start = batteryStartPercent, let end = batteryEndPercent, durationSeconds >= Self.minimumSecondsForBattery else { return nil }
            return (start - end) / (durationSeconds / 60)
        }

        /// iOS gives the level in steps; a shorter test says nothing per minute.
        public static let minimumSecondsForBattery = 20.0

        /// The test ran its planned time (to within a second).
        public var isComplete: Bool { durationSeconds >= plannedSeconds - 1 }

        public func stats(_ event: Event) -> EventStats? { events.first { $0.event == event } }
    }

    // MARK: - Altitude of the photos

    /// One photo's location as PhotoKit has it (concept §13: "ob Fotos eine Höhen-Genauigkeit
    /// haben", for the record "Höchstes Foto").
    public struct AltitudeSample: Hashable, Sendable {
        public var hasLocation: Bool
        /// Metres above sea level; 0 when the camera wrote none.
        public var altitude: Double
        /// Metres; 0 or less when unknown.
        public var verticalAccuracy: Double

        public init(hasLocation: Bool, altitude: Double, verticalAccuracy: Double) {
            self.hasLocation = hasLocation
            self.altitude = altitude
            self.verticalAccuracy = verticalAccuracy
        }

        /// A photo without a location.
        public static let withoutLocation = AltitudeSample(hasLocation: false, altitude: 0, verticalAccuracy: 0)
    }

    /// How many of the newest photos carry an altitude and how exact it is: counts only.
    public struct AltitudeCheck: Hashable, Sendable, Codable {
        /// An altitude this exact or better counts as good enough for a summit.
        public static let goodVerticalAccuracyMeters = 30.0

        public var checkedAt: Date
        public var photos: Int
        public var withLocation: Int
        /// With a location whose altitude is a number other than 0.
        public var withAltitude: Int
        /// With a location whose vertical accuracy is a positive number.
        public var withVerticalAccuracy: Int
        /// The median of those vertical accuracies, in metres.
        public var medianVerticalAccuracy: Double?
        /// Vertical accuracy of `goodVerticalAccuracyMeters` or better.
        public var withinGoodAccuracy: Int

        public init(samples: [AltitudeSample], checkedAt: Date) {
            self.checkedAt = checkedAt
            photos = samples.count
            let located = samples.filter(\.hasLocation)
            withLocation = located.count
            withAltitude = located.filter { $0.altitude.isFinite && $0.altitude != 0 }.count
            let accuracies = located.map(\.verticalAccuracy).filter { $0.isFinite && $0 > 0 }
            withVerticalAccuracy = accuracies.count
            medianVerticalAccuracy = finite(MapMeasurements.median(accuracies))
            withinGoodAccuracy = accuracies.filter { $0 <= Self.goodVerticalAccuracyMeters }.count
        }
    }

    // MARK: - Live values for the HUD

    /// What the HUD shows for one view, made at most twice a second.
    public struct Live: Hashable, Sendable {
        public var source: Source
        /// Frames that reached the screen in the last second ("fps now"; 0 while it stands still).
        public var framesLastSecond: Int
        /// The pacing of the last few seconds.
        public var recent: FrameStats
        public var gpu: TimeStats
        public var thermal: Thermal
        public var memoryMB: Double?
        public var events: [EventStats]
        public var notes: [String: String]
        /// Frames since the page opened.
        public var totalFrames: Int
        /// How long the map summary of the user's own trips took to make, if it was made.
        public var summaryMilliseconds: Int?

        public init(source: Source, framesLastSecond: Int, recent: FrameStats, gpu: TimeStats, thermal: Thermal, memoryMB: Double?, events: [EventStats],
                    notes: [String: String], totalFrames: Int, summaryMilliseconds: Int?) {
            self.source = source
            self.framesLastSecond = framesLastSecond
            self.recent = recent
            self.gpu = gpu
            self.thermal = thermal
            self.memoryMB = memoryMB
            self.events = events
            self.notes = notes
            self.totalFrames = totalFrames
            self.summaryMilliseconds = summaryMilliseconds
        }

        public func stats(_ event: Event) -> EventStats? { events.first { $0.event == event } }
    }

    // MARK: - Texts

    /// The English lines of the diagnostic report: per view its latest test, then the altitude
    /// check. Counts and times only. Empty when nothing was measured.
    public static func lines(results: [TestResult], altitude: AltitudeCheck?) -> [String] {
        guard !results.isEmpty || altitude != nil else { return [] }
        let iso = ISO8601DateFormatter()
        var lines = ["map prototype: tests \(results.count), altitude check \(altitude == nil ? "no" : "yes")"]
        let ordered = results.sorted { a, b in
            (Source.allCases.firstIndex(of: a.source) ?? 0, a.startedAt) < (Source.allCases.firstIndex(of: b.source) ?? 0, b.startedAt)
        }
        for result in ordered {
            lines += testLines(result, iso: iso)
        }
        if let altitude {
            lines.append("map prototype altitude \(iso.string(from: altitude.checkedAt)): photos \(altitude.photos), with location \(altitude.withLocation), "
                + "with altitude \(altitude.withAltitude), with vertical accuracy \(altitude.withVerticalAccuracy), "
                + "median vertical accuracy \(english(altitude.medianVerticalAccuracy, decimals: 0, unit: " m")), "
                + "within \(Int(AltitudeCheck.goodVerticalAccuracyMeters)) m \(altitude.withinGoodAccuracy)")
        }
        return lines
    }

    /// The report lines of one test.
    static func testLines(_ result: TestResult, iso: ISO8601DateFormatter) -> [String] {
        let name = "map prototype \(result.source.reportName)"
        let f = result.frames
        var lines = [
            "\(name) test: \(english(result.durationSeconds, decimals: 0)) s of \(english(result.plannedSeconds, decimals: 0)) s, "
                + "complete \(result.isComplete), started \(iso.string(from: result.startedAt))",
            "\(name) frames \(f.frames) in \(english(f.seconds, decimals: 1)) s, runs \(f.runs), median \(english(f.medianFPS, decimals: 0)) fps, "
                + "average \(english(f.averageFPS, decimals: 1)) fps, frame ms p50 \(english(f.p50Ms, decimals: 1)), p95 \(english(f.p95Ms, decimals: 1)), "
                + "p99 \(english(f.p99Ms, decimals: 1)), longest \(english(f.longestMs, decimals: 1)), hitches \(f.hitches), "
                + "\(english(f.hitchRatio, decimals: 1)) ms/s",
            "\(name) gpu median \(english(result.gpu.medianMs, decimals: 1)) ms, p95 \(english(result.gpu.p95Ms, decimals: 1)) ms of \(result.gpu.samples) frames; "
                + "thermal \(result.thermalStart.rawValue) to \(result.thermalEnd.rawValue); battery \(english(result.batteryStartPercent, decimals: 0)) "
                + "to \(english(result.batteryEndPercent, decimals: 0)) % (\(english(result.batteryPerMinute, decimals: 1)) per minute, "
                + "charging \(result.charging)); memory \(english(result.memoryStartMB, decimals: 0)) MB, peak \(english(result.memoryPeakMB, decimals: 0)) MB",
        ]
        if !result.events.isEmpty {
            lines.append("\(name) events: " + result.events.map(eventText).joined(separator: "; "))
        }
        let notes = result.notes.keys.sorted().compactMap { key in reportNote("\(key) \(result.notes[key] ?? "")") }
        if !notes.isEmpty {
            lines.append("\(name) notes: " + notes.joined(separator: "; "))
        }
        return lines
    }

    /// "first frame 1, median 412 ms, max 412 ms", or only the count for counted events.
    static func eventText(_ stats: EventStats) -> String {
        guard !stats.event.countsOnly else { return "\(stats.event.reportName) \(stats.count)" }
        let median = english(stats.medianSeconds.map { $0 * 1_000 }, decimals: 0)
        let longest = english(stats.maxSeconds.map { $0 * 1_000 }, decimals: 0)
        return "\(stats.event.reportName) \(stats.count), median \(median) ms, max \(longest) ms"
    }

    /// The longest note the report takes.
    public static let maximumNoteLength = 80

    /// A free note as the report takes it: on one line, at most `maximumNoteLength` characters,
    /// and left out (`nil`) when it holds a number with three or more decimals, which may be a
    /// coordinate (no coordinate ever leaves the device, concept §8).
    public static func reportNote(_ note: String) -> String? {
        let line = note.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.range(of: #"\d[.,]\d{3}"#, options: .regularExpression) == nil else { return nil }
        return String(line.prefix(maximumNoteLength))
    }

    /// The German lines of the HUD; the first one alone when the HUD is folded.
    public static func hudLines(_ live: Live) -> [String] {
        let r = live.recent
        let fps = live.framesLastSecond > 0 ? "\(live.framesLastSecond) fps" : "steht still"
        var lines = [
            "\(live.source.germanName): \(fps) · p95 \(german(r.p95Ms, decimals: 1, unit: " ms")) · Hänger \(german(r.hitchRatio, decimals: 1, unit: " ms/s"))",
            "GPU \(german(live.gpu.medianMs, decimals: 1, unit: " ms")) · Hitze \(live.thermal.germanName) · Speicher \(german(live.memoryMB, decimals: 0, unit: " MB")) "
                + "· \(germanInteger(live.totalFrames)) Bilder",
        ]
        let timed: [Event] = [.firstFrame, .shaderCompile, .textureLoad, .maskBuild, .handover, .backToGlobe, .pauseLatency, .dayJump]
        let times = timed.compactMap { event in
            live.stats(event).map { "\(event.germanName) \(german($0.lastSeconds, decimals: 2, unit: " s"))" }
        }
        if !times.isEmpty { lines.append(times.joined(separator: " · ")) }
        var tiles: [String] = []
        if let wait = live.stats(.tileWait) {
            tiles.append("Kacheln gewartet \(wait.count)× (Median \(german(wait.medianSeconds, decimals: 2, unit: " s")))")
        }
        for event in [Event.tileTimeout, .tileFailure, .memoryWarning] {
            if let stats = live.stats(event) { tiles.append("\(event.germanName) \(stats.count)") }
        }
        if !tiles.isEmpty { lines.append(tiles.joined(separator: " · ")) }
        if let summary = live.summaryMilliseconds {
            lines.append("Zusammenfassung deiner Reisen: \(germanInteger(summary)) ms")
        }
        for key in live.notes.keys.sorted() {
            lines.append("\(key): \(live.notes[key] ?? "")")
        }
        return lines
    }

    /// The German result of a test, for the page: one short paragraph.
    public static func summary(_ result: TestResult) -> String {
        let f = result.frames
        var parts: [String] = []
        if !result.isComplete {
            parts.append("nach \(german(result.durationSeconds, decimals: 0, unit: " s")) beendet")
        }
        parts.append("Median \(german(f.medianFPS, decimals: 0, unit: " fps")), p95 \(german(f.p95Ms, decimals: 1, unit: " ms"))")
        let verdict = f.hitchesAreGood.map { $0 ? " (gut)" : " (zu hoch)" } ?? ""
        parts.append("Hänger \(german(f.hitchRatio, decimals: 1, unit: " ms/s"))\(verdict)")
        if result.gpu.samples > 0 { parts.append("GPU \(german(result.gpu.medianMs, decimals: 1, unit: " ms"))") }
        parts.append("Hitze \(result.thermalStart.germanName) → \(result.thermalEnd.germanName)")
        var battery = "Akku \(german(result.batteryStartPercent, decimals: 0, unit: "")) → \(german(result.batteryEndPercent, decimals: 0, unit: " %"))"
        if let perMinute = result.batteryPerMinute { battery += " (\(german(perMinute, decimals: 1, unit: " %/min")))" }
        if result.charging { battery += ", am Strom" }
        parts.append(battery)
        parts.append("Speicher \(german(result.memoryStartMB, decimals: 0, unit: "")) → \(german(result.memoryPeakMB, decimals: 0, unit: " MB"))")
        return "\(result.source.germanName), 60-s-Test: " + parts.joined(separator: " · ")
    }

    /// The German result of the altitude check, for the page.
    public static func summary(_ check: AltitudeCheck) -> String {
        guard check.photos > 0 else { return "Höhen: keine Fotos gefunden." }
        return "Höhen: \(germanInteger(check.photos)) neueste Fotos, \(germanInteger(check.withLocation)) mit Ort, "
            + "\(germanInteger(check.withAltitude)) mit Höhe, \(germanInteger(check.withVerticalAccuracy)) mit Höhengenauigkeit "
            + "(Median \(german(check.medianVerticalAccuracy, decimals: 0, unit: " m"))), "
            + "\(germanInteger(check.withinGoodAccuracy)) auf \(Int(AltitudeCheck.goodVerticalAccuracyMeters)) m genau."
    }

    // MARK: - Numbers

    /// `value` rounded to `decimals`, with a point, or "?" when unknown (as the report writes
    /// what it does not know).
    static func english(_ value: Double?, decimals: Int, unit: String = "") -> String {
        guard let value = rounded(value, decimals: decimals) else { return "?" }
        return String(format: "%.\(max(0, decimals))f", value) + unit
    }

    /// `value` rounded to `decimals`, with a decimal comma and points between thousands, or "–"
    /// when unknown.
    static func german(_ value: Double?, decimals: Int, unit: String) -> String {
        guard let value = rounded(value, decimals: decimals) else { return "–" }
        let text = String(format: "%.\(max(0, decimals))f", abs(value))
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = groupedThousands(String(parts[0]))
        let fraction = parts.count > 1 ? "," + parts[1] : ""
        return (value < 0 ? "−" : "") + whole + fraction + unit
    }

    /// A whole number with points between thousands ("7.187").
    static func germanInteger(_ value: Int) -> String {
        (value < 0 ? "−" : "") + groupedThousands(String(value.magnitude))
    }

    private static func groupedThousands(_ digits: String) -> String {
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return groups.isEmpty ? "0" : groups.joined(separator: ".")
    }

    /// `value` rounded to `decimals`; never "-0", `nil` when not a finite number.
    private static func rounded(_ value: Double?, decimals: Int) -> Double? {
        guard let value, value.isFinite else { return nil }
        let scale = pow(10, Double(max(0, decimals)))
        let rounded = (value * scale).rounded() / scale
        return rounded == 0 ? 0 : rounded
    }
}
