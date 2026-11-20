import Foundation
import SortlyCore
import SortlyStore

/// What `AppModel.refreshDerived` shows that is made from the whole library, read and worked out
/// in one call off the main actor (`AnalysisPipeline.derivedLibrary`); the app only assigns it.
///
/// Review P4-02: the app read the facts, and next to them the image results of every photo and
/// the album list a second time, and awaited each pass over all photos one after the other (the
/// preview ranks, the albums that overlap, the ring); the start of the app waits for all of it.
/// Now every input is read once and the passes run side by side once everything is read: the
/// ring does not wait for the albums that overlap (only the "Alben" tab shows them), nor for
/// the preview ranks or the caches of the first draw.
///
/// Review P4-09: what the first screens made from all photos on the main thread at their first
/// draw after each refresh (the capture dates of the previews, the atlas of all years and its
/// years) is made here too, with the same functions the app's caches fall back on (after a
/// memory warning, say). Not the places "Dein Zuhause" offers: only that screen needs them, and
/// at every refresh they would cost battery for nothing (the app makes them off the main thread
/// when the screen asks, `AppModel.homeCandidates`).
///
/// Review P4-09, the rest: the facts by photo id (the photo view and the search hits; 97 ms at
/// 50,000 photos, 267 ms at 100,000 on the main thread at the first lookup after every refresh)
/// and the atlas of each year (75 and 151 ms on the main thread at each year chosen in the atlas)
/// are made here too, and handed over with the facts.
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
    /// The atlas of each year with photos (`yearAtlases(of:allYears:)`); a year without photos
    /// has the empty atlas of that year (`emptyYearAtlas`).
    public var yearAtlases: [Int: TravelAtlas] = [:]
    /// The facts by photo id (`FactsByID`).
    public var factsByID = FactsByID()
    /// The name of the detected home from the photos around it (`HomeName.components`), when
    /// the refresh asked for it (`AnalysisPipeline.derivedRefresh`).
    public var homeName: PlaceComponents?

    public init() {}

    /// `TravelAtlas.compute(facts:year:)` for every year with photos, from one pass over the
    /// facts and the atlas of all years (`allYears`, `TravelAtlas.compute(facts:year: nil)`),
    /// instead of a pass over all photos and the atlas of all years made again for each year.
    /// Each year's photos are copied out one year at a time (a copy of all facts would be tens
    /// of MB at 100,000 photos).
    public static func yearAtlases(of facts: [AssetFacts], allYears: TravelAtlas, calendar: Calendar = .current) -> [Int: TravelAtlas] {
        var positions: [Int: [Int]] = [:]
        for (index, f) in facts.enumerated() {
            guard let date = f.asset.creationDate else { continue }
            positions[calendar.component(.year, from: date), default: []].append(index)
        }
        var atlases: [Int: TravelAtlas] = [:]
        for (year, indices) in positions {
            // In the order of the facts, as `compute(facts:year:)` filters them.
            var atlas = TravelAtlas.compute(facts: indices.map { facts[$0] }, calendar: calendar)
            atlas.year = year
            atlas.newCountryCodes = atlas.countryCodes.filter { code in
                allYears.firstVisits[code].map { calendar.component(.year, from: $0) == year } ?? false
            }
            atlases[year] = atlas
        }
        return atlases
    }

    /// The atlas of a year without photos: `TravelAtlas.compute(facts:year:)` finds nothing in it.
    public static func emptyYearAtlas(_ year: Int) -> TravelAtlas {
        var atlas = TravelAtlas()
        atlas.year = year
        return atlas
    }

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
    enum Piece: String, Sendable { case previewRanks, merges, status, firstDraw, factsByID, homeName }
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

    /// `home`: the detected home, named from the photos around it (`DerivedLibrary.homeName`).
    nonisolated func derivedLibrary(snapshot: ProposalSnapshot?, settings: OrganizationSettings, managed: [ManagedAlbumState],
                                    scope: OrganizationScope, ownAlbums: Set<CollectionID>, home: GeoCoordinate? = nil,
                                    probe: DerivedLibrary.Probe?) async throws -> DerivedLibrary {
        let store = self.store
        // Each input once (`factsForOverview`), and everything read before any pass starts: once
        // they run, nothing throws, so no pass is left running when a read fails.
        let read = try await factsForOverview()
        let inventory = read.inventory, facts = read.facts, contents = read.contents
        let stored = try await store.overrides()
        let overrides = OverrideSet(stored)
        // The analysed photos still without their image labels ("Themen" or "Dokumente" turned
        // on since): only while one of the two is on, and only those photos.
        let labels = try await AnalysisPipeline.photosWaitingForLabels(in: store, settings: settings)
        // Side by side, with the priorities they had in the app: what the overview shows at once
        // user-initiated, the albums that overlap (only the "Alben" tab) as utility work until
        // they are awaited last (awaiting a task raises its priority to the waiting one's).
        let status = Self.pass(.status, .userInitiated, probe) {
            DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides,
                                        contents: contents, labelsMissing: labels.missing, labelsRetrying: labels.retrying,
                                        managed: managed, inventory: inventory, scope: scope)
        }
        let ranks = Self.pass(.previewRanks, .userInitiated, probe) { PreviewRank.ranks(of: facts) }
        let firstDraw = Self.pass(.firstDraw, .userInitiated, probe) {
            let atlas = TravelAtlas.compute(facts: facts, year: nil)
            return (DerivedLibrary.creationDates(of: facts), atlas, TravelAtlas.years(facts: facts),
                    DerivedLibrary.yearAtlases(of: facts, allYears: atlas))
        }
        let byID = Self.pass(.factsByID, .userInitiated, probe) { FactsByID(facts) }
        let homeName = Self.pass(.homeName, .userInitiated, probe) { home.flatMap { HomeName.components(near: $0, facts: facts) } }
        let merges = Self.pass(.merges, .utility, probe) { AlbumOverlapAnalyzer().suggestions(in: inventory, excluding: ownAlbums) }
        var result = DerivedLibrary()
        result.facts = facts
        result.inventory = inventory
        result.removed = DerivedLibrary.removedFromProposals(stored)
        result.status = await status.value
        result.previewRanks = await ranks.value
        (result.creationDates, result.atlas, result.atlasYears, result.yearAtlases) = await firstDraw.value
        result.factsByID = await byID.value
        result.homeName = await homeName.value
        result.merges = await merges.value
        return result
    }

    /// One pass over the whole library, started off any actor with its own priority (`derivedLibrary`
    /// awaits each one).
    private nonisolated static func pass<T: Sendable>(_ piece: DerivedLibrary.Piece, _ priority: TaskPriority,
                                                      _ probe: DerivedLibrary.Probe?,
                                                      _ work: @escaping @Sendable () -> T) -> Task<T, Never> {
        Task.detached(priority: priority) {
            await probe?(piece, false)
            let value = work()
            await probe?(piece, true)
            return value
        }
    }
}

