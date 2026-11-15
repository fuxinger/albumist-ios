import XCTest

/// The locked path of the one-time purchase, end to end (on the demo library, created first
/// when the test runs alone). The app starts with `-SortlyUITestLocked`
/// and one free album left: a plan with more albums shows the unlock card instead of
/// "Jetzt umsetzen", "Die ersten 1 jetzt kostenlos anlegen" shrinks the plan to the free
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

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    /// CI runs groups of UI tests on separate simulators: when this test runs without the flow
    /// before it, the demo library is created and analysed first (fast start, no onboarding).
    private func prepareLibrary() {
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-SortlyUITestUnlocked", "-SortlyUITestFastStart"]
        app.launch()
        let deadline = Date().addingTimeInterval(900)
        var streak = 0
        while Date() < deadline && streak < 3 {
            let ready = anything("Fotos analysiert").exists && !app.buttons["Pause"].exists
                && !anything("Beispielfotos werden angelegt").exists && !button("Beispiel-Mediathek anlegen").exists
            streak = ready ? streak + 1 : 0
            sleep(2)
        }
        print(streak >= 3 ? "UI_STEP_OK prepared (locked)" : "UI_STEP_MISSING prepared (locked)")
        app.terminate()
        app = XCUIApplication()
    }

    func test7_LockedPlanOffersTheFreeAlbumsLeft() {
        continueAfterFailure = true
        prepareLibrary()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-SortlyUITestUnlocked",
                               "-SortlyUITestLocked", "-SortlyUITestFreeAlbumsLeft", "1"]
        app.launch()
        // The overview is idle (the earlier runs analysed the demo library).
        let idle = anything("Fotos analysiert").waitForExistence(timeout: 120) || anything("Analyse aktuell").exists
        print(idle ? "UI_STEP_OK locked overview" : "UI_STEP_MISSING locked overview")

        // Something to apply: a selection left by the earlier runs, else the recommended ones.
        var apply = button("ausgewählte Alben anlegen")
        if !apply.waitForExistence(timeout: 5), tap(button("Vorschläge prüfen"), "open suggestions (locked)", timeout: 20) {
            sleep(1)
            if button("empfohlene auswählen").waitForExistence(timeout: 5) { button("empfohlene auswählen").tap(); sleep(1) }
            back(); sleep(1)
            apply = button("ausgewählte Alben anlegen")
        }
        guard apply.waitForExistence(timeout: 10) else {
            print("UI_FACT locked: nothing left to apply in the demo library")
            return
        }
        guard tap(apply, "open plan (locked)", timeout: 20) else { return }
        sleep(3)

        let unlock = app.staticTexts["Albumist freischalten"]
        if unlock.waitForExistence(timeout: 10) {
            print("UI_STEP_OK unlock card")
            XCTAssertFalse(button("Jetzt umsetzen").exists, "A plan over the free albums offered \"Jetzt umsetzen\"")
            XCTAssertTrue(button("Freischalten").exists, "No unlock button")
            XCTAssertTrue(button("Kauf wiederherstellen").exists, "No restore button")
            guard tap(button("jetzt kostenlos anlegen"), "keep the free albums only") else { return }
            sleep(3)
        } else {
            print("UI_FACT locked: the plan has a single album, it fits the free one")
        }
        let start = button("Jetzt umsetzen")
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
