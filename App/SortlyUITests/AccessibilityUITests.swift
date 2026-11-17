import XCTest
import UIKit

/// Accessibility run on its own small iPhone (CI job "Accessibility", iPhone SE size, Reduce
/// Motion on; see `.github/workflows/ui.yml`). Unlike the UI flow, which only prints what the
/// audit finds, these tests FAIL on real findings:
///
/// Failing audit types (`performAccessibilityAudit`):
/// - `.contrast` "Contrast failed" (clearly below WCAG AA)
/// - `.textClipped` at the accessibility text sizes, for text on one line ("Gan…thek")
/// - `.hitRegion` (target too small to tap)
/// - `.sufficientElementDescription` (missing or useless VoiceOver label)
///
/// Failing checks of our own (from one snapshot of the accessibility tree per screen):
/// - a button or link without a label, and a button, link or switch labelled "-" or with an
///   SF Symbol name ("chevron.right"), which VoiceOver would read out. Images and the inner
///   knob of a toggle are left to the audit: the tree also lists elements VoiceOver never
///   visits (`accessibilityHidden` thumbnails, the switch inside a labelled toggle), the
///   audit only real accessibility elements.
/// - a visible format placeholder ("%lld", "%@") and, in the English run, German words
///   left in the interface (untranslated strings)
/// - text that runs off the side of the screen
///
/// Reported, not failing (`A11Y_WARN`), each with its reason:
/// - "Contrast nearly passed": the system `secondaryLabel` colour Apple uses for secondary
///   text is 3.3–3.4:1 on light backgrounds (5.9–6.4:1 in dark mode); the app keeps the
///   system colour, see the report in the commit
/// - findings on disabled controls (WCAG 1.4.3 exempts inactive components)
/// - findings on or under the system's Liquid Glass bars (navigation bar, tab bar, toolbar,
///   bottom search field): XCTest cannot measure text on glass (Apple's own "Fertig" button
///   fails there), and content scrolling under a bar is cut by design
/// - contrast findings without an element on screens with such a bar: XCTest found text it
///   cannot attribute (text inside a combined row), which in the UI flow was always a row
///   passing under the tab bar
/// - text cut at the top or bottom edge of the screen (scrolled, not clipped)
/// - `.textClipped` at standard text sizes and on text that already wraps: the audit also
///   reports text that only clips once it grows, and wrapped text whose every line is shown
///   (checked in the screenshots); the run at the largest size is the real test
/// - findings on emoji only (country flags are pictures, not text) and inside a labelled
///   picture (the scaled-down share image preview, read out as one image)
/// - "Contrast failed" that does not repeat in a second contrast audit two seconds later
///   (measured while the screen moved; see `confirmContrast`)
/// - positions: XCTest can scroll while it audits, so an element counts as under a bar when
///   it was there in the snapshot taken just before the audit or is there afterwards. Bars
///   reach 12 pt into the content (the scroll edge effect), the keyboard 48 pt (its word
///   suggestions, three unlabelled system buttons)
/// - `.dynamicType`, `.elementDetection` and `.trait` are not audited here: the tests run at
///   the largest text size anyway, which is the stronger check, and the Dynamic Type audit
///   flags the intentional caps (progress ring, share image)
///
/// Every screen also prints a screenshot (`PREVIEW_JPEG ui-a11y-…`), like the UI flow.
@MainActor
final class AccessibilityUITests: XCTestCase {
    private var app = XCUIApplication()
    private var auditFailures: [String] = []
    private var screenFailures: [String] = []
    /// The current launch runs at an accessibility text size.
    private var accessibilitySize = false
    /// Frames by label from the snapshot just before the audit (see the class comment).
    private var framesBeforeAudit: [String: [CGRect]] = [:]
    /// Labelled pictures that contain text (share image preview).
    private var pictureFrames: [CGRect] = []
    /// "Contrast failed" findings waiting for the second contrast audit.
    private var pendingContrast: [(label: String, line: String, detail: String)] = []

    private static let largestText = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let failingAuditTypes: XCUIAccessibilityAuditType = [.contrast, .textClipped, .hitRegion, .sufficientElementDescription]

    /// Labels the walk taps, per language (from Localizable.xcstrings).
    private struct Words {
        var overviewTab: String
        var libraryTab: String
        var albumsTab: String
        var settings: String
        var done: String
        /// A pattern: the count is singular or plural ("1 Vorschlag prüfen" once only one
        /// suggestion is left open, UI run 43796844064).
        var reviewSuggestions: String
        var suggestionTitle: String
        var rowMarker: String
        var starterPattern: String
        var planTitle: String
        var applyNow: String
        var undo: String
        var atlas: String
        var shareAtlas: String
        var searchQuery: String
        var country: String
        /// Titles of screens the walk opens and goes back from: it waits for their bar.
        var receiptTitle: String
        var historyTitle: String

