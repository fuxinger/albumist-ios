import Foundation
import Testing
@testable import AlbumistCore

/// Which screen and which tab the quick create moment's bar is on (`QuickCreateMomentBarTests`).
extension QuickCreateMomentBarTests {
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
        Self.followATabChosenInCode(&watch, &start, suggestions: suggestions, albums: albums)
    }

    /// The end of `anotherTabStartsANewTrail`: a tab chosen in code (Siri, Spotlight) may come with
    /// a shrunk bar, and its mark is used up by the next tab the user chooses.
    static func followATabChosenInCode(_ watch: inout Moment.TabWatch, _ start: inout Screen, suggestions: UUID, albums: UUID) {
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
