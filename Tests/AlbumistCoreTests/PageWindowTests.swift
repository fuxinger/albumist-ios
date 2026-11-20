import Foundation
import Testing
@testable import AlbumistCore

/// Review 18.11. P4-11: the photo viewer put every photo the library had loaded into its
/// paging view (3,000 and, after scrolling on, 6,000 or 9,000 pages) when one photo opened.
/// It builds a window of pages around the photo shown and moves it along while the user swipes,
/// so every photo can still be reached.
@Suite("Photo viewer page window")
struct PageWindowTests {
    @Test func aPhotoOpenedFromALargeLibraryBuildsOnlyTheWindowAroundIt() {
        let window = PageWindow(around: 2_500, count: 9_000)
        #expect(window.range == 2_450..<2_551)
        #expect(window.range.count <= 2 * PageWindow.radius + 1)
    }

    @Test func aShortListIsBuiltWholeAsBefore() {
        #expect(PageWindow(around: 3, count: 40).range == 0..<40)
        #expect(PageWindow(around: 0, count: 1).range == 0..<1)
        #expect(PageWindow(around: 0, count: 0).range.isEmpty)
    }

    @Test func theWindowStopsAtBothEndsOfTheList() {
        #expect(PageWindow(around: 0, count: 3_000).range == 0..<51)
        #expect(PageWindow(around: 2_999, count: 3_000).range == 2_949..<3_000)
        // A photo that is not in the list (index past the end) opens on the nearest one.
        #expect(PageWindow(around: 5_000, count: 3_000).range == 2_949..<3_000)
        #expect(PageWindow(around: -4, count: 3_000).range == 0..<51)
    }

    @Test func swipingInsideTheWindowKeepsItSoThePagesStayPut() {
        let window = PageWindow(around: 1_000, count: 3_000)
        for index in (1_000 - PageWindow.radius + PageWindow.margin)...(1_000 + PageWindow.radius - PageWindow.margin) {
            #expect(window.following(index, count: 3_000) == window)
        }
    }

    @Test func nearTheEdgeTheWindowMovesOnAndKeepsThePhotoShown() {
        let window = PageWindow(around: 1_000, count: 3_000)
        let forward = window.following(1_000 + PageWindow.radius - PageWindow.margin + 1, count: 3_000)
        #expect(forward.range == PageWindow(around: 1_041, count: 3_000).range)
        #expect(forward.range.contains(1_041))
        let back = window.following(1_000 - PageWindow.radius + PageWindow.margin - 1, count: 3_000)
        #expect(back.range == PageWindow(around: 959, count: 3_000).range)
    }

    @Test func atTheEndsOfTheListTheWindowStays() {
        let first = PageWindow(around: 0, count: 3_000)
        #expect(first.following(0, count: 3_000) == first)
        let last = PageWindow(around: 2_999, count: 3_000)
        #expect(last.following(2_999, count: 3_000) == last)
    }

    /// Swiping one photo at a time from the first to the last reaches every photo: the next one
    /// is always a page of the window, and the window is rebuilt only now and then.
    @Test func swipingThroughTheWholeListReachesEveryPhoto() {
        let count = 3_000
        var window = PageWindow(around: 0, count: count)
        var moves = 0
        for index in 0..<count {
            #expect(window.range.contains(index))
            let next = window.following(index, count: count)
            if next != window { moves += 1 }
            window = next
            #expect(window.range.count <= 2 * PageWindow.radius + 1)
        }
        for index in stride(from: count - 1, through: 0, by: -1) {
            #expect(window.range.contains(index))
            window = window.following(index, count: count)
        }
        #expect(moves < count / 30)
    }
}
