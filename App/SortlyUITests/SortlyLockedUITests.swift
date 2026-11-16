import XCTest

/// The locked path of the one-time purchase, end to end (runs after SortlyFlowUITests, on the
/// library and suggestions that run left behind). The app starts with `-SortlyUITestLocked`
/// and one free album left: a plan with more albums shows the unlock card instead of
/// "Alben jetzt anlegen", "Die ersten 1 jetzt kostenlos anlegen" shrinks the plan to the free
/// album, it runs, and afterwards no free album is left. The purchase sheet itself is not
/// opened here (no App Store account on the CI simulator); buying, restoring, Ask to Buy,
/// failures and refunds are tested with StoreKit in PurchaseStoreKitTests.
@MainActor
final class SortlyLockedUITests: XCTestCase {
    private var app = XCUIApplication()

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            XCTFail("Missing: \(step)")
            return false
        }
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    /// "16 Vorschläge prüfen" or "1 Vorschlag prüfen".
    private func reviewSuggestionsButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9.]+ Vorschl(ag|äge) prüfen.*")).firstMatch
    }

    /// Opens the suggestions and selects the recommended ones; true when something is then
    /// ready to be created.
    private func selectRecommended(_ step: String) -> Bool {
        let review = reviewSuggestionsButton()
        guard review.waitForExistence(timeout: 20) else { return false }
        tap(review, step)
        sleep(1)
        if button("empfohlene auswählen").waitForExistence(timeout: 5) { button("empfohlene auswählen").tap(); sleep(1) }
        back(); sleep(1)
        return button("ausgewählte Alben anlegen").waitForExistence(timeout: 10)
    }

    /// Takes back the newest plans in "Verlauf und Rückgängig" (at most `limit`), so their
    /// suggestions are open again. Returns how many were taken back.
    private func takeBackNewestPlans(limit: Int) -> Int {
        guard tap(app.buttons["Einstellungen"], "settings (locked)"),
              tap(app.buttons["settings.history"], "history (locked)", timeout: 5) else { return 0 }
        sleep(1)
        var undone = 0
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for index in 0..<4 where undone < limit {
            let rows = app.buttons.matching(identifier: "history.row")
            guard index < rows.count else { break }
            rows.element(boundBy: index).tap()
            sleep(2)
            let undo = app.buttons["receipt.undo"]
            var more = 0
            while !undo.exists && more < 6 { app.swipeUp(); more += 1 }
            if undo.exists && undo.isEnabled {
                undo.tap()
                if let confirm = app.buttons.matching(identifier: "Rückgängig machen").allElementsBoundByIndex.first(where: \.isHittable) {
                    confirm.tap()
                    // iOS asks once before an app deletes albums.
                    let end = Date().addingTimeInterval(40)
                    while Date() < end && !app.staticTexts["Rückgängig gemacht"].exists {
                        let alert = springboard.alerts.firstMatch
                        if alert.waitForExistence(timeout: 3) {
                            let delete = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Löschen"])).firstMatch
                            if delete.exists { delete.tap(); sleep(2) } else { break }
                        }
                    }
                    if app.staticTexts["Rückgängig gemacht"].waitForExistence(timeout: 30) { undone += 1 }
                }
            }
            back(); sleep(1)
        }
        print("UI_FACT locked: plans taken back to have suggestions again: \(undone)")
        back(); sleep(1)
        tap(button("Fertig"), "close settings (locked)")
        sleep(3)
        return undone
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    func test7_LockedPlanOffersTheFreeAlbumsLeft() {
        continueAfterFailure = true
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-SortlyUITestUnlocked",
                               "-SortlyUITestLocked", "-SortlyUITestFreeAlbumsLeft", "1"]
        app.launch()
        // The overview is idle (the earlier runs analysed the demo library).
        let idle = anything("Fotos analysiert").waitForExistence(timeout: 120) || anything("Analyse aktuell").exists
        print(idle ? "UI_STEP_OK locked overview" : "UI_STEP_MISSING locked overview")

        // Something to apply: a selection left by the earlier runs, else the recommended ones.
        // After a complete flow nearly every suggestion is created (run 43796844064: "1
        // Vorschlag prüfen", nothing recommendable), so the test takes back the newest plans
        // and creates from those suggestions instead of skipping the locked path.
        let apply = button("ausgewählte Alben anlegen")
        if !apply.waitForExistence(timeout: 5) && !selectRecommended("open suggestions (locked)") {
            print("UI_FACT locked: nothing recommendable left, taking back the newest plans")
            if takeBackNewestPlans(limit: 2) > 0 { _ = selectRecommended("open suggestions after taking back (locked)") }
        }
        let ready = apply.waitForExistence(timeout: 10)
        print(ready ? "UI_STEP_OK something to create (locked)" : "UI_STEP_MISSING something to create (locked)")
        XCTAssertTrue(ready, "The locked run found nothing to create, not even after taking plans back")
        guard ready else { return }
        guard tap(apply, "open plan (locked)", timeout: 20) else { return }
        sleep(3)

        let unlock = app.staticTexts["Albumist freischalten"]
        if unlock.waitForExistence(timeout: 10) {
            print("UI_STEP_OK unlock card")
            XCTAssertFalse(app.buttons["plan.apply"].exists, "A plan over the free albums offered \"Alben jetzt anlegen\"")
            // With or without a price from StoreKit (W7: "Preis wird geladen …" until it is there).
            XCTAssertTrue(app.buttons["unlock.buy"].exists, "No unlock button")
            XCTAssertTrue(button("Kauf wiederherstellen").exists, "No restore button")
            guard tap(button("jetzt kostenlos anlegen"), "keep the free albums only") else { return }
            sleep(3)
        } else {
            print("UI_FACT locked: the plan has a single album, it fits the free one")
        }
        let start = app.buttons["plan.apply"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "The plan within the free albums cannot be applied")
        let rest = anything("noch 0 von 10 Gratis-Alben").exists
        print(rest ? "UI_STEP_OK free albums left after this plan" : "UI_STEP_MISSING free albums left after this plan")
        XCTAssertTrue(rest, "The plan does not say that no free album is left afterwards")
        guard tap(start, "apply plan (locked)") else { return }
        let done = button("Rückgängig machen").waitForExistence(timeout: 300)
        print(done ? "UI_STEP_OK locked plan finished" : "UI_STEP_MISSING locked plan finished")
        XCTAssertTrue(done, "The plan within the free albums did not finish")
    }
}
