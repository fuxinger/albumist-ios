import Foundation

// The times and events of `MapMeasurements` (first frame, tiles, pauses...) and the result of a
// 60-second test, which brings them together with the frames.

extension MapMeasurements {
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
        /// What went over Wi-Fi and the mobile network during the test, the whole iPhone's;
        /// `nil` when iOS gave no counters (and in tests stored before 21.11.2026).
        public var network: NetworkUse?

        /// `frameRuns`: the view's frames during the test; `gpuSeconds`: its GPU times during the
        /// test. Values out of range (a battery level of -1, a memory peak below the start) are
        /// made sensible here, so a stored result always encodes.
        public init(source: Source, startedAt: Date, plannedSeconds: Double, durationSeconds: Double, frameRuns: [[Double]], gpuSeconds: [Double],
                    thermalStart: Thermal, thermalEnd: Thermal, batteryStartPercent: Double?, batteryEndPercent: Double?, charging: Bool,
                    memoryStartMB: Double?, memoryPeakMB: Double?, events: [EventStats], notes: [String: String], network: NetworkUse? = nil) {
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
            self.network = network
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

        /// How many tests of one view are kept: the latest and the one before it, so the report
        /// can set a first run against a second (Apple's map comes partly from its cache then).
        public static let keptPerView = 2

        /// `stored` with `new` added: per view the `keptPerView` latest tests, oldest first, so the
        /// last test of a view in the list is its latest.
        public static func keeping(_ stored: [TestResult], adding new: TestResult) -> [TestResult] {
            let sameView = stored.filter { $0.source == new.source }.sorted { $0.startedAt < $1.startedAt }
            return stored.filter { $0.source != new.source } + sameView.suffix(keptPerView - 1) + [new]
        }
    }
}
