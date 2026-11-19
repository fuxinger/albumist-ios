import Foundation

/// What MetricKit says about Albumist's energy and responsiveness, for the diagnostic report
/// (owner, 19.11.2026: "Sollte auch noch Batterie verbraucht analysieren"). iOS sends a payload
/// for each day at most once a day; the app keeps the numbers of the last week
/// (`EnergyMetricsSubscriber` on the device fills this in, `UserDefaults`). Only numbers and
/// short names, never anything about the photos; nothing leaves the phone unless the user
/// shares the report.
///
/// MetricKit has no battery percentage for one app: CPU and GPU time are what the analysis'
/// energy shows up in (the image step runs Vision on the CPU, GPU and Neural Engine). The
/// battery number itself comes from the app's own measuring (`BatteryUse`).
public struct EnergyMetricsLog: Codable, Sendable, Equatable {
    /// How many days and diagnostic reports are kept.
    public static let kept = 7

    /// One `MXMetricPayload`: about one day.
    public struct Day: Codable, Sendable, Equatable {
        public var begin: Date
        public var end: Date
        public var build: String?
        /// `MXCPUMetric.cumulativeCPUTime`.
        public var cpuSeconds: Double?
        /// `MXGPUMetric.cumulativeGPUTime`.
        public var gpuSeconds: Double?
        /// `MXAppRunTimeMetric`.
        public var foregroundSeconds: Double?
        public var backgroundSeconds: Double?
        /// `MXAppResponsivenessMetric.histogrammedApplicationHangTime`, bucket by bucket.
        public var hangBuckets: [HangBucket]?
        /// The hangs of the day: the sum of the buckets' counts (second review: the number of
        /// buckets is not the number of hangs).
        public var hangCount: Int? { hangBuckets.map { $0.reduce(0) { $0 + $1.count } } }
        /// The upper end of the longest bucket with a hang.
        public var longestHang: Double? { hangBuckets?.filter { $0.count > 0 }.map(\.upTo).max() }
        /// Times iOS ended the app in the background, by reason ("task timeout", "cpu limit",
        /// "watchdog", "memory limit"); only reasons that happened.
        public var backgroundExits: [String: Int] = [:]

        public init(begin: Date, end: Date) {
            self.begin = begin
            self.end = end
        }
    }

    /// One bucket of the hang histogram: hangs up to `upTo` seconds long, and how many.
    public struct HangBucket: Codable, Sendable, Equatable {
        public var upTo: Double
        public var count: Int
        public init(upTo: Double, count: Int) { self.upTo = upTo; self.count = count }
    }

    /// One `MXDiagnosticPayload`: the durations of its hangs and CPU exceptions, the number of
    /// crashes. No call stacks.
    public struct Diagnostics: Codable, Sendable, Equatable {
        public var begin: Date
        public var end: Date
        public var hangSeconds: [Double]
        /// CPU time of each CPU exception (iOS saw the app use the CPU too much for too long).
        public var cpuExceptionSeconds: [Double]
        public var crashes: Int
        public var diskWriteExceptions: Int

        public init(begin: Date, end: Date, hangSeconds: [Double], cpuExceptionSeconds: [Double], crashes: Int,
                    diskWriteExceptions: Int) {
            self.begin = begin
            self.end = end
            self.hangSeconds = hangSeconds
            self.cpuExceptionSeconds = cpuExceptionSeconds
            self.crashes = crashes
            self.diskWriteExceptions = diskWriteExceptions
        }
    }

    /// Oldest first.
    public private(set) var days: [Day] = []
    public private(set) var diagnostics: [Diagnostics] = []

    public init() {}

