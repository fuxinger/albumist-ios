import Foundation

/// What the long press on a suggestion's card offers (design wave 2, DS-06a; draft E4 "lang
/// drücken": "Auf einer Vorschlags-Karte zeigt es dieselben Punkte wie „…“ im Vorschlag"), in
/// groups, in order. Every item is a shortcut to a way that exists, never a new one: the app
/// runs each one as the card's button or the open suggestion does it.
///
/// 1. The card's own word ("Anlegen", "Ergänzen …", "Benennen …", "Ansehen …"), doing what its
///    button does, and "Anpassen": both decide the album.
/// 2. For a trip, as in the open suggestion's "…": "Reise teilen oder zusammenlegen" (before
///    Albumist made its album) and "Keine Reise, hier bin ich öfter" (where the suggestion
///    offers it; it waits while the suggestions cannot change, `AppModel.canChangeHome`).
/// 3. "Nicht jetzt", unless the suggestion is set aside already.
///
/// Only what still makes sense: nothing while the card's album is made or its preview prepared,
/// once it is made ("✓ Angelegt"; "Widerrufen" is on its banner), or while the list selects
/// (a press ticks then). While another card works, the word waits as the card's button does.
public struct SuggestionMenu: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        /// The card's one action, exactly as its button shows and does it.
        case action(ProposalCardAction)
        /// "Anpassen": a new album or one of the user's albums (`AdjustProposalView`).
        case adjust
        /// "Reise teilen oder zusammenlegen" (`TripWorkshopView`).
        case reshapeTrip
        /// "Keine Reise, hier bin ich öfter", asked first ("Keine Reise?").
        case notATrip
        /// "Nicht jetzt": sets the suggestion aside; its photos and albums stay as they are.
        case notNow

        /// One word per item, for identifiers and lists.
        public var id: String {
            switch self {
            case .action: "action"
            case .adjust: "adjust"
            case .reshapeTrip: "reshapeTrip"
            case .notATrip: "notATrip"
            case .notNow: "notNow"
            }
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let item: Item
        /// Shown, but waits (dimmed in the menu).
        public let isEnabled: Bool

        public var id: String { item.id }

        public init(_ item: Item, isEnabled: Bool = true) {
            self.item = item
            self.isEnabled = isEnabled
        }
    }

    /// The card as it is now.
    public struct Card: Equatable, Sendable {
        /// Its one action (`ProposalCardText.action`).
        public var action: ProposalCardAction
        /// "✓ Angelegt": made from this card a moment ago.
        public var made: Bool
        /// Its album is being made, or its preview prepared ("Ergänzen …").
        public var working: Bool
        /// Another card's album is being made, or its preview prepared: one at a time.
        public var waits: Bool
        /// The list selects suggestions ("Auswählen").
        public var selecting: Bool
        /// Set aside with "Nicht jetzt" (`AppModel.isSetAside`).
        public var setAside: Bool
        /// A trip Albumist has not made an album of yet (`AppModel.canReshape`).
        public var canReshape: Bool
        /// The suggestion offers "Keine Reise, hier bin ich öfter" (`AppModel.offersNotATrip`).
        public var offersNotATrip: Bool
        /// The answer can be given now (`AppModel.canChangeHome`).
        public var canAnswerNotATrip: Bool

        public init(action: ProposalCardAction, made: Bool = false, working: Bool = false, waits: Bool = false,
                    selecting: Bool = false, setAside: Bool = false, canReshape: Bool = false,
                    offersNotATrip: Bool = false, canAnswerNotATrip: Bool = true) {
            self.action = action
            self.made = made
            self.working = working
            self.waits = waits
            self.selecting = selecting
            self.setAside = setAside
            self.canReshape = canReshape
            self.offersNotATrip = offersNotATrip
            self.canAnswerNotATrip = canAnswerNotATrip
        }
    }

    /// The groups of the menu, in order; none when the card offers nothing now.
    public let sections: [[Entry]]

    public init(_ card: Card) {
        guard !card.made, !card.working, !card.selecting else {
            sections = []
            return
        }
        var sections: [[Entry]] = [[Entry(.action(card.action), isEnabled: !card.waits), Entry(.adjust)]]
        var trip: [Entry] = []
        if card.canReshape { trip.append(Entry(.reshapeTrip)) }
        if card.offersNotATrip { trip.append(Entry(.notATrip, isEnabled: card.canAnswerNotATrip)) }
        if !trip.isEmpty { sections.append(trip) }
        if !card.setAside { sections.append([Entry(.notNow)]) }
        self.sections = sections
    }

    /// No menu: the long press does nothing.
    public var isEmpty: Bool { sections.isEmpty }

    /// Every entry, in order.
    public var entries: [Entry] { sections.flatMap { $0 } }

    /// Every item, in order.
    public var items: [Item] { entries.map(\.item) }

    /// Whether `item` is ready; nil when the menu does not offer it.
    public func isEnabled(_ item: Item) -> Bool? {
        entries.first { $0.item == item }?.isEnabled
    }
}
