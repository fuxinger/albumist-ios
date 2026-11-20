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
        // P4-09, the rest: the atlas of every year (each made with `compute(facts:year:)` on the
        // main thread when it was chosen) and the facts by id (a dictionary made on the main
        // thread at the first lookup).
        let years = Set(facts.compactMap { f in f.asset.creationDate.map { Calendar.current.component(.year, from: $0) } })
        #expect(years.count >= 2)
        #expect(Set(derived.yearAtlases.keys) == years)
        for year in years.sorted() {
            #expect(derived.yearAtlases[year] == TravelAtlas.compute(facts: facts, year: year), "the atlas of \(year)")
        }
        #expect(derived.yearAtlases.values.contains { $0.newCountryCodes.contains("IT") })
        #expect(DerivedLibrary.emptyYearAtlas(1999) == TravelAtlas.compute(facts: facts, year: 1999))
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(derived.factsByID.count == byID.count)
        #expect(byID.allSatisfy { derived.factsByID[$0.key] == $0.value })
        #expect(derived.factsByID[AssetID("no-such-photo")] == nil)
    }

    /// The facts by id say what the dictionary they replace said: the first photo of an id wins,
    /// an unknown id has none.
    @Test func factsByIDKeepsTheFirstPhotoOfAnID() {
        func photo(_ id: String, trip: String) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: Fixture.date("2024-05-01")), tripID: SortlyID(trip))
        }
        let facts = [photo("p1", trip: "t1"), photo("p2", trip: "t2"), photo("p1", trip: "t3")]
        let byID = FactsByID(facts)
        #expect(byID.count == 2)
        #expect(byID[AssetID("p1")]?.tripID == SortlyID("t1"), "the first photo with an id no longer wins")
        #expect(byID[AssetID("p2")]?.tripID == SortlyID("t2"))
        #expect(byID[AssetID("p9")] == nil)
        #expect(FactsByID()[AssetID("p1")] == nil)
    }

    /// The whole package a refresh shows (`AnalysisPipeline.derivedRefresh`): what the app read
    /// one value after the other, and the detected home named from the facts.
    @Test func theRefreshPackageHasWhatTheAppReadItself() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let reopened = Mutex<[Set<SortlyID>]>([])
        let undone = Mutex<[Set<SortlyID>]>([])
        let once = DerivedRefresh.Once(reopened: { ids in reopened.withLock { $0.append(ids) } },
                                       undone: { ids in undone.withLock { $0.append(ids) } })
        let refreshed = try await pipeline.derivedRefresh(settings: library.settings, managed: [], scope: .all, historyLimit: 50, once: once)
        #expect(reopened.withLock { $0.count } == 1 && undone.withLock { $0.count } == 1, "a call skipped what it applies once")
        let store = library.store
        let snapshot = try await pipeline.latestProposals()
        let rechecked = try await store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) ?? 0
        let report = try await pipeline.recurringPlaceReport()
        let notice = try await pipeline.homeChangeNotice()
        let plans = try await store.planHistory(limit: 51)
        let undoneTargets = try await store.undoneTargets()
        let detected = try await pipeline.detectedHome()
        let facts = try await library.launch().currentFacts()
        #expect(refreshed.snapshot == snapshot)
        #expect(refreshed.rechecked == rechecked)
        #expect(refreshed.recurringReport == report)
        #expect(refreshed.homeNotice == notice)
        #expect(refreshed.historyHasMore == (plans.count > 50))
        #expect(refreshed.history == plans.prefix(50).filter { $0.reverts == nil })
        #expect(refreshed.undone == undoneTargets)
        let home = try #require(detected, "the library has no detected home")
        #expect(refreshed.detectedHome == home)
        let named = HomePlace(center: home.center, components: HomeName.components(near: home.center, facts: refreshed.library.facts))
        #expect(named.components != nil)
        #expect(refreshed.detectedHomePlace == named)
        #expect(refreshed.library.facts == facts)
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
        #expect(!AppSource.calls(of: "pipeline.derivedRefresh(", in: body).isEmpty, "refreshDerived does not ask the engine")
        // Review P4-10: everything else it shows comes in the same package, not read beside it.
        for read in ["store.loadInventory(", "store.results(", "store.overrides(", "pipeline.currentFacts(", "store.allAssets(",
                     "pipeline.derivedLibrary(", "store.planHistory(", "store.undoneTargets(", "store.value(",
                     "pipeline.recurringPlaceReport(", "pipeline.detectedHome(", "pipeline.homeChangeNotice(",
                     "pipeline.refreshMatchesIfOutdated("] {
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
        for cache in ["previewRanksCache = ", "datesCache = ", "atlasCache = derived.yearAtlases", "atlasCache[0] = ", "atlasYearsCache = ",
                      "factsIndex = ", "detectedHomePlaceCache = "] {
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

    /// The passes over all photos that ran on the main actor when a screen asked (review P4-09:
    /// the places of "Dein Zuhause", the facts by id at the first lookup, the atlas of a year,
    /// the statuses of a search, the start of a stay when a home is picked, the name of the
    /// detected home): wherever the app or "Dein Zuhause" still makes one, it is inside a
    /// `Task.detached` closure; the rest comes made with the facts (`DerivedLibrary`).
    static let passesOverAllPhotos = ["HomeCandidates.make(", "HomeCandidates.stayStart(", "HomeName.components(", "TravelAtlas.compute(",
                                      "TravelAtlas.years(", "DerivedLibrary.yearAtlases(", "LibraryStatus.searchStatuses(",
                                      "LibraryBuckets.make(", "FactsByID(", "Dictionary(", ".mapValues("]

    @Test func passesOverAllPhotosRunOffTheMainActor() throws {
        var found = 0
        for path in ["App/Sortly/Model/AppModel.swift", "App/Sortly/Views/HomeSettingsView.swift"] {
            let source = try AppSource.read(path)
            let length = AppSource.code(source).unicodeScalars.count
            let detached = AppSource.callSites(of: "Task.detached(", in: source).compactMap { site in
                AppSource.bodyRange(of: "Task.detached(", in: source, within: site.offset..<length)
            }
            for pass in Self.passesOverAllPhotos {
                for site in AppSource.callSites(of: pass, in: source) {
                    // `FactsByID()`: no facts, nothing to go over.
                    if pass == "FactsByID(", site.arguments.isEmpty { continue }
                    // A dictionary or a mapping of something other than all photos (a few albums, a value).
                    if pass == "Dictionary(" || pass == ".mapValues(" {
                        let line = source.unicodeScalars.count > site.offset ? Self.line(at: site.offset, in: source) : ""
                        guard line.contains("facts") || line.contains("states") else { continue }
                    }
                    found += 1
                    let off = detached.contains { $0.contains(site.offset) }
                    #expect(off, "\(path): \(pass)\(site.arguments)) runs on the main actor: \(Self.line(at: site.offset, in: source))")
                }
            }
        }
        // The ones still made in the app: the home places, the start of a stay, the library tab's
        // areas and the statuses of a search.
        #expect(found >= 4, "the scan found only \(found) passes")
    }

    /// The line of `source` at a position in Unicode scalars, trimmed.
    static func line(at offset: Int, in source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var start = min(offset, scalars.count), end = start
        while start > 0, scalars[start - 1] != "\n" { start -= 1 }
        while end < scalars.count, scalars[end] != "\n" { end += 1 }
        return String(String.UnicodeScalarView(scalars[start..<end])).trimmingCharacters(in: .whitespaces)
    }

    /// What the refresh hands over (the facts by id, the atlas of each year, the name of the
    /// detected home) is there whenever facts are: the facts and the detected home are assigned
    /// in `refreshDerived` only, together with them. The getters make nothing themselves.
    @Test func factsAndTheDetectedHomeAreAssignedOnlyWithWhatIsMadeFromThem() throws {
        let model = AppSource.code(try AppSource.read("App/Sortly/Model/AppModel.swift"))
        let refresh = try Self.refreshBody()
        for name in ["facts", "detectedHome"] {
            let pattern = try Regex("(?m)^\\s*(self\\.)?\(name)\\s*=[^=]")
            let everywhere = model.matches(of: pattern).count
            let inRefresh = refresh.matches(of: pattern).count
            #expect(everywhere == 1 && inRefresh == 1, "\(name) is assigned \(everywhere) times, \(inRefresh) of them in refreshDerived")
        }
        for getter in ["func travelAtlas(year: Int? = nil) -> TravelAtlas", "var atlasYears: [Int]", "var factsByID: FactsByID",
                       "var detectedHomePlace: HomePlace?"] {
            let body = AppSource.code(AppSource.body(of: getter, in: model) ?? "")
            #expect(!body.isEmpty, "no \(getter)")
            let makes = Self.passesOverAllPhotos.contains { !AppSource.calls(of: $0, in: body).filter { !$0.isEmpty }.isEmpty }
            #expect(!makes, "\(getter) goes over all photos on the main thread")
        }
    }
}
