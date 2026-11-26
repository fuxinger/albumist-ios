import Testing
import AlbumistTestSupport

/// Wall-clock limits are hard unless a pull-request run asks for report-only (rule of 26.11.).
@Suite("Timing limits on the wall clock")
struct TimingLimitTests {
    @Test func underTheLimitHoldsInBothModes() {
        var lines: [String] = []
        #expect(TimingLimit.holds(.milliseconds(10), under: .seconds(1), "x", reporting: false) { lines.append($0) })
        #expect(TimingLimit.holds(.milliseconds(10), under: .seconds(1), "x", reporting: true) { lines.append($0) })
        #expect(lines.isEmpty)
    }

    @Test func overTheLimitFailsWhenHard() {
        var lines: [String] = []
        #expect(!TimingLimit.holds(.seconds(2), under: .seconds(1), "Pause", reporting: false, file: "M/F.swift", line: 7) { lines.append($0) })
        #expect(lines == ["TIMING_LIMIT_FAILED Pause: 2.0 seconds over 1.0 seconds at M/F.swift:7"])
    }

    @Test func overTheLimitIsReportedOnceWhenReportOnly() {
        var lines: [String] = []
        #expect(TimingLimit.holds(.seconds(2), under: .seconds(1), "Pause", reporting: true, file: "M/F.swift", line: 7) { lines.append($0) })
        #expect(lines == ["TIMING_OVER Pause: 2.0 seconds over 1.0 seconds at M/F.swift:7"])
    }

    @Test func equalCountsOnlyWithOrEqual() {
        #expect(!TimingLimit.holds(.seconds(1), under: .seconds(1), "x", reporting: false) { _ in })
        #expect(TimingLimit.holds(.seconds(1), under: .seconds(1), orEqual: true, "x", reporting: false) { _ in })
    }

    @Test func onlyTheExactValueReportSwitchesToReportOnly() {
        #expect(!TimingLimit.reportsOnly(in: [:]))
        #expect(!TimingLimit.reportsOnly(in: ["ALBUMIST_TIMING": "hard"]))
        #expect(!TimingLimit.reportsOnly(in: ["ALBUMIST_TIMING": "Report"]))
        #expect(TimingLimit.reportsOnly(in: ["ALBUMIST_TIMING": "report"]))
    }
}
