import Foundation
import Testing
@testable import AlbumistCore

/// What of the grid is on screen, read from the photos' own frames (`PhotoGridGestureTests`).
extension PhotoGridGestureTests {
    // MARK: What is on screen (review L1, W1)

    /// Three rows of three 100-pt photos, 2 pt apart, at three in a row on a 304-pt grid.
    static let layout = PhotoGridLayout(columns: 3, width: 304)

    static func frame(row: Int, column: Int) -> GridRect {
        GridRect(x: Double(column) * 102, y: Double(row) * 102, width: 100, height: 100)
    }

    /// The keys on screen in the part `visible` of the grid (nil: all laid out).
    static func found(_ screen: PhotoGridOnScreen<String, GridRect>, _ visible: ClosedRange<Double>? = nil) -> Set<String> {
        Set(screen.onScreen(visible) { $0 }.map(\.key))
    }

    /// "Auswählen" and "Fertig" give every photo on screen a new cell: the new one reports where
    /// it is and appears, the old one goes, in an order SwiftUI does not promise (review W1). The
    /// grid no longer hears SwiftUI's word that a cell appeared or went, only the frames: in all
    /// six orders the photo is found, before, between and after the three.
    @Test func aRebuiltCellIsFoundInEveryOrder() {
        enum Event: CaseIterable { case newReports, newAppears, oldGoes }
        let all = Event.allCases
        let orders = all.flatMap { a in all.filter { $0 != a }.flatMap { b in all.filter { $0 != a && $0 != b }.map { [a, b, $0] } } }
        #expect(orders.count == 6)
        for order in orders {
            var screen = PhotoGridOnScreen<String, GridRect>()
            screen.laidOut(Self.layout)
            screen.report("a", Self.frame(row: 0, column: 0))
            #expect(Self.found(screen, 0...300) == ["a"])
            for event in order {
                switch event {
                case .newReports: screen.report("a", Self.frame(row: 0, column: 0))
                // What SwiftUI says of the cells reaches no gesture.
                case .newAppears, .oldGoes: break
                }
                #expect(Self.found(screen, 0...300) == ["a"], "\(order)")
            }
            #expect(screen.count == 1, "one report per photo")
        }
    }

    /// Whether a photo is on screen is where its frame lies, not what SwiftUI said: a photo whose
    /// cell went without a word that it came back (a swipe back that was called off) is found
    /// while its frame is in the part of the grid the scroll view shows, and one that is said to
    /// be there but lies outside that part (scrolled away) is not, without any new report.
    @Test func aPhotoIsOnScreenWhereItsFrameIs() {
        var screen = PhotoGridOnScreen<String, GridRect>()
        screen.laidOut(Self.layout)
        for (index, key) in ["a", "b", "c", "d", "e", "f", "g", "h", "i"].enumerated() {
            screen.report(key, Self.frame(row: index / 3, column: index % 3))
        }
        #expect(Self.found(screen, 0...150) == ["a", "b", "c", "d", "e", "f"], "the first row and the top of the second")
        #expect(Self.found(screen, 210...500) == ["g", "h", "i"])
        #expect(Self.found(screen, 400...900).isEmpty, "scrolled past them")
        #expect(Self.found(screen).count == 9, "no scroll view to read: every photo laid out")
        // The part shown, from a finger at 250 in the grid and at 50 in a scroll view 120 high.
        #expect(PhotoGridHitTest.visiblePart(gridY: 250, scrollViewY: 50, height: 120) == 200...320)
        #expect(PhotoGridHitTest.visiblePart(gridY: 250, scrollViewY: 50, height: nil) == nil)
        #expect(PhotoGridHitTest.visiblePart(gridY: 250, scrollViewY: 50, height: 0) == nil)
    }

