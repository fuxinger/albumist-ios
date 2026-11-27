import XCTest

/// The screens of design wave 1 as every UI test reaches them, by identifier wherever a screen
/// gives one: the words change with the design and the language, the identifiers stay.
///
/// - Tabs (6B): "Vorschläge · Unsortiert · Alben · Suche" (`Tabs`).
/// - Cards of the start page (`Cards`): a `PhotoCard` is a container named by the screen's
///   identifier (`suggestion.card.<create|add|name|look|made>`); its body (`photoCard.body`)
///   opens it, its action ("Anlegen", "Ergänzen …", "Benennen …", "Ansehen …") is a real button
///   after the body, named with the album for VoiceOver („Kyoto, Oktober 2024“ anlegen).
/// - The analysis (`Analysis`): once nothing runs, the start page's line "Alle N Fotos
///   analysiert", "Analyse aktuell", "58 von 246 Fotos analysiert" (cut off part way) or
///   "Analyse fertig" (something follows later) (`analysis.summary`), right after a long run
///   "Analyse fertig" with the suggestions waiting (`analysis.finished`). Either opens the sheet
///   "Analyse" with the count, the photos that could not be read and "Neu prüfen" (which closes
///   the sheet).
/// - The start page's ways to several suggestions at once (`StartPage`): "Dein Startpaket"
///   (`starterSet.create`) and "Alle N" of an area (`startPage.all.<area>`).
/// - The list of suggestions (`SuggestionList`): cards two in a row (`suggestion.row`), and
///   "Auswählen" as in Photos: "Alle auswählen", then "N Alben anlegen" opens the preview.
/// - One suggestion (`SuggestionPage`): the facts line "16 Fotos · 12. bis 16. Oktober", the
///   photos by day (`proposalPhotos.photo`) and the page's own bar (`proposal.bar`).
/// - After "Anlegen" on a card (`QuickCreate`): the banner "„Name“ angelegt" with "Widerrufen".
/// - The purchase sheet (`Purchase`): "Albumist freischalten" with the price, "Kauf
///   wiederherstellen", "Code einlösen" and "Schließen".
/// - The tab "Unsortiert" (`Unsorted`): its filters `library.filter.<area>`, and "Anlegen …" in
///   its sheet "Zu Album hinzufügen" (`addToAlbum.create`).
/// - The tab "Alben" (`Albums`): "Verlauf und Rückgängig" (`albums.history`), the only way to
///   the history since 5C, and the album tiles (`album.tile`) with "…" and "Rückgängig machen".
///
/// Each part is `@MainActor` of its own: a type nested in a main-actor type is not on the main
/// actor by itself, and XCUIApplication and XCUIElement belong to it.
///
/// The tabs and the cards are here; the search, the analysis with the trial year, the start
/// page with the suggestions and the purchase sheet, and the tabs "Unsortiert" and "Alben" are
/// in files beside it (`UITestScreens+Search.swift` and the like).
@MainActor
enum UITestScreens {
    /// The tab names as Localizable.xcstrings says them (the search tab carries the system's own).
    struct Tabs: Sendable {
        let suggestions: String
        let unsorted: String
        let albums: String

        static let german = Tabs(suggestions: "Vorschläge", unsorted: "Unsortiert", albums: "Alben")
        static let english = Tabs(suggestions: "Suggestions", unsorted: "Unsorted", albums: "Albums")
        /// The names of before 6B: a tab bar that still shows one of them is the old frame.
        static let before = ["Übersicht", "Mediathek", "Overview", "Library"]
    }

    /// The element of `query` that can be tapped: a sheet at half height leaves the page below
    /// it in the tree, with buttons of the same name ("Neu prüfen" is on both when the library
    /// is empty).
    static func reachable(_ query: XCUIElementQuery) -> XCUIElement {
        query.allElementsBoundByIndex.first(where: \.isHittable) ?? query.firstMatch
    }

    /// The photo viewer's position ("3 von 176") of the photo on screen ("viewer.position"): the
    /// photo's value, its label being where and when it was taken. Nil when it cannot be read.
    static func viewerPosition(_ element: XCUIElement) -> String? {
        guard let snapshot = try? element.snapshot() else { return nil }
        return snapshot.value as? String
    }

    // MARK: Tabs

