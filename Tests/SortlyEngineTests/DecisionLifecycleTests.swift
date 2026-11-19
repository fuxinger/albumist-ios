import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// The whole decision cycle, end to end, the way the app runs it: analysis → suggestions →
/// the recommended decisions → plan → execution in a photo library → the next analysis.
/// Every manual decision the user makes in Photos or in Albumist must survive that cycle.
@Suite("Decision lifecycle (logic test)")
struct DecisionLifecycleTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    let planner = OrganizationPlanner(rootFolderTitle: "Albumist", chunkSize: 50)

    struct World {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var library: InMemoryPhotoLibrary
        var pipeline: AnalysisPipeline
        var rome: [AssetID]
        var paris: [AssetID]
        var all: Set<AssetID>
        var initial: CollectionInventory
    }

    /// Munich everyday life, trips to Rome and Paris, screenshots, and an existing album
    /// "Sommer in Rom" that already holds part of the Rome trip.
    func world() async throws -> World {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                  skipping: [("2025-09-03", "2025-09-08"), ("2026-05-12", "2026-05-19")])
        let paris = lib.daily(from: "2025-09-03", to: "2025-09-08", at: GeoCoordinate(latitude: 48.8566, longitude: 2.3522), perDay: 4, hour: 10)
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for day in 1...5 { _ = lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        let shots = Set(lib.assets.filter { $0.subtypes.contains(.screenshot) }.map(\.id))
        let analyzer = FakeContentAnalyzer(
            labels: { _ in [] },
            text: { asset in shots.contains(asset.id) ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung Sendungsverfolgung" : "" }
        )
        let existing = CollectionSnapshot(id: "sommer-rom", title: "Sommer in Rom", assetIDs: Set(rome.prefix(20)))
        let smart = CollectionSnapshot(id: "smart", title: "Favoriten", kind: .smartAlbum, capabilities: [], assetIDs: Set(rome.prefix(3)))
        let initial = CollectionInventory([existing, smart])
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets, inventory: initial)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(pauseAfterChecks: nil), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, batchSize: 50
        )
        let all = Set(lib.assets.map(\.id))
        let library = InMemoryPhotoLibrary(assets: all, collections: [existing, smart])
        return World(store: store, reader: reader, library: library, pipeline: pipeline, rome: rome, paris: paris, all: all, initial: initial)
    }

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    /// What "Alle sicheren übernehmen" + "umsetzen" does in the app.
    func acceptSafe(_ snapshot: ProposalSnapshot) -> [ConfirmedProposal] {
        snapshot.proposals.compactMap { p in
            guard !p.isSensitive, !p.requiresUserName else { return nil }
            let decision = ProposalDecision.recommended(for: p, match: snapshot.matches[p.id])
            guard decision.isAccepted, !decision.isKeepExisting else { return nil }
            return ConfirmedProposal(proposal: p, decision: decision)
        }
    }

    /// Runs a plan in the library, records the albums like the app does and lets the next
    /// analysis see the result.
    @discardableResult
    func apply(_ items: [ConfirmedProposal], in w: World) async throws -> ChangePlan {
        let overrides = OverrideSet(try await w.store.overrides())
        let plan = confirmed(planner.makePlan(from: items, inventory: try await w.library.currentInventory(), overrides: overrides))
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        let after = try await w.library.currentInventory()
        try await w.store.saveManagedAlbums(ManagedAlbumTracker().record(executed, into: try await w.store.managedAlbums(), inventory: after))
        await w.reader.set(inventory: after)
        return executed
    }

    /// What the app does when it notices changes made in Photos.
    func reconcile(_ w: World) async throws {
        let current = try await w.library.currentInventory()
        await w.reader.set(inventory: current)
        let result = ManagedAlbumTracker().reconcile(try await w.store.managedAlbums(), with: current)
        for override in result.newOverrides { try await w.store.addOverride(override) }
        try await w.store.saveManagedAlbums(result.updatedStates)
    }

    // MARK: - Tests

    @Test func appliedSuggestionsAreCompleteAfterTheNextAnalysisAndNothingIsPlannedTwice() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let items = acceptSafe(first)
        // The two trips. Their countries were seen on one trip each (the trip is their album),
        // and the order screenshots are with the documents, which are never taken in one go.
        #expect(items.count >= 2)
        // The existing album is extended, not duplicated.
        let romeTrip = try #require(items.first { $0.proposal.kind == .trip && Set($0.proposal.assetIDs) == Set(w.rome) })
        #expect(romeTrip.decision == .extendExisting("sommer-rom"))

        let executed = try await apply(items, in: w)
        #expect(executed.status == .completed)
        #expect(await w.library.assets == w.all) // never a photo created, copied or deleted

        _ = try await w.pipeline.run()
        let second = try #require(try await w.pipeline.latestProposals())
        for item in items {
            let match = second.matches[item.proposal.id]
            let albums = ([match?.best].compactMap { $0 } + (match?.alternatives ?? [])).map { "\($0.albumTitle) p\($0.metrics.purity) c\($0.metrics.coverage) s\($0.score)" }
            #expect(match?.status == .alreadyComplete, "\(item.proposal.title) [\(item.proposal.kind)]: \(String(describing: match?.status)) \(albums)")
        }
        // Accepting everything again changes nothing in Photos.
        let again = planner.makePlan(from: acceptSafe(second), inventory: try await w.library.currentInventory(),
                                     overrides: OverrideSet(try await w.store.overrides()))
        #expect(again.steps.isEmpty, "Second plan would change: \(again.steps.map(\.operation))")
    }

    @Test func readOnlyAlbumsAreNeverTouched() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let snapshot = try #require(try await w.pipeline.latestProposals())
        try await apply(acceptSafe(snapshot), in: w)
        let smart = try #require(try await w.library.currentInventory()["smart"])
        #expect(smart == w.initial["smart"])
    }

    @Test func undoBringsTheLibraryBack() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let snapshot = try #require(try await w.pipeline.latestProposals())
        let executed = try await apply(acceptSafe(snapshot), in: w)
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await w.library.currentInventory()))
        let undone = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        let inventory = try await w.library.currentInventory()
        #expect(Set(inventory.albums.map(\.id)) == Set(w.initial.albums.map(\.id)))
        for album in w.initial.albums { #expect(inventory[album.id] == album) }
    }

    @Test func photosTheUserTookOutOfAnAlbumStayOut() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        try await apply(acceptSafe(try #require(try await w.pipeline.latestProposals())), in: w)
        let states = try await w.store.managedAlbums()

        // In Photos, the user removes two Paris photos from the trip album Albumist created.
        let parisAlbum = try #require(states.first { state in
            state.createdBySortly && state.addedBySortly == Set(w.paris) && state.lastKnownTitle.contains(",")
        })
        let removed = Array(w.paris.prefix(2))
        await w.library.userEdit { inv in
            var album = inv[parisAlbum.albumID]!
            album.assetIDs.subtract(removed)
            inv.upsert(album)
        }
        try await reconcile(w)

        _ = try await w.pipeline.run()
        let next = try #require(try await w.pipeline.latestProposals())
        // The suggestion counts as done: it is not offered again because of the two photos.
        #expect(next.matches[parisAlbum.sourceID]?.status == .alreadyComplete)
        let plan = planner.makePlan(from: acceptSafe(next), inventory: try await w.library.currentInventory(),
                                    overrides: OverrideSet(try await w.store.overrides()))
        let readded = plan.steps.flatMap { step -> [AssetID] in
            if case .addAssets(_, let assets) = step.operation { return assets } else { return [] }
        }
        #expect(Set(readded).isDisjoint(with: removed), "Albumist would put removed photos back")
    }

    @Test func aDeletedAlbumIsNotCreatedAgain() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        try await apply(acceptSafe(try #require(try await w.pipeline.latestProposals())), in: w)
        let states = try await w.store.managedAlbums()
        let parisAlbum = try #require(states.first { $0.createdBySortly && $0.addedBySortly == Set(w.paris) })

        await w.library.userEdit { inv in inv.remove(parisAlbum.albumID) }
        try await reconcile(w)
        _ = try await w.pipeline.run()
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(!next.proposals.contains { $0.id == parisAlbum.sourceID })
    }

    @Test func aRejectedSuggestionStaysRejected() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let trip = try #require(first.proposals.first { $0.kind == .trip && Set($0.assetIDs) == Set(w.paris) })
        try await w.store.addOverride(UserOverride(scope: .source(trip.id), decision: .rejectProposal))
        _ = try await w.pipeline.run(mode: .refinement)
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(!next.proposals.contains { $0.id == trip.id })
        #expect(next.proposals.contains { $0.kind == .trip }) // the other trip is still there
    }

    @Test func anAlbumMarkedAsNotFittingIsReplacedByANewAlbum() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let trip = try #require(first.proposals.first { $0.kind == .trip && Set($0.assetIDs) == Set(w.rome) })
        #expect(first.matches[trip.id]?.best?.albumID == "sommer-rom")

        try await w.store.addOverride(UserOverride(scope: .albumForSource("sommer-rom", trip.id), decision: .notMatchingAlbum))
        let rematched = try #require(try await w.pipeline.rematch())
        #expect(rematched.matches[trip.id]?.best?.albumID != "sommer-rom")
        let decision = ProposalDecision.recommended(for: trip, match: rematched.matches[trip.id])
        guard case .createNew = decision else {
            Issue.record("Expected a new album, got \(decision)")
            return
        }
        // It also holds after a full analysis, not only after the quick re-match.
        _ = try await w.pipeline.run(mode: .refinement)
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(next.matches[trip.id]?.best?.albumID != "sommer-rom")
        // And applying it leaves the user's album exactly as it was.
        try await apply([ConfirmedProposal(proposal: trip, decision: decision)], in: w)
        #expect(try await w.library.currentInventory()["sommer-rom"] == w.initial["sommer-rom"])
    }

    /// Random libraries and decisions: whatever the user picks, the invariants hold.
    @Test(arguments: 1...40)
    func invariantsHoldForRandomDecisions(seed: Int) async throws {
        var rng = SplitMix(seed: UInt64(seed))
        let assets = (0..<200).map { AssetID("r-\($0)") }
        func randomSet(_ n: Int) -> Set<AssetID> { Set((0..<n).map { _ in assets[Int(rng.next() % 200)] }) }
        var albums: [CollectionSnapshot] = []
        for i in 0..<6 {
            let readOnly = rng.next() % 4 == 0
            albums.append(CollectionSnapshot(id: CollectionID("al-\(i)"), title: "Album \(i)",
                                             kind: readOnly ? .smartAlbum : .userAlbum, capabilities: readOnly ? [] : .all,
                                             assetIDs: randomSet(5 + Int(rng.next() % 40))))
        }
        let library = InMemoryPhotoLibrary(assets: Set(assets), collections: albums)
        let before = try await library.currentInventory()
        var items: [ConfirmedProposal] = []
        for i in 0..<8 {
            let proposal = AlbumProposal(id: SortlyID("p-\(i)"), kind: i % 2 == 0 ? .trip : .placeCollection(.locality),
                                         title: "Vorschlag \(i)", folderPath: i % 3 == 0 ? ["Reisen"] : [],
                                         assetIDs: randomSet(4 + Int(rng.next() % 30)))
            let target = albums[Int(rng.next() % UInt64(albums.count))].id
            let decision: ProposalDecision
            switch rng.next() % 5 {
            case 0: decision = .createNew(title: nil, folderPath: nil)
            case 1: decision = .extendExisting(target)
            case 2: decision = .keepExisting(target)
            case 3: decision = .renameExisting(target, newTitle: "Neu \(i)", extend: true)
            default: decision = .reject
            }
            items.append(ConfirmedProposal(proposal: proposal, decision: decision))
        }
        let plan = confirmed(planner.makePlan(from: items, inventory: before))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let after = try await library.currentInventory()

        // 1. Photos are never created, copied or deleted.
        #expect(await library.assets == Set(assets))
        // 2. Read-only albums are untouched; no album loses photos in a normal plan.
        for album in before.albums {
            let now = try #require(after[album.id], "album \(album.id) disappeared")
            if !album.isEditableAlbum { #expect(now == album) }
            #expect(album.assetIDs.isSubset(of: now.assetIDs))
        }
        // 3. Rejected and kept suggestions change nothing.
        let touched = Set(executed.steps.compactMap(\.sourceID))
        for item in items where item.decision == .reject || item.decision.isKeepExisting {
            #expect(!touched.contains(item.proposal.id))
        }
        // 4. The next round (re-matching with the recorded albums, as the app does) adds nothing:
        //    applied suggestions are complete, untouched decisions are kept as they were.
        let states = ManagedAlbumTracker().record(executed, into: [], inventory: after)
        let assignments = AnalysisPipeline.assignments(states)
        let matches = AlbumMatcher().match(items.map(\.proposal), against: after, assignments: assignments)
        let second = items.compactMap { item -> ConfirmedProposal? in
            guard item.decision.isAccepted else { return nil }
            guard touched.contains(item.proposal.id) else { return item }
            let decision = ProposalDecision.recommended(for: item.proposal, match: matches[item.proposal.id])
            return decision.isAccepted ? ConfirmedProposal(proposal: item.proposal, decision: decision) : nil
        }
        let again = planner.makePlan(from: second, inventory: after)
        let adds = again.steps.filter { if case .addAssets = $0.operation { true } else { false } }
        #expect(adds.isEmpty, "seed \(seed): second run adds again")
        if !adds.isEmpty {
            for step in adds {
                let id = step.sourceID!
                let item = items.first { $0.proposal.id == id }!
                print("DEBUG decision \(item.decision) | assigned \(String(describing: assignments[id])) | match \(String(describing: matches[id]?.status)) best \(String(describing: matches[id]?.best?.albumTitle))")
                print("DEBUG steps \(executed.steps.filter { $0.sourceID == id }.map { "\($0.operation) \($0.state)" })")
            }
        }
        // 5. Undo restores every album that existed before.
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: after))
        _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)
        let restored = try await library.currentInventory()
        for album in before.albums { #expect(restored[album.id] == album, "seed \(seed): \(album.title) not restored") }
        #expect(Set(restored.albums.map(\.id)) == Set(before.albums.map(\.id)))
    }

    /// Second review 16.11. (8): results saved by an older matching version are matched again
    /// once at launch, so the fixed rules hold at once and not only after the next analysis.
    @Test func outdatedMatchesAreMatchedAgainAtLaunch() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        var stored = try #require(try await w.pipeline.latestProposals())
        #expect(stored.matcherVersion == AlbumMatcher.version)
        #expect(!stored.matches.isEmpty)

        // Saved before the version stamp: the key is missing, it reads as version 0.
        let json = try JSONEncoder().encode(stored)
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["matcherVersion"] = nil
        let old = try JSONDecoder().decode(ProposalSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.matcherVersion == 0)

        // Current version: left as it is (here: no matches at all).
        stored.matches = [:]
        try await w.store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)
        #expect(try await w.pipeline.refreshMatchesIfOutdated().snapshot?.matches.isEmpty == true)
        // Older version: matched again and stamped.
        stored.matcherVersion = 1
        try await w.store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)
        let refreshed = try #require(try await w.pipeline.refreshMatchesIfOutdated().snapshot)
        #expect(refreshed.matcherVersion == AlbumMatcher.version)
        #expect(!refreshed.matches.isEmpty)
        #expect(try await w.pipeline.latestProposals()?.matcherVersion == AlbumMatcher.version)
    }

    /// Re-check 16.11. (3): a decision accepted under the old rules that would extend an album
    /// without a certain match any more is reported after the launch re-match, so the app sets
    /// it back to open. Other decisions stay; nothing is reported without a re-match.
    @Test func oldExtendDecisionsAreReopenedAfterTheRematch() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        var stored = try #require(try await w.pipeline.latestProposals())
        let ps = stored.proposals.filter { !$0.isSensitive && !$0.requiresUserName }
        #expect(ps.count >= 2)
        // Accepted earlier: "ergänzen" into "Sommer in Rom" for a suggestion it is no certain
        // match of, and a new album for another.
        let decisions: [SortlyID: ProposalDecision] = [ps[0].id: .extendExisting("sommer-rom"),
                                                       ps[1].id: .createNew(title: nil, folderPath: nil)]
        #expect(!AlbumMatcher().sortingAlbums(stored.matches[ps[0].id], kind: ps[0].kind, title: ps[0].title).contains("sommer-rom"))
        try await w.store.setValue(decisions, forKey: AnalysisPipeline.Key.decisions)
        #expect(try await w.pipeline.refreshMatchesIfOutdated().reopened.isEmpty)
        stored.matcherVersion = 1
        try await w.store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)

        // Final check 16.11.: the app ends half way through saving (here: right after the new
        // matches with their version stamp). Nothing may be saved, or the old "ergänzen" stays.
        struct Ended: Error {}
        await #expect(throws: Ended.self) {
            _ = try await w.pipeline.refreshMatchesIfOutdated(afterEachWrite: { key in
                if key == AnalysisPipeline.Key.proposals { throw Ended() }
            })
        }
        #expect(try await w.pipeline.latestProposals()?.matcherVersion == 1)
        #expect(try await w.store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions) == decisions)
        #expect(try await w.store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) == nil)

        // The next launch does it: decision open again, stamp and count saved with it.
        #expect(try await w.pipeline.refreshMatchesIfOutdated().reopened == [ps[0].id])
        let saved = try await w.store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions)
        #expect(saved == [ps[1].id: .createNew(title: nil, folderPath: nil)])
        #expect(try await w.pipeline.latestProposals()?.matcherVersion == AlbumMatcher.version)
        #expect(try await w.store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) == 1)
        // Once: the results carry the new version now.
        #expect(try await w.pipeline.refreshMatchesIfOutdated().reopened.isEmpty)
        #expect(try await w.store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) == 1)
    }

    /// Second review of the place IDs (18.11.): a suggestion ID can go to other photos (a
    /// frequent place that is gone leaves its ID to a new place in its cell). The album recorded
    /// for that ID shares no photo with them and is no longer its album (`AlbumMatcher`, version
    /// 4). An accepted "ergänzen" into that album is set back to open after every analysis (the
    /// app calls this after each run), not run on the new photos. An album the user picked is
    /// left as chosen; results of version 3 are matched again.
    @Test func anExtendIntoTheAlbumOfOtherPhotosIsReopened() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        var stored = try #require(try await w.pipeline.latestProposals())
        let rome = Set(w.rome)
        let ps = stored.proposals.filter { $0.assetIDs.isDisjoint(with: rome) }
        #expect(ps.count >= 2)
        let decisions: [SortlyID: ProposalDecision] = [ps[0].id: .extendExisting("sommer-rom"), ps[1].id: .extendExisting("sommer-rom")]
        try await w.store.setValue(decisions, forKey: AnalysisPipeline.Key.decisions)
        // Recorded for the ID too: the album made for the photos it has now.
        let own = Set(ps[0].assetIDs.prefix(3))
        let inventory = try await w.store.loadInventory()
        try await w.store.saveInventory(CollectionInventory(inventory.albums + [CollectionSnapshot(id: "a-now", title: ps[0].title, assetIDs: own)]))
        try await w.store.saveManagedAlbums([
            ManagedAlbumState(albumID: "sommer-rom", sourceID: ps[0].id, lastKnownTitle: "Sommer in Rom", lastKnownParentID: nil,
                              lastKnownMembers: Set(w.rome.prefix(20)), addedBySortly: Set(w.rome.prefix(20)), createdBySortly: true),
            ManagedAlbumState(albumID: "a-now", sourceID: ps[0].id, lastKnownTitle: ps[0].title, lastKnownParentID: nil,
                              lastKnownMembers: own, addedBySortly: own, createdBySortly: true)])
        #expect(try await w.pipeline.refreshMatchesIfOutdated().reopened == [ps[0].id])
        #expect(try await w.store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions)
                == [ps[1].id: .extendExisting("sommer-rom")])
        #expect(try await w.store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) == 1)
        #expect(try await w.pipeline.refreshMatchesIfOutdated().reopened.isEmpty)

        // Re-review: the user picks that album again ("Anderes Album wählen"). Their choice
        // stands: the same album is reopened for the same suggestion only once, not after
        // every analysis.
        try await w.store.setValue(decisions, forKey: AnalysisPipeline.Key.decisions)
        #expect(try await w.pipeline.refreshMatchesIfOutdated().reopened.isEmpty)
        #expect(try await w.store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions) == decisions)
        #expect(try await w.store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) == 1)

        // Third review: what is remembered goes once the suggestion has neither a decision nor a
        // recorded album; the entry of this suggestion stays (its albums are still recorded).
        let mine = ps[0].id.rawValue + "|sommer-rom"
        try await w.store.setValue(Set([mine, "gone-suggestion|some-album"]), forKey: AnalysisPipeline.Key.reopenedExtensions)
        _ = try await w.pipeline.refreshMatchesIfOutdated()
        #expect(try await w.store.value(Set<String>.self, forKey: AnalysisPipeline.Key.reopenedExtensions) == [mine])

        stored = try #require(try await w.pipeline.latestProposals())
        // The rule above came with version 4: saved results of version 3 are matched again.
        #expect(AlbumMatcher.version >= 4)
        stored.matcherVersion = 3
        stored.matches = [:]
        try await w.store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)
        #expect(try await w.pipeline.refreshMatchesIfOutdated().snapshot?.matches.isEmpty == false)
        #expect(try await w.pipeline.latestProposals()?.matcherVersion == AlbumMatcher.version)
    }

    /// Second review 19.11. (S1): decisions accepted before "Gleicher Name gewinnt" (matching
    /// version 5) and not yet applied. The user's album "Italien" holds the 2019 trip; the old
    /// rules gave it to the trip ("so lassen") and a new album to the country. After the launch
    /// re-match the country extends "Italien": its accepted "new album" would make a second
    /// "Italien", and the trip's "so lassen" refers to an album that is the country's now. Both
    /// go back to open. They were not reopened because the rules for the user's albums became
    /// stricter, so the overview's notice saying so does not count them.
    @Test func decisionsAgainstTheSameNameRuleAreReopenedWithoutTheStricterNotice() async throws {
        var lib = LibraryBuilder()
        let trips = [("2019-05-10", "2019-05-17", Fixture.Places.rome), ("2021-09-03", "2021-09-10", Fixture.Places.florence),
                     ("2023-06-01", "2023-06-08", Fixture.Places.naples)]
        lib.daily(from: "2019-01-01", to: "2024-06-30", at: Fixture.Places.munichHome, perDay: 1,
                  skipping: trips.map { ($0.0, $0.1) })
        let away = trips.map { lib.daily(from: $0.0, to: $0.1, at: $0.2, perDay: 4, hour: 10) }
        let mine = CollectionSnapshot(id: "it", title: "Italien", assetIDs: Set(away[0]))
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets, inventory: CollectionInventory([mine])),
            analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(pauseAfterChecks: nil), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, batchSize: 50)
        _ = try await pipeline.run()
        var stored = try #require(try await pipeline.latestProposals())
        let country = try #require(stored.proposals.first { $0.title == "Italien" })
        let trip19 = try #require(stored.proposals.first { $0.kind == .trip && $0.assetIDs == Set(away[0]) })
        let trip21 = try #require(stored.proposals.first { $0.kind == .trip && $0.assetIDs == Set(away[1]) })
        #expect(ProposalDecision.recommended(for: country, match: stored.matches[country.id]) == .extendExisting("it"))

        // Accepted under the old rules, not applied yet.
        let old: [SortlyID: ProposalDecision] = [country.id: .createNew(title: nil, folderPath: nil),
                                                 trip19.id: .keepExisting("it"),
                                                 trip21.id: .createNew(title: nil, folderPath: nil)]
        try await store.setValue(old, forKey: AnalysisPipeline.Key.decisions)
        stored.matcherVersion = 4
        try await store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)
        let refresh = try await pipeline.refreshMatchesIfOutdated()
        #expect(refresh.reopened == [country.id, trip19.id])
        #expect(try await store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions)
                == [trip21.id: .createNew(title: nil, folderPath: nil)])
        #expect((try await store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) ?? 0) == 0)

        // The trip extending "Italien" instead of keeping it: the same.
        try await store.setValue([trip19.id: ProposalDecision.extendExisting("it")], forKey: AnalysisPipeline.Key.decisions)
        try await store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)
        #expect(try await pipeline.refreshMatchesIfOutdated().reopened == [trip19.id])
        #expect((try await store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) ?? 0) == 0)

        // A choice made under these rules (stored version 5 or later) is the user's own: "new
        // album" for the country and "so lassen" for the trip stay at every later re-match
        // (third review 19.11., S5).
        if AlbumMatcher.version > AlbumMatcher.sameNameWhateverItHoldsVersion {
            try await store.setValue(old, forKey: AnalysisPipeline.Key.decisions)
            var chosen = stored
            chosen.matcherVersion = AlbumMatcher.sameNameWhateverItHoldsVersion
            try await store.setValue(chosen, forKey: AnalysisPipeline.Key.proposals)
            #expect(try await pipeline.refreshMatchesIfOutdated().reopened.isEmpty)
            #expect(try await store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions) == old)
            #expect(try await pipeline.latestProposals()?.matcherVersion == AlbumMatcher.version)
        }

        // A new album the user named differently is no second "Italien": it stays.
        let named: [SortlyID: ProposalDecision] = [country.id: .createNew(title: "Italienreisen", folderPath: nil)]
        try await store.setValue(named, forKey: AnalysisPipeline.Key.decisions)
        try await store.setValue(stored, forKey: AnalysisPipeline.Key.proposals)
        #expect(try await pipeline.refreshMatchesIfOutdated().reopened.isEmpty)
        #expect(try await store.value([SortlyID: ProposalDecision].self, forKey: AnalysisPipeline.Key.decisions) == named)
    }

    /// Review 16.11. (A10): the user dismissed the trip ("Nicht jetzt"), whose own album
    /// "Italien" already holds it completely. The shown country must not extend that album with
    /// the photos of other years.
    @Test func completeAlbumOfADismissedSuggestionIsNotExtended() throws {
        let y19 = Set((0..<150).map { AssetID("it19-\($0)") }), y23 = Set((0..<150).map { AssetID("it23-\($0)") })
        // Not named exactly like the country: an album called "Italien" goes to the country
        // since the decision of 16.11. (ENTWURF Q8, sameNameWinsInThePipeline below).
        let album = CollectionSnapshot(id: "it", title: "Urlaub in Italien", assetIDs: y19)
        let trip = AlbumProposal(id: SortlyID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19)
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y23))
        let matches = AnalysisPipeline.match([country], dismissed: [trip], against: CollectionInventory([album]),
                                             overrides: OverrideSet(), assignments: [:])
        #expect(matches[trip.id]?.status == .alreadyComplete)
        let decision = ProposalDecision.recommended(for: country, match: matches[country.id])
        #expect(decision == .createNew(title: nil, folderPath: nil), "\(String(describing: matches[country.id]?.status))")
    }

    /// Decision Fuchs 16.11. (ENTWURF Q8): the user's "Italien" holds the dismissed 2019 trip
    /// completely. The shown country "Italien" extends it anyway; the trip, matched together
    /// with it, no longer keeps it.
    @Test func sameNameWinsInThePipeline() throws {
        let y19 = Set((0..<150).map { AssetID("it19-\($0)") }), y23 = Set((0..<150).map { AssetID("it23-\($0)") })
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: y19)
        let trip = AlbumProposal(id: SortlyID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19)
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y23))
        let matches = AnalysisPipeline.match([country], dismissed: [trip], against: CollectionInventory([album]),
                                             overrides: OverrideSet(), assignments: [:], trips: [y19, y23])
        #expect(ProposalDecision.recommended(for: country, match: matches[country.id]) == .extendExisting("it"))
        #expect(matches[trip.id]?.status != .alreadyComplete)
    }
}

