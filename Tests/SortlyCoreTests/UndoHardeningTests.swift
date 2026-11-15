import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Writing to Photos and taking it back, hardened after the first iPhone test (15.11.):
/// interruptions at the worst moment, deletions Photos does not carry out, undo that must
/// not leave anything behind.
@Suite("Writing to Photos and undo, hardened")
struct UndoHardeningTests {
    let planner = OrganizationPlanner(rootFolderTitle: "Albumist", chunkSize: 50)
    let allAssets: Set<AssetID> = ids("a", 0..<300)

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    func newAlbum(_ id: String, _ title: String, _ path: [String], _ assets: Set<AssetID>) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: SortlyID(id), kind: .trip, title: title, folderPath: path, assetIDs: assets),
                          decision: .createNew(title: nil, folderPath: nil))
    }

    /// The app ends at a chosen save: everything saved before it is what the next launch finds.
    actor EndingPlanStore: ChangePlanStoring {
        struct Ended: Error {}
        private(set) var saved: [ChangePlan] = []
        private var ended = false
        private let endsAt: @Sendable (ChangePlan) -> Bool
        init(endsAt: @escaping @Sendable (ChangePlan) -> Bool) { self.endsAt = endsAt }
        func save(_ plan: ChangePlan) async throws {
            if !ended, endsAt(plan) {
                ended = true
                throw Ended()
            }
            saved.append(plan)
        }
    }

    // MARK: Interruption right after Photos created an album

    /// Photos created the album and returned its id, Albumist wrote the id down, and the app
    /// ended before the step was marked done. Resuming must take that album, not make a
    /// second one next to it, and undo must still remove it (it is provably Albumist's).
    @Test func resumeAfterTheAppEndedRightAfterCreatingDoesNotMakeASecondAlbum() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let plan = confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ["Reisen"], ids("a", 0..<10))],
                                              inventory: try await library.currentInventory()))
        let store = EndingPlanStore { plan in
            plan.steps.contains { step in
                if case .createAlbum = step.operation, case .succeeded = step.state { return true }
                return false
            }
        }
        await #expect(throws: EndingPlanStore.Ended.self) {
            _ = try await ChangeExecutor(library: library, store: store).execute(plan)
        }
        let interrupted = try #require(await store.saved.last)
        let createStep = try #require(interrupted.steps.first { if case .createAlbum = $0.operation { true } else { false } })
        guard case .createAlbum(let key, _, _) = createStep.operation else { return }
        #expect(interrupted.resolvedKeys[key] != nil)
        if case .running = createStep.state {} else { Issue.record("the create step should still be running") }

        let resumed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(interrupted)
        #expect(resumed.status == .completed)
        let albums = try await library.currentInventory().albums.filter { $0.title == "Rom" }
        #expect(albums.count == 1)
        #expect(albums.first?.assetIDs == ids("a", 0..<10))
        #expect(resumed.record?.adoptedKeys.isEmpty == true)

        let undo = confirmed(UndoPlanner().undoPlan(for: resumed, current: try await library.currentInventory()))
        _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)
        #expect(try await library.currentInventory().collections.isEmpty)
        #expect(await library.assets == allAssets)
    }

    /// Same moment, but the interrupted plan is taken back instead: the album counts as
    /// created by Albumist (not merely found), so the undo removes it with its folders.
    @Test func undoOfAPlanInterruptedRightAfterCreatingRemovesTheAlbum() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let plan = confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ["Reisen"], ids("a", 0..<10))],
                                              inventory: try await library.currentInventory()))
        let store = EndingPlanStore { plan in
            plan.steps.contains { step in
                if case .createAlbum = step.operation, case .succeeded = step.state { return true }
                return false
            }
        }
        _ = try? await ChangeExecutor(library: library, store: store).execute(plan)
        let interrupted = try #require(await store.saved.last)
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let settled = try await executor.reconcileInterrupted(interrupted)
        let created = settled.steps.first { if case .createAlbum = $0.operation { true } else { false } }
        if case .succeeded = created?.state {} else { Issue.record("the album Photos created should count as created") }
        #expect(settled.record?.adoptedKeys.isEmpty == true)
        let undo = confirmed(UndoPlanner().undoPlan(for: settled, current: try await library.currentInventory()))
        let undone = try await executor.execute(undo)
        #expect(undone.status == .completed)
        #expect(try await library.currentInventory().collections.isEmpty)
    }

    // MARK: Batch deletion

    /// The user put an own photo into one of the albums after the undo was planned, and then
    /// declined the iOS question. Taking Albumist's photos out of that album needs no
    /// question: it must still happen, and each step must say what really happened.
    @Test func declinedDeletionStillTakesAlbumistsPhotosOutOfAKeptAlbum() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let plan = confirmed(planner.makePlan(from: [
            newAlbum("r", "Rom", ["Reisen"], ids("a", 0..<10)),
            newAlbum("p", "Paris", ["Reisen"], ids("a", 10..<20)),
        ], inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        let paris = try #require(try await library.currentInventory().albums.first { $0.title == "Paris" }?.id)
        await library.userEdit { inv in
            var album = inv[paris]!
            album.assetIDs.insert("a-299")
            inv.upsert(album)
        }
        await library.setDeletionBehavior(.declined, times: 1)
        let undone = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)

        #expect(undone.status == .completedWithErrors)
        let inv = try await library.currentInventory()
        #expect(inv[paris]?.assetIDs == ["a-299"])
        func state(_ title: String) -> StepState? {
            undone.steps.first { if case .deleteCollection(_, title) = $0.operation { true } else { false } }?.state
        }
        #expect(state("Paris") == .skipped(reason: "kept: the album holds photos added meanwhile; only Albumist's photos were taken out"))
        #expect(state("Rom") == .failed(reason: StepState.deletionDeclinedReason))
        #expect(state("Reisen") == .failed(reason: "folder is not empty"))
        #expect(inv.albums.contains { $0.title == "Rom" })
        #expect(undone.record?.deletedAlbums.isEmpty == true)
        #expect(await library.assets == allAssets)
    }

    /// Photos handed out an empty album list for a moment right after the deletion. Albums
    /// missing from such a list are not proof of anything: the list is read again, and if it
    /// stays incomplete, nothing counts as deleted (otherwise the plan would count as undone
    /// for good while its albums are still there).
    @Test(arguments: [1, 2])
    func incompleteReadAfterDeletionIsNotTakenAsProof(blankReads: Int) async throws {
        let own = CollectionSnapshot(id: "familie", title: "Familie", assetIDs: ids("a", 200..<210))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [own])
        let plan = confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ["Reisen"], ids("a", 0..<10))],
                                              inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        // Reads in the undo: before the first step, before the deletion, then the read-back.
        await library.setDeletionBehavior(.silentlyIgnored, times: 1)
        await library.setBlankInventoryReads(blankReads, skipping: 2)
        let undone = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)

        #expect(undone.status == .completedWithErrors)
        let reasons = Set(undone.steps.compactMap { if case .failed(let r) = $0.state { r } else { nil } })
        // Read again once: the second read is complete and shows that nothing went.
        // Incomplete twice: nothing can be said, so nothing counts.
        #expect(reasons == [blankReads == 1 ? StepState.deletionNotAppliedReason : "deletion could not be verified"])
        #expect(undone.record?.deletedAlbums.isEmpty == true)
        #expect(PlanReceipt(plan: undone, inventory: try await library.currentInventory()).containersDeleted == 0)
    }

    // MARK: Moves taken back

    /// A plan moved one of the user's albums into a new folder. Undo moves it back, and the
    /// new folders, empty after that, go as well instead of staying behind.
    @Test func undoOfAMoveRemovesTheFoldersTheAlbumWasMovedInto() async throws {
        let mine = CollectionSnapshot(id: "garten", title: "Garten", assetIDs: ids("a", 0..<5))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [mine])
        let item = ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("g"), kind: .trip, title: "Garten", folderPath: [], assetIDs: ids("a", 0..<5)),
                                     decision: .moveExisting("garten", folderPath: ["Zuhause"], extend: false))
        let plan = confirmed(planner.makePlan(from: [item], inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        #expect(executed.status == .completed)
        #expect(try await library.currentInventory()["garten"]?.parentID != nil)

        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        let undone = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["garten"]?.parentID == nil)
        #expect(inv["garten"]?.assetIDs == ids("a", 0..<5))
        #expect(inv.collections.count == 1)
    }

    /// The folder the album came from was deleted meanwhile. There is no way back, and the
    /// top of the library is not where the user had it: the album stays in place, and so does
    /// the folder that holds it. Nothing is reported as failed.
    @Test func undoDoesNotMoveAnAlbumToTheTopWhenItsFolderIsGone() async throws {
        let folder = CollectionSnapshot(id: "alt", title: "Alt", kind: .folder)
        let mine = CollectionSnapshot(id: "garten", title: "Garten", parentID: "alt", assetIDs: ids("a", 0..<5))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [folder, mine])
        let item = ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("g"), kind: .trip, title: "Garten", folderPath: [], assetIDs: ids("a", 0..<5)),
                                     decision: .moveExisting("garten", folderPath: ["Zuhause"], extend: false))
        let plan = confirmed(planner.makePlan(from: [item], inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        #expect(executed.status == .completed)
        await library.userEdit { $0.remove("alt") }
        let target = try #require(try await library.currentInventory()["garten"]?.parentID)

        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        #expect(!undo.steps.contains { if case .moveCollection = $0.operation { true } else { false } })
        let undone = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        #expect(try await library.currentInventory()["garten"]?.parentID == target)
    }

    /// The executor moves an album out of the folder it is in now, and never takes it out of
    /// its folder when the target folder is gone.
    @Test func moveIntoAFolderThatWasDeletedMeanwhileChangesNothing() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [
            CollectionSnapshot(id: "ziel", title: "Ziel", kind: .folder),
            CollectionSnapshot(id: "start", title: "Start", kind: .folder),
            CollectionSnapshot(id: "garten", title: "Garten", parentID: "start", assetIDs: ids("a", 0..<5)),
        ])
        var plan = ChangePlan(id: SortlyID("m"), createdAt: Date(), confirmedAt: Date(), status: .confirmed, baseline: [:],
                              baselineCollectionIDs: ["ziel", "start", "garten"],
                              steps: [PlanStep(id: "m0", operation: .moveCollection("garten", from: "start", to: .existing("ziel")), sourceID: nil)],
                              conflicts: [], notes: [], resolvedKeys: [:])
        plan.status = .confirmed
        await library.userEdit { $0.remove("ziel") }
        let result = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        #expect(result.steps[0].state == .failed(reason: "parent folder no longer exists"))
        #expect(try await library.currentInventory()["garten"]?.parentID == "start")
    }
}
