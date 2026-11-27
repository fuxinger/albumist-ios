import XCTest

/// Ends the app of the last launch before the next one (or where a test closes it on purpose),
/// and logs how long that took and which way. Left to `launch()` or `terminate()`, XCTest ends
/// it on its own: on a busy CI Mac that failed with "Failed to terminate app.albumist.ios:…"
/// although the app stood idle (device test07, UI run 44446270757; accessibility test2 in
/// TestFlight run 44461253154, job 135366070532, at its relaunch in English). XCTest's
/// `terminate()` goes through the same call with its own time limit, so it can fail the same way.
///
/// With the CI helper (`ALBUMIST_HOST_HELPER=1`, handed over by ui_tests.py as
/// TEST_RUNNER_ALBUMIST_HOST_HELPER) the test asks the Mac instead: it prints
/// `UI_HOST_TERMINATE_APP <epoch second> [<pid>]`, ui_tests.py (HostGrants) ends exactly that
/// process (SIGTERM, then SIGKILL; `simctl terminate` hung 20 s in test06 of the same run) or,
/// without an id, runs `simctl terminate`,
/// and the test only reads the app's state until it is gone, up to 60 s. Reading the state
/// goes to XCTest's daemon, not into the app, so nothing is in flight that the end could
/// break ("Lost connection to the application" comes from a query or tap into an app that
/// went away; the caller gives the old `app` no query after this). simctl ends the app the way
/// the system does, which leaves no crash report, so XCTest has no crash to record either.
/// Only if the app is still there after the wait does XCTest end it. Without the helper (a run
/// in Xcode) XCTest ends it as before. Every UI test file uses this (shared since 19.11.; it was
/// `DeviceConditionUITests.endRunningApp`), and every launch goes through `launch` below.
@MainActor
enum UITestAppEnd {
    /// Every launch of the app goes through here (rule test in .github/scripts/tests/
    /// test_ui_tests.py): ends the app of the last launch first (`end`; without this a launch
    /// left that to XCTest, as `AlbumistLockedUITests.prepareLibrary` did), makes the app write its
    /// process id (adds `-AlbumistUITestWatchMainLog` when the arguments name no file) and notes the
    /// launch (`UITestLaunchRecord`). So the next `end` names the process to the Mac also when it
    /// is given a new `XCUIApplication` without arguments: the first launch of every test ended
    /// the app of the test before that way, with `simctl terminate` by bundle id. Callers do
    /// not end the app themselves before: a second end would wait again for an app still
    /// running. `justBefore`: runs after the end, right before the launch (the device tests'
    /// "UI_FACT clock … launch", which `ui_tests.py` compares with the process start).
    static func launch(_ app: XCUIApplication, justBefore: () -> Void = {}) {
        end(app)
        if let took = lastEnd, took >= slowEnd { settleAfterSlowEnd(took) }
        app.launchArguments += UITestStalls.arguments(besides: app.launchArguments)
        mainThreadChecker(app)
        UITestLaunchRecord.shared.launching(app.launchArguments)
        justBefore()
        app.launch()
    }

    /// Xcode's Main Thread Checker in the app (owner's decision 16.11.2026): `ui_tests.py` finds
    /// the simulator's copy of the library on the Mac and hands its path over as
    /// TEST_RUNNER_ALBUMIST_MTC_DYLIB (with ALBUMIST_MTC_PROBE=1 for the app's deliberate report,
    /// `MainThreadCheckerProbe`). Its reports go to the app's console file, which `ui_tests.py`
    /// reads after the pass. Without the variable (a run in Xcode, which inserts the checker
    /// itself) nothing changes.
    static func mainThreadChecker(_ app: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        guard let dylib = environment["ALBUMIST_MTC_DYLIB"], !dylib.isEmpty else { return }
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = dylib
        // Report and go on (no stop at a report): the test keeps running and every report counts.
        app.launchEnvironment["MTC_CRASH_ON_REPORT"] = "0"
        if environment["ALBUMIST_MTC_PROBE"] == "1" { app.launchEnvironment["ALBUMIST_MTC_PROBE"] = "1" }
    }

    /// Seconds the last `end` took from the request until the app was gone; nil when there was
    /// nothing to end.
    private(set) static var lastEnd: TimeInterval?
    /// An end this slow means the Mac is starved right now (Z4, 27.11.): in each of the four
    /// launches XCTest lost although the app came up ("does not have a process ID" 3-4 min later;
    /// device test02 in jobs 140195305412 and 140208691916, test07 in job 139048797216), the end
    /// before took 11-21 s; of 115 other ends only 4 took 8 s or more (median 1.8 s).
    static let slowEnd: TimeInterval = 8

