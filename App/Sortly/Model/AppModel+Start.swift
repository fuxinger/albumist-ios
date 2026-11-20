import Foundation
import SortlyCore
import SortlyEngine

/// What the start page "Vorschläge" reads from the model (design wave 1, drafts E1, E6, E7).
/// The decisions are in the core (`StartPage`, `ProposalCardText`, `FinishNotice`,
/// `AnalysisDoneLine`); this only hands them the model's facts.
extension AppModel {
    /// The first analysis went through once (the same fact the ring and the card for an empty
    /// library read).
    var analysedOnce: Bool {
        AnalysisMarker.completedOnce || analysis.lastReport?.isComplete == true
    }

    /// The sections of the start page for this visit. `analysedOnce` and `showsMosaic` come from
    /// the page above (`analysedOnce`, `showsScanShow`): read there, so the analysis' frequent
    /// changes redraw the ring card and not every suggestion's card.
    func startPage(visit: StartVisit, libraryHint: Bool, starterSetSize: Int, analysedOnce: Bool,
                   showsMosaic: Bool) -> StartPage {
        StartPage.make(.init(
            proposals: proposals, open: Set(openProposals.map(\.id)),
            areas: OrganizationArea.available.filter { settings.enabledAreas.contains($0) },
            analysedOnce: analysedOnce, showsMosaic: showsMosaic, starterSetSize: starterSetSize,
            nothingMadeYet: history.isEmpty && acceptedProposals.isEmpty, libraryHint: libraryHint, visit: visit))
    }

    /// When the last album was made or changed (undoing is not in `history`): "Neue Reisen" are
    /// the trips that ended after it.
    var lastAlbumsMade: Date? {
        history.compactMap { $0.finalizedAt ?? $0.confirmedAt }.max()
    }

    /// The photos a suggestion's card tries as its cover, best first: its own cover when it
    /// suits, then the newest ordinary photos; never a sensitive document or a screenshot
    /// (`PreviewPicker.coverCandidates`). `CoverPhoto` shows the first one that is sharp on the
    /// device, or its calm placeholder.
    func startCardCovers(for proposal: AlbumProposal) -> [AssetID] {
        let members = proposal.assetIDs.subtracting(removedFromProposals[proposal.id] ?? [])
        return PreviewPicker.coverCandidates(members, cover: coverID(for: proposal), dates: creationDates, ranks: previewRanks)
    }

    /// What a suggestion's card says and its one action ("Anlegen", "Ergänzen …", "Benennen …",
    /// "Ansehen …"), worked out as the plan would make it (`ProposalCardText`), in the app's
    /// language.
    func startCardText(for proposal: AlbumProposal) -> ProposalCardText {
        ProposalCardText(proposal: proposal, decision: decisions[proposal.id], userTitle: userTitles[proposal.id],
                         match: match(for: proposal), inventory: inventory,
                         removed: removedFromProposals[proposal.id] ?? [], hidesPreview: previewHidden(for: proposal),
                         rootFolderTitle: settings.rootFolderTitle, words: startCardWords)
    }
}

/// The words of the cards in the app's own language (its localization, not the iPhone's), with
/// the iPhone's region for the thousands separator, as `ProposalWords` asks.
private let startCardWords = ProposalWords(localization: Bundle.main.preferredLocalizations.first,
                                           region: Locale.current.region?.identifier)
