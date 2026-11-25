import XCTest
import UIKit

/// The frame of design wave 1: the tabs by their new names in both languages (decision 6B),
/// the three filters of "Unsortiert", and "Anlegen" on a card with its banner and "Widerrufen"
/// (decision 7B). Each test brings the app to an onboarded demo library by itself
/// (`UITestOnboarding`); in CI the class runs in the group flow-other (.github/ui-groups.json),
/// first of its classes (XCTest runs them in alphabetical order), so its first test usually
/// onboards. Log conventions as in AlbumistFlowUITests: `UI_STEP_OK` / `UI_STEP_MISSING`,
/// `UI_FACT`, screenshots as `PREVIEW_JPEG ui-frame-…` chunks.
@MainActor
final class FrameUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers

    private func launch(english: Bool = false) {
        // UITestAppEnd.launch ends the app of the last launch first.
        app = XCUIApplication()
        let language = english ? ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] : ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = language + ["-AlbumistUITestUnlocked"] + UITestStalls.arguments(besides: [])
        UITestAppEnd.launch(app)
    }

    /// An onboarded demo library whose analysis is done (made here when no test before made
    /// it), in German, with the start page at rest.
    private func prepare(_ test: String) {
        launch()
        UITestOnboarding.completeIfNeeded(app, in: test)
        let idle = UITestWait.holds(timeout: 120) { UITestScreens.Analysis.isIdle(app) }
        print(idle ? "UI_STEP_OK \(test): start page at rest" : "UI_STEP_MISSING \(test): start page at rest")
        XCTAssertTrue(idle, "\(test): the start page does not come to rest (the analysis still runs or waits)")
    }

    /// A tab bar button (`UITestScreens.tabButton`: leaves an active search first, brings a bar
    /// that scrolled away back).
    private func tabButton(_ name: String) -> XCUIElement {
        UITestScreens.tabButton(app, name)
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
            XCTFail("Missing: \(step)")
            return false
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "frame-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let small = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = small.jpegData(compressionQuality: 0.55) else { return }
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG ui-frame-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    // MARK: 1 Tabs

    /// The tabs are called as the design says (decision 6B): "Vorschläge", "Unsortiert" and
    /// "Alben" before the search, in English "Suggestions", "Unsorted" and "Albums". None of the
    /// names from before ("Übersicht", "Mediathek", "Overview", "Library") is left in either
    /// language.
    func test1_TabNamesInGermanAndEnglish() {
        continueAfterFailure = true
        prepare("FrameUITests.test1")
        for (english, tabs) in [(false, UITestScreens.Tabs.german), (true, UITestScreens.Tabs.english)] {
            let language = english ? "English" : "German"
            if english { launch(english: true) }
            let bar = app.tabBars.firstMatch
            guard UITestWait.appears(bar, "tab bar (\(language))", timeout: 30) else { continue }
            let wanted = [tabs.suggestions, tabs.unsorted, tabs.albums]
            for name in wanted {
                let shown = bar.buttons[name].waitForExistence(timeout: 5)
                print(shown ? "UI_STEP_OK tab \(name)" : "UI_STEP_MISSING tab \(name)")
                XCTAssertTrue(shown, "The tab bar (\(language)) has no tab \"\(name)\"")
            }
            let names = bar.buttons.allElementsBoundByIndex.map(\.label)
            print("UI_FACT tabs (\(language)): \(names)")
            for old in UITestScreens.Tabs.before {
                XCTAssertFalse(names.contains(old), "The tab bar (\(language)) still has the tab \"\(old)\" from before design wave 1")
            }
            // In the design's order, the search after them.
            let places = wanted.compactMap { names.firstIndex(of: $0) }
            XCTAssertEqual(places, places.sorted(), "The tabs (\(language)) are not in the order \(wanted): \(names)")
            // The search (DS-12a): Apple's search tab, a round button at the trailing end of the
            // bar (or, behind `MainTabs.searchField`, a fourth tab in the row). That it is there
            // and after "Alben" is asserted; its shape and gap are said for the screenshots until
            // the owner has chosen between the two.
            let search = UITestScreens.Search.button(app)
            let searchShown = search.waitForExistence(timeout: 5)
            XCTAssertTrue(searchShown, "The tab bar (\(language)) has no search button")
            let albums = bar.buttons[tabs.albums]
            if searchShown, albums.exists {
                let frame = search.frame
                let gap = frame.minX - albums.frame.maxX
                print("UI_FACT search button (\(language)): \(Int(frame.width)) x \(Int(frame.height)) pt at \(Int(frame.minX)),\(Int(frame.minY)); round \(abs(frame.width - frame.height) < 8); \(Int(gap)) pt after \"\(tabs.albums)\"; in the tab bar \(bar.buttons[search.label].exists)")
                XCTAssertGreaterThan(frame.midX, albums.frame.midX, "The search button (\(language)) is not after \"\(tabs.albums)\"")
            }
            shot("tabs-\(english ? "en" : "de")")
        }
    }

    // MARK: 2 Unsortiert

    /// "Unsortiert" (decision 6B) has three filters: "Unsortiert", chosen as the tab opens, then
    /// "Unsicher" and "Ignoriert". "Vorschläge", "Sortiert" and "Alle" are no filters of it
    /// (suggestions have their own tab). A tap chooses a filter and the chip says so: the
    /// selected trait VoiceOver reads, on that chip alone.
    func test2_UnsortedTabHasThreeFilters() {
        continueAfterFailure = true
        prepare("FrameUITests.test2")
        let title = UITestScreens.Tabs.german.unsorted
        guard tap(tabButton(title), "tab \(title)") else { return }
        UITestWait.appears(app.navigationBars[title], "\(title) shown", timeout: 10)
        let areas = UITestScreens.Unsorted.filters
        let chips = areas.map { UITestScreens.Unsorted.filter(app, $0) }
        for (area, chip) in zip(areas, chips) {
            let shown = chip.waitForExistence(timeout: 10)
            print(shown ? "UI_STEP_OK filter \(area)" : "UI_STEP_MISSING filter \(area)")
            XCTAssertTrue(shown, "\"\(title)\" has no filter \(area) (library.filter.\(area))")
        }
        guard chips.allSatisfy(\.exists) else { return }
        for gone in ["suggestions", "organized", "all", "excluded"] {
            XCTAssertFalse(app.buttons["library.filter.\(gone)"].exists, "\"\(title)\" still has the filter \(gone)")
        }
        XCTAssertTrue(chips[0].isSelected, "\"\(title)\" does not open with its own filter chosen")
        shot("unsorted-filters")
        // Each filter in turn, then back to the first: chosen alone.
        for index in [1, 2, 0] {
            chips[index].tap()
            let alone = UITestWait.until("filter \(areas[index]) chosen alone", timeout: 5) {
                chips.indices.allSatisfy { chips[$0].isSelected == ($0 == index) }
            }
            if !alone {
                print("UI_FACT filters selected: \(zip(areas, chips).map { "\($0.0)=\($0.1.isSelected)" })")
            }
        }
    }

    // MARK: 3 Anlegen on a card

    /// The card after `skipped` others that offers "Anlegen": on the start page, else in an
    /// area's list ("Alle N"; once open, the next tries stay in it). Nil when neither has one.
    private func cardThatCreates(skipping skipped: Int) -> XCUIElement? {
        let inList = UITestScreens.SuggestionList.cards(app).containing(UITestScreens.Cards.saying("anlegen"))
        if !UITestScreens.SuggestionList.cards(app).firstMatch.exists {
            let onPage = UITestScreens.Cards.cards(app, action: "create")
            if onPage.firstMatch.waitForExistence(timeout: 10)
                || UITestScreens.Cards.first(app, action: "create", swipes: 4, timeout: 1) != nil {
                let card = onPage.element(boundBy: skipped)
                if card.exists { return card }
            }
            guard UITestScreens.StartPage.openList(app, "a list for a card with Anlegen", timeout: 5) else { return nil }
        }
        var swipes = 0
        while !inList.element(boundBy: skipped).waitForExistence(timeout: 2) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        let card = inList.element(boundBy: skipped)
        return card.exists ? card : nil
    }

    /// "Anlegen" on a card makes the album at once (decision 7B): the banner "„Name“ angelegt"
    /// with "Widerrufen" shows, and the card says "Angelegt" meanwhile. "Widerrufen" takes the
    /// album back: iOS asks before Albumist deletes the album it made (answered "Löschen"), the
    /// banner goes, nothing is left to report, and the suggestion offers "Anlegen" again. A
    /// suggestion that has to be looked at first opens its page or its preview instead; then
    /// the next card is tried (at most three).
    func test3_CreateFromCardThenUndo() {
        continueAfterFailure = true
        prepare("FrameUITests.test3")
        let banner = UITestScreens.QuickCreate.banner(app)
        var made: (identifier: String, name: String, title: String)?
        for attempt in 0..<3 {
            guard let card = cardThatCreates(skipping: attempt) else { break }
            let identifier = card.identifier
            let name = card.buttons["photoCard.body"].label
            // The album's name as its button says it; the card is found by it afterwards.
            let title = UITestScreens.Cards.albumName(of: card) ?? name
            print("UI_FACT quick create: card '\(name)' (\(identifier))")
            shot("card-\(attempt + 1)")
            guard UITestScreens.Cards.tapAction(of: card, in: app, "Anlegen on '\(name)'") else { return }
            let preview = app.navigationBars["Vorschau"]
            _ = UITestWait.holds(timeout: 30) {
                banner.exists || UITestScreens.SuggestionPage.isShown(app) || preview.exists || app.alerts.firstMatch.exists
            }
            if banner.exists {
                made = (identifier, name, title)
                break
            }
            // Looked at first (its page or its preview opened), or a message: said, and the
            // next card.
            if app.alerts.firstMatch.exists {
                print("UI_FACT quick create: a message instead of the banner: \(app.alerts.firstMatch.label)")
                app.alerts.firstMatch.buttons.firstMatch.tap()
            }
            if preview.exists || UITestScreens.SuggestionPage.isShown(app) {
                print("UI_FACT quick create: '\(name)' opened \(preview.exists ? "its preview" : "its page") instead (it is looked at first)")
                app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
                _ = UITestWait.holds(timeout: 5) { !preview.exists && !UITestScreens.SuggestionPage.isShown(app) }
            }
        }
        guard let made else {
            print("UI_STEP_MISSING a card made at once")
            shot("x-no-card-made")
            XCTFail("No card on the start page or in a list made its album at once with \"Anlegen\" (three tried)")
            return
        }
        print("UI_STEP_OK banner after Anlegen on '\(made.name)'")
        shot("banner")
        let named = banner.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "angelegt")).firstMatch
        XCTAssertTrue(named.exists, "The banner does not say \"„Name“ angelegt\"")
        // Meanwhile the card says so where its button was, "✓ Angelegt" („Name“ angelegt for
        // VoiceOver): on the start page as `suggestion.card.made`, in a list on its button.
        let saysMade = UITestWait.holds(timeout: 10) {
            app.descendants(matching: .any)["suggestion.card.made"].exists
                || UITestScreens.SuggestionList.cards(app).containing(UITestScreens.Cards.saying("angelegt")).firstMatch.exists
        }
        print(saysMade ? "UI_STEP_OK the card says Angelegt" : "UI_STEP_MISSING the card says Angelegt")
        XCTAssertTrue(saysMade, "While the banner shows, the card '\(made.name)' does not say \"Angelegt\"")

        // Its 44 pt sit on the button's label, where the tap lands (H14): before, the button was
        // only as large as its word, and the space around it took no tap.
        let undo = UITestScreens.QuickCreate.undo(app)
        if undo.waitForExistence(timeout: 5) {
            let size = undo.frame.size
            print("UI_FACT Widerrufen in the banner: \(Int(size.width)) x \(Int(size.height)) pt")
            XCTAssertTrue(size.width >= 43.5 && size.height >= 43.5, "\"Widerrufen\" in the banner is less than 44 x 44 pt to tap: \(size)")
        }
        guard tap(undo, "Widerrufen in the banner", timeout: 5) else { return }
        // Albumist made the album and nothing else is in it: it is deleted, and iOS asks first.
        let asked = UITestScreens.QuickCreate.answerDeleteQuestion(app, timeout: 30) { !banner.exists }
        print("UI_FACT quick create undo asked by iOS: \(asked)")
        guard UITestWait.disappears(banner, "banner gone after Widerrufen", timeout: 60) else { return }
        XCTAssertFalse(app.alerts.firstMatch.exists, "\"Widerrufen\" left a message: \(app.alerts.firstMatch.label)")
        let again = UITestScreens.Cards.card(app, identifier: made.identifier, titled: made.title)
        let back = again.waitForExistence(timeout: 30)
        print(back ? "UI_STEP_OK the suggestion is open again" : "UI_STEP_MISSING the suggestion is open again")
        XCTAssertTrue(back, "After \"Widerrufen\" the card '\(made.name)' is not back")
        if back {
            let cardButton = UITestScreens.Cards.action(of: again)
            XCTAssertTrue(UITestScreens.Cards.button(cardButton, says: "anlegen"),
                          "After \"Widerrufen\" the card '\(made.name)' does not offer \"Anlegen\" again ('\(cardButton.label)')")
        }
        shot("after-undo")
    }

    // MARK: 4 Long press

    /// The long press of design wave 2 (DS-06a, draft E4), on the simulator, which runs Apple's
    /// context menus as an iPhone does. A card of the start page lifts with its items ("Nicht
    /// jetzt" among them), and a tap beside the menu closes it with nothing done. A photo of
    /// "Unsortiert" lifts with "Ansehen", "Zu Album hinzufügen …" and "Ignorieren", and
    /// "Ansehen" opens it. While "Auswählen" a long press only ticks the photo: no menu and
    /// nothing lifted (review C2 of wave 2, N1: a context menu with a lifted view and no items
    /// may still lift, so the photos attach none there). A photo of a suggestion offers "Aus
    /// Vorschlag entfernen", which asks first, as "Auswählen" does, and then takes it out.
    func test4_LongPressMenus() {
        continueAfterFailure = true
        prepare("FrameUITests.test4")
        longPressACard()
        longPressAnUnsortedPhoto()
        longPressWhileSelecting()
        longPressASuggestionsPhoto()
    }

    /// An item of an open menu by its identifier, or by its name where the menu does not pass
    /// the identifier on.
    private func menuItem(_ identifier: String, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, name)).firstMatch
    }

    /// The menu's items as the tree lists them, for the log: whether the identifiers reach the
    /// system's menu is itself worth knowing.
    private func logMenu(_ what: String, prefix: String) {
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        print("UI_FACT \(what) menu: \(items.map { "\($0.identifier)='\($0.label)'" })")
    }

    /// A finger resting on `element`, longer than the half second after which iOS lifts it.
    private func pressLong(_ element: XCUIElement, _ step: String) {
        element.press(forDuration: 1.2)
        print("UI_STEP_OK long press: \(step)")
    }

    /// The places a tap beside an open menu may go: not on the lifted view (`pressed`, its frame
    /// before the press, as a band across the screen, since the lift may move it a little) and
    /// not in the column of the menu's items (`items`).
    private func besideTheMenu(pressed: CGRect, items: [CGRect]) -> [CGPoint] {
        let screen = app.frame
        let blocked = [CGRect(x: screen.minX, y: pressed.minY - 32, width: screen.width, height: pressed.height + 64)]
            + items.map { CGRect(x: $0.minX - 16, y: screen.minY, width: $0.width + 32, height: screen.height) }
        let points = [
            CGPoint(x: screen.maxX - 24, y: screen.minY + 90), CGPoint(x: screen.minX + 24, y: screen.minY + 90),
            CGPoint(x: screen.maxX - 24, y: screen.maxY - 130), CGPoint(x: screen.minX + 24, y: screen.maxY - 130),
            CGPoint(x: screen.maxX - 24, y: screen.midY), CGPoint(x: screen.minX + 24, y: screen.midY),
        ]
        return points.filter { point in !blocked.contains { $0.contains(point) } }
    }

    /// Closes an open menu with a tap on the dimmed screen beside it, as a person does: true once
    /// `item` is gone. Nothing of the screen below is reached (the dimmed layer takes the tap).
    @discardableResult
    private func closeMenu(_ item: XCUIElement, pressed: CGRect, items: [CGRect], _ step: String) -> Bool {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let screen = app.frame
        for point in besideTheMenu(pressed: pressed, items: items).prefix(3) {
            origin.withOffset(CGVector(dx: point.x - screen.minX, dy: point.y - screen.minY)).tap()
            if UITestWait.holds(timeout: 3, { !item.exists }) {
                print("UI_STEP_OK \(step) (tap at \(Int(point.x)),\(Int(point.y)))")
                return true
            }
        }
        print("UI_STEP_MISSING \(step)")
        shot("x-menu-stays-" + step.replacingOccurrences(of: " ", with: "-"))
        XCTFail("\(step): the menu did not close on a tap beside it")
        return false
    }

    /// The photos of "Unsortiert" (named by their date), or of "Unsicher" when "Unsortiert" has
    /// none left (as in AlbumistFlowUITests.test1b).
    private func unsortedPhotos() -> XCUIElementQuery {
        let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
        if !photos.firstMatch.waitForExistence(timeout: 10) {
            UITestScreens.Unsorted.show(app, "uncertain", named: "Unsicher", "uncertain photos for the long press")
            _ = photos.firstMatch.waitForExistence(timeout: 10)
        }
        return photos
    }

    /// A card of the start page: it lifts with its menu, and a tap beside the menu closes it
    /// with nothing done (the card is still there, no question, no sheet).
    private func longPressACard() {
        guard let card = UITestScreens.Cards.first(app, swipes: 4) else {
            print("UI_STEP_MISSING a suggestion card on the start page")
            XCTFail("No suggestion card on the start page to press long")
            return
        }
        let body = card.buttons["photoCard.body"]
        UITestScreens.Cards.reach(body, in: app)
        // Read before the press: the lifted card is drawn apart from the page.
        let identifier = card.identifier
        let name = body.label
        let pressed = body.frame
        pressLong(body, "card '\(name)'")
        let notNow = menuItem("suggestionMenu.notNow", "Nicht jetzt")
        guard UITestWait.appears(notNow, "the card's menu with \"Nicht jetzt\"", timeout: 5) else {
            shot("x-card-without-menu")
            return
        }
        logMenu("card", prefix: "suggestionMenu.")
        shot("longpress-card")
        guard closeMenu(notNow, pressed: pressed, items: [notNow.frame], "card menu closed by a tap beside it") else { return }
        let same = app.descendants(matching: .any).matching(identifier: identifier)
            .containing(NSPredicate(format: "identifier == %@ AND label == %@", "photoCard.body", name)).firstMatch
        XCTAssertTrue(same.waitForExistence(timeout: 5), "After closing its menu the card '\(name)' is gone")
        XCTAssertFalse(app.sheets.firstMatch.exists || app.alerts.firstMatch.exists, "Closing the card's menu left a question or a sheet")
    }

    /// A photo of "Unsortiert": it lifts with its three items, and "Ansehen" opens it large.
    private func longPressAnUnsortedPhoto() {
        let title = UITestScreens.Tabs.german.unsorted
        guard tap(tabButton(title), "tab \(title) for the long press") else { return }
        let photo = unsortedPhotos().element(boundBy: 0)
        guard photo.exists else {
            print("UI_STEP_MISSING a photo in \(title) to press long")
            XCTFail("\"\(title)\" and \"Unsicher\" show no photo to press long")
            return
        }
        pressLong(photo, "a photo of \(title)")
        let view = menuItem("photoMenu.view", "Ansehen")
        guard UITestWait.appears(view, "the photo's menu with \"Ansehen\"", timeout: 5) else {
            shot("x-photo-without-menu")
            return
        }
        let add = menuItem("photoMenu.addToAlbum", "Zu Album hinzufügen …")
        let ignore = app.buttons.matching(NSPredicate(format: "identifier IN %@ OR label IN %@",
                                                      ["photoMenu.ignore", "photoMenu.unignore"],
                                                      ["Ignorieren", "Nicht mehr ignorieren"])).firstMatch
        XCTAssertTrue(add.exists, "The photo's menu has no \"Zu Album hinzufügen …\"")
        XCTAssertTrue(ignore.exists, "The photo's menu has neither \"Ignorieren\" nor \"Nicht mehr ignorieren\"")
        logMenu("photo", prefix: "photoMenu.")
        shot("longpress-photo")
        guard tap(view, "Ansehen in the photo's menu") else { return }
        let close = app.buttons["viewer.close"]
        guard UITestWait.appears(close, "the photo opened from its menu", timeout: 10) else { return }
        close.tap()
        UITestWait.disappears(close, "the photo closed again", timeout: 10)
    }

    /// While "Auswählen" a long press is a tap: it ticks the photo, and no menu opens and
    /// nothing lifts (a lifted photo would take the touch, so the tick is the proof). After
    /// "Fertig" the same photo's long press shows its menu again.
    private func longPressWhileSelecting() {
        guard tap(app.buttons["Auswählen"], "Auswählen for the long press") else { return }
        let photo = unsortedPhotos().element(boundBy: 1)
        guard photo.exists else {
            print("UI_STEP_MISSING a second photo to press long while selecting")
            XCTFail("No second photo to press long while selecting")
            return
        }
        let ticked = photo.isSelected
        pressLong(photo, "a photo while selecting")
        let view = menuItem("photoMenu.view", "Ansehen")
        UITestWait.until("a long press while selecting ticks the photo", timeout: 5) { photo.isSelected != ticked }
        UITestWait.never("a menu while selecting", for: 2) { view.exists }
        shot("longpress-selecting")
        let done = app.buttons["Fertig"]
        guard tap(done, "end the selection after the long press") else { return }
        // A lifted photo would have taken that tap: then once more, so the next step starts clean.
        if UITestWait.holds(timeout: 2, { done.exists }) {
            print("UI_FACT the selection was still on after one tap on Fertig")
            done.tap()
        }
        // After "Fertig" the photo has its menu again: its cell is built anew with the long press
        // switched back on (review C2 of design wave 2, N1).
        guard UITestWait.appears(app.buttons["Auswählen"], "Auswählen back after Fertig", timeout: 5) else { return }
        let again = unsortedPhotos().element(boundBy: 1)
        guard again.exists else {
            print("UI_STEP_MISSING the second photo after Fertig")
            XCTFail("The second photo is gone after Fertig")
            return
        }
        let pressed = again.frame
        pressLong(again, "the same photo after Fertig")
        guard UITestWait.appears(view, "the photo's menu again after Fertig", timeout: 5) else {
            shot("x-photo-without-menu-after-selecting")
            return
        }
        shot("longpress-after-selecting")
        closeMenu(view, pressed: pressed, items: [view.frame], "close the photo's menu after Fertig")
    }

    /// A photo of a suggestion: "Aus Vorschlag entfernen" asks first, then the suggestion has one
    /// photo less.
    private func longPressASuggestionsPhoto() {
        let title = UITestScreens.Tabs.german.suggestions
        guard tap(tabButton(title), "tab \(title) for a suggestion's photo") else { return }
        guard let card = UITestScreens.Cards.first(app, swipes: 4),
              UITestScreens.Cards.open(card, in: app, "open a suggestion to press a photo long"),
              UITestWait.until("the suggestion's page", timeout: 10, { UITestScreens.SuggestionPage.isShown(app) }) else { return }
        var seen: Int?
        UITestWait.until("the number of the suggestion's photos", timeout: 5) {
            seen = UITestScreens.SuggestionPage.photoCount(app)
            return seen != nil
        }
        guard let before = seen else { return }
        guard before >= 2 else {
            print("UI_FACT the first suggestion has \(before) photo(s): nothing to take out and keep")
            return
        }
        guard let photo = UITestScreens.SuggestionPage.photoInReach(app) else {
            print("UI_STEP_MISSING a photo of the suggestion in reach")
            XCTFail("No photo of the suggestion came clear of the bars to be pressed long")
            return
        }
        pressLong(photo, "a photo of the suggestion")
        let remove = menuItem("photoMenu.removeFromSuggestion", "Aus Vorschlag entfernen")
        guard UITestWait.appears(remove, "the photo's menu with \"Aus Vorschlag entfernen\"", timeout: 5) else {
            shot("x-suggestion-photo-without-menu")
            return
        }
        logMenu("suggestion photo", prefix: "photoMenu.")
        shot("longpress-suggestion-photo")
        guard tap(remove, "Aus Vorschlag entfernen in the photo's menu") else { return }
        let confirm = app.buttons["Entfernen"]
        guard UITestWait.appears(confirm, "the question before the photo is taken out", timeout: 5) else { return }
        shot("longpress-remove-question")
        confirm.tap()
        var after: Int?
        let fewer = UITestWait.until("the suggestion has one photo less", timeout: 15) {
            after = UITestScreens.SuggestionPage.photoCount(app)
            return after == before - 1
        }
        print("UI_FACT suggestion photos \(before) -> \(after.map { String($0) } ?? "-")")
        if fewer { shot("longpress-photo-taken-out") }
    }
}
