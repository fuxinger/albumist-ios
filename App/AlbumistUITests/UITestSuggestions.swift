import XCTest

/// Finding a suggestion in the open suggestions list ("Vorschläge").
@MainActor
enum UITestSuggestions {
    /// A suggestion in the open list that can still be created: one for a new album, else any
    /// that is not "Schon vollständig vorhanden" (an album to extend, a similar album found ...).
    /// UI run 45622518290 (PR #20, flow-other): after the earlier tests every suggestion was
    /// complete except one further down the list that was not for a new album, and the locked
    /// test looked only for "Neues Album" on the first screen. The list is scrolled to find one.
    static func openRow(in app: XCUIApplication) -> XCUIElement {
        let cells = app.collectionViews.cells
        let newAlbum = cells.containing(NSPredicate(format: "label CONTAINS %@", "Neues Album")).firstMatch
        for swipe in 0...6 {
            if newAlbum.exists { return newAlbum }
            for cell in cells.allElementsBoundByIndex where cell.isHittable {
                let texts = cell.staticTexts
                if texts.count > 0 && !texts["Schon vollständig vorhanden"].exists { return cell }
            }
            if swipe < 6 { app.swipeUp() }
        }
        return newAlbum
    }
}
