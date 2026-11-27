import XCTest

/// The search tab as the UI tests reach it (`UITestScreens`; a file of its own for SwiftLint's
/// file length).
extension UITestScreens {
    // MARK: Search

    /// The search (DS-12a, design wave 3), as the owner chose it on 25.11.2026 ("Runder Knopf,
    /// Suche bleibt"): a round button of its own at the bar's end named "Suchen"
    /// (`MainTabs.searchRole`), which may lie outside `app.tabBars`; choosing it shows the page
    /// and the field, the keyboard comes when the field is tapped, and leaving the search is
    /// choosing another tab (the search stays as it is). The field sits where
    /// `MainTabs.searchField` puts it: on iOS 26 on the tab view, where iOS may fold the other
    /// tabs into one button beside the active field; on iOS 27 on the page under its title,
    /// always shown. The helpers work with both and say what iOS shows (`UI_FACT`; review S4 of
    /// H14).
    @MainActor
    enum Search {
        /// The system's names of the search tab.
        static let labels = ["Suchen", "Suche", "Search"]
        /// What leaves an active search: the field's "Schließen" (iOS 26 and later), else
        /// "Abbrechen"; a photo opened from the results closes with "Schließen" too.
        static let leaveLabels = ["Schließen", "Abbrechen", "Close", "Cancel"]
        /// What closes a photo opened from the results, the only way out that is not beside the
        /// field: never "Abbrechen", which ends a dialog, not the search (review S10 of H14).
        static let closeLabels = ["Schließen", "Close"]

        /// The search button: the tab bar's, else one by its name in the tab bar's row (iOS may
        /// draw it as a round button of its own beside the bar), while neither the keyboard (its
        /// return key says "Suchen" too) nor a dialog is up: never a "Suchen" of the page or of a
        /// dialog (review S10 of H14). A bar that scrolled away comes back with up to two swipes
        /// down, never a tap into it. Never another tab: when neither shows, the tab bar's buttons
        /// are printed and the element returned does not exist, so the caller's tap reports the
        /// search tab missing. Choosing it never brings the keyboard: tap the field to type.
        static func button(_ app: XCUIApplication) -> XCUIElement {
            func found() -> XCUIElement? {
                if let label = labels.first(where: { app.tabBars.buttons[$0].exists }) { return app.tabBars.buttons[label] }
                guard !app.keyboards.firstMatch.exists, !app.alerts.firstMatch.exists, !app.sheets.firstMatch.exists else { return nil }
                return app.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex
                    .first(where: { inTabBarRow($0, app) })
            }
            UITestScreens.expandTabBar(app) { found()?.isHittable == true }
            if let button = found() { return button }
            print("UI_FACT no search button named \(labels) in or beside the tab bar (keyboard up: "
                  + "\(app.keyboards.firstMatch.exists)); the tab bar shows \(barFacts(app))")
            let english = app.tabBars.buttons[Tabs.english.suggestions].exists
            return app.tabBars.buttons[english ? "Search" : labels[0]]
        }

        /// `element` stands in the tab bar's row: iOS may draw the search tab as a round button of
        /// its own beside the bar, outside `app.tabBars`.
        private static func inTabBarRow(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
            let bar = app.tabBars.firstMatch
            guard bar.exists, element.exists else { return false }
            let mid = element.frame.midY
            return mid >= bar.frame.minY && mid <= bar.frame.maxY
        }

        /// Leaves the search, so the three named tabs are back in the tab bar, hittable (iOS may
        /// fold them into one button beside an active search, and the keyboard covers them).
        /// True when no search field is left or the tabs are back; at most three taps: a photo
        /// opened from the results, the field's own way out, and the folded tabs of iOS 26. The
        /// way out: `wayOut`, the field's own first, where only getting out matters (the sweep,
        /// `tabButton`).
        @discardableResult
        static func leave(_ app: XCUIApplication, _ what: String) -> Bool {
            leave(app, what, keepingSearch: false).back
        }

