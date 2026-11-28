import XCTest
import UIKit

/// Design wave 3, "Show und Handschrift", on the simulator with the demo library: the first
/// 100 % (DS-08), the sorting show's count (DS-17), a suggestion's page in its cover's calm
/// colour, light and dark (DS-11), and the app's icon with its name in Settings › "Über".
///
/// A class of its own, in the UI group "device" since 28.11. (`.github/ui-groups.json`; before in
/// "flow-other"), after the device-condition tests (XCTest runs the classes in alphabetical
/// order, and the tests of a class too; test10 before it gives the photo access back). Each test brings the
/// app to an onboarded, analysed demo library by itself (`prepare`). Test 1 rebuilds the
/// database twice, without the backup copy: the tests after it find every suggestion open.
/// Tests 3 and 4, the "Handschrift" half (DS-11), are an extension of this class in
/// `ShowAndHandwritingUITests+Handwriting.swift`; the helpers it uses are internal.
///
/// Steps print `UI_STEP_OK` / `UI_STEP_MISSING`, facts `UI_FACT`, screenshots `PREVIEW_JPEG
/// ui-…` and the audits' findings `A11Y_ISSUE` (`UITestReport`). No fixed sleeps: every wait
/// waits for a state and has a deadline (`UITestWait`).
@MainActor
final class ShowAndHandwritingUITests: XCTestCase {
    var app = XCUIApplication()

    // MARK: Helpers

    private func launch(_ extra: [String] = []) {
        // UITestAppEnd.launch ends the app of the last launch first.
        app = XCUIApplication()
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked"]
            + UITestStalls.arguments(besides: extra) + extra
        UITestAppEnd.launch(app)
    }

    func shot(_ name: String) {
        UITestReport.shot(name, in: self)
    }

    func audit(_ screen: String) {
        UITestReport.audit(app, screen)
    }

