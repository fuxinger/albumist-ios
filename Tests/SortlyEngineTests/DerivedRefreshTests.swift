import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Review P4-02: `AppModel.refreshDerived` read the whole library at every call, the image
/// results of every photo twice (once for the facts, once for the ring) and the album list twice,
/// and the start of the app waited for it, with each whole-library pass (preview ranks, albums
/// that overlap, the ring) run one after the other. It is one call into the engine now
/// (`AnalysisPipeline.derivedLibrary`): every input is read once, and the passes run side by side.
@Suite("Refresh of the overview: each read once, passes side by side")
struct DerivedRefreshTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Library {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var settings: OrganizationSettings
        var rome: [AssetID]

        /// A pipeline on the same database, as the app makes one at each launch.
        func launch() -> AnalysisPipeline {
            AnalysisPipeline(store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: DerivedRefreshTests.map,
                             conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source)
        }
    }

    /// An analysed library with "Themen" on: Munich every day and a week in Rome, three albums of
    /// Rome that overlap (Albumist's own "Rom" left out, the other two a merge suggestion), a
    /// photo ignored, one taken out of a suggestion, two not readable yet, three still without
    /// their image labels (one of them tried before).
    func analysed() async throws -> Library {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let inventory = CollectionInventory([
            CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(rome)),
            CollectionSnapshot(id: "rom-2026", title: "Rom 2026", assetIDs: Set(rome.dropLast(2))),
            CollectionSnapshot(id: "rom-ausflug", title: "Ausflug Rom", assetIDs: Set(rome.dropFirst(2))),
        ])
        let store = try SortlyStore(url: nil)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.enabledAreas.insert(.imageCategories)
        let library = Library(store: store, reader: InMemoryLibraryReader(assets: lib.assets, inventory: inventory), settings: settings, rome: rome)
        _ = try await library.launch().run()
        try await store.addOverride(UserOverride(scope: .asset(rome[0]), decision: .ignoreAsset))
        if let suggestion = try await library.launch().latestProposals()?.proposals.first, let photo = suggestion.assetIDs.sorted().first {
            try await store.addOverride(UserOverride(scope: .assetInSource(photo, suggestion.id), decision: .neverAdd))
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        for id in rome[1...2] {
            var failed = try #require(contents[id])
            failed.failedAttempts = 1
            try await store.saveResult(failed, kind: "content", asset: id, version: AnalysisPipeline.contentVersion)
        }
        try await store.saveResults([] as [(AssetID, ContentAnalysis)], kind: "content", version: AnalysisPipeline.contentVersion,
                                    markingAnalyzed: Array(rome[3...5]), labelsVersion: 0)
        try await store.saveResult(LabelAttempts(failedAttempts: 1, lastAttempt: Fixture.date("2026-06-30")), kind: "labels", asset: rome[3],
                                   version: AnalysisPipeline.contentVersion)
        return library
    }

    static func managed(_ snapshot: ProposalSnapshot?) -> [ManagedAlbumState] {
        guard let first = snapshot?.proposals.first else { return [] }
        return [ManagedAlbumState(albumID: "rom", sourceID: first.id, lastKnownTitle: "Rom", lastKnownParentID: nil,
                                  lastKnownMembers: first.assetIDs, addedBySortly: first.assetIDs, createdBySortly: true)]
    }

    /// What a refresh reads, as the app's `refreshDerived` asks for it: the matches first, then
    /// everything made from the whole library.
    func refresh(_ pipeline: AnalysisPipeline, _ library: Library, scope: OrganizationScope = .all,
                 probe: DerivedLibrary.Probe? = nil) async throws -> (DerivedLibrary, [String: Int]) {
        let before = await library.store.wholeLibraryReads
        let snapshot = try await pipeline.refreshMatchesIfOutdated().snapshot
        let derived = try await pipeline.derivedLibrary(snapshot: snapshot, settings: library.settings, managed: Self.managed(snapshot),
                                                        scope: scope, ownAlbums: ["rom"], probe: probe)
        let after = await library.store.wholeLibraryReads
        return (derived, after.reduce(into: [:]) { reads, entry in
            let count = entry.value - (before[entry.key] ?? 0)
            if count > 0 { reads[entry.key] = count }
        })
    }

    /// The reads that go over every photo: each once, at the first refresh after a launch (the
    /// zones of the places are not known yet) and at every later one.
    @Test func eachWholeLibraryReadRunsOncePerRefresh() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let once = ["allAssets": 1, "loadInventory": 1, "places": 1, "results.content": 1, "results.text": 1, "overrides": 1]
        let (_, atLaunch) = try await refresh(pipeline, library)
        #expect(atLaunch == once, "the first refresh after a launch reads \(atLaunch)")
        let (_, later) = try await refresh(pipeline, library)
        #expect(later == once, "a later refresh reads \(later)")
    }

    /// The ring (and so the first screen) does not wait for the albums that overlap: held, the
    /// other passes still end. Before, ranks, overlaps and the ring ran one after the other.
    @Test func theRingDoesNotWaitForTheOverlappingAlbums() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let ended = Mutex<Set<DerivedLibrary.Piece>>([])
        let held = Mutex(true)
        let probe: DerivedLibrary.Probe = { piece, end in
            if end { _ = ended.withLock { $0.insert(piece) } }
            if piece == .merges, !end {
                while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        async let result = refresh(pipeline, library, probe: probe)
        let deadline = ContinuousClock.now + .seconds(20)
        while !ended.withLock({ $0.contains(.status) && $0.contains(.previewRanks) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let whileHeld = ended.withLock { $0 }
        held.withLock { $0 = false }
        _ = try await result
        #expect(whileHeld.contains(.status), "the ring waited for the albums that overlap")
        #expect(whileHeld.contains(.previewRanks), "the preview ranks waited for the albums that overlap")
        #expect(!whileHeld.contains(.merges))
    }

    /// The same results as the code it replaces (`AppModel.refreshDerived` before: the facts, then
    /// each input read on its own and each pass on its own).
    @Test(arguments: [OrganizationScope.all, .year(2026)])
    func sameResultsAsBefore(scope: OrganizationScope) async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let (derived, _) = try await refresh(pipeline, library, scope: scope)

        let store = library.store
        let snapshot = try await pipeline.latestProposals()
        // From a pipeline of its own: the zones of the places the refresh worked out are not
        // reused (second review: a fault in handing them over cancelled out).
        let facts = try await library.launch().currentFacts()
        let inventory = try await store.loadInventory()
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let stored = try await store.overrides()
        var removed: [SortlyID: Set<AssetID>] = [:]
        for o in stored where o.decision == .neverAdd {
            if case .assetInSource(let asset, let source) = o.scope { removed[source, default: []].insert(asset) }
        }
        let labels = try await AnalysisPipeline.photosWaitingForLabels(in: store, settings: library.settings)
        let status = DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: library.settings, overrides: OverrideSet(stored),
                                                 contents: contents, labelsMissing: labels.missing, labelsRetrying: labels.retrying,
                                                 managed: Self.managed(snapshot), inventory: inventory, scope: scope)

        #expect(!facts.isEmpty && !(snapshot?.proposals.isEmpty ?? true))
        #expect(derived.facts == facts)
        #expect(derived.previewRanks == PreviewRank.ranks(of: facts))
        #expect(derived.inventory == inventory)
        let merges = AlbumOverlapAnalyzer().suggestions(in: inventory, excluding: ["rom"])
        #expect(merges.map(\.albumIDs) == [["rom-2026", "rom-ausflug"]])
        #expect(derived.merges == merges)
        #expect(!removed.isEmpty)
        #expect(derived.removed == removed)
        #expect(derived.status.states == status.states)
        #expect(derived.status.reasons == status.reasons)
        #expect(derived.status.progress == status.progress)
        #expect(derived.status.leftOut == status.leftOut)
        #expect(derived.status.photos == status.photos)
        #expect(derived.status.analyzed == status.analyzed)
        #expect(derived.status.unreadable == status.unreadable)
        #expect(status.unreadable == 2)
        #expect(derived.status.labelsMissing == status.labelsMissing)
        #expect(derived.status.labelsUntried == status.labelsUntried)
        #expect(status.labelsMissing == 3 && status.labelsUntried == 2)
        #expect(derived.status.ignored == status.ignored)
        #expect(!status.ignored.isEmpty)
        #expect(derived.status.ifNotIgnored == status.ifNotIgnored)
        // P4-09: what the first draw made on the main thread, made here with the same functions
        // (the app's former inline code for the capture dates).
        let dates = Dictionary(facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } }, uniquingKeysWith: { first, _ in first })
        #expect(!dates.isEmpty && derived.creationDates == dates)
        #expect(derived.atlas == TravelAtlas.compute(facts: facts, year: nil))
        #expect(derived.atlas.countryCodes.contains("IT"))
        #expect(derived.atlasYears == TravelAtlas.years(facts: facts))
    }
}

