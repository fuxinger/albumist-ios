import Foundation
import Testing
@testable import AlbumistCore

/// The small moment after "Anlegen" on a card (draft E6, design wave 2): a small copy of the
/// card's cover flies towards the tab "Alben" and fades into the tab bar as it reaches it. When it
/// flies, where the tab is and the path are decided here (`QuickCreateMoment`; whether the tab
/// bar is open: `QuickCreateMomentBarTests`); the app draws it. The album's one haptic is the
/// success tap with its banner, as before the moment (`MomentsSourceTests.theSmallMomentFliesOverTheTabsOnly`).
@Suite("Quick create moment")
struct QuickCreateMomentTests {
    typealias Moment = QuickCreateMoment

    // MARK: When

    /// It flies only from a card that is on screen and shows a sharp cover from the device, into a
    /// tab bar that is open: no card (the suggestion's page made it), no photo (a placeholder,
    /// "Vorschau ausgeblendet") or a bar shrunk while scrolling, and nothing flies.
    @Test func theCoverFliesOnlyFromACardOnScreenWithASharpCover() {
        #expect(Moment.kind(reduceMotion: false, sourceOnScreen: true, hasSharpCover: true, barOpen: true) == .fly)
        #expect(Moment.kind(reduceMotion: false, sourceOnScreen: false, hasSharpCover: true, barOpen: true) == .none)
        #expect(Moment.kind(reduceMotion: false, sourceOnScreen: true, hasSharpCover: false, barOpen: true) == .none)
        #expect(Moment.kind(reduceMotion: false, sourceOnScreen: false, hasSharpCover: false, barOpen: true) == .none)
        #expect(Moment.kind(reduceMotion: false, sourceOnScreen: true, hasSharpCover: true, barOpen: false) == .none)
    }

    /// With Reduce Motion nothing flies, and nothing rests on the tab bar either: the banner and
    /// its success tap say it, as before the moment (review E of design wave 2, finding 4: no small
    /// album on a point of the bar that is worked out rather than read).
    @Test func reduceMotionShowsNothing() {
        #expect(Moment.kind(reduceMotion: true, sourceOnScreen: true, hasSharpCover: true, barOpen: true) == .none)
        #expect(Moment.kind(reduceMotion: true, sourceOnScreen: true, hasSharpCover: true, barOpen: false) == .none)
    }

    // MARK: Where

    /// "Alben" is the third of the three tabs in the bar, left of the round search button (the app
    /// is iPhone only and portrait only): its place is worked out from the screen's width and where
    /// the bar begins, as drawn in the drafts. The flight only heads there and fades into the bar
    /// (`theFlightFadesIntoTheBar`), so a few points do not show; the real bar is a device check.
    @Test func theAlbumsTabIsTheThirdOfThreeBesideSearch() throws {
        for width in [375.0, 393.0, 402.0, 440.0] {
            let tab = try #require(Moment.TabBar.albumsTab(screenWidth: width, barTop: 769, screenBottom: 852, rightToLeft: false))
            let pillEnd = width - Moment.TabBar.margin - Moment.TabBar.searchSide - Moment.TabBar.gap
            #expect(tab.x > width / 2 && tab.x < pillEnd, "\(width): \(tab.x)")
            #expect(tab.y > 769 && tab.y < 852 - 21, "\(width): \(tab.y)")
        }
        // The draft's 393 pt screen: the tab's middle 254 pt from the left.
        let draft = try #require(Moment.TabBar.albumsTab(screenWidth: 393, barTop: 769, screenBottom: 852, rightToLeft: false))
        #expect(abs(draft.x - 254.17) < 0.01)
        // Right to left the bar is mirrored.
        let rtl = try #require(Moment.TabBar.albumsTab(screenWidth: 393, barTop: 769, screenBottom: 852, rightToLeft: true))
        #expect(abs(rtl.x - (393 - 254.17)) < 0.01)
        // The 4.7" iPhone without a home indicator: the bar is lower, still inside it.
        let small = try #require(Moment.TabBar.albumsTab(screenWidth: 375, barTop: 618, screenBottom: 667, rightToLeft: false))
        #expect(small.y > 618 && small.y < 667)
    }

    /// A screen that hides the tab bar leaves only the home indicator's room below its content, or
    /// none: no tab to head for, so nothing flies.
    @Test func noTabBarNoTab() {
        #expect(Moment.TabBar.albumsTab(screenWidth: 393, barTop: 818, screenBottom: 852, rightToLeft: false) == nil)
        #expect(Moment.TabBar.albumsTab(screenWidth: 375, barTop: 667, screenBottom: 667, rightToLeft: false) == nil)
        #expect(Moment.TabBar.albumsTab(screenWidth: 0, barTop: 769, screenBottom: 852, rightToLeft: false) == nil)
    }

