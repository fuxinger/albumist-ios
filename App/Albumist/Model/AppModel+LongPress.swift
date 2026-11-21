import Foundation
import AlbumistCore

/// The long press on suggestion cards and photos (design wave 2, DS-06a; draft E4 "lang
/// drücken"): what a card's menu offers is read where the open suggestion reads it, so the card
/// and its suggestion's "…" always offer the same (`SuggestionMenu`, `PhotoMenu`).
extension AppModel {
    /// Set aside with "Nicht jetzt", or made from there while its banner shows: the list keeps
    /// its card under "Nicht jetzt" (`quickCreateKeepsNotNow`), and its menu offers no second
    /// "Nicht jetzt".
    func isSetAside(_ proposal: AlbumProposal) -> Bool {
        decisions[proposal.id] == .reject || quickCreateKeepsNotNow(proposal.id)
    }

    /// "Keine Reise, hier bin ich öfter": the same answer without being asked, for a place
    /// visited too rarely for the question (a semester abroad, a new second home). Not while
    /// the question card asks it. Offered by the open suggestion's "…" and its card's long press.
    func offersNotATrip(_ proposal: AlbumProposal) -> Bool {
        recurringPlaceQuestion(for: proposal) == nil && canMarkRecurringPlace(proposal)
    }

    /// What the long press on `proposal`'s card offers now. `made`, `working`, `waits` and
    /// `selecting` are the card's state as its page knows it. Each fact is read only where the
    /// menu shows what it decides: nothing without a menu, and whether "Keine Reise" can be
    /// answered now (the analysis, the plans) only where it is offered (review C of design wave
    /// 2, M5). Called where the menu's items are evaluated (`SuggestionMenuItems`): to show the
    /// menu, and for a card's actions while an assistive technology or a UI test asks for them;
    /// then every card follows what it reads here, a trip card where "Keine Reise" is offered
    /// the analysis too (review C2 of design wave 2, N3).
    func suggestionMenu(for proposal: AlbumProposal, action: ProposalCardAction, made: Bool, working: Bool,
                        waits: Bool, selecting: Bool) -> SuggestionMenu {
        SuggestionMenu(action: action, made: made, working: working, waits: waits, selecting: selecting,
                       setAside: { isSetAside(proposal) }, canReshape: { canReshape(proposal) },
                       offersNotATrip: { offersNotATrip(proposal) }, canAnswerNotATrip: { canChangeHome })
    }

    /// The suggestion as the analysis has it now, found by its id, with its photos and name now
    /// (`SuggestionMenu.current`), for whatever acts on a suggestion a card shows: a long press's
    /// menu stays open as long as the user leaves it, while the analysis may change or remake
    /// the suggestions, and the card it was drawn from cannot follow once it is gone. Nil when
    /// it went meanwhile (made anew, split, merged, made): then that is said, and nothing is made
    /// from the copy (review C of design wave 2, H1).
    func currentSuggestion(_ proposal: AlbumProposal) -> AlbumProposal? {
        if let current = SuggestionMenu.current(proposal, in: proposals) { return current }
        message = .suggestionChanged
        return nil
    }

    /// The photo is ignored: its long press offers "Nicht mehr ignorieren" instead of
    /// "Ignorieren". As its "Info" tells it (`AssetDetailView`) where it has a state; a photo
    /// without one (an album's photo the analysis has not read yet) by the photos the user
    /// ignored, as "Ignorieren" gives it no state (review C of design wave 2, L6).
    func isIgnored(_ id: AssetID) -> Bool {
        PhotoMenu.isIgnored(id, ignored: ignoredIDs, state: states[id])
    }
}

extension AppMessage {
    /// A card's action or an item of its menu found its suggestion gone (`currentSuggestion`):
    /// nothing was done, and where to see what there is now. The title is the purchase sheet's
    /// for the same case (`continueQuickCreate`).
    static var suggestionChanged: AppMessage {
        AppMessage(title: String(localized: "Der Vorschlag hat sich geändert"),
                   text: String(localized: "Albumist hat die Vorschläge eben aktualisiert. Angelegt oder geändert wurde nichts; den neuen Stand siehst du auf der Seite „Vorschläge“."))
    }
}
