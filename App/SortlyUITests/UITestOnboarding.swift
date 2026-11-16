import XCTest

/// What the later UI tests need from test 1 (SortlyFlowUITests.test1_FullFlow): a finished
/// onboarding, the demo library and its first analysis.
///
/// UI run 43816787321: the test runner ended inside test 1 right after the trial step (no
/// "passed" or "failed" line, "Executed 5 tests" for the six flow tests). xcodebuild started a
/// new runner at test 2 with an app still at its welcome screen, and every later test failed
/// on that one cut-off (13 failures). Each later test now brings the app to that state by
/// itself when test 1 did not reach its end, so a cut-off costs test 1 and nothing else.
/// In CI (ui.yml) test 1 runs in its own group; the other flow tests run on another simulator
/// and always onboard by themselves there.
@MainActor
enum UITestOnboarding {
    /// Start and end markers of a first test in the runner's temporary folder. A static flag
    /// starts fresh in a restarted runner (run 43816787321: test 2 did not notice the
    /// cut-off); a file stays.
    struct Markers: Sendable {
        let started: URL
        let finished: URL

        init(_ name: String) {
            let folder = FileManager.default.temporaryDirectory
            started = folder.appending(path: "albumist-ui-\(name)-started")
            finished = folder.appending(path: "albumist-ui-\(name)-finished")
        }

        func starts() {
            try? FileManager.default.removeItem(at: finished)
            try? Data().write(to: started)
        }

        func ends() {
            try? Data().write(to: finished)
        }

        var reachedItsEnd: Bool {
            FileManager.default.fileExists(atPath: finished.path)
        }
    }

    /// SortlyFlowUITests.test1_FullFlow.
    static let fullFlow = Markers("full-flow")
    /// AccessibilityUITests.test1_OnboardingAtLargestTextInDarkMode (run 43823834271: a UI
    /// query timed out while the demo library was being created, which ended test 1, and
    /// tests 2 to 4 found no suggestions).
    static let accessibilityOnboarding = Markers("a11y-onboarding")

    static func fullFlowStarts() { fullFlow.starts() }
    static func fullFlowFinished() { fullFlow.ends() }
    static var fullFlowReachedItsEnd: Bool { fullFlow.reachedItsEnd }

    /// The overview says the analysis is done and nothing runs (as `analysisIdle` in the tests).
    static func analysisIdle(_ app: XCUIApplication) -> Bool {
        func anything(_ text: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        return (anything("Fotos analysiert") || anything("Analyse aktuell") || anything("Analyse fertig"))
            && !app.buttons["Pause"].exists
    }

    /// Onboarding, demo library and first analysis, when the app still shows its welcome
    /// screen, or only the demo library and its analysis when the app is past the onboarding
    /// but still offers it (as `onboardAndSeed` in AccessibilityUITests). Returns true when it
    /// had to do either.
    ///
    /// UI run 43893790053 (group "flow-other"): the runner ended in test 2 right after it tapped
    /// "Beispiel-Mediathek anlegen"; tests 3 to 7 found the app past its welcome screen and ran
    /// on the simulator's own handful of photos (no suggestions, no albums: 10 failures).
    @discardableResult
    static func completeIfNeeded(_ app: XCUIApplication, in test: String) -> Bool {
        func button(_ text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        guard button("Los geht").waitForExistence(timeout: 10) else {
            let demo = button("Beispiel-Mediathek anlegen")
            guard demo.waitForExistence(timeout: 5) else {
                finishInterruptedAnalysis(app, in: test)
                return false
            }
            print("UI_FACT \(test): past the onboarding without the demo library, creating it first")
            demo.tap()
            XCTAssertTrue(demoLibraryCreated(app), "\(test): demo library not created")
            let idle = waitStable(timeout: 1200) { analysisIdle(app) }
            print(idle ? "UI_STEP_OK \(test) demo library" : "UI_STEP_MISSING \(test) demo library")
            XCTAssertTrue(idle, "\(test): the analysis of the demo library did not finish")
            finishInterruptedAnalysis(app, in: test)
            return true
        }
        print("UI_FACT \(test): the app is at its welcome screen, onboarding first")
        button("Los geht").tap()
        if button("Weiter").waitForExistence(timeout: 10) { button("Weiter").tap() }
        if app.buttons["access.continue"].waitForExistence(timeout: 5) {
            app.buttons["access.continue"].tap()
            allowPhotosIfAsked(app)
        }
        if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
        guard button("Analyse starten").waitForExistence(timeout: 20) else {
            print("UI_STEP_MISSING \(test) onboarding")
            XCTFail("\(test): onboarding did not reach the trial step")
            return true
        }
        button("Analyse starten").tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] where springboard.buttons[label].waitForExistence(timeout: 4) {
            springboard.buttons[label].tap()
            break
        }
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            demo.tap()
            XCTAssertTrue(demoLibraryCreated(app), "\(test): demo library not created")
        }
        let idle = waitStable(timeout: 1200) { analysisIdle(app) }
        print(idle ? "UI_STEP_OK \(test) onboarding and demo library" : "UI_STEP_MISSING \(test) onboarding and demo library")
        XCTAssertTrue(idle, "\(test): the analysis of the demo library did not finish")
        finishInterruptedAnalysis(app, in: test)
        return true
    }

