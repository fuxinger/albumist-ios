import Foundation
import Testing
@testable import AlbumistCore

/// Whether the tab bar is open as "Anlegen" makes an album, so the small moment's cover flies
/// only into an open bar (draft E6): read from the scroll of the screens with cards, the start
/// page and the suggestion list (`onScrollGeometryChange`, `onScrollPhaseChange`), not from where
/// the cards are (review E2 of design wave 2, N1, N2 and N6). What only a device can tell (what
/// iOS does with the bar after a pop, a refresh, a tab chosen by Siri) is decided the safe way
/// and listed as a device check.
@Suite("Quick create moment: the tab bar")
struct QuickCreateMomentBarTests {
    typealias Moment = QuickCreateMoment
    typealias Spot = QuickCreateMoment.ScrollSpot

    /// The start page as an iPhone reports it: the content rests 140 pt down, below the large
    /// title, 2000 pt of cards on a screen 852 pt high with 34 pt below the tab bar.
    static func page(height: Double = 2000) -> Spot {
        Spot(offset: -140, top: -140, end: height + 34 - 852)
    }

    /// Moves the content by `distance` points (positive: scrolled down) a few points per frame,
    /// as a scroll view reports it.
    static func scroll(_ spot: inout Spot, by distance: Double, _ motion: Moment.ScrollMotion = .user, step: Double = 6,
                       into trail: inout Moment.BarTrail) {
        var left = distance
        while left != 0 {
            let move = left > 0 ? min(step, left) : max(-step, left)
            spot.offset += move
            left -= move
            trail.scrolled(to: spot, motion)
        }
    }

    /// A screen with cards on a tab, as the app reports it to the watch.
    struct Screen {
        let id = UUID()
        var spot: Spot

        mutating func scroll(by distance: Double, _ motion: Moment.ScrollMotion = .user, step: Double = 6,
                             in watch: inout Moment.TabWatch) {
            var left = distance
            while left != 0 {
                let move = left > 0 ? min(step, left) : max(-step, left)
                spot.offset += move
                left -= move
                watch.scrolled(screen: id, to: spot, motion)
            }
        }

        /// A reading that is no scroll (laid out, at rest).
        func read(in watch: inout Moment.TabWatch) {
            watch.scrolled(screen: id, to: spot, .other)
        }
    }

    // MARK: The scroll

    /// Open on a tab just chosen (it was open to choose it); a scroll down shrinks it to one round
    /// button (`.tabBarMinimizeBehavior(.onScrollDown)`), a clear scroll back up opens it again,
    /// and so does the top of the list, however little it took to get there.
    @Test func theScrollTellsWhetherTheBarIsOpen() {
        var trail = Moment.BarTrail()
        var spot = Self.page()
        trail.scrolled(to: spot, .other)
        #expect(trail.isOpen, "the bar was open to choose the tab")
        Self.scroll(&spot, by: 6, into: &trail)
        #expect(trail.isOpen, "a few points are no scroll")
        Self.scroll(&spot, by: 6, into: &trail)
        #expect(!trail.isOpen, "scrolled down: the bar may have shrunk")
        Self.scroll(&spot, by: 200, into: &trail)
        Self.scroll(&spot, by: -24, into: &trail)
        #expect(!trail.isOpen, "a little back up is not enough")
        Self.scroll(&spot, by: -12, into: &trail)
        #expect(trail.isOpen, "scrolled back up: open again")
        Self.scroll(&spot, by: 30, into: &trail)
        #expect(!trail.isOpen)
        // A turn of a few points starts the count anew.
        Self.scroll(&spot, by: -30, into: &trail)
        Self.scroll(&spot, by: 1, into: &trail)
        Self.scroll(&spot, by: -30, into: &trail)
        #expect(!trail.isOpen)
        Self.scroll(&spot, by: -2, into: &trail)
        #expect(trail.isOpen)
        // 20 pt down from the top, taken for shrunk: back at the top it is open, though 20 pt
        // back up would not be enough elsewhere.
        Self.scroll(&spot, by: spot.top - spot.offset, into: &trail)
        Self.scroll(&spot, by: 20, into: &trail)
        #expect(!trail.isOpen)
        Self.scroll(&spot, by: -20, into: &trail)
        #expect(spot.offset == spot.top)
        #expect(trail.isOpen)
    }

