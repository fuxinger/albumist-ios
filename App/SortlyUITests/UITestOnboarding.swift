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

    /// Onboarding, demo library and first analysis, only when the app still shows its welcome
    /// screen. Returns true when it had to do that.
    @discardableResult
    static func completeIfNeeded(_ app: XCUIApplication, in test: String) -> Bool {
        func button(_ text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        guard button("Los geht").waitForExistence(timeout: 10) else { return false }
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
        return true
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
        let created = waitStable(timeout: timeout, interval: 5) { !seeding.exists && !offer.exists }
        if !created { print("UI_STEP_MISSING demo library created (timeout \(Int(timeout)) s)") }
        return created
    }

    /// `condition` held on three checks in a row, `interval` seconds apart.
    private static func waitStable(timeout: TimeInterval, interval: UInt32 = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            streak = condition() ? streak + 1 : 0
            if streak >= 3 { return true }
            sleep(interval)
        }
        return false
    }
}
