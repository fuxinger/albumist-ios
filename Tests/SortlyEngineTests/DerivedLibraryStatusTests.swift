import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Review of d612bc0 (4): `refreshDerived` did O(photos) work on the main actor (sets of the
/// analysed photos, the ring's progress, what it leaves out, the trial year's filter). It is
/// one detached call now (`DerivedLibraryStatus.derive`); the app only assigns the result.
@Suite("Derived library status (off the main actor)")
struct DerivedLibraryStatusTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    /// A small analysed library: Munich every day and a week in Rome.
    func analysed() async throws -> (facts: [AssetFacts], snapshot: ProposalSnapshot?, contents: [AssetID: ContentAnalysis]) {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        _ = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let store = try SortlyStore(url: nil)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(),
            map: Self.map, conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        var contents = try await store.results(ContentAnalysis.self, kind: "content")
        // Two photos could not be read yet: not counted as analysed.
        for id in contents.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(2) {
            contents[id]?.failedAttempts = 1
        }
        return (try await pipeline.currentFacts(), try await pipeline.latestProposals(), contents)
    }

    /// The same numbers as the code it replaces (AppModel before: inline on the main actor).
    @Test(arguments: [OrganizationScope.all, .year(2026)])
    func sameAsBefore(scope: OrganizationScope) async throws {
        let (facts, snapshot, contents) = try await analysed()
        let settings = OrganizationSettings()
        let derived = DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: settings, overrides: OverrideSet(),
                                                  contents: contents, managed: [], inventory: CollectionInventory(), scope: scope)
        // The former inline code.
        let analyzed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
        let unreadable = Set(contents.filter { $0.value.failedAttempts != nil }.keys)
        let (computed, reasons) = LibraryStatus.computeWithReasons(facts: facts, snapshot: snapshot, settings: settings,
                                                                   contentAnalyzed: analyzed)
        let calendar = Calendar.sortlyDefault
        let inScope = scope == .all ? facts : facts.filter { scope.includes($0, calendar: calendar) }
        let scopedIDs = Set(inScope.map(\.id))
        let counted = scope == .all ? Array(computed.values) : computed.filter { scopedIDs.contains($0.key) }.map(\.value)
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        #expect(derived.states == computed)
        #expect(derived.progress == resolver.progress(counted))
        #expect(derived.leftOut == LibraryStatus.leftOut(counted, reasons: reasons, resolver: resolver))
        #expect(derived.photos == inScope.count)
        #expect(derived.analyzed == (scope == .all ? analyzed.count : analyzed.intersection(scopedIDs).count))
        #expect(derived.unreadable == (scope == .all ? unreadable.count : unreadable.intersection(scopedIDs).count))
        if scope == .all { #expect(derived.unreadable == 2) }
        if scope != .all { #expect(derived.photos < facts.count) }
    }

    /// Review of 9f0bc40 (B): two refreshes overlap; the older one finishes last. Only the
    /// newest assigns its result, as AppModel.refreshDerived does with `LatestCall`.
    @Test func olderRefreshFinishingLastDoesNotWin() async {
        actor Model {
            var calls = LatestCall()
            var shown = ""
            func refresh(_ value: String, takes: Duration) async {
                let call = calls.begin()
                try? await Task.sleep(for: takes)
                guard calls.isNewest(call) else { return }
                shown = value
            }
        }
        let model = Model()
        async let older: Void = model.refresh("older", takes: .milliseconds(300))
        try? await Task.sleep(for: .milliseconds(50))
        async let newer: Void = model.refresh("newer", takes: .milliseconds(10))
        _ = await (older, newer)
        #expect(await model.shown == "newer")
    }

    /// The early look during the image step: every 10 s in a small library, less often in a
    /// large one (each look derives the status of every photo).
    @Test func earlyLookIsRarerInALargeLibrary() {
        #expect(AnalysisCardState.earlyLookInterval(photos: 300) == .seconds(10))
        #expect(AnalysisCardState.earlyLookInterval(photos: 5_683) == .seconds(10))
        #expect(AnalysisCardState.earlyLookInterval(photos: 50_246) == .seconds(100))
    }
}
