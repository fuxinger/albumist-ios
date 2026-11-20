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
        ProposalCardText(proposal: proposal, decision: decisions[proposal.id],
                         userTitle: typedTitle ?? userTitles[proposal.id], match: match(for: proposal),
                         inventory: inventory, removed: removedFromProposals[proposal.id] ?? [],
                         hidesPreview: previewHidden(for: proposal),
                         rootFolderTitle: settings.rootFolderTitle, words: proposalWords)
    }

    /// The photos a cover of `proposal` tries, best first (`PreviewPicker.coverCandidates`): its
    /// own cover, then favourites (`favorites`), then the newest analysed photos; never a
    /// screenshot, a document or a sensitive photo, and none it no longer holds.
    func proposalCoverIDs(for proposal: AlbumProposal, favorites: Set<AssetID> = []) -> [AssetID] {
        PreviewPicker.coverCandidates(proposal.assetIDs.subtracting(removedFromProposals[proposal.id] ?? []),
                                      cover: coverID(for: proposal), dates: creationDates, ranks: previewRanks,
                                      favorites: favorites)
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