    /// A tab bar button by its name ("Vorschläge", "Unsortiert", "Alben"; the search tab is
    /// `Search.button`): the one every UI test class uses (review S7 of H14; the photo grid's
    /// and the show's tests keep their own copies for now, neither searches). While a search
    /// field shows and the button is missing or cannot be tapped, the search is left first
    /// (`Search.leave`): iOS may fold the tabs into one button beside an active search, and the
    /// keyboard covers the bar (review S4). Then up to two swipes down for a bar that scrolled
    /// away; never a tap into the bar, whose middle is another tab (review S10; in UI runs the
    /// bar does not shrink, `tabBarMinimizeBehavior(.never)`).
    static func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        func ready() -> Bool { button.exists && button.isHittable }
        if !ready(), app.searchFields.firstMatch.exists {
            Search.leave(app, "tab \(name)")
        }
        expandTabBar(app) { ready() }
        if !ready() { print("UI_FACT tab \(name) cannot be tapped; the tab bar shows \(Search.barFacts(app))") }
        return button
    }

    /// Brings back a tab bar that scrolled away: up to two swipes down, each followed by up to a
    /// second for `done`. No tap into the bar (review S10 of H14).
    static func expandTabBar(_ app: XCUIApplication, until done: () -> Bool) {
        var swipes = 0
        while !done() && swipes < 2 {
            app.swipeDown()
            // The bar expands after the swipe: on as soon as `done`, else the next swipe.
            _ = UITestWait.holds(timeout: 1, done)
            swipes += 1
        }
    }

    // MARK: Cards

    @MainActor
    enum Cards {
        /// The four actions a suggestion card can have (`ProposalCardAction`).
        static let actions = ["create", "add", "name", "look"]

        /// The suggestion cards on screen with `action` ("create", "add", "name" or "look"), or
        /// with any action when nil. A made card (`suggestion.card.made`) is not among them.
        static func cards(_ app: XCUIApplication, action: String? = nil) -> XCUIElementQuery {
            let identifiers = (action.map { [$0] } ?? actions).map { "suggestion.card.\($0)" }
            return app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", identifiers))
        }

        /// The first card with `action`, scrolled to: a shelf or a list may build a card only
        /// once it comes near. Up to `swipes` swipes up.
        static func first(_ app: XCUIApplication, action: String? = nil, swipes: Int = 6, timeout: TimeInterval = 10) -> XCUIElement? {
            let card = cards(app, action: action).firstMatch
            if card.waitForExistence(timeout: timeout) { return card }
            var tries = 0
            while !card.exists && tries < swipes {
                app.swipeUp()
                tries += 1
                _ = card.waitForExistence(timeout: 1)
            }
            return card.exists ? card : nil
        }

        /// The card's action button: any button of the card but its body.
        static func action(of card: XCUIElement) -> XCUIElement {
            card.buttons.matching(NSPredicate(format: "identifier != %@", "photoCard.body")).firstMatch
        }

        /// The card's button says `word` ("anlegen", "ergänzen", "benennen", "ansehen" or, once
        /// made, "angelegt"). VoiceOver's name of it holds the album since the second review of
        /// the cards („Kyoto, Oktober 2024“ anlegen, „Toskana“ ergänzen); the button shows only
        /// the word ("Anlegen", "Ergänzen …"), which was its name before.
        static func button(_ button: XCUIElement, says word: String) -> Bool {
            let label = button.label
            return label.hasSuffix("“ \(word)") || label.lowercased().hasPrefix(word)
        }

        /// Elements named as `button(_:says:)` takes them, for `containing` on a list's cards.
        static func saying(_ word: String) -> NSPredicate {
            NSPredicate(format: "label ENDSWITH %@ OR label BEGINSWITH[c] %@", "“ \(word)", word)
        }

        /// The album's name in the card's button („Kyoto, Oktober 2024“ anlegen: Kyoto, Oktober
        /// 2024; for "ergänzen" the album that gets the photos); nil for a button named only by
        /// its word.
        static func albumName(of card: XCUIElement) -> String? {
            let label = action(of: card).label
            guard let open = label.firstIndex(of: "„"), let close = label.lastIndex(of: "“"), open < close else { return nil }
            return String(label[label.index(after: open)..<close])
        }

        /// The card named `identifier` whose body starts with `title` ("Kyoto, Oktober 2024, 16
        /// Fotos · …": the line under the name may change meanwhile).
        static func card(_ app: XCUIApplication, identifier: String, titled title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier)
                .containing(NSPredicate(format: "identifier == %@ AND (label == %@ OR label BEGINSWITH %@)",
                                        "photoCard.body", title, "\(title), ")).firstMatch
        }

        /// Taps the card's action ("Anlegen", "Ergänzen …", "Benennen …", "Ansehen …"), scrolled
        /// into reach first. A card without an action button fails here with what is missing:
        /// never a tap at a guessed point, which could open the card instead.
        @discardableResult
        static func tapAction(of card: XCUIElement, in app: XCUIApplication, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let button = action(of: card)
            guard card.exists, button.waitForExistence(timeout: 3) else {
                print("UI_STEP_MISSING \(what): \(card.exists ? "the card has no action button" : "no card")")
                XCTFail("\(what): \(card.exists ? "the card '\(card.identifier)' has no button besides photoCard.body" : "no card")",
                        file: file, line: line)
                return false
            }
            reach(button, in: app)
            print("UI_STEP_OK \(what): '\(button.label)' on \(card.identifier)")
            button.tap()
            return true
        }

        /// Opens the card, as a tap on its photo or its name does.
        @discardableResult
        static func open(_ card: XCUIElement, in app: XCUIApplication, _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
            guard card.exists else {
                print("UI_STEP_MISSING \(what): no card")
                XCTFail("\(what): no card", file: file, line: line)
                return false
            }
            let body = card.buttons["photoCard.body"]
            let target = body.exists ? body : card
            reach(target, in: app)
            print("UI_STEP_OK \(what) (\(body.exists ? "photoCard.body" : "the card"))")
            target.tap()
            return true
        }

        /// Swipes until `element` can be tapped and is clear of the tab bar and of a bar at the
        /// bottom (a tap there lands on the bar), at most four times.
        static func reach(_ element: XCUIElement, in app: XCUIApplication) {
            let tabs = app.tabBars.firstMatch
            let bottom = app.toolbars.firstMatch
            func covered() -> Bool {
                let maxY = element.frame.maxY
                if tabs.exists && maxY > tabs.frame.minY { return true }
                return bottom.exists && bottom.frame.minY > app.frame.midY && maxY > bottom.frame.minY
            }
            var swipes = 0
            while swipes < 4, element.exists, !element.isHittable || covered() {
                app.swipeUp()
                swipes += 1
            }
        }
    }
}
