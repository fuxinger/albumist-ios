import Foundation

// The words of `MapMeasurements`: the live values of the HUD and its German lines, the English
// lines of the diagnostic report and the German results on the page, with their numbers.

extension MapMeasurements {
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
            "\(name) gpu median \(english(result.gpu.medianMs, decimals: 1)) ms, p95 \(english(result.gpu.p95Ms, decimals: 1)) ms "
                + "of \(result.gpu.samples) frames; "
                + "thermal \(result.thermalStart.rawValue) to \(result.thermalEnd.rawValue); battery \(english(result.batteryStartPercent, decimals: 0)) "
                + "to \(english(result.batteryEndPercent, decimals: 0)) % (\(english(result.batteryPerMinute, decimals: 1)) per minute, "
                + "charging \(result.charging)); memory \(english(result.memoryStartMB, decimals: 0)) MB, peak \(english(result.memoryPeakMB, decimals: 0)) MB",
        ]
        if let network = result.network {
            lines.append("\(name) data: wifi \(english(network.wifiMB, decimals: 1)) MB, "
                + "cellular \(english(network.cellularMB, decimals: 1)) MB (whole iPhone)")
        }
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
            "GPU \(german(live.gpu.medianMs, decimals: 1, unit: " ms")) · Hitze \(live.thermal.germanName) "
                + "· Speicher \(german(live.memoryMB, decimals: 0, unit: " MB")) "
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
        if let network = result.network {
            parts.append("Netz \(german(network.wifiMB, decimals: 1, unit: " MB")) WLAN, \(german(network.cellularMB, decimals: 1, unit: " MB")) mobil")
        }
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