    /// The cover is looked up at exactly the size its card asked Photos for (`CoverPhoto`: the
    /// width and height in whole points, times the screen's scale; a strip three times as wide as
    /// high at the accessibility sizes, `PhotoCard`), so the flying photo is the card's own.
    @Test func theCoverIsAskedForAtTheCardsOwnSize() {
        let compact = Moment.coverPixels(cardWidth: 172.4, aspectRatio: 1.5, accessibilitySize: false, scale: 3)
        #expect(compact.width == 519 && compact.height == 345)
        let large = Moment.coverPixels(cardWidth: 361, aspectRatio: 2, accessibilitySize: false, scale: 3)
        #expect(large.width == 1083 && large.height == 543)
        let strip = Moment.coverPixels(cardWidth: 172.4, aspectRatio: 1.5, accessibilitySize: true, scale: 2)
        #expect(strip.width == 346 && strip.height == 116)
        #expect(Moment.shownAspectRatio(4.0 / 3.0, accessibilitySize: true) == 3)
        #expect(Moment.shownAspectRatio(4.0 / 3.0, accessibilitySize: false) == 4.0 / 3.0)
        let cover = Moment.coverFrame(card: Moment.Rect(x: 16, y: 300, width: 361, height: 260), aspectRatio: 2, accessibilitySize: false)
        #expect(cover == Moment.Rect(x: 16, y: 300, width: 361, height: 180.5))
    }

    /// A card scrolled away, or under the bars, is not where anything flies from.
    @Test func aCoverOffScreenDoesNotFly() {
        let screen = (top: 100.0, bottom: 769.0, width: 393.0)
        func onScreen(_ y: Double) -> Bool {
            Moment.isOnScreen(Moment.Rect(x: 16, y: y, width: 361, height: 180), top: screen.top, bottom: screen.bottom, width: screen.width)
        }
        #expect(onScreen(300))
        #expect(onScreen(20), "half the photo is still to be seen")
        #expect(!onScreen(-200))
        #expect(!onScreen(700), "its middle is behind the tab bar")
        #expect(!Moment.isOnScreen(Moment.Rect(x: 400, y: 300, width: 172, height: 115), top: 100, bottom: 769, width: 393))
    }

    // MARK: How

    /// It lifts off the card's photo as a faint copy, gets solid on its way and swings down towards
    /// "Alben", ever smaller (draft E6: 60, 44, then 26 pt), and fades out as it reaches the bar: it
    /// never lands on a point of the bar that is worked out rather than read (review E of design
    /// wave 2, finding 4).
    @Test func theFlightFadesIntoTheBar() throws {
        let cover = Moment.Rect(x: 16, y: 362, width: 361, height: 180)
        let tab = try #require(Moment.TabBar.albumsTab(screenWidth: 393, barTop: 769, screenBottom: 852, rightToLeft: false))
        let flight = Moment.Flight(cover: cover, to: tab)
        #expect(flight.start == Moment.Point(x: cover.midX, y: cover.midY))
        #expect(flight.point(at: 0) == flight.start)
        #expect(abs(flight.point(at: 1).x - tab.x) < 0.001 && abs(flight.point(at: 1).y - tab.y) < 0.001)
        #expect(flight.startSide == 60, "a third of the cover's height, as in the draft")
        #expect(flight.side(at: 0) == 60 && flight.side(at: 1) == Moment.Flight.endSide && Moment.Flight.endSide == 26)
        let steps = Array(stride(from: 0.0, through: 1.0, by: 0.01))
        let sides = steps.map { flight.side(at: $0) }
        #expect(sides == sides.sorted(by: >), "it only gets smaller")
        let ys = steps.map { flight.point(at: $0).y }
        #expect(ys == ys.sorted(), "it never rises above the card")
        // Faint as it lifts off, solid on its way, gone at the end.
        #expect(flight.opacity(at: 0) < 0.5 && flight.opacity(at: 0.5) == 1 && flight.opacity(at: 1) == 0)
        let fading = steps.filter { $0 >= Moment.Flight.fadeFrom }.map { flight.opacity(at: $0) }
        #expect(fading == fading.sorted(by: >), "once it fades it only fades")
        // At the bar's edge it is mostly gone: a few points there do not show.
        let atBar = try #require(steps.first { flight.point(at: $0).y >= 769 })
        #expect(flight.opacity(at: atBar) <= 0.5, "\(atBar): \(flight.opacity(at: atBar))")
        // A small card: never smaller than a thumb's width at the start.
        #expect(Moment.Flight(cover: Moment.Rect(x: 16, y: 600, width: 172, height: 112), to: tab).startSide == 44)
        #expect(Moment.Flight(cover: Moment.Rect(x: 16, y: 300, width: 361, height: 400), to: tab).startSide == 72)
        #expect(Moment.Flight.duration > 0.5 && Moment.Flight.duration < 0.9)
    }
}
