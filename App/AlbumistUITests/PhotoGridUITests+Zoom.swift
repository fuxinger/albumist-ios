import XCTest
import UIKit

/// The steps of `PhotoGridUITests.test2_TwoFingersShowThreeFiveOrSevenInARow` (DS-06b, pinch
/// to zoom): how many photos a row shows, the pinch on the photo nearest the middle, the photo
/// that stays under the fingers, and a suggestion's photos at the same size.
extension PhotoGridUITests {
    /// Whether the grid's photos `photos` show `wanted` in a row, within a few seconds.
    func rowShowsPhotos(_ wanted: Int, _ what: String, _ photos: XCUIElementQuery, _ test: String) -> Bool {
        let met = UITestWait.until("\(test): \(wanted) in a row \(what)", timeout: 8) {
            photos.firstMatch.exists && columns(photos.firstMatch.frame.width) == wanted
        }
        if !met { print("UI_FACT \(test): \(what): a photo is \(photos.firstMatch.frame.width) pt wide") }
        return met
    }

    /// Two fingers on the photo nearest the middle of the screen (the grid, not its bars). The
    /// element is the one the snapshot saw there: checked by its frame, else the first photo
    /// of the query that lies in the middle third of the screen. What was seen of it, read
    /// before the pinch.
    func pinchNearestPhoto(_ scale: CGFloat, _ what: String, _ photos: XCUIElementQuery, _ test: String) -> Seen? {
        let window = app.windows.firstMatch.frame
        let all = self.photos("library.photo")
        guard let nearest = all.indices.min(by: {
            abs(all[$0].frame.midY - window.midY) < abs(all[$1].frame.midY - window.midY)
        }) else {
            XCTFail("\(test): no photo to pinch (\(what))")
            return nil
        }
        var target = photos.element(boundBy: nearest)
        var held = all[nearest]
        if target.frame != held.frame,
           let middle = (0..<min(photos.count, 40)).lazy.map({ photos.element(boundBy: $0) }).first(where: {
               abs($0.frame.midY - window.midY) < window.height / 6
           }) {
            target = middle
            held = Seen(frame: middle.frame, selected: false, label: middle.label)
        }
        print("UI_STEP_OK \(test): pinch \(scale) on '\(held.label)' at \(Int(held.frame.minX)),\(Int(held.frame.minY)) (\(what))")
        target.pinch(withScale: scale, velocity: scale < 1 ? -1 : 1)
        return held
    }

    /// The photo the fingers held is under them again, within about a row of where it was:
    /// right after the step, and still a second later, after the step landed (0.35 s).
    func pinchedPhotoKeepsItsPlace(_ held: Seen, _ what: String, _ test: String) {
        let row = held.frame.height + 2
        func there() -> Bool {
            self.photos("library.photo").contains { $0.label == held.label && abs($0.frame.midY - held.frame.midY) <= row }
        }
        guard UITestWait.until("\(test): the photo pinched on still under the fingers \(what)", timeout: 5, { there() }) else {
            let now = self.photos("library.photo").filter { $0.label == held.label }.map { Int($0.frame.midY) }
            print("UI_FACT \(test): '\(held.label)' was at y \(Int(held.frame.midY)), now at \(now)")
            shot("x-place-lost")
            return
        }
        UITestWait.never("\(test): the photo pinched on leaves the fingers a second later \(what)", for: 1) { !there() }
    }

    /// A suggestion's photos: the same grid, at the same size (five in a row after the pinches).
    func suggestionShowsFiveInARow(_ test: String) {
        if tap(tabButton(UITestScreens.Tabs.german.suggestions), "\(test): tab Vorschläge"),
           let card = UITestScreens.Cards.first(app, swipes: 6, timeout: 10),
           UITestScreens.Cards.open(card, in: app, "\(test): a suggestion's page"),
           UITestWait.until("\(test): the suggestion's page", timeout: 10, { UITestScreens.SuggestionPage.isShown(app) }) {
            if let photo = UITestScreens.SuggestionPage.photoInReach(app) {
                let inRow = columns(photo.frame.width)
                print("UI_FACT \(test): a suggestion's photos: \(inRow) in a row (\(photo.frame.width) pt)")
                XCTAssertEqual(inRow, 5, "\(test): a suggestion's photos do not show the size chosen in \"Unsortiert\"")
                shot("pg-04-suggestion-five")
            } else {
                XCTFail("\(test): no photo of the suggestion's page in reach")
            }
        }
    }
}
