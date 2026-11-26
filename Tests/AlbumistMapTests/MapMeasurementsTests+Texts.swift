import Foundation
import Testing
@testable import AlbumistMap

/// The texts of the measurements: the diagnostic report holds counts and times only and orders the
/// views, a note that may hold a coordinate stays on the device, the HUD and the test result speak
/// German, numbers are written for each language, and the names of views and events are the app's.
extension MapMeasurementsTests {
    // MARK: Texts

    @Test func theReportHoldsCountsAndTimesOnly() {
        let lines = Metrics.lines(results: [Self.result(notes: ["texture": "5400x2700, 78 MB", "center": "64.1466, -21.9426"])], altitude: Self.altitude)
        #expect(lines == [
            "map prototype: tests 1, altitude check yes",
            "map prototype own globe test: 60 s of 60 s, complete true, started 2026-11-21T09:00:00Z",
            "map prototype own globe frames 64 in 1.0 s, runs 1, median 64 fps, average 63.0 fps, frame ms p50 15.6, p95 15.6, p99 21.6, "
                + "longest 31.3, hitches 1, 15.6 ms/s",
            "map prototype own globe gpu median 4.0 ms, p95 4.9 ms of 3 frames; thermal nominal to fair; battery 81 to 80 % (1.0 per minute, "
                + "charging false); memory 180 MB, peak 215 MB",
            "map prototype own globe events: first frame 1, median 412 ms, max 412 ms; tile failure 2",
            "map prototype own globe notes: texture 5400x2700, 78 MB",
            "map prototype altitude 2026-11-21T10:00:00Z: photos 6, with location 5, with altitude 3, with vertical accuracy 3, "
                + "median vertical accuracy 12 m, within 30 m 2",
        ])
        // No coordinate-like number (two or more decimals) anywhere.
        let text = lines.joined(separator: "\n")
        #expect(text.range(of: #"\d[.,]\d\d"#, options: .regularExpression) == nil)
        #expect(!text.contains("64.14") && !text.contains("21.94"))
    }

    @Test func theReportIsEmptyWithoutMeasurementsAndOrdersTheViews() {
        #expect(Metrics.lines(results: [], altitude: nil).isEmpty)
        #expect(Metrics.lines(results: [], altitude: Self.altitude).count == 2)
        var playback = Self.result(notes: [:])
        playback.source = .playback
        playback.events = []
        var apple = Self.result(notes: [:])
        apple.source = .appleGlobe
        let lines = Metrics.lines(results: [playback, apple], altitude: nil)
        #expect(lines.first == "map prototype: tests 2, altitude check no")
        let order = lines.dropFirst().compactMap { line in Metrics.Source.allCases.first { line.hasPrefix("map prototype \($0.reportName) ") } }
        #expect(order.first == .appleGlobe && order.last == .playback)
        // Unknown values are "?", as elsewhere in the report.
        let empty = Metrics.TestResult(source: .handoverMap, startedAt: Self.started, plannedSeconds: 60, durationSeconds: 12, frameRuns: [], gpuSeconds: [],
                                       thermalStart: .serious, thermalEnd: .critical, batteryStartPercent: nil, batteryEndPercent: nil, charging: false,
                                       memoryStartMB: nil, memoryPeakMB: nil, events: [], notes: [:])
        #expect(Metrics.lines(results: [empty], altitude: nil).dropFirst() == [
            "map prototype handover map test: 12 s of 60 s, complete false, started 2026-11-21T09:00:00Z",
            "map prototype handover map frames 0 in 0.0 s, runs 0, median ? fps, average ? fps, frame ms p50 ?, p95 ?, p99 ?, longest ?, hitches 0, ? ms/s",
            "map prototype handover map gpu median ? ms, p95 ? ms of 0 frames; thermal serious to critical; battery ? to ? % (? per minute, "
                + "charging false); memory ? MB, peak ? MB",
        ])
    }

    @Test func aNoteThatMayHoldACoordinateStaysOnTheDevice() {
        #expect(Metrics.reportNote("texture 5400x2700, 78 MB") == "texture 5400x2700, 78 MB")
        #expect(Metrics.reportNote("center 64.1466 -21.9426") == nil)
        #expect(Metrics.reportNote("center 64,1466") == nil)
        #expect(Metrics.reportNote("first line\nsecond line") == "first line second line")
        #expect(Metrics.reportNote("   ") == nil)
        #expect(Metrics.reportNote(String(repeating: "x", count: 200))?.count == Metrics.maximumNoteLength)
    }

    @Test func theHUDSpeaksGerman() {
        let still = Metrics.Live(source: .playback, framesLastSecond: 0, recent: Metrics.FrameStats(), gpu: Metrics.TimeStats(seconds: []), thermal: .serious,
                                 memoryMB: nil,
                                 events: [Metrics.EventStats(event: .firstFrame, durations: [0.4123]),
                                          Metrics.EventStats(event: .pauseLatency, durations: [0.5, 0.25]),
                                          Metrics.EventStats(event: .tileWait, durations: [0.5, 1.0, 1.5]),
                                          Metrics.EventStats(event: .tileTimeout, durations: [0]),
                                          Metrics.EventStats(event: .tileFailure, durations: [0, 0])],
                                 notes: ["tiles": "satellite 3D"], totalFrames: 12_345, summaryMilliseconds: 1_234)
        #expect(Metrics.hudLines(still) == [
            "Reise abspielen: steht still · p95 – · Hänger –",
            "GPU – · Hitze ernst · Speicher – · 12.345 Bilder",
            "Erstes Bild 0,41 s · Pause 0,25 s",
            "Kacheln gewartet 3× (Median 1,00 s) · Bilderfolge-Tage 1 · Ladefehler 2",
            "Zusammenfassung deiner Reisen: 1.234 ms",
            "tiles: satellite 3D",
        ])
        let turning = Metrics.Live(source: .ownGlobe, framesLastSecond: 120, recent: Metrics.FrameStats(runs: [Self.steadyRun]),
                                   gpu: Metrics.TimeStats(seconds: [0.003]), thermal: .nominal, memoryMB: 182.4, events: [], notes: [:],
                                   totalFrames: 129, summaryMilliseconds: nil)
        #expect(Metrics.hudLines(turning) == [
            "Unser Globus: 120 fps · p95 7,8 ms · Hänger 0,0 ms/s",
            "GPU 3,0 ms · Hitze normal · Speicher 182 MB · 129 Bilder",
        ])
        #expect(turning.stats(.firstFrame) == nil && still.stats(.tileWait)?.count == 3)
    }

    @Test func theTestResultInGerman() {
        #expect(Metrics.summary(Self.result()) == "Unser Globus, 60-s-Test: Median 64 fps, p95 15,6 ms · Hänger 15,6 ms/s (zu hoch) · GPU 4,0 ms "
            + "· Hitze normal → erhöht · Akku 81 → 80 % (1,0 %/min) · Speicher 180 → 215 MB")
        var short = Self.result(duration: 23)
        short.charging = true
        short.gpu = Metrics.TimeStats(seconds: [])
        #expect(Metrics.summary(short) == "Unser Globus, 60-s-Test: nach 23 s beendet · Median 64 fps, p95 15,6 ms · Hänger 15,6 ms/s (zu hoch) "
            + "· Hitze normal → erhöht · Akku 81 → 80 % (2,6 %/min), am Strom · Speicher 180 → 215 MB")
        #expect(Metrics.summary(Self.altitude) == "Höhen: 6 neueste Fotos, 5 mit Ort, 3 mit Höhe, 3 mit Höhengenauigkeit (Median 12 m), 2 auf 30 m genau.")
        #expect(Metrics.summary(Metrics.AltitudeCheck(samples: [], checkedAt: Self.checked)) == "Höhen: keine Fotos gefunden.")
    }

    @Test func numbersAreWrittenForEachLanguage() {
        #expect(Metrics.german(1_234.56, decimals: 1, unit: " ms") == "1.234,6 ms")
        #expect(Metrics.german(1_234_567, decimals: 0, unit: "") == "1.234.567")
        #expect(Metrics.german(-0.04, decimals: 1, unit: "") == "0,0")
        #expect(Metrics.german(-2.5, decimals: 1, unit: " %") == "−2,5 %")
        #expect(Metrics.german(nil, decimals: 1, unit: " ms") == "–" && Metrics.german(.nan, decimals: 0, unit: "") == "–")
        #expect(Metrics.german(.infinity, decimals: 0, unit: "") == "–")
        #expect(Metrics.germanInteger(7_187) == "7.187" && Metrics.germanInteger(0) == "0" && Metrics.germanInteger(999) == "999")
        #expect(Metrics.germanInteger(-1_234_567) == "−1.234.567")
        #expect(Metrics.english(8.333, decimals: 1) == "8.3" && Metrics.english(-0.04, decimals: 1) == "0.0" && Metrics.english(2.5, decimals: 0) == "3")
        #expect(Metrics.english(nil, decimals: 1) == "?" && Metrics.english(.nan, decimals: 1, unit: " ms") == "?")
        #expect(Metrics.english(12, decimals: 0, unit: " m") == "12 m")
    }

    /// The app's `MetricSource` and `MetricEvent` map onto these by their raw values (the
    /// interface of the prototype's helpers, docs of the map prototype): a renamed case would
    /// lose its measurements.
    @Test func theNamesOfViewsAndEventsAreTheAppsOwn() {
        #expect(Metrics.Source.allCases.map(\.rawValue) == ["ownGlobe", "appleGlobe", "handoverMap", "playback"])
        #expect(Metrics.Event.allCases.map(\.rawValue) == ["firstFrame", "shaderCompile", "textureLoad", "maskBuild", "handover", "backToGlobe",
                                                          "pauseLatency", "dayJump", "tileWait", "tileTimeout", "tileFailure", "memoryWarning"])
        #expect(Metrics.Event.allCases.filter(\.countsOnly) == [.tileTimeout, .tileFailure, .memoryWarning])
        #expect(Set(Metrics.Source.allCases.map(\.reportName)).count == 4 && Set(Metrics.Event.allCases.map(\.reportName)).count == 12)
        #expect(Set(Metrics.Source.allCases.map(\.germanName)).count == 4 && Set(Metrics.Event.allCases.map(\.germanName)).count == 12)
    }
}
