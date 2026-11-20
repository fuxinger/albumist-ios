import Foundation
import SortlyCore
import SortlyEngine

/// What the start page "Vorschläge" reads from the model (design wave 1, drafts E1, E6, E7).
/// The decisions are in the core (`StartPage`, `ProposalCardText`, `FinishNotice`,
/// `AnalysisDoneLine`); this only hands them the model's facts. The cards' words and covers are
/// the suggestion list's (`proposalCard(for:)`, `proposalCoverIDs(for:)`).
extension AppModel {
    /// The first analysis went through once (the same fact the ring and the card for an empty
    /// library read).
    var analysedOnce: Bool {
        AnalysisMarker.completedOnce || analysis.lastReport?.isComplete == true
    }

    /// An analysis runs that may bring suggestions: not a quick check for new photos, not the
    /// overnight refinement. Read by the page above (it changes with the analysis).
    var analysisMayBringSuggestions: Bool {
        analysis.isRunning && analysis.kind != .check && !analysis.refining
    }

    /// The suggestions are being made anew: a recount ("Nur 2026" → "Alle Jahre", "Analyse neu
    /// aufbauen", the labels of a new area), the tables being cleared, a change in "Dein Zuhause".
    var suggestionsRebuilding: Bool {
        recount != nil || analysisResetting || homeChangeRunning
    }

    /// The suggestions open on the start page (`StartPage.isOpen`): no decision, or an accepted
    /// one that still changes something in Photos, and not complete in Photos already.
    var startOpenIDs: Set<SortlyID> {
        var open = Set<SortlyID>()
        for proposal in proposals
        where StartPage.isOpen(decision: decisions[proposal.id], complete: match(for: proposal)?.status == .alreadyComplete) {
            open.insert(proposal.id)
        }
        return open
    }

    /// The sections of the start page for this visit. `analysedOnce`, `showsMosaic`, `rebuilding`
    /// and `analysing` come from the page above (`analysedOnce`, `showsScanShow`,
    /// `suggestionsRebuilding`, `analysisMayBringSuggestions`): read there, so the analysis'
    /// frequent changes redraw the ring card and not every suggestion's card.
    func startPage(visit: StartVisit, libraryHint: Bool, starterSet: [AlbumProposal], analysedOnce: Bool,
                   showsMosaic: Bool, rebuilding: Bool, analysing: Bool) -> StartPage {
        StartPage.make(.init(
            proposals: proposals, open: startOpenIDs,
            areas: OrganizationArea.available.filter { settings.enabledAreas.contains($0) },
            analysedOnce: analysedOnce, showsMosaic: showsMosaic, starterSet: starterSet.map(\.id),
            nothingMadeYet: history.isEmpty && acceptedProposals.isEmpty, libraryHint: libraryHint,
            rebuilding: rebuilding, analysing: analysing, interruptedPlan: interruptedPlan != nil,
            inYourAlbums: suggestionsInYourAlbums, visit: visit))
    }

    /// Suggestions whose album is one of the user's already: the same albums as the ring
    /// (`AlbumMatcher.sortingAlbums`), as the area list said it ("12 davon in deinen Alben").
    var suggestionsInYourAlbums: Int {
        let matcher = AlbumMatcher()
        return proposals.reduce(0) { count, proposal in
            matcher.sortingAlbums(match(for: proposal), kind: proposal.kind, title: proposal.title).isEmpty ? count : count + 1
        }
    }

    /// When the last album was made or changed (undoing is not in `history`): "Neue Reisen" are
    /// the trips that ended after it.
    var lastAlbumsMade: Date? {
        history.compactMap { $0.finalizedAt ?? $0.confirmedAt }.max()
    }
}
