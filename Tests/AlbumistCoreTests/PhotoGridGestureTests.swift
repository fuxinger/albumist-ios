import Foundation
import Testing
@testable import AlbumistCore

/// Design wave 3, DS-06b: drag to select and pinch to zoom in the photo grids ("Unsortiert" and
/// a suggestion's photos), as in Photos. What the gestures decide is worked out here; the app's
/// grid (`PhotoGrid`) only measures and hands over.
@Suite("Photo grid gestures")
struct PhotoGridGestureTests {
    // MARK: Drag to select

    /// A selection starts only on a mostly sideways start, as in Photos: a vertical swipe still
    /// scrolls, and so does a diagonal one at 45° or steeper.
    @Test func onlyASidewaysStartSelects() {
        #expect(PhotoGridDrag.startsSelection(dx: 12, dy: 3))
        #expect(PhotoGridDrag.startsSelection(dx: -12, dy: 5))
        #expect(PhotoGridDrag.startsSelection(dx: 10, dy: -9))
        #expect(!PhotoGridDrag.startsSelection(dx: 3, dy: 12))
        #expect(!PhotoGridDrag.startsSelection(dx: -5, dy: -14))
        #expect(!PhotoGridDrag.startsSelection(dx: 10, dy: 10), "45° scrolls")
        #expect(!PhotoGridDrag.startsSelection(dx: 0, dy: 0))
    }

    /// The first photo touched decides: unticked, the drag ticks; ticked, it unticks. That
    /// photo changes at once.
    @Test func theFirstPhotoDecidesTickOrUntick() {
        let tick = PhotoGridDrag(anchor: 4, anchorWasSelected: false)
        #expect(tick.mode == .select)
        #expect(tick.start == PhotoGridDrag.Change(marked: [4...4]))
        #expect(tick.selection(from: [1]) == [1, 4])
        let untick = PhotoGridDrag(anchor: 4, anchorWasSelected: true)
        #expect(untick.mode == .deselect)
        #expect(untick.selection(from: [1, 4, 5]) == [1, 5])
    }

    /// Every photo from the first one to the one under the finger, in grid order (across rows
    /// and days: positions run on through the headers); moving back shrinks the range and the
    /// photos it leaves are as they were before the drag.
    @Test func theRangeGrowsAndShrinksWithTheFinger() {
        var drag = PhotoGridDrag(anchor: 10, anchorWasSelected: false)
        let base: Set<Int> = [2, 12, 30]
        #expect(drag.move(to: 14) == PhotoGridDrag.Change(marked: [11...14]))
        #expect(drag.range == 10...14)
        #expect(drag.selection(from: base) == Set([2, 30]).union(10...14))
        #expect(drag.move(to: 12) == PhotoGridDrag.Change(restored: [13...14]))
        #expect(drag.selection(from: base) == Set([2, 30]).union(10...12))
        // Across the first photo: the other side ticks, the first side goes back.
        #expect(drag.move(to: 7) == PhotoGridDrag.Change(marked: [7...9], restored: [11...12]))
        #expect(drag.selection(from: base) == Set([2, 12, 30]).union(7...10))
        #expect(drag.move(to: 7) == PhotoGridDrag.Change())
        #expect(drag.move(to: 10) == PhotoGridDrag.Change(restored: [7...9]))
        #expect(drag.selection(from: base) == base.union([10]))
    }

    /// Applying each move's change to the selection gives the same as working the selection out
    /// anew from the selection before the drag, for any path of the finger, ticking or
    /// unticking.
    @Test func eachMovesChangeAddsUpToTheWholeSelection() {
        var generator = SplitMix(seed: 3)
        for round in 0..<300 {
            let count = 1 + Int(generator.next() % 60)
            let ids = (0..<count).map { "p\($0)" }
            let base = Set(ids.filter { _ in generator.next() % 3 == 0 })
            let anchor = Int(generator.next() % UInt64(count))
            var drag = PhotoGridDrag(anchor: anchor, anchorWasSelected: base.contains(ids[anchor]))
            var selection = base
            PhotoGridDrag.apply(drag.start, mode: drag.mode, to: &selection, base: base, ids: ids)
            for _ in 0..<12 {
                let change = drag.move(to: Int(generator.next() % UInt64(count)))
                PhotoGridDrag.apply(change, mode: drag.mode, to: &selection, base: base, ids: ids)
                let positions = Set(ids.indices.filter { base.contains(ids[$0]) })
                let expected = Set(drag.selection(from: positions).map { ids[$0] })
                #expect(selection == expected, "round \(round)")
            }
        }
    }