/// Everything one `AppModel.refreshDerived` call shows, read and worked out off the main actor in
/// one call (`AnalysisPipeline.derivedRefresh`), so the app assigns all of it together, and only
/// when the call is still the newest (`LatestCall`). Reviews G4-03 and P4-10: the suggestions, the
/// facts, the inventory, the history and the rest were assigned as each was read, and only the
/// last assignment asked whether the call was the newest; two overlapping calls that ended in
/// swapped order left an older call's facts next to the newer call's states.
public struct DerivedRefresh: Sendable {
    /// The suggestions with their matches (`refreshMatchesIfOutdated`).
    public var snapshot: ProposalSnapshot?
    /// Suggestions matched again under newer rules ("Neu geprüft").
    public var rechecked = 0
    public var recurringReport: RecurringPlaceReport?
    public var detectedHome: DetectedHome?
    /// The detected home with its name from the user's own photos (`HomeName.components`, a
    /// pass over all photos): made here with the facts, not on the main thread when "Dein
    /// Zuhause" or the settings draw (review P4-09).
    public var detectedHomePlace: HomePlace?
    public var homeNotice: HomeChangeNotice?
    /// The newest plans the history shows (no undo plans), and whether there are more than `historyLimit`.
    public var history: [ChangePlan] = []
    public var historyHasMore = false
    /// The plans taken back.
    public var undone: Set<SortlyID> = []
    /// Everything made from the whole library (`DerivedLibrary`).
    public var library = DerivedLibrary()

    public init() {}

    /// What a call applies at once, whether or not it is still the newest when it ends: the
    /// decisions opened again after a recheck (the store gives them out once) and the plans taken
    /// back (settled with the free albums before the library is read, so a read that fails there
    /// does not skip it).
    public struct Once: Sendable {
        public var reopened: @Sendable (Set<SortlyID>) async -> Void
        public var undone: @Sendable (Set<SortlyID>) async -> Void

        public init(reopened: @escaping @Sendable (Set<SortlyID>) async -> Void,
                    undone: @escaping @Sendable (Set<SortlyID>) async -> Void) {
            self.reopened = reopened
            self.undone = undone
        }

        public static let nothing = Once(reopened: { _ in }, undone: { _ in })
    }
}

extension AnalysisPipeline {
    /// Everything the overview shows (`DerivedRefresh`), in the order `AppModel.refreshDerived`
    /// read it: the matches first (results of an older matching version are matched again
    /// once), then the small values, the plans, and everything made from the whole library.
    /// `managed`: Albumist's own albums as the app knows them (after its album check); their ids
    /// are left out of the albums that overlap (a country holds its trips on purpose).
    public nonisolated func derivedRefresh(settings: OrganizationSettings, managed: [ManagedAlbumState], scope: OrganizationScope,
                                           historyLimit: Int, once: DerivedRefresh.Once) async throws -> DerivedRefresh {
        try await derivedRefresh(settings: settings, managed: managed, scope: scope, historyLimit: historyLimit, once: once, probe: nil)
    }

    nonisolated func derivedRefresh(settings: OrganizationSettings, managed: [ManagedAlbumState], scope: OrganizationScope,
                                    historyLimit: Int, once: DerivedRefresh.Once,
                                    probe: DerivedLibrary.Probe?) async throws -> DerivedRefresh {
        let store = self.store
        var result = DerivedRefresh()
        let refresh = try await refreshMatchesIfOutdated()
        await once.reopened(refresh.reopened)
        result.snapshot = refresh.snapshot
        result.rechecked = try await store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) ?? 0
        result.recurringReport = try await recurringPlaceReport()
        result.detectedHome = try await detectedHome()
        result.homeNotice = try await homeChangeNotice()
        let plans = try await store.planHistory(limit: historyLimit + 1)
        result.historyHasMore = plans.count > historyLimit
        result.history = plans.prefix(historyLimit).filter { $0.reverts == nil }
        result.undone = try await store.undoneTargets()
        await once.undone(result.undone)
        let home = result.detectedHome?.center
        result.library = try await derivedLibrary(snapshot: refresh.snapshot, settings: settings, managed: managed, scope: scope,
                                                  ownAlbums: Set(managed.map(\.albumID)), home: home, probe: probe)
        let name = result.library.homeName
        result.detectedHomePlace = home.map { HomePlace(center: $0, components: name) }
        return result
    }
}
