import Foundation

/// A time limit measured on the wall clock of the test machine (ContinuousClock), not on a
/// simulated clock. Such a limit says something about speed only on a machine that is not
/// overloaded; the shared CI Macs (3 cores, load 200-850) broke limits of 300 ms to 10 s
/// without any change to the code (main CI 45722816550, nightly 45376001346, 45138547459).
///
/// Rule (coordinator for Fuchs, 26.11.): in runs on a pull request (`ALBUMIST_TIMING=report`,
/// set by the workflows for `pull_request` only) an exceeded limit is reported, not failed:
/// one line `TIMING_OVER <what>: <measured> over <limit> at <file>:<line>`, which the
/// workflow counts and shows as a warning, each a finding of its own. Everywhere else (the
/// merge gate run by hand, main, the nightly run, TestFlight, Xcode) the limit fails the test
/// as before. Without the variable the limit is hard, so a missing setting can only make a
/// run stricter.
///
/// Limits on a simulated clock (FakeClock, SimClock, the pipeline's `time`) never use this:
/// they test the app's own promises, independent of the machine.
public enum TimingLimit {
    /// True only when the workflow asked for report-only limits.
    public static var reportsOnly: Bool { reportsOnly(in: ProcessInfo.processInfo.environment) }

    public static func reportsOnly(in environment: [String: String]) -> Bool {
        environment["ALBUMIST_TIMING"] == "report"
    }

    /// Whether `measured` is under `limit` (or at most `limit` with `orEqual`). In report
    /// mode an exceeded limit prints its TIMING_OVER line and still answers true, so
    /// `#expect(TimingLimit.holds(...))` fails only where the limit is hard.
    public static func holds(_ measured: Duration, under limit: Duration, orEqual: Bool = false, _ what: String,
                             file: String = #fileID, line: Int = #line) -> Bool {
        holds(measured, under: limit, orEqual: orEqual, what, reporting: reportsOnly, file: file, line: line) { print($0) }
    }

    /// The same with the mode and the output handed in (tests of this type).
    public static func holds(_ measured: Duration, under limit: Duration, orEqual: Bool = false, _ what: String,
                             reporting: Bool, file: String = #fileID, line: Int = #line,
                             report: (String) -> Void) -> Bool {
        let within = orEqual ? measured <= limit : measured < limit
        if within { return true }
        guard reporting else { return false }
        report("TIMING_OVER \(what): \(measured) over \(limit) at \(file):\(line)")
        return true
    }
}