    /// A running drag follows the photos the grid shows now (review L3): more photos loaded after
    /// them keep the range where it is and let it grow into them; new photos before it move it
    /// with its photos; when its photos are no longer together in that order (one of them went,
    /// or one came between), there is no range to keep and the drag ends.
    @Test func aDragFollowsThePhotosTheGridShowsNow() throws {
        var drag = PhotoGridDrag(anchor: 1, anchorWasSelected: false)
        _ = drag.move(to: 3)
        let old = ["a", "b", "c", "d", "e"]
        #expect(drag.rebased(from: old, to: old) == drag)
        // More loaded after them: the same range, which grows into them.
        var on = try #require(drag.rebased(from: old, to: old + ["f", "g"]))
        #expect(on == drag)
        #expect(on.move(to: 6) == PhotoGridDrag.Change(marked: [4...6]))
        // Photos before the range changed, its own stayed in place.
        #expect(drag.rebased(from: old, to: ["q", "b", "c", "d"]) == drag)
        // New photos at the top: the range moves with its photos.
        let moved = try #require(drag.rebased(from: old, to: ["x", "y"] + old))
        #expect(moved.anchor == 3 && moved.current == 5 && moved.mode == .select)
        // Backwards from a ticked photo: the same.
        var back = PhotoGridDrag(anchor: 3, anchorWasSelected: true)
        _ = back.move(to: 2)
        let shifted = try #require(back.rebased(from: old, to: ["x"] + old))
        #expect(shifted.anchor == 4 && shifted.current == 3 && shifted.mode == .deselect)
        // One of its photos went, or one came between: no range to keep.
        #expect(drag.rebased(from: old, to: ["a", "b", "d", "e"]) == nil)
        #expect(drag.rebased(from: old, to: ["a", "b", "c", "z", "d", "e"]) == nil)
        #expect(drag.rebased(from: old, to: ["a", "c", "d", "e"]) == nil)
        #expect(drag.rebased(from: old, to: []) == nil)
    }

    /// Positions outside the grid's photos (a page that shrank meanwhile) change nothing.
    @Test func positionsBeyondThePhotosChangeNothing() {
        var selection: Set<String> = ["a"]
        PhotoGridDrag.apply(PhotoGridDrag.Change(marked: [1...5], restored: [7...9]), mode: .select, to: &selection,
                            base: ["a"], ids: ["a", "b", "c"])
        #expect(selection == ["a", "b", "c"])
    }

    // MARK: A gesture's lift (review L8, W3)

    /// The lift that ends a drag or a pinch is no tap (UIKit may hand it to the photo's button
    /// too, before or right after the gesture's end); a tap after the next finger touched down is
    /// one of its own, however soon: a tap right after a drag ticks, one right after a pinch opens.
    @Test func onlyTheLiftOfTheGestureThatEndedIsNoTap() {
        var lift = PhotoGridLift()
        #expect(!lift.swallowsTap(at: 0), "a plain tap")
        // A drag: its finger touches down, then it begins.
        lift.touchedDown()
        lift.gestureBegan()
        #expect(lift.swallowsTap(at: 1), "a tap while it runs")
        lift.gestureEnded(at: 2)
        #expect(lift.swallowsTap(at: 2), "its own lift")
        #expect(lift.swallowsTap(at: 2.3), "its lift, a few frames later")
        lift.touchedDown()
        #expect(!lift.swallowsTap(at: 2.3), "a tap right after the drag ticks or unticks")
        // A pinch: its second finger touches down while it runs, which is no tap of its own.
        lift.gestureBegan()
        lift.touchedDown()
        #expect(lift.swallowsTap(at: 3))
        lift.gestureEnded(at: 4)
        #expect(lift.swallowsTap(at: 4.1), "the lift of its fingers")
        lift.touchedDown()
        #expect(!lift.swallowsTap(at: 4.1), "a tap right after the pinch opens")
    }

