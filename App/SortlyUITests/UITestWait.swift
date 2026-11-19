import XCTest

/// Waits for a state instead of a fixed sleep (review P5-05). A fixed sleep that stands in for
/// a state the app has to reach turns red on a starved Mac: device test06 waited a fixed 4 s
/// for the background and failed (UI run 44480215847). Each wait here has a deadline at least as
/// long as the sleep it replaced. When the deadline runs out it prints `UI_STEP_MISSING` and
/// fails the test, never a silent pass. The time it took is printed as `UI_TIMING wait`, so a
/// starved Mac shows in the log. The rule `SleepRuleTests` (test_ui_tests.py) keeps the number
/// of fixed sleeps going down.
@MainActor
enum UITestWait {
    /// `element` exists within `timeout` seconds.
    @discardableResult
    static func appears(_ element: XCUIElement, _ what: String, timeout: TimeInterval,
                        file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let start = Date()
        let shown = element.waitForExistence(timeout: timeout)
        report(shown, what, since: start, timeout: timeout, file: file, line: line)
        return shown
    }

    /// `element` is gone within `timeout` seconds.
    @discardableResult
    static func disappears(_ element: XCUIElement, _ what: String, timeout: TimeInterval,
                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let start = Date()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        let done = XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
        report(done, what, since: start, timeout: timeout, file: file, line: line)
        return done
    }

    /// `condition` holds within `timeout` seconds (checked every half second).
    @discardableResult
    static func until(_ what: String, timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
        let start = Date()
        var met = condition()
        while !met, Date().timeIntervalSince(start) < timeout {
            usleep(500_000)
            met = condition()
        }
        report(met, what, since: start, timeout: timeout, file: file, line: line)
        return met
    }

    /// Presses Home and waits until iOS has the app in the background (or ended it), then until
    /// at least `atLeast` seconds have passed since the press, at least 1 s after the state was
    /// reached. A fixed sleep after Home brought the app back before it was ever in the
    /// background on a slow Mac (device test06, UI run 44480215847; d8f863f).
    @discardableResult
    static func toBackground(_ app: XCUIApplication, _ why: String, atLeast: TimeInterval, timeout: TimeInterval = 30,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let pressed = Date()
        XCUIDevice.shared.press(.home)
        UITestOnboarding.clock("wait start app in the background \(why)")
        var reached = false
        while Date().timeIntervalSince(pressed) < timeout {
            let state = app.state
            if state == .runningBackground || state == .runningBackgroundSuspended || state == .notRunning {
                reached = true
                break
            }
            usleep(250_000)
        }
        let took = Date().timeIntervalSince(pressed)
        print("UI_FACT app in the background \(why): state \(app.state.rawValue) after \(String(format: "%.1f", took)) s")
        report(reached, "app in the background \(why)", since: pressed, timeout: timeout, file: file, line: line)
        let wait = max(atLeast - took, reached ? 1 : 0)
        // pacing: the minimum time in the background, counted after iOS reported it
        if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
        return reached
    }

    /// `condition` never holds for `seconds` (checked every half second): the check that
    /// something does not happen watches as long as the fixed sleep before it did (second review
    /// of C2: a check right after a state was reached saw nothing yet).
    @discardableResult
    static func never(_ what: String, for seconds: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
        let start = Date()
        var seen = condition()
        while !seen, Date().timeIntervalSince(start) < seconds {
            usleep(500_000)
            seen = condition()
        }
        let took = String(format: "%.1f", Date().timeIntervalSince(start))
        if seen {
            print("UI_STEP_MISSING \(what) (it happened after \(took) s)")
            XCTFail("Within \(Int(seconds)) s: \(what) did not hold", file: file, line: line)
        } else {
            print("UI_STEP_OK \(what) (watched \(took) s)")
        }
        return !seen
    }

    /// Waits until `seconds` have passed since `start`: the old fixed time stays the minimum
    /// after the state a wait reached (second review of C2: the screen was there, its content
    /// or the next check needed the rest of the old time).
    static func atLeast(_ seconds: TimeInterval, since start: Date) {
        let rest = seconds - Date().timeIntervalSince(start)
        // pacing: the rest of the old fixed time, after the state was reached
        if rest > 0 { usleep(UInt32(rest * 1_000_000)) }
    }

    private static func report(_ met: Bool, _ what: String, since start: Date, timeout: TimeInterval,
                               file: StaticString, line: UInt) {
        print("UI_TIMING wait \(what) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        if met {
            print("UI_STEP_OK \(what)")
        } else {
            print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
            XCTFail("Not within \(Int(timeout)) s: \(what)", file: file, line: line)
        }
    }
}
