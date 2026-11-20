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

    /// The start page says the analysis is done and nothing runs (as `analysisIdle` in the
    /// tests): its line (`analysis.summary` or `analysis.finished`) and no "Pause".
    static func analysisIdle(_ app: XCUIApplication) -> Bool {
        UITestScreens.Analysis.isIdle(app)
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
        let welcome = app.buttons["onboarding.letsGo"]
        let demo = app.buttons["Beispiel-Mediathek anlegen"]
        // The first screen: the welcome screen, the start page's tab bar or "Kein Zugriff". The
        // app picks it once when it has loaded (`AppModel.phase`), so a tab bar is never followed
        // by the welcome screen. Waiting 10 s for the welcome screen alone ran out in every test
        // that found the app onboarded: in CI test 1 runs in its own group, so flow tests 3-7
        // and the locked test came here each time (UI run 44630953220).
        _ = UITestWait.holds(timeout: 10) {
            welcome.exists || app.tabBars.firstMatch.exists || app.buttons["access.continue"].exists
        }
        guard welcome.exists else {
            // The demo card is drawn in the same body as the start page's title (OverviewView, a
            // plain VStack; DemoLibrary.isDone is read at start), so once "Vorschläge" is there,
            // the card is there too or does not come. Up to the old 5 s when it is not.
            let startPage = app.navigationBars["Vorschläge"]
            _ = UITestWait.holds(timeout: 5) { demo.exists || startPage.exists }
            guard demo.exists else {
                finishInterruptedAnalysis(app, in: test)
                return false
            }
            print("UI_FACT \(test): past the onboarding without the demo library, creating it first")
            demo.tap()
            XCTAssertTrue(demoLibraryCreated(app), "\(test): demo library not created")
            let idle = waitStable(timeout: 1200) { analysisIdle(app) }
            print(idle ? "UI_STEP_OK \(test) demo library" : "UI_STEP_MISSING \(test) demo library")
            XCTAssertTrue(idle, "\(test): the analysis of the demo library did not finish")
            expectCompleteAnalysis(app, in: test)
            return true
        }
        print("UI_FACT \(test): the app is at its welcome screen, onboarding first")
        welcome.tap()
        guard passAccessPage(app) else {
            print("UI_STEP_MISSING \(test) onboarding")
            XCTFail("\(test): the onboarding did not reach the tabs after the access page")
            return true
        }
        if demo.waitForExistence(timeout: 30) {
            demo.tap()
            XCTAssertTrue(demoLibraryCreated(app), "\(test): demo library not created")
        }
        let idle = waitStable(timeout: 1200) { analysisIdle(app) }
        print(idle ? "UI_STEP_OK \(test) onboarding and demo library" : "UI_STEP_MISSING \(test) onboarding and demo library")
        XCTAssertTrue(idle, "\(test): the analysis of the demo library did not finish")
        expectCompleteAnalysis(app, in: test)
        return true
    }

    /// The access page after "Los geht’s" (H5, design wave 1): "Analyse starten"
    /// (`onboarding.start`) when the photos can be read already (the CI grants them before the
    /// run), else "Weiter" (`access.continue`) and the iOS question, after which the analysis
    /// starts by itself. No areas page, no year, no question about notifications any more.
    /// True once the tabs show.
    @discardableResult
    static func passAccessPage(_ app: XCUIApplication) -> Bool {
        let start = app.buttons["onboarding.start"]
        let ask = app.buttons["access.continue"]
        let tabs = app.tabBars.firstMatch
        guard UITestWait.holds(timeout: 10, { start.exists || ask.exists || tabs.exists }) else {
            print("UI_FACT onboarding: neither \"Analyse starten\" nor \"Weiter\" on the access page")
            return false
        }
        if ask.exists && !start.exists {
            ask.tap()
            allowPhotosIfAsked(app)
        }
        // With access the app goes on by itself; "Analyse starten" stays only where the photos
        // could be read before the question (or iOS gave limited access).
        if !tabs.exists && start.waitForExistence(timeout: 3) { start.tap() }
        return tabs.waitForExistence(timeout: 30)
    }

    /// The counts of the start page and the sheet "Analyse" when not every photo counts as
    /// analysed and read: the line "58 von 246 Fotos analysiert", or "Analyse fertig" with "12
    /// Fotos konnten noch nicht gelesen werden" in the sheet. Nil when every photo is (the line
    /// says "Alle 246 Fotos analysiert"), or when the page shows no line within `wait`. German
    /// only. A line that could not be read is never taken as complete (`readFailed`).
    static func partialAnalysis(_ app: XCUIApplication, wait: TimeInterval = 3) -> UITestScreens.Analysis.Counts? {
        guard let counts = UITestScreens.Analysis.counts(app, wait: wait), !counts.complete else { return nil }
        return counts
    }

    /// After a test watched the analysis finish in this app process, every photo must count as
    /// analysed: a partial count is an analysis that stopped early and said "fertig" (never
    /// allowed), not something to repair with "Neu prüfen".
    static func expectCompleteAnalysis(_ app: XCUIApplication, in test: String) {
        guard let partial = partialAnalysis(app) else { return }
        if partial.readFailed {
            print("UI_STEP_MISSING \(test) complete analysis: count not readable")
            XCTFail("\(test): the start page shows an analysis count that could not be read ('\(partial.label)')")
        } else if partial.cutOff {
            print("UI_STEP_MISSING \(test) complete analysis: '\(partial.label)'")
            XCTFail("\(test): the analysis ended early at '\(partial.label)' (\(partial.unreadable) unreadable, \(partial.loads)) although this test watched it finish")
        } else {
            print("UI_STEP_MISSING \(test) readable demo photos: \(partial.unreadableText)")
            XCTFail("\(test): \(partial.unreadableText)")
        }
    }

    /// Only for a relaunch into a library seeded earlier (no welcome screen, no demo button):
    /// an analysis cut off by a restarted test runner (the app was ended in the middle of it)
    /// does not go on by itself in UI runs, which start no analysis at launch. The start page
    /// then says "58 von 246 Fotos analysiert" (its sheet "Analyse" has "Neu prüfen"), or
    /// "Fortsetzen" when the run ended for the device, and `analysisIdle` takes the line as
    /// done (run 43918684247: the runner was restarted in accessibility test
    /// 1, and tests 2 to 4 found "No suggestions yet"). "Neu prüfen" analyses the rest, as a
    /// user would. Photos that could not be read are no cut-off: checking again would not change
    /// them, so they fail at once with their count instead of after a 20-minute wait.
    static func finishInterruptedAnalysis(_ app: XCUIApplication, in test: String) {
        let resume = app.buttons["analysis.resume"]
        if resume.exists {
            print("UI_FACT \(test): the analysis ended for the device or iOS, \"Fortsetzen\"")
            UITestScreens.Cards.reach(resume, in: app)
            resume.tap()
        } else {
            guard let partial = partialAnalysis(app) else { return }
            if partial.readFailed {
                print("UI_STEP_MISSING \(test) partial count readable")
                XCTFail("\(test): the start page shows an analysis count that could not be read ('\(partial.label)')")
                return
            }
            guard partial.cutOff else {
                print("UI_STEP_MISSING \(test) readable demo photos: \(partial.unreadableText)")
                XCTFail("\(test): \(partial.unreadableText)")
                return
            }
            print("UI_FACT \(test): the analysis was cut off at '\(partial.label)' (\(partial.unreadable) unreadable), checking again")
            guard UITestScreens.Analysis.checkAgain(app, "\(test) check again after a cut-off analysis") else { return }
        }
        // Idle once more; the count is judged after it (unreadable photos included).
        let done = waitStable(timeout: 1200) { analysisIdle(app) }
        print(done ? "UI_STEP_OK \(test) cut-off analysis finished" : "UI_STEP_MISSING \(test) cut-off analysis finished")
        XCTAssertTrue(done, "\(test): the cut-off analysis did not finish after \"Neu prüfen\" or \"Fortsetzen\"")
        if done { expectCompleteAnalysis(app, in: test) }
    }

    /// Taps "Allow Full Access" in the iOS question for the photos when it comes; the tabs, the
    /// access page's "Analyse starten" or its "Einstellungen öffnen" (denied) mean the app went
    /// on without it.
    static func allowPhotosIfAsked(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        _ = UITestWait.holds(timeout: 25) {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    return true
                }
            }
            return app.tabBars.firstMatch.exists || app.buttons["onboarding.start"].exists || app.buttons["access.settings"].exists
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
            // pacing: the poll's interval
            sleep(interval)
        }
        return false
    }

    /// One check (a few queries) normally answers in well under a second. A slow one is printed
    /// with the time, so a run whose queries time out shows whether the answers slowed down
    /// first or stopped at once (compare `UI_MAIN_STALL` / `UI_PROCESS_STALL` from the app).
    static func reportSlowCheck(since asked: Date) {
        let took = Date().timeIntervalSince(asked)
        if took >= 5 { print("UI_FACT slow query: a check took \(Int(took)) s, from \(clockText(asked)) UTC") }
    }

    /// `UI_FACT clock 18:31:05.2 <event>`: the time of a test step in UTC, on the clock the app's
    /// `UI_MAIN_STALL` lines use (`MainThreadWatch.clock`), so a stall can be put next to the
    /// step, the tap or the accessibility audit that ran then.
    static func clock(_ event: String) {
        // UI_FACT: the job log keeps only some prefixes of the test output (ui_tests.py
        // REPORT), and prints them after the test, so the time has to be in the line.
        print("UI_FACT clock \(clockText(Date())) \(event)")
    }

    static func clockText(_ date: Date) -> String {
        let day = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let hours = Int(day / 3600), minutes = Int(day.truncatingRemainder(dividingBy: 3600) / 60)
        let rest = day.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%04.1f", hours, minutes, rest)
    }
}
