import XCTest
import UIKit

/// The long presses of test4: a card, a photo of "Unsortiert", one while selecting and a suggestion's photo (SwiftLint's file length).
extension FrameUITests {
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
    func longPressACard() {
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
    func longPressAnUnsortedPhoto() {
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
    func longPressWhileSelecting() {
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
    func longPressASuggestionsPhoto() {
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
