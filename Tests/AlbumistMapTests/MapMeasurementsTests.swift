import Foundation
import Testing
@testable import AlbumistMap

/// The statistics behind the map prototype's HUD, its 60-second tests and its lines in the
/// diagnostic report (`MapMeasurements`): frame pacing and hitches, events, heat, battery and
/// memory, the altitude check, and texts that hold counts and times only.
@Suite("Map measurements")
struct MapMeasurementsTests {
    typealias Metrics = MapMeasurements

    /// 64 frames over exactly one second at 64 frames per second, the 33rd left out: 62 frame
    /// times of 15.625 ms and one of 31.25 ms (binary-exact numbers, so sums are exact).
    static let hitchRun: [Double] = (0...64).filter { $0 != 32 }.map { 1_000 + Double($0) * 0.015_625 }
    /// 129 frames at 128 frames per second: one second without a hitch.
    static let steadyRun: [Double] = (0...128).map { 2_000 + Double($0) * 0.007_812_5 }

    static let started = Date(timeIntervalSince1970: 1_795_251_600)  // 2026-11-21 09:00 UTC
    static let checked = Date(timeIntervalSince1970: 1_795_255_200)  // 2026-11-21 10:00 UTC

    static func result(planned: Double = 60, duration: Double = 60, notes: [String: String] = ["texture": "5400x2700, 78 MB"]) -> Metrics.TestResult {
        Metrics.TestResult(source: .ownGlobe, startedAt: started, plannedSeconds: planned, durationSeconds: duration, frameRuns: [hitchRun],
                           gpuSeconds: [0.003, 0.004, 0.005, .nan, -1], thermalStart: .nominal, thermalEnd: .fair, batteryStartPercent: 81,
                           batteryEndPercent: 80, charging: false, memoryStartMB: 180.4, memoryPeakMB: 214.6,
                           events: [Metrics.EventStats(event: .firstFrame, durations: [0.412]), Metrics.EventStats(event: .tileFailure, durations: [0, 0])],
                           notes: notes)
    }

    /// Equal but for the last bits of a binary fraction (0.003 s is no exact binary number).
    static func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    static let altitude = Metrics.AltitudeCheck(samples: [
        Metrics.AltitudeSample(hasLocation: true, altitude: 512.3, verticalAccuracy: 8),
        Metrics.AltitudeSample(hasLocation: true, altitude: 0, verticalAccuracy: 0),
        Metrics.AltitudeSample(hasLocation: true, altitude: 100, verticalAccuracy: 45),
        .withoutLocation,
        Metrics.AltitudeSample(hasLocation: true, altitude: .nan, verticalAccuracy: -1),
        Metrics.AltitudeSample(hasLocation: true, altitude: 20, verticalAccuracy: 12),
    ], checkedAt: checked)

    // MARK: Percentiles

    @Test func percentilesInterpolateBetweenTheNearestRanks() {
        #expect(Metrics.percentile([], 50) == nil)
        #expect(Metrics.median([]) == nil)
        #expect(Metrics.median([7]) == 7)
        #expect(Metrics.median([4, 1, 3, 2]) == 2.5)
        #expect(Metrics.median([3, 1, 2]) == 2)
        #expect(Metrics.percentile([1, 2, 3, 4, 5], 0) == 1)
        #expect(Metrics.percentile([1, 2, 3, 4, 5], 100) == 5)
        #expect(Metrics.percentile([1, 2, 3, 4, 5], 25) == 2)
        #expect(Metrics.percentile([10, 20], 95) == 19.5)
        // Out of range: the nearest end; not a number: none.
        #expect(Metrics.percentile([1, 2, 3], -10) == 1)
        #expect(Metrics.percentile([1, 2, 3], 250) == 3)
        #expect(Metrics.percentile([1, 2, 3], .infinity) == 3)
        #expect(Metrics.percentile([1, 2, 3], .nan) == nil)
        // Values that are not numbers are left out.
        #expect(Metrics.median([.nan, 5, .nan]) == 5)
        #expect(Metrics.median([.nan]) == nil)
    }

    // MARK: Frames

    @Test func aSteadyRunHasNoHitch() {
        let stats = Metrics.FrameStats(runs: [Self.steadyRun])
        #expect(stats.frames == 129 && stats.runs == 1 && stats.seconds == 1)
        #expect(stats.medianFPS == 128 && stats.averageFPS == 128)
        #expect(stats.p50Ms == 7.8125 && stats.p95Ms == 7.8125 && stats.p99Ms == 7.8125 && stats.longestMs == 7.8125)
        #expect(stats.hitches == 0 && stats.hitchMs == 0 && stats.hitchRatio == 0)
        #expect(stats.hitchesAreGood == true)
    }

