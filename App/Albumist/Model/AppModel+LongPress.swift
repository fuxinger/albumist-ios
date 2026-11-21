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
    /// `selecting` are the card's state as its page knows it; without a menu nothing else is read.
    func suggestionMenu(for proposal: AlbumProposal, action: ProposalCardAction, made: Bool, working: Bool,
                        waits: Bool, selecting: Bool) -> SuggestionMenu {
        guard !made, !working, !selecting else {
            return SuggestionMenu(SuggestionMenu.Card(action: action, made: made, working: working, selecting: selecting))
        }
        return SuggestionMenu(SuggestionMenu.Card(
            action: action, waits: waits, setAside: isSetAside(proposal), canReshape: canReshape(proposal),
            offersNotATrip: offersNotATrip(proposal), canAnswerNotATrip: canChangeHome))
    }

    /// The photo is ignored: its long press offers "Nicht mehr ignorieren" instead of
    /// "Ignorieren". As its "Info" tells it (`AssetDetailView`) where it has a state; a photo
    /// without one (an album's photo the analysis has not read yet) by the photos the user
    /// ignored, as "Ignorieren" gives it no state (review C of design wave 2, L6).
    func isIgnored(_ id: AssetID) -> Bool {
        PhotoMenu.isIgnored(id, ignored: ignoredIDs, state: states[id])
    }
}
