import Foundation
import Testing
@testable import AlbumistStore
import AlbumistCore
import AlbumistTestSupport

/// Albumist's own changes that are not stored yet are never the user's decisions (plugin
/// review W2). At launch the album check used to run before plans that had finished but were
/// not finalized were stored: an undo cut off during its finalization made the albums it had
/// deleted look deleted by the user, and their suggestions never came back.
@Suite("Albums Albumist's own plans may still be changing")
struct InFlightAlbumsTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)

    func photos(_ range: Range<Int>) -> Set<AssetID> { Set(range.map { AssetID("a-\($0)") }) }

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    /// "Rom" in "Reisen", made by a plan whose results are stored.
    func romeStored(in store: AlbumistStore, library: InMemoryPhotoLibrary) async throws -> (executed: ChangePlan, states: [ManagedAlbumState]) {
        let proposal = AlbumProposal(id: AlbumistID("r"), kind: .trip, title: "Rom", folderPath: ["Reisen"], assetIDs: photos(0..<10))
        let plan = confirmed(planner.makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))],
                                              inventory: try await library.currentInventory()))
        var executed = try await ChangeExecutor(library: library, store: store).execute(plan)
        #expect(executed.status == .completed)
        let states = ManagedAlbumTracker().record(executed, into: [], inventory: try await library.currentInventory())
        executed.finalizedAt = Date()
        try await store.finalize(executed, managedAlbums: states, values: [AlbumistStore.pendingFinalizationKey: [AlbumistID]()])
        return (executed, states)
    }

    /// The undo deleted "Rom" in Photos, and the app ended before the undo's results were
    /// stored. Until it is finalized, its albums are left alone by the album check; finalized
    /// first (the order at launch now), nothing is left that could be taken for the user's doing.
    @Test func undoCutOffBeforeItsResultsWereStoredIsNotTheUsersDeletion() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        let (executed, states) = try await romeStored(in: store, library: library)
        #expect(try await store.collectionsInFlight().isEmpty)

        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        try await store.setValue([undo.id], forKey: AlbumistStore.pendingFinalizationKey)
        let undone = try await ChangeExecutor(library: library, store: store).execute(undo)
        #expect(undone.status == .completed)
        let now = try await library.currentInventory()
        #expect(now.collections.isEmpty)

        let stored = try await store.managedAlbums()
        #expect(stored == states)
        let rome = try #require(states.first?.albumID)
        let inFlight = try await store.collectionsInFlight()
        #expect(inFlight.contains(rome))
        let tracker = ManagedAlbumTracker()
        // Compared without knowing about the undo, Rom counts as deleted by the user for good.
        #expect(tracker.reconcile(stored, with: now).newOverrides.contains { $0.decision == .doNotRecreateAlbum })
        let careful = tracker.reconcile(stored, with: now, changing: inFlight)
        #expect(careful.changes.isEmpty)
        #expect(careful.newOverrides.isEmpty)
        #expect(careful.updatedStates == stored)

        // The undo is finalized first: Rom is no longer Albumist's, and nothing is recorded.
        var done = undone
        done.finalizedAt = Date()
        let after = tracker.record(done, into: stored, inventory: now)
        #expect(after.isEmpty)
        try await store.finalize(done, managedAlbums: after, values: [AlbumistStore.pendingFinalizationKey: [AlbumistID]()])
        #expect(try await store.collectionsInFlight().isEmpty)
        #expect(tracker.reconcile(try await store.managedAlbums(), with: now).newOverrides.isEmpty)
    }

    /// A plan that was cut off (offered to continue or take back) counts as well, and a plan on
    /// the list that is already finalized, cancelled or gone does not.
    @Test func interruptedPlanCountsFinishedOnesDoNot() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50),
                                           collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: photos(40..<45))])
        let (executed, _) = try await romeStored(in: store, library: library)
        let proposal = AlbumProposal(id: AlbumistID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: photos(20..<30))
        var cutOff = confirmed(planner.makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("sommer"))],
                                                inventory: try await library.currentInventory()))
        cutOff.status = .running
        try await store.save(cutOff)
        var dropped = cutOff
        dropped.id = AlbumistID("dropped")
        dropped.status = .cancelled
        dropped.steps = [PlanStep(id: "d0", operation: .addAssets(album: .existing("elsewhere"), assets: []), sourceID: nil)]
        try await store.save(dropped)
        try await store.setValue([executed.id, dropped.id, AlbumistID("gone")], forKey: AlbumistStore.pendingFinalizationKey)

        #expect(try await store.collectionsInFlight() == ["sommer"])
    }
}