/// Small deterministic generator for the randomized cases.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Speed of the matching with many places and trips (re-check 16.11.: the one-trip rule
/// counted trips per suggestion and doubled the time). Shown and dismissed suggestions, as
/// the pipeline matches them.
@Suite("Matching speed with places and trips")
struct PlaceMatchingSpeedTests {
    /// CPU time the calling thread has used, in seconds.
    static func threadCPUSeconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    @Test func placeHeavyLibraryMatchesQuickly() {
        func ids(_ range: Range<Int>) -> Set<AssetID> { Set(range.map { AssetID("x-\($0)") }) }
        // 400 trips of 100 photos, 10,000 photos at home.
        let trips = (0..<400).map { ids(($0 * 100)..<($0 * 100 + 100)) }
        var albums = [CollectionSnapshot(id: "alle", title: "Alle", assetIDs: ids(0..<50_000))]
        for i in 0..<400 { albums.append(CollectionSnapshot(id: CollectionID("t\(i)"), title: "Reise \(i)", assetIDs: trips[i])) }
        for i in 0..<300 { albums.append(CollectionSnapshot(id: CollectionID("p\(i)"), title: "Land \(i % 60)", assetIDs: ids((i * 100)..<(i * 100 + 60)))) }
        // Every photo in about 15 more albums ("Auswahl", "Beste", exports).
        for i in 0..<400 { albums.append(CollectionSnapshot(id: CollectionID("s-\(i)"), title: "Auswahl \(i)", assetIDs: ids((i * 100)..<min(50_000, i * 100 + 1500)))) }
        var open: [AlbumProposal] = [], dismissed: [AlbumProposal] = []
        // 60 countries of 6–7 trips, 200 cities of 2 trips each.
        for c in 0..<60 {
            let members = (0..<400).filter { $0 % 60 == c }.reduce(into: Set<AssetID>()) { $0.formUnion(trips[$1]) }
            open.append(AlbumProposal(id: SortlyID("c\(c)"), kind: .placeCollection(.country), title: "Land \(c)", assetIDs: members))
        }
        for c in 0..<200 {
            let p = AlbumProposal(id: SortlyID("s\(c)"), kind: .placeCollection(.locality), title: "Stadt \(c)",
                                  assetIDs: trips[c].union(trips[c + 200]))
            if c % 4 == 0 { dismissed.append(p) } else { open.append(p) }
        }
        // Measured as this thread's CPU time, not wall time: `match` runs on one thread, and
        // under `swift test --parallel` on a shared runner the wall time also counts the time
        // other tests held the CPU (5.02 s once, 2–3 s otherwise, run 43889885825). The limit
        // is unchanged; only what it measures no longer depends on the neighbours.
        let wallStart = Date()
        let cpuStart = Self.threadCPUSeconds()
        let matches = AnalysisPipeline.match(open, dismissed: dismissed, against: CollectionInventory(albums), overrides: OverrideSet(),
                                             assignments: [:], trips: trips)
        let seconds = Self.threadCPUSeconds() - cpuStart
        print("PLACE-PROBE seconds=\(seconds) wall=\(Date().timeIntervalSince(wallStart))")
        #expect(matches.count == open.count + dismissed.count)
        #expect(seconds < 5)
    }
}
