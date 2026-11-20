import Foundation
import Testing
@testable import AlbumistStore
import AlbumistCore
import AlbumistTestSupport

/// What the store tells the app about plans that are not settled (review of 6c6ef79): the plan
/// offered to continue, take back or keep (read again after every run and every way out, K2),
/// the plans whose results are still to be stored, and the journal "Rückgängig" on an
/// interrupted plan leaves behind (K1).
@Suite("Open plans: offered to continue, awaiting their results, taken back")
struct OpenPlansTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)

    func photos(_ range: Range<Int>) -> Set<AssetID> { Set(range.map { AssetID("a-\($0)") }) }

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

    /// "Paris" and "Rom" in a new folder "Reisen" (Paris is made first).
    func parisAndRome(_ library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        confirmed(planner.makePlan(from: [newAlbum("p", "Paris", photos(10..<20)), newAlbum("r", "Rom", photos(0..<10))],
                                   inventory: try await library.currentInventory()))
    }

    /// The store, until one of its writes fails (as on a full disk, see `DataSafetyTests`); that
    /// write and every one after it throw.
    actor FailingJournal: ChangePlanStoring {
        struct DiskFull: Error {}
        let store: AlbumistStore
        let failsAt: @Sendable (ChangePlan) -> Bool
        private var failing = false
        init(_ store: AlbumistStore, failsAt: @escaping @Sendable (ChangePlan) -> Bool) {
            self.store = store
            self.failsAt = failsAt
        }
        func save(_ plan: ChangePlan) async throws {
            if !failing, failsAt(plan) { failing = true }
            guard !failing else { throw DiskFull() }
            try await store.save(plan)
        }
    }

    static func madeRome(_ plan: ChangePlan) -> Bool {
        plan.steps.contains { step in
            if case .createAlbum(_, "Rom", _) = step.operation, case .succeeded = step.state { return true }
            return false
        }
    }

    /// The app's run: the plan goes on the list of plans to finalize, then it is executed.
    func run(_ plan: ChangePlan, in store: AlbumistStore, journal: (any ChangePlanStoring)? = nil, library: any PhotoLibraryWriting) async throws -> ChangePlan {
        var pending = try await store.value([AlbumistID].self, forKey: AlbumistStore.pendingFinalizationKey) ?? []
        if !pending.contains(plan.id) { pending.append(plan.id) }
        try await store.setValue(pending, forKey: AlbumistStore.pendingFinalizationKey)
        return try await ChangeExecutor(library: library, store: journal ?? store).execute(plan)
    }

    /// What the app's finalization stores, in one transaction: the plan with its time,
    /// Albumist's albums, and the list of plans to finalize without it.
    func finalize(_ plan: ChangePlan, in store: AlbumistStore, library: InMemoryPhotoLibrary) async throws {
        var done = plan
        done.finalizedAt = Date()
        let states = ManagedAlbumTracker().record(plan, into: try await store.managedAlbums(), inventory: try await library.currentInventory())
        let pending = (try await store.value([AlbumistID].self, forKey: AlbumistStore.pendingFinalizationKey) ?? []).filter { $0 != plan.id }
        try await store.finalize(done, managedAlbums: states, values: [AlbumistStore.pendingFinalizationKey: pending])
    }

    // MARK: K2 The plan offered is read again after every run

    /// A plan whose journal write fails half way (a full disk) in the same session stays
    /// unfinished. The store offers it at once, so the next "Jetzt umsetzen" of the same
    /// suggestions waits for it instead of making a second "Paris". Before, the app read the
    /// open plan only at launch and after "Rückgängig", and this one went unnoticed until then.
    @Test func planFailingHalfWayIsOfferedAtOnceAndTheSamePlanWaits() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        let plan = try await parisAndRome(library)
        #expect(try await store.openInterruptedPlan() == nil)

        await #expect(throws: FailingJournal.DiskFull.self) {
            _ = try await run(plan, in: store, journal: FailingJournal(store, failsAt: Self.madeRome), library: library)
        }
        #expect(try await library.currentInventory().albums.contains { $0.title == "Paris" })
        let open = try #require(try await store.openInterruptedPlan())
        #expect(open.id == plan.id)
        #expect(open.status == .running)
        // Not taken for a finished plan whose results wait to be stored.
        #expect(try await store.plansAwaitingFinalization().isEmpty)

        // The review builds the same plan again: it waits for the one that failed.
        let again = try await parisAndRome(library)
        #expect(again.steps.contains { if case .createAlbum(_, "Paris", _) = $0.operation { true } else { false } })
        #expect(PlanGate.refusal(for: again, interrupted: open) == .interruptedPlanOpen)
        // Continuing it is the way out, and it does not make Paris twice.
        #expect(PlanGate.refusal(for: open, interrupted: open) == nil)
        let resumed = try await ChangeExecutor(library: library, store: store).execute(open)
        #expect(resumed.status == .completed)
        #expect(try await library.currentInventory().albums.filter { $0.title == "Paris" }.count == 1)
        #expect(try await store.openInterruptedPlan() == nil)
    }

    /// Two plans left unfinished (by an older version, or a cut-off undo next to its plan): once
    /// one is settled, the other is offered. Before, "So lassen" and "Fortsetzen" cleared the
    /// offer, and the other plan was not offered until the next launch.
    @Test func settlingOneOfTwoOpenPlansOffersTheOther() async throws {
        let store = try AlbumistStore(url: nil)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var older = try await parisAndRome(InMemoryPhotoLibrary(assets: photos(0..<50)))
        older.id = AlbumistID("older")
        older.createdAt = start
        older.status = .running
        var newer = older
        newer.id = AlbumistID("newer")
        newer.createdAt = start.addingTimeInterval(60)
        newer.status = .confirmed
        try await store.save(newer)
        try await store.save(older)

        #expect(try await store.openInterruptedPlan()?.id == newer.id)
        newer.status = .completedWithErrors
        try await store.save(newer)
        #expect(try await store.openInterruptedPlan()?.id == older.id)
        older.status = .cancelled
        try await store.save(older)
        #expect(try await store.openInterruptedPlan() == nil)
    }

    /// Plans that finished but whose results are not stored yet: on the app's list, finished,
    /// without a finalization time. A plan still running on the list is offered instead; one
    /// finalized, cancelled or gone is neither.
    @Test func plansAwaitingTheirResults() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        let done = try await run(try await parisAndRome(library), in: store, library: library)
        #expect(done.status == .completed)
        #expect(try await store.awaitsFinalization(done.id))
        #expect(try await store.plansAwaitingFinalization().map(\.id) == [done.id])

        var open = done
        open.id = AlbumistID("open")
        open.status = .running
        open.finalizedAt = nil
        try await store.save(open)
        try await store.setValue([open.id, done.id, AlbumistID("gone")], forKey: AlbumistStore.pendingFinalizationKey)
        #expect(try await store.plansAwaitingFinalization().map(\.id) == [done.id])
        #expect(!(try await store.awaitsFinalization(open.id)))
        #expect(!(try await store.awaitsFinalization(AlbumistID("gone"))))

        try await finalize(done, in: store, library: library)
        #expect(!(try await store.awaitsFinalization(done.id)))
        #expect(try await store.plansAwaitingFinalization().isEmpty)
    }

    // MARK: K1 "Rückgängig" on an interrupted plan, with the store

    /// The plan cut off right after Photos made "Rom", from the store, with "Rückgängig" tapped.
    func interruptedPlanToTakeBack(_ store: AlbumistStore, _ library: InMemoryPhotoLibrary) async throws -> InterruptedPlanUndo {
        _ = try? await run(try await parisAndRome(library), in: store, journal: FailingJournal(store, failsAt: Self.madeRome), library: library)
        let interrupted = try #require(try await store.openInterruptedPlan())
        let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
        return InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
    }

    /// The app ends right after "Rückgängig" was stored, before the plan's results were. The
    /// next launch finds both: the plan's results to store (and its albums left alone by the
    /// album check until then), and the undo to continue. Once it ran, the plan counts as
    /// taken back. Before, the plan was finalized first and the undo was written only when it
    /// started: an app ending in between lost the tap.
    @Test func appEndingRightAfterRueckgaengigLosesNothing() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        let way = try await interruptedPlanToTakeBack(store, library)
        let undo = try #require(way.undo)

        let outcome = try await way.carryOut(journal: store, finalize: { _ in false }, run: { _ in Issue.record("the undo ran") })
        #expect(outcome == .resultsNotStored)

        // The next launch.
        let open = try #require(try await store.openInterruptedPlan())
        #expect(open.id == undo.id)
        #expect(open.status == .confirmed)
        #expect(try await store.plansAwaitingFinalization().map(\.id) == [way.kept.id])
        let made = try await library.currentInventory().collections.values.filter { $0.title != "Sommer" }.map(\.id)
        #expect(made.count == 3)
        #expect(try await store.collectionsInFlight().isSuperset(of: made))

        // It stores the plan's results first, then continues the undo.
        try await finalize(way.kept, in: store, library: library)
        #expect(Set(try await store.managedAlbums().map(\.lastKnownTitle)) == ["Paris", "Rom"])
        #expect(PlanGate.refusal(for: open, interrupted: open) == nil)
        let undone = try await run(open, in: store, library: library)
        #expect(undone.status == .completed)
        try await finalize(undone, in: store, library: library)
        #expect(try await library.currentInventory().collections.isEmpty)
        #expect(try await store.managedAlbums().isEmpty)
        #expect(try await store.undoneTargets().contains(way.kept.id))
        #expect(try await store.openInterruptedPlan() == nil)
        #expect(try await store.plansAwaitingFinalization().isEmpty)
    }

    /// What the receipt reads after "Rückgängig" ended in part or never started (point 6 of the
    /// review of 6c6ef79): after a declined deletion the plan has a finished undo that did not
    /// get everything back ("Rest rückgängig machen", and the app says the rest can be taken
    /// back); after an undo refused before its first step the plan has none ("Rückgängig
    /// machen", and the app says so), and that undo is not offered as an interrupted plan.
    @Test(arguments: [false, true])
    func receiptAfterRueckgaengigEndedEarly(refusedBeforeItRan: Bool) async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<50))
        let way = try await interruptedPlanToTakeBack(store, library)
        let undo = try #require(way.undo)
        if !refusedBeforeItRan { await library.setDeletionBehavior(.declined, times: 1) }

        let outcome = try await way.carryOut(journal: store, finalize: { kept in
            do { try await finalize(kept, in: store, library: library) } catch { return false }
            if refusedBeforeItRan { await library.setWriteAllowed(false) }
            return true
        }, run: { undo in
            _ = try? await run(undo, in: store, library: library)
        })

        #expect(outcome == (refusedBeforeItRan ? .notStarted : .partlyUndone))
        #expect(try await store.openInterruptedPlan() == nil)
        #expect(try await store.plan(way.kept.id)?.status == .completedWithErrors)
        #expect(try await store.planHistory().map(\.id).contains(way.kept.id))
        #expect(!(try await store.undoneTargets().contains(way.kept.id)))
        let undos = try await store.reverts(of: way.kept.id)
        if refusedBeforeItRan {
            #expect(undos.isEmpty)
            #expect(try await store.plan(undo.id)?.status == .cancelled)
        } else {
            #expect(undos.map(\.id) == [undo.id])
            #expect(undos.first?.status == .completedWithErrors)
        }
    }

    /// The id Photos gave a new album, written down from inside the change (review P2-01), is
    /// added to the plan as it is stored now: a change Photos runs late (after the run stopped
    /// waiting and wrote more) never puts an older plan back. Written twice, it stays once.
    @Test func idWrittenDownInsideTheChangeIsAddedToTheStoredPlan() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<20))
        var plan = try await parisAndRome(library)
        let early = plan
        plan.status = .running
        plan.record = ExecutionRecord()
        plan.record?.unavailable["x"] = 1
        try await store.save(plan)
        // As the executor calls it: through the protocol.
        let journal: any ChangePlanStoring = store
        try await journal.noteCreated(CollectionID("album-1"), key: "k", in: early)
        try await journal.noteCreated(CollectionID("album-1"), key: "k", in: early)
        let stored = try #require(try await store.plan(plan.id))
        #expect(stored.status == .running)
        #expect(stored.record?.unavailable["x"] == 1)
        #expect(stored.record?.maybeCreated["k"] == CollectionID("album-1"))
        #expect(stored.record?.maybeCreatedAt["k"] == nil)
        #expect(stored.record?.earlierMaybeCreated.isEmpty == true)
        // A second request for the same key: the first id stays Albumist's.
        try await journal.noteCreated(CollectionID("album-2"), key: "k", in: early)
        let again = try #require(try await store.plan(plan.id))
        #expect(again.record?.maybeCreated["k"] == CollectionID("album-2"))
        #expect(again.record?.earlierMaybeCreated == [CollectionID("album-1")])
    }

    /// Second review of P2-01 (S1): an id written down from inside a change that Photos ran
    /// after the run stopped waiting is in the stored plan only. A later save of a copy taken
    /// before it (the app's interrupted plan, the executor's own step saves) never loses it:
    /// before, `insertPlan` replaced the stored plan and the id was gone.
    @Test func aSaveOfAStaleCopyNeverRemovesANotedID() async throws {
        let store = try AlbumistStore(url: nil)
        let library = InMemoryPhotoLibrary(assets: photos(0..<20))
        var stale = try await parisAndRome(library)
        stale.status = .running
        stale.record = ExecutionRecord()
        stale.record?.unavailable["x"] = 1
        try await store.save(stale)
        let journal: any ChangePlanStoring = store
        try await journal.noteCreated(CollectionID("late-1"), key: "k", in: stale)
        try await journal.noteCreated(CollectionID("late-2"), key: "k", in: stale)
        try await journal.noteCreated(CollectionID("late-f"), key: "f", in: stale)

        // The stale copy, saved again (one more step settled): the noted ids stay.
        stale.record?.unavailable["y"] = 2
        stale.steps[0].state = .succeeded(createdID: nil, verifiedAt: Date())
        try await store.save(stale)
        var stored = try #require(try await store.plan(stale.id))
        #expect(stored.record?.maybeCreated == ["k": CollectionID("late-2"), "f": CollectionID("late-f")])
        #expect(stored.record?.earlierMaybeCreated == [CollectionID("late-1")])
        #expect(stored.record?.unavailable == ["x": 1, "y": 2])
        #expect(stored.steps[0].state.isFinished)

        // A copy that knows another id for the same key keeps it; the stored one stays
        // Albumist's as an earlier one. Saved in a batch too (`save([...])`, the undo's way).
        var other = stale
        other.record?.maybeCreated["k"] = CollectionID("mine")
        try await store.save([other])
        stored = try #require(try await store.plan(stale.id))
        #expect(stored.record?.maybeCreated == ["k": CollectionID("mine"), "f": CollectionID("late-f")])
        #expect(Set(stored.record?.earlierMaybeCreated ?? []) == [CollectionID("late-1"), CollectionID("late-2")])

        // Finalizing a stale copy keeps them as well.
        try await store.finalize(stale, managedAlbums: [], values: [:])
        stored = try #require(try await store.plan(stale.id))
        #expect(Set(stored.record?.maybeCreated.values.map { $0 } ?? []) == [CollectionID("mine"), CollectionID("late-f")])
        #expect(Set(stored.record?.earlierMaybeCreated ?? []) == [CollectionID("late-1"), CollectionID("late-2")])

        // And the copy itself is brought up to date before anything is decided from it.
        let refreshed = try await journal.withNotedIDs(stale)
        #expect(refreshed.record?.maybeCreated["f"] == CollectionID("late-f"))
        #expect(refreshed.record?.unavailable == ["x": 1, "y": 2])
    }

    /// The merge itself never drops anything (`ExecutionRecord.takeNotedIDs`).
    @Test func takingNotedIDsNeverDropsAnything() {
        var stored = ExecutionRecord()
        stored.maybeCreated = ["a": "s-a", "b": "s-b", "c": "same"]
        stored.maybeCreatedAt = ["a": Date(timeIntervalSince1970: 5)]
        stored.earlierMaybeCreated = ["old-1", "c-copy"]
        var copy = ExecutionRecord()
        copy.maybeCreated = ["b": "c-b", "c": "same", "d": "c-d", "e": "c-copy"]
        copy.earlierMaybeCreated = ["old-2"]
        let took = copy.takeNotedIDs(from: stored)
        #expect(took)
        #expect(copy.maybeCreated == ["a": "s-a", "b": "c-b", "c": "same", "d": "c-d", "e": "c-copy"])
        #expect(copy.maybeCreatedAt == ["a": Date(timeIntervalSince1970: 5)])
        #expect(copy.earlierMaybeCreated == ["old-2", "s-b", "old-1"])
        let again = copy.takeNotedIDs(from: stored)
        #expect(!again)
        var empty = ExecutionRecord()
        let none = empty.takeNotedIDs(from: ExecutionRecord())
        #expect(!none)
    }
}
