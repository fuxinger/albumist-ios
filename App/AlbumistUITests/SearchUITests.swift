import XCTest
import UIKit

/// Search on the seeded demo library: realistic queries, the chips that show how each one
/// was understood, and results or a helpful empty state.
///
/// The class is named so it runs after `AlbumistFlowUITests` (XCTest runs classes in
/// alphabetical order): the full flow seeds and analyses the demo library first and keeps
/// its onboarding screenshots. Run alone, this test does the onboarding and seeding itself.
/// Steps print `UI_STEP_OK` / `UI_STEP_MISSING`, chips `UI_FACT`, screenshots `PREVIEW_JPEG`.
@MainActor
final class AlbumistSearchUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers (as in AlbumistFlowUITests)

    private func launch(_ extra: [String] = []) {
        // UITestAppEnd.launch ends the app of the last launch first.
        app = XCUIApplication()
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked"]
            + UITestStalls.arguments(besides: extra) + extra
        UITestAppEnd.launch(app)
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The search tab (`Tab(role: .search)`): the system's round button at the bar's end
    /// (`UITestScreens.Search`), never another tab.
    private func searchTabButton() -> XCUIElement {
        UITestScreens.Search.button(app, tabButton: tabButton)
    }

    /// A tab bar button; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            // The bar expands after the swipe: on as soon as the button can be tapped, else the
            // next try after the old second.
            _ = UITestWait.holds(timeout: 1) { button.exists && button.isHittable }
            tries += 1
        }
        return button
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
            XCTFail("Missing: \(step)")
            return false
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
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

    private func audit(_ screen: String) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("Failed to get matching snapshot") }
        XCTExpectFailure("The screen changed during the accessibility audit", options: options) {
            do {
                try app.performAccessibilityAudit { issue in
                    let element = issue.element
                    let frame = element.map { f in "\(Int(f.frame.minX)),\(Int(f.frame.minY)) \(Int(f.frame.width))x\(Int(f.frame.height))" } ?? "-"
                    print("A11Y_ISSUE \(screen) | type \(issue.auditType.rawValue) | \(issue.compactDescription) | label '\(element?.label ?? "-")' | \(element?.elementType.rawValue ?? 0) | id '\(element?.identifier ?? "-")' | \(frame)")
                    return true
                }
                print("A11Y_AUDIT_DONE \(screen)")
            } catch {
                print("A11Y_AUDIT_ERROR \(screen) \(error)")
            }
        }
    }

    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            streak = condition() ? streak + 1 : 0
            if streak >= stableChecks { return true }
            // pacing: the poll's interval, kept: "three checks in a row" means the state held for
            // about four seconds (the analysis idle, not only between two batches).
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    /// The start page's line about the analysis, and no "Pause" (`UITestScreens.Analysis`).
    private var analysisIdle: Bool {
        UITestScreens.Analysis.isIdle(app)
    }

    // MARK: Search helpers

    private func search(_ identifier: String, containing text: String? = nil) -> XCUIElement {
        let all = app.descendants(matching: .any).matching(identifier: identifier)
        guard let text else { return all.firstMatch }
        return all.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func chips() -> [String] {
        app.descendants(matching: .any).matching(identifier: "search.token").allElementsBoundByIndex.map(\.label)
            + app.descendants(matching: .any).matching(identifier: "search.ignored").allElementsBoundByIndex.map { "? " + $0.label }
    }

    /// Replaces the text in the field (the caret stays at its end while typing; a tap on
    /// a completion may have taken the focus away).
    private func replaceQuery(in field: XCUIElement, with text: String) {
        if !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) { field.tap() }
        let current = (field.value as? String) ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    /// Types `query`, waits for a chip containing each of `expected`, and reports what the
    /// search understood. Returns whether every chip appeared.
    @discardableResult
    private func check(_ query: String, in field: XCUIElement, expect expected: [String], shotName: String) -> Bool {
        replaceQuery(in: field, with: query)
        var found = true
        for label in expected {
            let chip = search("search.token", containing: label)
            let ok = chip.waitForExistence(timeout: 15)
            print(ok ? "UI_STEP_OK search '\(query)' chip \(label)" : "UI_STEP_MISSING search '\(query)' chip \(label)")
            XCTAssertTrue(ok, "Search '\(query)' shows no chip '\(label)' (chips: \(chips()))")
            found = found && ok
        }
        // Chips, count and results come in one update (SearchView); the picture once the
        // results have stopped moving under the chips.
        UITestWait.screenAtRest(app, "search '\(query)' results at rest")
        let count = search("search.count")
        print("UI_FACT search '\(query)' chips \(chips()) | \(count.exists ? count.label : "no count")")
        shot(shotName)
        return found
    }

    // MARK: Test

    func testSearchUnderstandsRealQueries() {
        continueAfterFailure = true
        launch()

        // Fresh simulator (run alone): onboarding and the demo library first. One wait for the
        // first screen (the app picks it once when it has loaded, `AppModel.phase`): waiting 15 s
        // for the welcome screen alone ran out on every simulator that was onboarded already.
        // After "Los geht’s" only the access page (design wave 1): the analysis starts by itself
        // with access.
        let welcome = app.buttons["onboarding.letsGo"]
        _ = UITestWait.holds(timeout: 15) {
            welcome.exists || app.tabBars.firstMatch.exists || app.buttons["access.continue"].exists
        }
        if welcome.exists {
            tap(welcome, "welcome")
            let tabs = UITestOnboarding.passAccessPage(app)
            print(tabs ? "UI_STEP_OK access page" : "UI_STEP_MISSING access page")
            XCTAssertTrue(tabs, "The onboarding did not reach the tabs after the access page")
        }
        let demo = button("Beispiel-Mediathek anlegen")
        // The demo card is drawn in the same body as the start page's title (OverviewView, a
        // plain VStack), so once "Vorschläge" is there the card is there too or does not come:
        // the old 10 s only when neither shows.
        let startPage = app.navigationBars["Vorschläge"]
        _ = UITestWait.holds(timeout: 10) { demo.exists || startPage.exists }
        if demo.exists {
            tap(demo, "seed demo library")
            waitStable("demo library created", timeout: 600) {
                !anything("Beispielfotos werden angelegt").exists && !button("Beispiel-Mediathek anlegen").exists
            }
        }
        if app.tabBars.buttons["Vorschläge"].exists { tabButton("Vorschläge").tap() }
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")

        guard tap(searchTabButton(), "search tab") else { return }
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 10) else {
            XCTFail("No search field")
            return
        }
        // Starting points come from the library (or examples before the analysis).
        let start = search("search.example")
        let started = start.waitForExistence(timeout: 10)
        print(started ? "UI_STEP_OK search starting points" : "UI_STEP_MISSING search starting points")
        XCTAssertTrue(started, "The empty search shows no starting points")
        print("UI_FACT search starting points \(app.descendants(matching: .any).matching(identifier: "search.example").allElementsBoundByIndex.map(\.label))")
        // Design wave 3 (DS-13): after the analysis the starting points are photo tiles as in the
        // tab "Alben": a name with "N Fotos" as its value, two side by side (well over 140 pt
        // each; the word chips for papers are narrower), at most six, never "Live Photos" or
        // "HDR". They are worked out after the page opens, so the first ones may be chips.
        let counted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value MATCHES %@",
                                                                             "search.example", "[0-9.]+ Fotos?"))
        func tiles() -> [XCUIElement] { counted.allElementsBoundByIndex.filter { $0.frame.width >= 140 } }
        let tiled = UITestWait.until("photo tiles among the search's starting points", timeout: 15) { !tiles().isEmpty }
        let shown = tiles()
        print("UI_FACT search tiles \(shown.map { "\($0.label) | \(($0.value as? String) ?? "")" })")
        XCTAssertTrue(tiled, "The empty search shows no photo tiles after the analysis")
        XCTAssertLessThanOrEqual(shown.count, 6, "More than six tiles in the empty search")
        XCTAssertFalse(shown.contains { ["Live Photos", "HDR"].contains($0.label) }, "Live Photos or HDR offered as a starting point")
        shot("s0-search-start")
        field.tap()

        // 1. Country and year: the Florence trip of 2022.
        check("Italien 2022", in: field, expect: ["Italien", "2022"], shotName: "s1-italien-2022")
        let hits = search("search.result").waitForExistence(timeout: 10)
        print(hits ? "UI_STEP_OK search results Italien 2022" : "UI_STEP_MISSING search results Italien 2022")
        XCTAssertTrue(hits, "Italien 2022 found nothing")
        XCTAssertTrue(search("search.count").exists, "No hit count for Italien 2022")
        audit("search chips")

        // 2. Country and month ("Portugal April") left the UI test: the chips look as in 1, and
        // what such a query finds is checked in SearchQuerySetTests ("Rom Juli 2025").

        // 3. A typo is corrected and the correction is shown.
        check("Frankriech", in: field, expect: ["Frankreich"], shotName: "s3-typo")
        let corrected = search("search.token", containing: "Frankriech").exists
        print(corrected ? "UI_STEP_OK typo shown as corrected" : "UI_STEP_MISSING typo shown as corrected")
        XCTAssertTrue(search("search.result").waitForExistence(timeout: 10), "Frankriech found nothing")

        // 4. Nothing matches both terms: the year is left out, and the page says so.
        check("Japan 2019", in: field, expect: ["Japan"], shotName: "s4-relaxed")
        let relaxed = search("search.relaxed").waitForExistence(timeout: 10)
        print(relaxed ? "UI_STEP_OK search relaxed note" : "UI_STEP_MISSING search relaxed note")
        XCTAssertTrue(relaxed, "Japan 2019 does not say that a term was left out")
        XCTAssertTrue(search("search.result").exists, "Japan 2019 shows no photos from Japan")

        // 5. Completion from the library: "Ital" offers Italien.
        replaceQuery(in: field, with: "Ital")
        let suggestion = search("search.suggestion", containing: "Italien")
        if suggestion.waitForExistence(timeout: 10) {
            print("UI_STEP_OK search suggestion Italien")
            // One answer for the word (P3-13): once the search for "Ital" ran (after a pause of
            // 250 ms), nothing beside the completion says "nicht erkannt".
            let notice = search("search.empty").waitForExistence(timeout: 3) || search("search.ignored", containing: "Ital").exists
            print(notice ? "UI_STEP_MISSING search no notice beside the suggestion" : "UI_STEP_OK search no notice beside the suggestion")
            XCTAssertFalse(notice, "\"Ital\" is reported as not recognised beside the completion Italien")
            shot("s5-suggestion")
            suggestion.tap()
            let chip = search("search.token", containing: "Italien").waitForExistence(timeout: 10)
            XCTAssertTrue(chip, "Choosing the suggestion did not search for Italien")
            XCTAssertTrue(search("search.result").waitForExistence(timeout: 10), "The suggestion Italien found nothing")
        } else {
            print("UI_STEP_MISSING search suggestion Italien")
            XCTFail("Typing 'Ital' offers no completion 'Italien'")
        }

        // 6. A word nobody can understand: said plainly, never an unexplained empty page.
        replaceQuery(in: field, with: "xyzzy")
        let ignored = search("search.ignored", containing: "xyzzy").waitForExistence(timeout: 15)
        print(ignored ? "UI_STEP_OK search ignored word" : "UI_STEP_MISSING search ignored word")
        XCTAssertTrue(ignored, "The word that was not understood is not shown")
        let empty = search("search.empty").waitForExistence(timeout: 10)
        print(empty ? "UI_STEP_OK search empty state" : "UI_STEP_MISSING search empty state")
        XCTAssertTrue(empty, "No helpful empty state for a query without results")
        shot("s6-not-understood")

        // Close the keyboard.
        field.typeText("\n")

        // DS-12a: while the search is active iOS folds the other tabs into one button beside its
        // field; leaving the search brings them back. Which tab is chosen then (the one before,
        // with `.searchTabSelection`) is the system's: said, not asserted.
        let left = UITestScreens.Search.leave(app, "search")
        XCTAssertTrue(left, "Leaving the search does not bring the other tabs back")
        let before = app.tabBars.buttons["Vorschläge"]
        let backOnIt = UITestWait.holds(timeout: 3) { before.exists && before.isSelected }
        print("UI_FACT search left, back on \"Vorschläge\": \(backOnIt); tabs \(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        shot("s7-search-left")
    }
}
