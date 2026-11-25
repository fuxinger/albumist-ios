import XCTest

/// The start page's ways to several suggestions, the list and the page of one suggestion, the
/// banner after "Anlegen" and the purchase sheet as the UI tests reach them (`UITestScreens`;
/// a file of its own for SwiftLint's file length).
extension UITestScreens {
    // MARK: Start page

    @MainActor
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
                print("UI_FACT \(what): no \"Alle N\" of an area on the start page; it shows \(facts(app))")
                return false
            }
            Cards.reach(all, in: app)
            // Read before the tap: the pushed list takes the start page out of the tree, and an
            // element read after it fails the test (UI run 44852630315, `UITestHelperSourceTests`).
            let identifier = all.identifier
            all.tap()
            print("UI_STEP_OK \(what): \(identifier)")
            return UITestWait.holds(timeout: 10) { SuggestionList.cards(app).firstMatch.exists }
        }

        /// What the start page shows, for the line of a step that found nothing there: its parts
        /// (`startPage.…`, at most twelve), how many suggestion cards, the bar's title and the
        /// selected tab. Read from one snapshot, so nothing goes away between two reads.
        static func facts(_ app: XCUIApplication) -> String {
            guard let root = try? app.snapshot() else { return "nothing (no snapshot of the app)" }
            var parts: [String] = []
            var cards = 0
            var bar = "-"
            var tab = "-"
            var stack: [(node: any XCUIElementSnapshot, inTabBar: Bool)] = [(root, false)]
            while let entry = stack.popLast() {
                let node = entry.node
                let identifier = node.identifier
                if identifier.hasPrefix("startPage."), parts.count < 12 { parts.append(identifier) }
                if identifier.hasPrefix("suggestion.card.") { cards += 1 }
                if node.elementType == .navigationBar, bar == "-" { bar = identifier.isEmpty ? node.label : identifier }
                if entry.inTabBar, node.elementType == .button, node.isSelected { tab = node.label }
                let below = entry.inTabBar || node.elementType == .tabBar
                for child in node.children.reversed() { stack.append((child, below)) }
            }
            return "parts [\(parts.joined(separator: ", "))], \(cards) suggestion cards, bar '\(bar)', tab '\(tab)'"
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

    @MainActor
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
    @MainActor
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

    @MainActor
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

    @MainActor
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
}
