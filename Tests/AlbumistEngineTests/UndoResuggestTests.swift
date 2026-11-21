import Foundation
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistTestSupport

/// UI run 43823834271 (rerun): after two plans were taken back ("Rückgängig gemacht"), the
/// overview still offered one suggestion, as before. The undo itself worked (the suggestions
/// said "Neues Album" again), but "15 empfohlene auswählen" had just turned 15 complete
/// suggestions into "So lassen" decisions: not open, nothing to create, and after the undo
/// their albums were gone. A user who takes a plan back must be able to create those albums
/// again.
@Suite("Undo brings the suggestions back")
struct UndoResuggestTests {
    let lifecycle = DecisionLifecycleTests()

    /// What `AppModel.finalize` stores after a plan, then `pipeline.rematch()`.
    /// `listed`: what the album list returned (nil: the library as it is).
    func finalize(_ plan: ChangePlan, in w: DecisionLifecycleTests.World, listed: CollectionInventory? = nil) async throws -> ProposalSnapshot {
        let current = try await w.library.currentInventory()
        let after = listed ?? current
        try await w.store.saveInventory(after)
        try await w.store.saveManagedAlbums(ManagedAlbumTracker().record(plan, into: try await w.store.managedAlbums(), inventory: after))
        await w.reader.set(inventory: after)
        return try #require(try await w.pipeline.rematch())
    }

    func open(_ snapshot: ProposalSnapshot, _ ids: Set<AlbumistID>) -> [String] {
        snapshot.proposals.filter { ids.contains($0.id) && snapshot.matches[$0.id]?.status != .alreadyComplete }.map(\.title)
    }

    @Test func takenBackSuggestionsAreOpenAgain() async throws {
        let w = try await lifecycle.world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let items = lifecycle.acceptSafe(first)
        let ids = Set(items.map(\.proposal.id))
        #expect(items.count >= 2)

        let plan = lifecycle.confirmed(lifecycle.planner.makePlan(from: items, inventory: try await w.library.currentInventory(),
                                                                  overrides: OverrideSet(try await w.store.overrides())))
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        #expect(executed.status == .completed)
        let applied = try await finalize(executed, in: w)
        let afterApply = open(applied, ids)
        #expect(afterApply.isEmpty, "Applied but still open: \(afterApply)")
        _ = try await w.pipeline.run()

        // "Rückgängig machen", the way `AppModel.undo` plans it.
        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in try await w.store.managedAlbums() { owned[state.albumID, default: []].formUnion(state.addedByAlbumist) }
        let undo = lifecycle.confirmed(UndoPlanner().undoPlan(for: executed, current: try await w.library.currentInventory(), owned: owned))
        let undone = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        let rematched = try await finalize(undone, in: w)
        let back = open(rematched, ids)
        let states = rematched.proposals.filter { ids.contains($0.id) }.map { "\($0.title): \(String(describing: rematched.matches[$0.id]?.status))" }
        #expect(back.count == ids.count, "Taken back, open again: \(back) of \(states)")

        // And after the next analysis, which the app starts after every plan.
        _ = try await w.pipeline.run()
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(open(next, ids).count == ids.count)
    }

