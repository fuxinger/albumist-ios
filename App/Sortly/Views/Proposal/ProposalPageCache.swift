import Foundation
import SortlyCore

/// What the open suggestion works out from all of its photos: its photos by day (`PhotoDays`) and
/// its cover's candidates (`AppModel.proposalCoverIDs`). Kept while nothing they are made from
/// changes, so typing a name, ticking a photo or scrolling draws the page again without sorting
/// and grouping every photo again (second review of design wave 1). The page holds it in
/// `@State`; it is not observed: everything it is made from, the page reads itself.
@MainActor
final class ProposalPageCache {
    /// What the days and the cover candidates are made from.
    struct Key: Equatable {
        let id: SortlyID
        let photos: Set<AssetID>
        /// The photos the user took out of the suggestion.
        let removed: Set<AssetID>
        let cover: AssetID?
        /// The language of the days' titles.
        let words: ProposalWords
        /// The analysis the photos' dates and ranks come from: a new one may bring new facts
        /// for the same photos, new photos change their number.
        let analysis: Date?
        let facts: Int
    }

    private var key: Key?
    private(set) var days: [PhotoDay] = []
    private(set) var coverIDs: [AssetID] = []

    /// Makes the days and cover candidates again only when `key` is not the one they were made for.
    func update(for key: Key, days makeDays: () -> [PhotoDay], coverIDs makeCoverIDs: () -> [AssetID]) {
        guard key != self.key else { return }
        self.key = key
        days = makeDays()
        coverIDs = makeCoverIDs()
    }
}