    @Test func aDroppedFrameIsAHitchOfItsExtraTime() {
        let stats = Metrics.FrameStats(runs: [Self.hitchRun])
        #expect(stats.frames == 64 && stats.runs == 1 && stats.seconds == 1)
        #expect(stats.medianFPS == 64 && stats.averageFPS == 63)
        #expect(stats.p50Ms == 15.625 && stats.p95Ms == 15.625 && stats.longestMs == 31.25)
        #expect(abs((stats.p99Ms ?? 0) - 21.5625) < 1e-9)
        // One hitch: 31.25 ms where the run's median is 15.625 ms, so 15.625 ms late.
        #expect(stats.hitches == 1 && stats.hitchMs == 15.625 && stats.hitchRatio == 15.625)
        #expect(stats.hitchesAreGood == false)
    }

    @Test func aHitchIsLongerThanOneAndAHalfMedians() {
        // Exactly 1.5 times the median is no hitch yet.
        #expect(Metrics.FrameStats(runs: [[0.5, 1.5, 2.5, 4.0]]).hitches == 0)
        let late = Metrics.FrameStats(runs: [[0.5, 1.5, 2.5, 4.1]])
        #expect(late.hitches == 1 && abs(late.hitchMs - 600) < 1e-6)
        // Each run against its own median: a 60 Hz run and a 120 Hz run, neither has a hitch.
        let sixty = (0...60).map { 10 + Double($0) / 64 }
        let mixed = Metrics.FrameStats(runs: [sixty, Self.steadyRun])
        #expect(mixed.hitches == 0 && mixed.runs == 2)
    }

    @Test func theGapBetweenRunsIsNoHitch() {
        let second = Self.hitchRun.map { $0 + 10 }
        let stats = Metrics.FrameStats(runs: [Self.hitchRun, second])
        #expect(stats.frames == 128 && stats.runs == 2)
        // Ten seconds of standing still count neither as time nor as a hitch.
        #expect(stats.seconds == 2 && stats.hitches == 2 && stats.hitchRatio == 15.625)
    }

    @Test func tinyAndBrokenRunsAreCountedSensibly() {
        for empty in [[], [[]], [[], []], [[Double.nan, .infinity, -.infinity]]] as [[[Double]]] {
            let stats = Metrics.FrameStats(runs: empty)
            #expect(stats == Metrics.FrameStats())
            #expect(stats.frames == 0 && stats.runs == 0 && stats.seconds == 0 && stats.p50Ms == nil && stats.hitchRatio == nil)
            #expect(stats.hitchesAreGood == nil)
        }
        let one = Metrics.FrameStats(runs: [[5]])
        #expect(one.frames == 1 && one.runs == 1 && one.seconds == 0)
        #expect(one.medianFPS == nil && one.averageFPS == nil && one.p50Ms == nil && one.longestMs == nil && one.hitchRatio == nil)
        // A frame reported twice (or within a microsecond) is one frame.
        #expect(Metrics.FrameStats(runs: [[5, 5]]).frames == 1)
        #expect(Metrics.FrameStats(runs: [[5, 5.000_000_1]]).frames == 1)
        let two = Metrics.FrameStats(runs: [[5, 5.5]])
        #expect(two.frames == 2 && two.seconds == 0.5 && two.p50Ms == 500 && two.medianFPS == 2 && two.hitches == 0 && two.hitchRatio == 0)
        // Unsorted, repeated and broken timestamps: sorted, each frame once, the rest left out.
        let messy = Metrics.FrameStats(runs: [[3, 1, .nan, 2, 2, 1, .infinity]])
        #expect(messy.frames == 3 && messy.seconds == 2 && messy.p50Ms == 1_000 && messy.hitches == 0)
        // A run of a single frame still counts as a run, but adds no time.
        let withSingle = Metrics.FrameStats(runs: [[7], Self.steadyRun])
        #expect(withSingle.frames == 130 && withSingle.runs == 2 && withSingle.seconds == 1)
    }

