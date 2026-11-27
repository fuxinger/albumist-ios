import Foundation

/// The cover candidates of the suggestions' cards (`PreviewPicker.coverCandidates`), kept per
/// suggestion until what they are made from changes: its photos, the photos the user took out
/// of it, its own cover, the favourites asked for, or the photos' facts (their dates and preview
/// ranks). Review A of design wave 1 (finding 1): the start page worked them out for every card
/// in each pass of its body, one pass over all photos of the suggestion each, on the main
/// thread, and the suggestion list did the same.
///
/// Like the albums tab's cache: an entry keeps what it was made from, and the cache keeps the
/// facts it was last asked with, so comparing them costs nothing while they are the same copy
/// (the model keeps one copy of each until the facts change). Emptied on a memory warning
/// (`MemoryPressure`): the candidates are worked out again at their next use.
@MainActor
public final class CoverCandidatesCache {
    public static let shared = CoverCandidatesCache()

    /// What one suggestion's candidates are made from, besides the photos' facts.
    public struct Source: Equatable, Sendable {
        public var photos: Set<AssetID>
        /// The photos the user took out of the suggestion.
        public var removed: Set<AssetID>
        /// The suggestion's own cover as the analysis chose it (`AlbumProposal.coverAssetID`).
        public var cover: AssetID?
        public var favorites: Set<AssetID>

        public init(photos: Set<AssetID>, removed: Set<AssetID> = [], cover: AssetID? = nil,
                    favorites: Set<AssetID> = []) {
            self.photos = photos
            self.removed = removed
            self.cover = cover
            self.favorites = favorites
        }
    }

    private struct Entry {
        var source: Source
        var candidates: [AssetID]
    }

    /// The facts the entries were made with.
    private var dates: [AssetID: Date] = [:]
    private var ranks: [AssetID: PreviewRank] = [:]
    private var entries: [AlbumistID: Entry] = [:]

    public init(pressure: MemoryPressure = .shared) {
        pressure.register("cover candidates", owner: self) { $0.empty() }
    }

    /// The candidates of suggestion `id`: the ones kept for `source` and these facts, else
    /// `make()`'s, kept from now on. New facts drop every entry.
    public func candidates(of id: AlbumistID, from source: Source, dates: [AssetID: Date],
                           ranks: [AssetID: PreviewRank], make: () -> [AssetID]) -> [AssetID] {
        if dates != self.dates || ranks != self.ranks { entries.removeAll() }
        // The copies asked with now, so the next comparison costs nothing (also when they hold
        // the same as the ones kept before).
        self.dates = dates
        self.ranks = ranks
        if let kept = entries[id], kept.source == source {
            entries[id]?.source = source
            return kept.candidates
        }
        let made = make()
        entries[id] = Entry(source: source, candidates: made)
        return made
    }

    /// Forgets everything, the facts too, so a memory warning frees them along with the model's
    /// own copies.
    public func empty() {
        dates = [:]
        ranks = [:]
        entries = [:]
    }
}
