import XCTest
import UIKit

/// The steps of `PhotoGridUITests.test3_FromTheLeftEdgeASuggestionsPageGoesBackWhileSelecting`
/// (review L7 of H10): the control before "Auswählen", the drag along a row while selecting, and
/// the swipe back from the left edge; and the way to a trip's page, test2's too (`openTrip`).
extension PhotoGridUITests {
    /// A trip's page with a row of two or more photos away from the bars (`calmRow`), from the
    /// tab "Vorschläge": the trips' list ("Reisen · Alle N", `startPage.all.trips`), else the
    /// trips the start page shows itself (`tripCards`). Not any suggestion: a frequent place's
    /// days may hold one photo each, with no row to drag along (UI run 45567033486). Up to three
    /// trips are opened, the first with such a row stays open, scrolled back to where it opened
    /// (the steps after it look from there, `SuggestionPage.photoInReach`). False, and the test
    /// failed with what was found, when none has one.
    func openTrip(_ test: String) -> Bool {
        let trips = tripCards(test)
        var found: [String] = []
        for index in 0..<3 {
            let card = trips.element(boundBy: index)
            guard card.waitForExistence(timeout: index == 0 ? 5 : 2) else { break }
            // Read before the tap: the pushed page takes the card out of the tree.
            let body = card.buttons["photoCard.body"]
            let name = String((body.exists ? body.label : card.label).prefix(48))
            guard UITestScreens.Cards.open(card, in: app, "\(test): the trip '\(name)'") else { return false }
            guard UITestWait.until("\(test): the trip's page", timeout: 10, { UITestScreens.SuggestionPage.isShown(app) }) else {
                shot("x-no-trip-page")
                return false
            }
            // As `calmRow` looks, counting its slow swipes, so as many take the page back.
            var swipes = 0
            var row = calmRow("proposalPhotos.photo", swipes: 0)
            while row.isEmpty && swipes < 3 {
                app.swipeUp(velocity: .slow)
                swipes += 1
                row = calmRow("proposalPhotos.photo", swipes: 0)
            }
            for _ in 0..<swipes { app.swipeDown(velocity: .slow) }
            if let first = row.first {
                print("UI_FACT \(test): the trip '\(name)': a row of \(row.count) photos at y \(Int(first.midY)) after \(swipes) swipes")
                return true
            }
            found.append("'\(name)'")
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            _ = UITestWait.holds(timeout: 5) { !UITestScreens.SuggestionPage.isShown(app) }
        }
        print("UI_FACT \(test): no trip's page with a row of two photos: \(trips.count) trips shown, opened without one: "
              + "[\(found.joined(separator: ", "))]; the page shows \(UITestScreens.StartPage.facts(app))")
        shot("x-no-trip")
        XCTFail("\(test): no trip's page with a row of two or more photos (\(found.count) opened without one)")
        return false
    }