    /// N1: a layout change above the cards moves the cards on screen, not the scroll. The ring card
    /// grows by 40 pt as the analysis changes phase (animated, a few points per frame), or shrinks
    /// to one line as it ends, or a card comes or goes at once: no scroll, either way.
    @Test func aLayoutChangeAboveTheCardsIsNoScroll() {
        // Scenario A: scrolled down 300 pt, the bar shrunk; the ring card grows.
        var trail = Moment.BarTrail()
        var spot = Self.page()
        trail.scrolled(to: spot, .other)
        Self.scroll(&spot, by: 300, into: &trail)
        #expect(!trail.isOpen)
        for _ in 0..<10 {
            spot.end += 4
            trail.scrolled(to: spot, .other)
        }
        #expect(!trail.isOpen, "the cards moved down on screen: no scroll up")
        // Should SwiftUI keep what shows in place instead, the offset follows the growth: still none.
        for _ in 0..<10 {
            spot.end += 4
            spot.offset += 4
            trail.scrolled(to: spot, .other)
        }
        for _ in 0..<20 {
            spot.end -= 4
            spot.offset -= 4
            trail.scrolled(to: spot, .other)
        }
        #expect(!trail.isOpen)
        // A scroll after the change counts from where the change left the list.
        Self.scroll(&spot, by: -36, into: &trail)
        #expect(trail.isOpen)

        // Scenario B: at the top, the bar open; the ring card shrinks as the analysis ends.
        var top = Moment.BarTrail()
        var resting = Self.page()
        top.scrolled(to: resting, .other)
        for _ in 0..<30 {
            resting.end -= 4
            top.scrolled(to: resting, .other)
        }
        #expect(top.isOpen, "the cards moved up on screen: no scroll down")
        resting.end -= 260
        top.scrolled(to: resting, .other)
        #expect(top.isOpen, "a card that went at once")

        // The content shrinks below a list scrolled to its end: iOS moves the offset up with it.
        var end = Moment.BarTrail()
        var bottom = Self.page()
        end.scrolled(to: bottom, .other)
        Self.scroll(&bottom, by: bottom.end - bottom.offset, step: 40, into: &end)
        #expect(!end.isOpen)
        bottom.end -= 300
        bottom.offset = bottom.end
        end.scrolled(to: bottom, .other)
        #expect(!end.isOpen)
    }

    /// N2: a flick back to the top passes it and settles back; the settling is no scroll down.
    @Test func aFlickToTheTopOpensTheBar() {
        var trail = Moment.BarTrail()
        var spot = Self.page()
        trail.scrolled(to: spot, .other)
        Self.scroll(&spot, by: 600, into: &trail)
        #expect(!trail.isOpen)
        // The fling slows down past the top by 40 pt and settles back (decelerating: the user's).
        Self.scroll(&spot, by: -640, step: 30, into: &trail)
        #expect(trail.isOpen)
        Self.scroll(&spot, by: 40, step: 4, into: &trail)
        trail.scrolled(to: spot, .other)
        #expect(spot.offset == spot.top)
        #expect(trail.isOpen, "settling back at the top shrank the bar")
        // Only 20 pt down, then flicked past the top: open as well.
        Self.scroll(&spot, by: 20, into: &trail)
        #expect(!trail.isOpen)
        Self.scroll(&spot, by: -50, step: 10, into: &trail)
        Self.scroll(&spot, by: 30, step: 3, into: &trail)
        #expect(trail.isOpen)
    }

