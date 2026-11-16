import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// The album check the app runs before every plan and when the overview refreshes (review of
/// 6c6ef79, point 7): what it records does not depend on whether the results of a plan that
/// finished right before the app ended were stored before it ran (the order at launch, plugin
/// review W2). A real deletion is still recorded, a limited library compares nothing, and an
/// album only the album list lacks is looked up on its own (W3).
@Suite("Album check before planning")
struct ManagedAlbumCheckTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)

    func photos(_ range: Range<Int>) -> Set<AssetID> { Set(range.map { AssetID("a-\($0)") }) }

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    func newAlbum(_ id: String, _ title: String, _ assets: Set<AssetID>) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: SortlyID(id), kind: .trip, title: title, folderPath: ["Reisen"], assetIDs: assets),
                          decision: .createNew(title: nil, folderPath: nil))
    }

    /// The app's run: the plan goes on the list of plans to finalize, then it is executed.
    func run(_ plan: ChangePlan, in store: SortlyStore, library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        var pending = try await store.value([SortlyID].self, forKey: SortlyStore.pendingFinalizationKey) ?? []
        if !pending.contains(plan.id) { pending.append(plan.id) }
        try await store.setValue(pending, forKey: SortlyStore.pendingFinalizationKey)
        return try await ChangeExecutor(library: library, store: store).execute(plan)
    }

    /// What the app's finalization stores, in one transaction.
    func finalize(_ plan: ChangePlan, in store: SortlyStore, library: InMemoryPhotoLibrary) async throws {
        var done = plan
        done.finalizedAt = Date()
        let states = ManagedAlbumTracker().record(plan, into: try await store.managedAlbums(), inventory: try await library.currentInventory())
        let pending = (try await store.value([SortlyID].self, forKey: SortlyStore.pendingFinalizationKey) ?? []).filter { $0 != plan.id }
        try await store.finalize(done, managedAlbums: states, values: [SortlyStore.pendingFinalizationKey: pending])
    }

    /// "Paris" and "Rom" in "Reisen", made and recorded as Albumist's.
    func parisAndRomeRecorded(_ store: SortlyStore, _ library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        let plan = confirmed(planner.makePlan(from: [newAlbum("p", "Paris", photos(10..<20)), newAlbum("r", "Rom", photos(0..<10))],
                                              inventory: try await library.currentInventory()))
        let executed = try await run(plan, in: store, library: library)
        #expect(executed.status == .completed)
        try await finalize(executed, in: store, library: library)
        #expect(Set(try await store.managedAlbums().map(\.lastKnownTitle)) == ["Paris", "Rom"])
        return executed
    }

    /// Their undo ran, and the app ended before its results were stored: at the next launch it
    /// waits on the list of plans to finalize.
    func undoAwaitingItsResults(_ store: SortlyStore, _ library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        let executed = try await parisAndRomeRecorded(store, library)
        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in try await store.managedAlbums() { owned[state.albumID, default: []].formUnion(state.addedBySortly) }
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory(), owned: owned))
        let undone = try await run(undo, in: store, library: library)
        #expect(undone.status == .completed)
        #expect(try await library.currentInventory().collections.isEmpty)
        #expect(try await store.awaitsFinalization(undone.id))
        return undone
    }

    /// Whichever comes first at launch, the album check or storing the results of the undo
    /// that finished right before the app ended, Paris and Rom never count as deleted by the
    /// user (their suggestions would never come back), and nothing else is recorded.
    @Test(arguments: [false, true])
    func checkAnswersTheSameBeforeAndAfterAPlansResultsAreStored(resultsFirst: Bool) async throws {
        let store = try SortlyStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        let undone = try await undoAwaitingItsResults(store, library)
        let check = ManagedAlbumCheck(store: store, library: library, pause: .zero)

        if resultsFirst { try await finalize(undone, in: store, library: library) }
        let first = try await check.run(access: .full)
        #expect(!first.foundChanges)
        #expect(try await store.overrides().isEmpty)
        if !resultsFirst {
            // Left alone until the undo is settled, not taken for the user's deletion.
            #expect(Set(first.managedAlbums.map(\.lastKnownTitle)) == ["Paris", "Rom"])
            try await finalize(undone, in: store, library: library)
        }
        let second = try await check.run(access: .full)
        #expect(!second.foundChanges)
        #expect(second.managedAlbums.isEmpty)
        #expect(try await store.overrides().isEmpty)
        #expect(try await store.managedAlbums().isEmpty)
    }

    /// The user deleted "Rom" in Photos and renamed "Paris": both are recorded, Rom for good
    /// (its suggestion is not made again), and stored with the new records in one go.
    @Test func whatTheUserChangedIsRecorded() async throws {
        let store = try SortlyStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        _ = try await parisAndRomeRecorded(store, library)
        let states = try await store.managedAlbums()
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" })
        let paris = try #require(states.first { $0.lastKnownTitle == "Paris" })
        await library.userEdit { inv in
            inv.remove(rome.albumID)
            var album = inv[paris.albumID]!
            album.title = "Paris 2026"
            inv.upsert(album)
        }

        let outcome = try await ManagedAlbumCheck(store: store, library: library, pause: .zero).run(access: .full)
        #expect(outcome.foundChanges)
        #expect(outcome.managedAlbums.map(\.lastKnownTitle) == ["Paris 2026"])
        #expect(try await store.managedAlbums() == outcome.managedAlbums)
        let overrides = try await store.overrides()
        #expect(overrides.map(\.scope) == [.source(rome.sourceID)])
        #expect(overrides.allSatisfy { $0.decision == .doNotRecreateAlbum })
        #expect(outcome.inventory[paris.albumID]?.title == "Paris 2026")
    }

    /// With access to some photos only, albums and photos Albumist cannot see would look
    /// deleted: nothing is compared or recorded.
    @Test func limitedAccessComparesNothing() async throws {
        let store = try SortlyStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        _ = try await parisAndRomeRecorded(store, library)
        let states = try await store.managedAlbums()
        await library.userEdit { inv in for state in states { inv.remove(state.albumID) } }

        for access in [LibraryAccess.limited, .denied] {
            let outcome = try await ManagedAlbumCheck(store: store, library: library, pause: .zero).run(access: access)
            #expect(!outcome.foundChanges)
            #expect(outcome.managedAlbums == states)
        }
        #expect(try await store.overrides().isEmpty)
        #expect(try await store.managedAlbums() == states)
    }

    /// The album list lacks "Rom" (iCloud still syncing after a restore), Photos still has it:
    /// it is looked up on its own, nothing is recorded, and the list planning works with has it.
    @Test func albumOnlyTheListLacksIsLookedUpOnItsOwn() async throws {
        let store = try SortlyStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        _ = try await parisAndRomeRecorded(store, library)
        let states = try await store.managedAlbums()
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" })

        let outcome = try await ManagedAlbumCheck(store: store, library: ListLacking(inner: library, missing: [rome.albumID]), pause: .zero)
            .run(access: .full)
        #expect(!outcome.foundChanges)
        #expect(outcome.inventory[rome.albumID]?.assetIDs == photos(0..<10))
        #expect(try await store.overrides().isEmpty)
        #expect(try await store.managedAlbums() == states)
    }

    /// The in-memory library with an album list that lacks some albums; they can still be read
    /// one by one.
    struct ListLacking: PhotoLibraryWriting {
        let inner: InMemoryPhotoLibrary
        let missing: Set<CollectionID>
        func canWrite() async -> Bool { await inner.canWrite() }
        func currentInventory() async throws -> CollectionInventory {
            var inventory = try await inner.currentInventory()
            for id in missing { inventory.remove(id) }
            return inventory
        }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await inner.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await inner.collection(id) }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createFolder(title: title, parent: parent) }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createAlbum(title: title, parent: parent) }
        func addAssets(_ assets: [AssetID], to album: CollectionID) async throws { try await inner.addAssets(assets, to: album) }
        func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await inner.removeAssets(assets, from: album) }
        func renameCollection(_ id: CollectionID, to title: String) async throws { try await inner.renameCollection(id, to: title) }
        func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
            try await inner.moveCollection(id, from: oldParent, to: newParent)
        }
        func deleteCollection(_ id: CollectionID) async throws { try await inner.deleteCollection(id) }
        func deleteCollections(_ ids: [CollectionID]) async throws { try await inner.deleteCollections(ids) }
    }

    // MARK: N7 A plan finishes while the check runs

    /// The album list lacks "Paris", so the check looks it up on its own; while it waits, a
    /// plan finishes and stores its new album "Wien". The check started from the older records
    /// and must not write them over Wien (plugin review N7): it compares once more.
    @Test func checkOvertakenByAPlanDoesNotOverwriteItsAlbums() async throws {
        let store = try SortlyStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<100))
        _ = try await parisAndRomeRecorded(store, library)
        let records = try await store.managedAlbums()
        let paris = try #require(records.first { $0.lastKnownTitle == "Paris" }).albumID
        let rome = try #require(records.first { $0.lastKnownTitle == "Rom" }).albumID
        // The user took a photo out of Rom: a change the check stores.
        await library.userEdit { inv in
            var r = inv[rome]!
            r.assetIDs.remove(AssetID("a-0"))
            inv.upsert(r)
            inv.upsert(CollectionSnapshot(id: "wien", title: "Wien", assetIDs: [AssetID("a-50")]))
        }
        let wien = ManagedAlbumState(albumID: "wien", sourceID: SortlyID("w"), lastKnownTitle: "Wien", lastKnownParentID: nil,
                                     lastKnownMembers: [AssetID("a-50")], addedBySortly: [AssetID("a-50")], createdBySortly: true)
        let overtaking = OvertakingLibrary(inner: library, hidden: [paris]) {
            try? await store.saveManagedAlbums(try await store.managedAlbums() + [wien])
        }
        let outcome = try await ManagedAlbumCheck(store: store, library: overtaking, pause: .milliseconds(1)).run(access: .full)
        #expect(outcome.foundChanges)
        #expect(outcome.managedAlbums.contains { $0.albumID == "wien" })
        #expect(try await store.managedAlbums().contains(wien))
        #expect(try await store.managedAlbums().first { $0.albumID == rome }?.lastKnownMembers.contains(AssetID("a-0")) == false)
        #expect(try await store.overrides().contains { $0.scope == .assetInAlbum(AssetID("a-0"), rome) })
    }
}

