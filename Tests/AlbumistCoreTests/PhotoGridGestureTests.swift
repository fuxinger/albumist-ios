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

    /// Positions outside the grid's photos (a page that shrank meanwhile) change nothing.
    @Test func positionsBeyondThePhotosChangeNothing() {
        var selection: Set<String> = ["a"]
        PhotoGridDrag.apply(PhotoGridDrag.Change(marked: [1...5], restored: [7...9]), mode: .select, to: &selection,
                            base: ["a"], ids: ["a", "b", "c"])
        #expect(selection == ["a", "b", "c"])
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

    // MARK: Scrolling by itself

    /// Near the top or bottom edge of what is visible the grid scrolls by itself, faster the
    /// closer the finger is to the edge, at the fastest at it and beyond (over a bar); in the
    /// middle it stands still.
    @Test func nearAnEdgeTheGridScrollsFasterTheCloserTheFinger() {
        let top = 100.0, bottom = 800.0
        #expect(PhotoGridAutoScroll.speed(y: 450, top: top, bottom: bottom) == 0)
        #expect(PhotoGridAutoScroll.speed(y: top + PhotoGridAutoScroll.edge, top: top, bottom: bottom) == 0)
        var last = 0.0
        for y in stride(from: bottom - PhotoGridAutoScroll.edge + 1, through: bottom, by: 4) {
            let speed = PhotoGridAutoScroll.speed(y: y, top: top, bottom: bottom)
            #expect(speed > last, "\(y)")
            last = speed
        }
        #expect(PhotoGridAutoScroll.speed(y: bottom, top: top, bottom: bottom) == PhotoGridAutoScroll.fastest)
        #expect(PhotoGridAutoScroll.speed(y: bottom + 60, top: top, bottom: bottom) == PhotoGridAutoScroll.fastest)
        #expect(PhotoGridAutoScroll.speed(y: top + 10, top: top, bottom: bottom) < 0, "up")
        #expect(PhotoGridAutoScroll.speed(y: top - 30, top: top, bottom: bottom) == -PhotoGridAutoScroll.fastest)
        // Smooth from a standstill: the first points into the zone barely move it.
        #expect(PhotoGridAutoScroll.speed(y: bottom - PhotoGridAutoScroll.edge + 2, top: top, bottom: bottom) < 5)
        // Symmetric.
        #expect(PhotoGridAutoScroll.speed(y: top + 20, top: top, bottom: bottom) == -PhotoGridAutoScroll.speed(y: bottom - 20, top: top, bottom: bottom))
    }

    /// On a short visible area the edges take at most a quarter each, so the middle stays still.
    @Test func aShortAreaKeepsAStillMiddle() {
        #expect(PhotoGridAutoScroll.speed(y: 150, top: 100, bottom: 200) == 0)
        #expect(PhotoGridAutoScroll.speed(y: 120, top: 100, bottom: 200) < 0)
        #expect(PhotoGridAutoScroll.speed(y: 180, top: 100, bottom: 200) > 0)
        #expect(PhotoGridAutoScroll.speed(y: 150, top: 100, bottom: 100) == 0, "no area")
    }

    /// One frame's step: speed times its time, a frame after a stall no larger than one of a
    /// thirtieth of a second, so the grid never jumps.
    @Test func aFramesStep() {
        #expect(abs(PhotoGridAutoScroll.step(speed: 600, seconds: 1.0 / 60) - 10) < 1e-9)
        #expect(abs(PhotoGridAutoScroll.step(speed: -600, seconds: 1.0 / 60) + 10) < 1e-9)
        #expect(abs(PhotoGridAutoScroll.step(speed: 600, seconds: 2) - 20) < 1e-9)
        #expect(PhotoGridAutoScroll.step(speed: 600, seconds: -1) == 0)
    }

    /// Steps go on from the last one asked for until the scroll view reports it, within the
    /// content; at an end nothing more is asked.
    @Test func targetsGoOnFromTheLastAskedWithinTheContent() {
        var target = PhotoGridAutoScroll.Target()
        #expect(target.next(by: 10, offset: 100, range: -50...1_000) == 110)
        // The scroll view has not reported 110 yet: the next step goes on from it.
        #expect(target.next(by: 10, offset: 100, range: -50...1_000) == 120)
        target.reported(120)
        #expect(target.next(by: -30, offset: 120, range: -50...1_000) == 90)
        target.reset()
        #expect(target.next(by: 30, offset: 990, range: -50...1_000) == 1_000)
        target.reported(1_000)
        #expect(target.next(by: 30, offset: 1_000, range: -50...1_000) == nil, "at the end")
        #expect(target.next(by: -60, offset: -20, range: -50...1_000) == -50)
    }

    // MARK: Pinch to zoom

    /// Three, five or seven in a row, as Photos offers 3 and 5 among others; three when
    /// nothing was chosen. A stored size from elsewhere is taken to the nearest step.
    @Test func theSteps() {
        #expect(PhotoGridZoom.columns == [3, 5, 7])
        #expect(PhotoGridZoom.standard == 3)
        #expect([0, -2, 1, 2, 3, 4, 5, 6, 7, 8, 40].map(PhotoGridZoom.columns(stored:)) == [3, 3, 3, 3, 3, 3, 5, 5, 7, 7, 7])
        #expect(PhotoGridZoom.fewer(than: 7) == 5 && PhotoGridZoom.fewer(than: 5) == 3 && PhotoGridZoom.fewer(than: 3) == nil)
        #expect(PhotoGridZoom.more(than: 3) == 5 && PhotoGridZoom.more(than: 5) == 7 && PhotoGridZoom.more(than: 7) == nil)
    }

    /// Every photo stays a target of at least 44 pt (design rule 2) on every iPhone from the
    /// smallest (375 pt) to the largest (440 pt) at every step.
    @Test func everyPhotoStaysAFingerWide() {
        for width in [375.0, 390, 393, 402, 414, 428, 430, 440] {
            for columns in PhotoGridZoom.columns {
                let side = PhotoGridZoom.side(width: width, columns: columns)
                #expect(side >= 44, "\(width) pt, \(columns) in a row")
                #expect(abs(side * Double(columns) + PhotoGridZoom.spacing * Double(columns - 1) - width) < 0.001)
            }
        }
        #expect(PhotoGridZoom.side(width: 0, columns: 3) == 0)
    }

    /// Spreading two fingers by a quarter shows fewer, larger photos, pinching by a quarter more,
    /// smaller ones; a long pinch goes on step by step; past the last step a turn back needs a
    /// quarter again, so the grid does not flicker between two steps.
    @Test func aPinchStepsByAQuarter() {
        var pinch = PhotoGridZoom.Pinch(columns: 5)
        #expect(pinch.update(scale: 1.1) == nil)
        #expect(pinch.update(scale: 1.26) == 3)
        #expect(pinch.update(scale: 1.6) == nil, "no fewer than three")
        #expect(pinch.update(scale: 2.0) == nil)
        #expect(pinch.update(scale: 1.7) == nil, "a little back from the furthest")
        #expect(pinch.update(scale: 1.59) == 5, "a quarter back from 2.0")
        #expect(pinch.columns == 5)
        #expect(pinch.update(scale: 1.3) == nil)
        #expect(pinch.update(scale: 1.27) == 7)
        #expect(pinch.update(scale: 0.5) == nil, "no more than seven")
        var out = PhotoGridZoom.Pinch(columns: 3)
        #expect(out.update(scale: 0.79) == 5)
        #expect(out.update(scale: 0.62) == 7)
    }

    /// The photo under the fingers stays under them: the point of the photo the fingers hold
    /// lands where they are, for the alignment the scroll view takes (`scrollTo(id:anchor:)`
    /// lines up the same unit point of the photo and of the visible area).
    @Test func thePhotoUnderTheFingersStaysThere() {
        let height = 600.0
        for side in [51.0, 74, 123] {
            for finger in stride(from: 0.0, through: height, by: 25) {
                for point in [0.0, 0.3, 1] {
                    let unit = PhotoGridZoom.anchor(fingerY: finger, visibleHeight: height, side: side, pointInPhoto: point)
                    #expect((0...1).contains(unit))
                    // Where the photo's top lands, and the held point with it.
                    let top = unit * (height - side)
                    let wanted = finger - point * side
                    if (0...(height - side)).contains(wanted) {
                        #expect(abs(top + point * side - finger) < 0.0001, "\(side) \(finger) \(point)")
                    } else {
                        #expect(abs(top - min(max(wanted, 0), height - side)) < 0.0001, "kept inside the visible area")
                    }
                }
            }
        }
        #expect(PhotoGridZoom.anchor(fingerY: 100, visibleHeight: 50, side: 80, pointInPhoto: 0.5) == 0, "a photo taller than the area")
    }

    /// Calm: the new size settles from the old one around the fingers, a little in from far
    /// out (Reduce Motion: no settling at all, in the app).
    @Test func theSettleScale() {
        #expect(PhotoGridZoom.settleScale(oldSide: 123, newSide: 74) > 1, "pinched in: settles from larger")
        #expect(abs(PhotoGridZoom.settleScale(oldSide: 74, newSide: 123) - 0.85) < 0.0001, "spread: a little only")
        #expect(PhotoGridZoom.settleScale(oldSide: 123, newSide: 51) <= 1.7)
        #expect(PhotoGridZoom.settleScale(oldSide: 0, newSide: 51) == 1)
    }
}