    /// The trips to open: the cards of the trips' list (already shown, after the control went
    /// back to it; else "Alle N" of the trips on the start page, scrolled to), else the open
    /// trips the start page shows itself (its row "Reisen", "Neue Reisen", "Schon gefunden"):
    /// with at most one open trip it has no "Alle N" (the group's earlier tests make albums).
    private func tripCards(_ test: String) -> XCUIElementQuery {
        let list = UITestScreens.SuggestionList.cards(app)
        if list.firstMatch.exists, !UITestScreens.SuggestionPage.isShown(app) { return list }
        let all = app.buttons["startPage.all.trips"]
        _ = all.waitForExistence(timeout: 3)
        var swipes = 0
        while !all.exists && swipes < 4 {
            app.swipeUp()
            swipes += 1
            _ = all.waitForExistence(timeout: 1)
        }
        if all.exists {
            UITestScreens.Cards.reach(all, in: app)
            all.tap()
            print("UI_STEP_OK \(test): the trips' list (startPage.all.trips)")
            if UITestWait.holds(timeout: 10, { list.firstMatch.exists }) { return list }
            print("UI_FACT \(test): the trips' list shows no card")
        } else {
            print("UI_FACT \(test): no \"Alle N\" of the trips on the start page: the trips it shows itself")
            for _ in 0..<swipes { app.swipeDown() }
        }
        let areas = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", [
            "startPage.row.trips", "startPage.newTrips", "startPage.earlyTrips",
        ]))
        let unmade = UITestScreens.Cards.actions.map { "suggestion.card.\($0)" }
        return areas.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", unmade))
    }

    /// The control: the same finger from the left edge, over a row of photos, before "Auswählen".
    /// Whether it went back (the page is opened again then); nil, and the test failed, when the
    /// page does not open again.
    func edgeSwipeControl(_ test: String) -> Bool? {
        let controlY = calmRow("proposalPhotos.photo").first?.midY ?? app.windows.firstMatch.frame.midY
        swipeFromLeftEdge(at: controlY)
        print("UI_STEP_OK \(test): finger from the left edge at y \(Int(controlY)) before Auswählen (the control)")
        let edgeSwipeGoesBack = UITestWait.holds(timeout: 5) { !UITestScreens.SuggestionPage.isShown(app) }
        if edgeSwipeGoesBack {
            print("UI_STEP_OK \(test): the control went back to the suggestions")
            guard openTrip(test + " again") else { return nil }
        } else {
            print("UI_FACT \(test): the control stayed on the suggestion's page: the simulator's swipe from x = 0 was no edge swipe")
            shot("x-control-stayed")
            XCTFail("\(test): the simulator's swipe from the left edge was no edge swipe: the page stayed before "
                    + "Auswählen too, so the swipe while selecting is not tried and says nothing about the app")
        }
        return edgeSwipeGoesBack
    }

    /// A row of photos well away from the bars, dragged over from the middle of its first one:
    /// they are ticked and the page stays. The row's first photo; nil, and the test failed, when
    /// there is no such row.
    func dragAlongACalmRow(_ test: String) -> CGRect? {
        let row = calmRow("proposalPhotos.photo")
        guard let start = row.first, let end = row.last else {
            shot("x-no-row-to-drag")
            XCTFail("\(test): no row of two or more photos of the suggestion away from the bars")
            return nil
        }
        print("UI_FACT \(test): a row of \(row.count) photos at y \(Int(start.midY))")
        drag(from: CGPoint(x: start.minX + start.width * 0.5, y: start.midY),
             to: CGPoint(x: end.minX + end.width * 0.8, y: end.midY))
        let remove = app.buttons["proposalPhotos.remove"]
        let ticked = UITestWait.until("\(test): \(row.count) photos ticked by the sideways drag", timeout: 5) {
            remove.exists && remove.label.hasPrefix("\(row.count) ")
        }
        if !ticked {
            print("UI_FACT \(test): the bottom bar says '\(remove.exists ? remove.label : "nothing")'")
            for mark in pinchMarks(since: Date().addingTimeInterval(-20), prefix: "grid drag") ?? [] {
                print("UI_FACT \(test): the app saw '\(mark)'")
            }
        }
        XCTAssertTrue(UITestScreens.SuggestionPage.isShown(app), "\(test): a sideways drag over the photos left the suggestion's page")
        shot("pg-05-suggestion-drag")
        return start
    }

    /// From the left screen edge at height `y` while selecting: the swipe back to the
    /// suggestions, not the drag to select.
    func swipeBackFromTheEdge(at y: CGFloat, _ test: String) {
        let suggestions = UITestScreens.Tabs.german.suggestions
        let remove = app.buttons["proposalPhotos.remove"]
        swipeFromLeftEdge(at: y)
        print("UI_STEP_OK \(test): finger from the left edge at y \(Int(y))")
        let back = UITestWait.until("\(test): back from the suggestion's page", timeout: 5) {
            !UITestScreens.SuggestionPage.isShown(app)
        }
        if !back {
            print("UI_FACT \(test): the page stayed; the bottom bar says '\(remove.exists ? remove.label : "nothing")'")
            shot("x-edge-swipe-stayed")
            return
        }
        let listed = UITestWait.holds(timeout: 5) {
            UITestScreens.Cards.cards(app).firstMatch.exists || app.tabBars.buttons[suggestions].isSelected
        }
        print("UI_FACT \(test): after the swipe back the suggestions show: \(listed)")
        XCTAssertTrue(listed, "\(test): the swipe back from the edge did not lead to the suggestions")
        shot("pg-06-edge-back")
    }
}
