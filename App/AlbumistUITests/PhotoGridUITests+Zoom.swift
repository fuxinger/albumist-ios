import XCTest
import UIKit

/// The steps of `PhotoGridUITests.test2_TwoFingersShowThreeFiveOrSevenInARow` (DS-06b, pinch
/// to zoom): how many photos a row shows, the pinch on the middle of the page, the photo that
/// stays under the fingers, a trip's photos at the same size, and what the app saw of a pinch
/// without its step (its record, `PhotoGridPinchRecord` in the app).
extension PhotoGridUITests {
    /// Whether the grid's photos `photos` show `wanted` in a row, within a few seconds.
    func rowShowsPhotos(_ wanted: Int, _ what: String, _ photos: XCUIElementQuery, _ test: String) -> Bool {
        let met = UITestWait.until("\(test): \(wanted) in a row \(what)", timeout: 8) {
            photos.firstMatch.exists && columns(photos.firstMatch.frame.width) == wanted
        }
        if !met { print("UI_FACT \(test): \(what): a photo is \(photos.firstMatch.frame.width) pt wide") }
        return met
    }

    /// What a pinch did: whether the row then showed the photos wanted, and the photo under the
    /// middle of the fingers as seen before (nil when none was on screen).
    struct Pinched {
        var shown: Bool
        var held: Seen?
    }

    /// Two fingers on the photo under the middle of the page (or the nearest one), which stays
    /// under them. Not on the page itself: there XCTest starts a pinch's fingers as far apart as
    /// the page is large, and none of them reached the grid (UI run 45603459548: both pinches to
    /// 0.7 left no record of a finger on it). UIKit counts the scale only from where the pinch
    /// began, so the scales leave room for that (`PhotoGridSourceTests`). Without the step the
    /// app's record of the pinch says why (`explainPinch`).
    func pinchTheGrid(to wanted: Int, by scale: CGFloat, _ what: String, _ photos: XCUIElementQuery, _ test: String) -> Pinched {
        let page = app.scrollViews.containing(.button, identifier: "library.photo").firstMatch
        guard page.waitForExistence(timeout: 5) else {
            XCTFail("\(test): no page of photos to pinch (\(what))")
            return Pinched(shown: false, held: nil)
        }
        let frame = page.frame
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let held = heldPhoto(at: middle) else {
            XCTFail("\(test): no photo on screen to pinch (\(what))")
            return Pinched(shown: false, held: nil)
        }
        let photo = photos.matching(NSPredicate(format: "label == %@", held.label)).firstMatch
        print("UI_STEP_OK \(test): pinch \(scale) on the photo '\(held.label)' (\(Int(held.frame.width)) pt) "
              + "at \(Int(held.frame.midX)),\(Int(held.frame.midY)), under the page's middle \(Int(middle.x)),\(Int(middle.y)) (\(what))")
        let since = Date()
        photo.pinch(withScale: scale, velocity: scale < 1 ? -1 : 1)
        let shown = rowShowsPhotos(wanted, "after the pinch \(what)", photos, test)
        explainPinch(what, since: since, stepped: shown, test)
        return Pinched(shown: shown, held: held)
    }

    /// The photo under `point` on screen, else the one nearest to it, from one snapshot; the
    /// first of the grid's order when two are as near.
    func heldPhoto(at point: CGPoint) -> Seen? {
        let window = app.windows.firstMatch.frame
        let shown = photos("library.photo").filter { window.intersects($0.frame) }
        if let under = shown.first(where: { $0.frame.contains(point) }) { return under }
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        return shown.min { distance($0.frame) < distance($1.frame) }
    }

    /// The app's record of the grid's pinches (`-AlbumistUITestProgressLog`): in the runner's
    /// temporary folder, which the simulator's app writes to, anew at each launch (`launch`).
    static var pinchRecord: String { NSTemporaryDirectory() + "grid-pinch-record.txt" }

