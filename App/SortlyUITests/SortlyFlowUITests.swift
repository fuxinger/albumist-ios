import XCTest
import UIKit

/// End-to-end run on the simulator: onboarding, demo library, analysis, accepting
/// suggestions, creating albums, atlas, library, search, settings and undo.
/// Every step prints `UI_STEP_OK` / `UI_STEP_MISSING`, screenshots are printed as
/// `PREVIEW_JPEG ui-…` chunks and accessibility audit findings as `A11Y_ISSUE` lines,
/// so the CI log is the whole report (artifact downloads are not available to us).
/// CI runs groups of these tests on separate simulators, so each test sets itself up:
/// test1_FullFlow goes through the real onboarding and seeding, the others start with
/// `prepare()` (fast start, demo library) and make the state they need themselves.
@MainActor
final class SortlyFlowUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-SortlyUITestUnlocked"] + extra
        app.launch()
    }

    /// The first suggestion row of a list ("57 Fotos" is in every row, never in a button).
    private func suggestionRow() -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos?")).element(boundBy: 0)
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// "16 Vorschläge prüfen", or "1 Vorschlag prüfen" once a single suggestion is left open
    /// (UI run 43796844064: the locked run after a complete flow found only the singular).
    private func reviewSuggestionsButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9.]+ Vorschl(ag|äge) prüfen.*")).firstMatch
    }

    /// The search tab (`Tab(role: .search)`) carries the system's own label.
    private func searchTabButton() -> XCUIElement {
        for label in ["Suchen", "Suche", "Search"] where app.tabBars.buttons[label].exists {
            return tabButton(label)
        }
        return app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
    }

    /// A tab bar button; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            // Minimized bar: scroll back up first, then tap the bar itself to expand it.
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            sleep(1)
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
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-")) // what was on screen instead
            XCTFail("Missing: \(step)")
            return false
        }
        // Scroll the element into view. Content above the screen or under the navigation bar
        // still counts as "hittable" for XCUITest, but a tap there lands on the bar, so it is
        // scrolled back down; content below the screen is scrolled up.
        let bar = app.navigationBars.firstMatch
        var swipes = 0
        while swipes < 8 {
            let underBar = bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
            if underBar { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
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

    private func audit(_ screen: String) {
        // The screen first comes to rest (a ring or count still moving after an analysis):
        // an audit of a screen in motion ends the whole test (see `UITestOnboarding`).
        // One snapshot per check (labels and frames); element addresses differ every time.
        var last = ""
        for _ in 0..<6 {
            let tree = app.debugDescription.replacing(#/0x[0-9a-f]+/#, with: "")
            if tree == last { break }
            last = tree
            sleep(1)
        }
        // An element that changes while the audit reads the screen (a progress bar finishing)
        // makes XCTest record "Failed to get matching snapshot". That says nothing about the app,
        // so only that internal error is expected; every other failure still counts.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("Failed to get matching snapshot") }
        XCTExpectFailure("The screen changed during the accessibility audit", options: options) {
            do {
                try app.performAccessibilityAudit { issue in
                    let element = issue.element
                    let frame = element.map { f in "\(Int(f.frame.minX)),\(Int(f.frame.minY)) \(Int(f.frame.width))x\(Int(f.frame.height))" } ?? "-"
                    print("A11Y_ISSUE \(screen) | type \(issue.auditType.rawValue) | \(issue.compactDescription) | label '\(element?.label ?? "-")' | \(element?.elementType.rawValue ?? 0) | id '\(element?.identifier ?? "-")' | \(frame)")
                    return true // collect everything, the report decides
                }
                print("A11Y_AUDIT_DONE \(screen)")
            } catch {
                print("A11Y_AUDIT_ERROR \(screen) \(error)")
            }
        }
    }

    /// The system photo alert, if the simulator still asks (the CI grant does not always hold).
    /// It can take several seconds to appear while it renders its photo preview.
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
            if button("Analyse starten").exists { return } // access was already granted
            usleep(500_000)
        }
        print("UI_STEP_MISSING system photo alert")
    }

    /// A10: the notification question is declined; the app must work just the same (it only
    /// uses notifications to say that a long analysis finished while it was away).
    private func declineNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            for label in ["Nicht erlauben", "Don’t Allow", "Don't Allow"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
                print("UI_STEP_OK notification alert declined")
                return
            }
            usleep(500_000)
        }
        print("UI_FACT no notification alert")
    }

    /// Polls until `condition` held on `stableChecks` checks in a row (2 s apart).
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

    /// The overview says the analysis is done ("Alle 412 Fotos analysiert", or "Analyse fertig"
    /// right after a long run) and nothing runs (no "Pause").
    private var analysisIdle: Bool {
        (anything("Fotos analysiert").exists || anything("Analyse aktuell").exists || anything("Analyse fertig").exists)
            && !app.buttons["Pause"].exists
    }

    /// The card's progress element (one element, B1): value "120 von 412 Fotos, fertig gegen
    /// 23:40, Schritt 4 von 6, …", as (step, done, total). Read from one snapshot: the element
    /// can go away between an `exists` and reading it, and that read failed test6 (run
    /// 43743310212).
    private func analysisCount() -> (step: Int, done: Int, total: Int)? {
        guard let snapshot = try? app.descendants(matching: .any)["analysis.progress"].firstMatch.snapshot() else { return nil }
        let text = ((snapshot.value as? String) ?? "") + " " + snapshot.label
        let digits = text.replacingOccurrences(of: ".", with: "")
        guard let s = digits.firstMatch(of: #/Schritt (\d+) von \d+/#), let step = Int(s.1),
              let m = digits.firstMatch(of: #/(\d+) von (\d+) /#), let done = Int(m.1), let total = Int(m.2) else { return nil }
        return (step, done, total)
    }

    // MARK: Setup for tests that run alone

    /// Every test except test1 may be the first on a fresh simulator: the onboarding counts as
    /// done (`-SortlyUITestFastStart`), the demo library is created and analysed. On a
    /// simulator where that already happened this only waits until nothing runs.
    private func prepare() {
        let started = Date()
        launch(["-SortlyUITestFastStart"])
        let noAccess = app.buttons["access.continue"]
        if noAccess.waitForExistence(timeout: 5) {
            // Photo access is not granted (the CI grant did not hold, or a test took it away):
            // with the introduction done the app shows "Kein Zugriff auf deine Fotos" (W4).
            noAccess.tap()
            allowPhotosIfAsked()
            // Opened once more, so the fast start runs as with access (demo library, if missing).
            launch(["-SortlyUITestFastStart"])
        } else if button("Los geht").exists {
            // A first start without the fast start's introduction: the real onboarding.
            tap(button("Los geht"), "welcome (prepare)")
            sleep(1)
            tap(app.buttons["Weiter"], "areas (prepare)")
            if noAccess.waitForExistence(timeout: 5) { noAccess.tap(); allowPhotosIfAsked() }
            if app.buttons["Weiter"].waitForExistence(timeout: 3) { app.buttons["Weiter"].tap() }
            tap(button("Analyse starten"), "start analysis (prepare)", timeout: 20)
            declineNotificationsIfAsked()
        }
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 3), !anything("Beispielfotos werden angelegt").exists { demo.tap() }
        let ready = waitStable("demo library analysed", timeout: 900) {
            anything("Fotos analysiert").exists && !app.buttons["Pause"].exists && !anything("Beispielfotos werden angelegt").exists
                && !button("Beispiel-Mediathek anlegen").exists
        }
        print(ready ? "UI_STEP_OK prepared" : "UI_STEP_MISSING prepared")
        XCTAssertTrue(ready, "The demo library was not created and analysed")
        print("UI_TIMING prepare \(Int(Date().timeIntervalSince(started))) s")
    }

    /// Two photos from the library into a new album: opens its plan ("Umsetzen").
    private func openManualPlan(_ title: String) -> Bool {
        guard tap(tabButton("Mediathek"), "library for \(title)") else { return false }
        sleep(2)
        let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
        if !photos.firstMatch.waitForExistence(timeout: 5) { tap(app.buttons["Alle"], "all photos for \(title)", timeout: 5); sleep(2) }
        guard tap(app.buttons["Auswählen"], "select photos for \(title)"), photos.count >= 2 else { return false }
        photos.element(boundBy: 0).tap()
        photos.element(boundBy: 1).tap()
        guard tap(button("Zu Album hinzufügen"), "add to album for \(title)") else { return false }
        var field = app.textFields["Name des neuen Albums"]
        if !field.waitForExistence(timeout: 5) { field = app.textFields.firstMatch }
        guard tap(field, "name for \(title)") else { return false }
        field.typeText(title)
        guard tap(app.buttons["Anlegen"], "create \(title)") else { return false }
        return app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
    }

    /// Opens the plan of the recommended suggestions (or of what is selected already); a new
    /// album of two photos when nothing is recommended.
    private func openRecommendedPlan(_ what: String) -> Bool {
        var apply = button("ausgewählte Alben anlegen")
        // "16 Vorschläge prüfen", or "1 Vorschlag prüfen" when one is left.
        let open = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Vorschl(ag|äge) prüfen")).firstMatch
        if !apply.waitForExistence(timeout: 5), open.waitForExistence(timeout: 10), tap(open, "open suggestions for \(what)") {
            sleep(1)
            if button("empfohlene auswählen").waitForExistence(timeout: 5) { button("empfohlene auswählen").tap(); sleep(1) }
            back(); sleep(1)
            apply = button("ausgewählte Alben anlegen")
        }
        if apply.waitForExistence(timeout: 5) {
            guard tap(apply, "open plan for \(what)", timeout: 20) else { return false }
            sleep(3)
            return true
        }
        print("UI_FACT nothing recommended for \(what): a new album of two photos instead")
        return openManualPlan("Testalbum \(what)")
    }

    /// Applies a plan, so the history holds one; the app is started again afterwards.
    @discardableResult
    private func applyRecommended(_ what: String, relaunchWith extra: [String] = []) -> Bool {
        guard openRecommendedPlan(what), tap(app.buttons["plan.apply"], "apply plan for \(what)", timeout: 30) else { return false }
        let done = button("Rückgängig machen").waitForExistence(timeout: 900)
        print(done ? "UI_STEP_OK plan for \(what) finished" : "UI_STEP_MISSING plan for \(what) finished")
        XCTAssertTrue(done, "The plan for \(what) did not finish")
        sleep(2)
        launch(extra)
        return done
    }

    // MARK: Tests

    /// The demo library is fully readable: the analysis card says "Alle N Fotos analysiert"
    /// and no photo counts as unreadable. UI runs reported "0 von 246 Fotos analysiert" and
    /// "246 Fotos konnten noch nicht gelesen werden" for weeks without failing.
    private func assertEveryPhotoAnalysed(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Alle ", "Fotos analysiert")).firstMatch
        _ = card.waitForExistence(timeout: 10)
        // Any other analysis line (e.g. "0 von 246 Fotos analysiert") is printed for the log.
        let other = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fotos analysiert")).firstMatch
        print("UI_FACT analysis card \(when): \(card.exists ? card.label : "not found (\(other.exists ? other.label : "-"))") | \(card.exists ? (card.value as? String ?? "-") : "-")")
        let unreadable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "konnten noch nicht gelesen")).firstMatch
        if unreadable.exists { print("UI_FACT unreadable \(when): \(unreadable.label)") }
        let all = card.exists && card.label.hasPrefix("Alle ")
        print(all && !unreadable.exists ? "UI_STEP_OK every photo analysed \(when)" : "UI_STEP_MISSING every photo analysed \(when)")
        XCTAssertTrue(card.exists, "No analysis card \(when)", file: file, line: line)
        XCTAssertTrue(all, "Not every demo photo analysed \(when): \(card.label)", file: file, line: line)
        XCTAssertFalse(unreadable.exists, "Demo photos unreadable \(when): \(unreadable.label)", file: file, line: line)
    }

    /// Set by test 1 at its start and its end; the runner keeps them for the later tests.
    /// An audit that meets a screen in motion makes XCTest record "Failed to get matching
    /// snapshot" (expected in `audit`), and that issue ends the test method: test 1 then
    /// "passed" after the overview audit having done nothing more (runs 43773339053 and
    /// 43804947107: no "A11Y_AUDIT_DONE overview", no plan applied, so test 4's backup had
    /// no history to bring back). Test 2 reports such a cut-off test 1 as a failure. The
    /// markers are files (`UITestOnboarding`): run 43816787321 lost the test runner inside
    /// test 1, and the restarted runner began with fresh static flags.

    /// The first start as a user sees it: onboarding (notifications declined), demo library,
    /// analysis, overview, starter set, suggestions, the trip list, applying and the receipt.
    func test1_FullFlow() {
        continueAfterFailure = true
        UITestOnboarding.fullFlowStarts()
        // Test 1 runs first on a freshly erased simulator (its own group in ui.yml, and a repeat
        // after a simulator failure erases it again). An issue that ends the method early (an
        // audit meeting a screen in motion) would otherwise let it pass without its later checks;
        // this replaces the check test 2 made while both ran in one job.
        let end = UITestOnboarding.fullFlow.finished
        addTeardownBlock {
            if !FileManager.default.fileExists(atPath: end.path) {
                print("UI_STEP_MISSING full flow reached its end")
                XCTFail("test1_FullFlow stopped before its end (an accessibility audit cut it off, or the test runner restarted)")
            }
        }
        launch()

        // Onboarding: a fresh simulator always starts at the welcome screen.
        let welcome = button("Los geht").waitForExistence(timeout: 20)
        if !welcome {
            print("UI_STEP_MISSING welcome screen")
            XCTFail("test1_FullFlow must start on a fresh simulator: no welcome screen, so the onboarding checks did not run")
        }
        if welcome {
            shot("01-welcome"); audit("welcome")
            tap(button("Los geht"), "welcome")
            shot("02-areas")
            // Cities can be chosen right at the start (off by default).
            let cities = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Städte")).firstMatch
            print(cities.waitForExistence(timeout: 3) ? "UI_STEP_OK cities switch in onboarding" : "UI_STEP_MISSING cities switch in onboarding")
            tap(button("Weiter"), "areas")
            shot("03-access")
            // Design review W13: every step after the welcome screen has the system way back.
            if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5) {
                back()
                let areasAgain = app.staticTexts["Was soll Albumist sortieren?"].waitForExistence(timeout: 5)
                print(areasAgain ? "UI_STEP_OK onboarding back to areas" : "UI_STEP_MISSING onboarding back to areas")
                XCTAssertTrue(areasAgain, "Back from the access step did not return to the areas")
                tap(button("Weiter"), "areas again")
            } else {
                print("UI_STEP_MISSING onboarding back button")
                XCTFail("The access step has no back button")
            }
            if app.buttons["access.continue"].waitForExistence(timeout: 5) {
                app.buttons["access.continue"].tap()
                allowPhotosIfAsked()
            }
            // With access granted the app moves on by itself; "Weiter" only appears when
            // access had been granted before.
            if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
            let trial = button("Analyse starten").waitForExistence(timeout: 20)
            print(trial ? "UI_STEP_OK access granted" : "UI_STEP_MISSING access granted")
            XCTAssertTrue(trial, "Onboarding did not reach the trial step")
            shot("04-trial"); audit("trial")
            tap(button("Analyse starten"), "start analysis")
            declineNotificationsIfAsked()
        }

        // Demo library
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            // A fresh simulator holds only its own handful of sample photos, like many App Review
            // devices (plugin review K6): once the first analysis is done, the overview explains
            // why there is nothing to suggest and offers Albumist's sample photos (not tapped:
            // the demo library below is the bigger one).
            let hint = app.descendants(matching: .any)["overview.libraryHint"]
            let explained = hint.waitForExistence(timeout: 120)
            print(explained ? "UI_STEP_OK empty-library hint" : "UI_STEP_MISSING empty-library hint")
            XCTAssertTrue(explained, "A nearly empty library shows no explanation")
            let offer = app.buttons["samples.add"].exists
            print(offer ? "UI_STEP_OK sample photos offered" : "UI_STEP_MISSING sample photos offered")
            XCTAssertTrue(offer, "A nearly empty library does not offer the sample photos")
            shot("05-overview-empty")
            tap(demo, "seed demo library")
            let started = Date()
            // The demo card disappears from the overview once every photo is in the library.
            let seeded = UITestOnboarding.demoLibraryCreated(app)
            XCTAssertTrue(seeded, "Demo library not created")
            print("UI_TIMING seed \(Int(Date().timeIntervalSince(started))) s")
        } else {
            print("UI_STEP_MISSING demo button")
            XCTFail("No \"Beispiel-Mediathek anlegen\" on a fresh simulator: the empty-library checks and the seeding did not run")
        }
        let analysed = Date()
        // Seeding starts a fresh analysis; wait until it ran and the overview stays idle.
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")
        print("UI_TIMING analysis \(Int(Date().timeIntervalSince(analysed))) s")
        assertEveryPhotoAnalysed("after seeding")
        // With every photo readable the suggestions reach the overview a little after the
        // analysis card says done (run 43774578089: the overview changed during its audit,
        // which ended test1 there). The audit waits for them.
        let offers = Date()
        let ready = waitStable("suggestions on the overview", timeout: 180) {
            app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ (Vorschläge|Vorschlag) prüfen|[0-9]+ Alben (kostenlos )?anlegen")).firstMatch.exists
        }
        print("UI_FACT suggestions on the overview \(ready) after \(Int(Date().timeIntervalSince(offers))) s")
        // The demo library holds 12 trips; "1 Reisen" was a real detection bug.
        let teaser = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dein Reise-Atlas")).firstMatch
        if teaser.waitForExistence(timeout: 10) {
            print("UI_FACT atlas \(teaser.label)")
            let trips = teaser.label.firstMatch(of: #/(\d+) Reise/#).flatMap { Int($0.1) } ?? 0
            XCTAssertGreaterThanOrEqual(trips, 8, "Too few trips detected in the demo library: \(teaser.label)")
        }
        shot("06-overview"); audit("overview")
        app.swipeUp(); sleep(1)
        shot("06b-overview-areas")
        app.swipeDown(); app.swipeDown()

        // Fuchs, 14.11.: looking at the starter set and going back must not select anything.
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ Alben (kostenlos )?anlegen")).firstMatch
        if starter.waitForExistence(timeout: 5) {
            tap(starter, "open starter set")
            let preview = app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
            print(preview ? "UI_STEP_OK starter preview opened" : "UI_STEP_MISSING starter preview opened")
            sleep(2); shot("06c-starter-plan")
            back(); sleep(2)
            let leftover = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ausgewählte")).firstMatch.exists
            print(leftover ? "UI_STEP_MISSING nothing selected after starter preview" : "UI_STEP_OK nothing selected after starter preview")
            XCTAssertFalse(leftover, "Going back from the starter preview left suggestions selected")
            shot("06d-back-from-starter")
        } else {
            print("UI_STEP_MISSING starter set card")
        }

        // Suggestions
        if tap(reviewSuggestionsButton(), "open suggestions", timeout: 20) {
            sleep(1)
            shot("07-suggestions"); audit("suggestions")
            // Rows live in a List (collection view), not a scroll view. The first cell can be
            // the "N empfohlene auswählen" button, so pick the first real suggestion row.
            let first = suggestionRow()
            if tap(first, "open first suggestion", timeout: 10) {
                sleep(1)
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK suggestion detail opened" : "UI_STEP_MISSING suggestion detail opened")
                XCTAssertTrue(opened, "Tapping a suggestion did not open its detail")
                shot("08-suggestion-detail"); audit("suggestion detail")
                // Design review D3: every photo of a suggestion is a named button (its date),
                // so VoiceOver and Voice Control can pick photos to take out.
                let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alle ")).firstMatch
                if tap(all, "open all photos of the suggestion", timeout: 5) {
                    let photo = app.buttons["proposalPhotos.photo"].firstMatch
                    let named = photo.waitForExistence(timeout: 5) && photo.label.range(of: "20[0-9][0-9]", options: .regularExpression) != nil
                    print(named ? "UI_STEP_OK suggestion photos are named buttons (\(photo.label))" : "UI_STEP_MISSING suggestion photos are named buttons")
                    XCTAssertTrue(named, "The photos of a suggestion are not buttons named by their date")
                    if tap(button("Auswählen"), "select photos of the suggestion", timeout: 5) {
                        photo.tap()
                        XCTAssertTrue(photo.isSelected, "A selected photo does not report the selected trait")
                        shot("08a-suggestion-photos"); audit("suggestion photos")
                        tap(button("Fertig"), "end photo selection")
                    }
                    back(); sleep(1)
                }
                // "Album anlegen" opens a preview; back without creating selects nothing.
                let create = app.buttons["Album anlegen"]
                if create.exists {
                    create.tap()
                    if app.navigationBars["Vorschau"].waitForExistence(timeout: 20) { sleep(1); back(); sleep(1) }
                }
                back(); sleep(1)
                let selected = suggestionRow().label.contains("Ausgewählt")
                print(selected ? "UI_STEP_MISSING nothing selected after single preview" : "UI_STEP_OK nothing selected after single preview")
                XCTAssertFalse(selected, "Going back from a single preview left the suggestion selected")
                let list = app.navigationBars["Vorschläge"].waitForExistence(timeout: 5)
                print(list ? "UI_STEP_OK back to suggestions" : "UI_STEP_MISSING back to suggestions")
                XCTAssertTrue(list, "Back from a suggestion did not return to the list")
                shot("08b-back-to-list")
            }
            if tap(button("empfohlene auswählen"), "accept recommended") {
                sleep(1)
                shot("09-accepted")
            }
            back(); sleep(1)
        }

        // Area list: open a suggestion and come back (reported: rows not tappable, warning triangle on back)
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        if tap(travel, "open travel area", timeout: 10) {
            sleep(1)
            if tap(suggestionRow(), "open trip suggestion", timeout: 10) {
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK trip detail opened" : "UI_STEP_MISSING trip detail opened")
                XCTAssertTrue(opened, "Tapping a trip suggestion did not open its detail")
                shot("08c-trip-detail")
                back(); sleep(1)
                shot("08d-back-to-trips")
            }
            back(); sleep(1)
        }

        // Apply
        if tap(button("ausgewählte Alben anlegen"), "open plan", timeout: 20) {
            sleep(3)
            shot("10-plan"); audit("plan")
            // The plan names every album it will make, not only the counts.
            let list = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diese Alben werden")).firstMatch
            print(list.waitForExistence(timeout: 5) ? "UI_STEP_OK plan lists albums" : "UI_STEP_MISSING plan lists albums")
            if list.exists {
                app.swipeUp(); sleep(1)
                shot("10a-plan-albums")
                app.swipeDown(); sleep(1)
            }
            if tap(app.buttons["plan.apply"], "apply plan", timeout: 30) {
                let applied = Date()
                // Mid-show frames of "photos fly into albums".
                usleep(1_100_000); shot("10b-show")
                usleep(900_000); shot("10c-show")
                XCTAssertTrue(button("Rückgängig machen").waitForExistence(timeout: 900), "Plan did not finish")
                print("UI_TIMING apply \(Int(Date().timeIntervalSince(applied))) s")
                sleep(1)
                shot("11-result"); audit("result")
                // The change receipt: what really changed, from the execution journal.
                let receipt = app.buttons["result.receipt"]
                if !receipt.isHittable { app.swipeUp(); sleep(1) }
                if tap(receipt, "open change receipt", timeout: 10) {
                    sleep(2)
                    let checked = anything("Kein Original gelöscht").waitForExistence(timeout: 5)
                    print(checked ? "UI_STEP_OK receipt shows originals untouched" : "UI_STEP_MISSING receipt shows originals untouched")
                    shot("11a-receipt"); audit("receipt")
                    app.swipeUp(); sleep(1)
                    shot("11b-receipt-albums")
                    back(); sleep(1)
                }
            }
            back(); sleep(2)
        }

        print("UI_FACT notifications declined, the app went on: \(app.state == .runningForeground)")
    }

    /// Atlas, library, albums and search on the analysed demo library.
    func test1b_AtlasLibrarySearch() {
        continueAfterFailure = true
        prepare()
        // Travel atlas
        if tap(button("Reise-Atlas"), "open atlas", timeout: 30) {
            sleep(8)
            shot("12-atlas"); audit("atlas")
            app.swipeUp(); sleep(1)
            shot("12b-atlas-list")
            // A country opens its photos (list row; the map does the same for sighted users).
            let italy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Italien")).firstMatch
            if tap(italy, "open country", timeout: 10) {
                let opened = app.navigationBars["Italien"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK country photos opened" : "UI_STEP_MISSING country photos opened")
                XCTAssertTrue(opened, "Tapping a country did not open its photos")
                let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).count
                print("UI_FACT country photos \(photos)")
                XCTAssertGreaterThan(photos, 5, "The country screen shows no photos")
                sleep(1)
                shot("12c-country"); audit("country")
                back(); sleep(1)
            }
            if tap(app.buttons["Reise-Atlas teilen"], "share atlas") {
                sleep(3)
                shot("13-share-card"); audit("share card")
                tap(button("Fertig"), "close share")
                sleep(2) // the sheet slides away before the navigation bar answers again
            }
            back(); sleep(1)
        }

        // Library
        if tap(tabButton("Mediathek"), "library tab") {
            sleep(2)
            shot("14-library"); audit("library")
            let photo = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
            // After the plan ran, "Nicht sortiert" can be empty: show the sorted photos instead.
            if !photo.waitForExistence(timeout: 3), tap(button("Sortiert"), "sorted photos") {
                sleep(2)
                shot("14b-library-sorted")
            }
            // Design review W11/W12: a tap opens the photo large, its details behind "i",
            // and a pull down closes it, as in Photos.
            if tap(photo, "open photo") {
                sleep(2)
                shot("15-photo-viewer"); audit("photo viewer")
                if tap(app.buttons["viewer.info"], "photo info") {
                    sleep(1)
                    shot("15a-photo-detail"); audit("photo detail")
                    tap(app.buttons["detail.close"], "close photo info")
                    sleep(1)
                }
                let close = app.buttons["viewer.close"]
                app.swipeDown(velocity: .slow)
                let closed = waitGone(close, timeout: 5)
                print(closed ? "UI_STEP_OK pull down closes the photo" : "UI_STEP_MISSING pull down closes the photo")
                XCTAssertTrue(closed, "Pulling the photo down did not close it")
                if !closed { closeViewerIfOpen() }
            }
            if tap(button("Auswählen"), "select mode") {
                let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
                if photos.count >= 2 { photos.element(boundBy: 0).tap(); photos.element(boundBy: 1).tap() }
                sleep(1)
                shot("16-selection")
                if tap(button("Zu Album hinzufügen"), "add to album") {
                    sleep(2)
                    shot("17-add-to-album"); audit("add to album")
                    tap(button("Schließen"), "close add")
                }
                tap(button("Fertig"), "end selection")
            }
            ignoreAndUndo()
        }

        // Albums
        if tap(tabButton("Alben"), "albums tab") {
            sleep(2)
            shot("18-albums"); audit("albums")
            // Design review W12: an album shows all its photos, and each opens large.
            let album = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9] Fotos?")).firstMatch
            if tap(album, "open an album", timeout: 5) {
                let photo = app.buttons["album.photo"].firstMatch
                if tap(photo, "open a photo of the album", timeout: 10) {
                    let viewer = app.buttons["viewer.close"].waitForExistence(timeout: 5)
                    print(viewer ? "UI_STEP_OK album photo opens large" : "UI_STEP_MISSING album photo opens large")
                    XCTAssertTrue(viewer, "A photo of an album does not open")
                    shot("18a-album-photo")
                    closeViewerIfOpen()
                }
                back(); sleep(1)
            }
        }

        // Search (the system names the search tab itself)
        if tap(searchTabButton(), "search tab") {
            sleep(1)
            shot("19-search-empty")
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("Rom")
                sleep(3)
                shot("20-search-rom"); audit("search")
                // Close the keyboard: it covers the tab bar, and a tap on "Übersicht" would hit it.
                field.typeText("\n")
                sleep(1)
            }
        }
    }

    /// Undo of a plan from the history in the settings: one question from iOS, everything gone.
    func test1c_UndoFromHistory() {
        continueAfterFailure = true
        prepare()
        applyRecommended("undo")
        // Settings and undo
        if tap(tabButton("Übersicht"), "overview tab") {
            if tap(app.buttons["Einstellungen"], "settings") {
                sleep(1)
                shot("21-settings"); audit("settings")
                // Design review W16: history and undo are the first row, on their own screen.
                let history = tap(app.buttons["settings.history"], "open history and undo", timeout: 5)
                if history { sleep(1); shot("21h-history"); audit("history") }
                let row = app.buttons["history.row"].firstMatch
                // A history row opens the plan's change receipt; undo lives there.
                let opened = history && tap(row, "history row opens receipt", timeout: 10)
                if opened { sleep(2); shot("21a-history-receipt") }
                let undo = app.buttons["receipt.undo"]
                if opened && !undo.exists {
                    var more = 0
                    while !undo.exists && more < 6 { app.swipeUp(); more += 1 }
                }
                if opened, tap(undo, "undo in receipt", timeout: 10) {
                    // Another "Rückgängig machen" (the result card further back) can exist in
                    // the hierarchy; tap the one in the dialog that is really on screen.
                    let dialog = app.staticTexts["Diese Änderungen rückgängig machen?"].waitForExistence(timeout: 5)
                    print(dialog ? "UI_STEP_OK undo dialog" : "UI_STEP_MISSING undo dialog")
                    shot("21b-undo-dialog")
                    let confirms = app.buttons.matching(identifier: "Rückgängig machen").allElementsBoundByIndex
                    print("UI_FACT undo confirm buttons \(confirms.count), hittable \(confirms.filter(\.isHittable).count)")
                    if let confirm = confirms.first(where: \.isHittable) {
                        confirm.tap()
                        print("UI_STEP_OK confirm undo")
                    } else {
                        print("UI_STEP_MISSING confirm undo")
                    }
                    // iOS asks before an app deletes albums. All albums go in one request, so
                    // this must be one question, not one per album.
                    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    var questions = 0
                    let end = Date().addingTimeInterval(40)
                    while Date() < end {
                        let alert = springboard.alerts.firstMatch
                        if alert.waitForExistence(timeout: 3) {
                            if questions == 0 { shot("22-delete-question") }
                            let delete = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Löschen"])).firstMatch
                            if delete.exists { delete.tap(); questions += 1; sleep(2) } else { break }
                        } else if app.staticTexts["Rückgängig gemacht"].exists {
                            break
                        }
                    }
                    print("UI_FACT undo questions \(questions)")
                    XCTAssertLessThanOrEqual(questions, 1, "Undo asked more than once before deleting albums")
                    let undone = app.staticTexts["Rückgängig gemacht"].waitForExistence(timeout: 30)
                    print(undone ? "UI_STEP_OK undo finished" : "UI_STEP_MISSING undo finished")
                    if !undone {
                        for alert in app.alerts.allElementsBoundByIndex { print("UI_FACT app alert \(alert.label)") }
                        shot("22-undo-not-finished")
                    }
                    XCTAssertTrue(undone, "Undo did not finish")
                    // The receipt now ends with what the undo removed.
                    app.swipeUp(); app.swipeUp(); sleep(1)
                    shot("22-after-undo")
                    // "Rückgängig gemacht" is also the section title of a partial undo; on the
                    // first real iPhone nothing was taken back and the test would not have
                    // noticed (15.11.). Everything must be gone.
                    let partial = anything("Nicht alles ließ sich zurücknehmen").exists || anything("teilweise rückgängig").exists
                    let removedRow = anything("Entfernte Alben und Ordner").exists
                    print(!partial && removedRow ? "UI_STEP_OK undo took back everything" : "UI_STEP_MISSING undo took back everything (partial \(partial), removed row \(removedRow))")
                    XCTAssertFalse(partial, "Undo was only partial")
                    XCTAssertTrue(removedRow, "Undo removed no albums or folders")
                }
                if opened { back(); sleep(1) }
                if history { back(); sleep(1) }
                tap(button("Fertig"), "close settings")
            }
        }
    }

    /// Reise-Werkstatt: split a trip and merge it again, then take the changes back in the
    /// settings.
    func test1d_TripWorkshop() {
        continueAfterFailure = true
        prepare()
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        if tap(travel, "open travel area for workshop", timeout: 10) {
            sleep(1)
            tripWorkshop()
            back(); sleep(1)
        }
        // The trip changes from the workshop can be taken back in the settings.
        if tap(app.buttons["Einstellungen"], "settings for trip reset") {
            sleep(1)
            let reset = app.buttons["settings.resetTrips"]
            let list = app.collectionViews.firstMatch
            var swipes = 0
            while !(reset.exists && reset.isHittable) && swipes < 8 {
                (list.exists ? list : app).swipeUp()
                swipes += 1
            }
            if tap(reset, "reset trip changes", timeout: 5) {
                shot("66-settings-trips")
                let confirm = app.buttons["Automatisch erkennen"]
                if tap(confirm, "confirm trip reset", timeout: 5) {
                    let gone = waitGone(reset, timeout: 20)
                    print(gone ? "UI_STEP_OK trip changes reset" : "UI_STEP_MISSING trip changes reset")
                    XCTAssertTrue(gone, "Resetting the trip changes did not clear them")
                }
            }
            tap(button("Fertig"), "close settings after trip reset")
            _ = waitStable("analysis after trip reset", timeout: 180) { analysisIdle }
        }
        UITestOnboarding.fullFlowFinished()
        print("UI_STEP_OK full flow reached its end")
    }

    /// Design review D4 (15.11.): "Ignorieren" can be taken back, right after the action
    /// ("Widerrufen") and later in "Ignoriert" ("Nicht mehr ignorieren"). Runs in the library.
    private func ignoreAndUndo() {
        let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
        func ignoreTwo(_ step: String) -> Bool {
            guard tap(button("Auswählen"), "select mode for \(step)") else { return false }
            guard photos.count >= 2 else { print("UI_STEP_MISSING two photos for \(step)"); return false }
            photos.element(boundBy: 0).tap(); photos.element(boundBy: 1).tap()
            return tap(app.buttons["selection.ignore"], "ignore two photos (\(step))")
        }
        // 1. Ignore, then "Widerrufen" in the note right after.
        if ignoreTwo("undo") {
            let note = anything("2 Fotos ignoriert")
            let shown = note.waitForExistence(timeout: 5)
            print(shown ? "UI_STEP_OK ignore note" : "UI_STEP_MISSING ignore note")
            XCTAssertTrue(shown, "No \"2 Fotos ignoriert\" note after ignoring")
            shot("16a-ignore-note"); audit("ignore note")
            if tap(app.buttons["ignore.undo"], "undo ignore") {
                XCTAssertTrue(waitGone(note, timeout: 5), "The ignore note stayed after Widerrufen")
                tap(app.buttons["Ignoriert"], "ignored area after undo")
                sleep(2)
                let empty = anything("Keine Fotos").waitForExistence(timeout: 5)
                print(empty ? "UI_STEP_OK undo restored the photos" : "UI_STEP_MISSING undo restored the photos")
                XCTAssertTrue(empty, "Widerrufen left photos in Ignoriert")
                tap(app.buttons["Alle"], "all photos")
                sleep(1)
            }
        }
        // 2. Ignore again, then bring one back from "Ignoriert".
        if ignoreTwo("unignore") {
            sleep(2)
            tap(app.buttons["Ignoriert"], "ignored area")
            sleep(2)
            shot("16b-ignored")
            if tap(button("Auswählen"), "select in ignored") {
                let ignored = photos.count
                print("UI_FACT ignored photos \(ignored)")
                XCTAssertEqual(ignored, 2, "Ignoriert should hold the two photos")
                if ignored > 0 { photos.element(boundBy: 0).tap() }
                // No red, destructive look for a step that can be taken back.
                if tap(app.buttons["selection.unignore"], "unignore one photo") {
                    sleep(2)
                    XCTAssertEqual(photos.count, max(0, ignored - 1), "Nicht mehr ignorieren did not bring the photo back")
                }
            }
            // The other one through the photo's own detail.
            if photos.count > 0, tap(photos.element(boundBy: 0), "open ignored photo") {
                sleep(1)
                openPhotoInfo()
                // The info sheet opens at half height and its List builds rows only on
                // screen: the action at the end is not in the tree until the sheet is pulled
                // up (UI run 43779950348).
                let unignore = app.buttons["detail.unignore"]
                var pulls = 0
                let sheet = app.collectionViews["detail.list"]
                while !(unignore.exists && unignore.isHittable) && pulls < 4 { (sheet.exists ? sheet : app).swipeUp(); pulls += 1; sleep(1) }
                if tap(unignore, "unignore in detail") {
                    sleep(2)
                    closeViewerIfOpen()
                    let empty = anything("Keine Fotos").waitForExistence(timeout: 5)
                    print(empty ? "UI_STEP_OK ignored area empty again" : "UI_STEP_MISSING ignored area empty again")
                    XCTAssertTrue(empty, "Nicht mehr ignorieren in the detail did not bring the photo back")
                }
            }
            tap(app.buttons["Alle"], "all photos after unignore")
        }
    }

    /// A photo opens large; its details sit behind the "i" button (design review W12).
    private func openPhotoInfo() {
        let info = app.buttons["viewer.info"]
        if info.waitForExistence(timeout: 5) { info.tap(); sleep(1) }
    }

    private func closeViewerIfOpen() {
        let close = app.buttons["viewer.close"]
        if close.waitForExistence(timeout: 2) { close.tap(); sleep(1) }
    }

    /// Reise-Werkstatt (I07), from the trip list. The demo library's Iceland trip is
    /// Reykjavík (1.–4. August) and Vík (5.–7. August) in one: split it at 5 August, then
    /// merge the two parts again, so the rest of the run sees the trips as before.
    /// Found by month and year, the one part of a title that does not depend on where the
    /// place names come from: with Apple's towns the trip is "Island, August 2023", with the
    /// offline map alone "Reykjavík, August 2023" (UI run 43779950348 looked for "Island" and
    /// scrolled past it); after the split the parts may carry two different places.
    private func tripWorkshop() {
        let iceland = "August 2023"
        func tripRows(_ text: String) -> XCUIElementQuery {
            app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", text))
        }
        func tripRow(_ text: String) -> XCUIElement { tripRows(text).element(boundBy: 0) }
        func openWorkshop(_ row: XCUIElement, _ step: String) -> Bool {
            var swipes = 0
            while !(row.exists && row.isHittable) && swipes < 4 { app.swipeUp(); swipes += 1; sleep(1) }
            guard tap(row, "open trip for " + step, timeout: 10) else { return false }
            let reshape = app.buttons["proposal.reshapeTrip"]
            if reshape.waitForExistence(timeout: 5) && !reshape.isHittable { app.swipeUp(); sleep(1) }
            return tap(reshape, "open trip workshop for " + step, timeout: 5)
        }
        func finish(_ step: String, shotName: String) {
            let done = app.buttons["workshop.done"]
            let finished = done.waitForExistence(timeout: 180)
            print(finished ? "UI_STEP_OK trip \(step)" : "UI_STEP_MISSING trip \(step)")
            XCTAssertTrue(finished, "The trip \(step) did not finish")
            sleep(1)
            shot(shotName)
            if finished { done.tap(); sleep(3) }
        }

        guard openWorkshop(tripRow(iceland), "split") else { return }
        sleep(2)
        shot("60-trip-workshop"); audit("trip workshop")
        let day = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "workshop.day", "5. August")).firstMatch
        var swipes = 0
        while !(day.exists && day.isHittable) && swipes < 4 { app.swipeUp(); swipes += 1; sleep(1) }
        guard tap(day, "choose split day", timeout: 5) else { back(); return }
        sleep(1)
        // The preview and the button sit above the home indicator, whatever is scrolled.
        let split = app.buttons["workshop.split"]
        let inReach = split.waitForExistence(timeout: 5) && split.isHittable
        print(inReach ? "UI_STEP_OK split button in reach" : "UI_STEP_MISSING split button in reach")
        shot("61-split-preview"); audit("split preview")
        guard tap(split, "split trip") else { return }
        finish("split", shotName: "62-split-done")
        let list = app.navigationBars["Reisen"].waitForExistence(timeout: 5)
        print(list ? "UI_STEP_OK back to trips after split" : "UI_STEP_MISSING back to trips after split")
        let parts = waitStable("two trips in August 2023", timeout: 20, stableChecks: 1) { tripRows(iceland).count == 2 }
        print(parts ? "UI_STEP_OK second part is its own trip" : "UI_STEP_MISSING second part is its own trip")
        print("UI_FACT trips after split: \(tripRows(iceland).allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(parts, "After the split there are not two trips in August 2023")
        shot("63-trips-after-split")

        // The first part (listed below the newer one) lists the split and offers to merge with
        // the part after it; the other part offers the one before.
        guard openWorkshop(tripRows(iceland).element(boundBy: tripRows(iceland).count > 1 ? 1 : 0), "merge") else { return }
        sleep(2)
        let listed = app.buttons["workshop.undoChange"].exists
        print(listed ? "UI_STEP_OK workshop lists the split" : "UI_STEP_MISSING workshop lists the split")
        shot("64-workshop-after-split")
        let after = app.buttons["workshop.merge.after"], before = app.buttons["workshop.merge.before"]
        swipes = 0
        // Rows of a List exist only once they are on screen.
        while !((after.exists && after.isHittable) || (before.exists && before.isHittable)) && swipes < 4 { app.swipeUp(); swipes += 1; sleep(1) }
        guard tap(after.exists ? after : before, "merge with the other part", timeout: 5) else { return }
        sleep(1)
        shot("64b-merge-question")
        let confirm = app.buttons.matching(identifier: "Zusammenlegen").allElementsBoundByIndex.first(where: \.isHittable)
        guard let confirm else {
            print("UI_STEP_MISSING confirm merge")
            XCTFail("Missing: confirm merge")
            return
        }
        confirm.tap()
        finish("merge", shotName: "65-merge-done")
        let whole = waitStable("one trip in August 2023 again", timeout: 20, stableChecks: 1) { tripRows(iceland).count == 1 }
        print(whole ? "UI_STEP_OK trip whole again" : "UI_STEP_MISSING trip whole again")
        XCTAssertTrue(whole, "After the merge the trip is not one again")
    }

    /// Test 1 did not reach its end (or did not run): the app may still be at its welcome
    /// screen. One plain start finishes the onboarding and the demo library first, so a
    /// cut-off test 1 does not fail every later test (run 43816787321: 13 failures).
    private func completeOnboardingIfCutOff(_ test: String) {
        guard !UITestOnboarding.fullFlowReachedItsEnd else { return }
        launch()
        if UITestOnboarding.completeIfNeeded(app, in: test) { shot("x-onboarded-again-\(test)") }
    }

    /// Creates albums once if "Verlauf und Rückgängig" is empty: the starter set, else the
    /// suggestions already selected.
    private func ensureHistory() {
        guard tap(app.buttons["Einstellungen"], "settings before backup"),
              tap(app.buttons["settings.history"], "history before backup", timeout: 5) else { return }
        sleep(1)
        let empty = app.staticTexts["Noch keine Änderungen"].exists
        print("UI_FACT history empty before backup \(empty)")
        back(); sleep(1)
        tap(button("Fertig"), "close settings before backup")
        sleep(1)
        guard empty else { return }
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ Alben (kostenlos )?anlegen")).firstMatch
        let selected = button("ausgewählte Alben anlegen")
        let open = starter.waitForExistence(timeout: 10) ? starter : selected
        guard tap(open, "open a plan for the backup", timeout: 10),
              app.navigationBars["Vorschau"].waitForExistence(timeout: 20),
              tap(app.buttons["plan.apply"], "apply a plan for the backup", timeout: 30) else { return }
        let done = button("Rückgängig machen").waitForExistence(timeout: 900)
        print(done ? "UI_STEP_OK plan for the backup applied" : "UI_STEP_MISSING plan for the backup applied")
        XCTAssertTrue(done, "The plan for the backup did not finish")
        back(); sleep(2)
        _ = waitStable("analysis before backup", timeout: 180) { analysisIdle }
    }

    /// Same app state, but with the largest accessibility text size in dark mode.
    func test2_LargeTextDarkMode() {
        continueAfterFailure = true
        // Whether test 1 reached its end is checked by test 1 itself (its teardown block): the
        // two run in different groups on different simulators now.
        completeOnboardingIfCutOff("test2")
        prepare()
        XCUIDevice.shared.appearance = .dark
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-SortlyUITestDark"])
        sleep(5)
        shot("30-overview-xxxl-dark"); audit("overview xxxl dark")
        if tap(button("Reise-Atlas"), "open atlas xxxl", timeout: 20) {
            sleep(6)
            shot("31-atlas-xxxl-dark")
            back()
        }
        if tap(tabButton("Mediathek"), "library xxxl") {
            sleep(2)
            shot("32-library-xxxl-dark"); audit("library xxxl dark")
        }
        XCUIDevice.shared.appearance = .light
    }

    // MARK: Tap-through sweep

    /// Labels the sweep never taps: anything that changes the library or the analysis.
    private let sweepSkip = ["Pause", "Neu prüfen", "jetzt anlegen", "jetzt einsortieren", "jetzt ausführen", "zurücknehmen", "Rest anlegen",
                             "Erledigtes behalten", "ignorieren", "Widerrufen", "Rückgängig", "Fotos-App öffnen", "Alle Jahre", "Ganze Mediathek dazunehmen", "arbeitet mit", "Nur 20", "Löschen", "Entfernen", "Anlegen",
                             "Übernehmen", "Nicht jetzt", "ergänzen", "so lassen", "Fortsetzen", "Beispiel", "Ignorieren", "Auswählen",
                             "aufheben", "gleichen Fotos"]

    private func isSafe(_ label: String) -> Bool {
        !label.isEmpty && !sweepSkip.contains { label.localizedCaseInsensitiveContains($0) }
    }

    private var screenTitle: String {
        let bar = app.navigationBars.firstMatch
        return bar.exists ? bar.identifier : "-"
    }

    /// Closes a sheet or popover if one is open; returns true if it did.
    @discardableResult
    private func closeSheet() -> Bool {
        for label in ["Fertig", "Abbrechen", "Schließen"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); sleep(1); return true }
        }
        return false
    }

    /// What a row says: its own label, or for a list cell (whose own label is usually empty,
    /// UI run 43842312131: no row of "Vorschläge" or "Alben" was ever tapped) its first text.
    private func rowLabel(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        let text = element.staticTexts.firstMatch
        return text.exists ? text.label : ""
    }

    /// A list cell without its own label is a row (a link to a screen) only when it shows more
    /// than one text or an image: a suggestion or album row has its title, "12 Fotos" and a
    /// thumbnail. A section header ("Länder und Orte") or footer is a cell with one text and
    /// nothing to open (UI run 43906501407: they were tapped as rows and reported as dead).
    /// Every cell skipped this way is printed as UI_SWEEP_SKIP, and ui_tests.py lists those in
    /// the job summary and the run's "UI summary", so a real row skipped here is seen.
    private func looksLikeRow(_ element: XCUIElement) -> Bool {
        element.staticTexts.count >= 2 || element.images.count > 0
    }

    /// A row is tapped only when its label is not on the skip list, and a cell found by its
    /// text only when nothing in it is: a tap on the middle of such a cell can land on a
    /// button inside it. (Rows with their own label are tapped as before.)
    private func rowIsSafe(_ element: XCUIElement, label: String) -> Bool {
        guard isSafe(label) else { return false }
        guard element.label.isEmpty else { return true }
        let inside = element.buttons.allElementsBoundByIndex.prefix(8).map(\.label)
            + element.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label)
        return !inside.contains { !$0.isEmpty && !isSafe($0) }
    }

    /// Taps every row (and on top-level screens every button in the content) and checks
    /// that each tap leads somewhere and back works: no dead rows, no crash, no lost screen.
    /// Returns how many taps led somewhere (this screen and the screens below it). Rows it
    /// leaves out are printed (UI_SWEEP_SKIP), so a sweep that taps nothing says why.
    @discardableResult
    private func sweep(_ screen: String, depth: Int, strict: Bool = false) -> Int {
        var reached = 0
        let start = screenTitle
        let useCells = app.collectionViews.cells.count > 0
        if depth > 0 && !useCells { return 0 } // detail screens hold actions, not navigation
        let query = useCells ? app.collectionViews.cells : app.scrollViews.firstMatch.buttons
        // Rows by what they say; a cell whose own label is empty is found again by its text.
        var rows: [(label: String, own: Bool)] = []
        for i in 0..<min(query.count, 8) {
            let element = query.element(boundBy: i)
            let label = rowLabel(element)
            if label.isEmpty {
                print("UI_SWEEP_SKIP \(screen) row \(i) (no label, no text)")
            } else if element.label.isEmpty && !looksLikeRow(element) {
                print("UI_SWEEP_SKIP \(screen) › \(label) (section header or footer text)")
            } else if !rowIsSafe(element, label: label) {
                print("UI_SWEEP_SKIP \(screen) › \(label) (changes the library)")
            } else if !rows.contains(where: { $0.label == label }) {
                rows.append((label, !element.label.isEmpty))
            }
        }
        for (label, own) in rows.prefix(6) {
            let match = NSPredicate(format: "label == %@", label)
            let element = own ? query.matching(match).firstMatch : query.containing(match).firstMatch
            guard element.exists else { print("UI_SWEEP_SKIP \(screen) › \(label) (gone)"); continue }
            if !element.isHittable { app.swipeUp(); sleep(1) }
            guard element.isHittable else { print("UI_SWEEP_SKIP \(screen) › \(label) (not hittable)"); continue }
            element.tap(); sleep(2)
            guard app.state == .runningForeground else {
                print("UI_SWEEP_CRASH \(screen) › \(label)")
                XCTFail("App crashed after tapping \(label) on \(screen)")
                launch(); sleep(5)
                return reached
            }
            let now = screenTitle
            if now != start {
                print("UI_SWEEP_OK \(screen) › \(label) → \(now)")
                reached += 1
                if depth == 0 && useCells { reached += sweep("\(screen) › \(label)", depth: 1) }
                back(); sleep(1)
                if screenTitle != start {
                    print("UI_SWEEP_BACK_FAILED \(screen) › \(label) (still \(screenTitle))")
                    XCTFail("Back did not return to \(screen) after \(label)")
                    back(); sleep(1)
                }
            } else if closeSheet() {
                print("UI_SWEEP_OK \(screen) › \(label) → sheet")
                reached += 1
            } else {
                print("UI_SWEEP_NOOP \(screen) › \(label)")
                if strict { XCTFail("Row '\(label)' on \(screen) did nothing") }
            }
        }
        return reached
    }

    /// The search tab has no rows to open: a starting point must find photos, and a found
    /// photo must open large. Starting points from the library carry their photo count
    /// ("12 Fotos") and are taken first; before the analysis the fixed examples show, of which
    /// "Italien" matches the demo library.
    private func sweepSearch() -> Int {
        let chips = app.descendants(matching: .any).matching(identifier: "search.example")
        guard chips.firstMatch.waitForExistence(timeout: 10) else {
            print("UI_SWEEP_NOOP Suchen › no example")
            return 0
        }
        let counted = chips.matching(NSPredicate(format: "value MATCHES %@", "[1-9][0-9]* Fotos?")).firstMatch
        let italy = chips.matching(NSPredicate(format: "label == %@", "Italien")).firstMatch
        let chip = counted.exists ? counted : italy.exists ? italy : chips.firstMatch
        let label = chip.label
        chip.tap()
        let result = app.descendants(matching: .any).matching(identifier: "search.result").firstMatch
        guard result.waitForExistence(timeout: 20) else {
            print("UI_SWEEP_NOOP Suchen › \(label) (no results)")
            return 0
        }
        print("UI_SWEEP_OK Suchen › \(label) → results")
        var reached = 1
        // The keyboard can cover the grid; the first photo is above it.
        if !result.isHittable, app.keyboards.firstMatch.exists { app.swipeDown(); sleep(1) }
        if result.isHittable {
            result.tap()
            let viewer = app.buttons["viewer.close"].waitForExistence(timeout: 5)
            print(viewer ? "UI_SWEEP_OK Suchen › \(label) › photo → viewer" : "UI_SWEEP_NOOP Suchen › \(label) › photo")
            XCTAssertTrue(viewer, "A photo found by the search example '\(label)' did not open")
            if viewer { reached += 1 }
            closeViewerIfOpen()
        } else {
            print("UI_SWEEP_SKIP Suchen › \(label) › photo (not hittable)")
        }
        if app.buttons["Abbrechen"].exists { app.buttons["Abbrechen"].tap(); sleep(1) }
        return reached
    }

    /// Third run: every tab, every row, one level deep.
    func test3_TapThroughSweep() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test3")
        prepare()
        sleep(5)
        // A sweep that reaches nothing proves nothing: every tab and the suggestions list must
        // lead somewhere. The albums tab is the exception only while the library really has no
        // album (a fresh simulator before any plan): then it must say so.
        func check(_ tab: String, _ reached: Int) {
            print("UI_SWEEP_TAB \(tab) \(reached)")
            if reached == 0 { XCTFail("The sweep reached no screen from \(tab)") }
        }
        check("Übersicht", sweep("Übersicht", depth: 0))
        for tab in ["Mediathek", "Alben", "Suchen"] {
            let button = tab == "Suchen" ? searchTabButton() : tabButton(tab)
            guard button.waitForExistence(timeout: 5) else {
                print("UI_STEP_MISSING sweep tab \(tab)")
                XCTFail("No tab \(tab) for the sweep")
                continue
            }
            button.tap(); sleep(2)
            if tab == "Suchen" {
                check(tab, sweepSearch())
            } else if tab == "Alben" && app.staticTexts["Noch keine Alben"].exists {
                // An album row shows its photo count ("12 Fotos"), alone or in the row's label.
                let album = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label MATCHES %@", "(.*, )?[0-9]+ Fotos?")).firstMatch
                print("UI_SWEEP_TAB Alben not checked (empty)")
                XCTAssertFalse(album.exists, "\"Noch keine Alben\" while an album is listed")
            } else {
                check(tab, sweep(tab, depth: 0))
            }
        }
        // Suggestions list, the screen that had dead rows.
        tabButton("Übersicht").tap(); sleep(1)
        let suggestions = reviewSuggestionsButton()
        if suggestions.waitForExistence(timeout: 5) {
            suggestions.tap(); sleep(2)
            check("Vorschläge", sweep("Vorschläge", depth: 0, strict: true))
            back()
        } else {
            print("UI_STEP_MISSING sweep suggestions")
            XCTFail("No \"Vorschläge prüfen\" on the overview for the sweep")
        }
        print("UI_SWEEP_DONE")
    }

    // MARK: Safety backup

    /// Fourth run: the decisions and the plan made here are copied when the app goes to the
    /// background, the database is then set aside (as with "Neu aufbauen") and the next start
    /// must bring the decisions and the history back and say so.
    func test4_DecisionsComeBackAfterRebuild() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test4")
        prepare()
        // Decisions and a plan in the history, made in a run that keeps the backup copy.
        launch(["-SortlyUITestBackup"])
        applyRecommended("backup", relaunchWith: ["-SortlyUITestBackup"])
        sleep(5)
        // The copy must hold a history to bring back: when the earlier tests left none (test 1
        // cut off before its plan), this test creates one first instead of testing a backup
        // that has nothing to restore.
        ensureHistory()
        // Going to the background writes the copy.
        XCUIDevice.shared.press(.home)
        sleep(4)
        launch(["-SortlyUITestBackup", "-SortlyUITestRebuildDatabase"])
        let card = app.staticTexts["Entscheidungen zurückgeholt"]
        let restored = card.waitForExistence(timeout: 30)
        print(restored ? "UI_STEP_OK restored card" : "UI_STEP_MISSING restored card")
        XCTAssertTrue(restored, "The decisions did not come back after the database was rebuilt")
        // The analysis starts again right away, as after a real rebuild.
        sleep(4)
        shot("40-restored-card"); audit("restored card")
        let withHistory = anything("Alben und den Verlauf aus der Sicherung").exists
        print("UI_FACT restore included history \(withHistory)")
        XCTAssertTrue(withHistory, "Album records and history were not restored into the same library")

        // The history is back and the settings say when the copy was made.
        if tap(app.buttons["Einstellungen"], "settings after restore"),
           tap(app.buttons["settings.history"], "history after restore", timeout: 5) {
            sleep(1)
            let list = app.collectionViews.firstMatch
            let saved = anything("Zuletzt gesichert")
            var swipes = 0
            while !saved.exists && swipes < 10 {
                (list.exists ? list : app).swipeUp()
                swipes += 1
            }
            print(saved.exists ? "UI_STEP_OK backup date in settings" : "UI_STEP_MISSING backup date in settings")
            let empty = app.staticTexts["Noch keine Änderungen"].exists
            print("UI_FACT history empty after restore \(empty)")
            XCTAssertFalse(empty, "The history is empty after the restore")
            shot("41-settings-backup")
            back(); sleep(1)
            tap(button("Fertig"), "close settings after restore")
        }
        if tap(app.buttons["overview.restoredFromBackup.ok"], "dismiss restored card") {
            sleep(1)
            let gone = !card.exists
            print(gone ? "UI_STEP_OK restored card dismissed" : "UI_STEP_MISSING restored card dismissed")
            XCTAssertTrue(gone, "The restored card did not go away")
        }
    }

    /// Fifth run: the app is closed while a plan runs. The next start offers to continue,
    /// undo or leave it; "Nur Erledigtes behalten" keeps what was done, the change list says so and
    /// "Fehlendes erneut versuchen" makes a plan with only the missing steps.
    /// (Fortsetzen and Rückgängig: DeviceConditionUITests.test07.)
    func test5_InterruptedPlanCanBeLeftAndRetried() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test5")
        prepare()
        // The first change in Photos goes through at once, every later one waits 30 s, so the
        // app is always closed half way.
        launch(["-SortlyUITestSlowPlan"])
        _ = waitStable("analysis idle before interruption", timeout: 120) { analysisIdle }
        // Something to apply: the selection of earlier runs, else the recommended ones, else a
        // new album of two photos. Tests 1c and 4 apply the recommended suggestions on this
        // simulator first, so often only one that is not recommended is left (UI run
        // 43930271358: "1 Vorschlag prüfen", nothing to select, "Missing: open plan for
        // interruption"). Any plan of two or more changes is cut off by the slow plan.
        guard openRecommendedPlan("interruption") else {
            print("UI_STEP_MISSING plan for interruption")
            XCTFail("No plan to interrupt could be opened")
            return
        }
        guard tap(app.buttons["plan.apply"], "start plan for interruption", timeout: 30) else { return }
        sleep(5)
        print("UI_FACT plan running when the app was closed: \(anything("Alben werden angelegt").exists)")
        app.terminate()
        sleep(2)
        launch()
        let card = anything("Anlegen wurde unterbrochen")
        guard card.waitForExistence(timeout: 30) else {
            // Not silent any more: with the slow plan this means the interruption was lost.
            print("UI_STEP_MISSING interruption card")
            shot("x-no-interruption-card")
            XCTFail("No interruption card although the app was closed in the middle of a plan")
            return
        }
        print("UI_STEP_OK interruption card")
        sleep(1)
        shot("50-interrupted"); audit("interrupted card")
        let keep = app.buttons["interrupted.keep"]
        if !keep.isHittable { app.swipeUp(); sleep(1) }
        guard tap(keep, "leave interrupted plan as it is") else { return }
        let gone = waitGone(card, timeout: 30)
        print(gone ? "UI_STEP_OK interruption card gone after keep" : "UI_STEP_MISSING interruption card gone after keep")
        XCTAssertTrue(gone, "The interruption card stayed after \"Nur Erledigtes behalten\"")
        sleep(2)
        shot("50b-after-keep")

        // The kept plan is the newest history row; its receipt says what is missing.
        guard tap(app.buttons["Einstellungen"], "settings after keep") else { return }
        sleep(1)
        guard tap(app.buttons["settings.history"], "history after keep", timeout: 5) else { return }
        sleep(1)
        let row = app.buttons["history.row"].firstMatch
        guard tap(row, "kept plan in history", timeout: 10) else { return }
        sleep(2)
        let partial = anything("Teilweise umgesetzt").waitForExistence(timeout: 5)
        print(partial ? "UI_STEP_OK kept plan is partial" : "UI_STEP_MISSING kept plan is partial")
        XCTAssertTrue(partial, "The kept plan does not say it is partial")
        shot("51-kept-receipt"); audit("kept receipt")
        let retry = app.buttons["receipt.retry"]
        var more = 0
        while !(retry.exists && retry.isHittable) && more < 6 { app.swipeUp(); more += 1 }
        sleep(1)
        shot("52-receipt-repair")
        guard tap(retry, "retry missing steps", timeout: 10) else { return }
        let plan = app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
        print(plan ? "UI_STEP_OK retry plan opened" : "UI_STEP_MISSING retry plan opened")
        XCTAssertTrue(plan, "\"Fehlendes erneut versuchen\" did not open a plan")
        sleep(2)
        shot("53-retry-plan"); audit("retry plan")
        if tap(app.buttons["plan.apply"], "apply retry plan", timeout: 30) {
            let done = button("Rückgängig machen").waitForExistence(timeout: 300)
            print(done ? "UI_STEP_OK retry plan finished" : "UI_STEP_MISSING retry plan finished")
            XCTAssertTrue(done, "The retry plan did not finish")
            sleep(1)
            shot("54-retry-result")
        }
    }
    // MARK: Analysis keeps going

    /// Sixth run (first device test 15.11.: "bricht die Suche ab", "die Zahlen werden kleiner",
    /// "läuft es weiter, wenn man den Tab wechselt?"): a full analysis, made slow on purpose,
    /// survives leaving the app, coming back and switching tabs. Its count never goes down,
    /// it never starts at step 1 again, and it ends with every photo analysed. Then the trial
    /// year: choosing one shows it on the overview, "Alle Jahre" takes it back.
    func test6_AnalysisKeepsGoingThroughBackgroundAndTabs() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test6")
        prepare()
        launch(["-SortlyUITestSlowAnalysis"])
        _ = waitStable("analysis idle before rebuild", timeout: 300) { analysisIdle }
        // A full run from scratch: "Analyse neu aufbauen" in the settings.
        guard tap(app.buttons["Einstellungen"], "settings for rebuild") else { return }
        let list = app.collectionViews.firstMatch
        let rebuild = app.buttons["Analyse neu aufbauen"]
        var swipes = 0
        while !(rebuild.exists && rebuild.isHittable) && swipes < 12 { (list.exists ? list : app).swipeUp(); swipes += 1 }
        tap(rebuild, "rebuild analysis")
        tap(app.buttons["Neu aufbauen"], "confirm rebuild")
        sleep(1)
        if app.buttons["Fertig"].exists { app.buttons["Fertig"].tap() }

        var seen: [(step: Int, done: Int, total: Int)] = []
        func record(_ moment: String) {
            guard let count = analysisCount() else {
                print("UI_FACT analysis \(moment): no count (running \(app.buttons["Pause"].exists))")
                return
            }
            print("UI_FACT analysis \(moment): step \(count.step) \(count.done)/\(count.total)")
            if let last = seen.last {
                let back = count.step < last.step || (count.step == last.step && count.total == last.total && count.done < last.done)
                print(back ? "UI_STEP_MISSING count never goes back (\(moment))" : "UI_STEP_OK count never goes back (\(moment))")
                XCTAssertFalse(back, "The analysis went back at \(moment): \(last) -> \(count)")
            }
            seen.append(count)
        }

        // Wait for the image analysis (step 4), where most of the time goes.
        let inContent = waitStable("analysis reached the images", timeout: 300, stableChecks: 1) { (analysisCount()?.step ?? 0) >= 4 }
        XCTAssertTrue(inContent, "The analysis did not reach the image step")
        record("before leaving")
        shot("60-analysis-running"); audit("analysis running")

        // In the foreground the count moves (run 43743310212 printed only "0/246" while the
        // app was away, which says nothing about the foreground).
        let start = analysisCount()
        let moved = waitStable("progress moves in the foreground", timeout: 60, stableChecks: 1) {
            guard let start else { return true }
            guard let now = analysisCount() else { return analysisIdle }
            return now.step > start.step || (now.step == start.step && now.done > start.done)
        }
        print(moved ? "UI_STEP_OK progress moves in the foreground" : "UI_STEP_MISSING progress moves in the foreground")
        XCTAssertTrue(moved, "The analysis progress did not move in the foreground for 60 s")
        record("in the foreground")

        // Leave the app (on the simulator iOS holds it right away) and come back.
        XCUIDevice.shared.press(.home)
        sleep(8)
        app.activate()
        sleep(3)
        let running = app.buttons["Pause"].exists || analysisIdle
        print(running ? "UI_STEP_OK analysis still there after background" : "UI_STEP_MISSING analysis still there after background")
        XCTAssertTrue(running, "After coming back the analysis neither runs nor is done")
        XCTAssertFalse(app.buttons["analysis.resume"].exists, "Coming back from the background paused the analysis")
        record("after background")
        shot("61-after-background")

        // Switch tabs while it runs, then back to the overview.
        for name in ["Mediathek", "Alben"] {
            if tap(tabButton(name), "tab \(name) during analysis") { sleep(3) }
        }
        tap(tabButton("Übersicht"), "back to overview during analysis")
        sleep(2)
        record("after tabs")
        shot("62-after-tabs")

        // It goes on and ends with every photo analysed.
        var checks = 0
        while !analysisIdle && checks < 300 {
            sleep(3)
            if checks % 5 == 0 { record("while running") }
            checks += 1
        }
        let done = waitStable("analysis finished after background and tabs", timeout: 60) { analysisIdle }
        XCTAssertTrue(done, "The analysis did not finish after background and tabs")
        assertEveryPhotoAnalysed("after background and tabs")
        shot("63-analysis-done"); audit("analysis done")

        // "Neu prüfen" finds nothing new and says so.
        if tap(app.buttons["Neu prüfen"], "check again") {
            let said = waitStable("check result shown", timeout: 120) { analysisIdle && anything("keine neuen Fotos").exists }
            print(said ? "UI_STEP_OK check says no new photos" : "UI_STEP_MISSING check says no new photos")
            shot("64-check-again")
        }

        // Trial year: chosen in the settings, shown on the overview, taken back there.
        let year = Calendar.current.component(.year, from: Date())
        if tap(app.buttons["Einstellungen"], "settings for trial year") {
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Albumist arbeitet mit")).firstMatch
            if tap(picker, "trial year picker") {
                tap(app.buttons["Nur \(year)"], "choose \(year)")
                sleep(1)
            }
            shot("65-settings-trial-year")
            if app.buttons["Fertig"].exists { app.buttons["Fertig"].tap() }
            let note = app.descendants(matching: .any)["analysis.trial"]
            let shown = note.waitForExistence(timeout: 20)
            print(shown ? "UI_STEP_OK trial year on overview" : "UI_STEP_MISSING trial year on overview")
            XCTAssertTrue(shown, "The chosen year is not shown on the overview")
            _ = waitStable("analysis idle with trial year", timeout: 300) { analysisIdle }
            shot("66-overview-trial-year")
            if tap(button("Alle Jahre"), "take in all years") {
                let gone = waitGone(note, timeout: 20)
                print(gone ? "UI_STEP_OK trial year taken back" : "UI_STEP_MISSING trial year taken back")
                _ = waitStable("analysis idle after all years", timeout: 300) { analysisIdle }
                shot("67-overview-all-years")
            }
        }
    }
}
