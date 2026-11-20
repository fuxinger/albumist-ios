import Foundation
import Testing
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Second review of P2-01 (S1): the id of a new album is written into the stored plan from
/// inside the change that makes it (`ChangePlanStoring.noteCreated`). Photos may run that change
/// only after the run stopped waiting for it (`PhotosDeadline`). The ways out "Fortsetzen",
/// "Alles rückgängig machen" and "So lassen" then start from the copy of the plan the app read
/// before, without the id. Before, they took the album over by its name (adopted: never
/// removed by undo, kept as the user's), and the next save of that copy replaced the stored
/// plan and lost the id. Now the executor reads the noted ids back before it decides, and no
/// save loses one.
@Suite("A new album's id written down after the run stopped waiting (S1)", .serialized)
struct LateNoteWaysOutTests {
    /// Photos that runs the change making the album titled `late` only after the run gave up
    /// waiting for it: the run gets `PhotosNotResponding`, and the change block (which hears the
    /// new id and waits while Albumist writes it down) runs when `runLateChange()` is called.
    actor LatePhotos: PhotoLibraryWriting {
        let base: InMemoryPhotoLibrary
        let late: String
        static let lateID = CollectionID("late-album")
        private var pending: (title: String, parent: CollectionID?, noted: @Sendable (CollectionID) async -> Void)?
        private var answered: Set<CollectionID> = []

        init(_ base: InMemoryPhotoLibrary, late: String) {
            self.base = base
            self.late = late
        }

        /// Photos runs the change now: Albumist hears the id inside it, then the album is there.
        func runLateChange() async {
            guard let change = pending else { return }
            pending = nil
            await change.noted(Self.lateID)
            await base.userEdit { inventory in
                inventory.upsert(CollectionSnapshot(id: Self.lateID, title: change.title, kind: .userAlbum, parentID: change.parent))
                if let parent = change.parent, var p = inventory[parent] { p.childIDs.append(Self.lateID); inventory.upsert(p) }
            }
            answered.insert(Self.lateID)
        }

        func hasUnansweredWrites() async -> Bool { pending != nil }
        func createAnswered(_ id: CollectionID) async -> Bool { answered.contains(id) }

        func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            guard title == late, !answered.contains(Self.lateID) else {
                return try await base.createAlbum(title: title, parent: parent, noted: noted)
            }
            pending = (title, parent, noted)
            throw PhotosNotResponding(lane: .write, what: "createAlbum", notSent: false)
        }
        func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await base.createFolder(title: title, parent: parent, noted: noted)
        }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
            try await createAlbum(title: title, parent: parent, noted: { _ in })
        }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
            try await base.createFolder(title: title, parent: parent)
        }
        func canWrite() async -> Bool { await base.canWrite() }
        func currentInventory() async throws -> CollectionInventory { try await base.currentInventory() }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await base.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await base.collection(id) }
        func addAssets(_ assets: [AssetID], to album: CollectionID) async throws { try await base.addAssets(assets, to: album) }
        func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await base.removeAssets(assets, from: album) }
        func renameCollection(_ id: CollectionID, to title: String) async throws { try await base.renameCollection(id, to: title) }
        func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
            try await base.moveCollection(id, from: oldParent, to: newParent)
        }
        func deleteCollection(_ id: CollectionID) async throws { try await base.deleteCollection(id) }
        func deleteCollections(_ ids: [CollectionID]) async throws { try await base.deleteCollections(ids) }
        func deleteCollections(_ ids: [CollectionID], onlyHolding allowed: [CollectionID: Set<AssetID>]) async throws {
            try await base.deleteCollections(ids, onlyHolding: allowed)
        }
    }

    /// The database, looked at after every write: whether the stored plan still holds the late
    /// album's id. Once written down it must stay in every version after it.
    actor WatchedJournal: PlanJournal {
        let inner: SortlyStore
        let planID: SortlyID
        private(set) var holdsLateID: [Bool] = []
        init(_ inner: SortlyStore, planID: SortlyID) {
            self.inner = inner
            self.planID = planID
        }
        private func look() async throws {
            let stored = try await inner.plan(planID)
            holdsLateID.append(stored?.record?.maybeCreated.values.contains(LatePhotos.lateID) == true)
        }
        func save(_ plan: ChangePlan) async throws { try await inner.save(plan); try await look() }
        func save(_ plans: [ChangePlan]) async throws { try await inner.save(plans); try await look() }
        func noteCreated(_ id: CollectionID, key: String, in plan: ChangePlan) async throws {
            try await inner.noteCreated(id, key: key, in: plan)
            try await look()
        }
        func withNotedIDs(_ plan: ChangePlan) async throws -> ChangePlan { try await inner.withNotedIDs(plan) }
        func plan(_ id: SortlyID) async throws -> ChangePlan? { try await inner.plan(id) }

        /// Never lost once written down: after the first version that holds it, every one does.
        var neverLost: Bool {
            guard let first = holdsLateID.firstIndex(of: true) else { return false }
            return holdsLateID[first...].allSatisfy { $0 }
        }
    }

    struct Setup {
        let lib: InMemoryPhotoLibrary
        let photos: LatePhotos
        let store: SortlyStore
        let journal: WatchedJournal
        /// The interrupted plan as the app read it once the run stopped: without the id.
        let stale: ChangePlan
        let key: String
    }

    /// A folder "Reisen" with a new album "Reise": Photos makes "Reise" only after the run gave
    /// up waiting, and the app has read the interrupted plan before.
    func interrupted() async throws -> Setup {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y", "o"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["o"])])
        var plan = OrganizationPlanner(rootFolderTitle: "").makePlan(from: [ConfirmedProposal(
            proposal: AlbumProposal(id: SortlyID("reise"), kind: .trip, title: "Reise", folderPath: ["Reisen"], assetIDs: ["x", "y"]),
            decision: .createNew(title: nil, folderPath: nil))], inventory: try await lib.currentInventory())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let key = try #require(plan.steps.lazy.compactMap { step -> String? in
            if case .createAlbum(let key, _, _) = step.operation { return key }
            return nil
        }.first)
        let store = try SortlyStore(url: nil)
        let journal = WatchedJournal(store, planID: plan.id)
        let photos = LatePhotos(lib, late: "Reise")
        await #expect(throws: PhotosNotResponding.self) {
            try await ChangeExecutor(library: photos, store: journal).execute(plan)
        }
        // The app reads the interrupted plan to offer the ways out (`reloadInterruptedPlan`).
        let stale = try #require(try await store.openInterruptedPlan())
        #expect(stale.record?.maybeCreated[key] == nil)
        // Photos runs the change now: the id is written into the stored plan, not the copy.
        await photos.runLateChange()
        #expect(try await store.plan(plan.id)?.record?.maybeCreated[key] == LatePhotos.lateID)
        #expect(try await albums(lib, "Reise").map(\.id) == [LatePhotos.lateID])
        return Setup(lib: lib, photos: photos, store: store, journal: journal, stale: stale, key: key)
    }

    func albums(_ lib: InMemoryPhotoLibrary, _ title: String) async throws -> [CollectionSnapshot] {
        try await lib.currentInventory().collections.values.filter { $0.title == title }
    }

    /// Undo of a plan as the history offers it: everything Albumist made goes.
    func expectUndoRemovesAll(_ applied: ChangePlan, _ s: Setup) async throws {
        var undo = UndoPlanner().undoPlan(for: applied, current: try await s.lib.currentInventory())
        undo.status = .confirmed
        undo.confirmedAt = Date()
        let undone = try await ChangeExecutor(library: s.lib, store: s.journal).execute(undo)
        #expect(undone.status == .completed, "\(undone.steps.map(\.state))")
        #expect(try await albums(s.lib, "Reise").isEmpty)
        #expect(try await albums(s.lib, "Reisen").isEmpty)
    }

    /// "Fortsetzen" with the copy: the late album is this plan's own (made, not adopted), filled,
    /// not made a second time, and undo removes it.
    @Test func resumeWithTheStaleCopyTakesTheLateAlbumAsMade() async throws {
        let s = try await interrupted()
        let resumed = try await ChangeExecutor(library: s.photos, store: s.journal).execute(s.stale)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(resumed.resolvedKeys[s.key] == LatePhotos.lateID)
        #expect(resumed.record?.adoptedKeys.isEmpty == true)
        #expect(try await albums(s.lib, "Reise").map(\.id) == [LatePhotos.lateID])
        #expect(try await albums(s.lib, "Reise").first?.assetIDs == ["x", "y"])
        #expect(try await s.store.plan(s.stale.id)?.record?.maybeCreated[s.key] == LatePhotos.lateID)
        let versions = await s.journal.holdsLateID
        #expect(await s.journal.neverLost, "\(versions)")
        try await expectUndoRemovesAll(resumed, s)
    }

    /// "Alles rückgängig machen" with the copy: the late album goes with everything else, nothing is
    /// named as left, and the plan is cancelled.
    @Test func undoWithTheStaleCopyRemovesTheLateAlbum() async throws {
        let s = try await interrupted()
        let settled = try await ChangeExecutor(library: s.photos, store: s.journal).reconcileInterrupted(s.stale)
        #expect(settled.resolvedKeys[s.key] == LatePhotos.lateID)
        #expect(settled.record?.adoptedKeys.isEmpty == true)
        let way = InterruptedPlanUndo(settled: settled, current: try await s.lib.currentInventory())
        #expect(way.remainder.isEmpty)
        let lib = s.lib, journal = s.journal
        let outcome = try await way.carryOut(journal: journal, finalize: { _ in true }, run: { undo in
            _ = try? await ChangeExecutor(library: lib, store: journal).execute(undo)
        })
        #expect(outcome == .undone)
        #expect(try await albums(s.lib, "Reise").isEmpty)
        #expect(try await albums(s.lib, "Reisen").isEmpty)
        let stored = try #require(try await s.store.plan(s.stale.id))
        #expect(stored.status == .cancelled)
        #expect(stored.record?.maybeCreated[s.key] == LatePhotos.lateID)
        let versions = await s.journal.holdsLateID
        #expect(await s.journal.neverLost, "\(versions)")
    }

    /// "So lassen" with the copy: the late album is recorded as Albumist's (made, not adopted),
    /// the plan stays in the history, and its undo later removes the album.
    @Test func keepWithTheStaleCopyRecordsTheLateAlbumAsMade() async throws {
        let s = try await interrupted()
        let settled = try await ChangeExecutor(library: s.photos, store: s.journal).reconcileInterrupted(s.stale, keeping: true)
        let kept = settled.keptAsIs(current: try await s.lib.currentInventory())
        try await s.journal.save(kept)
        #expect(kept.status == .completedWithErrors)
        #expect(kept.resolvedKeys[s.key] == LatePhotos.lateID)
        #expect(kept.record?.adoptedKeys.isEmpty == true)
        let managed = ManagedAlbumTracker().record(kept, into: [], inventory: try await s.lib.currentInventory())
        #expect(managed.first { $0.albumID == LatePhotos.lateID }?.createdBySortly == true)
        let stored = try #require(try await s.store.plan(s.stale.id))
        #expect(stored.record?.maybeCreated[s.key] == LatePhotos.lateID)
        let versions = await s.journal.holdsLateID
        #expect(await s.journal.neverLost, "\(versions)")
        try await expectUndoRemovesAll(stored, s)
    }
}
