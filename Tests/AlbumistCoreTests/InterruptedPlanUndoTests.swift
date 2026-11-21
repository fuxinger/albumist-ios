import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Findings of the plugin review (15.11.) about writing to Photos and taking it back:
/// K1 undo of an interrupted plan, K2 a new plan next to an interrupted one, W1 a second undo
/// of a removal, W3 an album that is missing from the album list for a while, W4 the start
/// screen without photo access. (W2 is in `AlbumistStoreTests`, the analysis part of W4 in
/// `AlbumistEngineTests`.) The review of that work (6c6ef79) added the reviewer's probes, the
/// order of "Rückgängig" on an interrupted plan and the second undo into an album that was
/// there before; its store and album-check parts are `OpenPlansTests` and
/// `ManagedAlbumCheckTests`.
@Suite("Interrupted plans, undo twice, albums missing for a while")
struct InterruptedPlanUndoTests {
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
        ConfirmedProposal(proposal: AlbumProposal(id: AlbumistID(id), kind: .trip, title: title, folderPath: ["Reisen"], assetIDs: assets),
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
        for state in states { result[state.albumID, default: []].formUnion(state.addedByAlbumist) }
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
        #expect(ledger.legacyLeft == 3)
        let inv = try await library.currentInventory()
        #expect(inv.collections.count == 1)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)

        // An undo that could not run, or the result of another plan, cancels nothing.
        #expect(!taking.cancelsPlan(after: nil))
        var other = undone
        other.id = AlbumistID("another plan")
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

        // "Rückgängig": the plan is stored as cancelled; nothing is finalized or run.
        let journal = RecordingJournal()
        let outcome = try await taking.carryOut(journal: journal, finalize: { _ in
            await journal.note("finalize")
            return true
        }, run: { _ in await journal.note("run") })
        #expect(outcome == .nothingToTakeBack)
        #expect(await journal.log == ["save \(interrupted.id.rawValue) cancelled"])
        #expect(taking.selectionToRestore(after: outcome).isEmpty)
    }

