import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Re-review of "Dein Zuhause" (16.11.): the scenarios of its findings, kept as tests.
@Suite("Re-review: Dein Zuhause concurrency")
struct ReReviewHomeTests {
    let now = Fixture.date("2026-11-16")

    /// `rematch()` ("Passt nicht", after a plan) while "Analyse neu aufbauen" clears the store:
    /// `resetAnalysis()` bumps `proposalsGeneration` before the reset is sent, so a rematch that
    /// read the old suggestions matches again (and finds none) instead of writing them back.
    @Test func rematchDuringRebuildLeavesNoOldSuggestions() async throws {
        let s = try HomePipelineTests().setup { lib in _ = HomePipelineTests.gardaEveryMonth(&lib) }
        _ = try await s.pipeline.run()
        let snapshot = try #require(try await s.pipeline.latestProposals())
        // Albums Albumist made before (kept by the rebuild): the last read of the rematch takes
        // a moment, as on a library where many albums were made.
        let members = Set(s.lib.assets.prefix(60).map(\.id))
        try await s.store.saveManagedAlbums((0..<1500).map { i in
            ManagedAlbumState(albumID: CollectionID("album-\(i)"), sourceID: SortlyID.stable("re-review", "\(i)"), lastKnownTitle: "Album \(i)",
                              lastKnownParentID: nil, lastKnownMembers: members, addedBySortly: members, createdBySortly: true)
        })
        let p = s.pipeline
        var stale = 0
        var tries = 0
        for _ in 0..<1 {
            for k in 0..<30 {
                tries += 1
                try await s.store.setValue(snapshot, forKey: "analysis.proposals")
                let rematch = Task { try await p.rematch() }
                let reset = Task {
                    try? await Task.sleep(for: .milliseconds(2 * k))
                    try await p.resetAnalysis()
                }
                _ = try await rematch.value
                try await reset.value
                if try await p.latestProposals() != nil { stale += 1 }
            }
        }
        #expect(stale == 0)
    }

    /// "Nein, das sind Reisen" (`changeRecurringPlaces(rerun: false)`, allowed at any time) while
    /// the suggestions of a home change are made: nothing the suggestions are made from changed,
    /// so the change is applied and the overview told at once.
    @Test func aNeinWhileTheSuggestionsAreMadeHoldsBackTheNotice() async throws {
        var lib = LibraryBuilder()
        _ = HomePipelineTests.gardaEveryMonth(&lib)
        let store = try SortlyStore(url: nil)
        let reader = HookedReader(base: InMemoryLibraryReader(assets: lib.assets))
        let p = HomeReviewStoreTests().pipeline(store, reader: reader)
        _ = try await p.run()
        let parents = try await p.recurringPlaceAnswers()
            .addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        try await p.setRecurringPlaceAnswers(parents)
        let nein = parents.answering(false, at: Fixture.Places.rome, name: "Rom", date: now)
        reader.hook = { try? await p.setRecurringPlaceAnswers(nein) }
        reader.armed = true
        let notice = try await p.resuggest()
        let after = try #require(try await p.latestProposals())
        // The suggestions did change: the ten trips to Lake Garda are gone.
        #expect(after.proposals.filter { $0.kind == .trip }.isEmpty)
        let pendingAfterResuggest = try await p.pendingHomeChange() != nil
        #expect(notice != nil)
        #expect(!pendingAfterResuggest)
        // Not lost: the next analysis tells the overview.
        _ = try await p.run()
        #expect(try await p.homeChangeNotice() != nil)
        #expect(try await p.pendingHomeChange() == nil)
    }
}

@Suite("Re-review: Ändern after a move, through the pipeline")
struct ReReviewChangeAfterAMovePipelineTests {
    let now = Fixture.date("2026-11-16")

    /// Moved from Munich to Hamburg 2.5 months ago: the detection still shows Munich. The user
    /// picks Hamburg under "Ändern" with the proposed date of the move (AppModel.chooseHome).
    @Test func pickingTheNewTownAddsNoTrip() async throws {
        let s = try HomePipelineTests().setup { lib in
            lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
            lib.daily(from: "2026-09-01", to: "2026-11-15", at: HomePipelineTests.hamburg, perDay: 2, hour: 19)
        }
        _ = try await s.pipeline.run()
        let detected = try #require(try await s.pipeline.detectedHome())
        let before = try #require(try await s.pipeline.latestProposals())
        let facts = try await s.pipeline.currentFacts()
        let hamburg = HomePlace(center: HomePipelineTests.hamburg, components: HomeName.components(near: HomePipelineTests.hamburg, facts: facts))
        let since = try #require(HomeCandidates.stayStart(near: HomePipelineTests.hamburg, assets: try await s.store.allAssets(), calendar: Fixture.calendar))
        #expect(since == Fixture.date("2026-09-01"))
        try await s.pipeline.setHomeSettings(HomeSettings().choosing(hamburg, from: since, date: now))
        let notice = try await s.pipeline.resuggest()
        let after = try #require(try await s.pipeline.latestProposals())
        let beforeIDs = Set(before.proposals.map(\.id))
        let new = after.proposals.filter { !beforeIDs.contains($0.id) }
        let homeBefore = try await s.store.value(Set<AssetID>.self, forKey: "analysis.home")?.count ?? 0
        #expect(new.filter { $0.kind == .trip }.isEmpty)
    }
}
