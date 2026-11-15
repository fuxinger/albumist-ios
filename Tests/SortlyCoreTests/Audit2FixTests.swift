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
}
