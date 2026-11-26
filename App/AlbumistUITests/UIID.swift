import XCTest

/// Finding elements by their fixed identifier (rebuild stage 2, 26.11.2026; guideline
/// docs/UI_IDENTIFIERS.md).
///
/// Why: many UI tests look elements up by the words on screen ("Einstellungen", "Weiter",
/// `label CONTAINS 'von'`). A change of wording, the English texts, a larger text size or a
/// second element with the same words then turns a test red although the app is right, and
/// each such red costs a Mac run of about 25 minutes. A fixed identifier (`plan.apply`,
/// `viewer.position`) does not change with the words, the language or the layout.
///
/// The identifier is set once in the app (`.accessibilityIdentifier("screen.element")`) and
/// looked up here, of any element kind, so a test does not break either when a text becomes a
/// button. The rule `UIIdentifierRuleTests` (test_ui_identifiers.py, on Linux) checks that every
/// identifier a test asks for is set somewhere in the app, so a renamed or mistyped identifier is
/// red within seconds on Linux instead of after a Mac run.
@MainActor
extension XCUIApplication {
    /// The first element with the fixed identifier `id`, of any kind (button, text, cell, image,
    /// other). Does not wait; use `waitFor(id:)` when the element may still be on its way.
    func element(id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Every element with the fixed identifier `id` (the rows of a list that share one, such as
    /// `history.row`).
    func elements(id: String) -> XCUIElementQuery {
        descendants(matching: .any).matching(identifier: id)
    }

    /// The element with the fixed identifier `id` once it exists, within `timeout` seconds.
    /// When it does not come it prints `UI_STEP_MISSING` and fails the test (`UITestWait.appears`),
    /// never a silent pass; `what` says in the log what was waited for.
    @discardableResult
    func waitFor(id: String, _ what: String? = nil, timeout: TimeInterval,
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = element(id: id)
        UITestWait.appears(element, what ?? id, timeout: timeout, file: file, line: line)
        return element
    }

    /// Waits for the element with the fixed identifier `id` (`waitFor(id:)`) and taps it.
    /// Taps nothing when it never came (the test has already failed then).
    func tap(id: String, _ what: String? = nil, timeout: TimeInterval,
             file: StaticString = #filePath, line: UInt = #line) {
        let element = waitFor(id: id, what, timeout: timeout, file: file, line: line)
        if element.exists { element.tap() }
    }
}
