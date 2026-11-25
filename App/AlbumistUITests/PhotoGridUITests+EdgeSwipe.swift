import XCTest
import UIKit

/// The steps of `PhotoGridUITests.test3_FromTheLeftEdgeASuggestionsPageGoesBackWhileSelecting`
/// (review L7 of H10): the control before "Auswählen", the drag along a row while selecting, and
/// the swipe back from the left edge.
extension PhotoGridUITests {
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
            guard openSuggestion(test + " again") else {
                shot("x-no-suggestion-page-again")
                XCTFail("\(test): the suggestion's page does not open again after the control")
                return nil
            }
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
        if !ticked { print("UI_FACT \(test): the bottom bar says '\(remove.exists ? remove.label : "nothing")'") }
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
