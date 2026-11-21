import XCTest
import UIKit

/// Design wave 3, "Show und Handschrift", on the simulator with the demo library: the first
/// 100 % (DS-08), the sorting show's count (DS-17), a suggestion's page in its cover's calm
/// colour, light and dark (DS-11), and the app's icon with its name in Settings › "Über".
///
/// A class of its own, so it runs in the UI group "flow-other" (`.github/ui-groups.json`: every
/// test the other groups do not run), after the flow, locked, search and frame tests (XCTest
/// runs the classes in alphabetical order, and the tests of a class too). Each test brings the
/// app to an onboarded, analysed demo library by itself (`prepare`). Test 1 rebuilds the
/// database twice, without the backup copy: the tests after it find every suggestion open.
///
/// Steps print `UI_STEP_OK` / `UI_STEP_MISSING`, facts `UI_FACT`, screenshots `PREVIEW_JPEG
/// ui-…` and the audits' findings `A11Y_ISSUE` (`UITestReport`). No fixed sleeps: every wait
/// waits for a state and has a deadline (`UITestWait`).
@MainActor
final class ShowAndHandwritingUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers

    private func launch(_ extra: [String] = []) {
        // UITestAppEnd.launch ends the app of the last launch first.
        app = XCUIApplication()
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked"]
            + UITestStalls.arguments(besides: extra) + extra
        UITestAppEnd.launch(app)
    }

    private func shot(_ name: String) {
        UITestReport.shot(name, in: self)
    }

    private func audit(_ screen: String) {
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
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
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

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    /// The onboarded demo library with nothing running, as each test needs it: the fast start
    /// (onboarding done, the demo library created where it is missing), the onboarding where
    /// the app still shows its welcome screen, an analysis cut off by an earlier test finished,
    /// and the whole library where an earlier test left a trial year on (`prepare` of the flow
    /// tests).
    private func prepare(_ test: String, _ extra: [String] = []) {
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
            // once the run was seen, or after half a minute.
            return line.exists && (ran || Date().timeIntervalSince(start) > 30)
        }
        end.seconds = Int(Date().timeIntervalSince(start))
        // The card claims the moment as it appears: a few seconds more for it.
        if end.ended && !end.moment { end.moment = moment.waitForExistence(timeout: 5) }
        end.celebrated = app.buttons["analysis.finished"].exists
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
        XCTAssertTrue(next.celebrated, "The next full analysis ended without \"Analyse fertig\" (\(next.seconds) s): no moment could have shown, so its absence says nothing")
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
            XCTAssertTrue(landed.hasSuffix(", 2 Fotos einsortiert"), "The show says '\(landed)' once its album landed, not \"…, 2 Fotos einsortiert\" for its two photos")
        } else if ended {
            print("UI_STEP_MISSING show: a look saw its album land")
            XCTFail("The show ended before a look saw its album land, though it holds its end 15 s in this run")
        }
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Rückgängig machen")).firstMatch
        let finished = UITestWait.appears(result, "show: the plan's result after the show", timeout: 300)
        if finished { shot("10z-show-result") }
    }

    // MARK: The page's own colour (DS-11)

    /// iOS's grouped background (`Theme.background`), the page's ground without a tint, in sRGB:
    /// #F2F2F7 in light mode, black in dark mode.
    private static func neutralGround(dark: Bool) -> [Int] {
        dark ? [0, 0, 0] : [242, 242, 247]
    }

    /// The colour of the screen at `point` (in points), in sRGB 0–255, the mean of 3 × 3 pixels
    /// of a new screenshot. Nil when it cannot be read.
    private func pixel(at point: CGPoint) -> [Int]? {
        let width = app.frame.width
        guard width > 0, let image = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let scale = CGFloat(image.width) / width
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 1, y >= 1, x + 2 <= image.width, y + 2 <= image.height,
              let crop = image.cropping(to: CGRect(x: x - 1, y: y - 1, width: 3, height: 3)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 3 * 3 * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            return true
        }
        guard drawn else { return nil }
        return (0..<3).map { channel in stride(from: channel, to: bytes.count, by: 4).map { Int(bytes[$0]) }.reduce(0, +) / 9 }
    }

    /// The open suggestion page's ground beside its facts line ("16 Fotos · 12. bis 16.
    /// Oktober"), 5 pt from the left edge: left of the header's 16-pt margin, below the cover,
    /// where only the page's ground is. Nil without the line or a picture.
    private func pageGround() -> [Int]? {
        let facts = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos? · .*")).firstMatch
        guard let frame = (try? facts.snapshot())?.frame, !frame.isEmpty else { return nil }
        return pixel(at: CGPoint(x: 5, y: frame.midY))
    }

    /// The open suggestion page's ground took its cover's colour: it differs from the grouped
    /// background (by at least 4 in the three channels together; a pale tint differs by 5 or
    /// more, a picture of the plain background by at most 3) and holds still from one look to
    /// the next (the 0.45 s cross-fade has ended). Not a failure by itself: a cover without a
    /// colour of its own has no tint. The last colour seen, for the report.
    private func waitForTint(_ what: String, dark: Bool) -> (tinted: Bool, ground: [Int]?) {
        let neutral = Self.neutralGround(dark: dark)
        var last: [Int]?
        let start = Date()
        let tinted = UITestWait.holds(timeout: 12) {
            guard let now = pageGround() else {
                last = nil
                return false
            }
            defer { last = now }
            let away = zip(now, neutral).map { abs($0 - $1) }.reduce(0, +) >= 4
            let still = last.map { zip($0, now).allSatisfy { abs($0 - $1) <= 1 } } ?? false
            return away && still
        }
        print("UI_TIMING wait \(what): tint \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        return (tinted, last)
    }

    /// Opens a trip's suggestion page whose ground takes its cover's colour (`named`: that trip,
    /// by the album its card names; else the first of the list's first three that does) and
    /// returns its name; nil, with a failure, when none does.
    private func openTintedTrip(_ what: String, dark: Bool, named wanted: String?) -> String? {
        guard UITestScreens.StartPage.openList(app, area: "trips", "\(what): trips") else {
            print("UI_STEP_MISSING \(what): a list of trips")
            XCTFail("\(what): the start page offers no list of suggestions")
            return nil
        }
        let cards = UITestScreens.SuggestionList.cards(app)
        let candidates: [XCUIElement]
        if let wanted, let card = UITestScreens.SuggestionList.card(app, containing: wanted) {
            candidates = [card]
        } else {
            if let wanted { print("UI_FACT \(what): '\(wanted)' is not in the list, another trip instead") }
            candidates = (0..<min(3, cards.count)).map { cards.element(boundBy: $0) }
        }
        var tried: [String] = []
        for card in candidates {
            // Read before the tap: the pushed page takes the list out of the tree.
            let name = UITestScreens.Cards.albumName(of: card) ?? card.buttons["photoCard.body"].label
            guard UITestScreens.Cards.open(card, in: app, "\(what): open '\(name)'") else { continue }
            let page = UITestWait.until("\(what): page of '\(name)' with its facts", timeout: 15) {
                UITestScreens.SuggestionPage.isShown(app) && UITestScreens.SuggestionPage.photoCount(app) != nil
            }
            guard page else { continue }
            let (tinted, ground) = waitForTint(what, dark: dark)
            let colour = ground.map { "rgb(\($0.map(String.init).joined(separator: ", ")))" } ?? "not read"
            if tinted {
                print("UI_STEP_OK \(what): the page of '\(name)' takes its cover's colour, \(colour) (grouped background \(Self.neutralGround(dark: dark)))")
                return name
            }
            print("UI_FACT \(what): the page of '\(name)' kept \(colour), no colour of its own")
            tried.append(name)
            back()
            UITestWait.appears(cards.firstMatch, "\(what): back in the list", timeout: 10)
        }
        print("UI_STEP_MISSING \(what): a trip's page in its cover's colour (tried \(tried))")
        shot("x-\(dark ? "dark" : "light")-no-tint")
        XCTFail("\(what): no trip's page took its cover's colour (tried \(tried))")
        return nil
    }

    /// DS-11: a suggestion's page takes its cover's calm colour as its ground, pale in light
    /// mode and deep in dark mode (`PhotoTintGround`), and stays readable: screenshots and the
    /// accessibility audit of the page in both (dark mode as the other tests force it,
    /// `-AlbumistUITestDark`). The colour is read from the screenshot beside the facts line.
    func test3_SuggestionPageTakesItsCoversCalmColour() {
        continueAfterFailure = true
        prepare("tint light")
        guard let trip = openTintedTrip("tint light", dark: false, named: nil) else { return }
        shot("30x-tint-light")
        audit("suggestion page in its cover's colour, light")

        prepare("tint dark", ["-AlbumistUITestDark"])
        guard openTintedTrip("tint dark", dark: true, named: trip) != nil else { return }
        shot("30y-tint-dark")
        audit("suggestion page in its cover's colour, dark")
    }

    // MARK: Settings › Über

    /// Settings › "Über" starts with the app's icon (the Glass Stack, DS-11: where the app
    /// speaks of itself) and its name, one element for VoiceOver: "Albumist" between the
    /// section's title and "Version".
    func test4_SettingsAboutShowsTheAppsIconAndName() {
        continueAfterFailure = true
        prepare("about")
        guard tap(app.buttons["Einstellungen"], "about: settings") else { return }
        UITestWait.appears(app.navigationBars["Einstellungen"], "about: settings open", timeout: 10)
        let version = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Version")).firstMatch
        var swipes = 0
        while !(version.exists && version.isHittable) && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        UITestWait.screenAtRest(app, "about: settings at rest at \"Über\"")
        // One snapshot: the section's title, the name and "Version", top to bottom.
        var title: CGRect?, versionRow: CGRect?
        var names: [(type: XCUIElement.ElementType, frame: CGRect)] = []
        if let root = try? app.snapshot() {
            var stack: [any XCUIElementSnapshot] = [root]
            while let node = stack.popLast() {
                if node.label.caseInsensitiveCompare("Über") == .orderedSame, title == nil { title = node.frame }
                if node.label == "Version", versionRow == nil { versionRow = node.frame }
                if node.label == "Albumist", node.elementType != .button { names.append((node.elementType, node.frame)) }
                stack.append(contentsOf: node.children)
            }
        }
        let inAbout = names.filter { name in
            (title.map { name.frame.minY >= $0.maxY - 1 } ?? false) && (versionRow.map { name.frame.maxY <= $0.minY + 1 } ?? false)
        }
        print("UI_FACT about: title \(title.map { "\($0)" } ?? "missing"), Version \(versionRow.map { "\($0)" } ?? "missing"), \"Albumist\" \(names.map { "\($0.type.rawValue) \($0.frame)" })")
        shot("80x-settings-about")
        let text = inAbout.contains { $0.type == .staticText }
        print(text ? "UI_STEP_OK about: \"Albumist\" in \"Über\"" : "UI_STEP_MISSING about: \"Albumist\" in \"Über\"")
        XCTAssertTrue(text, "Settings › Über has no text \"Albumist\" between its title and \"Version\"")
        tap(app.buttons["Fertig"], "about: close settings", timeout: 5)
    }
}