    /// "Empfohlene auswählen" on suggestions whose albums are complete selects nothing, and a
    /// "So lassen" whose album an undo took away goes back to open (what `AppModel.finalize`
    /// does with `ProposalDecision.keepsOfAlbumsDeleted`).
    @Test func completeSuggestionsAreNotRecommendedAndAKeptOneComesBackAfterTheUndo() async throws {
        let w = try await lifecycle.world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let items = lifecycle.acceptSafe(first)
        let created = Set(items.filter { if case .createNew = $0.decision { true } else { false } }.map(\.proposal.id))
        #expect(!created.isEmpty)
        let plan = lifecycle.confirmed(lifecycle.planner.makePlan(from: items, inventory: try await w.library.currentInventory(),
                                                                  overrides: OverrideSet(try await w.store.overrides())))
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        let applied = try await finalize(executed, in: w)

        // The suggestions list's "N empfohlene auswählen" (`ProposalListView.recommendable`).
        var decisions: [AlbumistID: ProposalDecision] = [:]
        func recommendable(_ snapshot: ProposalSnapshot) -> Set<AlbumistID> {
            Set(snapshot.proposals.filter { decisions[$0.id] == nil && ProposalDecision.isSafeToAcceptUnseen($0, match: snapshot.matches[$0.id]) }.map(\.id))
        }
        let complete = Set(applied.proposals.filter { applied.matches[$0.id]?.status == .alreadyComplete }.map(\.id))
        #expect(created.isSubset(of: complete))
        #expect(recommendable(applied).isDisjoint(with: complete), "Complete suggestions offered as recommended")

        // A "So lassen" stored for each complete album (by a version before this fix, or chosen).
        for p in applied.proposals where complete.contains(p.id) {
            decisions[p.id] = ProposalDecision.recommended(for: p, match: applied.matches[p.id])
            #expect(decisions[p.id]?.isKeepExisting == true)
        }

        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in try await w.store.managedAlbums() { owned[state.albumID, default: []].formUnion(state.addedByAlbumist) }
        let undo = lifecycle.confirmed(UndoPlanner().undoPlan(for: executed, current: try await w.library.currentInventory(), owned: owned))
        let undone = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        let rematched = try await finalize(undone, in: w)
        for id in ProposalDecision.keepsOfAlbumsDeleted(by: undone, in: decisions) { decisions[id] = nil }

        // `AppModel.openProposals`: no decision and not complete.
        let open = Set(rematched.proposals.filter { decisions[$0.id] == nil && rematched.matches[$0.id]?.status != .alreadyComplete }.map(\.id))
        #expect(created.isSubset(of: open), "Not open again after the undo: \(rematched.proposals.filter { created.contains($0.id) && !open.contains($0.id) }.map(\.title))")
        #expect(created.isSubset(of: recommendable(rematched)))
        // The album of the user stays, and so does the decision to leave it as it is.
        let kept = decisions.compactMap { _, d -> CollectionID? in if case .keepExisting(let a) = d { a } else { nil } }
        #expect(kept.allSatisfy { w.initial[$0] != nil })
    }

    /// Review of 697852f: the album list can come back with few or no albums (limited access,
    /// an iCloud sync). A "So lassen" is dropped only for an album the undo's own deletion
    /// steps removed; one for an album the list merely lacks survives, after a plan and after
    /// an undo.
    @Test func aKeepSurvivesAnAlbumListWithoutAlbums() async throws {
        let w = try await lifecycle.world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let items = lifecycle.acceptSafe(first)
        let plan = lifecycle.confirmed(lifecycle.planner.makePlan(from: items, inventory: try await w.library.currentInventory(),
                                                                  overrides: OverrideSet(try await w.store.overrides())))
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        _ = try await finalize(executed, in: w)
        let createdAlbums = Set(try await w.store.managedAlbums().filter(\.createdByAlbumist).map(\.albumID))
        #expect(!createdAlbums.isEmpty)
        let userAlbum: CollectionID = "sommer-rom"
        let other = try #require(first.proposals.first { p in !items.contains { $0.proposal.id == p.id } })
        let created = try #require(items.first { if case .createNew = $0.decision { true } else { false } })
        var decisions: [AlbumistID: ProposalDecision] = [
            other.id: .keepExisting(userAlbum),
            created.proposal.id: .keepExisting(try #require(createdAlbums.first)),
        ]

        // A plan finishes while the album list is empty: nothing is dropped.
        #expect(ProposalDecision.keepsOfAlbumsDeleted(by: executed, in: decisions).isEmpty)

        // The undo deletes Albumist's albums; the list read after it is empty as well.
        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in try await w.store.managedAlbums() { owned[state.albumID, default: []].formUnion(state.addedByAlbumist) }
        let undo = lifecycle.confirmed(UndoPlanner().undoPlan(for: executed, current: try await w.library.currentInventory(), owned: owned))
        let undone = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(undo)
        _ = try await finalize(undone, in: w, listed: CollectionInventory())
        let dropped = ProposalDecision.keepsOfAlbumsDeleted(by: undone, in: decisions)
        for id in dropped { decisions[id] = nil }
        #expect(decisions[other.id] == .keepExisting(userAlbum), "A deliberate \"So lassen\" was lost")
        #expect(try await w.library.currentInventory()[userAlbum] != nil)
        #expect(dropped == [created.proposal.id])
    }
}
