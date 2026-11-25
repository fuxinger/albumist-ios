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
        #expect(landing.reported(contentHeight: 7_300) == nil, "asked once")
        #expect(landing.landed() == nil, "nothing left at the landing")
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