    /// A photo that went (scrolled away, or its page left for another tab or page) and comes back
    /// with nothing moved reports nothing anew (SwiftUI reports a frame only when it changes): it
    /// is found with what it reported (review L1).
    @Test func aPhotoBackOnScreenCountsWithWhatItReported() {
        var screen = PhotoGridOnScreen<String, GridRect>()
        screen.laidOut(Self.layout)
        screen.report("a", Self.frame(row: 0, column: 0))
        screen.report("b", Self.frame(row: 0, column: 1))
        // The tab is left and shown again: the grid's body runs, its layout is the same.
        screen.laidOut(Self.layout)
        #expect(Self.found(screen, 0...300) == ["a", "b"])
    }

    /// Another number in a row or another width lays out every photo anew: what was reported
    /// before is stale and dropped, and the photos on screen report their new frames. The first
    /// width the grid measures (from 0) changes no frame, and drops nothing.
    @Test func reportsOfAnotherLayoutAreStale() {
        var screen = PhotoGridOnScreen<String, GridRect>()
        screen.laidOut(PhotoGridLayout(columns: 3, width: 0))
        screen.report("a", Self.frame(row: 0, column: 0))
        screen.laidOut(Self.layout)
        #expect(Self.found(screen) == ["a"], "the first width")
        screen.laidOut(PhotoGridLayout(columns: 3, width: 0))
        screen.laidOut(Self.layout)
        #expect(Self.found(screen) == ["a"], "a width not measured for a moment")
        // A pinch to five in a row: only what reports anew is found.
        screen.laidOut(PhotoGridLayout(columns: 5, width: 304))
        #expect(Self.found(screen).isEmpty)
        screen.report("b", GridRect(x: 0, y: 0, width: 59, height: 59))
        #expect(Self.found(screen) == ["b"])
        // Another width.
        screen.laidOut(PhotoGridLayout(columns: 5, width: 390))
        #expect(Self.found(screen).isEmpty)
    }

    /// Of two reports at one place the later one counts: the earlier one is of a photo that went
    /// before it could report its move (a day's header grew while it was away), and the photo
    /// there now reported after it. Reports that do not count (a photo no longer at the place it
    /// reported in the grid's order) replace nothing.
    @Test func ofTwoReportsAtOnePlaceTheLaterOneCounts() {
        var screen = PhotoGridOnScreen<String, GridRect>()
        screen.laidOut(Self.layout)
        screen.report("old", Self.frame(row: 1, column: 0))
        screen.report("left", Self.frame(row: 1, column: 1))
        screen.report("new", GridRect(x: 0, y: 140, width: 100, height: 100))
        #expect(Self.found(screen) == ["new", "left"])
        // Touching or 2 pt apart is no overlap.
        #expect(!Self.frame(row: 0, column: 0).overlaps(Self.frame(row: 0, column: 1)))
        #expect(!GridRect(x: 0, y: 0, width: 100, height: 100).overlaps(GridRect(x: 100, y: 0, width: 100, height: 100)))
        #expect(Self.frame(row: 0, column: 0).overlaps(GridRect(x: 50, y: 50, width: 100, height: 100)))
        let counted = screen.onScreen(nil, frame: { $0 }, where: { key, _ in key != "new" }).map(\.key)
        #expect(Set(counted) == ["old", "left"])
    }

    /// Scrolling through a large library keeps at most twice `kept` reports, always the latest
    /// `kept` of them: the photos on screen, which reported last, are found after the page was
    /// left and shown again.
    @Test func whatWentIsKeptBounded() {
        var screen = PhotoGridOnScreen<Int, GridRect>()
        screen.laidOut(Self.layout)
        // 20,000 photos scrolled through, three in a row.
        for id in 0..<20_000 {
            screen.report(id, GridRect(x: Double(id % 3) * 102, y: Double(id / 3) * 102, width: 100, height: 100))
            #expect(screen.count <= 2 * PhotoGridOnScreen<Int, GridRect>.kept)
        }
        // The last rows on screen, after the page was away.
        screen.laidOut(Self.layout)
        let top = Double(19_900 / 3) * 102
        let shown = Set(screen.onScreen(top...(top + 3_500)) { $0 }.map(\.key))
        #expect(shown == Set(19_899..<20_000), "\(shown.count)")
        #expect(screen.onScreen(0...700) { $0 }.isEmpty, "long gone: not kept")
    }
}
