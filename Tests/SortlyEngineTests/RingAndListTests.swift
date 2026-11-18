import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// The ring and the library's lists after a real analysis, counted the way
/// `AppModel.refreshDerived` and `AppModel.makeLibraryBuckets` count (decisions Fuchs 18.11.:
/// ignored photos do not count in the ring, and "Sortiert" shows the ring's number; Fable review
/// P1-05 and P1-06, whose library this is).
@Suite("Ring and lists after an analysis")
struct RingAndListTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    static let basel = GeoCoordinate(latitude: 47.5596, longitude: 7.5886)
    static let today = Fixture.date("2026-11-18 06:00")

    struct World {
        var store: SortlyStore
        var pipeline: AnalysisPipeline
        var settings: OrganizationSettings
        var home: [AssetID]
        var rome: [AssetID]
        var basel: [AssetID]
        /// Photos of 2025 in the user's own album "Toskana" (a trip of that year).
        var tuscany: [AssetID]

        func derived(scope: OrganizationScope = .all) async throws -> DerivedLibraryStatus {
            DerivedLibraryStatus.derive(
                facts: try await pipeline.currentFacts(), snapshot: try await pipeline.latestProposals(), settings: settings,
                overrides: OverrideSet(try await store.overrides()),
                contents: try await store.results(ContentAnalysis.self, kind: "content"),
                managed: [], inventory: try await store.loadInventory(), scope: scope, calendar: Fixture.calendar)
        }

        func ignore(_ ids: [AssetID]) async throws {
            for id in ids { try await store.addOverride(UserOverride(scope: .asset(id), decision: .ignoreAsset)) }
        }
    }

    /// Munich every day; a week in Rome (the user's album "Rom" holds all of it); six days in
    /// Basel (no album yet); with `withTuscany` also a trip to Florence in 2025, in the user's
    /// album "Toskana".
    func world(withTuscany: Bool = false, scope: OrganizationScope = .all) async throws -> World {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                             skipping: [("2026-05-12", "2026-05-19"), ("2026-03-10", "2026-03-15")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let basel = lib.daily(from: "2026-03-10", to: "2026-03-15", at: Self.basel, perDay: 3, hour: 11)
        var tuscany: [AssetID] = []
        var albums = [CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(rome))]
        if withTuscany {
            _ = lib.daily(from: "2025-09-01", to: "2025-09-30", at: Fixture.Places.munichHome, perDay: 1,
                          skipping: [("2025-09-10", "2025-09-15")])
            tuscany = lib.daily(from: "2025-09-10", to: "2025-09-15", at: Fixture.Places.florence, perDay: 4, hour: 10)
            albums.append(CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: Set(tuscany)))
        }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets, inventory: CollectionInventory(albums)),
            analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(),
            settings: settings, calendar: Fixture.calendar, time: ManualTime().source, now: { Self.today }
        )
        #expect(try await pipeline.run(scope: scope).isComplete)
        return World(store: store, pipeline: pipeline, settings: settings, home: home, rome: rome, basel: basel, tuscany: tuscany)
    }

    /// The lists of the library tab for these states, as the app makes them.
    func lists(_ w: World, _ d: DerivedLibraryStatus, scope: OrganizationScope = .all) async throws -> LibraryBuckets {
        let resolver = OrganizationStatusResolver(primaryAreas: w.settings.primaryAreas)
        return try #require(LibraryBuckets.make(facts: try await w.pipeline.currentFacts(), states: d.states, resolver: resolver,
                                                scope: scope, calendar: Fixture.calendar))
    }

    static func line(_ p: OrganizationStatusResolver.Progress) -> String {
        "\(p.fully) von \(p.total) sortiert, teilweise \(p.partially), offen \(p.unorganized + p.pending), ignoriert \(p.ignored), nicht mitgezählt \(p.outsideMainAreas)"
    }

    /// Fable P1-05: ignoring ten photos from home made "32 von 50" into "32 von 60", and with
    /// every open photo ignored the ring stayed at 53 %.
    @Test func ignoringPhotosDoesNotMakeTheRingWorseAndItReachesOneHundredPercent() async throws {
        let w = try await world()
        let before = try await w.derived().progress
        #expect(before.fully == w.rome.count && before.total == w.rome.count + w.basel.count, "\(Self.line(before))")
        try await w.ignore(Array(w.home.prefix(10)))
        let afterHome = try await w.derived().progress
        #expect(afterHome.total == before.total, "\(Self.line(afterHome))")
        #expect(afterHome.fullyShare >= before.fullyShare)
        #expect(afterHome.ignored == 10)
        try await w.ignore(w.basel)
        let afterTrip = try await w.derived().progress
        #expect(afterTrip.fully == w.rome.count && afterTrip.total == w.rome.count, "\(Self.line(afterTrip))")
        #expect(afterTrip.fullyShare == 1)
        #expect(afterTrip.ignored == 10 + w.basel.count)
        #expect(afterTrip.allPhotos == before.allPhotos)
    }

    /// Fable P1-06: the ring said "32 von 50", the list "Sortiert" held 199 photos, most of them
    /// from home. Also with photos ignored, and after they are brought back.
    @Test func listSortedShowsTheSameNumberAsTheRing() async throws {
        let w = try await world()
        func check(_ step: String) async throws {
            let d = try await w.derived()
            let lists = try await lists(w, d)
            #expect(lists[.organized].count == d.progress.fully, "\(step): Sortiert \(lists[.organized].count), Ring \(Self.line(d.progress))")
            #expect(lists[.unorganized].count == d.progress.total - d.progress.fully, "\(step)")
            #expect(lists[.ignored].count == d.progress.ignored, "\(step)")
            #expect(Set(lists[.organized].map(\.id)).isDisjoint(with: w.home), "\(step): a photo from home in Sortiert")
        }
        try await check("first count")
        try await w.ignore([w.rome[0], w.basel[0], w.home[0]])
        try await check("three ignored")
        _ = try await w.store.unignoreAssets([w.rome[0], w.basel[0], w.home[0]])
        try await check("brought back")
    }

    /// "Nur 2026": the ring counts the photos of 2026 only, and so does "Sortiert". The 2025
    /// trip in the user's own album is sorted, but not part of this ring.
    @Test func listSortedFollowsTheChosenPartOfTheLibrary() async throws {
        let w = try await world(withTuscany: true, scope: .year(2026))
        let year = try await w.derived(scope: .year(2026))
        let yearLists = try await lists(w, year, scope: .year(2026))
        #expect(yearLists[.organized].count == year.progress.fully, "Sortiert \(yearLists[.organized].count), Ring \(Self.line(year.progress))")
        #expect(yearLists[.unorganized].count == year.progress.total - year.progress.fully)
        #expect(Set(yearLists[.organized].map(\.id)).isDisjoint(with: w.tuscany))
        #expect(yearLists[.all].count == (try await w.pipeline.currentFacts()).count)
        // The whole library: the same rule over every photo.
        let all = try await w.derived(scope: .all)
        let allLists = try await lists(w, all)
        #expect(allLists[.organized].count == all.progress.fully)
        #expect(allLists[.unorganized].count == all.progress.total - all.progress.fully)
    }

    /// "Ignorieren", then "Widerrufen" or "Nicht mehr ignorieren", shown at once
    /// (`IgnoreChange`): the ring that follows from what is shown and the lists are those of the
    /// recount, and back where they were once the photos are no longer ignored.
    @Test func ignoreAndUnignoreKeepRingAndListsTogether() async throws {
        let w = try await world()
        let resolver = OrganizationStatusResolver(primaryAreas: w.settings.primaryAreas)
        let facts = try await w.pipeline.currentFacts()
        let first = try await w.derived()
        let firstLists = try await lists(w, first)
        let picked = [w.rome[1], w.basel[1], w.home[1]]
        var shown = IgnoreChange.Shown(first)
        var changes = IgnoreChange()
        changes.record(picked, ignore: true, in: &shown)
        try await w.ignore(picked)
        let recount = try await w.derived()
        #expect(resolver.progress(shown.states.values) == recount.progress)
        let moved = firstLists.updating(picked, to: shown.states, resolver: resolver)
        #expect(moved[.organized].count == recount.progress.fully)
        #expect(moved[.ignored].count == 3)
        #expect(moved == (try await lists(w, recount)))
        // Back again.
        changes.record(picked, ignore: false, in: &shown)
        _ = try await w.store.unignoreAssets(picked)
        let again = try await w.derived()
        #expect(resolver.progress(shown.states.values) == first.progress)
        #expect(again.progress == first.progress)
        #expect(moved.updating(picked, to: shown.states, resolver: resolver) == firstLists)
        #expect(LibraryBuckets.make(facts: facts, states: shown.states, resolver: resolver) == firstLists)
    }
}