/// The app's side (it does not build on Linux, so its code is read, `AppSource`).
@Suite("Refresh of the overview: the app only assigns")
struct DerivedRefreshAppTests {
    static func refreshBody() throws -> String {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        return AppSource.code(try #require(AppSource.body(of: "func refreshDerived(", in: model)))
    }

    /// P4-02: the inputs made from the whole library are read by the engine, once each, not by the
    /// app next to it (the image results and the album list were read twice).
    @Test func refreshDerivedReadsNothingOfTheWholeLibraryItself() throws {
        let body = try Self.refreshBody()
        #expect(!AppSource.calls(of: "pipeline.derivedLibrary(", in: body).isEmpty, "refreshDerived does not ask the engine")
        for read in ["store.loadInventory(", "store.results(", "store.overrides(", "pipeline.currentFacts(", "store.allAssets("] {
            #expect(AppSource.calls(of: read, in: body).isEmpty, "refreshDerived reads \(read)) itself")
        }
    }

    /// P4-02: no pass over all photos is awaited one after the other in the app; the engine runs
    /// them side by side.
    @Test func refreshDerivedAwaitsNoPassOfItsOwn() throws {
        let body = try Self.refreshBody()
        #expect(AppSource.calls(of: "Task.detached(", in: body).isEmpty, "refreshDerived awaits passes over all photos one after the other")
    }

    /// P4-09: what the first screens make from all photos at their first draw after a refresh (the
    /// capture dates of the previews, the atlas of all years and its years) was made on the main
    /// thread there; the engine makes it off the main thread and the refresh hands it over with
    /// the facts (after them: a new value of the facts empties these caches).
    @Test func refreshDerivedHandsOverWhatTheFirstDrawMadeOnTheMainThread() throws {
        let body = try Self.refreshBody()
        let facts = try #require(body.range(of: "(?<![A-Za-z0-9_.])facts = ", options: .regularExpression), "refreshDerived assigns no facts")
        for cache in ["previewRanksCache = ", "datesCache = ", "atlasCache[0] = ", "atlasYearsCache = "] {
            let handed = body.range(of: cache).map { $0.lowerBound > facts.lowerBound } ?? false
            #expect(handed, "refreshDerived does not hand over \(cache)…: the first draw makes it on the main thread")
        }
    }

    /// P4-09, second review: the places "Dein Zuhause" offers (322 ms at 50,000 photos) are made
    /// only when that screen asks, off the main thread, and never at a refresh (battery).
    @Test func homePlacesAreMadeOffTheMainThreadOnlyWhenTheScreenAsks() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        let engine = AppSource.code(try AppSource.read("Sources/SortlyEngine/DerivedLibrary.swift"))
        #expect(AppSource.calls(of: "HomeCandidates.make(", in: engine).isEmpty, "every refresh makes the home places")
        let handed = try Self.refreshBody().contains("homeCandidatesCache =")
        #expect(!handed, "every refresh hands over the home places")
        let getter = AppSource.code(AppSource.body(of: "var homeCandidates: [HomeCandidate]?", in: model) ?? "")
        #expect(!getter.isEmpty && AppSource.calls(of: "HomeCandidates.make(", in: getter).isEmpty,
                "the screen makes the home places on the main thread")
        let make = AppSource.code(AppSource.body(of: "private func makeHomeCandidates(", in: model) ?? "")
        let offMain = !AppSource.calls(of: "Task.detached(", in: make).isEmpty && !AppSource.calls(of: "HomeCandidates.make(", in: make).isEmpty
        #expect(offMain, "the home places are not made off the main thread")
    }
}
