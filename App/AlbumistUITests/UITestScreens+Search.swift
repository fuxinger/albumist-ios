import XCTest

/// The search tab as the UI tests reach it (`UITestScreens`; a file of its own for SwiftLint's
/// file length).
extension UITestScreens {
    // MARK: Search

    /// The search (DS-12a, design wave 3): `Tab(role: .search)`, Apple's search tab, with its
    /// field where `MainTabs.searchField` puts it. By default on the tab view: choosing the tab
    /// shows the page and the field, the keyboard comes when the field is tapped, and leaving
    /// the search is choosing another tab (the search stays as it is). With
    /// `.tabViewOpeningKeyboard` the keyboard comes with the tab and closing the field goes back
    /// to the tab before; with `.pageFocusingField` the field is on the page, a fourth tab. The
    /// tab carries the system's own name; iOS may draw it as a round button at the bar's end,
    /// which may lie outside `app.tabBars`, and may fold the other tabs into one button beside an
    /// active field. The helpers work with all three and say what iOS shows (`UI_FACT`), so the
    /// first run on iOS 27.2 tells what they rest on (review S4 of H14).
    @MainActor
    enum Search {
        /// The system's names of the search tab.
        static let labels = ["Suchen", "Suche", "Search"]
        /// What leaves an active search: the field's "Schließen" (iOS 26 and later), else
        /// "Abbrechen"; a photo opened from the results closes with "Schließen" too.
        static let leaveLabels = ["Schließen", "Abbrechen", "Close", "Cancel"]

        /// The search button: the tab bar's, else one outside the tab bar by its name while no
        /// keyboard is up (the keyboard's return key says "Suchen" too). A bar that scrolled away
        /// comes back with up to two swipes down, never a tap into it (review S10 of H14). Never
        /// another tab: when neither shows, the tab bar's buttons are printed and the element
        /// returned does not exist, so the caller's tap reports the search tab missing. Choosing
        /// it brings the keyboard only with `.tabViewOpeningKeyboard`: tap the field to type.
        static func button(_ app: XCUIApplication) -> XCUIElement {
            func found() -> XCUIElement? {
                if let label = labels.first(where: { app.tabBars.buttons[$0].exists }) { return app.tabBars.buttons[label] }
                let outside = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                return !app.keyboards.firstMatch.exists && outside.exists ? outside : nil
            }
            UITestScreens.expandTabBar(app) { found()?.isHittable == true }
            if let button = found() { return button }
            print("UI_FACT no search button named \(labels) in or beside the tab bar (keyboard up: "
                  + "\(app.keyboards.firstMatch.exists)); the tab bar shows \(barFacts(app))")
            let english = app.tabBars.buttons[Tabs.english.suggestions].exists
            return app.tabBars.buttons[english ? "Search" : labels[0]]
        }

        /// Leaves the search, so the three named tabs are back in the tab bar, hittable (iOS may
        /// fold them into one button beside an active search, and the keyboard covers them).
        /// True when no search field is left or the tabs are back; at most three taps: a photo
        /// opened from the results, the field's own way out, and by default (where closing the
        /// field stays on the search) the folded tabs. The way out: `wayOut`.
        @discardableResult
        static func leave(_ app: XCUIApplication, _ what: String) -> Bool {
            for step in 0..<3 {
                guard app.searchFields.firstMatch.exists, !tabsBack(app) else { return true }
                if step == 0 { print("UI_FACT \(what): leaving the search; \(facts(app))") }
                guard let way = wayOut(app, what) else { return false }
                way.tap()
                if UITestWait.holds(timeout: 5, { tabsBack(app) }) { return true }
            }
            let back = !app.searchFields.firstMatch.exists || tabsBack(app)
            if !back { print("UI_FACT \(what): the tabs are not back after leaving the search; \(facts(app))") }
            return back
        }

        /// The three named tabs can be tapped, in German or in English: the search does not fold
        /// them. Not "Vorschläge" alone, which a folded button may be named after (review S4).
        static func tabsBack(_ app: XCUIApplication) -> Bool {
            [Tabs.german, Tabs.english].contains { tabs in
                [tabs.suggestions, tabs.unsorted, tabs.albums].allSatisfy { name in
                    let tab = app.tabBars.buttons[name]
                    return tab.exists && tab.isHittable
                }
            }
        }

        /// The way out of the search, said in the log before it is tapped: a button of
        /// `leaveLabels` beside the field first (its own "Schließen"), else one elsewhere (a
        /// photo opened from the results), else the one button left in the tab bar besides the
        /// search (the folded tabs, which choose a tab; review S4 and S10 of H14). Nil, with what
        /// shows, when there is none.
        private static func wayOut(_ app: XCUIApplication, _ what: String) -> XCUIElement? {
            let named = app.buttons.matching(NSPredicate(format: "label IN %@", leaveLabels))
                .allElementsBoundByIndex.filter(\.isHittable)
            let field = app.searchFields.firstMatch
            let row = field.exists ? field.frame.insetBy(dx: -60, dy: -12) : .null
            if let beside = named.first(where: { row.intersects($0.frame) }) {
                print("UI_STEP_OK \(what): leave the search with \"\(beside.label)\" beside its field")
                return beside
            }
            if let elsewhere = named.first {
                print("UI_STEP_OK \(what): leave the search with \"\(elsewhere.label)\", not beside its field")
                return elsewhere
            }
            let left = app.tabBars.buttons.allElementsBoundByIndex.filter { $0.isHittable && !labels.contains($0.label) }
            if left.count == 1, let folded = left.first {
                print("UI_STEP_OK \(what): leave the search with the one button left in the tab bar, \"\(folded.label)\"")
                return folded
            }
            print("UI_FACT \(what): a search field shows, but none of \(leaveLabels) can be tapped, and the tab bar has "
                  + "\(left.count) buttons besides the search; \(facts(app))")
            return nil
        }

        /// What iOS shows of the search, for the log: the tab bar's buttons, whether the named
        /// tabs are folded, the field, the keyboard, and the buttons beside the field.
        static func facts(_ app: XCUIApplication) -> String {
            let field = app.searchFields.firstMatch
            let row = field.exists ? field.frame.insetBy(dx: -60, dy: -12) : .null
            var beside: [String] = []
            if !row.isNull, let root = try? app.snapshot() {
                var nodes: [any XCUIElementSnapshot] = [root]
                while let node = nodes.popLast() {
                    if node.elementType == .button, row.intersects(node.frame) { beside.append(node.label) }
                    nodes += node.children
                }
            }
            return "tab bar \(barFacts(app)), folded \(!tabsBack(app)), search field \(field.exists), "
                + "keyboard \(app.keyboards.firstMatch.exists), beside the field \(beside)"
        }

        /// The tab bar's buttons by name, "(not hittable)" after one that cannot be tapped.
        static func barFacts(_ app: XCUIApplication) -> [String] {
            app.tabBars.buttons.allElementsBoundByIndex.map { $0.label + ($0.isHittable ? "" : " (not hittable)") }
        }
    }
}