/// Lacks some albums in the list (they are there when asked for on their own); the first such
/// lookup runs `meanwhile` (a plan that finishes while the check waits for Photos).
struct OvertakingLibrary: PhotoLibraryWriting {
    let inner: InMemoryPhotoLibrary
    let hidden: Set<CollectionID>
    let meanwhile: @Sendable () async -> Void
    let once = Once()

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }

    func canWrite() async -> Bool { await inner.canWrite() }
    func currentInventory() async throws -> CollectionInventory {
        var inventory = try await inner.currentInventory()
        for id in hidden { inventory.remove(id) }
        return inventory
    }
    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await inner.availableAssets(ids) }
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        if hidden.contains(id), once.take() { await meanwhile() }
        return try await inner.collection(id)
    }
    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createFolder(title: title, parent: parent) }
    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createAlbum(title: title, parent: parent) }
    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws { try await inner.addAssets(assets, to: album) }
    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await inner.removeAssets(assets, from: album) }
    func renameCollection(_ id: CollectionID, to title: String) async throws { try await inner.renameCollection(id, to: title) }
    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        try await inner.moveCollection(id, from: oldParent, to: newParent)
    }
    func deleteCollection(_ id: CollectionID) async throws { try await inner.deleteCollection(id) }
    func deleteCollections(_ ids: [CollectionID]) async throws { try await inner.deleteCollections(ids) }
}
