import Foundation

// The frame pacing of `MapMeasurements`: the statistics of a view's frames and the logs that
// collect them while it runs.

extension MapMeasurements {
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
}
