import XCTest
import UIKit

/// The steps of `PhotoGridUITests.test1_DragTicksARangeAcrossRowsAndDays` (DS-06b, drag to
/// select): the range dragged over, the drag with a tap right after it, and the drag back that
/// takes three ticks away.
extension PhotoGridUITests {
    /// A drag across rows of "Unsortiert": the photos built (their frames, in the grid's order),
    /// the screen between the bars, and the drag's first and last photo.
    struct DragRange {
        var all: [CGRect]
        var top: CGFloat
        var bottom: CGFloat
        var first: Int
        var last: Int

        /// Whole on the screen, between the bars.
        func onScreen(_ frame: CGRect) -> Bool { frame.minY >= top + 4 && frame.maxY <= bottom - 4 }

        /// In the middle of the first photo, well away from the screen's left edge (review W6).
        var start: CGPoint { CGPoint(x: all[first].minX + all[first].width * 0.5, y: all[first].midY) }

        /// Where the finger ends on the photo `index`: well inside it, on its right.
        func end(_ index: Int) -> CGPoint { CGPoint(x: all[index].minX + all[index].width * 0.8, y: all[index].midY) }
    }

    /// From the first photo of a row on screen to a photo of a later row two or more places to
    /// the right; nil, and the test failed, when the screen shows none.
    func dragRange(_ test: String) -> DragRange? {
        // What is on screen: below the navigation bar, above the bottom bar.
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
        let window = app.windows.firstMatch.frame
        let bar = app.toolbars.firstMatch
        let bottom = bar.exists && bar.frame.minY > window.midY ? bar.frame.minY : window.maxY - 90
        let all = photos("library.photo").map(\.frame)
        print("UI_FACT \(test): \(all.count) photos built, first \(all.first.map { "\($0)" } ?? "none")")
        var span = DragRange(all: all, top: top, bottom: bottom, first: 0, last: 0)
        // The finger starts and ends well away from the bars: within 72 pt of them the page
        // scrolls on by itself (`PhotoGridAutoScroll`), which would tick more.
        let calm = 90.0
        let leading = all.map(\.minX).min() ?? 0
        let firsts = all.indices.filter {
            span.onScreen(all[$0]) && abs(all[$0].minX - leading) < 1 && all[$0].midY >= top + calm
        }
        guard !firsts.isEmpty else {
            shot("x-no-photo-on-screen")
            XCTFail("\(test): no first photo of a row of \"Unsortiert\" on screen (bars at \(top) and \(bottom))")
            return nil
        }
        // From the first row's photo that has one (UI run 45717521559: days of four photos, so
        // from the topmost row every later photo two places on lay too far below).
        for first in firsts {
            span.first = first
            let start = all[first]
            // A photo of a later row two or more places to the right, close enough below that the
            // line to it is mostly sideways (the drag only selects when it starts sideways).
            let candidates = all.indices.filter { index in
                let frame = all[index]
                return index > first && span.onScreen(frame) && frame.midY <= bottom - calm
                    && frame.minY >= start.maxY && frame.minX >= start.minX + 1.5 * start.width
            }
            let fromPoint = span.start
            if let last = candidates.first(where: { abs(span.end($0).y - fromPoint.y) < 0.8 * abs(span.end($0).x - fromPoint.x) }) {
                span.last = last
                return span
            }
        }
        shot("x-no-range")
        let seen = all.prefix(24).map { "\(Int($0.minX)),\(Int($0.minY))" }
        XCTFail("\(test): no photo of a later row two places to the right on screen: \(seen)")
        return nil
    }

    /// The drag over the range, a tap on the photo after it as soon as the finger is up, and the
    /// ticks as the bar says them; how many are ticked.
    func dragOverTheRange(_ span: DragRange, _ test: String) -> Int {
        let all = span.all
        let first = span.first
        let last = span.last
        let range = last - first + 1
        print("UI_FACT \(test): drag from photo \(first) to photo \(last) (\(range) photos)")
        // The photo after the range, tapped as soon as the finger is up: a tap right after a drag
        // ticks (review L8 of H10: a time window after the drag swallowed it). Its point is worked
        // out before the drag, so the tap follows without asking the app again.
        let next = last + 1 < all.count && span.onScreen(all[last + 1]) ? last + 1 : nil
        let origin = app.coordinate(withNormalizedOffset: .zero)
        drag(from: span.start, to: span.end(last))
        if let next {
            origin.withOffset(CGVector(dx: all[next].midX, dy: all[next].midY)).tap()
            print("UI_STEP_OK \(test): tap photo \(next) right after the drag")
        } else {
            print("UI_FACT \(test): no photo after the range on screen: no tap right after the drag")
        }
        let ticked = range + (next == nil ? 0 : 1)
        let counted = UITestWait.until("\(test): \(ticked) ausgewählt after the drag", timeout: 5) { selectedCount(ticked).exists }
        if !counted {
            let shown = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " ausgewählt")).firstMatch
            print("UI_FACT \(test): the bar says '\(shown.exists ? shown.label : "nothing")'")
        }
        // Ticked as the bar says: the range and nothing else on screen (the drag held still at
        // its end, away from the edges, so the page did not scroll).
        let afterDrag = photos("library.photo")
        if afterDrag.count == all.count {
            let wrong = all.indices.filter {
                span.onScreen(all[$0]) && afterDrag[$0].selected != ((first...last).contains($0) || $0 == next)
            }
            XCTAssertTrue(wrong.isEmpty, "\(test): photos ticked other than \(first) to \(last)\(next.map { " and \($0)" } ?? ""): \(wrong)")
        } else {
            print("UI_FACT \(test): \(afterDrag.count) photos built after the drag, \(all.count) before: ticks not compared")
        }
        shot("pg-01-drag")
        return ticked
    }

    /// Along the last photo's row, from its first photo two to the right: all three ticked, so
    /// the drag takes their ticks away. False, and the test failed, when that row has no first
    /// photo in the range.
    func untickAlongTheLastRow(_ span: DragRange, ticked: Int, _ test: String) -> Bool {
        let all = span.all
        let last = span.last
        guard let rowStart = all.indices.first(where: { $0 >= span.first && abs(all[$0].minY - all[last].minY) < 1 }),
              rowStart + 2 <= last else {
            XCTFail("\(test): the row of photo \(last) has no first photo in the range")
            return false
        }
        let rowEnd = rowStart + 2
        drag(from: CGPoint(x: all[rowStart].minX + all[rowStart].width * 0.5, y: all[rowStart].midY),
             to: CGPoint(x: all[rowEnd].minX + all[rowEnd].width * 0.8, y: all[rowEnd].midY))
        UITestWait.until("\(test): \(ticked - 3) ausgewählt after dragging back over three", timeout: 5) { selectedCount(ticked - 3).exists }
        let afterUntick = photos("library.photo")
        if afterUntick.count > rowEnd {
            XCTAssertFalse((rowStart...rowEnd).contains { afterUntick[$0].selected }, "\(test): a photo of the second drag is still ticked")
        }
        shot("pg-01b-untick")
        return true
    }
}
