import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review P5-11 (18.11.2026): faults seeded on purpose that no fast test caught. Each test
/// here was red with its fault seeded (sample 19.11.2026 on the Linux suite of 1,314 tests).
/// The third fault of the review (a partly sorted photo counted as sorted) is caught by 18
/// existing checks since then and needs no test of its own.
@Suite("Seeded faults the fast tests must catch (P5-11)")
struct SeededFaultTests {
    let planner = OrganizationPlanner(rootFolderTitle: "Albumist")

    private func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    private func album(_ title: String, fitting: Int, other: Int) -> CollectionSnapshot {
        CollectionSnapshot(id: CollectionID(title), title: title,
                           assetIDs: ids("trip", 0..<fitting).union(ids("own", 0..<other)))
    }

    /// Fault 7: `extendablePurity` lowered from 0.8 to 0.7 put the suggestion's photos into a
    /// user's album that is only three quarters this trip; only an incidental check of the name
    /// rule noticed. An album with 80 % of its photos from the trip is extended, one with 75 %
    /// is not (its other photos are the user's own collection).
    @Test func anAlbumIsExtendedFromEightyPercentOfItsPhotosNotBelow() throws {
        let matcher = AlbumMatcher()
        let proposal = AlbumProposal(id: SortlyID("p-trip"), kind: .trip, title: "Gardasee · 03.08.–14.08.2026",
                                     assetIDs: ids("trip", 0..<100))
        let fits = album("Sommer", fitting: 80, other: 20)
        let atFit = try #require(matcher.match([proposal], against: CollectionInventory([fits]))[proposal.id])
        #expect(atFit.best?.metrics.purity == 0.8)
        #expect(atFit.status == .extendable)
        #expect(atFit.best?.albumID == fits.id)

        let below = album("Sommer", fitting: 75, other: 25)
        let underFit = try #require(matcher.match([proposal], against: CollectionInventory([below]))[proposal.id])
        #expect(underFit.best.map { $0.metrics.purity } ?? 0.75 < 0.8)
        #expect(underFit.status != .extendable)
        #expect(underFit.status != .alreadyComplete)
    }