        static let german = Words(overviewTab: "Übersicht", libraryTab: "Mediathek", albumsTab: "Alben",
                                  settings: "Einstellungen", done: "Fertig", reviewSuggestions: ".*[0-9.]+ Vorschl(ag|äge) prüfen.*",
                                  suggestionTitle: "Vorschlag", rowMarker: "Fotos",
                                  starterPattern: "[0-9]+ Alben (kostenlos )?anlegen", planTitle: "Vorschau",
                                  applyNow: "Alben jetzt anlegen", undo: "Rückgängig machen", atlas: "Reise-Atlas",
                                  shareAtlas: "Reise-Atlas teilen", searchQuery: "Rom", country: "Italien",
                                  receiptTitle: "Änderungen", historyTitle: "Verlauf und Rückgängig")
        static let english = Words(overviewTab: "Overview", libraryTab: "Library", albumsTab: "Albums",
                                   settings: "Settings", done: "Done", reviewSuggestions: ".*Review [0-9,]+ suggestions?.*",
                                   suggestionTitle: "Suggestion", rowMarker: "photo",
                                   starterPattern: "Create [0-9]+ Albums?( for Free)?", planTitle: "Preview",
                                   applyNow: "Create Albums Now", undo: "Undo", atlas: "Travel Atlas",
                                   shareAtlas: "Share Travel Atlas", searchQuery: "Rome", country: "Italy",
                                   receiptTitle: "Changes", historyTitle: "History and Undo")
    }

    // MARK: Tests

    /// First start at the largest accessibility text size in dark mode: every onboarding step,
    /// then the demo library and its analysis, which the later tests use.
    func test1_OnboardingAtLargestTextInDarkMode() {
        continueAfterFailure = true
        UITestOnboarding.accessibilityOnboarding.starts()
        // Test 1 runs first on a freshly erased simulator (ui.yml; a repeat after a simulator
        // failure erases it again), so it always meets the welcome screen and checks every step.
        // An issue that ends the method early must not let it pass without its later checks.
        let end = UITestOnboarding.accessibilityOnboarding.finished
        addTeardownBlock {
            if !FileManager.default.fileExists(atPath: end.path) {
                print("UI_STEP_MISSING accessibility onboarding reached its end")
                XCTFail("test1_OnboardingAtLargestTextInDarkMode stopped before its end")
            }
        }
        launch(textSize: Self.largestText, dark: true)
        if !onboardAndSeed(checking: true) {
            print("UI_STEP_MISSING onboarding")
            XCTFail("test1 must start on a fresh simulator: no welcome screen, so the onboarding was not checked")
        }
        check("overview after first analysis")
        UITestOnboarding.accessibilityOnboarding.ends()
        finish("onboarding")
    }

    /// Test 1 did not reach its end (or did not run): onboarding, demo library and analysis
    /// first, without audits, so one cut-off test 1 does not fail every later test (run
    /// 43823834271: a timed-out query ended test 1 while the demo library was being created,
    /// and tests 2 to 4 found no suggestions).
    private func completeOnboardingIfCutOff(_ test: String) {
        guard !UITestOnboarding.accessibilityOnboarding.reachedItsEnd else { return }
        print("UI_FACT \(test): test 1 did not reach its end, onboarding and demo library first")
        launch()
        onboardAndSeed(checking: false)
    }

    /// Onboarding, demo library and its analysis, when the app is at its first start. Test 1
    /// does this with an audit of every step; a later test that finds the app new does it
    /// without (run 43796844064: the simulator service dropped the first pass before any test
    /// ran, and the contrast pass met the welcome screen instead of the overview).
    /// False when the app was past the onboarding already.
    @discardableResult
    private func onboardAndSeed(checking: Bool) -> Bool {
        let welcome = button("Los geht").waitForExistence(timeout: checking ? 30 : 10)
        if welcome {
            if !checking { print("UI_FACT app at its first start: onboarding and demo library first") }
            if checking { check("onboarding welcome") }
            tap(button("Los geht"), "welcome")
            if checking { check("onboarding areas") }
            tap(button("Weiter"), "areas")
            if checking { check("onboarding access") }
            if button("Zugriff erlauben").waitForExistence(timeout: 5) {
                button("Zugriff erlauben").tap()
                allowPhotosIfAsked()
            }
            if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
            let trial = button("Analyse starten").waitForExistence(timeout: 20)
            XCTAssertTrue(trial, "Onboarding did not reach the trial step")
            if checking { check("onboarding trial") }
            tap(button("Analyse starten"), "start analysis")
            allowNotificationsIfAsked()
        }
        let demo = button("Beispiel-Mediathek anlegen")
        let seeds = demo.waitForExistence(timeout: welcome ? 30 : 5)
        if seeds {
            tap(demo, "seed demo library")
            XCTAssertTrue(UITestOnboarding.demoLibraryCreated(app), "Demo library not created")
        } else if checking {
            print("UI_STEP_MISSING demo button")
            XCTFail("No \"Beispiel-Mediathek anlegen\" after the onboarding on a fresh simulator")
        }
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")
        let test = checking ? "accessibility test 1" : "accessibility"
        if welcome || seeds {
            // This test watched the analysis run to its end: a partial count now is an early stop.
            UITestOnboarding.expectCompleteAnalysis(app, in: test)
        } else {
            // A relaunch into a library seeded earlier, whose analysis a restarted runner may have cut off.
            UITestOnboarding.finishInterruptedAnalysis(app, in: test)
        }
        return welcome
    }

