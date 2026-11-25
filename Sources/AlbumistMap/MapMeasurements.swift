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
}