    /// A day delivered again (`pastPayloads` at launch), or a second payload of the same day
    /// (iOS can send several), is merged into the one kept: what it says replaces, what it lacks
    /// never wipes a value (second review).
    public mutating func add(_ day: Day) {
        var merged = day
        if let index = days.firstIndex(where: { $0.begin == day.begin }) {
            let kept = days.remove(at: index)
            merged.end = max(day.end, kept.end)
            merged.build = day.build ?? kept.build
            merged.cpuSeconds = day.cpuSeconds ?? kept.cpuSeconds
            merged.gpuSeconds = day.gpuSeconds ?? kept.gpuSeconds
            merged.foregroundSeconds = day.foregroundSeconds ?? kept.foregroundSeconds
            merged.backgroundSeconds = day.backgroundSeconds ?? kept.backgroundSeconds
            merged.hangBuckets = day.hangBuckets ?? kept.hangBuckets
            merged.backgroundExits = kept.backgroundExits.merging(day.backgroundExits) { max($0, $1) }
        }
        days.append(merged)
        days.sort { $0.begin < $1.begin }
        days = Array(days.suffix(Self.kept))
    }

    public mutating func add(_ report: Diagnostics) {
        diagnostics.removeAll { $0.begin == report.begin && $0.end == report.end }
        diagnostics.append(report)
        diagnostics.sort { $0.begin < $1.begin }
        diagnostics = Array(diagnostics.suffix(Self.kept))
    }

    /// Lines for the diagnostic report, in English like the rest of it.
    public var reportLines: [String] {
        var lines: [String] = []
        if let last = days.last, let first = days.first {
            let builds = days.compactMap(\.build).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            var exits: [String: Int] = [:]
            for day in days { exits.merge(day.backgroundExits) { $0 + $1 } }
            let exitText = exits.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            lines.append("metrickit \(days.count) days \(Self.date(first.begin)) – \(Self.date(last.end)), build \(builds.isEmpty ? "?" : builds.joined(separator: ", ")): "
                + "cpu \(Self.minutes(Self.sum(days.map(\.cpuSeconds)))), gpu \(Self.minutes(Self.sum(days.map(\.gpuSeconds)))), "
                + "on screen \(Self.hours(Self.sum(days.map(\.foregroundSeconds)))), background \(Self.hours(Self.sum(days.map(\.backgroundSeconds)))), "
                + "hangs \(Self.hangs(days)), "
                + "background exits \(exitText.isEmpty ? "none" : exitText.joined(separator: ", ")); "
                + "last day cpu \(Self.minutes(last.cpuSeconds)), gpu \(Self.minutes(last.gpuSeconds)), hangs \(last.hangCount.map(String.init) ?? "-")")
        }
        if !diagnostics.isEmpty {
            let hangs = diagnostics.flatMap(\.hangSeconds)
            let cpu = diagnostics.flatMap(\.cpuExceptionSeconds)
            var line = "metrickit diagnostics \(diagnostics.count) reports: hangs \(hangs.count)"
            if let longest = hangs.max() {
                line += " (longest \(Self.oneDecimal(longest)) s, together \(Self.oneDecimal(hangs.reduce(0, +))) s)"
            }
            line += ", cpu exceptions \(cpu.count)"
            if !cpu.isEmpty { line += " (\(Self.minutes(cpu.reduce(0, +))) cpu)" }
            line += ", crashes \(diagnostics.map(\.crashes).reduce(0, +)), disk write exceptions \(diagnostics.map(\.diskWriteExceptions).reduce(0, +))"
            lines.append(line)
        }
        return lines.isEmpty ? ["metrickit no data yet (iOS sends it at most once a day)"] : lines
    }

    /// "5 (longest up to 2.0 s)"; "-" when no day said.
    private static func hangs(_ days: [Day]) -> String {
        let counts = days.compactMap(\.hangCount)
        guard !counts.isEmpty else { return "-" }
        let total = counts.reduce(0, +)
        guard let longest = days.compactMap(\.longestHang).max(), total > 0 else { return "\(total)" }
        return "\(total) (longest up to \(oneDecimal(longest)) s)"
    }

    /// The sum of the values given; `nil` when none was given.
    private static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func minutes(_ seconds: Double?) -> String { seconds.map { "\(oneDecimal($0 / 60)) min" } ?? "-" }
    private static func hours(_ seconds: Double?) -> String { seconds.map { "\(oneDecimal($0 / 3_600)) h" } ?? "-" }

    private static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
