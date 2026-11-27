import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Which covers of the stack load next while the plan runs (draft E3; review E2 of design wave 2,
/// N3): a few cards side by side in the stack's order, a card Photos did not answer for makes way
/// for the next and is tried again after them, and only cards that may still lie on the stack
/// load. The app loads each through `CoverLoader` (sharp, from the device) and keeps what arrives.
@Suite("Result cover prefetch")
struct ResultCoverPrefetchTests {
    typealias Prefetch = ResultCoverPrefetch

    static func cards(_ count: Int) -> [String] {
        (0..<count).map { "card\($0)" }
    }

    /// Starts what may start now.
    static func start(_ loading: inout Prefetch) -> [Prefetch.Start] {
        var started: [Prefetch.Start] = []
        while let next = loading.next() { started.append(next) }
        return started
    }

    static func answer(_ loading: inout Prefetch, _ card: String, _ answer: Prefetch.Answer) {
        loading.record(Prefetch.Arrival(card: card, answer: answer))
    }

    /// Three cards load side by side, in the stack's order (review E2, N3: one after another, a
    /// card Photos did not answer for held up every card after it).
    @Test func theCoversLoadSideBySide() {
        #expect(Prefetch.together == 3)
        var loading = Prefetch(cards: Self.cards(8), limit: 5)
        let first = Self.start(&loading)
        #expect(first.map(\.card) == ["card0", "card1", "card2"])
        #expect(first.allSatisfy { !$0.again })
        #expect(loading.loading == 3)
        let fourth = loading.next()
        #expect(fourth == nil, "no fourth while three load")
        Self.answer(&loading, "card1", .sharp("p1"))
        let then = Self.start(&loading)
        #expect(then.map(\.card) == ["card3"])
        #expect(!loading.isDecided)
    }

    /// A card Photos did not answer for makes way for the next ones and is tried again after
    /// them: the stack does not wait on it, and it still gets its turn while there is time.
    @Test func aCardWithoutAnswerMakesWayAndComesBack() {
        var loading = Prefetch(cards: Self.cards(6), limit: 5)
        _ = Self.start(&loading)
        Self.answer(&loading, "card0", .noAnswer)
        let next = Self.start(&loading)
        #expect(next == [Prefetch.Start(card: "card3", again: false)])
        Self.answer(&loading, "card1", .sharp("p1"))
        let after = Self.start(&loading)
        #expect(after == [Prefetch.Start(card: "card4", again: false)])
        Self.answer(&loading, "card2", .sharp("p2"))
        // Cards 0 to 4 may still lie on the stack: card 5 waits, card 0 comes back.
        let back = Self.start(&loading)
        #expect(back == [Prefetch.Start(card: "card0", again: true)])
        Self.answer(&loading, "card3", .sharp("p3"))
        Self.answer(&loading, "card4", .sharp("p4"))
        #expect(!loading.isDecided, "card 0 may still be the main cover")
        Self.answer(&loading, "card0", .sharp("p0"))
        #expect(loading.isDecided)
        #expect(loading.sharp == ["card0": "p0", "card1": "p1", "card2": "p2", "card3": "p3", "card4": "p4"])
        let done = Self.start(&loading)
        #expect(done.isEmpty)
    }

    /// A card is tried at most `tries` times, as a card's own cover; then the stack goes on
    /// without it.
    @Test func aCardIsTriedAFewTimesAtMost() {
        #expect(Prefetch.tries == 4)
        var loading = Prefetch(cards: Self.cards(1), limit: 5)
        var starts: [Prefetch.Start] = []
        while let next = loading.next() {
            starts.append(next)
            Self.answer(&loading, next.card, .noAnswer)
        }
        let again = Array(repeating: Prefetch.Start(card: "card0", again: true), count: 3)
        #expect(starts == [Prefetch.Start(card: "card0", again: false)] + again)
        #expect(loading.isDecided)
        #expect(loading.sharp.isEmpty)
    }

    /// Only cards that may still lie on the stack load: once the cards before one have, or may
    /// still get, as many sharp covers as the stack holds, it waits; a card without a sharp photo
    /// on the device makes room for the next. The stack is decided in its own order.
    @Test func onlyCardsThatMayLieOnTheStackLoad() {
        var loading = Prefetch(cards: Self.cards(7), limit: 3)
        let first = Self.start(&loading)
        #expect(first.map(\.card) == ["card0", "card1", "card2"])
        Self.answer(&loading, "card2", .sharp("p2"))
        Self.answer(&loading, "card1", .sharp("p1"))
        let waiting = Self.start(&loading)
        #expect(waiting.isEmpty, "cards 0, 1 and 2 may fill the stack")
        Self.answer(&loading, "card0", .noSharpPhoto)
        #expect(!loading.isDecided)
        let next = Self.start(&loading)
        #expect(next.map(\.card) == ["card3"])
        Self.answer(&loading, "card3", .sharp("p3"))
        #expect(loading.isDecided)
        #expect(loading.sharp == ["card1": "p1", "card2": "p2", "card3": "p3"])
        // An answer nobody asked for changes nothing.
        Self.answer(&loading, "card6", .sharp("p6"))
        #expect(loading.sharp["card6"] == nil)
    }

    /// Nothing to load, or no room on the stack: decided at once.
    @Test func nothingToLoad() {
        var empty = Prefetch(cards: [], limit: 5)
        let none = empty.next()
        #expect(empty.isDecided)
        #expect(none == nil)
        var full = Prefetch(cards: Self.cards(3), limit: 0)
        let nothing = full.next()
        #expect(full.isDecided)
        #expect(nothing == nil)
    }
}
