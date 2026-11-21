import Foundation
import SortlyCore

/// What a suggestion's card and its open page show, from the model's state (design wave 1: E1,
/// E2, E6): the card's words (`ProposalCardText`, the same album name and folder the plan and the
/// receipt will name), its cover candidates and its photos by day. The words are in the app's
/// language (`ProposalWords`): "16 photos · New album" in English.
extension AppModel {
    /// The language the app shows (its localization, not the first language of the device) with
    /// the region's number format ("1.354" in Germany, "1,354" in the US).
    var proposalWords: ProposalWords {
        ProposalWords(localization: Bundle.main.preferredLocalizations.first, region: Locale.current.region?.identifier)
    }

    /// The card of `proposal` as it stands: the user's decision and name for it, the photos taken
    /// out of it, the folder for new albums. `typedTitle`: a name typed in the open suggestion
    /// that is not stored yet (blank is no name).
    func proposalCard(for proposal: AlbumProposal, typedTitle: String? = nil) -> ProposalCardText {
        ProposalCardText(proposal: proposal, decision: shownDecision(for: proposal, typedTitle: typedTitle),
                         userTitle: typedTitle ?? userTitles[proposal.id], match: match(for: proposal),
                         inventory: inventory, removed: removedFromProposals[proposal.id] ?? [],
                         hidesPreview: previewHidden(for: proposal),
                         rootFolderTitle: settings.rootFolderTitle, words: proposalWords)
    }

    /// The user's decision as the card shows it. A name typed in the open suggestion is the new
    /// album's name, also over one chosen before under "Anpassen" ("Neues Album wählen" stores it
    /// with the decision, where it would win over the field: second review of design wave 1);
    /// with the field blank there is no name yet.
    private func shownDecision(for proposal: AlbumProposal, typedTitle: String?) -> ProposalDecision? {
        let decision = decisions[proposal.id]
        guard let typedTitle, case .createNew(_, let folderPath)? = decision else { return decision }
        return UserTitle.stored(typedTitle) == nil ? nil : .createNew(title: nil, folderPath: folderPath)
    }

    /// The photos a cover of `proposal` tries, best first (`PreviewPicker.coverCandidates`): its
    /// own cover, then favourites (`favorites`), then the newest analysed photos; never a
    /// screenshot, a document or a sensitive photo, and none it no longer holds. Kept per
    /// suggestion until its photos, its cover or the photos' facts change
    /// (`CoverCandidatesCache`): the start page and the list ask for every card in each pass of
    /// their body, and working them out goes once over all photos of the suggestion (review A of
    /// design wave 1). The work is a marked section of the main thread (`MainThreadWatch`).
    func proposalCoverIDs(for proposal: AlbumProposal, favorites: Set<AssetID> = []) -> [AssetID] {
        let removed = removedFromProposals[proposal.id] ?? []
        let dates = creationDates
        let ranks = previewRanks
        let source = CoverCandidatesCache.Source(photos: proposal.assetIDs, removed: removed,
                                                 cover: proposal.coverAssetID, favorites: favorites)
        return CoverCandidatesCache.shared.candidates(of: proposal.id, from: source, dates: dates, ranks: ranks) {
            MainThreadWatch.shared.section("cover candidates") {
                PreviewPicker.coverCandidates(proposal.assetIDs.subtracting(removed), cover: coverID(for: proposal),
                                              dates: dates, ranks: ranks, favorites: favorites)
            }
        }
    }

    /// The favourites among the photos of `proposal`, for its big cover on its own page (one
    /// suggestion: cheap; the cards of a list leave them out).
    func proposalFavorites(for proposal: AlbumProposal) -> Set<AssetID> {
        let facts = factsByID
        let removed = removedFromProposals[proposal.id] ?? []
        return Set(proposal.assetIDs.lazy.filter { !removed.contains($0) && facts[$0]?.asset.isFavorite == true })
    }

    /// The photos of `proposal` by day, as Photos shows its days: each photo on the day of the
    /// clock where it was taken, oldest day first, photos without a date last (`PhotoDays`).
    func proposalPhotoDays(for proposal: AlbumProposal) -> [PhotoDay] {
        PhotoDays.group(members(of: proposal), facts: factsByID, fallback: .current, words: proposalWords)
    }
}