    /// A drag and a pinch at once: a tap is their lift until both ended and a finger touched again.
    @Test func twoGesturesAtOnceLiftTogether() {
        var lift = PhotoGridLift()
        lift.gestureBegan()
        lift.gestureBegan()
        lift.gestureEnded(at: 1)
        lift.touchedDown()
        #expect(lift.swallowsTap(at: 2), "the other one still runs")
        lift.gestureEnded(at: 3)
        #expect(lift.swallowsTap(at: 3.1))
        lift.touchedDown()
        #expect(!lift.swallowsTap(at: 3.1))
        // An end without a beginning leaves nothing running.
        lift.gestureEnded(at: 5)
        lift.touchedDown()
        #expect(!lift.swallowsTap(at: 5))
    }

    /// An activation that comes without a touch (VoiceOver's double tap, Switch Control's
    /// "Tippen") a while after a drag or a pinch is a tap of its own: the lift UIKit hands the
    /// button comes with the gesture's end, within half a second of it (review W3).
    @Test func anActivationWithoutATouchLaterIsATapOfItsOwn() {
        var lift = PhotoGridLift()
        lift.gestureBegan()
        lift.gestureEnded(at: 10)
        #expect(lift.swallowsTap(at: 10), "right after the end: its lift")
        #expect(lift.swallowsTap(at: 10 + PhotoGridLift.window - 0.01))
        #expect(!lift.swallowsTap(at: 11), "no touch down and a second later: a tap of its own")
        #expect(!lift.swallowsTap(at: 10 + PhotoGridLift.window))
        // After a touch down: at once.
        lift.gestureBegan()
        lift.gestureEnded(at: 20)
        lift.touchedDown()
        #expect(!lift.swallowsTap(at: 20.01))
    }

    // MARK: The photo under the finger

    /// Two rows of three 100-pt photos with 2 pt between them; the second row is short.
    static let cells: [(position: Int, frame: GridRect)] = [
        (0, GridRect(x: 0, y: 0, width: 100, height: 100)), (1, GridRect(x: 102, y: 0, width: 100, height: 100)),
        (2, GridRect(x: 204, y: 0, width: 100, height: 100)),
        // A day's header from 100 to 150, then its photos.
        (3, GridRect(x: 0, y: 150, width: 100, height: 100)), (4, GridRect(x: 102, y: 150, width: 100, height: 100)),
    ]

    @Test func thePhotoUnderTheFinger() {
        #expect(PhotoGridHitTest.position(x: 50, y: 50, in: Self.cells) == 0)
        #expect(PhotoGridHitTest.position(x: 150, y: 99, in: Self.cells) == 1)
        #expect(PhotoGridHitTest.position(x: 250, y: 200, in: Self.cells) == 4, "beside a short row: its last photo")
        #expect(PhotoGridHitTest.position(x: -20, y: 160, in: Self.cells) == 3, "before a row: its first photo")
        #expect(PhotoGridHitTest.position(x: 100.5, y: 10, in: Self.cells) == 0, "in the gap: the nearer photo")
        #expect(PhotoGridHitTest.position(x: 101.8, y: 10, in: Self.cells) == 1)
    }

    /// Between rows and on a header there is no photo: the drag keeps the one it has.
    @Test func noPhotoBetweenRowsOrOnAHeader() {
        #expect(PhotoGridHitTest.position(x: 50, y: 120, in: Self.cells) == nil)
        #expect(PhotoGridHitTest.position(x: 50, y: 400, in: Self.cells) == nil)
        #expect(PhotoGridHitTest.position(x: 50, y: 50, in: []) == nil)
    }