    /// N2: pull to refresh at the top. The pull is a scroll up; while it refreshes the spinner
    /// holds the content down (the inset grows by its height); as it ends the system moves the
    /// content back up to its top, which is no scroll of the user's.
    @Test func pullToRefreshKeepsTheBarOpen() {
        var trail = Moment.BarTrail()
        var spot = Self.page()
        trail.scrolled(to: spot, .other)
        Self.scroll(&spot, by: -120, step: 4, into: &trail)
        #expect(trail.isOpen)
        // Let go: it settles with the spinner above the cards.
        spot.top -= 60
        Self.scroll(&spot, by: 60, step: 4, into: &trail)
        trail.scrolled(to: spot, .other)
        #expect(trail.isOpen)
        // The refresh ends: the spinner goes, animated by the system.
        for _ in 0..<15 {
            spot.top += 4
            spot.offset += 4
            trail.scrolled(to: spot, .other)
        }
        #expect(spot.offset == -140 && spot.top == -140)
        #expect(trail.isOpen, "the end of the refresh shrank the bar")
        // The trail goes on as before.
        Self.scroll(&spot, by: 20, into: &trail)
        #expect(!trail.isOpen)
        Self.scroll(&spot, by: -20, into: &trail)
        #expect(trail.isOpen)

        // A bar taken for shrunk at the top (a tab chosen by Siri) opens with a pull.
        var unsure = Moment.BarTrail(isOpen: false)
        var pulled = Self.page()
        unsure.scrolled(to: pulled, .other)
        Self.scroll(&pulled, by: -30, into: &unsure)
        #expect(unsure.isOpen)
    }

    /// N2: a list that fits the screen cannot scroll; dragged and let go it bounces back, which
    /// is no scroll: it stays as it was, and open once it is back at its top.
    @Test func aListThatFitsTheScreenStaysOpen() {
        var trail = Moment.BarTrail()
        var spot = Self.page(height: 400)
        #expect(spot.end < spot.top)
        trail.scrolled(to: spot, .other)
        Self.scroll(&spot, by: 60, step: 5, into: &trail)
        #expect(trail.isOpen, "dragged up, it bounces back: no scroll down")
        Self.scroll(&spot, by: -60, step: 5, into: &trail)
        #expect(trail.isOpen)
        // Taken for shrunk (a tab chosen by Siri): the next drag that ends at the top opens it.
        var unsure = Moment.BarTrail(isOpen: false)
        var short = Self.page(height: 400)
        unsure.scrolled(to: short, .other)
        Self.scroll(&short, by: 40, step: 5, into: &unsure)
        #expect(!unsure.isOpen)
        Self.scroll(&short, by: -40, step: 5, into: &unsure)
        #expect(unsure.isOpen)
    }

    /// A bounce at the end of the list is no scroll either: it neither opens nor shrinks the bar.
    @Test func aBounceAtTheEndIsNoScroll() {
        var trail = Moment.BarTrail()
        var spot = Self.page()
        trail.scrolled(to: spot, .other)
        Self.scroll(&spot, by: spot.end - spot.offset, step: 40, into: &trail)
        #expect(!trail.isOpen)
        Self.scroll(&spot, by: 60, step: 20, into: &trail)
        Self.scroll(&spot, by: -60, step: 4, into: &trail)
        #expect(spot.offset == spot.end)
        #expect(!trail.isOpen, "bouncing back from past the end opened the bar")
        Self.scroll(&spot, by: -36, into: &trail)
        #expect(trail.isOpen)
        Self.scroll(&spot, by: 36 + 60, step: 12, into: &trail)
        Self.scroll(&spot, by: -60, step: 4, into: &trail)
        #expect(!trail.isOpen)
    }

    /// Should iOS report the room the large title gives up as it folds as a smaller inset, the
    /// content's top follows the offset at first: it still counts as a scroll down, and as one up.
    @Test func aFoldingLargeTitleIsStillAScroll() {
        var trail = Moment.BarTrail()
        var spot = Self.page()
        trail.scrolled(to: spot, .other)
        for _ in 0..<3 {
            spot.offset += 4
            spot.top += 4
            trail.scrolled(to: spot, .user)
        }
        #expect(!trail.isOpen)
        for _ in 0..<3 {
            spot.offset -= 4
            spot.top -= 4
            trail.scrolled(to: spot, .user)
        }
        #expect(trail.isOpen)
    }

