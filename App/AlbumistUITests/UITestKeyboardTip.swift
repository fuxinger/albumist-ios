import XCTest

/// iOS' one-time keyboard tip "Speed up your typing by sliding your finger across the letters
/// to compose a word." (slide to type) with its button "Continue". It shows over the keyboard
/// the first time a simulator's keyboard comes up and covered the lower half of the English
/// search pictures in AccessibilityUITests (full UI run 45690592821). It belongs to iOS, not
/// to Albumist, so the test closes it the way a person would, with its own button, before
/// the screen is checked. Only when the tip's text is on screen: "Continue" or "Weiter" alone
/// could be one of the app's own buttons.
@MainActor
enum UITestKeyboardTip {
    private static let tipText = NSPredicate(
        format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
        "Speed up your typing", "sliding your finger", "über die Buchstaben")
    private static let closeLabels = ["Continue", "Weiter", "Fortfahren"]

    /// Closes the tip when it shows; returns whether it was there. Waits at most `timeout`
    /// seconds for it to appear (it comes with the keyboard's animation).
    @discardableResult
    static func dismissIfShown(_ app: XCUIApplication, step: String, timeout: TimeInterval = 2) -> Bool {
        let text = app.descendants(matching: .any).matching(tipText).firstMatch
        guard text.waitForExistence(timeout: timeout) else { return false }
        print("UI_FACT keyboard tip shown at \(step): '\(text.label.prefix(80))'")
        // The tip's own button sits below its text, inside the tip; an app button of the same
        // name above the keyboard is never taken (second review 25.11.).
        let tipTop = text.frame.minY
        let button = app.buttons.matching(NSPredicate(format: "label IN %@", closeLabels))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.frame.minY >= tipTop }
        guard let close = button else {
            print("UI_STEP_MISSING keyboard tip closed at \(step) (no button \(closeLabels) below the tip)")
            XCTFail("iOS' keyboard tip covers the screen at \(step) and has no button to close it")
            return false
        }
        close.tap()
        return UITestWait.disappears(text, "keyboard tip closed at \(step)", timeout: 5)
    }
}