    @Test func frameStatsAlwaysEncode() throws {
        let stats = Metrics.FrameStats(frames: 3, runs: 1, seconds: .nan, medianFPS: .infinity, averageFPS: .nan, p50Ms: 1, p95Ms: .nan, p99Ms: nil,
                                       longestMs: -.infinity, hitches: 0, hitchMs: .nan, hitchRatio: .infinity)
        #expect(stats.seconds == 0 && stats.medianFPS == nil && stats.averageFPS == nil && stats.p50Ms == 1 && stats.p95Ms == nil)
        #expect(stats.longestMs == nil && stats.hitchMs == 0 && stats.hitchRatio == nil)
        let data = try JSONEncoder().encode(stats)
        #expect(try JSONDecoder().decode(Metrics.FrameStats.self, from: data) == stats)
        let real = Metrics.FrameStats(runs: [Self.hitchRun])
        #expect(try JSONDecoder().decode(Metrics.FrameStats.self, from: JSONEncoder().encode(real)) == real)
    }

    // MARK: Logs

    @Test func aFrameLogKeepsRunsAndTheNewestFrames() {
        var log = Metrics.FrameLog(capacity: 10)
        for bad in [0, -1, .nan, .infinity, -.infinity] as [Double] { log.append(bad) }
        #expect(log.count == 0 && log.total == 0 && log.runs.isEmpty)
        log.append(1)
        log.append(2)
        log.pause()
        log.pause()  // two pauses make no empty run
        log.append(3)
        #expect(log.runs == [[1, 2], [3]] && log.count == 3 && log.total == 3)
        for time in 4...25 { log.append(Double(time)) }
        // The oldest go in steps; at most a tenth over the capacity stays.
        #expect(log.total == 25 && log.count >= 10 && log.count <= 11)
        let kept = log.runs.flatMap { $0 }
        #expect(kept == (26 - log.count...25).map(Double.init))
        #expect(log.runs.allSatisfy { !$0.isEmpty })
        // The frames since a time, and those of the last second.
        #expect(log.runs(from: 23) == [[23, 24, 25]])
        #expect(log.runs(from: 99).isEmpty)
        #expect(log.frames(after: 22.5) == 3)
        #expect(log.frames(after: 25) == 0)
    }

    @Test func aFrameLogTrimsAcrossRuns() {
        var log = Metrics.FrameLog(capacity: 4)
        for time in [1.0, 2, 3] { log.append(time) }
        log.pause()
        log.append(4)
        log.append(5)
        log.pause()
        log.append(6)
        #expect(log.runs == [[3], [4, 5], [6]] && log.count == 4 && log.total == 6)
        // The open run goes on after trimming.
        log.append(7)
        #expect(log.runs.last == [6, 7])
        // A capacity below one is one.
        var tiny = Metrics.FrameLog(capacity: 0)
        for time in 1...5 { tiny.append(Double(time)) }
        #expect(tiny.capacity == 1 && tiny.count <= 2 && tiny.runs.flatMap { $0 }.last == 5)
    }

    @Test func aSampleLogFindsTheValuesSinceAMark() {
        var log = Metrics.SampleLog(capacity: 5)
        for bad in [-1, .nan, .infinity] as [Double] { log.append(bad) }
        #expect(log.total == 0)
        let mark = log.total
        for value in 1...7 { log.append(Double(value)) }
        #expect(log.total == 7 && log.values.count <= 6)
        #expect(log.since(4) == [5, 6, 7])
        #expect(log.since(mark) == log.values)
        #expect(log.since(7).isEmpty && log.since(9).isEmpty)
        #expect(log.last(2) == [6, 7] && log.last(0).isEmpty && log.last(-3).isEmpty)
        log.append(0)
        #expect(log.last(1) == [0])
    }

    @Test func eventsAreCountedEveryTimeAndTimedWhenTheyCan() {
        var log = Metrics.EventLog(capacityPerEvent: 3)
        log.record(.firstFrame, seconds: 0.5)
        for seconds in [1, 2, .nan, 3, 4] as [Double] { log.record(.tileWait, seconds: seconds) }
        #expect(log.stats(.handover) == nil)
        let first = log.stats(.firstFrame)
        #expect(first?.count == 1 && first?.medianSeconds == 0.5 && first?.maxSeconds == 0.5 && first?.lastSeconds == 0.5)
        // Five waits counted, the latest three kept: a duration that is no number counts but has no time.
        let waits = log.stats(.tileWait)
        #expect(waits?.count == 5 && waits?.medianSeconds == 3.5 && waits?.maxSeconds == 4 && waits?.lastSeconds == 4)
        #expect(log.allStats.map(\.event) == [.firstFrame, .tileWait])
        let broken = Metrics.EventStats(event: .pauseLatency, durations: [.nan, -1], count: 1)
        #expect(broken.count == 2 && broken.medianSeconds == nil && broken.maxSeconds == nil && broken.lastSeconds == nil)
    }

