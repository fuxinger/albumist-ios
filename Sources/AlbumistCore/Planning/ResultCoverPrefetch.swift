import Foundation

/// Which covers of the result's stack load next while the plan runs (draft E3, design wave 2;
/// review E2, N3). The covers were loaded one after another: a card Photos did not answer for
/// (it is busy with the run) held up every card after it, and the stack's size was left to
/// timing.
///
/// - `together` cards load side by side, in the stack's order (its first card is the main cover).
/// - A card Photos did not answer for makes way for the next ones and comes back after them, at
///   most `tries` times in all (as a card's own cover, `CoverLoader.retryDelays`); the app's
///   patience bounds it too.
/// - A card loads only while it may still lie on the stack: fewer than `limit` cards before it
///   have a sharp cover or may still get one. One without a sharp photo on the device makes room
///   for the next.
/// - Decided once the first `limit` sharp covers in the stack's order are known, or every card
///   answered (`isDecided`); what loads beyond that is not needed.
///
/// The app loads each card through `CoverLoader` (only sharp covers, only from the device, never
/// from iCloud) and keeps every cover that arrives in the result's own state
/// (`ResultMomentLoader.prefetch`). The stack itself never holds a personal suggestion's album.
public struct ResultCoverPrefetch: Hashable, Sendable {
    /// What loading one card's cover found.
    public enum Answer: Hashable, Sendable {
        /// The photo whose cover is sharp on the device.
        case sharp(AssetID)
        /// Photos answered: none of the card's photos is sharp on the device.
        case noSharpPhoto
        /// Photos did not answer in time (it is busy with the run): nothing is known yet.
        case noAnswer
    }

    /// A card to load now; `again` after Photos did not answer for it (the app waits a moment
    /// before it asks once more).
    public struct Start: Hashable, Sendable {
        public var card: String
        public var again: Bool

        public init(card: String, again: Bool) {
            self.card = card
            self.again = again
        }
    }

    /// A card's answer, as the app hands it back.
    public struct Arrival: Hashable, Sendable {
        public var card: String
        public var answer: Answer

        public init(card: String, answer: Answer) {
            self.card = card
            self.answer = answer
        }
    }

    /// Cards loading at once.
    public static let together = 3
    /// Loads of one card at most: the first, then again after no answer.
    public static let tries = 4

    private enum State: Hashable, Sendable {
        case waiting
        case loading
        case unanswered
        case sharp(AssetID)
        case noSharpPhoto
    }

    /// The cards (`ResultCoverStack.Card.id`), in the stack's order.
    public let cards: [String]
    /// Covers the stack shows at most.
    public let limit: Int
    private var states: [String: State] = [:]
    private var tried: [String: Int] = [:]

    public init(cards: [String], limit: Int = ResultCoverStack.limit) {
        var seen = Set<String>()
        self.cards = cards.filter { seen.insert($0).inserted }
        self.limit = limit
    }

    /// The cards whose cover is sharp, with the photo it shows.
    public var sharp: [String: AssetID] {
        var sharp: [String: AssetID] = [:]
        for (card, state) in states {
            if case .sharp(let photo) = state { sharp[card] = photo }
        }
        return sharp
    }

    /// How many cards load now.
    public var loading: Int {
        states.values.filter { $0 == .loading }.count
    }

    /// The first `limit` sharp covers in the stack's order are known, or every card answered:
    /// nothing more is needed.
    public var isDecided: Bool {
        guard limit > 0 else { return true }
        var found = 0
        for card in cards {
            switch state(of: card) {
            case .sharp:
                found += 1
                if found >= limit { return true }
            case .noSharpPhoto:
                continue
            case .unanswered where !hasTriesLeft(card):
                continue
            case .waiting, .loading, .unanswered:
                return false
            }
        }
        return true
    }

    /// The next card to load, marked as loading; nil when none starts now (`together` load, the
    /// stack is decided, or the cards left wait for those loading). Cards not tried yet come
    /// first, in the stack's order, then those Photos did not answer for.
    public mutating func next() -> Start? {
        guard loading < Self.together, !isDecided else { return nil }
        for again in [false, true] {
            // Cards before this one that have, or may still get, a sharp cover.
            var mayLie = 0
            for card in cards {
                guard mayLie < limit else { break }
                let state = state(of: card)
                let startsNow = again ? state == .unanswered && hasTriesLeft(card) : state == .waiting
                if startsNow {
                    states[card] = .loading
                    tried[card, default: 0] += 1
                    return Start(card: card, again: again)
                }
                if mayLieOnTheStack(card) { mayLie += 1 }
            }
        }
        return nil
    }

    /// A card's answer; one for a card that is not loading is not taken.
    public mutating func record(_ arrival: Arrival) {
        guard state(of: arrival.card) == .loading else { return }
        switch arrival.answer {
        case .sharp(let photo): states[arrival.card] = .sharp(photo)
        case .noSharpPhoto: states[arrival.card] = .noSharpPhoto
        case .noAnswer: states[arrival.card] = .unanswered
        }
    }

    private func state(of card: String) -> State {
        states[card] ?? .waiting
    }

    private func hasTriesLeft(_ card: String) -> Bool {
        tried[card, default: 0] < Self.tries
    }

    /// It has a sharp cover, or may still get one.
    private func mayLieOnTheStack(_ card: String) -> Bool {
        switch state(of: card) {
        case .sharp, .waiting, .loading: true
        case .unanswered: hasTriesLeft(card)
        case .noSharpPhoto: false
        }
    }
}
