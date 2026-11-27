import Foundation
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// App-speed (18.11.2026): "Ignorieren" and "Nicht mehr ignorieren" are shown at once
/// (`IgnoreChange`), the recount follows in the background. UI runs measured 1.2 to 1.3 s
/// before the note appeared. What is shown at once must be what the recount gives, and a count
/// that started before the tap was stored must not put the photo back.
@Suite("Ignore shown at once")
struct IgnoreChangeTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Library {
        let facts: [AssetFacts]
        let snapshot: ProposalSnapshot?
        let contents: [AssetID: ContentAnalysis]
        let settings: OrganizationSettings

        /// What a count gives with these overrides (`AppModel.refreshDerived`).
        func count(_ overrides: [UserOverride]) -> DerivedLibraryStatus {
            DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: settings, overrides: OverrideSet(overrides),
                                        contents: contents, managed: [], inventory: CollectionInventory(), scope: .all)
        }
    }

    /// Munich every day, a week in Rome, analysed.
    func library() async throws -> Library {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        _ = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let store = try AlbumistStore(url: nil)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(),
            map: Self.map, conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        return Library(facts: try await pipeline.currentFacts(), snapshot: try await pipeline.latestProposals(),
                       contents: try await store.results(ContentAnalysis.self, kind: "content"), settings: OrganizationSettings())
    }

    func ignore(_ ids: [AssetID]) -> [UserOverride] { ids.map { UserOverride(scope: .asset($0), decision: .ignoreAsset) } }

    /// Photos of different kinds: from the Rome trip (with a suggestion) and from home.
    func picks(_ lib: Library, _ derived: DerivedLibraryStatus) -> [AssetID] {
        let resolver = OrganizationStatusResolver(primaryAreas: lib.settings.primaryAreas)
        let suggested = lib.facts.first { derived.states[$0.id].map { resolver.buckets($0).contains(.suggestions) } ?? false }
        let outside = lib.facts.first { derived.states[$0.id].map(resolver.isOutsideMainAreas) ?? false }
        let other = lib.facts.last
        return [suggested?.id, outside?.id, other?.id].compactMap { $0 }
    }

    @Test func ignoringShowsWhatTheRecountGives() async throws {
        let lib = try await library()
        let before = lib.count([])
        let picked = picks(lib, before)
        #expect(picked.count == 3)
        var shown = IgnoreChange.Shown(before)
        var changes = IgnoreChange()
        changes.record(picked, ignore: true, in: &shown)
        let after = lib.count(ignore(picked))
        #expect(shown == IgnoreChange.Shown(after))
        // The numbers that follow from the states agree too: nothing moves when the count comes.
        let resolver = OrganizationStatusResolver(primaryAreas: lib.settings.primaryAreas)
        #expect(resolver.progress(shown.states.values) == after.progress)
        #expect(resolver.progress(shown.states.values).ignored == 3)
    }

    @Test func unignoringShowsWhatTheRecountGives() async throws {
        let lib = try await library()
        let picked = picks(lib, lib.count([]))
        // Ignored in an earlier session: only the count knows their states without the ignore.
        var shown = IgnoreChange.Shown(lib.count(ignore(picked)))
        var changes = IgnoreChange()
        changes.record([picked[0], picked[2]], ignore: false, in: &shown)
        #expect(shown == IgnoreChange.Shown(lib.count(ignore([picked[1]]))))
        changes.record([picked[1]], ignore: false, in: &shown)
        #expect(shown == IgnoreChange.Shown(lib.count([])))
    }

    /// "Widerrufen" right after "Ignorieren", before any count: everything as before.
    @Test func widerrufenBeforeTheCountRestoresEverything() async throws {
        let lib = try await library()
        let before = IgnoreChange.Shown(lib.count([]))
        let picked = picks(lib, lib.count([]))
        var shown = before
        var changes = IgnoreChange()
        changes.record(picked, ignore: true, in: &shown)
        changes.record(picked, ignore: false, in: &shown)
        #expect(shown == before)
    }

    /// An excluded photo stays excluded when it is ignored and when it is no longer ignored.
    @Test func excludedPhotoStaysExcluded() async throws {
        let lib = try await library()
        let id = lib.facts[3].id
        let excluded = [UserOverride(scope: .asset(id), decision: .excludeFromAnalysis)]
        var shown = IgnoreChange.Shown(lib.count(excluded))
        var changes = IgnoreChange()
        changes.record([id], ignore: true, in: &shown)
        #expect(shown == IgnoreChange.Shown(lib.count(excluded + ignore([id]))))
        changes.record([id], ignore: false, in: &shown)
        #expect(shown == IgnoreChange.Shown(lib.count(excluded)))
    }

    /// With no main area counted, or with every area off (the states have no area then),
    /// "Ignorieren" still puts the photo into "Ignoriert" at once, as the recount does, and
    /// "Nicht mehr ignorieren" takes it back out (finding N-01: such a photo was "Nicht sortiert"
    /// whether ignored or not).
    @Test(arguments: [false, true])
    func ignoringWithNoCountedAreaShowsWhatTheRecountGives(everyAreaOff: Bool) async throws {
        let analysed = try await library()
        var settings = analysed.settings
        if everyAreaOff { settings.enabledAreas = [] } else { settings.primaryAreas = [] }
        let lib = Library(facts: analysed.facts, snapshot: analysed.snapshot, contents: analysed.contents, settings: settings)
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        let picked = [lib.facts[0].id, lib.facts[lib.facts.count / 2].id, lib.facts[lib.facts.count - 1].id]
        let before = IgnoreChange.Shown(lib.count([]))
        if everyAreaOff { #expect(before.states.values.allSatisfy { $0.areas.isEmpty }) }
        var shown = before
        var changes = IgnoreChange()
        changes.record(picked, ignore: true, in: &shown)
        let after = lib.count(ignore(picked))
        #expect(shown == IgnoreChange.Shown(after))
        for id in picked {
            let state = try #require(shown.states[id])
            #expect(resolver.overall(state) == .ignored && resolver.ringPart(state) == .ignored, "\(id)")
        }
        #expect(resolver.progress(shown.states.values) == after.progress)
        #expect(after.progress.total == 0 && after.progress.ignored == 3, "\(after.progress)")
        #expect(after.progress.outsideMainAreas == lib.facts.count - 3, "\(after.progress)")
        changes.record(picked, ignore: false, in: &shown)
        #expect(shown == before)
    }

    /// A count that began before the tap was stored read the overrides without it. Laid over
    /// it, the photo stays where the tap put it; a count that includes the tap ends it.
    @Test func olderCountDoesNotPutThePhotoBack() async throws {
        let lib = try await library()
        let picked = picks(lib, lib.count([]))
        let ignoredShown = IgnoreChange.Shown(lib.count(ignore(picked)))
        var shown = IgnoreChange.Shown(lib.count([]))
        var changes = IgnoreChange()
        let step = changes.record(picked, ignore: true, in: &shown)
        // Count 4 began before the store had the tap (it is still being written).
        var stale = IgnoreChange.Shown(lib.count([]))
        changes.settle(&stale, call: 4)
        #expect(stale == ignoredShown)
        // Stored now: counts from 5 on read it. Count 4 arriving late still gets the tap.
        changes.stored(step, nextCall: 5)
        var late = IgnoreChange.Shown(lib.count([]))
        changes.settle(&late, call: 4)
        #expect(late == ignoredShown)
        #expect(changes.pending == 1)
        var current = IgnoreChange.Shown(lib.count(ignore(picked)))
        changes.settle(&current, call: 5)
        #expect(current == ignoredShown)
        #expect(changes.pending == 0)
    }

    /// The store did not take the tap: the next count shows the photos as they are.
    /// "Ignorieren", stored; then "Widerrufen" still being written, while one recount runs for
    /// both (the app counts once the writes are done, not after each, second review 1). A count
    /// that read only the first tap shows the photos as not ignored all the same, and the count
    /// after the second write ends both.
    @Test func countWithTheFirstTapOnlyKeepsTheSecond() async throws {
        let lib = try await library()
        let picked = picks(lib, lib.count([]))
        let notIgnored = IgnoreChange.Shown(lib.count([]))
        var shown = notIgnored
        var changes = IgnoreChange()
        let first = changes.record(picked, ignore: true, in: &shown)
        changes.stored(first, nextCall: 3)
        let second = changes.record(picked, ignore: false, in: &shown)
        #expect(shown == notIgnored)
        // Count 3 read the ignore but not the undo, which is still on its way.
        var three = IgnoreChange.Shown(lib.count(ignore(picked)))
        changes.settle(&three, call: 3)
        #expect(three == notIgnored)
        #expect(changes.pending == 1)
        // The undo is stored; the count after it ends it.
        changes.stored(second, nextCall: 4)
        var four = IgnoreChange.Shown(lib.count([]))
        changes.settle(&four, call: 4)
        #expect(four == notIgnored)
        #expect(changes.pending == 0)
    }

    @Test func failedWriteIsNotLaidOverTheCount() async throws {
        let lib = try await library()
        let picked = picks(lib, lib.count([]))
        var shown = IgnoreChange.Shown(lib.count([]))
        var changes = IgnoreChange()
        let step = changes.record(picked, ignore: true, in: &shown)
        changes.failed(step)
        var next = IgnoreChange.Shown(lib.count([]))
        changes.settle(&next, call: 2)
        #expect(next == IgnoreChange.Shown(lib.count([])))
    }

    /// The note says what the store will add, so "Widerrufen" takes back exactly that.
    @Test func newlyIgnoredMatchesTheStore() async throws {
        let store = try AlbumistStore(url: nil)
        try await store.ignoreAssets(["a"])
        let local = IgnoreChange.newlyIgnored(["a", "b", "b", "c"], ignored: ["a"])
        #expect(local == ["b", "c"])
        #expect(try await store.ignoreAssets(["a", "b", "b", "c"]) == local)
    }
}
