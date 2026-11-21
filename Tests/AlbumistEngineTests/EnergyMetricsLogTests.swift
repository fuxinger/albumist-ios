import Foundation
import Testing
@testable import AlbumistEngine

/// MetricKit for the diagnostic report (owner, 19.11.2026: battery use of the analysis): iOS
/// sends a day's CPU and GPU time and the hangs at most once a day; the app keeps their numbers
/// (`EnergyMetricsLog`) and the report shows them. Only numbers, nothing about the photos.
@Suite("MetricKit numbers for the report")
struct EnergyMetricsLogTests {
    static let day0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func day(_ index: Int, cpu: Double? = 600, gpu: Double? = 30, hangs: Int? = 0,
                    exits: [String: Int] = [:]) -> EnergyMetricsLog.Day {
        var day = EnergyMetricsLog.Day(begin: day0.addingTimeInterval(Double(index) * 86_400),
                                       end: day0.addingTimeInterval(Double(index + 1) * 86_400))
        day.build = "37"
        day.cpuSeconds = cpu
        day.gpuSeconds = gpu
        day.foregroundSeconds = 1_800
        day.backgroundSeconds = 900
        day.hangBuckets = hangs.map { [EnergyMetricsLog.HangBucket(upTo: 1, count: $0)] }
        day.backgroundExits = exits
        return day
    }

    static func diagnostics(_ index: Int, hangs: [Double] = [], cpuExceptions: [Double] = [], crashes: Int = 0)
        -> EnergyMetricsLog.Diagnostics {
        EnergyMetricsLog.Diagnostics(begin: day0.addingTimeInterval(Double(index) * 86_400),
                                     end: day0.addingTimeInterval(Double(index + 1) * 86_400),
                                     hangSeconds: hangs, cpuExceptionSeconds: cpuExceptions, crashes: crashes,
                                     diskWriteExceptions: 0)
    }

    @Test func keepsTheNewestSevenDaysOnceEach() {
        var log = EnergyMetricsLog()
        for index in [3, 1, 2, 0, 4, 5, 6, 7, 8] { log.add(Self.day(index)) }
        // The same day delivered again (`pastPayloads` at launch) is not kept twice.
        log.add(Self.day(8, cpu: 700))
        #expect(log.days.count == 7)
        #expect(log.days.first?.begin == Self.day(2).begin)
        #expect(log.days.last?.begin == Self.day(8).begin)
        #expect(log.days.last?.cpuSeconds == 700)
    }

    /// Second review: iOS can send several payloads for the same day; a field one of them lacks
    /// never wipes what another said.
    @Test func aSecondPayloadOfTheSameDayKeepsWhatTheFirstSaid() {
        var log = EnergyMetricsLog()
        log.add(Self.day(0, cpu: 600, gpu: 30, hangs: 1, exits: ["watchdog": 1]))
        var later = Self.day(0, cpu: 700, gpu: nil, hangs: nil, exits: [:])
        later.build = nil
        later.foregroundSeconds = nil
        log.add(later)
        #expect(log.days.count == 1)
        let day = log.days[0]
        #expect(day.cpuSeconds == 700)
        #expect(day.gpuSeconds == 30)
        #expect(day.hangCount == 1)
        #expect(day.build == "37")
        #expect(day.foregroundSeconds == 1_800)
        #expect(day.backgroundExits == ["watchdog": 1])
    }

    /// Second review: the hang count is the sum of the histogram's counts, not its number of
    /// buckets.
    @Test func hangsAreTheSumOfTheBucketCounts() {
        var day = Self.day(0)
        day.hangBuckets = [.init(upTo: 0.5, count: 3), .init(upTo: 2, count: 2)]
        #expect(day.hangCount == 5)
        var log = EnergyMetricsLog()
        log.add(day)
        #expect(log.reportLines[0].contains("hangs 5 (longest up to 2.0 s)"))
    }

    @Test func keepsTheNewestSevenDiagnosticsOnceEach() {
        var log = EnergyMetricsLog()
        for index in 0..<9 { log.add(Self.diagnostics(index, hangs: [1])) }
        log.add(Self.diagnostics(8, hangs: [1, 2]))
        #expect(log.diagnostics.count == 7)
        #expect(log.diagnostics.last?.hangSeconds == [1, 2])
    }

    @Test func withoutDataTheReportSaysWhy() {
        #expect(EnergyMetricsLog().reportLines == ["metrickit no data yet (iOS sends it at most once a day)"])
    }

    @Test func theReportSumsTheDaysAndNamesTheLastOne() {
        var log = EnergyMetricsLog()
        log.add(Self.day(0, cpu: 600, gpu: 30, hangs: 1))
        log.add(Self.day(1, cpu: 1_200, gpu: nil, hangs: 2, exits: ["task timeout": 1]))
        let lines = log.reportLines
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.hasPrefix("metrickit 2 days 2027-01-15 – 2027-01-17, build 37"))
        #expect(line.contains("cpu 30.0 min"))
        #expect(line.contains("gpu 0.5 min"))
        #expect(line.contains("on screen 1.0 h, background 0.5 h"))
        #expect(line.contains("hangs 3"))
        #expect(line.contains("background exits task timeout 1"))
        #expect(line.contains("last day cpu 20.0 min"))
    }

    @Test func diagnosticsSayHangsWithTheLongestAndCPUExceptions() {
        var log = EnergyMetricsLog()
        log.add(Self.diagnostics(0, hangs: [0.4, 3.42], cpuExceptions: [180]))
        log.add(Self.diagnostics(1, hangs: [1.1], crashes: 1))
        let line = log.reportLines.last ?? ""
        #expect(line == "metrickit diagnostics 2 reports: hangs 3 (longest 3.4 s, together 4.9 s), cpu exceptions 1 (3.0 min cpu), crashes 1, disk write exceptions 0")
    }

    @Test func storedLogReadsBack() throws {
        var log = EnergyMetricsLog()
        log.add(Self.day(0))
        log.add(Self.diagnostics(0, hangs: [2]))
        let data = try JSONEncoder().encode(log)
        #expect(try JSONDecoder().decode(EnergyMetricsLog.self, from: data) == log)
    }
}