    /// Fault 11: an interrupted add to a user's own album, settled before the undo
    /// (`reconcileInterrupted`), counted as done although only part of the photos are there.
    /// It must stay unclear: Albumist cannot tell whether it put them there, so the undo
    /// leaves them, and the step is not reported as done.
    @Test func anInterruptedAddWithOnlySomePhotosInTheUsersAlbumStaysUnclear() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer")])
        let store = InMemoryPlanStore()
        let proposal = AlbumProposal(id: SortlyID("extend"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["x", "y"])
        let plan = confirmed(planner.makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("sommer"))],
                                              inventory: try await lib.currentInventory()))
        // The request reached Photos, then the app stopped before it noted the answer.
        await lib.setFailAfterWrites(0, afterApplying: true)
        _ = try await ChangeExecutor(library: lib, store: store).execute(plan)
        await lib.setFailAfterWrites(nil)
        let addIndex = try #require(plan.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } })
        let crashed = try #require(await store.saved.last { if case .running = $0.steps[addIndex].state { true } else { false } })
        // Meanwhile one of the two photos left the album again (the user, or iCloud).
        try await lib.removeAssets(["y"], from: "sommer")

        let settled = try await ChangeExecutor(library: lib, store: store).reconcileInterrupted(crashed)
        #expect(settled.steps[addIndex].state == .failed(reason: StepState.unclearReason))
        #expect(try await lib.currentInventory()["sommer"]?.assetIDs == ["x"])
    }

    // MARK: Branches the review found never run (P5-11, "Album gibt es nicht mehr", resume)

    private func removalPlan(_ album: CollectionID, _ assets: [AssetID]) -> ChangePlan {
        ChangePlan(id: SortlyID("removal"), createdAt: Date(), confirmedAt: Date(), status: .confirmed, baseline: [:],
                   baselineCollectionIDs: [], steps: [PlanStep(id: "r0", operation: .removeAssets(album: album, assets: assets),
                                                              sourceID: SortlyID("g"))],
                   conflicts: [], notes: [], resolvedKeys: [:])
    }

    /// The album went away while Albumist added to it (the user deleted it in Photos at that
    /// moment): the step fails as "album no longer exists" and claims no photo for the undo.
    @Test func anAlbumDeletedWhileAddingClaimsNothing() async throws {
        let base = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer")])
        let lib = DeletesAfterWrite(base, album: "sommer")
        let proposal = AlbumProposal(id: SortlyID("extend"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["x", "y"])
        let plan = confirmed(planner.makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("sommer"))],
                                              inventory: try await base.currentInventory()))
        let done = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let add = try #require(done.steps.first { if case .addAssets = $0.operation { true } else { false } })
        #expect(add.state == .failed(reason: "album no longer exists"))
        #expect(done.record?.media[add.id]?.isEmpty ?? true)
        #expect(done.record?.unverified.contains(add.id) != true)
        #expect(done.status == .completedWithErrors)
    }

    /// The same for taking photos out of an album (undo, "Album entfernen").
    @Test func anAlbumDeletedWhileRemovingClaimsNothing() async throws {
        let base = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["x", "y"])])
        let lib = DeletesAfterWrite(base, album: "sommer")
        let done = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(removalPlan("sommer", ["x"]))
        #expect(done.steps[0].state == .failed(reason: "album no longer exists"))
        #expect(done.record?.media["r0"]?.isEmpty ?? true)
    }

    /// An interrupted removal, settled before an undo: what is out of the album counts as done
    /// and is recorded; with nothing taken out, the step stays not done.
    @Test func anInterruptedRemovalIsSettledByWhatLeftTheAlbum() async throws {
        for applied in [true, false] {
            let lib = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["x", "y"])])
            let store = InMemoryPlanStore()
            await lib.setFailAfterWrites(0, afterApplying: applied)
            _ = try await ChangeExecutor(library: lib, store: store).execute(removalPlan("sommer", ["x"]))
            await lib.setFailAfterWrites(nil)
            let crashed = try #require(await store.saved.last { if case .running = $0.steps[0].state { true } else { false } })
            let settled = try await ChangeExecutor(library: lib, store: store).reconcileInterrupted(crashed)
            if applied {
                #expect({ if case .succeeded = settled.steps[0].state { true } else { false } }(), "applied")
                #expect(settled.record?.media["r0"] == ["x"])
            } else {
                #expect(settled.steps[0].state == .failed(reason: "interrupted"), "not applied")
            }
        }
    }
}

/// Deletes one album right after the first write to it reached the library, as if the user
/// deleted it in Photos at that moment.
actor DeletesAfterWrite: PhotoLibraryWriting {
    let base: InMemoryPhotoLibrary
    let album: CollectionID
    init(_ base: InMemoryPhotoLibrary, album: CollectionID) { self.base = base; self.album = album }

    func canWrite() async -> Bool { await base.canWrite() }
    func currentInventory() async throws -> CollectionInventory { try await base.currentInventory() }
    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await base.availableAssets(ids) }
    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await base.createFolder(title: title, parent: parent) }
    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID { try await base.createAlbum(title: title, parent: parent) }
    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws {
        try await base.addAssets(assets, to: album)
        if album == self.album { try await base.deleteCollection(album) }
    }
    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws {
        try await base.removeAssets(assets, from: album)
        if album == self.album { try await base.deleteCollection(album) }
    }
    func renameCollection(_ id: CollectionID, to title: String) async throws { try await base.renameCollection(id, to: title) }
    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        try await base.moveCollection(id, from: oldParent, to: newParent)
    }
    func deleteCollection(_ id: CollectionID) async throws { try await base.deleteCollection(id) }
    func deleteCollections(_ ids: [CollectionID]) async throws { try await base.deleteCollections(ids) }
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await base.collection(id) }
}
