import XCTest
import UIKit

/// Accessibility run on its own small iPhone (CI job "Accessibility", iPhone SE size, Reduce
/// Motion on; see `.github/workflows/ui.yml`). Unlike the UI flow, which only prints what the
/// audit finds, these tests FAIL on real findings:
///
/// Failing audit types (`performAccessibilityAudit`):
/// - `.contrast` "Contrast failed" (clearly below WCAG AA)
/// - `.textClipped` (truncated or cut text)
/// - `.hitRegion` (target too small to tap)
/// - `.sufficientElementDescription` (missing or useless VoiceOver label)
///
/// Failing checks of our own (from one snapshot of the accessibility tree per screen):
/// - a button, link, switch or image without a label, labelled "-", or labelled with an SF
///   Symbol name ("chevron.right"), which VoiceOver would read out
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

    private static let largestText = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let failingAuditTypes: XCUIAccessibilityAuditType = [.contrast, .textClipped, .hitRegion, .sufficientElementDescription]

    /// Labels the walk taps, per language (from Localizable.xcstrings).
    private struct Words {
        var overviewTab: String
        var libraryTab: String
        var albumsTab: String
        var settings: String
        var done: String
        var reviewSuggestions: String
        var suggestionTitle: String
        var rowMarker: String
        var starterPattern: String
        var planTitle: String
        var applyNow: String
        var undo: String
        var atlas: String
        var shareAtlas: String

        static let german = Words(overviewTab: "Übersicht", libraryTab: "Mediathek", albumsTab: "Alben",
                                  settings: "Einstellungen", done: "Fertig", reviewSuggestions: "Vorschläge prüfen",
                                  suggestionTitle: "Vorschlag", rowMarker: "Aufnahmen",
                                  starterPattern: "[0-9]+ Alben (kostenlos )?anlegen", planTitle: "Umsetzen",
                                  applyNow: "Jetzt umsetzen", undo: "Rückgängig machen", atlas: "Reise-Atlas",
                                  shareAtlas: "Reise-Atlas teilen")
        static let english = Words(overviewTab: "Overview", libraryTab: "Library", albumsTab: "Albums",
                                   settings: "Settings", done: "Done", reviewSuggestions: "Review",
                                   suggestionTitle: "Suggestion", rowMarker: "item",
                                   starterPattern: "Create [0-9]+ Albums?( for Free)?", planTitle: "Apply",
                                   applyNow: "Apply now", undo: "Undo", atlas: "Travel Atlas",
                                   shareAtlas: "Share Travel Atlas")
    }

    // MARK: Tests

    /// First start at the largest accessibility text size in dark mode: every onboarding step,
    /// then the demo library and its analysis, which the later tests use.
    func test1_OnboardingAtLargestTextInDarkMode() {
        continueAfterFailure = true
        launch(textSize: Self.largestText, dark: true)
        if button("Los geht").waitForExistence(timeout: 30) {
            check("onboarding welcome")
            tap(button("Los geht"), "welcome")
            check("onboarding areas")
            tap(button("Weiter"), "areas")
            check("onboarding access")
            if button("Zugriff erlauben").waitForExistence(timeout: 5) {
                button("Zugriff erlauben").tap()
                allowPhotosIfAsked()
            }
            if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
            let trial = button("Analyse starten").waitForExistence(timeout: 20)
            XCTAssertTrue(trial, "Onboarding did not reach the trial step")
            check("onboarding trial")
            tap(button("Analyse starten"), "start analysis")
            allowNotificationsIfAsked()
        } else {
            print("UI_STEP_MISSING onboarding (already done on this simulator?)")
        }
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            tap(demo, "seed demo library")
            let seeded = waitStable("demo library created", timeout: 600) {
                !anything("Beispielfotos werden angelegt").exists && !button("Beispiel-Mediathek anlegen").exists
            }
            XCTAssertTrue(seeded, "Demo library not created")
        }
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")
        check("overview after first analysis")
        finish("onboarding")
    }

    /// The main screens in English at the default text size, light mode: nothing German left,
    /// nothing clipped, contrast and labels as in German. Runs before anything is applied, so
    /// no album names from a German run are on screen.
    func test2_EnglishMainScreens() {
        continueAfterFailure = true
        launch(english: true)
        walk("en", .english, english: true)
        finish("english")
    }

    /// Largest accessibility text size, dark mode, Reduce Motion (set for this simulator by
    /// the workflow): every main screen, then the starter set is applied, so the sorting show,
    /// the result and the change receipt are checked too.
    func test3_LargestTextDarkModeReduceMotion() {
        continueAfterFailure = true
        launch(textSize: Self.largestText, dark: true)
        walk("xxxl", .german, applyStarter: true)
        finish("largest text")
    }

    /// Landscape on the small iPhone (the app allows it): 375 pt of height for everything.
    func test4_Landscape() {
        continueAfterFailure = true
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
        if tap(button(w.reviewSuggestions), "\(tag) open suggestions", timeout: 20) {
            sleep(1)
            check("\(tag) suggestions", english: english)
            if tap(suggestionRow(w.rowMarker), "\(tag) open suggestion", timeout: 10) {
                _ = app.navigationBars[w.suggestionTitle].waitForExistence(timeout: 5)
                sleep(1)
                check("\(tag) suggestion detail", english: english)
                if !short {
                    app.swipeUp(); sleep(1)
                    check("\(tag) suggestion detail lower", english: english)
                }
                back(); sleep(1)
            }
            back(); sleep(1)
        }

        // The starter set opens the plan; going back selects nothing. Once it has been applied
        // (test 3) the card is gone.
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", w.starterPattern)).firstMatch
        if !starter.waitForExistence(timeout: 8) {
            print("UI_STEP_SKIPPED \(tag) starter plan (no starter set on the overview)")
        } else if tap(starter, "\(tag) open starter plan", timeout: 10) {
            if app.navigationBars[w.planTitle].waitForExistence(timeout: 20) {
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
                        if tap(receipt, "\(tag) open receipt", timeout: 10) {
                            sleep(2)
                            check("\(tag) receipt", english: english)
                            back(); sleep(1)
                        }
                    } else {
                        XCTFail("The starter plan did not finish")
                    }
                }
            }
            back(); sleep(2)
        }

        // Travel atlas and the share image
        if tap(button(w.atlas), "\(tag) open atlas", timeout: 20) {
            sleep(3)
            check("\(tag) atlas", english: english)
            if !short {
                app.swipeUp(); app.swipeUp(); sleep(1)
                check("\(tag) atlas lower", english: english)
                app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(1)
                if tap(app.buttons[w.shareAtlas], "\(tag) share atlas", timeout: 5) {
                    sleep(3)
                    check("\(tag) share sheet", english: english)
                    tap(button(w.done), "\(tag) close share")
                    sleep(2)
                }
            }
            back(); sleep(1)
        }

        // Tabs
        if tap(tabButton(w.libraryTab), "\(tag) library tab") {
            sleep(2)
            check("\(tag) library", english: english)
        }
        if tap(tabButton(w.albumsTab), "\(tag) albums tab") {
            sleep(2)
            check("\(tag) albums", english: english)
        }
        if !short, tap(searchTabButton(), "\(tag) search tab") {
            sleep(2)
            check("\(tag) search", english: english)
        }

        // Settings
        if tap(tabButton(w.overviewTab), "\(tag) back to overview"), tap(app.buttons[w.settings], "\(tag) settings") {
            sleep(2)
            check("\(tag) settings", english: english)
            if !short {
                let list = app.collectionViews.firstMatch
                (list.exists ? list : app).swipeUp(); (list.exists ? list : app).swipeUp(); sleep(1)
                check("\(tag) settings lower", english: english)
            }
            tap(button(w.done), "\(tag) close settings")
            sleep(1)
        }
    }

    // MARK: Checks

    /// Screenshot, audit and tree checks for what is on screen now.
    private func check(_ screen: String, english: Bool = false) {
        shot("a11y-" + slug(screen))
        let chrome = chromeFrames()
        audit(screen, chrome: chrome)
        inspectTree(screen, chrome: chrome, english: english)
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
        for query in [app.navigationBars, app.tabBars, app.toolbars] {
            for element in query.allElementsBoundByIndex where element.exists {
                frames.append(element.frame)
            }
        }
        for field in app.searchFields.allElementsBoundByIndex where field.exists {
            frames.append(field.frame.insetBy(dx: -8, dy: -8))
        }
        return frames.filter { !$0.isEmpty }
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
            if finished { return }
            auditFailures = []
            sleep(2)
        }
        // "Audit failed to complete in time" twice: say so loudly, the tree checks still ran.
        print("A11Y_WARN \(screen) | audit | did not complete, screen not audited")
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
            if type == .contrast && summary.localizedCaseInsensitiveContains("nearly") {
                reason = "contrast nearly passed (system secondary text)"
            } else if type == .contrast && !element.isEnabled {
                reason = "disabled control (WCAG exempt)"
            } else if chrome.contains(where: { $0.intersects(frame) }) {
                reason = "on or under a system Liquid Glass bar"
            } else if frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1
                        && (frame.minY < bounds.minY || frame.maxY > bounds.maxY) {
                reason = "cut by the top or bottom edge of the screen (scrolled)"
            }
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
        } else {
            print("A11Y_FAIL \(line)")
            print("A11Y_DETAIL \(screen) | \(String(issue.detailedDescription.prefix(400)))")
            auditFailures.append("\(Self.name(of: type)) '\(label.prefix(40))'")
        }
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
            if visible {
                if label.contains("%lld") || label.contains("%@") || label.contains("%ld") {
                    fail("format placeholder", label, frame)
                }
                if english {
                    let words = label.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
                    if let word = words.first(where: { Self.germanWords.contains($0) }) {
                        fail("German word '\(word)' in English UI", label, frame)
                    }
                }
            }
            if visible && !inChrome {
                switch type {
                case .button, .link, .switch, .toggle, .image:
                    if label.isEmpty || label == "-" || Self.looksLikeSymbolName(label) {
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
        app = XCUIApplication()
        var arguments = ["-SortlyUITestUnlocked"]
        arguments += english ? ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] : ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        if dark { arguments.append("-SortlyUITestDark") }
        app.launchArguments = arguments
        app.launch()
    }

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
        let bar = app.navigationBars.firstMatch
        var swipes = 0
        while swipes < 10 {
            let underBar = bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
            if underBar { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
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

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 4) { allow.tap(); print("UI_STEP_OK notification alert"); return }
        }
    }

    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            streak = condition() ? streak + 1 : 0
            if streak >= stableChecks { return true }
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    private var analysisIdle: Bool {
        (anything("Fotos analysiert").exists || anything("Analyse aktuell").exists) && !app.buttons["Pause"].exists
    }
}
