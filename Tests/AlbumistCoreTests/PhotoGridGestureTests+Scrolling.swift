import Foundation
import Testing
@testable import AlbumistCore

/// The grid scrolls by itself near an edge while a finger drags (`PhotoGridGestureTests`).
extension PhotoGridGestureTests {
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

    /// The edges' zones begin where the bars end. "Unsortiert" insets its content by the bars;
    /// a suggestion's cover reaches up under them (no content inset at the top), and they cover
    /// it all the same: at each edge what covers more counts.
    @Test func theEdgesAreWhereTheBarsEnd() {
        // "Unsortiert" on the small iPhone: the navigation bar above, the tab bar below.
        #expect(PhotoGridAutoScroll.seenArea(height: 667, insetTop: 116, insetBottom: 83, safeTop: 116, safeBottom: 83) == 116...584)
        // A suggestion: the cover under the status bar and the bar's buttons, the toolbar below.
        #expect(PhotoGridAutoScroll.seenArea(height: 852, insetTop: 0, insetBottom: 83, safeTop: 103, safeBottom: 34) == 103...769)
        let top = PhotoGridAutoScroll.seenArea(height: 852, insetTop: 0, insetBottom: 83, safeTop: 103, safeBottom: 34)?.lowerBound ?? 0
        #expect(PhotoGridAutoScroll.speed(y: top + 10, top: top, bottom: 769) < 0, "just below the bar scrolls up")
        #expect(PhotoGridAutoScroll.speed(y: top + PhotoGridAutoScroll.edge + 10, top: top, bottom: 769) == 0)
        // Nothing to see, or the page not laid out yet.
        #expect(PhotoGridAutoScroll.seenArea(height: 100, insetTop: 60, insetBottom: 0, safeTop: 0, safeBottom: 40) == nil)
        #expect(PhotoGridAutoScroll.seenArea(height: 0, insetTop: 0, insetBottom: 0, safeTop: 0, safeBottom: 0) == nil)
        // An inset below zero does not widen the area beyond the scroll view.
        #expect(PhotoGridAutoScroll.seenArea(height: 500, insetTop: -20, insetBottom: -10, safeTop: 0, safeBottom: 0) == 0...500)
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
}