    /// An analysis cut off by a restarted test runner (the app was ended in the middle of it)
    /// does not go on by itself in UI runs, which start no analysis at launch: the card says
    /// "58 von 246 Fotos analysiert" with "Neu prüfen", and `analysisIdle` takes that as done
    /// (run 43918684247: the runner was restarted in accessibility test 1, and tests 2 to 4
    /// found "No suggestions yet"). "Neu prüfen" analyses the rest, as a user would.
    /// German only (every caller launches the app in German).
    static func finishInterruptedAnalysis(_ app: XCUIApplication, in test: String) {
        let partial = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ von [0-9.]+ Fotos analysiert")).firstMatch
        guard partial.waitForExistence(timeout: 3) else { return }
        print("UI_FACT \(test): the analysis was cut off at '\(partial.label)', checking again")
        let again = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Neu prüfen")).firstMatch
        guard again.waitForExistence(timeout: 5) else {
            print("UI_STEP_MISSING \(test) check again after a cut-off analysis")
            XCTFail("\(test): an analysis was cut off and the overview offers no \"Neu prüfen\"")
            return
        }
        // Below other cards the button can sit under the tab bar, where a tap lands on the bar.
        let tabs = app.tabBars.firstMatch
        var swipes = 0
        while swipes < 4, tabs.exists, again.frame.maxY > tabs.frame.minY {
            app.swipeUp()
            swipes += 1
        }
        again.tap()
        let done = waitStable(timeout: 1200) { analysisIdle(app) && !partial.exists }
        print(done ? "UI_STEP_OK \(test) cut-off analysis finished" : "UI_STEP_MISSING \(test) cut-off analysis finished")
        XCTAssertTrue(done, "\(test): the cut-off analysis did not finish after \"Neu prüfen\"")
    }

    private static func allowPhotosIfAsked(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    return
                }
            }
            if app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Analyse starten")).firstMatch.exists { return }
            usleep(500_000)
        }
    }

    /// Waits until the demo card no longer creates photos and no longer offers to.
    ///
    /// Run 43823834271: a query over every element ("label CONTAINS" on `.any`) every 2 s timed
    /// out while the app wrote the photos at the largest text size ("Failed to get matching
    /// snapshots: Timed out while evaluating UI query"), and a failed query ends the test. The
    /// wait asks only for the card's text and button, every 5 s.
    static func demoLibraryCreated(_ app: XCUIApplication, timeout: TimeInterval = 600) -> Bool {
        let seeding = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Beispielfotos werden angelegt")).firstMatch
        let offer = app.buttons["Beispiel-Mediathek anlegen"]
        let started = Date()
        let created = waitStable(timeout: timeout, interval: 5) { !seeding.exists && !offer.exists }
        if !created { print("UI_STEP_MISSING demo library created (timeout \(Int(timeout)) s)") }
        print("UI_TIMING demo library \(Int(Date().timeIntervalSince(started))) s")
        return created
    }

    /// `condition` held on three checks in a row, `interval` seconds apart.
    private static func waitStable(timeout: TimeInterval, interval: UInt32 = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            let asked = Date()
            streak = condition() ? streak + 1 : 0
            reportSlowCheck(since: asked)
            if streak >= 3 { return true }
            sleep(interval)
        }
        return false
    }

    /// One check (a few queries) normally answers in well under a second. A slow one is printed
    /// with the time, so a run whose queries time out shows whether the answers slowed down
    /// first or stopped at once (compare `UI_MAIN_STALL` / `UI_PROCESS_STALL` from the app).
    static func reportSlowCheck(since asked: Date) {
        let took = Date().timeIntervalSince(asked)
        if took >= 5 { print("UI_SLOW_QUERY a check took \(Int(took)) s") }
    }
}
