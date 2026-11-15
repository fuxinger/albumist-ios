import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Our own tests for the fixes of the second review (docs/review/AUDIT2_2026-11-15.md),
/// next to the cases the reviewers supplied (Audit2RegressionTests).
@Suite("Audit 2: counting, receipt, free albums")
struct Audit2FixTests {
    private func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan; p.confirmedAt = Date(); p.status = .confirmed; return p
    }

    // MARK: 6.3 free albums given back once

    @Test func undoGivesFreeAlbumsBackOnceEvenWhenFinalizedAgain() {
        var ledger = FreeAlbumLedger()
        let plan = SortlyID("p")
        ledger.record(plan: plan, albums: 3)
        #expect(ledger.used == 3)
        // The undo is finalized, the app ends before the database write, the next launch
        // finalizes it again.
        let first = ledger.giveBack(plan: plan, albums: 3)
        let again = ledger.giveBack(plan: plan, albums: 3)
        #expect(first && !again)
        #expect(ledger.used == 0)
        // A plan given back is not counted again.
        let counted = ledger.record(plan: plan, albums: 3)
        #expect(!counted)
        #expect(ledger.used == 0)
    }

    @Test func olderTotalIsGivenBackOnlyOnce() {
        var ledger = FreeAlbumLedger(legacyUsed: 5)
        ledger.giveBack(plan: SortlyID("old"), albums: 2)
        ledger.giveBack(plan: SortlyID("old"), albums: 2)
        #expect(ledger.used == 3)
    }

    @Test func launchSettlesPlansThatWereUndoneBeforeTheirAlbumsCameBack() {
        var ledger = FreeAlbumLedger(legacyUsed: 4, byPlan: ["a": 2, "b": 1])
        let settled = ledger.settleUndone([SortlyID("a"), SortlyID("unknown")])
        #expect(settled)
        #expect(ledger.used == 5) // old total untouched, plan b still counts
        let again = ledger.settleUndone([SortlyID("a")])
        #expect(!again)
    }

    // MARK: 6.2 only confirmed changes count

    @Test func unverifiedRemovalIsNotCounted() {
        let inventory = CollectionInventory([CollectionSnapshot(id: "album", title: "Sommer", assetIDs: ["x"])])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["y"])
        var p = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("album"))], inventory: inventory))
        p.steps = [PlanStep(id: "r", operation: .removeAssets(album: "album", assets: ["x"]), sourceID: nil)]
        var record = ExecutionRecord()
        record.begin(p.steps[0].id, ["x"])
        p.record = record
        p.steps[0].state = .failed(reason: "read back failed")
        #expect(p.appliedSummary.removedMemberships == 0)
        #expect(PlanReceipt(plan: p, inventory: inventory).membershipsRemoved == 0)
    }

    // MARK: 7.2 names as they were

    @Test func receiptKeepsAlbumNameAndFolderAfterRename() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [
            CollectionSnapshot(id: "folder", title: "Reisen", kind: .folder, childIDs: ["album"]),
            CollectionSnapshot(id: "album", title: "Sommer", parentID: "folder"),
        ])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["x"])
        let plan = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("album"))], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        await lib.userEdit { inv in
            if var a = inv["album"] { a.title = "Archiv"; inv.upsert(a) }
            if var f = inv["folder"] { f.title = "Alt"; inv.upsert(f) }
        }
        let receipt = PlanReceipt(plan: result, inventory: try await lib.currentInventory())
        let album = try #require(receipt.albums.first)
        #expect(album.title == "Sommer")
        #expect(album.folderPath == ["Reisen"])
        // Even after the album is gone.
        let gone = PlanReceipt(plan: result, inventory: CollectionInventory())
        #expect(gone.albums.first?.title == "Sommer")
    }

    // MARK: 7.1 photos that were gone

    @Test func receiptWithOnlyUnavailablePhotosSaysWhy() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [CollectionSnapshot(id: "album", title: "Sommer")])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["x", "gone"])
        let plan = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("album"))], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let receipt = PlanReceipt(plan: result, inventory: try await lib.currentInventory())
        #expect(receipt.photosAdded == 1)
        #expect(receipt.unavailablePhotos == 1)
        #expect(!receipt.isComplete)
        #expect(receipt.failedSteps == 0)
    }

    // MARK: 1.1 / 1.2 interrupted adds

    private func running(_ state: StepState) -> Bool { if case .running = state { return true }; return false }

    /// In an album the plan created itself, what arrived is Albumist's; what the user took out
    /// afterwards stays out.
    @Test func resumeInOwnNewAlbumKeepsWhatArrivedAndAddsNothingBack() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [])
        let store = InMemoryPlanStore()
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x", "y"])
        let plan = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory()))
        // Folder and album are made, the add goes through, then the app stops.
        await lib.setFailAfterWrites(2, afterApplying: true)
        _ = try await ChangeExecutor(library: lib, store: store).execute(plan)
        await lib.setFailAfterWrites(nil)
        let crashed = try #require(await store.saved.last { $0.steps.contains { running($0.state) } })
        let album = try #require(try await lib.currentInventory().albums.first)
        await lib.userEdit { inv in if var a = inv[album.id] { a.assetIDs.remove("x"); inv.upsert(a) } }
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed)
        #expect(resumed.status == .completed)
        #expect(try await lib.currentInventory()[album.id]?.assetIDs == ["y"])
        #expect(resumed.appliedAssets == ["y"])
    }

    // MARK: 1.3 deleted albums are not made again

    @Test func deletedSuggestionDropsItsFolderAndPhotosToo() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "z"], collections: [])
        let deleted = AlbumProposal(id: SortlyID("deleted"), kind: .trip, title: "Rom", folderPath: ["Reisen"], assetIDs: ["x"])
        let kept = AlbumProposal(id: SortlyID("kept"), kind: .trip, title: "Paris", folderPath: ["Städte"], assetIDs: ["z"])
        let plan = confirmed(OrganizationPlanner().makePlan(from: [
            ConfirmedProposal(proposal: deleted, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: kept, decision: .createNew(title: nil, folderPath: nil)),
        ], inventory: try await lib.currentInventory()))
        let filtered = plan.respecting(OverrideSet([UserOverride(scope: .source(deleted.id), decision: .doNotRecreateAlbum)]))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(filtered)
        let titles = Set(try await lib.currentInventory().collections.values.map(\.title))
        #expect(!titles.contains("Rom") && !titles.contains("Reisen"))
        #expect(titles.contains("Paris") && titles.contains("Städte"))
        #expect(result.steps.contains { $0.state == .skipped(reason: StepState.deletedByUserReason) })
    }

    // MARK: 1.4 changes between the run and its finalization

    @Test func photoTakenOutBeforeFinalizationBecomesTheUsersDecision() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x", "y"])
        let plan = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let album = try #require(try await lib.currentInventory().albums.first)
        await lib.userEdit { inv in if var a = inv[album.id] { a.assetIDs.remove("x"); inv.upsert(a) } }
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(result, into: [], inventory: try await lib.currentInventory())
        let reconciled = tracker.reconcile(states, with: try await lib.currentInventory())
        #expect(reconciled.newOverrides.contains { $0.scope == .assetInAlbum("x", album.id) && $0.decision == .neverAdd })
        #expect(reconciled.updatedStates.first?.addedBySortly == ["y"])
    }

    @Test func albumDeletedBeforeFinalizationIsNotMadeAgain() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x"])
        let plan = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let album = try #require(try await lib.currentInventory().albums.first)
        try await lib.deleteCollection(album.id)
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(result, into: [], inventory: try await lib.currentInventory())
        let reconciled = tracker.reconcile(states, with: try await lib.currentInventory())
        #expect(reconciled.newOverrides.contains { $0.scope == .source(proposal.id) && $0.decision == .doNotRecreateAlbum })
    }

    // MARK: 1.7 the id of a new album is kept

    @Test func createdAlbumIsNotMadeTwiceWhenItsCheckFails() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x"])
        let plan = confirmed(OrganizationPlanner().makePlan(
            from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory()))
        await lib.setFailingCollectionReads(1) // the check right after creating fails once
        let executor = ChangeExecutor(library: lib, store: InMemoryPlanStore())
        let result = try await executor.execute(plan)
        #expect(result.steps.first?.state == .failed(reason: "created collection could not be verified"))
        let album = try #require(try await lib.currentInventory().albums.first)
        #expect(result.resolvedKeys.values.contains(album.id))
        if let retry = RetryPlanner().retryPlan(for: result, current: try await lib.currentInventory()) {
            _ = try await executor.execute(confirmed(retry))
        }
        #expect(try await lib.currentInventory().albums.count == 1)
        // Undo knows it is Albumist's album and removes it.
        let undo = UndoPlanner().undoPlan(for: result, current: try await lib.currentInventory())
        _ = try await executor.execute(confirmed(undo))
        #expect(try await lib.currentInventory().albums.isEmpty)
    }
}