    /// A day's header pinned at the top over the photos scrolling under it hides them: a finger
    /// on it is on no photo, so the drag ticks nothing the user cannot see (review L4); above and
    /// below it the photos count, and a header that covers nothing changes nothing.
    @Test func noPhotoUnderAPinnedHeader() {
        // The second day's header pinned over the first row, from 40 to 90.
        let pinned = GridRect(x: 0, y: 40, width: 304, height: 50)
        #expect(PhotoGridHitTest.position(x: 50, y: 60, in: Self.cells, covered: [pinned]) == nil)
        #expect(PhotoGridHitTest.position(x: 150, y: 90, in: Self.cells, covered: [pinned]) == nil, "its edge")
        #expect(PhotoGridHitTest.position(x: 150, y: 95, in: Self.cells, covered: [pinned]) == 1, "below it")
        #expect(PhotoGridHitTest.position(x: 150, y: 20, in: Self.cells, covered: [pinned]) == 1, "above it")
        #expect(PhotoGridHitTest.position(x: 50, y: 60, in: Self.cells) == 0, "nothing pinned: the photo")
        // A header in its own place, between the days.
        let between = GridRect(x: 0, y: 100, width: 304, height: 50)
        #expect(PhotoGridHitTest.position(x: 50, y: 160, in: Self.cells, covered: [between]) == 3)
        #expect(PhotoGridHitTest.position(x: 50, y: 50, in: Self.cells, covered: [between]) == 0)
    }

    /// While a drag runs, a finger on a day's header that lies over photos (pinned at the top
    /// while the page scrolls up under it) is on the first row below the header, at the finger's
    /// place across, so the range goes on with the rows that come out below it (review W2). A drag
    /// that begins there still waits (`noPhotoUnderAPinnedHeader`), and a header in its own place
    /// between the days, over no photo, is on none.
    @Test func aRunningDragOnAPinnedHeaderGoesOnBelowIt() {
        func running(_ x: Double, _ y: Double, _ covered: [GridRect]) -> Int? {
            PhotoGridHitTest.position(x: x, y: y, in: Self.cells, covered: covered, onCovered: .rowBelow)
        }
        // Pinned over the first row, from 40 to 90: that row reaches below its bottom.
        let pinned = GridRect(x: 0, y: 40, width: 304, height: 50)
        #expect(running(50, 60, [pinned]) == 0)
        #expect(running(250, 45, [pinned]) == 2)
        #expect(running(150, 90, [pinned]) == 1, "its edge")
        // Its bottom in the gap below the first row: the next day's first row.
        let low = GridRect(x: 0, y: 0, width: 304, height: 120)
        #expect(running(50, 110, [low]) == 3)
        #expect(running(280, 20, [low]) == 4, "beside a short row: its last photo")
        // Pushed up by the next day's header, in its own place from 100 to 150: below the pushed
        // one the next day's first row; the next one lies over no photo.
        let pushed = GridRect(x: 0, y: 50, width: 304, height: 50)
        let next = GridRect(x: 0, y: 100, width: 304, height: 50)
        #expect(running(150, 70, [pushed, next]) == 4)
        #expect(running(150, 120, [pushed, next]) == nil, "a header in its own place")
        // Over the last row, with no row below it: no photo.
        #expect(running(50, 200, [GridRect(x: 0, y: 140, width: 304, height: 120)]) == nil)
        // Off the header the photos count as before.
        #expect(running(150, 95, [pinned]) == 1)
        #expect(running(50, 160, [pinned]) == 3)
        // Where a drag begins: no photo.
        #expect(PhotoGridHitTest.position(x: 50, y: 60, in: Self.cells, covered: [pinned]) == nil)
    }

    /// Two fingers always hold a photo, the one whose place the zoom keeps: the one under them,
    /// else the nearest (between rows, on a header, beside the grid); on a tie the earlier one.
    @Test func twoFingersHoldTheNearestPhoto() {
        #expect(PhotoGridHitTest.nearest(x: 150, y: 50, in: Self.cells) == 1, "under the fingers")
        #expect(PhotoGridHitTest.nearest(x: 150, y: 110, in: Self.cells) == 1, "just below a row: its photo")
        #expect(PhotoGridHitTest.nearest(x: 150, y: 140, in: Self.cells) == 4, "on the header, near the next day")
        #expect(PhotoGridHitTest.nearest(x: 150, y: 125, in: Self.cells) == 1, "halfway: the earlier one")
        #expect(PhotoGridHitTest.nearest(x: 280, y: 200, in: Self.cells) == 4, "beside a short row: its last photo")
        #expect(PhotoGridHitTest.nearest(x: 280, y: 400, in: Self.cells) == 4, "below the grid: its nearest photo")
        #expect(PhotoGridHitTest.nearest(x: 50, y: -60, in: Self.cells) == 0, "above the grid")
        #expect(PhotoGridHitTest.nearest(x: 50, y: 50, in: []) == nil, "no photo on screen")
    }
}