    /// "So lassen" when no step counts as done, but Photos had created the album before its
    /// check failed (audit 2, 1.7): the plan is kept with the album (history, undo later)
    /// instead of being cancelled with the album left in Photos.
    @Test func keptAsIsKeepsAnAlbumWhoseCheckFailed() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [CollectionSnapshot(id: "made", title: "Rom", assetIDs: [])])
        let plan = ChangePlan(id: AlbumistID("k"), createdAt: Date(), confirmedAt: Date(), status: .running, baseline: [:], baselineCollectionIDs: [],
                              steps: [
                                  PlanStep(id: "k0", operation: .createAlbum(key: "rom", title: "Rom", parent: .topLevel), sourceID: AlbumistID("r"),
                                           state: .failed(reason: "created collection could not be verified")),
                                  PlanStep(id: "k1", operation: .addAssets(album: .planned("rom"), assets: ids("a", 0..<5).sorted()), sourceID: AlbumistID("r")),
                              ],
                              conflicts: [], notes: [], resolvedKeys: ["rom": "made"])
        let current = try await library.currentInventory()
        let kept = plan.keptAsIs(current: current)
        #expect(kept.status == .completedWithErrors)
        #expect(kept.steps[1].state == .skipped(reason: StepState.leftByUserReason))
        let undo = UndoPlanner().undoPlan(for: kept, current: current)
        #expect(undo.steps.map(\.operation) == [.deleteCollection("made", title: "Rom")])
    }

    // MARK: K1 "Rückgängig" carried out (review of 6c6ef79)

    /// The plan journal as `InterruptedPlanUndo.carryOut` leaves it, with every write, and the
    /// app's finalization and run, in the order they happened.
    actor RecordingJournal: PlanJournal {
        private(set) var plans: [AlbumistID: ChangePlan] = [:]
        private(set) var log: [String] = []
        func save(_ plan: ChangePlan) async throws {
            plans[plan.id] = plan
            log.append("save \(plan.id.rawValue) \(plan.status.rawValue)")
        }
        func save(_ plans: [ChangePlan]) async throws {
            for plan in plans { self.plans[plan.id] = plan }
            log.append("transaction " + plans.map { "\($0.id.rawValue) \($0.status.rawValue)" }.joined(separator: ", "))
        }
        func plan(_ id: AlbumistID) async throws -> ChangePlan? { plans[id] }
        func note(_ entry: String) { log.append(entry) }
    }

    /// Writes to a journal until the app ends (that save throws, nothing after it is written).
    actor EndingJournal: ChangePlanStoring {
        let journal: RecordingJournal
        let endsAt: @Sendable (ChangePlan) -> Bool
        private var ended = false
        init(_ journal: RecordingJournal, endsAt: @escaping @Sendable (ChangePlan) -> Bool) {
            self.journal = journal
            self.endsAt = endsAt
        }
        func save(_ plan: ChangePlan) async throws {
            if !ended, endsAt(plan) { ended = true }
            guard !ended else { throw UndoHardeningTests.EndingPlanStore.Ended() }
            try await journal.save(plan)
        }
    }

    enum UndoEnding: String, CaseIterable, Sendable {
        /// Everything is taken back.
        case completed
        /// "Nicht erlauben" in the iOS question.
        case deletionDeclined
        /// The write access is gone by the time the undo starts: refused before its first step.
        case refusedBeforeItRan
        /// The plan's results could not be stored (a full disk).
        case resultsNotStored
        /// The app ends while the undo runs.
        case cutOff
    }

    /// "Rückgängig" on the interrupted plan, in the app's order: the plan as kept and its undo
    /// in one transaction (from here on the tap is not lost: the next launch stores the plan's
    /// results and offers the undo to continue), the plan's results stored, the undo run, and
    /// only a completed undo cancels the plan. Before, the plan's results were stored first and
    /// the undo was written only when it started, so an app ending in between lost the tap.
    /// What the journal holds afterwards is what the receipt reads: "Rest rückgängig machen"
    /// only after an undo that ran in part, "Rückgängig machen" after one that never started.
    @Test(arguments: UndoEnding.allCases)
    func rueckgaengigOnAnInterruptedPlan(ending: UndoEnding) async throws {
        let library = library()
        let interrupted = try await interruptedAfterCreatingRome(library)
        let settled = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).reconcileInterrupted(interrupted)
        let way = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory(), undoID: AlbumistID("undo"))
        let undo = try #require(way.undo)
        let plan = interrupted.id.rawValue
        let journal = RecordingJournal()
        if ending == .deletionDeclined { await library.setDeletionBehavior(.declined, times: 1) }

        let outcome = try await way.carryOut(journal: journal, finalize: { kept in
            await journal.note("finalize \(kept.id.rawValue) \(kept.status.rawValue)")
            if ending == .refusedBeforeItRan { await library.setWriteAllowed(false) }
            return ending != .resultsNotStored
        }, run: { undo in
            await journal.note("run \(undo.id.rawValue)")
            let store: any ChangePlanStoring = ending == .cutOff
                ? EndingJournal(journal) { $0.steps.contains { if case .succeeded = $0.state { true } else { false } } }
                : journal
            _ = try? await ChangeExecutor(library: library, store: store).execute(undo)
        })

        let log = await journal.log
        #expect(log.first == "transaction \(plan) completedWithErrors, undo confirmed")
        #expect(log.dropFirst().first == "finalize \(plan) completedWithErrors")
        #expect(log.dropFirst(2).first == (ending == .resultsNotStored ? nil : "run undo"))
        let kept = try #require(await journal.plan(interrupted.id))
        let undoNow = try #require(await journal.plan(undo.id))
        let inventory = try await library.currentInventory()
        let left = inventory.albums.map(\.title).sorted()
        switch ending {
        case .completed:
            #expect(outcome == .undone)
            #expect(log.last == "save \(plan) cancelled")
            #expect(undoNow.status == .completed)
            #expect(inventory.collections.count == 1)
            #expect(inventory["sommer"]?.assetIDs == Self.ownPhotos)
        case .deletionDeclined:
            #expect(outcome == .partlyUndone)
            // A finished undo that did not get everything back: "Rest rückgängig machen".
            #expect(undoNow.status == .completedWithErrors)
            #expect(!PlanReceipt(plan: undoNow, inventory: inventory).isComplete)
            #expect(left == ["Paris", "Rom", "Sommer"])
        case .refusedBeforeItRan:
            #expect(outcome == .notStarted)
            // Dropped: no undo on the receipt (it offers "Rückgängig machen"), and not offered
            // as an interrupted plan either.
            #expect(undoNow.status == .cancelled)
            #expect(log.last == "save undo cancelled")
            #expect(left == ["Paris", "Rom", "Sommer"])
        case .resultsNotStored:
            #expect(outcome == .resultsNotStored)
            // Nothing is taken back yet; the undo stays to continue once the results are stored.
            #expect(undoNow.status == .confirmed)
            #expect(log.count == 2)
            #expect(left == ["Paris", "Rom", "Sommer"])
        case .cutOff:
            #expect(outcome == .undoInterrupted)
            // Offered to continue or keep, like any plan that was cut off.
            #expect(undoNow.status == .running)
        }
        // Only a completed undo cancels the plan, and only then the selection comes back.
        #expect(kept.status == (ending == .completed ? .cancelled : .completedWithErrors))
        #expect(log.contains("save \(plan) cancelled") == (ending == .completed))
        #expect(way.selectionToRestore(after: outcome) == (ending == .completed ? [AlbumistID("p"), AlbumistID("r")] : []))
    }

    /// Only suggestions the plan carried out leave the selection when it is finalized (review of
    /// 6c6ef79): "Venedig", whose steps never ran before the app ended, stays selected after
    /// "So lassen" or "Rückgängig"; Paris (made and filled) and Rom (made) leave it. Before,
    /// every suggestion of the plan did. An album Photos made although its check failed counts
    /// as made; a suggestion whose steps all failed does not.
    @Test func onlySuggestionsThePlanCarriedOutLeaveTheSelection() async throws {
        let library = library()
        let plan = confirmed(planner.makePlan(from: [newAlbum("p", "Paris", ids("a", 10..<20)), newAlbum("r", "Rom", ids("a", 0..<10)),
                                                     newAlbum("v", "Venedig", ids("a", 20..<30))],
                                              inventory: try await library.currentInventory()))
        let store = UndoHardeningTests.EndingPlanStore { plan in
            plan.steps.contains { step in
                if case .createAlbum(_, "Rom", _) = step.operation, case .succeeded = step.state { return true }
                return false
            }
        }
        _ = try? await ChangeExecutor(library: library, store: store).execute(plan)
        let interrupted = try #require(await store.saved.last)
        let settled = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).reconcileInterrupted(interrupted)
        let kept = settled.keptAsIs(current: try await library.currentInventory())
        #expect(Set(kept.steps.compactMap(\.sourceID)) == [AlbumistID("p"), AlbumistID("r"), AlbumistID("v")])
        #expect(kept.appliedSources == [AlbumistID("p"), AlbumistID("r")])
        let way = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
        #expect(way.kept.appliedSources == [AlbumistID("p"), AlbumistID("r")])

        var failed = ChangePlan(id: AlbumistID("f"), createdAt: Date(), confirmedAt: Date(), status: .completedWithErrors, baseline: [:], baselineCollectionIDs: [],
                                steps: [
                                    PlanStep(id: "f0", operation: .createAlbum(key: "rom", title: "Rom", parent: .topLevel), sourceID: AlbumistID("r"),
                                             state: .failed(reason: "created collection could not be verified")),
                                    PlanStep(id: "f1", operation: .addAssets(album: .existing("sommer"), assets: ["a-1"]), sourceID: AlbumistID("s"),
                                             state: .failed(reason: "refused")),
                                ],
                                conflicts: [], notes: [], resolvedKeys: ["rom": "made"])
        #expect(failed.appliedSources == [AlbumistID("r")])
        failed.resolvedKeys = [:]
        #expect(failed.appliedSources.isEmpty)
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
        older.id = AlbumistID("older")
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
        private var passing: Int
        /// - Parameter passing: requests that go through before the refusals start.
        init(_ count: Int, after passing: Int = 0) {
            left = count
            self.passing = passing
        }
        func take() -> Bool {
            lock.withLock {
                if passing > 0 {
                    passing -= 1
                    return false
                }
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

    /// A plan made "Rom" (in "Reisen") and put Albumist's photos into the user's album "Sommer";
    /// one "Album entfernen" plan then took both back: Rom is deleted, Sommer holds only the
    /// user's photos again.
    func removedRomeAndSommer(_ library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10)), sommerExtension()],
                                                                            inventory: try await library.currentInventory())))
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" })
        let sommer = try #require(states.first { $0.albumID == "sommer" })
        // "Album entfernen" for both, as one plan.
        var removal = tracker.removalPlan(for: rome, current: try await library.currentInventory(), id: AlbumistID("removal"))
        let sommerRemoval = tracker.removalPlan(for: sommer, current: try await library.currentInventory(), id: AlbumistID("removal-s"))
        removal.steps += sommerRemoval.steps
        removal.baseline.merge(sommerRemoval.baseline) { first, _ in first }
        removal.deleteGuards?.merge(sommerRemoval.deleteGuards ?? [:]) { first, _ in first }
        let removed = try await executor.execute(confirmed(removal))
        #expect(removed.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(!inv.albums.contains { $0.title == "Rom" })
        return removed
    }

    /// One removal took "Rom" away and Albumist's photos out of the user's album "Sommer".
    /// The first undo brings Rom back with its photos but cannot put the photos back into
    /// Sommer; the user then takes one photo out of the new Rom. The second undo puts the
    /// photos back into Sommer and leaves Rom as the user wants it.
    @Test func secondUndoRespectsWhatTheUserTookOutOfTheAlbumBroughtBack() async throws {
        let library = library()
        let removed = try await removedRomeAndSommer(library)

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
        let second = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(rest))
        #expect(second.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<110)))
        #expect(inv.albums.filter { $0.title == "Rom" }.map(\.id) == [back.id])
        #expect(inv[back.id]?.assetIDs == ids("a", 1..<10))
    }

    /// The other way round, for an album that was there before (review of 6c6ef79): the first
    /// undo of the removal puts the photos back into Sommer but cannot fill the Rom it brings
    /// back. The user then takes one of those photos out of Sommer again. The second undo fills
    /// Rom and leaves Sommer as the user wants it.
    @Test func secondUndoRespectsWhatTheUserTookOutOfAnAlbumTheFirstOneFilled() async throws {
        let library = library()
        let removed = try await removedRomeAndSommer(library)

        // The first add (photos back into Sommer) goes through, the second (into the Rom
        // brought back) is refused.
        let first = try await ChangeExecutor(library: ShakyLibrary(inner: library, refusedAdds: AddRefusals(1, after: 1)), store: InMemoryPlanStore())
            .execute(confirmed(UndoPlanner().undoPlan(for: removed, current: try await library.currentInventory())))
        #expect(first.status == .completedWithErrors)
        #expect(try await library.currentInventory()["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<110)))
        let back = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" })
        #expect(back.assetIDs.isEmpty)
        await library.userEdit { inv in
            var album = inv["sommer"]!
            album.assetIDs.remove("a-100")
            inv.upsert(album)
        }

        let rest = UndoPlanner().undoPlan(for: removed, current: try await library.currentInventory(), earlierUndos: [first])
        #expect(!rest.steps.contains { if case .addAssets(.existing("sommer"), _) = $0.operation { true } else { false } },
                "the second undo puts the photo the user took out back into Sommer: \(rest.steps.map(\.operation))")
        let second = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(rest))
        #expect(second.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 101..<110)))
        #expect(inv.albums.filter { $0.title == "Rom" }.map(\.id) == [back.id])
        #expect(inv[back.id]?.assetIDs == ids("a", 0..<10))
        #expect(await library.assets == allAssets)
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

    /// Which media of a plan are still Albumist's when it is taken back (review of 6c6ef79). An
    /// album without a record holds nothing of Albumist's any more: its record goes once
    /// Albumist took its photos out, and what the user put in after that is theirs. Only a plan
    /// whose results were never stored (an interrupted one, `owned: nil`) goes by its journal.
    @Test func albumWithoutARecordIsTheUsersOnlyAPlanNeverRecordedGoesByItsJournal() async throws {
        let library = library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10)), sommerExtension()],
                                                                            inventory: try await library.currentInventory())))
        let states = ManagedAlbumTracker().record(executed, into: [], inventory: try await library.currentInventory())
        #expect(states.count == 2)
        let before = try await library.currentInventory()
        func removesFromSommer(_ plan: ChangePlan) -> Bool {
            plan.steps.contains { if case .removeAssets("sommer", _) = $0.operation { true } else { false } }
        }
        func deletesRome(_ plan: ChangePlan) -> Bool {
            plan.steps.contains { if case .deleteCollection(_, "Rom") = $0.operation { true } else { false } }
        }

        // Recorded: what the records say is Albumist's goes.
        let recorded = UndoPlanner().undoPlan(for: executed, current: before, owned: owned(states))
        #expect(removesFromSommer(recorded) && deletesRome(recorded))
        // A record that is there still wins: Albumist owns nothing in Sommer any more.
        let respectful = UndoPlanner().undoPlan(for: executed, current: before, owned: ["sommer": [], states.first { $0.lastKnownTitle == "Rom" }!.albumID: ids("a", 0..<10)])
        #expect(!removesFromSommer(respectful) && deletesRome(respectful))
        // No record at all: nothing in those albums is Albumist's, everything stays.
        let unrecorded = UndoPlanner().undoPlan(for: executed, current: before, owned: [:])
        #expect(!removesFromSommer(unrecorded) && !deletesRome(unrecorded))
        // Never recorded (owned nil): the journal decides, and everything goes.
        let journal = UndoPlanner().undoPlan(for: executed, current: before)
        #expect(removesFromSommer(journal) && deletesRome(journal))
        let undone = try await executor.execute(confirmed(journal))
        #expect(undone.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv.collections.count == 1)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(await library.assets == allAssets)
    }

    // MARK: Review of 6c6ef79: records dropped on purpose (the reviewer's probes)

    func sommerExtension() -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: AlbumistID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ids("a", 100..<110)),
                          decision: .extendExisting("sommer"))
    }

    /// The plan extended the user's album "Sommer". "Album entfernen" took Albumist's photos out
    /// again (its record goes: nothing of Albumist's is left). The user then put the photos back
    /// by hand: they are the user's now, and "Rückgängig" of the plan leaves them.
    @Test func undoAfterRemovalKeepsPhotosTheUserPutBackByHand() async throws {
        let library = library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let tracker = ManagedAlbumTracker()
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [sommerExtension()], inventory: try await library.currentInventory())))
        #expect(executed.status == .completed)
        var states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let sommer = try #require(states.first { $0.albumID == "sommer" })
        let removal = try await executor.execute(confirmed(tracker.removalPlan(for: sommer, current: try await library.currentInventory())))
        #expect(removal.status == .completed)
        states = tracker.record(removal, into: states, inventory: try await library.currentInventory())
        #expect(!states.contains { $0.albumID == "sommer" })

        await library.userEdit { inv in
            var album = inv["sommer"]!
            album.assetIDs.formUnion(ids("a", 100..<110))
            inv.upsert(album)
        }
        let current = try await library.currentInventory()
        let checked = tracker.reconcile(states, with: current)
        let undo = UndoPlanner().undoPlan(for: executed, current: current, owned: owned(checked.updatedStates))
        #expect(!undo.steps.contains { if case .removeAssets("sommer", _) = $0.operation { true } else { false } },
                "undo takes photos the user put back by hand out of Sommer: \(undo.steps.map(\.operation))")
    }

    /// The same with an album Albumist created: the user had added an own photo, "Album
    /// entfernen" kept the album and took Albumist's photos out; the user then swapped their
    /// photo for Albumist's photos by hand. "Rückgängig" of the plan does not delete the album.
    @Test func undoAfterRemovalDoesNotDeleteAnAlbumTheUserRefilled() async throws {
        let library = library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let tracker = ManagedAlbumTracker()
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10))],
                                                                            inventory: try await library.currentInventory())))
        var states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" })
        await library.userEdit { inv in
            var album = inv[rome.albumID]!
            album.assetIDs.insert("a-200")
            inv.upsert(album)
        }
        states = tracker.reconcile(states, with: try await library.currentInventory()).updatedStates
        let romeNow = try #require(states.first { $0.albumID == rome.albumID })
        let removal = try await executor.execute(confirmed(tracker.removalPlan(for: romeNow, current: try await library.currentInventory())))
        #expect(removal.status == .completed)
        states = tracker.record(removal, into: states, inventory: try await library.currentInventory())
        #expect(!states.contains { $0.albumID == rome.albumID })
        #expect(try await library.currentInventory()[rome.albumID]?.assetIDs == ["a-200"])

        await library.userEdit { inv in
            var album = inv[rome.albumID]!
            album.assetIDs = ids("a", 0..<10)
            inv.upsert(album)
        }
        let current = try await library.currentInventory()
        let checked = tracker.reconcile(states, with: current)
        let undo = UndoPlanner().undoPlan(for: executed, current: current, owned: owned(checked.updatedStates))
        #expect(!undo.steps.contains { if case .deleteCollection(rome.albumID, _) = $0.operation { true } else { false } },
                "undo deletes the album the user refilled by hand: \(undo.steps.map(\.operation))")
        _ = try await executor.execute(confirmed(undo))
        #expect(try await library.currentInventory()[rome.albumID]?.assetIDs == ids("a", 0..<10), "album deleted or emptied")
    }

    /// The same through K1's own path: the first undo is partial (deletion declined) and took
    /// Albumist's photos out of the extended album, whose record then goes. The user puts some
    /// back; "Rest rückgängig machen" leaves them.
    @Test func restUndoKeepsPhotosTheUserPutBackAfterAPartialUndo() async throws {
        let library = library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let tracker = ManagedAlbumTracker()
        let executed = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10)), sommerExtension()],
                                                                            inventory: try await library.currentInventory())))
        var states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        await library.setDeletionBehavior(.declined, times: 1)
        let first = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory(), owned: owned(states))))
        #expect(first.status == .completedWithErrors)
        states = tracker.record(first, into: states, inventory: try await library.currentInventory())
        #expect(!states.contains { $0.albumID == "sommer" })
        await library.userEdit { inv in
            var album = inv["sommer"]!
            album.assetIDs.formUnion(ids("a", 100..<103))
            inv.upsert(album)
        }
        let current = try await library.currentInventory()
        let checked = tracker.reconcile(states, with: current)
        let rest = UndoPlanner().undoPlan(for: executed, current: current, owned: owned(checked.updatedStates), earlierUndos: [first])
        #expect(!rest.steps.contains { if case .removeAssets("sommer", _) = $0.operation { true } else { false } },
                "rest undo takes the user's re-added photos out of Sommer: \(rest.steps.map(\.operation))")
        #expect(rest.steps.contains { if case .deleteCollection(_, "Rom") = $0.operation { true } else { false } })
        _ = try await executor.execute(confirmed(rest))
        #expect(try await library.currentInventory()["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<103)))
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

        // The access changes while Albumist is open (back from Settings): from "Kein Zugriff"
        // to the main screen as soon as the photos can be read (the app's `followAccess`). The
        // introduction goes on by itself, and the main screen stays.
        #expect(StartScreen.noPhotoAccess.afterAccessChange(to: .full) == .main)
        #expect(StartScreen.noPhotoAccess.afterAccessChange(to: .limited) == .main)
        for access in [LibraryAccess.denied, .restricted, .notDetermined] {
            #expect(StartScreen.noPhotoAccess.afterAccessChange(to: access) == .noPhotoAccess, "\(access)")
            #expect(StartScreen.main.afterAccessChange(to: access) == .main, "\(access)")
            #expect(StartScreen.introduction.afterAccessChange(to: access) == .introduction, "\(access)")
        }
        #expect(StartScreen.introduction.afterAccessChange(to: .full) == .introduction)
    }
}
