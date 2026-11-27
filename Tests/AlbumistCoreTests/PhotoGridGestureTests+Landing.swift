import Testing
@testable import AlbumistCore

/// A zoom step's photo is asked of the scroll view only once the grid has laid out its new size
/// (UI run 45695824722: asked at once, in the same update that changed the size and turned the
/// grid's scroll targets on, the page went to its top, offset 799 to -168, and the photo pinched
/// on went from y 454 to 1072, off the screen).
struct PhotoGridZoomLandingTests {
    @Test func thePhotoIsAskedOnceTheNewSizeIsLaidOut() {
        var landing = PhotoGridZoomLanding<Int>()
        landing.asked(7, contentHeight: 13_648)
        #expect(landing.reported(contentHeight: 13_648) == nil, "still the old size: not yet")
        #expect(landing.reported(contentHeight: 7_351) == 7, "the new size is there")
        #expect(landing.reported(contentHeight: 7_351) == nil, "the same size again: asked already")
        #expect(landing.landed() == nil, "nothing left at the landing")
    }

    /// The lazy grid's height settles over several reports, and the first ask went by an estimate:
    /// in UI run 46033354388 (a small library, after the page was away) the step asked at 5213,
    /// the scroll view went from 906 to 94, the content came down to 3292 and 3283, and the page
    /// ended at its top (-168), the photo pinched on from y 532 to 826. Each new height asks again,
    /// so the last ask goes by the grid as laid out; at most four times a step.
    @Test func eachNewHeightWhileTheStepLandsAsksAgain() {
        var landing = PhotoGridZoomLanding<Int>()
        landing.asked(7, contentHeight: 6_492)
        #expect(landing.reported(contentHeight: 5_213) == 7, "the first new size")
        #expect(landing.reported(contentHeight: 5_213) == nil, "the same size: not again")
        #expect(landing.reported(contentHeight: 3_292) == 7, "the size settled further: again")
        #expect(landing.reported(contentHeight: 3_283) == 7)
        #expect(landing.reported(contentHeight: 3_290) == 7)
        #expect(landing.reported(contentHeight: 3_300) == nil, "at most four asks a step")
        #expect(landing.landed() == nil, "asked already, nothing left at the landing")
        #expect(landing.reported(contentHeight: 3_000) == nil, "landed: the user's scrolling is plain again")
    }

    @Test func aStepWhoseSizeNeverShowedAsksAtTheLanding() {
        var landing = PhotoGridZoomLanding<Int>()
        landing.asked(3, contentHeight: 900)
        #expect(landing.reported(contentHeight: 900) == nil)
        #expect(landing.landed() == 3, "asked at the latest when the step lands")
        #expect(landing.landed() == nil)
    }

    @Test func theLastStepCounts() {
        var landing = PhotoGridZoomLanding<Int>()
        landing.asked(1, contentHeight: 900)
        landing.asked(2, contentHeight: 900)
        #expect(landing.reported(contentHeight: 600) == 2)
    }

    @Test func beforeTheScrollViewReportedItselfTheFirstReportAsks() {
        var landing = PhotoGridZoomLanding<Int>()
        landing.asked(5, contentHeight: nil)
        #expect(landing.reported(contentHeight: 900) == 5)
    }
}