    /// After a slow end: the Mac waits until the simulator answers quickly again, up to 60 s
    /// (UI_HOST_SETTLE, `settle` in ui_tests.py), and answers into a file; then the launch goes
    /// on, settled or not. Without the CI helper (a run in Xcode) nothing changes.
    static func settleAfterSlowEnd(_ took: TimeInterval) {
        let answer = NSTemporaryDirectory() + "uitest-host-answer-\(UUID().uuidString)"
        guard ProcessInfo.processInfo.environment["ALBUMIST_HOST_HELPER"] == "1", !answer.contains(where: \.isWhitespace) else { return }
        defer { try? FileManager.default.removeItem(atPath: answer) }
        let start = Date()
        print("UI_HOST_SETTLE \(answer)")
        // 60 s of the Mac's wait plus its last probe and process list (up to 30 s each) and the
        // 2 s it reads the log: up to about 125 s.
        _ = UITestWait.holds(timeout: 150, interval: 1) { FileManager.default.fileExists(atPath: answer) }
        let reply = (try? String(contentsOfFile: answer, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        print("UI_TIMING simulator settle after an end of \(Int(took)) s: \(Int(Date().timeIntervalSince(start))) s, "
              + "the Mac answered '\(reply ?? "nothing")'")
    }

    /// `when`: what the log lines say ("before the next launch", "during the plan").
    static func end(_ app: XCUIApplication, _ when: String = "before the next launch") {
        lastEnd = nil
        guard app.state != .notRunning else { return }
        let asked = Date()
        defer { lastEnd = Date().timeIntervalSince(asked) }
        UITestOnboarding.clock("end the app \(when)")
        var way = "XCTest"
        if ProcessInfo.processInfo.environment["ALBUMIST_HOST_HELPER"] == "1" {
            // With the app's process id the Mac ends exactly that process: ended by bundle id,
            // an app that ended by itself just after the request (iOS ends it when the photo
            // access is taken away) let the test launch it again, and the Mac's late end hit
            // that new launch (test09, PR #9 UI run 44464687545).
            let pid = processID(of: app)
            // The Mac answers "ended" or "not ended" into this file once its end is done
            // (`HostGrants` in ui_tests.py); a path with a space could not be named in the line.
            let answer = NSTemporaryDirectory() + "uitest-host-answer-\(UUID().uuidString)"
            let answered = !answer.contains(where: \.isWhitespace)
            defer { try? FileManager.default.removeItem(atPath: answer) }
            print("UI_HOST_TERMINATE_APP \(Int(asked.timeIntervalSince1970))" + (pid.map { " \($0)" } ?? "")
                  + (answered ? " \(answer)" : ""))
            switch waitForEnd(app, answer: answered ? answer : nil) {
            case .gone:
                print("UI_TIMING app ended \(when) \(Int(Date().timeIntervalSince(asked))) s (by the Mac, ended)")
                return
            case .staleAfterMacEnd:
                let since = Int(Date().timeIntervalSince(asked))
                print("UI_FACT the Mac ended the app, XCTest still reads it running \(since) s after the request: XCTest ends it")
                way = "by XCTest after the Mac ended it"
            case .running:
                print("UI_FACT app still running \(Int(Date().timeIntervalSince(asked))) s after asking the Mac to end it: XCTest ends it")
                way = "by XCTest after the Mac"
            }
        }
        app.terminate()
        let gone = app.wait(for: .notRunning, timeout: 60)
        print("UI_TIMING app ended \(when) \(Int(Date().timeIntervalSince(asked))) s (\(way), \(gone ? "ended" : "still running"))")
    }

    /// How long the test waits for the Mac's end (TERMINATE_WAIT in ui_tests.py).
    static let macEndWait: TimeInterval = 60
    /// XCTest's time to see the app gone after the Mac answered "ended".
    static let staleStateWait: TimeInterval = 5

    /// What `waitForEnd` saw.
    enum MacEnd {
        /// XCTest reads the app as not running.
        case gone
        /// The Mac answered that the process is gone, and XCTest still read it as running
        /// `staleStateWait` s later.
        case staleAfterMacEnd
        /// Still running after `macEndWait` s, and the Mac did not say it ended it.
        case running
    }

    /// Waits up to `macEndWait` s until XCTest reads `app` as not running, as the single wait
    /// before did, and stops early when the Mac answered "ended" into `answer` and XCTest still
    /// does not see it within `staleStateWait` s: then XCTest ends it at once, as it did after the
    /// whole wait. Device test07 in the full UI run 45865545486 (job 140074115643): the Mac ended
    /// the app 12 s after the request ("ended by SIGTERM (10 s)"), XCTest read it as running for
    /// 60 s and its own terminate then took 17 s (77 s for the end).
    private static func waitForEnd(_ app: XCUIApplication, answer: String?) -> MacEnd {
        let start = Date()
        while true {
            let left = macEndWait - Date().timeIntervalSince(start)
            guard left > 0 else { return .running }
            // Short slices of the same wait, so the answer is read in between.
            if app.wait(for: .notRunning, timeout: min(2, left)) { return .gone }
            guard let answer, let text = try? String(contentsOfFile: answer, encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines) == "ended" else { continue }
            return app.wait(for: .notRunning, timeout: staleStateWait) ? .gone : .staleAfterMacEnd
        }
    }

    /// The process id the app of the last launch wrote first thing ("@ <pid> <start> <now>")
    /// into the file of `-AlbumistUITestWatchMainLog` (`UITestStalls`), whichever `XCUIApplication`
    /// is ended (`UITestLaunchRecord`); nil before the app got that far. Without a launch known
    /// to this test runner (a new runner after a crash), the file of `app`'s arguments or the
    /// default one.
    static func processID(of app: XCUIApplication) -> Int32? {
        let fallback = UITestLaunchRecord.watchFile(in: app.launchArguments) ?? UITestStalls.path
        return UITestLaunchRecord.shared.processID(fallback: fallback) { try? String(contentsOfFile: $0, encoding: .utf8) }
    }
}