    /// `condition` held on three checks in a row, 2 s apart: the analysis idle for about four
    /// seconds, not only between two batches (`waitStable` of the flow tests).
    @discardableResult
    private func steadily(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let start = Date()
        var streak = 0
        let held = UITestWait.holds(timeout: timeout, interval: 2) {
            let asked = Date()
            streak = condition() ? streak + 1 : 0
            UITestOnboarding.reportSlowCheck(since: asked)
            return streak >= 3
        }
        print("UI_TIMING wait \(what) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        print(held ? "UI_STEP_OK \(what)" : "UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return held
    }

    /// A tab of the bar; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tab(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            // The bar expands after the swipe: on as soon as the button can be tapped.
            _ = UITestWait.holds(timeout: 1) { button.exists && button.isHittable }
            tries += 1
        }
        return button
    }

    @discardableResult
    func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
            XCTFail("Missing: \(step)")
            return false
        }
        var swipes = 0
        while !element.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        UITestOnboarding.clock("tap \(step)")
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    /// The onboarded demo library with nothing running, as each test needs it: the fast start
    /// (onboarding done, the demo library created where it is missing), the onboarding where
    /// the app still shows its welcome screen, an analysis cut off by an earlier test finished,
    /// and the whole library where an earlier test left a trial year on (`prepare` of the flow
    /// tests).
    func prepare(_ test: String, _ extra: [String] = []) {
        let started = Date()
        launch(["-AlbumistUITestFastStart"] + extra)
        UITestOnboarding.completeIfNeeded(app, in: test)
        let seeding = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Beispielfotos werden angelegt")).firstMatch
        let ready = steadily("\(test): demo library analysed", timeout: 900) {
            UITestScreens.Analysis.isIdle(app) && !seeding.exists
        }
        XCTAssertTrue(ready, "\(test): the demo library was not created and analysed")
        let trialYear = UITestScreens.TrialYear.shown(app)
        if trialYear.exists, tap(UITestScreens.TrialYear.allYearsButton(app), "\(test): take in all years", timeout: 5) {
            print("UI_FACT \(test): a trial year was still on, all years taken in")
            UITestWait.disappears(trialYear, "\(test): trial year off", timeout: 20)
            steadily("\(test): analysis idle after all years", timeout: 300) { UITestScreens.Analysis.isIdle(app) }
        }
        print("UI_TIMING prepare \(test) \(Int(Date().timeIntervalSince(started))) s")
    }

    // MARK: The first 100 % (DS-08)

    /// "100 %" above "Analyse fertig" on the ring card (`FirstAnalysisMomentHeader`), there only
    /// while it plays.
    private var firstFinish: XCUIElement {
        app.descendants(matching: .any)["analysis.firstFinish"]
    }

    /// How the analysis that started with a launch ended.
    private struct AnalysisEnd {
        var ended = false
        /// The first 100 % showed at the end.
        var moment = false
        /// The finish was celebrated: "Analyse fertig" with its suggestions (`analysis.finished`),
        /// which the moment rides on.
        var celebrated = false
        var seconds = 0
    }

    /// Watches the analysis that started with this launch to its end, asking as little as
    /// possible while it runs (every query slows it down, see `analysisIdle` in the flow tests):
    /// "Pause" every 2 s until it is gone, then the first 100 % and the start page's line. A
    /// question about notifications in front of the app (`UITestWait.clearSystemAlert`) is
    /// answered: the app is not active behind it, and the moment waits for the screen.
    private func watchAnalysis(_ what: String, timeout: TimeInterval = 1200) -> AnalysisEnd {
        let start = Date()
        let pause = app.buttons["Pause"]
        let moment = firstFinish
        let line = UITestScreens.Analysis.line(app)
        var ran = false
        var end = AnalysisEnd()
        end.ended = UITestWait.holds(timeout: timeout, interval: 2) {
            UITestWait.clearSystemAlert("while \(what) runs")
            if pause.exists {
                ran = true
                return false
            }
            if moment.exists {
                end.moment = true
                return true
            }
            // Before the run shows its "Pause" the page may show a line already: the end counts
            // once the run was seen, or after a minute and a half (both runs here are slowed to
            // well over 30 s, so their "Pause" shows long enough to be seen on a busy Mac).
            return line.exists && (ran || Date().timeIntervalSince(start) > 90)
        }
        end.seconds = Int(Date().timeIntervalSince(start))
        // Between the run's end and its card the page shows the done row, which counts as the
        // line above; "Analyse fertig" comes only after the counts are made anew and the safety
        // copy, on a busy Mac more than a few seconds later: up to 20 s for the card or the moment
        // (verification review V, X7). The card claims the moment as it appears: a few seconds
        // more for it. What the wait saw counts: a run that starts in those seconds replaces the
        // card, and a celebrated finish stays celebrated (verification review Y, Y6).
        let finished = app.buttons["analysis.finished"]
        if end.ended && !end.moment {
            _ = UITestWait.holds(timeout: 20) {
                end.celebrated = end.celebrated || finished.exists
                return end.celebrated || moment.exists
            }
            end.moment = moment.waitForExistence(timeout: 5)
        }
        end.celebrated = end.celebrated || finished.exists
        print("UI_TIMING \(what) \(end.seconds) s (its Pause seen: \(ran))")
        print(end.ended ? "UI_STEP_OK \(what) ended" : "UI_STEP_MISSING \(what) ended (timeout \(Int(timeout)) s)")
        XCTAssertTrue(end.ended, "\(what) did not end within \(Int(timeout)) s")
        return end
    }

    /// DS-08: the first full analysis that ends while Albumist is on screen shows "100 %" above
    /// "Analyse fertig" once (`analysis.firstFinish`, VoiceOver's "Analyse fertig: 100 %"), and
    /// never again, not after the next full analysis either. The group's simulator is not fresh,
    /// so the first launch starts the moment afresh (`-AlbumistUITestFirstFinishOwed`) and
    /// rebuilds the database: its analysis at launch is the first full one. The relaunch rebuilds
    /// the database again without starting afresh: the same full analysis, and the moment must
    /// stay away. Both launches let it show (`-AlbumistUITestFirstFinishMoment`, held 15 s instead
    /// of 3.2 s) and slow the analysis (`-AlbumistUITestSlowAnalysis`: 150 ms more per photo, one
    /// lane), so each full analysis of the demo library's 241 photos runs well over the 30 s that
    /// "Analyse fertig" needs, on any Mac: the second finish is celebrated, and the check that
    /// the moment stays away has teeth (verification review V7).
    func test1_FirstFullAnalysisShowsItsHundredPercentOnce() {
        continueAfterFailure = true
        prepare("first 100 %")

        launch(["-AlbumistUITestRebuildDatabase", "-AlbumistUITestFirstFinishMoment", "-AlbumistUITestFirstFinishOwed",
                "-AlbumistUITestSlowAnalysis"])
        UITestWait.appears(app.tabBars.firstMatch, "first 100 %: start page after the rebuild", timeout: 60)
        let first = watchAnalysis("first 100 %: first full analysis")
        let moment = firstFinish
        if first.moment {
            // The picture first, while it is there; then what it says.
            shot("09x-first-100")
            let label = (try? moment.snapshot())?.label ?? ""
            print("UI_FACT first 100 %: '\(label)', the finish celebrated: \(first.celebrated)")
            print("UI_STEP_OK first 100 %: shown after the first full analysis")
            // "100 %" with the locale's space (a no-break space in German).
            let says = label.hasPrefix("Analyse fertig: 100") && label.hasSuffix("%")
            XCTAssertTrue(says, "The first 100 % says '\(label)', not \"Analyse fertig: 100 %\"")
            XCTAssertTrue(first.celebrated, "The first 100 % showed without \"Analyse fertig\" (analysis.finished)")
        } else {
            print("UI_STEP_MISSING first 100 %: shown after the first full analysis (the finish celebrated: \(first.celebrated), \(first.seconds) s)")
            shot("x-no-first-100")
            XCTFail("No \"100 %\" (analysis.firstFinish) after the first full analysis (\"Analyse fertig\" shown: \(first.celebrated), \(first.seconds) s)")
        }
        // Gone before anything else looks at the page (held 15 s in UI runs, then it folds).
        UITestWait.disappears(moment, "first 100 %: folded away", timeout: 40)
        audit("start page after the first 100 %")

        launch(["-AlbumistUITestRebuildDatabase", "-AlbumistUITestFirstFinishMoment", "-AlbumistUITestSlowAnalysis"])
        UITestWait.appears(app.tabBars.firstMatch, "first 100 %: start page after the second rebuild", timeout: 60)
        let next = watchAnalysis("first 100 %: next full analysis")
        // Only a celebrated finish could show it: the check below has teeth only then.
        print("UI_FACT first 100 %: the next finish \(next.celebrated ? "was" : "was not") celebrated (\(next.seconds) s)")
        XCTAssertTrue(next.celebrated,
                      "The next full analysis ended without \"Analyse fertig\" (\(next.seconds) s): no moment could have shown, so its absence says nothing")
        XCTAssertFalse(next.moment, "The 100 % came again after the next full analysis")
        UITestWait.never("first 100 %: not again after the next full analysis", for: 20) { firstFinish.exists }
        shot("09y-no-second-100")
    }

    // MARK: The sorting show (DS-17)

    /// What the sorting show says, from one snapshot of the screen (an element that goes between
    /// asking for it and reading it fails the test, and the show ends on its own): whether its
    /// "Animation überspringen" (`show.skip`) is there, and the value of its one VoiceOver
    /// element "Fotos werden einsortiert". Nil when the snapshot cannot be read.
    private func showState() -> (skip: Bool, value: String?)? {
        guard let root = try? app.snapshot() else { return nil }
        var skip = false
        var value: String?
        var stack: [any XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            if node.identifier == "show.skip" { skip = true }
            if node.label == "Fotos werden einsortiert" { value = node.value as? String }
            stack.append(contentsOf: node.children)
        }
        return (skip, value)
    }

    /// DS-17: while a plan's sorting show runs, "Animation überspringen" (`show.skip`) is there
    /// and the show's one VoiceOver element ("Fotos werden einsortiert") says how far it is, its
    /// photos at the end: "…, 0 Fotos einsortiert" while its album waits, "…, 2 Fotos
    /// einsortiert" once it landed with its two photos (verification review V8; the grouping of
    /// bigger numbers, which two photos cannot show, is a unit test of the words:
    /// `SortingShowSourceTests.theCountReadsAsTheCatalogWritesIt`). The plan is one new album of
    /// two photos made by hand, with the slow plan (`-AlbumistUITestSlowPlan`: every change after
    /// a launch's first waits 30 s), so the show stays on screen while its album waits, long
    /// enough to be read and pictured on a slow Mac. The album lands once its photos are in, and
    /// the show then holds its end 15 s (`-AlbumistUITestShowHold`) instead of half a second, so
    /// a look sees it landed: a test whose looks all miss it fails.
    func test2_SortingShowCountsThePhotosItSorts() {
        continueAfterFailure = true
        prepare("show", ["-AlbumistUITestSlowPlan", "-AlbumistUITestShowHold"])
        guard tap(tab("Unsortiert"), "show: tab Unsortiert"),
              UITestScreens.Unsorted.planNewAlbum(app, titled: "Testalbum Show", "show") else {
            XCTFail("show: no plan of a new album could be opened")
            return
        }
        guard tap(app.buttons["plan.apply"], "show: apply the plan", timeout: 30) else { return }
        var state: (skip: Bool, value: String?)?
        let running = UITestWait.until("show: on screen with \"Animation überspringen\" and its count", timeout: 20) {
            state = showState()
            return state?.skip == true && state?.value != nil
        }
        if running, let value = state?.value {
            shot("10x-show")
            print("UI_FACT show: '\(value)'")
            let waiting = value.hasSuffix(", 0 Fotos einsortiert")
            print(waiting ? "UI_STEP_OK show: its value ends in \", 0 Fotos einsortiert\" while its album waits"
                          : "UI_STEP_MISSING show: its value ends in \", 0 Fotos einsortiert\" while its album waits ('\(value)')")
            XCTAssertTrue(value.hasSuffix(", 0 Fotos einsortiert"), "The show says '\(value)' while its album waits, not \"…, 0 Fotos einsortiert\"")
        }
        // The album lands once its photos are in: the count changes while the show is still on,
        // and the show holds its end for this look.
        var landed: String?
        let ended = UITestWait.until("show: the album landed or the show ended", timeout: 120) {
            guard let now = showState() else { return false }
            if now.value == nil && !now.skip { return true }
            if let value = now.value, !value.hasSuffix(", 0 Fotos einsortiert") {
                landed = value
                return true
            }
            return false
        }
        if ended, let landed {
            shot("10y-show-landed")
            print("UI_FACT show: '\(landed)'")
            let two = landed.hasSuffix(", 2 Fotos einsortiert")
            print(two ? "UI_STEP_OK show: its value ends in \", 2 Fotos einsortiert\" once its album landed"
                      : "UI_STEP_MISSING show: its value ends in \", 2 Fotos einsortiert\" once its album landed ('\(landed)')")
            XCTAssertTrue(landed.hasSuffix(", 2 Fotos einsortiert"),
                          "The show says '\(landed)' once its album landed, not \"…, 2 Fotos einsortiert\" for its two photos")
        } else if ended {
            print("UI_STEP_MISSING show: a look saw its album land")
            XCTFail("The show ended before a look saw its album land, though it holds its end 15 s in this run")
        }
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Rückgängig machen")).firstMatch
        let finished = UITestWait.appears(result, "show: the plan's result after the show", timeout: 300)
        if finished { shot("10z-show-result") }
    }
}