    // MARK: Which screen, which tab

    /// N2: back from a suggestion's page (it has no cards: nothing reads its scroll, so it may have
    /// shrunk the bar unseen). At the top of the list the bar is open, as the start page shows it
    /// in draft E6; elsewhere it counts as shrunk until a scroll up.
    @Test func backFromASuggestionTheBarIsOpenAtTheTop() {
        var watch = Moment.TabWatch()
        let tab = UUID()
        watch.show(place: tab, true, now: 0)
        var start = Screen(spot: Self.page())
        watch.appeared(screen: start.id, on: tab, at: nil, again: false, now: 0.1)
        start.read(in: &watch)
        #expect(watch.barOpen)
        start.scroll(by: 300, in: &watch)
        #expect(!watch.barOpen)
        start.scroll(by: -300, in: &watch)
        #expect(watch.barOpen)
        // A suggestion's page covers the start page and goes again.
        watch.disappeared(screen: start.id)
        watch.appeared(screen: start.id, on: tab, at: start.spot, again: true, now: 30)
        #expect(watch.barOpen, "at the top after a pop the bar counts as shrunk")
        // Not at the top: shrunk, whatever it was before, until the list scrolls up.
        start.scroll(by: 200, in: &watch)
        start.scroll(by: -50, in: &watch)
        #expect(watch.barOpen)
        watch.disappeared(screen: start.id)
        watch.appeared(screen: start.id, on: tab, at: start.spot, again: true, now: 60)
        #expect(!watch.barOpen)
        start.scroll(by: -40, in: &watch)
        #expect(watch.barOpen, "the scroll up after the pop counts from where the list was")
        // A list that never reported a reading never scrolled: back on it, it is at its top.
        var fresh = Moment.TabWatch()
        fresh.show(place: tab, true, now: 0)
        fresh.appeared(screen: start.id, on: tab, at: nil, again: false, now: 0.1)
        fresh.disappeared(screen: start.id)
        fresh.appeared(screen: start.id, on: tab, at: nil, again: true, now: 30)
        #expect(fresh.barOpen)
    }

    /// Another tab: a new trail, open, as the bar was open to choose the tab; its screens that show
    /// with it (just before or after its tab) are no pop. A tab chosen in code (Siri, Spotlight)
    /// may come with a shrunk bar: shrunk, even at the top, until a pull or a scroll up.
    @Test func anotherTabStartsANewTrail() {
        var watch = Moment.TabWatch()
        let suggestions = UUID(), albums = UUID()
        watch.show(place: suggestions, true, now: 0)
        var start = Screen(spot: Self.page())
        watch.appeared(screen: start.id, on: suggestions, at: nil, again: false, now: 0)
        start.read(in: &watch)
        start.scroll(by: 300, in: &watch)
        #expect(!watch.barOpen)
        // To "Alben" (no cards there) and back: the list is still scrolled down, the bar open.
        watch.disappeared(screen: start.id)
        watch.show(place: suggestions, false, now: 10)
        watch.show(place: albums, true, now: 10)
        #expect(watch.barOpen)
        watch.show(place: albums, false, now: 20)
        watch.show(place: suggestions, true, now: 20)
        watch.appeared(screen: start.id, on: suggestions, at: start.spot, again: true, now: 20.05)
        #expect(watch.barOpen)
        start.read(in: &watch)
        start.scroll(by: 20, in: &watch)
        #expect(!watch.barOpen, "the new trail follows the list")
        // The list may show just before its tab does.
        watch.disappeared(screen: start.id)
        watch.show(place: suggestions, false, now: 30)
        watch.show(place: albums, true, now: 30)
        watch.appeared(screen: start.id, on: suggestions, at: start.spot, again: true, now: 40)
        watch.show(place: albums, false, now: 40)
        watch.show(place: suggestions, true, now: 40)
        #expect(watch.barOpen)
        // Siri or Spotlight opens the tab from "Alben" (a tab chosen in code): the bar may still be
        // shrunk, so it counts as shrunk, even at the top, until a pull.
        start.read(in: &watch)
        start.scroll(by: start.spot.top - start.spot.offset, in: &watch)
        watch.disappeared(screen: start.id)
        watch.show(place: suggestions, false, now: 50)
        watch.show(place: albums, true, now: 50)
        watch.tabChosenInCode()
        watch.show(place: albums, false, now: 60)
        watch.show(place: suggestions, true, now: 60)
        watch.appeared(screen: start.id, on: suggestions, at: start.spot, again: true, now: 60.1)
        start.read(in: &watch)
        #expect(!watch.barOpen)
        start.scroll(by: -30, step: 3, in: &watch)
        #expect(watch.barOpen, "a pull at the top")
        // The mark is used up: the next tab the user chooses is open again.
        start.scroll(by: 300, in: &watch)
        watch.disappeared(screen: start.id)
        watch.show(place: suggestions, false, now: 70)
        watch.show(place: albums, true, now: 70)
        #expect(watch.barOpen)
        // A suggestion Siri opens covers the start page: back from it, at the top, the bar is open.
        watch.tabChosenInCode()
        watch.show(place: albums, false, now: 80)
        watch.show(place: suggestions, true, now: 80)
        #expect(!watch.barOpen)
        start.spot.offset = start.spot.top
        watch.appeared(screen: start.id, on: suggestions, at: start.spot, again: true, now: 90)
        #expect(watch.barOpen)
    }