    /// The main screens in English at the default text size, light mode: nothing German left,
    /// nothing clipped, contrast and labels as in German. Runs before anything is applied, so
    /// no album names from a German run are on screen.
    func test2_EnglishMainScreens() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test2")
        launch(english: true)
        walk("en", .english, english: true)
        finish("english")
    }

    /// Largest accessibility text size, dark mode, Reduce Motion (set for this simulator by
    /// the workflow): every main screen, then the starter set is applied, so the sorting show,
    /// the result and the change receipt are checked too.
    func test3_LargestTextDarkModeReduceMotion() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test3")
        launch(textSize: Self.largestText, dark: true)
        walk("xxxl", .german, applyStarter: true)
        finish("largest text")
    }

    /// Landscape on the small iPhone (the app allows it): 375 pt of height for everything.
    func test4_Landscape() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test4")
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        sleep(2)
        walk("landscape", .german, short: true)
        finish("landscape")
    }

    /// Increase Contrast and Reduce Transparency (switched on by the workflow before this test
    /// runs on its own), light and dark: the high-contrast colour variants must hold everywhere.
    func test5_IncreasedContrastAndReducedTransparency() {
        continueAfterFailure = true
        launch()
        onboardAndSeed(checking: false)
        walk("contrast light", .german, short: true)
        launch(dark: true)
        walk("contrast dark", .german, short: true)
        finish("increased contrast")
    }

    // MARK: Walk

    /// Overview, suggestions, one suggestion, the starter plan, atlas and share image, library,
    /// albums, search and settings; `short` leaves out the lower halves and the side screens.
    private func walk(_ tag: String, _ w: Words, english: Bool = false, applyStarter: Bool = false, short: Bool = false) {
        let overview = tabButton(w.overviewTab)
        if overview.waitForExistence(timeout: 20) { overview.tap() }
        sleep(2)
        check("\(tag) overview", english: english)
        if !short {
            app.swipeUp(); app.swipeUp(); sleep(1)
            check("\(tag) overview lower", english: english)
            app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(1)
        }

        // Suggestions and one suggestion
        if tap(app.buttons.matching(NSPredicate(format: "label MATCHES %@", w.reviewSuggestions)).firstMatch, "\(tag) open suggestions", timeout: 20) {
            sleep(1)
            check("\(tag) suggestions", english: english)
            // A List only creates the rows on screen; at the largest text size the first row
            // starts below the fold.
            let row = suggestionRow(w.rowMarker)
            var swipes = 0
            while !row.exists && swipes < 6 { app.swipeUp(); swipes += 1; sleep(1) }
            if tap(row, "\(tag) open suggestion", timeout: 10) {
                let detailShown = app.navigationBars[w.suggestionTitle].waitForExistence(timeout: 5)
                sleep(1)
                check("\(tag) suggestion detail", english: english)
                if !short {
                    app.swipeUp(); sleep(1)
                    check("\(tag) suggestion detail lower", english: english)
                }
                back("\(tag) suggestion detail", confirmed: detailShown); sleep(1)
            }
            back("\(tag) suggestions", confirmed: false); sleep(1)
        }

        // The starter set opens the plan; going back selects nothing. Once it has been applied
        // (test 3) the card is gone.
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", w.starterPattern)).firstMatch
        if !starter.waitForExistence(timeout: 8) {
            print("UI_STEP_SKIPPED \(tag) starter plan (no starter set on the overview)")
        } else if tap(starter, "\(tag) open starter plan", timeout: 10) {
            let planShown = app.navigationBars[w.planTitle].waitForExistence(timeout: 20)
            if planShown {
                sleep(2)
                check("\(tag) plan", english: english)
                if !short {
                    app.swipeUp(); app.swipeUp(); sleep(1)
                    check("\(tag) plan lower", english: english)
                }
                if applyStarter, tap(button(w.applyNow), "\(tag) apply plan", timeout: 30) {
                    // The sorting show; with Reduce Motion one album at a time, cross-faded.
                    usleep(900_000); shot("a11y-\(slug(tag))-sorting-show-1")
                    usleep(1_500_000); shot("a11y-\(slug(tag))-sorting-show-2")
                    if button(w.undo).waitForExistence(timeout: 600) {
                        sleep(2)
                        check("\(tag) result", english: english)
                        let receipt = app.buttons["result.receipt"]
                        if tap(receipt, "\(tag) open receipt", timeout: 10),
                           opened(app.navigationBars[w.receiptTitle], "\(tag) receipt") {
                            sleep(2)
                            check("\(tag) receipt", english: english)
                            back("\(tag) receipt", confirmed: true); sleep(1)
                        }
                    } else {
                        XCTFail("The starter plan did not finish")
                    }
                }
            }
            back("\(tag) starter plan", confirmed: planShown); sleep(2)
        }

        // Travel atlas and the share image
        if tap(button(w.atlas), "\(tag) open atlas", timeout: 20), opened(app.navigationBars[w.atlas], "\(tag) atlas") {
            sleep(3)
            check("\(tag) atlas", english: english)
            if !short {
                app.swipeUp(); app.swipeUp(); sleep(1)
                check("\(tag) atlas lower", english: english)
                // A country: its photo colours sit behind the title and caption.
                let country = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", w.country)).firstMatch
                // Its screen is called by the country's name.
                if tap(country, "\(tag) open country", timeout: 10), opened(app.navigationBars[w.country], "\(tag) country") {
                    sleep(2)
                    check("\(tag) country", english: english)
                    back("\(tag) country", confirmed: true); sleep(1)
                }
                app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(1)
                if tap(app.buttons[w.shareAtlas], "\(tag) share atlas", timeout: 5) {
                    sleep(3)
                    check("\(tag) share sheet", english: english)
                    tap(button(w.done), "\(tag) close share")
                    sleep(2)
                }
            }
            back("\(tag) atlas", confirmed: true); sleep(1)
        }

        // Tabs
        if tap(tabButton(w.libraryTab), "\(tag) library tab") {
            sleep(2)
            check("\(tag) library", english: english)
            // Design review W11/W12: the photo viewer (system toolbar) and its info sheet.
            let photo = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
            if !short, photo.waitForExistence(timeout: 5), tap(photo, "\(tag) open photo", timeout: 5) {
                sleep(2)
                check("\(tag) photo viewer", english: english)
                if tap(app.buttons["viewer.info"], "\(tag) photo info", timeout: 5) {
                    sleep(1)
                    check("\(tag) photo info", english: english)
                    tap(app.buttons["detail.close"], "\(tag) close photo info")
                    sleep(1)
                }
                tap(app.buttons["viewer.close"], "\(tag) close photo", timeout: 5)
                sleep(1)
            }
        }
        if tap(tabButton(w.albumsTab), "\(tag) albums tab") {
            sleep(2)
            check("\(tag) albums", english: english)
        }
        // Settings
        if tap(tabButton(w.overviewTab), "\(tag) back to overview"), tap(app.buttons[w.settings], "\(tag) settings") {
            sleep(2)
            check("\(tag) settings", english: english)
            if !short {
                // Design review W16: history and undo on their own screen. Opened first, from
                // the top of the list: after scrolling down and back the first row was not in
                // the tree again (UI run 43773339053, "history" missing).
                if tap(app.buttons["settings.history"], "\(tag) history", timeout: 5),
                   opened(app.navigationBars[w.historyTitle], "\(tag) history") {
                    sleep(1)
                    check("\(tag) history", english: english)
                    back("\(tag) history", confirmed: true); sleep(1)
                }
                let list = app.collectionViews.firstMatch
                (list.exists ? list : app).swipeUp(); (list.exists ? list : app).swipeUp(); sleep(1)
                check("\(tag) settings lower", english: english)
            }
            tap(button(w.done), "\(tag) close settings")
            sleep(1)
        }

        // Search last: the search tab focuses its field, and the keyboard covers the tab bar.
        if !short, tap(searchTabButton(), "\(tag) search tab") {
            sleep(2)
            check("\(tag) search", english: english)
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText(w.searchQuery)
                sleep(3)
                // The keyboard covers the lower half; the results and chips above it count.
                check("\(tag) search results", english: english)
                field.typeText("\n")
                sleep(1)
            }
        }
    }

    // MARK: Checks

    /// Screenshot, audit and tree checks for what is on screen now.
    private func check(_ screen: String, english: Bool = false) {
        // Let a scroll come to rest, so screenshot, tree and audit see the same positions.
        sleep(1)
        shot("a11y-" + slug(screen))
        let chrome = chromeFrames()
        UITestOnboarding.clock("check start \(screen)")
        inspectTree(screen, chrome: chrome, english: english)
        audit(screen, chrome: chrome)
        UITestOnboarding.clock("check end \(screen)")
        let failures = auditFailures + screenFailures
        if failures.isEmpty {
            print("A11Y_SCREEN_OK \(screen)")
        } else {
            print("A11Y_SCREEN_FAILED \(screen) \(failures.count)")
            XCTFail("\(screen): \(failures.count) accessibility finding(s): " + failures.prefix(8).joined(separator: " · "))
        }
        auditFailures = []
        screenFailures = []
    }

    /// Frames of the system's Liquid Glass chrome: navigation bars, tab bar, toolbars and
    /// search fields (in iOS 26 a sheet's search field floats at the bottom like a toolbar).
    private func chromeFrames() -> [CGRect] {
        var frames: [CGRect] = []
        // The keyboard covers content like a bar does.
        for query in [app.navigationBars, app.tabBars, app.toolbars] {
            for element in query.allElementsBoundByIndex where element.exists {
                // The scroll edge effect softens content for a few points beyond the bar.
                frames.append(element.frame.insetBy(dx: 0, dy: -12))
            }
        }
        // The status bar: content scrolling under it (onboarding) shares its pixels with the clock.
        let top = app.frame
        frames.append(CGRect(x: top.minX, y: top.minY, width: top.width, height: top.height > 800 ? 54 : 20))
        for keyboard in app.keyboards.allElementsBoundByIndex where keyboard.exists {
            // The word suggestions sit in a 44 pt strip above the keyboard's frame.
            let frame = keyboard.frame
            frames.append(CGRect(x: frame.minX, y: frame.minY - 48, width: frame.width, height: frame.height + 48))
        }
        for field in app.searchFields.allElementsBoundByIndex where field.exists {
            frames.append(field.frame.insetBy(dx: -8, dy: -8))
        }
        // Only real bars count: at the top or bottom edge and not taller than the keyboard
        // (45 % of the screen). Anything else would exempt the middle of the screen.
        let screen = app.frame
        let bars = frames.filter { frame in
            !frame.isEmpty && frame.height < screen.height * 0.45
                && (frame.minY <= screen.minY + screen.height * 0.3 || frame.maxY >= screen.maxY - screen.height * 0.3)
        }
        let described = frames.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: "; ")
        print("A11Y_CHROME \(frames.count) frames, \(bars.count) used: \(described)")
        return bars
    }

    private func audit(_ screen: String, chrome: [CGRect]) {
        let bounds = app.frame
        // A screen with a bar over scrolling content (see the class comment).
        let barOverContent = app.tabBars.firstMatch.exists || app.toolbars.firstMatch.exists || app.searchFields.firstMatch.exists
        // An element that changes while the audit reads the screen makes XCTest record
        // "Failed to get matching snapshot"; that says nothing about the app.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("Failed to get matching snapshot") }
        for attempt in 1...2 {
            var finished = false
            XCTExpectFailure("The screen changed during the accessibility audit", options: options) {
                do {
                    try app.performAccessibilityAudit(for: Self.failingAuditTypes) { issue in
                        self.record(issue, screen: screen, chrome: chrome, bounds: bounds, barOverContent: barOverContent)
                        return true // handled here: failures are collected and reported per screen
                    }
                    finished = true
                } catch {
                    print("A11Y_AUDIT_ERROR \(screen) attempt \(attempt) \(error.localizedDescription)")
                }
            }
            if finished {
                confirmContrast(screen)
                return
            }
            auditFailures = []
            pendingContrast = []
            sleep(2)
        }
        // "Audit failed to complete in time" twice: say so loudly, the tree checks still ran.
        print("A11Y_WARN \(screen) | audit | did not complete, screen not audited")
    }

    /// "Contrast failed" must repeat in a second contrast audit two seconds later to count.
    /// In UI run 2 and 3 the first audit reported black titles and buttons on white (over
    /// 15:1) on screens that had just scrolled: it measured them mid-movement. Text that
    /// really lacks contrast fails both times.
    private func confirmContrast(_ screen: String) {
        guard !pendingContrast.isEmpty else { return }
        let pending = pendingContrast
        pendingContrast = []
        sleep(2)
        var again = Set<String>()
        do {
            try app.performAccessibilityAudit(for: .contrast) { issue in
                if !issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
                    again.insert(issue.element?.label ?? "-")
                }
                return true
            }
        } catch {
            // Without a second measurement the first one stands.
            print("A11Y_AUDIT_ERROR \(screen) contrast confirmation \(error.localizedDescription)")
            again = Set(pending.map { $0.label })
        }
        for finding in pending {
            if again.contains(finding.label) {
                print("A11Y_FAIL \(finding.line)")
                print("A11Y_DETAIL \(screen) | \(finding.detail)")
                auditFailures.append("contrast '\(finding.label.prefix(40))'")
            } else {
                print("A11Y_WARN \(finding.line) | did not repeat in a second contrast audit (measured mid-movement)")
            }
        }
    }

    private func record(_ issue: XCUIAccessibilityAuditIssue, screen: String, chrome: [CGRect], bounds: CGRect, barOverContent: Bool) {
        let type = issue.auditType
        let summary = issue.compactDescription
        var reason: String?
        var where_ = "-"
        var label = "-"
        if let element = issue.element {
            let frame = element.frame
            label = element.label
            where_ = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) type \(element.elementType.rawValue) id '\(element.identifier)'"
            // The same element before the audit: same label, column and size (a scroll only moves it up or down).
            let before = (framesBeforeAudit[label] ?? []).filter {
                abs($0.minX - frame.minX) < 1 && abs($0.width - frame.width) < 1 && abs($0.height - frame.height) < 1
            }
            let frames = [frame] + before
            if type == .contrast && summary.localizedCaseInsensitiveContains("nearly") {
                reason = "contrast nearly passed (system secondary text)"
            } else if type == .contrast && !element.isEnabled {
                reason = "disabled control (WCAG exempt)"
            } else if frames.contains(where: { frame in chrome.contains { $0.intersects(frame) } }) {
                reason = "on or under a system Liquid Glass bar"
            } else if Self.isEmojiOnly(label) {
                reason = "emoji only (a flag is a picture, not text)"
            } else if pictureFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) }) {
                reason = "inside a labelled picture (share image preview)"
            } else if type == .textClipped && !accessibilitySize {
                reason = "text clipped at a standard size (the audit enlarges text; the largest-size run decides)"
            } else if type == .textClipped && frame.height > Self.wrappedHeight {
                reason = "text clipped on wrapped text (every line shown in the screenshot)"
            } else if frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1
                        && (frame.minY < bounds.minY || frame.maxY > bounds.maxY) {
                reason = "cut by the top or bottom edge of the screen (scrolled)"
            }
        } else if type == .textClipped {
            reason = "text clipped, no element (text inside a combined row)"
        } else if type == .contrast {
            if summary.localizedCaseInsensitiveContains("nearly") {
                reason = "contrast nearly passed (system secondary text), no element"
            } else if barOverContent {
                reason = "no element, screen has content passing under a system bar"
            }
        }
        let line = "\(screen) | audit \(Self.name(of: type)) | \(summary) | label '\(label)' | \(where_)"
        if let reason {
            print("A11Y_WARN \(line) | \(reason)")
        } else if type == .contrast {
            pendingContrast.append((label, line, String(issue.detailedDescription.prefix(400))))
        } else {
            print("A11Y_FAIL \(line)")
            print("A11Y_DETAIL \(screen) | \(String(issue.detailedDescription.prefix(400)))")
            auditFailures.append("\(Self.name(of: type)) '\(label.prefix(40))'")
        }
    }

    /// Taller than two lines of body text at the largest accessibility size: text that wraps.
    private static let wrappedHeight: CGFloat = 100

    /// Flags and other emoji, without letters or digits.
    private static func isEmojiOnly(_ label: String) -> Bool {
        let scalars = label.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        return !scalars.isEmpty && scalars.allSatisfy { $0.properties.isEmojiPresentation || (0x1F1E6...0x1F1FF).contains($0.value) || $0.properties.isEmojiModifier || $0.value == 0xFE0F || $0.value == 0x200D }
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .textClipped: "textClipped"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "elementDescription"
        case .dynamicType: "dynamicType"
        case .elementDetection: "elementDetection"
        case .trait: "trait"
        default: "type \(type.rawValue)"
        }
    }

    /// Top folders the German first run created in the library: data in the English run.
    private static let germanFolderNames: Set<String> = ["Länder", "Reisen", "Orte", "Länder und Orte", "Themen", "Dokumente"]

    /// Words that only a German interface shows (the English run must show none of them).
    private static let germanWords: Set<String> = [
        "und", "oder", "nicht", "der", "die", "das", "Der", "Die", "Das", "dein", "deine", "deinen", "deiner", "deinem",
        "Dein", "Deine", "mit", "für", "Alle", "alle",
        "werden", "wird", "ist", "sind", "jetzt", "noch", "Fotos", "Alben", "Aufnahmen", "Vorschläge", "Vorschlag",
        "Einstellungen", "Übersicht", "Mediathek", "Reisen", "Länder", "Orte", "Städte", "anlegen", "prüfen",
        "Zurück", "Fertig", "Weiter", "Abbrechen", "Schließen", "Analyse", "sortiert", "Sortiert", "Jahre", "Tage",
    ]

    /// One snapshot of the accessibility tree: labels, placeholders, untranslated words, text
    /// running off the side, and (reported only) small targets and overlapping text.
    private func inspectTree(_ screen: String, chrome: [CGRect], english: Bool) {
        let root: any XCUIElementSnapshot
        do {
            root = try app.snapshot()
        } catch {
            print("A11Y_WARN \(screen) | tree | no snapshot: \(error.localizedDescription)")
            return
        }
        let bounds = root.frame
        var texts: [(label: String, frame: CGRect)] = []
        var seen = 0
        framesBeforeAudit = [:]
        pictureFrames = []

        func fail(_ kind: String, _ label: String, _ frame: CGRect) {
            print("A11Y_FAIL \(screen) | \(kind) | label '\(label)' | \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            screenFailures.append("\(kind) '\(label.prefix(40))'")
        }

        func visit(_ node: any XCUIElementSnapshot) {
            seen += 1
            let frame = node.frame
            let visible = !frame.isEmpty && frame.intersects(bounds)
            let inChrome = chrome.contains { $0.intersects(frame) }
            let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = node.elementType
            if !label.isEmpty { framesBeforeAudit[label, default: []].append(frame) }
            if type == .image && !label.isEmpty && frame.width >= 80 && frame.height >= 80 {
                pictureFrames.append(frame)
            }
            if visible {
                if label.contains("%lld") || label.contains("%@") || label.contains("%ld") {
                    fail("format placeholder", label, frame)
                }
                if english {
                    // Folder paths ("Albumist › Reisen › 2024") are names of folders that exist in
                    // the library, made in the German first run: data, not interface text.
                    // So are the top folders standing alone as a value ("Folder, Länder").
                    let interface = label.components(separatedBy: ", ")
                        .filter { !$0.contains("›") && !Self.germanFolderNames.contains($0) }.joined(separator: " ")
                    let words = interface.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
                    if let word = words.first(where: { Self.germanWords.contains($0) }) {
                        fail("German word '\(word)' in English UI", label, frame)
                    }
                }
            }
            if visible && !inChrome {
                switch type {
                case .button, .link, .switch, .toggle:
                    if (label.isEmpty && (type == .button || type == .link)) || label == "-" || Self.looksLikeSymbolName(label) {
                        fail("no VoiceOver label (\(type.rawValue))", label, frame)
                    }
                    if (type == .button || type == .link) && node.isEnabled && (frame.height < 43.5 || frame.width < 43.5) {
                        print("A11Y_WARN \(screen) | small target \(Int(frame.width))x\(Int(frame.height)) | label '\(label)'")
                    }
                case .staticText:
                    texts.append((label, frame))
                    // Wider than the screen or starting off its side: the layout does not fit.
                    if frame.minX < bounds.minX - 1 || frame.maxX > bounds.maxX + 1 {
                        fail("text runs off the side of the screen", label, frame)
                    }
                default:
                    break
                }
            }
            for child in node.children { visit(child) }
        }
        visit(root)

        // Overlapping texts (reported): two labels drawn over each other.
        for i in texts.indices {
            for j in texts.indices where j > i {
                let overlap = texts[i].frame.intersection(texts[j].frame)
                guard !overlap.isNull, overlap.width > 4, overlap.height > 4 else { continue }
                let smaller = min(texts[i].frame.width * texts[i].frame.height, texts[j].frame.width * texts[j].frame.height)
                if overlap.width * overlap.height > 0.3 * smaller {
                    print("A11Y_WARN \(screen) | overlapping text | '\(texts[i].label.prefix(40))' and '\(texts[j].label.prefix(40))'")
                }
            }
        }
        print("A11Y_TREE \(screen) \(seen) elements, \(texts.count) texts")
    }

    /// "chevron.right", "square.and.arrow.up": a symbol name read out instead of a label.
    private static func looksLikeSymbolName(_ label: String) -> Bool {
        guard label.contains("."), !label.contains(" "), label == label.lowercased() else { return false }
        let parts = label.split(separator: ".")
        let plain = parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { character in character.isLetter || character.isNumber } }
        return parts.count >= 2 && plain && label.contains(where: { character in character.isLetter })
    }

    private func finish(_ test: String) {
        print("A11Y_TEST_DONE \(test)")
    }

    // MARK: Helpers (copied from SortlyFlowUITests, which another change owns)

    private func launch(english: Bool = false, textSize: String? = nil, dark: Bool = false) {
        // The app's stalls and stacks of each launch (UITestStalls; the contrast run's long
        // stalls before "close settings" had no stack, UI run 44012530107).
        UITestStalls.report()
        if !stallsReportedAtEnd {
            stallsReportedAtEnd = true
            addTeardownBlock { UITestStalls.report() }
        }
        app = XCUIApplication()
        var arguments = ["-SortlyUITestUnlocked"] + UITestStalls.arguments(besides: [])
        arguments += english ? ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] : ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        accessibilitySize = textSize?.contains("Accessibility") ?? false
        if dark { arguments.append("-SortlyUITestDark") }
        app.launchArguments = arguments
        app.launch()
    }

    private var stallsReportedAtEnd = false

    private func slug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private func suggestionRow(_ marker: String) -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", marker)).element(boundBy: 0)
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func searchTabButton() -> XCUIElement {
        for label in ["Suchen", "Suche", "Search"] where app.tabBars.buttons[label].exists {
            return tabButton(label)
        }
        return app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
    }

    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            sleep(1)
            tries += 1
        }
        return button
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("a11y-x-missing-" + slug(step))
            XCTFail("Missing: \(step)")
            return false
        }
        // Content under the tab bar also counts as hittable, but a tap there lands on the bar
        // (contrast run 43918684247: the atlas teaser sat under the tab bar on a fresh simulator,
        // the tap opened nothing, and `back()` then tapped the overview's settings button). The
        // bar takes taps a little above its frame too: run 43945035122 tapped the teaser 6 pt
        // above it (centre y 578, bar from 584) and the atlas did not open, so the centre has
        // to be clear of the bar by the scroll edge it softens (see `chromeFrames`) and more.
        let bar = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        var swipes = 0
        while swipes < 10 {
            let underBar = bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
            let underTabs = tabs.exists && !tabs.frame.contains(element.frame) && element.frame.midY > tabs.frame.minY - 24
            if underBar { app.swipeDown() } else if underTabs || !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        if tabs.exists, swipes > 0 || element.frame.maxY > tabs.frame.minY {
            print("UI_FACT tap \(step): element \(element.frame), tab bar \(tabs.frame), \(swipes) swipes")
        }
        UITestOnboarding.clock("tap \(step)")
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    /// A screen that was tapped open is there. Only such a screen is left with `back()`: on the
    /// overview the first button of the navigation bar is the settings button, and `back()`
    /// there opened the settings in the middle of the walk (contrast run 43918684247).
    private func opened(_ screen: XCUIElement, _ step: String) -> Bool {
        guard screen.waitForExistence(timeout: 10) else {
            print("UI_STEP_MISSING \(step) opened")
            shot("a11y-x-missing-" + slug("\(step) opened"))
            XCTFail("Not opened: \(step)")
            return false
        }
        return true
    }

    /// Taps the back button. Never on the overview, whose first bar button is the settings
    /// button: after the suggestions list had closed by itself, `back()` opened the settings,
    /// and every later step of the contrast walk ran on the settings sheet until "settings"
    /// tapped its "Fertig" (contrast run 44038288087: "close settings" missing, the screenshots
    /// show the sheet). Told by the bar's title, not the button's label: the back button of a
    /// screen opened from the settings is called "Einstellungen" too (UI run 44055738268).
    /// `confirmed`: the walk saw the screen open (its bar or `opened`); finding the overview
    /// instead means the screen closed by itself, which is a finding. Unconfirmed screens (only
    /// the tap is known) are left alone there.
    private func back(_ step: String, confirmed: Bool) {
        let bar = app.navigationBars.firstMatch
        let first = bar.buttons.element(boundBy: 0)
        guard first.exists else { return }
        if ["Übersicht", "Overview"].contains(bar.identifier) {
            print("UI_FACT back: no back button, the overview is showing (\(step))")
            shot("a11y-x-back-on-overview-" + slug(step))
            if confirmed { XCTFail("Closed by itself before going back: \(step)") }
            return
        }
        first.tap()
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let small = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = small.jpegData(compressionQuality: 0.55) else { return }
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG ui-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    print("UI_STEP_OK system photo alert")
                    return
                }
            }
            if button("Analyse starten").exists { return }
            usleep(500_000)
        }
        print("UI_STEP_MISSING system photo alert")
    }

    /// The notification question comes a while after "Analyse starten" (never within the 8 s
    /// this waited before: no run printed "notification alert"), and until it is answered it
    /// takes every touch: in UI runs 44032718289 and 44038288087 it still covered the overview
    /// when "Beispiel-Mediathek anlegen" was tapped, and no demo library was made. Looked for in
    /// the springboard and in the app for up to 20 s; when it never came, that is said.
    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for source in [springboard, app] {
                for label in ["Erlauben", "Allow"] where source.buttons[label].exists {
                    source.buttons[label].tap()
                    print("UI_STEP_OK notification alert")
                    return
                }
            }
            usleep(500_000)
        }
        print("UI_FACT no notification alert within 20 s")
    }

    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            let asked = Date()
            streak = condition() ? streak + 1 : 0
            UITestOnboarding.reportSlowCheck(since: asked)
            if streak >= stableChecks { return true }
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    /// The Pause button first: while the analysis runs it is there, and one query answers.
    /// Every other query reads the whole screen, and during the analysis such a read held the
    /// app's main thread for 16 to 48 s (UI run 43979263666: each long stall began within half
    /// a second of a check of this wait).
    private var analysisIdle: Bool {
        !app.buttons["Pause"].exists && (anything("Fotos analysiert").exists || anything("Analyse aktuell").exists || anything("Analyse fertig").exists)
    }
}
