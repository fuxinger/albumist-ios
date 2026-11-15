import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Findings of the plugin review (15.11.) about writing to Photos and taking it back:
/// K1 undo of an interrupted plan, K2 a new plan next to an interrupted one, W1 a second undo
/// of a removal, W3 an album that is missing from the album list for a while, W4 the start
/// screen without photo access. (W2 is in `SortlyStoreTests`, the analysis part of W4 in
/// `SortlyEngineTests`.)
@Suite("Plugin review: interrupted plans, undo twice, albums missing for a while")
struct PluginReviewSafetyTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)
    let allAssets: Set<AssetID> = ids("a", 0..<300)
    static let ownPhotos = ids("a", 250..<255)

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

    /// The user's library before Albumist: one own album with own photos.
    func library() -> InMemoryPhotoLibrary {
        InMemoryPhotoLibrary(assets: allAssets, collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: Self.ownPhotos)])
    }

    /// "Paris" and "Rom" in a new folder "Reisen" (Paris is made first).
    func parisAndRome(_ inventory: CollectionInventory) -> ChangePlan {
        confirmed(planner.makePlan(from: [newAlbum("p", "Paris", ids("a", 10..<20)), newAlbum("r", "Rom", ids("a", 0..<10))], inventory: inventory))
    }

    /// The app ends right after Photos created "Rom": Paris is made and filled, Rom is made
    /// (its id is written down), Rom's photos are not added yet.
    func interruptedAfterCreatingRome(_ library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        let plan = parisAndRome(try await library.currentInventory())
        let store = UndoHardeningTests.EndingPlanStore { plan in
            plan.steps.contains { step in
                if case .createAlbum(_, "Rom", _) = step.operation, case .succeeded = step.state { return true }
                return false
            }
        }
        _ = try? await ChangeExecutor(library: library, store: store).execute(plan)
        return try #require(await store.saved.last)
    }

    func owned(_ states: [ManagedAlbumState]) -> [CollectionID: Set<AssetID>] {
        var result: [CollectionID: Set<AssetID>] = [:]
        for state in states { result[state.albumID, default: []].formUnion(state.addedBySortly) }
        return result
    }

    // MARK: K1 Undo of an interrupted plan

    /// "Rückgängig" on the interrupted plan, and the user answers "Nicht erlauben" in the iOS
    /// question. The albums stay in Photos, so the plan must stay too: kept like "So lassen"
    /// (history, receipt, Albumist's albums, free albums), not cancelled. "Rest rückgängig
    /// machen" then takes back what is left.
    @Test func declinedUndoOfAnInterruptedPlanKeepsItInTheHistory() async throws {
        let library = library()
        let interrupted = try await interruptedAfterCreatingRome(library)
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let settled = try await executor.reconcileInterrupted(interrupted)
        let taking = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())

        // Kept like "So lassen": what happened stays, the step that never ran is left out.
        #expect(taking.kept.id == interrupted.id)
        #expect(taking.kept.status == .completedWithErrors)
        #expect(taking.kept.steps.filter { $0.state == .skipped(reason: StepState.leftByUserReason) }.count == 1)
        let undo = try #require(taking.undo)
        #expect(undo.reverts == interrupted.id)
        #expect(undo.status == .confirmed && undo.confirmedAt != nil)
        // What the app's finalization stores for it: both albums are Albumist's, both count.
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(taking.kept, into: [], inventory: try await library.currentInventory())
        #expect(Set(states.map(\.lastKnownTitle)) == ["Paris", "Rom"])
        #expect(taking.kept.freeAlbumUse(applied: true) == 2)
        #expect(PlanReceipt(plan: taking.kept, inventory: try await library.currentInventory()).albumsCreated == 2)

        await library.setDeletionBehavior(.declined, times: 1)
        let undone = try await executor.execute(undo)
        #expect(undone.status == .completedWithErrors)
        #expect(!taking.cancelsPlan(after: undone))
        let afterDecline = try await library.currentInventory()
        #expect(afterDecline.albums.contains { $0.title == "Paris" })
        // The partial undo changed nothing: the albums are still recorded as Albumist's.
        let stillOurs = tracker.record(undone, into: states, inventory: afterDecline)
        #expect(Set(stillOurs.map(\.lastKnownTitle)) == ["Paris", "Rom"])

        // "Rest rückgängig machen": an ordinary undo of the kept plan.
        let rest = UndoPlanner().undoPlan(for: taking.kept, current: afterDecline, owned: owned(stillOurs), earlierUndos: [undone])
        #expect(!rest.steps.isEmpty)
        let second = try await executor.execute(confirmed(rest))
        #expect(second.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv.collections.count == 1)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(await library.assets == allAssets)
    }

    /// A completed undo takes the plan out of the history again, as before. Its free albums
    /// are counted when it is kept and given back with the undo: nothing is taken off the
    /// count of older versions (plugin review N4).
    @Test func completedUndoOfAnInterruptedPlanCancelsIt() async throws {
        let library = library()
        let interrupted = try await interruptedAfterCreatingRome(library)
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let taking = InterruptedPlanUndo(settled: try await executor.reconcileInterrupted(interrupted), current: try await library.currentInventory())
        let undo = try #require(taking.undo)

        var ledger = FreeAlbumLedger(legacyUsed: 3)
        ledger.record(plan: taking.kept.id, albums: taking.kept.freeAlbumUse(applied: true))
        #expect(ledger.used == 5)
        let undone = try await executor.execute(undo)
        #expect(undone.status == .completed)
        #expect(taking.cancelsPlan(after: undone))
        ledger.giveBack(plan: taking.kept.id, albums: taking.kept.freeAlbumUse(applied: true))
        #expect(ledger.used == 3)
        #expect(ledger.legacyUsed == 3)
        let inv = try await library.currentInventory()
        #expect(inv.collections.count == 1)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)

        // An undo that could not run, or the result of another plan, cancels nothing.
        #expect(!taking.cancelsPlan(after: nil))
        var other = undone
        other.id = SortlyID("another plan")
        #expect(!taking.cancelsPlan(after: other))
    }

    /// Cut off before anything happened in Photos: there is nothing to take back, and the plan
    /// simply goes away.
    @Test func interruptedPlanThatChangedNothingIsCancelled() async throws {
        let library = library()
        let plan = parisAndRome(try await library.currentInventory())
        let store = UndoHardeningTests.EndingPlanStore { plan in plan.steps.contains { if case .running = $0.state { true } else { false } } }
        _ = try? await ChangeExecutor(library: library, store: store).execute(plan)
        let interrupted = try #require(await store.saved.last)
        let settled = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).reconcileInterrupted(interrupted)
        let taking = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
        #expect(taking.undo == nil)
        #expect(taking.kept.status == .cancelled)
        #expect(taking.cancelsPlan(after: nil))
        #expect(settled.keptAsIs(current: try await library.currentInventory()).status == .cancelled)
    }

    /// "So lassen" when no step counts as done, but Photos had created the album before its
    /// check failed (audit 2, 1.7): the plan is kept with the album (history, undo later)
    /// instead of being cancelled with the album left in Photos.
    @Test func keptAsIsKeepsAnAlbumWhoseCheckFailed() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [CollectionSnapshot(id: "made", title: "Rom", assetIDs: [])])
        let plan = ChangePlan(id: SortlyID("k"), createdAt: Date(), confirmedAt: Date(), status: .running, baseline: [:], baselineCollectionIDs: [],
                              steps: [
                                  PlanStep(id: "k0", operation: .createAlbum(key: "rom", title: "Rom", parent: .topLevel), sourceID: SortlyID("r"),
                                           state: .failed(reason: "created collection could not be verified")),
                                  PlanStep(id: "k1", operation: .addAssets(album: .planned("rom"), assets: ids("a", 0..<5).sorted()), sourceID: SortlyID("r")),
                              ],
                              conflicts: [], notes: [], resolvedKeys: ["rom": "made"])
        let current = try await library.currentInventory()
        let kept = plan.keptAsIs(current: current)
        #expect(kept.status == .completedWithErrors)
        #expect(kept.steps[1].state == .skipped(reason: StepState.leftByUserReason))
        let undo = UndoPlanner().undoPlan(for: kept, current: current)
        #expect(undo.steps.map(\.operation) == [.deleteCollection("made", title: "Rom")])
    }

    // MARK: K2 One plan at a time

    /// While a plan that was cut off is open, its suggestions are still selected. A new plan of
    /// the same suggestions would make "Paris" a second time (only with a warning), so it does
    /// not run until the interrupted plan was continued, taken back or kept. Those ways out
    /// always may run.
    @Test func newPlanWaitsWhileAnInterruptedPlanIsOpen() async throws {
        let library = library()
        let interrupted = try await interruptedAfterCreatingRome(library)
        let again = confirmed(parisAndRome(try await library.currentInventory()))
        #expect(again.steps.contains { if case .createAlbum(_, "Paris", _) = $0.operation { true } else { false } })
        #expect(again.conflicts.contains { if case .titleExistsInFolder(title: "Paris", _) = $0 { true } else { false } })
        #expect(!again.conflicts.contains { $0.isBlocking })

        #expect(PlanGate.refusal(for: again, interrupted: interrupted) == .interruptedPlanOpen)
        // The ways out: continue it, take it back.
        #expect(PlanGate.refusal(for: interrupted, interrupted: interrupted) == nil)
        let settled = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).reconcileInterrupted(interrupted)
        let undo = try #require(InterruptedPlanUndo(settled: settled, current: try await library.currentInventory()).undo)
        #expect(PlanGate.refusal(for: undo, interrupted: interrupted) == nil)
        // Taking back an older plan from the history waits as well.
        var older = interrupted
        older.id = SortlyID("older")
        let olderUndo = UndoPlanner().undoPlan(for: older, current: try await library.currentInventory())
        #expect(PlanGate.refusal(for: olderUndo, interrupted: interrupted) == .interruptedPlanOpen)
        // Nothing open: everything may run.
        #expect(PlanGate.refusal(for: again, interrupted: nil) == nil)
    }

    // MARK: W1 Undo of a removal, twice

    /// Photos refuses the next `count` requests to add photos (seen as an error on a device
    /// when an album cannot be changed for a moment).
    final class AddRefusals: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(_ count: Int) { left = count }
        func take() -> Bool {
            lock.withLock {
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
    }

    /// The in-memory library, with an album list that lacks some albums (they can still be
    /// read one by one) and add requests that Photos refuses.
    struct ShakyLibrary: PhotoLibraryWriting {
        let inner: InMemoryPhotoLibrary
        var missingFromList: Set<CollectionID> = []
        var refusedAdds = AddRefusals(0)
        struct Refused: Error {}

        func canWrite() async -> Bool { await inner.canWrite() }
        func currentInventory() async throws -> CollectionInventory {
            var inventory = try await inner.currentInventory()
            for id in missingFromList { inventory.remove(id) }
            return inventory
        }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await inner.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await inner.collection(id) }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createFolder(title: title, parent: parent) }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createAlbum(title: title, parent: parent) }
        func addAssets(_ assets: [AssetID], to album: CollectionID) async throws {
            if refusedAdds.take() { throw Refused() }
            try await inner.addAssets(assets, to: album)
        }
        func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await inner.removeAssets(assets, from: album) }
        func renameCollection(_ id: CollectionID, to title: String) async throws { try await inner.renameCollection(id, to: title) }
        func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
            try await inner.moveCollection(id, from: oldParent, to: newParent)
        }
        func deleteCollection(_ id: CollectionID) async throws { try await inner.deleteCollection(id) }
        func deleteCollections(_ ids: [CollectionID]) async throws { try await inner.deleteCollections(ids) }
    }

    /// Rom (made by Albumist, in "Reisen") is removed again with "Album entfernen".
    func removedRome(_ library: InMemoryPhotoLibrary) async throws -> (removal: ChangePlan, rome: CollectionID, folder: CollectionID?) {
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10))],
                                                                            inventory: try await library.currentInventory())))
        let tracker = ManagedAlbumTracker()
        let rome = try #require(tracker.record(executed, into: [], inventory: try await library.currentInventory()).first { $0.lastKnownTitle == "Rom" })
        let folder = try await library.currentInventory()[rome.albumID]?.parentID
        let removal = try await executor.execute(confirmed(tracker.removalPlan(for: rome, current: try await library.currentInventory())))
        #expect(removal.status == .completed)
        #expect(try await library.currentInventory()[rome.albumID] == nil)
        return (removal, rome.albumID, folder)
    }

    /// The first undo of the removal brings "Rom" back but cannot put its photos in. The
    /// second ("Rest rückgängig machen") fills that album instead of making a second "Rom".
    @Test func secondUndoOfARemovalFillsTheAlbumTheFirstOneBroughtBack() async throws {
        let library = library()
        let (removal, _, folder) = try await removedRome(library)
        let shaky = ShakyLibrary(inner: library, refusedAdds: AddRefusals(1))
        let first = try await ChangeExecutor(library: shaky, store: InMemoryPlanStore())
            .execute(confirmed(UndoPlanner().undoPlan(for: removal, current: try await library.currentInventory())))
        #expect(first.status == .completedWithErrors)
        let back = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" })
        #expect(back.assetIDs.isEmpty)

        // Without knowing the first undo, the old way: a second album of the same name.
        let blind = UndoPlanner().undoPlan(for: removal, current: try await library.currentInventory())
        #expect(blind.steps.contains { if case .createAlbum = $0.operation { true } else { false } })

        let rest = UndoPlanner().undoPlan(for: removal, current: try await library.currentInventory(), earlierUndos: [first])
        #expect(!rest.steps.contains { if case .createAlbum = $0.operation { true } else { false } })
        let second = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(rest))
        #expect(second.status == .completed)
        let inv = try await library.currentInventory()
        let romes = inv.albums.filter { $0.title == "Rom" }
        #expect(romes.count == 1)
        #expect(romes.first?.id == back.id)
        #expect(romes.first?.assetIDs == ids("a", 0..<10))
        #expect(romes.first?.parentID == folder)
        #expect(await library.assets == allAssets)
    }

    /// After the first undo the user deleted the album it brought back: it stays deleted, the
    /// second undo makes nothing.
    @Test func albumBroughtBackAndDeletedByTheUserIsNotMadeAgain() async throws {
        let library = library()
        let (removal, _, _) = try await removedRome(library)
        let first = try await ChangeExecutor(library: ShakyLibrary(inner: library, refusedAdds: AddRefusals(1)), store: InMemoryPlanStore())
            .execute(confirmed(UndoPlanner().undoPlan(for: removal, current: try await library.currentInventory())))
        #expect(first.status == .completedWithErrors)
        let back = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" })
        await library.userEdit { $0.remove(back.id) }

        let rest = UndoPlanner().undoPlan(for: removal, current: try await library.currentInventory(), earlierUndos: [first])
        #expect(rest.steps.isEmpty)
        #expect(!(try await library.currentInventory().albums.contains { $0.title == "Rom" }))
    }

    /// One removal took "Rom" away and Albumist's photos out of the user's album "Sommer".
    /// The first undo brings Rom back with its photos but cannot put the photos back into
    /// Sommer; the user then takes one photo out of the new Rom. The second undo puts the
    /// photos back into Sommer and leaves Rom as the user wants it.
    @Test func secondUndoRespectsWhatTheUserTookOutOfTheAlbumBroughtBack() async throws {
        let library = library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let extendSommer = ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ids("a", 100..<110)),
                                             decision: .extendExisting("sommer"))
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10)), extendSommer],
                                                                            inventory: try await library.currentInventory())))
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" })
        let sommer = try #require(states.first { $0.albumID == "sommer" })
        // "Album entfernen" for both, as one plan.
        var removal = tracker.removalPlan(for: rome, current: try await library.currentInventory(), id: SortlyID("removal"))
        let sommerRemoval = tracker.removalPlan(for: sommer, current: try await library.currentInventory(), id: SortlyID("removal-s"))
        removal.steps += sommerRemoval.steps
        removal.baseline.merge(sommerRemoval.baseline) { first, _ in first }
        removal.deleteGuards?.merge(sommerRemoval.deleteGuards ?? [:]) { first, _ in first }
        let removed = try await executor.execute(confirmed(removal))
        #expect(removed.status == .completed)
        #expect(try await library.currentInventory()["sommer"]?.assetIDs == Self.ownPhotos)

        // The first add (photos back into Sommer) is refused; Rom comes back complete.
        let first = try await ChangeExecutor(library: ShakyLibrary(inner: library, refusedAdds: AddRefusals(1)), store: InMemoryPlanStore())
            .execute(confirmed(UndoPlanner().undoPlan(for: removed, current: try await library.currentInventory())))
        #expect(first.status == .completedWithErrors)
        let back = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" })
        #expect(back.assetIDs == ids("a", 0..<10))
        await library.userEdit { inv in
            var album = inv[back.id]!
            album.assetIDs.remove("a-0")
            inv.upsert(album)
        }

        let rest = UndoPlanner().undoPlan(for: removed, current: try await library.currentInventory(), earlierUndos: [first])
        let second = try await executor.execute(confirmed(rest))
        #expect(second.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<110)))
        #expect(inv.albums.filter { $0.title == "Rom" }.map(\.id) == [back.id])
        #expect(inv[back.id]?.assetIDs == ids("a", 1..<10))
    }

    // MARK: W3 An album missing from the list for a while

    /// Albumist's albums "Paris" and "Rom" in "Reisen", recorded as after a plan.
    func recordedParisAndRome(_ library: InMemoryPhotoLibrary) async throws -> (executed: ChangePlan, states: [ManagedAlbumState]) {
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(parisAndRome(try await library.currentInventory()))
        #expect(executed.status == .completed)
        return (executed, ManagedAlbumTracker().record(executed, into: [], inventory: try await library.currentInventory()))
    }

    /// The album list lacks "Paris" and its folder (iCloud still syncing after a restore from
    /// a backup), but Photos still has them. That is not the user deleting Paris: nothing is
    /// recorded, and the list everything else works with gets them back. An album the user
    /// really deleted is still recorded.
    @Test func albumMissingFromTheListIsCheckedOnItsOwnBeforeItCountsAsDeleted() async throws {
        let library = library()
        let (_, states) = try await recordedParisAndRome(library)
        let paris = try #require(states.first { $0.lastKnownTitle == "Paris" })
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" })
        let folder = try #require(try await library.currentInventory()[paris.albumID]?.parentID)
        let shaky = ShakyLibrary(inner: library, missingFromList: [paris.albumID, folder])
        let tracker = ManagedAlbumTracker()

        let listed = try await shaky.currentInventory()
        // Compared with the list alone, Paris would count as deleted by the user for good.
        #expect(tracker.reconcile(states, with: listed).newOverrides.contains { $0.decision == .doNotRecreateAlbum })

        let checked = try await tracker.reconcile(states, listed: listed, in: shaky, pause: .zero)
        #expect(checked.reconciliation.changes.isEmpty)
        #expect(checked.reconciliation.newOverrides.isEmpty)
        #expect(checked.reconciliation.updatedStates == states)
        #expect(checked.inventory[paris.albumID] != nil)
        #expect(checked.inventory[folder]?.kind == .folder)

        // Deleted for real: Photos does not have it on its own either.
        await library.userEdit { $0.remove(rome.albumID) }
        let deleted = try await tracker.reconcile(states, listed: try await shaky.currentInventory(), in: shaky, pause: .zero)
        #expect(deleted.reconciliation.changes == [.deleted(albumID: rome.albumID, sourceID: rome.sourceID)])
        #expect(deleted.reconciliation.newOverrides.map(\.scope) == [.source(rome.sourceID)])
        #expect(deleted.reconciliation.newOverrides.allSatisfy { $0.decision == .doNotRecreateAlbum })
    }

    /// An empty list for a moment, with every album still there: nothing is recorded. If an
    /// album cannot be read on its own, nothing is recorded either (the check fails, planning
    /// waits).
    @Test func emptyListOrAFailedLookUpRecordsNothing() async throws {
        let library = library()
        let (_, states) = try await recordedParisAndRome(library)
        let tracker = ManagedAlbumTracker()
        let checked = try await tracker.reconcile(states, listed: CollectionInventory(), in: library, pause: .zero)
        #expect(checked.reconciliation.newOverrides.isEmpty)
        #expect(checked.reconciliation.updatedStates == states)

        await library.setFailingCollectionReads(1)
        await #expect(throws: InMemoryPhotoLibrary.ReadFailure.self) {
            _ = try await tracker.reconcile(states, listed: CollectionInventory(), in: library, pause: .zero)
        }
    }

    /// The record of an album was lost (an album check that took it for deleted while the list
    /// lacked it). Undo falls back to the plan's own journal instead of an empty set: the album
    /// goes, Albumist's photos leave the user's album, and nothing of the user's is touched.
    @Test func undoWithoutTheAlbumsRecordUsesThePlansJournal() async throws {
        let library = library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let extendSommer = ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ids("a", 100..<110)),
                                             decision: .extendExisting("sommer"))
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10)), extendSommer],
                                                                            inventory: try await library.currentInventory())))
        let states = ManagedAlbumTracker().record(executed, into: [], inventory: try await library.currentInventory())
        #expect(states.count == 2)
        let before = try await library.currentInventory()

        // A record that is there still wins: Albumist owns nothing in Sommer any more (the user
        // took its photos out and put them back by hand), so they stay.
        let respectful = UndoPlanner().undoPlan(for: executed, current: before, owned: ["sommer": []])
        #expect(!respectful.steps.contains { if case .removeAssets("sommer", _) = $0.operation { true } else { false } })
        #expect(respectful.steps.contains { if case .deleteCollection(_, "Rom") = $0.operation { true } else { false } })

        // No record at all: the journal decides.
        let undo = UndoPlanner().undoPlan(for: executed, current: before, owned: [:])
        #expect(undo.steps.contains { if case .deleteCollection(_, "Rom") = $0.operation { true } else { false } })
        #expect(undo.steps.contains { if case .removeAssets("sommer", _) = $0.operation { true } else { false } })
        let undone = try await executor.execute(confirmed(undo))
        #expect(undone.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv.collections.count == 1)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(await library.assets == allAssets)
    }

    // MARK: W4 Start screen

    /// The introduction only until it was finished once; without photo access afterwards a
    /// screen of its own, never the introduction again (it ended with the whole library).
    @Test func startScreenAfterPhotoAccessWasTakenAway() {
        #expect(StartScreen.after(onboardingDone: false, access: .notDetermined) == .introduction)
        #expect(StartScreen.after(onboardingDone: false, access: .denied) == .introduction)
        #expect(StartScreen.after(onboardingDone: false, access: .full) == .introduction)
        for access in [LibraryAccess.denied, .restricted, .notDetermined] {
            #expect(StartScreen.after(onboardingDone: true, access: access) == .noPhotoAccess, "\(access)")
        }
        #expect(StartScreen.after(onboardingDone: true, access: .limited) == .main)
        #expect(StartScreen.after(onboardingDone: true, access: .full) == .main)
    }
}
