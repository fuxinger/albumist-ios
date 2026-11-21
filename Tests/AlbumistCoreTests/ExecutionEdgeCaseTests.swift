import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

@Suite("Execution: edge cases")
struct ExecutionEdgeCaseTests {
    private func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan; p.confirmedAt = Date(); p.status = .confirmed; return p
    }
    private func extend(_ inventory: CollectionInventory, assets: Set<AssetID>) -> ChangePlan {
        let p = AlbumProposal(id: AlbumistID("audit2"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: assets)
        return confirmed(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: p, decision: .extendExisting("album"))], inventory: inventory))
    }
    private func running(_ state: StepState) -> Bool { if case .running = state { return true }; return false }

    @Test func resumeAfterAllAddedPhotosWereRemovedByUser() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [CollectionSnapshot(id: "album", title: "Sommer")])
        let store = InMemoryPlanStore()
        let p = extend(try await lib.currentInventory(), assets: ["x", "y"])
        await lib.setFailAfterWrites(0, afterApplying: true)
        _ = try await ChangeExecutor(library: lib, store: store).execute(p)
        await lib.setFailAfterWrites(nil)
        let interrupted = try #require(await store.saved.last { $0.steps.contains { running($0.state) } })
        await lib.userEdit { inv in if var a = inv["album"] { a.assetIDs = []; inv.upsert(a) } }
        _ = try await ChangeExecutor(library: lib, store: store).execute(interrupted)
        #expect(try await lib.currentInventory()["album"]?.assetIDs.isEmpty == true)
    }

    @Test func uncertainInterruptedAddDoesNotClaimUsersMembership() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [CollectionSnapshot(id: "album", title: "Sommer")])
        let store = InMemoryPlanStore()
        let p = extend(try await lib.currentInventory(), assets: ["x"])
        await lib.setFailAfterWrites(0, afterApplying: false)
        _ = try await ChangeExecutor(library: lib, store: store).execute(p)
        await lib.setFailAfterWrites(nil)
        let interrupted = try #require(await store.saved.last { $0.steps.contains { running($0.state) } })
        await lib.userEdit { inv in if var a = inv["album"] { a.assetIDs.insert("x"); inv.upsert(a) } }
        let executor = ChangeExecutor(library: lib, store: store)
        let settled = try await executor.reconcileInterrupted(interrupted)
        let undo = confirmed(UndoPlanner().undoPlan(for: settled, current: try await lib.currentInventory()))
        _ = try await executor.execute(undo)
        #expect(try await lib.currentInventory()["album"]?.assetIDs == ["x"])
    }

    @Test func newDoNotRecreateOverrideStopsPendingCreation() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [])
        let p = AlbumProposal(id: AlbumistID("deleted-source"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x"])
        let plan = confirmed(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: p, decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory()))
        let override = UserOverride(scope: .source(p.id), decision: .doNotRecreateAlbum)
        let filtered = plan.respecting(OverrideSet([override]))
        _ = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(filtered)
        #expect(try await lib.currentInventory().albums.isEmpty)
    }

    @Test func unverifiedIntentIsNotCountedAsApplied() {
        var p = extend(CollectionInventory([CollectionSnapshot(id: "album", title: "Sommer")]), assets: ["x"])
        let i = p.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } }!
        p.steps[i].state = .failed(reason: "read back failed")
        var record = ExecutionRecord(); record.begin(p.steps[i].id, ["x"]); p.record = record
        #expect(p.appliedSummary.totalAssignments == 0)
        #expect(p.freeAlbumUse(applied: true) == 0)
    }

    @Test func receiptWithUnavailablePhotoIsNotComplete() {
        var p = extend(CollectionInventory([CollectionSnapshot(id: "album", title: "Sommer")]), assets: ["x", "y"])
        let i = p.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } }!
        p.steps[i].state = .succeeded(createdID: nil, verifiedAt: Date())
        var record = ExecutionRecord(); record.settle(p.steps[i].id, ["x"]); record.unavailable[p.steps[i].id] = 1; p.record = record
        #expect(!PlanReceipt(plan: p, inventory: CollectionInventory()).isComplete)
    }

    @Test func trackerKeepsEmptyCreatedAlbumForFutureDeletionDetection() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x"], collections: [])
        let proposal = AlbumProposal(id: AlbumistID("empty-source"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x"])
        let p = confirmed(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory()))
        let executor = ChangeExecutor(library: lib, store: InMemoryPlanStore())
        let result = try await executor.execute(p)
        let inv = try await lib.currentInventory()
        let tracker = ManagedAlbumTracker()
        let cid = try #require(inv.albums.first?.id)
        // User removes all the photos between execution and the first finalization.
        await lib.userEdit { inventory in if var a = inventory[cid] { a.assetIDs = []; inventory.upsert(a) } }
        let empty = try await lib.currentInventory()
        let refreshed = tracker.record(result, into: [], inventory: empty)
        #expect(refreshed.contains { $0.albumID == cid })
    }
}

@Suite("Audit 2 – OCR line boundaries")
struct Audit2OCRRegressionTests {
    @Test func cardNumberSplitAcrossOCRLinesIsMasked() {
        let raw = "4111 1111\n1111 1111"
        let stored = TextMinimizer.storable(raw)
        #expect(stored != raw)
    }
}