    /// A pushed list keeps the bar as it was (a push does not change it) and goes on with it.
    @Test func aPushedListKeepsTheTrail() {
        var watch = Moment.TabWatch()
        let tab = UUID()
        watch.show(place: tab, true, now: 0)
        var start = Screen(spot: Self.page())
        watch.appeared(screen: start.id, on: tab, at: nil, again: false, now: 0)
        start.read(in: &watch)
        start.scroll(by: 300, in: &watch)
        // "Alle Vorschläge": the list appears before the start page goes.
        var list = Screen(spot: Self.page(height: 5000))
        watch.appeared(screen: list.id, on: tab, at: nil, again: false, now: 5)
        watch.disappeared(screen: start.id)
        #expect(!watch.barOpen, "a push opened the bar")
        list.read(in: &watch)
        #expect(!watch.barOpen)
        list.scroll(by: 100, in: &watch)
        list.scroll(by: -40, in: &watch)
        #expect(watch.barOpen)
        // Opened from the top of the start page, the list starts open.
        var other = Moment.TabWatch()
        other.show(place: tab, true, now: 0)
        other.appeared(screen: start.id, on: tab, at: nil, again: false, now: 0)
        other.appeared(screen: list.id, on: tab, at: nil, again: false, now: 5)
        other.disappeared(screen: start.id)
        #expect(other.barOpen)
    }

    /// Only the screen on top of the tab that shows feeds the trail: during a push both show, and
    /// a screen of another tab never counts. A screen's first reading is no scroll.
    @Test func onlyTheScreenOnTopFeedsTheTrail() {
        var watch = Moment.TabWatch()
        let tab = UUID(), elsewhere = UUID()
        watch.show(place: tab, true, now: 0)
        var start = Screen(spot: Self.page())
        var list = Screen(spot: Self.page(height: 5000))
        watch.appeared(screen: start.id, on: tab, at: nil, again: false, now: 0)
        watch.appeared(screen: list.id, on: tab, at: nil, again: false, now: 0.2)
        #expect(watch.feeding == list.id)
        start.read(in: &watch)
        start.scroll(by: 300, in: &watch)
        #expect(watch.barOpen, "the screen under the pushed one scrolled the trail")
        var away = Screen(spot: Self.page())
        watch.appeared(screen: away.id, on: elsewhere, at: nil, again: false, now: 0.3)
        #expect(watch.feeding == list.id)
        away.read(in: &watch)
        away.scroll(by: 300, in: &watch)
        #expect(watch.barOpen, "a screen of another tab scrolled the trail")
        // The list's first reading, far down, is no scroll; its next ones are.
        list.spot.offset = 900
        list.read(in: &watch)
        #expect(watch.barOpen)
        list.scroll(by: 12, in: &watch)
        #expect(!watch.barOpen)
        // Once the list goes, the start page feeds again from its own next reading.
        watch.disappeared(screen: list.id)
        #expect(watch.feeding == start.id)
        start.scroll(by: -30, in: &watch)
        #expect(!watch.barOpen, "a screen's first reading after another fed the trail counted as a scroll")
        start.scroll(by: -12, in: &watch)
        #expect(watch.barOpen)
    }

