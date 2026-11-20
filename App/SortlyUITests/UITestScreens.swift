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
/// - The tab "Unsortiert" (`Unsorted`): its filters `library.filter.<area>`.
/// - The tab "Alben" (`Albums`): "Verlauf und Rückgängig" (`albums.history`), the only way to
///   the history since 5C, and the album tiles (`album.tile`) with "…" and "Rückgängig machen".
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

    // MARK: Cards

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

    // MARK: Analysis

    enum Analysis {
        /// The start page's line once nothing runs (`analysis.summary`: "Alle N Fotos analysiert",
        /// "Analyse aktuell", "58 von 246 Fotos analysiert" or "Analyse fertig"), or right after
        /// a long run ("Analyse fertig", "N Vorschläge warten auf dich.", `analysis.finished`).
        /// Each opens the sheet "Analyse".
        static func line(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier IN %@", ["analysis.summary", "analysis.finished"])).firstMatch
        }

        /// Nothing runs and nothing waits: no "Pause", and the start page shows its line (a run
        /// that waits for the device or for Photos shows its card instead). The Pause button
        /// first: one query while the analysis runs.
        static func isIdle(_ app: XCUIApplication) -> Bool {
            !app.buttons["Pause"].exists && line(app).exists
        }

        /// What the start page and the sheet "Analyse" say about the photos.
        struct Counts {
            /// What was read: the line ("Alle 246 Fotos analysiert, …") or the sheet's headline
            /// ("58 von 246 Fotos analysiert").
            let label: String
            let analyzed: Int
            let photos: Int
            /// "12 Fotos konnten noch nicht gelesen werden", 0 without the note.
            let unreadable: Int
            /// How the image requests ended (the line's or the headline's value in UI runs).
            let loads: String
            /// The line or the sheet was there but could not be read: never taken as complete.
            var readFailed = false

            /// Photos the analysis never came to; unreadable ones it tried and keeps for later.
            var cutOff: Bool { readFailed || analyzed + unreadable < photos }
            /// Every photo analysed, none left unreadable.
            var complete: Bool { !readFailed && analyzed >= photos && unreadable == 0 }

            var unreadableText: String {
                "\(unreadable) of \(photos) photos could not be read ('\(label)', \(loads))"
            }
        }

        /// Opens the sheet "Analyse" from the start page's line; true once its headline shows.
        @discardableResult
        static func openSheet(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
            if app.buttons["analysis.summary.done"].exists { return headline(app).waitForExistence(timeout: timeout) }
            let row = line(app)
            guard row.waitForExistence(timeout: timeout) else {
                print("UI_FACT no analysis line (analysis.summary, analysis.finished) to open the sheet \"Analyse\"")
                return false
            }
            Cards.reach(row, in: app)
            row.tap()
            return headline(app).waitForExistence(timeout: timeout)
        }

        /// Closes the sheet "Analyse" if it is open.
        static func closeSheet(_ app: XCUIApplication) {
            let done = app.buttons["analysis.summary.done"]
            guard done.exists else { return }
            done.tap()
            _ = UITestWait.holds(timeout: 5) { !done.exists }
        }

        /// The sheet's headline: "Alle N Fotos analysiert", "N von M Fotos analysiert" or
        /// "Analyse aktuell" (the line on the page is a button, never a text).
        static func headline(_ app: XCUIApplication) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@ OR label == %@", "Fotos analysiert", "Analyse aktuell")).firstMatch
        }

        /// A snapshot of `element`, tried three times half a second apart: the count changes
        /// while the analysis runs, and reading `label` of an element that has just changed is a
        /// hard test failure ("No matches found", flow test 5 in UI run 44038288087, right after
        /// "checking again"). `gone`: the element went away between the tries.
        private static func snapshot(of element: XCUIElement) -> (shot: (any XCUIElementSnapshot)?, gone: Bool) {
            var taken: (any XCUIElementSnapshot)?
            var gone = false
            var tries = 0
            // Three tries end it; the 30 s cap only keeps the wait finite and visible to the
            // time-limit rule (second review of P5-05).
            _ = UITestWait.holds(timeout: 30) {
                tries += 1
                if let snapshot = try? element.snapshot() { taken = snapshot; return true }
                gone = !element.exists
                return gone || tries >= 3
            }
            return (taken, gone)
        }

        private static func number(_ text: Substring) -> Int { Int(text.filter(\.isNumber)) ?? 0 }

        /// The counts once nothing runs, or nil when the page shows no line within `wait` (or it
        /// went while it was read: a run started). "Alle N Fotos analysiert" and "Analyse
        /// aktuell" are read from the line (nothing follows later then); "58 von 246 Fotos
        /// analysiert" and "Analyse fertig" (something follows later, or a run that just
        /// finished) from the sheet "Analyse", which also says how many photos could not be
        /// read; it is opened and closed again. A line or a sheet that cannot be read is
        /// `readFailed`, never complete (it was, while `try?` gave nil).
        static func counts(_ app: XCUIApplication, wait: TimeInterval = 3) -> Counts? {
            let row = line(app)
            guard row.waitForExistence(timeout: wait) else { return nil }
            let read = snapshot(of: row)
            if read.gone { return nil }
            guard let shot = read.shot else {
                print("UI_FACT analysis: the line is on screen but could not be read three times")
                return Counts(label: "(not readable)", analyzed: 0, photos: 0, unreadable: 0, loads: "", readFailed: true)
            }
            let lineLabel = shot.label
            let lineLoads = (shot.value as? String) ?? ""
            if let m = lineLabel.firstMatch(of: #/^Alle ([0-9.]+) Fotos analysiert/#) {
                let photos = number(m.1)
                return Counts(label: lineLabel, analyzed: photos, photos: photos, unreadable: 0, loads: lineLoads)
            }
            if lineLabel.hasPrefix("Analyse aktuell") {
                return Counts(label: lineLabel, analyzed: 0, photos: 0, unreadable: 0, loads: lineLoads)
            }
            // "58 von 246 Fotos analysiert" or "Analyse fertig": the sheet says how far, and what
            // could not be read.
            guard openSheet(app) else {
                closeSheet(app)
                print("UI_FACT analysis: '\(lineLabel)' and the sheet \"Analyse\" did not open")
                return Counts(label: lineLabel, analyzed: 0, photos: 0, unreadable: 0, loads: lineLoads, readFailed: true)
            }
            defer { closeSheet(app) }
            guard let sheet = snapshot(of: headline(app)).shot else {
                print("UI_FACT analysis: the sheet's count could not be read three times")
                return Counts(label: lineLabel, analyzed: 0, photos: 0, unreadable: 0, loads: lineLoads, readFailed: true)
            }
            let label = sheet.label
            let sheetLoads = (sheet.value as? String) ?? ""
            let loads = sheetLoads.isEmpty ? lineLoads : sheetLoads
            var analyzed = 0, photos = 0
            if let m = label.firstMatch(of: #/([0-9.]+) von ([0-9.]+) Fotos analysiert/#) {
                analyzed = number(m.1)
                photos = number(m.2)
            } else if let m = label.firstMatch(of: #/Alle ([0-9.]+) Fotos analysiert/#) {
                analyzed = number(m.1)
                photos = analyzed
            } else if label != "Analyse aktuell" {
                print("UI_FACT analysis: the sheet says '\(label)'")
                return Counts(label: label, analyzed: 0, photos: 0, unreadable: 0, loads: loads, readFailed: true)
            }
            let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "konnten noch nicht gelesen")).firstMatch
            let noteLabel = note.exists ? (try? note.snapshot())?.label : nil
            let unreadable = noteLabel.map { $0.split(separator: " ").first.map(number) ?? 0 } ?? 0
            return Counts(label: label, analyzed: analyzed, photos: photos, unreadable: unreadable, loads: loads)
        }

        /// "Neu prüfen" in the sheet "Analyse" (it closes the sheet as the check starts).
        @discardableResult
        static func checkAgain(_ app: XCUIApplication, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let again = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Neu prüfen"))
            guard openSheet(app), again.firstMatch.waitForExistence(timeout: 5) else {
                closeSheet(app)
                print("UI_STEP_MISSING \(what): no \"Neu prüfen\" in the sheet \"Analyse\"")
                XCTFail("\(what): no \"Neu prüfen\" in the sheet \"Analyse\"", file: file, line: line)
                return false
            }
            reachable(again).tap()
            print("UI_STEP_OK \(what)")
            _ = UITestWait.holds(timeout: 5) { !app.buttons["analysis.summary.done"].exists }
            return true
        }
    }

    // MARK: Start page

    enum StartPage {
        /// The start page's title (and its tab's name).
        static let title = "Vorschläge"

        /// "Alle N" of an area's row (`startPage.all.<area>`): trips first, they are the ones
        /// the demo library has most of; else any area's.
        static func allSuggestions(_ app: XCUIApplication, area: String = "trips") -> XCUIElement {
            let wanted = app.buttons["startPage.all.\(area)"]
            if wanted.exists { return wanted }
            let any = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startPage.all.")).firstMatch
            return any.exists ? any : wanted
        }

        /// "Dein Startpaket": up to ten suggestions as one preview, while nothing is made yet.
        static func starterSet(_ app: XCUIApplication) -> XCUIElement {
            app.buttons["starterSet.create"]
        }

        /// Opens the list of an area's suggestions from the start page ("Alle N" of the row),
        /// scrolled to first. True once a card of the list shows (`suggestion.row`).
        @discardableResult
        static func openList(_ app: XCUIApplication, area: String = "trips", _ what: String,
                             timeout: TimeInterval = 20) -> Bool {
            var all = allSuggestions(app, area: area)
            var swipes = 0
            while !all.exists && swipes < 6 {
                app.swipeUp()
                swipes += 1
                _ = all.waitForExistence(timeout: 1)
                all = allSuggestions(app, area: area)
            }
            guard all.waitForExistence(timeout: timeout) else {
                print("UI_FACT \(what): no \"Alle N\" of an area on the start page")
                return false
            }
            Cards.reach(all, in: app)
            all.tap()
            print("UI_STEP_OK \(what): \(all.identifier)")
            return UITestWait.holds(timeout: 10) { SuggestionList.cards(app).firstMatch.exists }
        }

        /// The preview of several suggestions, as a new user makes it: "Dein Startpaket" while
        /// the page offers it, else an area's list ("Alle N") with "Auswählen", "Alle auswählen"
        /// and "N Alben anlegen". True once the preview ("Vorschau") shows; false (with a log
        /// line) when the page offers neither, which the caller judges.
        @discardableResult
        static func openPlan(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 30) -> Bool {
            let starter = starterSet(app)
            let anyAll = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startPage.all.")).firstMatch
            _ = UITestWait.holds(timeout: timeout) { starter.exists || anyAll.exists }
            if starter.exists {
                Cards.reach(starter, in: app)
                starter.tap()
                print("UI_STEP_OK \(what): Dein Startpaket")
                return app.navigationBars["Vorschau"].waitForExistence(timeout: 30)
            }
            guard openList(app, what, timeout: 5) else {
                print("UI_FACT \(what): neither \"Dein Startpaket\" nor \"Alle N\" on the start page")
                return false
            }
            return SuggestionList.createAll(app, what)
        }
    }

    // MARK: List of suggestions

    enum SuggestionList {
        /// The cards of the list (`suggestion.row`): body `photoCard.body`, one action button.
        static func cards(_ app: XCUIApplication) -> XCUIElementQuery {
            app.descendants(matching: .any).matching(identifier: "suggestion.row")
        }

        /// The first card whose name or status contains `text`, scrolled to: the list builds
        /// its cards only once they come near. Nil when none shows within `swipes` swipes.
        static func card(_ app: XCUIApplication, containing text: String, swipes: Int = 8) -> XCUIElement? {
            let card = cards(app).containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            if card.waitForExistence(timeout: 5) { return card }
            var tries = 0
            while !card.exists && tries < swipes {
                app.swipeUp()
                tries += 1
                _ = card.waitForExistence(timeout: 1)
            }
            return card.exists ? card : nil
        }

        /// "Auswählen" (`suggestions.select`): the list ticks instead of opening; true once
        /// "Alle auswählen" shows. False when the list has nothing a tick can take (the button
        /// is off: every card needs its own page first).
        @discardableResult
        static func select(_ app: XCUIApplication, _ what: String) -> Bool {
            let select = app.buttons["suggestions.select"]
            guard select.waitForExistence(timeout: 10) else {
                print("UI_FACT \(what): no \"Auswählen\" in the list")
                return false
            }
            guard UITestWait.holds(timeout: 5, { select.isEnabled }) else {
                print("UI_FACT \(what): \"Auswählen\" is off, nothing in the list can be ticked")
                return false
            }
            select.tap()
            return app.buttons["suggestions.selectAll"].waitForExistence(timeout: 5)
        }

        /// "N Alben anlegen" (`suggestions.createSelected`) while the list ticks.
        static func createSelected(_ app: XCUIApplication) -> XCUIElement {
            app.buttons["suggestions.createSelected"]
        }

        /// "Auswählen", "Alle auswählen", "N Alben anlegen": the preview of every suggestion of
        /// the list a tick can take. True once the preview ("Vorschau") shows.
        @discardableResult
        static func createAll(_ app: XCUIApplication, _ what: String) -> Bool {
            guard select(app, what) else { return false }
            let create = createSelected(app)
            app.buttons["suggestions.selectAll"].tap()
            guard UITestWait.holds(timeout: 5, { create.exists && create.isEnabled }) else {
                print("UI_FACT \(what): \"Alle auswählen\" ticked nothing (\(create.exists ? create.label : "no button"))")
                return false
            }
            print("UI_STEP_OK \(what): '\(create.label)'")
            create.tap()
            return app.navigationBars["Vorschau"].waitForExistence(timeout: 30)
        }
    }

    // MARK: One suggestion

    /// The page of one suggestion (draft E2): cover, facts, photos by day, its own bar.
    enum SuggestionPage {
        /// What only the page has, while photos are picked too: its bar ("Nicht jetzt" and the
        /// filled button) or its "Auswählen"/"Fertig" for the photos. The bar's title stays
        /// "Vorschlag", but since wave 1 the bar shows the album's name (a principal item) once
        /// the page's own title went under it, so the title alone is not relied on.
        static func marker(_ app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", [
                "proposal.bar", "proposal.create", "proposalPhotos.select", "proposalPhotos.selectDone",
            ])).firstMatch
        }

        static func isShown(_ app: XCUIApplication) -> Bool {
            app.navigationBars["Vorschlag"].exists || marker(app).exists
        }

        /// The page's bar (`proposal.bar`), gone while photos are picked.
        static func bar(_ app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any)["proposal.bar"]
        }

        /// "Auswählen" for the photos (`proposalPhotos.select`); by its name where the bar does
        /// not pass the identifier on.
        static func selectPhotos(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "proposalPhotos.select", "Auswählen")).firstMatch
        }

        /// "Fertig" while photos are picked (`proposalPhotos.selectDone`).
        static func endSelection(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "proposalPhotos.selectDone", "Fertig")).firstMatch
        }

        /// The first photo of the page clear of the bars at the top and at the bottom (the
        /// page's own bar, or the bottom bar while photos are picked). The photos come below
        /// the cover and the facts and are built once they come near: slow swipes, because a
        /// fast one can fling the first rows under the top bar. Nil when none is clear within
        /// four swipes.
        static func photoInReach(_ app: XCUIApplication) -> XCUIElement? {
            let photos = app.buttons.matching(identifier: "proposalPhotos.photo")
            let top = app.navigationBars.firstMatch
            let toolbar = app.toolbars.firstMatch
            let pageBar = bar(app)
            func clear(_ photo: XCUIElement) -> Bool {
                guard photo.isHittable else { return false }
                let frame = photo.frame
                if top.exists && frame.minY < top.frame.maxY { return false }
                if toolbar.exists && toolbar.frame.minY > app.frame.midY && frame.maxY > toolbar.frame.minY { return false }
                return !(pageBar.exists && frame.maxY > pageBar.frame.minY)
            }
            for swipe in 0...4 {
                if swipe > 0 { app.swipeUp(velocity: .slow) }
                guard photos.firstMatch.waitForExistence(timeout: swipe == 0 ? 3 : 1) else { continue }
                if let photo = photos.allElementsBoundByIndex.prefix(12).first(where: clear) { return photo }
            }
            return nil
        }

        /// The number of photos in the facts line under the name: "16 Fotos · 12. bis 16.
        /// Oktober", "1 Foto · 12. Oktober", "1.354 Fotos · …"; a bare "16 Fotos" only where no
        /// line with days shows (the album card's "Vielleicht passend" is a bare count too).
        /// Nil while it does not show.
        static func photoCount(_ app: XCUIApplication) -> Int? {
            let dated = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos? · .*")).firstMatch
            let facts = dated.exists
                ? dated : app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos?")).firstMatch
            guard facts.exists else { return nil }
            return facts.label.firstMatch(of: #/^([0-9.]+) Foto/#).flatMap { Int($0.1.filter(\.isNumber)) }
        }
    }

    // MARK: After "Anlegen"

    enum QuickCreate {
        /// "„Name“ angelegt" with "Widerrufen" (`quickCreate.banner`).
        static func banner(_ app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any)["quickCreate.banner"]
        }

        /// "Widerrufen" in the banner.
        static func undo(_ app: XCUIApplication) -> XCUIElement {
            app.buttons["quickCreate.undo"]
        }

        /// iOS asks before Albumist deletes the album it made (P3-07): answered with "Löschen".
        /// True when it asked; stops waiting once `done` holds.
        @discardableResult
        static func answerDeleteQuestion(_ app: XCUIApplication, timeout: TimeInterval = 20, done: () -> Bool) -> Bool {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            var answered = false
            _ = UITestWait.holds(timeout: timeout) {
                for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                    let delete = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Löschen"])).firstMatch
                    guard delete.exists else { continue }
                    delete.tap()
                    answered = true
                    return true
                }
                return done()
            }
            print(answered ? "UI_STEP_OK delete question answered" : "UI_FACT no delete question")
            return answered
        }
    }

    // MARK: Purchase sheet

    enum Purchase {
        /// "Albumist freischalten" as a sheet (`unlock.sheet`).
        static func sheet(_ app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any)["unlock.sheet"]
        }

        /// The sheet offers what draft E6 shows: one button with the App Store's price
        /// (`unlock.buy`: "Preis wird geladen …" until StoreKit answers; no purchase in UI runs,
        /// the CI simulator has no App Store account), "Kauf wiederherstellen", "Code einlösen",
        /// and "Schließen", which closes it. True once it is closed again.
        @discardableResult
        static func expectOffersAndClose(_ app: XCUIApplication, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
            guard UITestWait.appears(sheet(app), "\(what): purchase sheet", timeout: 10, file: file, line: line) else { return false }
            for (identifier, name) in [("unlock.buy", "price button"), ("unlock.restore", "Kauf wiederherstellen"),
                                       ("unlock.redeem", "Code einlösen")] {
                let shown = app.buttons[identifier].waitForExistence(timeout: 3)
                print(shown ? "UI_STEP_OK \(what): \(name)" : "UI_STEP_MISSING \(what): \(name)")
                XCTAssertTrue(shown, "\(what): the purchase sheet has no \(name) (\(identifier))", file: file, line: line)
            }
            let close = app.buttons["unlock.close"]
            guard close.waitForExistence(timeout: 3) else {
                print("UI_STEP_MISSING \(what): Schließen")
                XCTFail("\(what): the purchase sheet has no \"Schließen\" (unlock.close)", file: file, line: line)
                return false
            }
            close.tap()
            return UITestWait.disappears(sheet(app), "\(what): purchase sheet closed", timeout: 10, file: file, line: line)
        }
    }

    // MARK: Unsorted

    enum Unsorted {
        /// The tab's three filters (`LibraryBuckets.unsortedTabFilters`), "Unsortiert" first.
        static let filters = ["unorganized", "uncertain", "ignored"]

        /// One filter's chip, at the standard text sizes.
        static func filter(_ app: XCUIApplication, _ area: String) -> XCUIElement {
            app.buttons["library.filter.\(area)"]
        }

        /// Shows the filter: its chip at the standard text sizes; at the accessibility sizes
        /// the menu (`library.filter`), then the choice by its name.
        @discardableResult
        static func show(_ app: XCUIApplication, _ area: String, named name: String, _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let chip = filter(app, area)
            if chip.waitForExistence(timeout: 5) {
                chip.tap()
                print("UI_STEP_OK \(what)")
                return true
            }
            let menu = app.buttons["library.filter"]
            guard menu.waitForExistence(timeout: 3) else {
                print("UI_STEP_MISSING \(what): neither the chip nor the menu")
                XCTFail("\(what): no filter \(area) in the tab \"Unsortiert\"", file: file, line: line)
                return false
            }
            menu.tap()
            let choice = app.buttons[name]
            guard choice.waitForExistence(timeout: 5) else {
                print("UI_STEP_MISSING \(what): no \"\(name)\" in the menu")
                XCTFail("\(what): no \"\(name)\" in the menu of the tab \"Unsortiert\"", file: file, line: line)
                return false
            }
            choice.tap()
            print("UI_STEP_OK \(what) (menu)")
            return true
        }
    }

    // MARK: Albums

    enum Albums {
        /// "Verlauf und Rückgängig" in the tab "Alben" (`albums.history`): the only way to the
        /// history since 5C (it left the settings).
        static func historyRow(_ app: XCUIApplication) -> XCUIElement {
            app.buttons["albums.history"]
        }

        /// Opens the history from the tab "Alben" (the caller has the tab open). True once its
        /// screen shows.
        @discardableResult
        static func openHistory(_ app: XCUIApplication, title: String = "Verlauf und Rückgängig", _ what: String,
                                timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let row = historyRow(app)
            var swipes = 0
            while !row.exists && swipes < 6 {
                app.swipeUp()
                swipes += 1
                _ = row.waitForExistence(timeout: 1)
            }
            guard row.waitForExistence(timeout: timeout) else {
                print("UI_STEP_MISSING \(what): no albums.history in the tab \"Alben\"")
                XCTFail("\(what): no \"Verlauf und Rückgängig\" (albums.history) in the tab \"Alben\"", file: file, line: line)
                return false
            }
            Cards.reach(row, in: app)
            row.tap()
            print("UI_STEP_OK \(what)")
            return app.navigationBars[title].waitForExistence(timeout: timeout)
        }

        /// The tile of the album named `title` (`album.tile`, its body says "Title, 2 Fotos"), in
        /// the tab "Alben" the caller has open: on the shelf "Von Albumist" (newest first; tiles
        /// far along it are built only once scrolled to), else behind the shelf's "Alle N"
        /// (`albums.managed`, which stays open then), else further down under "Deine Alben". Nil
        /// when it shows in none of them.
        static func tile(_ app: XCUIApplication, titled title: String) -> XCUIElement? {
            let tile = app.descendants(matching: .any).matching(identifier: "album.tile")
                .containing(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
            if tile.waitForExistence(timeout: 10) { return tile }
            let all = app.buttons["albums.managed"]
            if all.exists {
                Cards.reach(all, in: app)
                all.tap()
                if tile.waitForExistence(timeout: 10) { return tile }
            }
            var swipes = 0
            while !tile.exists && swipes < 3 {
                app.swipeUp()
                swipes += 1
                _ = tile.waitForExistence(timeout: 1)
            }
            return tile.exists ? tile : nil
        }

        /// "…" in an album of Albumist's with something to undo (`album.more`); by its name where
        /// the bar does not pass the identifier on.
        static func more(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "album.more", "Weitere Aktionen")).firstMatch
        }

        /// "Rückgängig machen" in that menu or in the long press on the tile (`album.undo`); its
        /// second line may be part of its name.
        static func undo(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "album.undo", "Rückgängig machen")).firstMatch
        }
    }
}