    @Test func timesAreInMilliseconds() {
        let gpu = Metrics.TimeStats(seconds: [0.002, 0.004, .nan, -0.001, .infinity, 0.003])
        #expect(gpu.samples == 3 && Self.close(gpu.medianMs, 3) && Self.close(gpu.p95Ms, 3.9))
        let none = Metrics.TimeStats(seconds: [])
        #expect(none.samples == 0 && none.medianMs == nil && none.p95Ms == nil)
    }

    // MARK: Heat, tests, altitude

    @Test func theFourHeatLevels() {
        #expect([-1, 0, 1, 2, 3, 7].map(Metrics.Thermal.init(level:)) == [.nominal, .nominal, .fair, .serious, .critical, .critical])
        #expect(Metrics.Thermal.allCases.sorted() == [.nominal, .fair, .serious, .critical])
        #expect(Metrics.Thermal.fair < .serious && !(Metrics.Thermal.critical < .nominal))
        #expect(Metrics.Thermal.allCases.map(\.germanName) == ["normal", "erhöht", "ernst", "kritisch"])
    }

    @Test func aTestResultTellsBatteryMemoryAndWhetherItRanItsTime() throws {
        let result = Self.result()
        #expect(result.isComplete && result.batteryPerMinute == 1)
        #expect(result.frames == Metrics.FrameStats(runs: [Self.hitchRun]))
        #expect(result.gpu.samples == 3 && Self.close(result.gpu.medianMs, 4) && Self.close(result.gpu.p95Ms, 4.9))
        #expect(result.memoryStartMB == 180.4 && result.memoryPeakMB == 214.6)
        #expect(result.stats(.firstFrame)?.medianSeconds == 0.412 && result.stats(.handover) == nil)
        #expect(Self.result(duration: 59.5).isComplete && !Self.result(duration: 30).isComplete)
        // Battery per minute needs both levels and a test of 20 s or more.
        #expect(Self.result(duration: 30).batteryPerMinute == 2)
        #expect(Self.result(duration: 10).batteryPerMinute == nil)
        var unknown = Self.result()
        unknown.batteryEndPercent = nil
        #expect(unknown.batteryPerMinute == nil)
        // Values out of range are made sensible, so the result always encodes.
        let odd = Metrics.TestResult(source: .playback, startedAt: Self.started, plannedSeconds: .nan, durationSeconds: .infinity, frameRuns: [[.nan]],
                                     gpuSeconds: [.nan], thermalStart: .critical, thermalEnd: .nominal, batteryStartPercent: -100,
                                     batteryEndPercent: .nan, charging: true, memoryStartMB: 300, memoryPeakMB: 120, events: [], notes: [:])
        #expect(odd.plannedSeconds == 0 && odd.durationSeconds == 0 && odd.batteryStartPercent == nil && odd.batteryEndPercent == nil)
        #expect(odd.memoryPeakMB == 300 && odd.frames.frames == 0)
        #expect(Metrics.TestResult(source: .appleGlobe, startedAt: Self.started, plannedSeconds: 60, durationSeconds: 60, frameRuns: [], gpuSeconds: [],
                                   thermalStart: .fair, thermalEnd: .fair, batteryStartPercent: 150, batteryEndPercent: 100, charging: false,
                                   memoryStartMB: .nan, memoryPeakMB: -5, events: [], notes: [:]).batteryStartPercent == nil)
        for value in [result, odd] {
            let data = try JSONEncoder().encode([value])
            #expect(try JSONDecoder().decode([Metrics.TestResult].self, from: data) == [value])
        }
    }

    @Test func theAltitudeCheckCountsOnly() throws {
        let check = Self.altitude
        #expect(check.photos == 6 && check.withLocation == 5 && check.withAltitude == 3)
        #expect(check.withVerticalAccuracy == 3 && check.medianVerticalAccuracy == 12 && check.withinGoodAccuracy == 2)
        let none = Metrics.AltitudeCheck(samples: [], checkedAt: Self.checked)
        #expect(none.photos == 0 && none.withLocation == 0 && none.medianVerticalAccuracy == nil)
        let noLocation = Metrics.AltitudeCheck(samples: [.withoutLocation, .withoutLocation], checkedAt: Self.checked)
        #expect(noLocation.photos == 2 && noLocation.withLocation == 0 && noLocation.withVerticalAccuracy == 0)
        #expect(try JSONDecoder().decode(Metrics.AltitudeCheck.self, from: JSONEncoder().encode(check)) == check)
    }
}
