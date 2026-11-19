import XCTest

/// Ends the app of the last launch before the next one (or where a test closes it on purpose),
/// and logs how long that took and which way. Left to `launch()` or `terminate()`, XCTest ends
/// it on its own: on a busy CI Mac that failed with "Failed to terminate app.albumist.ios:…"
/// although the app stood idle (device test07, UI run 44446270757; accessibility test2 in
/// TestFlight run 44461253154, job 135366070532, at its relaunch in English). XCTest's
/// `terminate()` goes through the same call with its own time limit, so it can fail the same way.
///
/// With the CI helper (`SORTLY_HOST_HELPER=1`, handed over by ui_tests.py as
/// TEST_RUNNER_SORTLY_HOST_HELPER) the test asks the Mac instead: it prints
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
/// `DeviceConditionUITests.endRunningApp`).
@MainActor
enum UITestAppEnd {
    /// `when`: what the log lines say ("before the next launch", "during the plan").
    static func end(_ app: XCUIApplication, _ when: String = "before the next launch") {
        guard app.state != .notRunning else { return }
        let asked = Date()
        UITestOnboarding.clock("end the app \(when)")
        var way = "XCTest"
        if ProcessInfo.processInfo.environment["SORTLY_HOST_HELPER"] == "1" {
            // With the app's process id the Mac ends exactly that process: ended by bundle id,
            // an app that ended by itself just after the request (iOS ends it when the photo
            // access is taken away) let the test launch it again, and the Mac's late end hit
            // that new launch (test09, PR #9 UI run 44464687545).
            let pid = processID(of: app)
            print("UI_HOST_TERMINATE_APP \(Int(asked.timeIntervalSince1970))" + (pid.map { " \($0)" } ?? ""))
            if app.wait(for: .notRunning, timeout: 60) {
                print("UI_TIMING app ended \(when) \(Int(Date().timeIntervalSince(asked))) s (by the Mac, ended)")
                return
            }
            print("UI_FACT app still running \(Int(Date().timeIntervalSince(asked))) s after asking the Mac to end it: XCTest ends it")
            way = "by XCTest after the Mac"
        }
        app.terminate()
        let gone = app.wait(for: .notRunning, timeout: 60)
        print("UI_TIMING app ended \(when) \(Int(Date().timeIntervalSince(asked))) s (\(way), \(gone ? "ended" : "still running"))")
    }

    /// The process id the app of this launch wrote first thing ("@ <pid> <start> <now>") into
    /// the file of `-SortlyUITestWatchMainLog` (`UITestStalls`); nil without the file or before
    /// the app got that far.
    static func processID(of app: XCUIApplication) -> Int32? {
        let arguments = app.launchArguments
        guard let flag = arguments.firstIndex(of: "-SortlyUITestWatchMainLog"), flag + 1 < arguments.count,
              let text = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").last { $0.hasPrefix("@ ") }
        let parts = line?.split(separator: " ") ?? []
        return parts.count >= 2 ? Int32(parts[1]) : nil
    }
}