    /// The app's marks of the grid's pinches since `since`: "grid pinch: fingers 2, …" when the
    /// fingers lifted, "grid pinch step 3 to 5 at 0.78" at a step. Nil without a record.
    func pinchMarks(since: Date) -> [String]? {
        guard let text = try? String(contentsOfFile: Self.pinchRecord, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { row -> String? in
            let fields = row.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3, fields[0] == "#", let time = Double(fields[1]), time >= since.timeIntervalSince1970,
                  fields[2].hasPrefix("grid pinch") else { return nil }
            return fields[2]
        }
    }

    /// What the app saw of the pinch, each mark as a `UI_FACT`; without its step, which of the
    /// three causes UI run 45567033486 left open it was: one finger or none on the grid at a time
    /// is where XCTest put them (the fingers); two and the pinch never began is another gesture
    /// that held it back (the arbitration); it began and made no step is UIKit's scale, counted
    /// from where it began, staying short of a step's 0.8 or 1.25 (the threshold). A pinch whose
    /// scale went past a step's and still made none points at the grid's own handling of it.
    func explainPinch(_ what: String, since: Date, stepped: Bool, _ test: String) {
        guard let marks = pinchMarks(since: since) else {
            if !stepped { print("UI_FACT \(test): pinch \(what): no record of the app's pinches at \(Self.pinchRecord)") }
            return
        }
        for mark in marks { print("UI_FACT \(test): pinch \(what): the app saw '\(mark)'") }
        guard !stepped else { return }
        let lifts = marks.filter { $0.hasPrefix("grid pinch:") }
        let verdict: String
        if marks.contains(where: { $0.hasPrefix("grid pinch step") }) {
            verdict = "the grid made its step and the row did not show it"
        } else if !lifts.contains(where: { (Int(Self.field("fingers", of: $0) ?? "") ?? 0) >= 2 }) {
            verdict = "the fingers: \(lifts.isEmpty ? "none" : "one at a time") on the grid"
        } else if lifts.allSatisfy({ Self.field("began", of: $0) == "-" }) {
            verdict = "the arbitration: two fingers on the grid, and the pinch never began"
        } else if lifts.contains(where: { Self.field("scale", of: $0).flatMap(Double.init).map { $0 <= 0.8 || $0 >= 1.25 } ?? false }) {
            verdict = "the grid: UIKit's scale went past a step's, and the grid made no step"
        } else {
            verdict = "the threshold: the pinch began, and UIKit's scale stayed short of a step"
        }
        print("UI_FACT \(test): pinch \(what) made no step: \(verdict)")
    }

    /// The value after `name` in a line of the record ("fingers 2, apart 212, began -, …"), up
    /// to the next comma.
    static func field(_ name: String, of line: String) -> String? {
        guard let range = line.range(of: " \(name) ") else { return nil }
        return String(line[range.upperBound...].prefix { $0 != "," })
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
        UITestWait.never("\(test): the photo pinched on stays under the fingers a second later \(what)", for: 1) { !there() }
    }

    /// The page's first rows, by label: the photos on screen while it is at its top. The first
    /// one's label goes to the log (`UI_FACT`), as the first one's on screen does after the page
    /// went away (`firstPhotoOnScreen`), so the log shows that it went.
    func photosAtTheTop(_ test: String) -> Set<String> {
        let window = app.windows.firstMatch.frame
        let atTop = photos("library.photo").filter { $0.frame.minY < window.maxY }
        print("UI_FACT \(test): the first photo at the page's top: '\(atTop.first?.label ?? "none")', \(atTop.count) photos on screen")
        return Set(atTop.map(\.label))
    }

    /// The label of the first photo on screen, below the navigation bar.
    func firstPhotoOnScreen() -> String {
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch
        let top = bar.exists ? bar.frame.maxY : window.minY
        return photos("library.photo").first { $0.frame.maxY > top && $0.frame.minY < window.maxY }?.label ?? "none"
    }

    /// The photo the fingers held is not among the page's first rows (`photosAtTheTop`): at the
    /// top the scroll view cannot keep it under them either (review Y5), so there the test could
    /// not check what it is for, and fails.
    func isBelow(_ firstRows: Set<String>, _ held: Seen, _ test: String) -> Bool {
        guard firstRows.contains(held.label) else { return true }
        XCTFail("\(test): the photo pinched on ('\(held.label)') is among the page's first rows: the swipes left the page at its top")
        return false
    }

    /// A trip's photos: the same grid, at the same size (five in a row after the pinches). A trip,
    /// whose days hold rows of photos (`openTrip`). Then two fingers on one of its photos
    /// (`spreadOnePhoto`).
    func suggestionShowsFiveInARow(_ test: String) {
        guard tap(tabButton(UITestScreens.Tabs.german.suggestions), "\(test): tab Vorschläge"), openTrip(test) else { return }
        guard let photo = UITestScreens.SuggestionPage.photoInReach(app) else {
            XCTFail("\(test): no photo of the trip's page in reach")
            return
        }
        let inRow = columns(photo.frame.width)
        print("UI_FACT \(test): a trip's photos: \(inRow) in a row (\(photo.frame.width) pt)")
        XCTAssertEqual(inRow, 5, "\(test): a trip's photos do not show the size chosen in \"Unsortiert\"")
        shot("pg-04-suggestion-five")
        spreadOnePhoto(photo, test)
    }

    /// Two fingers spread on one photo, both on it, as a hand mostly pinches (the page's pinches
    /// above have them on different photos; second review of the fix): back to three in a row.
    /// From five the step to three is the last one, so 1.8 makes exactly one, also counted from a
    /// tenth of the way in. Without it, the app's record says why (`explainPinch`).
    func spreadOnePhoto(_ photo: XCUIElement, _ test: String) {
        let what = "on one photo back to three"
        print("UI_STEP_OK \(test): spread 1.8 on one photo '\(photo.label)' (\(Int(photo.frame.width)) pt) (\(what))")
        let since = Date()
        photo.pinch(withScale: 1.8, velocity: 1)
        let three = rowShowsPhotos(3, "after the spread \(what)", app.buttons.matching(identifier: "proposalPhotos.photo"), test)
        explainPinch(what, since: since, stepped: three, test)
        XCTAssertTrue(three, "\(test): two fingers spread on one photo do not go back to three photos in a row")
        shot("pg-04b-one-photo-three")
    }
}
