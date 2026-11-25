import XCTest

/// Finding a suggestion in the open suggestions list ("Vorschläge").
@MainActor
enum UITestSuggestions {
    /// A suggestion in the open list that can still be created: one for a new album, else any
    /// that is not "Schon vollständig vorhanden" (an album to extend, a similar album found ...).
    /// A row is a button whose label joins its texts ("Rom, Mai 2024, 20 Fotos, Neues Album",
    /// ProposalRow in a PushLink), so rows are found by that label, not by a cell's own texts.
    /// It must be in sight: clear of the tab bar and of the navigation bar, since content under
    /// them counts as hittable for XCUITest and a tap there hits the bar.
    /// UI run 45622518290 (PR #20, flow-other): every suggestion on the first screen was
    /// complete and the test looked only for "Neues Album" there. UI run 45662948348: the first
    /// lookup by a cell's texts took a cell with no label, and the tap opened nothing. nil when
    /// none is in sight after scrolling: the caller then takes plans back.
    static func openRow(in app: XCUIApplication) -> XCUIElement? {
        let rows = app.collectionViews.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", " Fotos", "Schon vollständig vorhanden"))
        let newAlbum = rows.matching(NSPredicate(format: "label CONTAINS %@", "Neues Album")).firstMatch
        let tabs = app.tabBars.firstMatch
        let bar = app.navigationBars["Vorschläge"]
        func inSight(_ row: XCUIElement) -> Bool {
            row.exists && row.isHittable && app.frame.contains(row.frame)
                && (!tabs.exists || row.frame.maxY <= tabs.frame.minY)
                && (!bar.exists || row.frame.minY >= bar.frame.maxY)
        }
        for swipe in 0...8 {
            if inSight(newAlbum) { return newAlbum }
            if let row = rows.allElementsBoundByIndex.first(where: inSight) { return row }
            if swipe < 8 { app.swipeUp() }
        }
        return nil
    }
}
