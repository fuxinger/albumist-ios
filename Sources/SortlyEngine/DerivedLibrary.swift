import Foundation
import SortlyCore
import SortlyStore

/// What `AppModel.refreshDerived` shows that is made from the whole library, read and worked out
/// in one call off the main actor (`AnalysisPipeline.derivedLibrary`); the app only assigns it.
///
/// Review P4-02: the app read the facts, and next to them the image results of every photo and
/// the album list a second time, and awaited each pass over all photos one after the other (the
/// preview ranks, the albums that overlap, the ring); the start of the app waits for all of it.
/// Now every input is read once and the passes run side by side once the facts are there: the
/// ring does not wait for the albums that overlap (only the "Alben" tab shows them), nor for
/// the preview ranks or the caches of the first draw.
///
/// Review P4-09: what the first screens made from all photos on the main thread at their first
/// draw after each refresh (the capture dates of the previews, the atlas of all years and its
/// years, the places "Dein Zuhause" offers) is made here too, with the same functions the app's
/// caches fall back on (after a memory warning, say).
public struct DerivedLibrary: Sendable {
    public var facts: [AssetFacts] = []
    public var previewRanks: [AssetID: PreviewRank] = [:]
    public var inventory = CollectionInventory()
    public var merges: [AlbumOverlapAnalyzer.MergeSuggestion] = []
    /// Photos the user took out of a suggestion ("Aus Vorschlag entfernen"), by suggestion.
    public var removed: [SortlyID: Set<AssetID>] = [:]
    public var status = DerivedLibraryStatus()
    /// `creationDates(of: facts)`.
    public var creationDates: [AssetID: Date] = [:]
    /// The atlas of all years (`TravelAtlas.compute(facts:year: nil)`) and the years it offers.
    public var atlas = TravelAtlas()
    public var atlasYears: [Int] = []
    /// `HomeCandidates.make(facts:)`.
    public var homeCandidates: [HomeCandidate] = []

    public init() {}

    /// Capture date of every photo, for time-ordered previews (the first one of an id).
    public static func creationDates(of facts: [AssetFacts]) -> [AssetID: Date] {
        Dictionary(facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The photos the user took out of each suggestion, from the overrides.
    public static func removedFromProposals(_ overrides: [UserOverride]) -> [SortlyID: Set<AssetID>] {
        var removed: [SortlyID: Set<AssetID>] = [:]
        for o in overrides where o.decision == .neverAdd {
            if case .assetInSource(let asset, let source) = o.scope { removed[source, default: []].insert(asset) }
        }
        return removed
    }

    /// A pass over the whole library, for tests (`probe`: called as each starts and ends).
    enum Piece: String, Sendable { case previewRanks, merges, status, firstDraw }
    typealias Probe = @Sendable (Piece, _ ended: Bool) async -> Void
}

extension AnalysisPipeline {
    /// Everything the overview shows that is made from the whole library (`DerivedLibrary`).
    /// `snapshot`: the suggestions as `refreshMatchesIfOutdated` returned them; `managed`:
    /// Albumist's own albums as the app knows them; `ownAlbums`: their ids, left out of the
    /// albums that overlap (a country holds its trips on purpose).
    public nonisolated func derivedLibrary(snapshot: ProposalSnapshot?, settings: OrganizationSettings, managed: [ManagedAlbumState],
                                           scope: OrganizationScope, ownAlbums: Set<CollectionID>) async throws -> DerivedLibrary {
        try await derivedLibrary(snapshot: snapshot, settings: settings, managed: managed, scope: scope, ownAlbums: ownAlbums, probe: nil)
    }

    nonisolated func derivedLibrary(snapshot: ProposalSnapshot?, settings: OrganizationSettings, managed: [ManagedAlbumState],
                                    scope: OrganizationScope, ownAlbums: Set<CollectionID>,
                                    probe: DerivedLibrary.Probe?) async throws -> DerivedLibrary {
        let store = self.store
        // Each input once (`factsForOverview`); then the passes side by side.
        let read = try await factsForOverview()
        let inventory = read.inventory, facts = read.facts, contents = read.contents
        async let merges = Self.pass(.merges, probe) { AlbumOverlapAnalyzer().suggestions(in: inventory, excluding: ownAlbums) }
        let stored = try await store.overrides()
        let overrides = OverrideSet(stored)
        // The analysed photos still without their image labels ("Themen" or "Dokumente" turned
        // on since): only while one of the two is on, and only those photos.
        let labels = try await AnalysisPipeline.photosWaitingForLabels(in: store, settings: settings)
        async let status = Self.pass(.status, probe) {
            DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides,
                                        contents: contents, labelsMissing: labels.missing, labelsRetrying: labels.retrying,
                                        managed: managed, inventory: inventory, scope: scope)
        }
        async let ranks = Self.pass(.previewRanks, probe) { PreviewRank.ranks(of: facts) }
        async let firstDraw = Self.pass(.firstDraw, probe) {
            (DerivedLibrary.creationDates(of: facts), TravelAtlas.compute(facts: facts, year: nil), TravelAtlas.years(facts: facts),
             HomeCandidates.make(facts: facts))
        }
        var result = DerivedLibrary()
        result.facts = facts
        result.inventory = inventory
        result.removed = DerivedLibrary.removedFromProposals(stored)
        result.status = await status
        result.previewRanks = await ranks
        (result.creationDates, result.atlas, result.atlasYears, result.homeCandidates) = await firstDraw
        result.merges = await merges
        return result
    }

    /// One pass over the whole library, off any actor (a child task of `derivedLibrary`).
    private nonisolated static func pass<T: Sendable>(_ piece: DerivedLibrary.Piece, _ probe: DerivedLibrary.Probe?,
                                                      _ work: @Sendable () -> T) async -> T {
        await probe?(piece, false)
        let value = work()
        await probe?(piece, true)
        return value
    }
}