    /// A back swipe shows the list below before it is done; one the user takes back leaves the
    /// bar as the list on top had it.
    @Test func aBackSwipeTakenBackLeavesTheTrail() {
        var watch = Moment.TabWatch()
        let tab = UUID()
        watch.show(place: tab, true, now: 0)
        var start = Screen(spot: Self.page())
        watch.appeared(screen: start.id, on: tab, at: nil, again: false, now: 0)
        start.read(in: &watch)
        var list = Screen(spot: Self.page(height: 5000))
        watch.appeared(screen: list.id, on: tab, at: nil, again: false, now: 5)
        watch.disappeared(screen: start.id)
        list.read(in: &watch)
        list.scroll(by: 300, in: &watch)
        #expect(!watch.barOpen)
        // The swipe begins: the start page, at its top, shows under the list.
        watch.appeared(screen: start.id, on: tab, at: start.spot, again: true, now: 10)
        #expect(watch.barOpen)
        // Taken back.
        watch.disappeared(screen: start.id)
        #expect(!watch.barOpen)
        list.scroll(by: -12, in: &watch)
        #expect(!watch.barOpen)
        // Done: the list goes.
        watch.appeared(screen: start.id, on: tab, at: start.spot, again: true, now: 20)
        watch.disappeared(screen: list.id)
        #expect(watch.barOpen)
        start.scroll(by: 12, in: &watch)
        #expect(!watch.barOpen, "the trail goes on from where the start page was")
        // Another list, left with the back button: it may go before the start page shows.
        let second = Screen(spot: Self.page(height: 5000))
        watch.appeared(screen: second.id, on: tab, at: nil, again: false, now: 30)
        watch.disappeared(screen: start.id)
        second.read(in: &watch)
        watch.disappeared(screen: second.id)
        watch.appeared(screen: start.id, on: tab, at: start.spot, again: true, now: 40)
        #expect(!watch.barOpen, "12 pt down is not the top")
    }

    /// The tabs' screens are measured where the banner shows (`QuickCreateMomentBarProbe`): at
    /// most `keptPlaces` are kept, the one noted longest ago that does not show goes first, and
    /// one that shows is never dropped (review E of design wave 2, finding 14).
    @Test func theTabsScreensArePruned() {
        var watch = Moment.TabWatch()
        let shown = UUID()
        let bar = Moment.TabPlace(barTop: 769, top: 59)
        watch.measured(bar, for: shown)
        watch.show(place: shown, true, now: 0)
        #expect(watch.place == bar)
        #expect(watch.shownPlace == shown)
        for index in 0..<12 {
            watch.measured(Moment.TabPlace(barTop: Double(index), top: 0), for: UUID())
        }
        #expect(watch.places.count == Moment.TabWatch.keptPlaces)
        #expect(watch.place == bar, "the screen that shows was dropped")
        // Gone from view: dropped as others come, measured again when it shows again.
        watch.show(place: shown, false, now: 1)
        #expect(watch.place == nil)
        for index in 0..<8 {
            watch.measured(Moment.TabPlace(barTop: Double(index), top: 0), for: UUID())
        }
        #expect(watch.places[shown] == nil)
        watch.measured(bar, for: shown)
        watch.show(place: shown, true, now: 2)
        #expect(watch.place == bar)
    }
}