        /// `leave(_:_:)`, and the ways it tapped as the log names them. `keepingSearch`: as a user
        /// looks at another tab, the search stays as it is: the folded tabs first, and never the
        /// field's own way out, which ends the search and empties the field (review T4 of H14).
        /// The tabs come back by themselves as the keyboard goes (iOS 27, where the field is the
        /// page's): up to 3 s for them before any tap, unless the keyboard is up where only getting
        /// out matters (it covers them until something is tapped). Without that wait a tap on
        /// "Schließen" a moment too early ended the search the test meant to keep (second check
        /// of the search, 25.11.2026).
        static func leave(_ app: XCUIApplication, _ what: String, keepingSearch: Bool) -> (back: Bool, ways: [String]) {
            var ways: [String] = []
            for step in 0..<3 {
                guard app.searchFields.firstMatch.exists, !tabsBack(app) else { return (true, ways) }
                if keepingSearch || !app.keyboards.firstMatch.exists, UITestWait.holds(timeout: 3, { tabsBack(app) }) {
                    return (true, ways)
                }
                if step == 0 { print("UI_FACT \(what): leaving the search; \(facts(app))") }
                guard let way = wayOut(app, what, keepingSearch: keepingSearch) else { return (false, ways) }
                ways.append(way.said)
                way.button.tap()
                if UITestWait.holds(timeout: 5, { tabsBack(app) }) { return (true, ways) }
            }
            let back = !app.searchFields.firstMatch.exists || tabsBack(app)
            if !back { print("UI_FACT \(what): the tabs are not back after leaving the search; \(facts(app))") }
            return (back, ways)
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
        /// `leaveLabels` beside the field first (its own "Schließen"), else a "Schließen"
        /// elsewhere (a photo opened from the results), else the one button left in the tab bar
        /// besides the search (the folded tabs of iOS 26, which choose a tab; review S4 and S10 of
        /// H14). `keepingSearch`: the folded tabs first, and never the field's own way out, which
        /// ends the search (review T4). Never a button of a dialog (`leaveButtons`). Nil, with
        /// what shows, when there is none.
        private static func wayOut(_ app: XCUIApplication, _ what: String, keepingSearch: Bool) -> (button: XCUIElement, said: String)? {
            let named = leaveButtons(app)
            let field = app.searchFields.firstMatch
            let row = field.exists ? field.frame.insetBy(dx: -60, dy: -12) : .null
            var ways: [(button: XCUIElement, said: String)] = []
            if !keepingSearch, let beside = named.first(where: { row.intersects($0.frame) }) {
                ways.append((beside, "\"\(beside.label)\" beside its field"))
            }
            if let elsewhere = named.first(where: { closeLabels.contains($0.label) && !row.intersects($0.frame) }) {
                ways.append((elsewhere, "\"\(elsewhere.label)\", not beside its field"))
            }
            let left = app.tabBars.buttons.allElementsBoundByIndex.filter { $0.isHittable && !labels.contains($0.label) }
            if left.count == 1, let folded = left.first {
                let way = (button: folded, said: "the one button left in the tab bar, \"\(folded.label)\"")
                if keepingSearch { ways.insert(way, at: 0) } else { ways.append(way) }
            }
            if let way = ways.first {
                print("UI_STEP_OK \(what): leave the search with \(way.said)")
                return way
            }
            print("UI_FACT \(what): a search field shows, but none of \(leaveLabels) can be tapped, and the tab bar has "
                  + "\(left.count) buttons besides the search; \(facts(app))")
            return nil
        }

        /// The buttons of `leaveLabels` that can be tapped, but none of a dialog (an alert, an
        /// action sheet): its "Abbrechen" ends the dialog, never the search (review S10 of H14).
        private static func leaveButtons(_ app: XCUIApplication) -> [XCUIElement] {
            let dialogs = (app.alerts.allElementsBoundByIndex + app.sheets.allElementsBoundByIndex).map(\.frame)
            return app.buttons.matching(NSPredicate(format: "label IN %@", leaveLabels)).allElementsBoundByIndex
                .filter { button in button.isHittable && !dialogs.contains { $0.intersects(button.frame) } }
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
