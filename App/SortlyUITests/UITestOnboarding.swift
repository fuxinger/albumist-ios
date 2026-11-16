import XCTest

/// What the later UI tests need from test 1 (SortlyFlowUITests.test1_FullFlow): a finished
/// onboarding, the demo library and its first analysis.
///
/// UI run 43816787321: the test runner ended inside test 1 right after the trial step (no
/// "passed" or "failed" line, "Executed 5 tests" for the six flow tests). xcodebuild started a
/// new runner at test 2 with an app still at its welcome screen, and every later test failed
/// on that one cut-off (13 failures). Each later test now brings the app to that state by
/// itself when test 1 did not reach its end, so a cut-off costs test 1 and nothing else.
@MainActor
enum UITestOnboarding {
    /// Markers of test 1 in the runner's temporary folder. A static flag starts fresh in a
    /// restarted runner (run 43816787321: test 2 did not notice the cut-off); a file stays.
    private static let folder = FileManager.default.temporaryDirectory
    private static let started = folder.appending(path: "albumist-ui-full-flow-started")
    private static let finished = folder.appending(path: "albumist-ui-full-flow-finished")

    static func fullFlowStarts() {
        try? FileManager.default.removeItem(at: finished)
        try? Data().write(to: started)
    }

    static func fullFlowFinished() {
        try? Data().write(to: finished)
    }

    static var fullFlowWasCutOff: Bool {
        FileManager.default.fileExists(atPath: started.path) && !FileManager.default.fileExists(atPath: finished.path)
    }

    static var fullFlowReachedItsEnd: Bool {
        FileManager.default.fileExists(atPath: finished.path)
    }

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
            let seeded = waitStable(timeout: 600) {
                !app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Beispielfotos werden angelegt")).firstMatch.exists
                    && !demo.exists
            }
            XCTAssertTrue(seeded, "\(test): demo library not created")
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

    /// `condition` held on three checks in a row, 2 s apart.
    private static func waitStable(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            streak = condition() ? streak + 1 : 0
            if streak >= 3 { return true }
            sleep(2)
        }
        return false
    }
}
