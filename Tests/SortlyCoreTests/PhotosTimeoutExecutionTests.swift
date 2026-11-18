import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// App-speed (18.11.2026, docs/DECISIONS.md): a change request Photos does not answer in time
/// (`PhotosNotResponding`) is neither done nor undone. Photos may still carry it out, so the
/// plan stops at that step with the step journaled as running, like a step the app was closed
/// in; continuing or taking the plan back then settles it from what the library shows.
@Suite("Writes Photos did not answer")
struct PhotosTimeoutExecutionTests {
    /// Photos that does not answer one kind of write in time: the change lands (late) or not,
    /// and the caller gets `PhotosNotResponding` either way. Every later call goes through.
    actor SlowPhotos: PhotoLibraryWriting {
        let base: InMemoryPhotoLibrary
        var stalls: String?
        var lands: Bool

        init(_ base: InMemoryPhotoLibrary, stalls: String, lands: Bool) {
            self.base = base
            self.stalls = stalls
            self.lands = lands
        }

        private func stall<T>(_ what: String, _ write: () async throws -> T) async throws -> T {
            guard stalls == what else { return try await write() }
            stalls = nil
            if lands { _ = try await write() }
            throw PhotosNotResponding(lane: .write, what: what, notSent: false)
        }

        func canWrite() async -> Bool { await base.canWrite() }
        func currentInventory() async throws -> CollectionInventory { try await base.currentInventory() }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await base.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await base.collection(id) }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
            try await stall("createFolder") { try await base.createFolder(title: title, parent: parent) }
        }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
            try await stall("createAlbum") { try await base.createAlbum(title: title, parent: parent) }
        }
        func addAssets(_ assets: [AssetID], to album: CollectionID) async throws {
            try await stall("addAssets") { try await base.addAssets(assets, to: album) }
        }
        func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws {
            try await stall("removeAssets") { try await base.removeAssets(assets, from: album) }
        }
        func renameCollection(_ id: CollectionID, to title: String) async throws {
            try await stall("rename") { try await base.renameCollection(id, to: title) }
        }
        func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
            try await stall("move") { try await base.moveCollection(id, from: oldParent, to: newParent) }
        }
        func deleteCollection(_ id: CollectionID) async throws {
            try await stall("delete") { try await base.deleteCollection(id) }
        }
        func deleteCollections(_ ids: [CollectionID]) async throws {
            try await stall("delete") { try await base.deleteCollections(ids) }
        }
    }

    private func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan; p.confirmedAt = Date(); p.status = .confirmed; return p
    }
    private func running(_ state: StepState) -> Bool { if case .running = state { return true }; return false }
    private func succeeded(_ state: StepState) -> Bool { if case .succeeded = state { return true }; return false }

    /// A new album "Reise" with x and y.
    private func setup() async throws -> (InMemoryPhotoLibrary, ChangePlan) {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y", "o"],
                                       collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["o"])])
        let proposals = [ConfirmedProposal(
            proposal: AlbumProposal(id: SortlyID("reise"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x", "y"]),
            decision: .createNew(title: nil, folderPath: nil))]
        return (lib, confirmed(OrganizationPlanner().makePlan(from: proposals, inventory: try await lib.currentInventory())))
    }

    /// The new album's planned key.
    private func albumKey(_ plan: ChangePlan) throws -> String {
        try #require(plan.steps.lazy.compactMap { step -> String? in
            if case .createAlbum(let key, _, _) = step.operation { return key }
            return nil
        }.first)
    }

    private func albums(_ lib: InMemoryPhotoLibrary, titled title: String) async throws -> [CollectionSnapshot] {
        try await lib.currentInventory().albums.filter { $0.title == title }
    }

    /// The run stops at the step, which stays running in the journal; nothing counts as done.
    private func stopped(_ plan: ChangePlan, on photos: SlowPhotos, _ store: InMemoryPlanStore) async throws -> ChangePlan {
        await #expect(throws: PhotosNotResponding.self) {
            try await ChangeExecutor(library: photos, store: store).execute(plan)
        }
        let journal = try #require(await store.latest)
        #expect(journal.status == .running)
        #expect(journal.steps.contains { running($0.state) })
        #expect(journal.steps.contains { !$0.state.isFinished })
        return journal
    }

    @Test(arguments: [true, false])
    func addThatTimedOutIsSettledWhenThePlanGoesOn(landed: Bool) async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let journal = try await stopped(plan, on: SlowPhotos(lib, stalls: "addAssets", lands: landed), store)
        let add = try #require(journal.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } })
        #expect(running(journal.steps[add].state))
        #expect(journal.appliedAssets.isEmpty)

        // "Fortsetzen" once Photos answers again: settled from the library, nothing twice.
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").map(\.assetIDs) == [["x", "y"]])
        #expect(resumed.appliedAssets == ["x", "y"])
    }

    /// The album came late: taken over, never made a second time; marked as found, so an undo
    /// leaves it alone (`adoptionCandidate`, the same rule as after the app was closed).
    @Test func albumThatCameLateIsNotMadeTwice() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let journal = try await stopped(plan, on: SlowPhotos(lib, stalls: "createAlbum", lands: true), store)
        #expect(journal.resolvedKeys[try albumKey(journal)] == nil)
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").count == 1)
        #expect(resumed.record?.adoptedKeys.isEmpty == false)
    }

    /// Taking a plan back: a deletion Photos did not answer is not "rückgängig gemacht". What
    /// goes stays written down (it can still be brought back), and the plan stays open.
    @Test(arguments: [true, false])
    func undoThatTimedOutIsNotUndone(landed: Bool) async throws {
        let (lib, plan) = try await setup()
        let applied = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        #expect(applied.status == .completed)
        let undo = confirmed(UndoPlanner().undoPlan(for: applied, current: try await lib.currentInventory()))
        let store = InMemoryPlanStore()
        let journal = try await stopped(undo, on: SlowPhotos(lib, stalls: "delete", lands: landed), store)
        let reise = try #require(applied.resolvedKeys[try albumKey(applied)])
        let delete = try #require(journal.steps.firstIndex { if case .deleteCollection = $0.operation { true } else { false } })
        #expect(running(journal.steps[delete].state))
        #expect(journal.record?.deletedAlbums[reise] != nil)

        let settled = try await ChangeExecutor(library: lib, store: store).reconcileInterrupted(journal)
        if landed {
            #expect(succeeded(settled.steps[delete].state))
        } else {
            #expect(!succeeded(settled.steps[delete].state))
            #expect(try await albums(lib, titled: "Reise").count == 1)
        }
    }
}
