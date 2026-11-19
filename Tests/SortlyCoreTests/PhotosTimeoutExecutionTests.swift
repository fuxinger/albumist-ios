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
    /// Photos that does not answer one kind of write in time: the change lands (at once, or
    /// only when `land()` is called: `later`) or not, and the caller gets `PhotosNotResponding`
    /// either way. A create hears its id before that, as from PhotoKit's placeholder. While a
    /// late change has no answer, no write is sent (`PhotosDeadline`) and the executor is told
    /// (`hasUnansweredWrites`). `stallRead`: the n-th read of the album or folder with this
    /// title gets no answer.
    actor SlowPhotos: PhotoLibraryWriting {
        let base: InMemoryPhotoLibrary
        var stalls: String?
        var lands: Bool
        let later: Bool
        var stallRead: (title: String, nth: Int)?
        private var reads = 0
        /// A create without an answer yet, which lands with `land()`.
        private var pending: (id: CollectionID, title: String, parent: CollectionID?, folder: Bool)?
        private(set) var sentWrites = 0
        /// Creates whose request returned in this launch (`createAnswered`).
        private var answered: Set<CollectionID> = []

        init(_ base: InMemoryPhotoLibrary, stalls: String?, lands: Bool, later: Bool = false,
             stallRead: (title: String, nth: Int)? = nil) {
            self.base = base
            self.stalls = stalls
            self.lands = lands
            self.later = later
            self.stallRead = stallRead
        }

        /// The late create is carried out now.
        func land() async {
            guard let c = pending else { return }
            pending = nil
            answered.insert(c.id)
            await base.userEdit { inventory in
                inventory.upsert(CollectionSnapshot(id: c.id, title: c.title, kind: c.folder ? .folder : .userAlbum, parentID: c.parent))
                if let parent = c.parent, var p = inventory[parent] { p.childIDs.append(c.id); inventory.upsert(p) }
            }
        }

        /// The late create is answered with a failure: it never lands.
        func neverLands() {
            if let c = pending { answered.insert(c.id) }
            pending = nil
        }

        /// The late create lands in a later launch: Albumist does not hear of it.
        func landsAfterARestart() async {
            guard let c = pending else { return }
            pending = nil
            await base.userEdit { inventory in
                inventory.upsert(CollectionSnapshot(id: c.id, title: c.title, kind: c.folder ? .folder : .userAlbum, parentID: c.parent))
            }
        }

        func hasUnansweredWrites() async -> Bool { pending != nil }
        func createAnswered(_ id: CollectionID) async -> Bool { answered.contains(id) }

        private func lane(_ what: String) throws {
            if pending != nil { throw PhotosNotResponding(lane: .write, what: what, notSent: true) }
            sentWrites += 1
        }

        private func stall<T>(_ what: String, _ write: () async throws -> T) async throws -> T {
            try lane(what)
            guard stalls == what else { return try await write() }
            stalls = nil
            if lands { _ = try await write() }
            throw PhotosNotResponding(lane: .write, what: what, notSent: false)
        }

        private func create(_ what: String, title: String, parent: CollectionID?, folder: Bool,
                            noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try lane(what)
            guard stalls == what else {
                return folder ? try await base.createFolder(title: title, parent: parent, noted: noted)
                    : try await base.createAlbum(title: title, parent: parent, noted: noted)
            }
            stalls = nil
            if later {
                let id = CollectionID("late-\(what)")
                await noted(id)
                pending = (id, title, parent, folder)
            } else if lands {
                _ = folder ? try await base.createFolder(title: title, parent: parent, noted: noted)
                    : try await base.createAlbum(title: title, parent: parent, noted: noted)
            }
            throw PhotosNotResponding(lane: .write, what: what, notSent: false)
        }

        func canWrite() async -> Bool { await base.canWrite() }
        func currentInventory() async throws -> CollectionInventory { try await base.currentInventory() }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await base.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
            let found = try await base.collection(id)
            if let stallRead, found?.title == stallRead.title {
                reads += 1
                if reads == stallRead.nth { throw PhotosNotResponding(lane: .read, what: "collection", notSent: false) }
            }
            return found
        }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
            try await createFolder(title: title, parent: parent, noted: { _ in })
        }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
            try await createAlbum(title: title, parent: parent, noted: { _ in })
        }
        func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await create("createFolder", title: title, parent: parent, folder: true, noted: noted)
        }
        func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await create("createAlbum", title: title, parent: parent, folder: false, noted: noted)
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

    /// The album came late (before the plan went on): Photos had given its id to the request,
    /// so it is this plan's own, never made a second time, and undo removes it (second review
    /// of the PhotoKit limits, 1: before, it was only adopted and stayed after undo).
    @Test func albumThatCameLateIsNotMadeTwice() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let journal = try await stopped(plan, on: SlowPhotos(lib, stalls: "createAlbum", lands: true), store)
        let key = try albumKey(journal)
        #expect(journal.resolvedKeys[key] == nil)
        let maybe = try #require(journal.record?.maybeCreated[key])
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").map(\.id) == [maybe])
        #expect(resumed.resolvedKeys[key] == maybe)
        #expect(resumed.record?.adoptedKeys.isEmpty == true)
        try await expectUndoRemovesReise(resumed, lib)
    }

    /// Undo of a plan whose album is Albumist's: the album goes.
    private func expectUndoRemovesReise(_ applied: ChangePlan, _ lib: InMemoryPhotoLibrary) async throws {
        let undo = confirmed(UndoPlanner().undoPlan(for: applied, current: try await lib.currentInventory()))
        let undone = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed, "\(undone.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").isEmpty)
    }

    /// The create lands only later. Going on while it has no answer sends nothing (no second
    /// "Reise" next to the late one); once it landed, the plan goes on with it.
    @Test func lateCreateLandsWhileThePlanWaits() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        let key = try albumKey(journal)
        #expect(journal.record?.maybeCreated[key] == CollectionID("late-createAlbum"))
        let writes = await photos.sentWrites
        // "Rest anlegen" right away: refused before anything is read or sent.
        await #expect(throws: PhotosNotResponding.self) { try await ChangeExecutor(library: photos, store: store).execute(journal) }
        #expect(await photos.sentWrites == writes)
        #expect(try await store.latest == journal)
        await photos.land()
        let resumed = try await ChangeExecutor(library: photos, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").map(\.id) == [CollectionID("late-createAlbum")])
        #expect(try await albums(lib, titled: "Reise").first?.assetIDs == ["x", "y"])
        #expect(resumed.record?.adoptedKeys.isEmpty == true)
        try await expectUndoRemovesReise(resumed, lib)
    }

    /// Taking the plan back while the create has no answer: not settled from a library that may
    /// still change. Once the album landed, the undo finds it as this plan's and removes it.
    @Test func lateCreateLandsBeforeTheUndoSettles() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        await #expect(throws: PhotosNotResponding.self) { try await ChangeExecutor(library: photos, store: store).reconcileInterrupted(journal) }
        await photos.land()
        let settled = try await ChangeExecutor(library: photos, store: store).reconcileInterrupted(journal)
        let key = try albumKey(settled)
        #expect(settled.resolvedKeys[key] == CollectionID("late-createAlbum"))
        #expect(settled.record?.adoptedKeys.isEmpty == true)
        try await expectUndoRemovesReise(settled, lib)
    }

    /// The create is answered with a failure: it never lands, and the plan makes the album when
    /// it goes on, once.
    @Test func lateCreateThatNeverLandsIsMadeOnce() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        await photos.neverLands()
        let resumed = try await ChangeExecutor(library: photos, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").count == 1)
        // Never forgotten, but answered: it never comes, so it is not waited for. The album made
        // instead has its id written down too (review P2-01), the earlier one stays on record.
        #expect(resumed.record?.earlierMaybeCreated.contains(CollectionID("late-createAlbum")) == true)
        let key = try albumKey(resumed)
        #expect(resumed.record?.maybeCreated[key] == resumed.resolvedKeys[key])
        #expect(resumed.record?.adoptedKeys.isEmpty == true)
    }

    /// After a restart Albumist cannot know whether the create still lands: for a while neither
    /// going on nor settling for an undo decides that step (no second "Reise"). Once it landed,
    /// it is this plan's own (third review of the PhotoKit limits, N2).
    @Test func lateCreateAfterARestartIsNotMadeTwice() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        let since = try #require(journal.record?.maybeCreatedAt[try albumKey(journal)])
        // The app was closed with the request on its way; a new launch knows nothing of it.
        let soon: @Sendable () -> Date = { since.addingTimeInterval(ChangeExecutor.lateCreateWait - 60) }
        await #expect(throws: ChangeExecutor.ExecutionError.earlierCreateMayLand(until: since.addingTimeInterval(ChangeExecutor.lateCreateWait))) {
            try await ChangeExecutor(library: lib, store: store, clock: soon).execute(journal)
        }
        await #expect(throws: ChangeExecutor.ExecutionError.self) {
            try await ChangeExecutor(library: lib, store: store, clock: soon).reconcileInterrupted(journal)
        }
        #expect(try await store.latest == journal)
        #expect(try await albums(lib, titled: "Reise").isEmpty)
        await photos.landsAfterARestart()
        let resumed = try await ChangeExecutor(library: lib, store: store, clock: soon).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").map(\.id) == [CollectionID("late-createAlbum")])
        #expect(resumed.record?.adoptedKeys.isEmpty == true)
        try await expectUndoRemovesReise(resumed, lib)
    }

    /// The create lands only after the wait, when the plan has made the album anyway: the late
    /// one is still Albumist's. The album records keep it, and undo removes both (N2).
    @Test func lateCreateLandingAfterTheWaitIsStillAlbumists() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        let since = try #require(journal.record?.maybeCreatedAt[try albumKey(journal)])
        let later: @Sendable () -> Date = { since.addingTimeInterval(ChangeExecutor.lateCreateWait + 60) }
        let resumed = try await ChangeExecutor(library: lib, store: store, clock: later).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").count == 1)
        await photos.landsAfterARestart()
        #expect(try await albums(lib, titled: "Reise").count == 2)
        let late = CollectionID("late-createAlbum")
        #expect(resumed.record?.mayStillLand(resolved: resumed.resolvedKeys) == [late])
        let managed = ManagedAlbumTracker().record(resumed, into: [], inventory: try await lib.currentInventory())
        #expect(managed.first { $0.albumID == late }?.createdBySortly == true)
        try await expectUndoRemovesReise(resumed, lib)
    }

    /// "So lassen" does not wait: it makes nothing, the plan stays in the history, and if the
    /// album lands after all, the undo takes it away (round-3 review, L1).
    @Test func keepingDuringTheWaitMakesNothingAndTheUndoStillTakesTheLateAlbum() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        let since = try #require(journal.record?.maybeCreatedAt[try albumKey(journal)])
        let soon: @Sendable () -> Date = { since.addingTimeInterval(60) }
        let settled = try await ChangeExecutor(library: lib, store: store, clock: soon).reconcileInterrupted(journal, keeping: true)
        let kept = settled.keptAsIs(current: try await lib.currentInventory())
        #expect(kept.status == .completedWithErrors)
        #expect(kept.record?.adoptedKeys.isEmpty == true)
        #expect(try await albums(lib, titled: "Reise").isEmpty)
        await photos.landsAfterARestart()
        try await expectUndoRemovesReise(kept, lib)
    }

    /// The clock was set back after the request: the wait is never longer than itself (L2).
    @Test func aClockSetBackDoesNotMakeTheWaitLonger() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        let since = try #require(journal.record?.maybeCreatedAt[try albumKey(journal)])
        let setBack: @Sendable () -> Date = { since.addingTimeInterval(-3_600) }
        let resumed = try await ChangeExecutor(library: lib, store: store, clock: setBack).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").count == 1)
    }

    /// Settled for an undo after the wait, and the create lands only then: the undo still
    /// takes it away (N2).
    @Test func lateCreateLandingAfterAnUndoWasSettledIsTakenAway() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let photos = SlowPhotos(lib, stalls: "createAlbum", lands: false, later: true)
        let journal = try await stopped(plan, on: photos, store)
        let since = try #require(journal.record?.maybeCreatedAt[try albumKey(journal)])
        let later: @Sendable () -> Date = { since.addingTimeInterval(ChangeExecutor.lateCreateWait + 60) }
        let settled = try await ChangeExecutor(library: lib, store: store, clock: later).reconcileInterrupted(journal)
        await photos.landsAfterARestart()
        try await expectUndoRemovesReise(settled, lib)
    }

    /// No answer to the check after the album was made: the step stays running with the id
    /// written down (not "failed"), and is checked when the plan goes on (second review, 8).
    @Test func checkWithoutAnswerAfterCreateStaysRunning() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let journal = try await stopped(plan, on: SlowPhotos(lib, stalls: nil, lands: false, stallRead: ("Reise", 1)), store)
        let key = try albumKey(journal)
        let made = try #require(journal.resolvedKeys[key])
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").map(\.id) == [made])
    }

    /// Nothing reached Photos (a read before the write got no answer): the step is as it was,
    /// waiting, not "running" to be settled by adoption later (second review, 9).
    @Test func stepOfWhichNothingWasSentIsPendingAgain() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y"], collections: [])
        let proposals = [ConfirmedProposal(
            proposal: AlbumProposal(id: SortlyID("reise"), kind: .trip, title: "Reise", folderPath: ["Urlaub"], assetIDs: ["x", "y"]),
            decision: .createNew(title: nil, folderPath: nil))]
        let plan = confirmed(OrganizationPlanner().makePlan(from: proposals, inventory: try await lib.currentInventory()))
        let albumStep = try #require(plan.steps.firstIndex { if case .createAlbum(_, _, .planned) = $0.operation { true } else { false } },
                                     "\(plan.steps.map(\.operation))")
        let store = InMemoryPlanStore()
        // The new folder is read for its check, then by the album step before the album is made.
        let photos = SlowPhotos(lib, stalls: nil, lands: false, stallRead: ("Urlaub", 2))
        await #expect(throws: PhotosNotResponding.self) { try await ChangeExecutor(library: photos, store: store).execute(plan) }
        let journal = try #require(await store.latest)
        #expect(journal.steps[albumStep].state == .pending)
        #expect(try await albums(lib, titled: "Reise").isEmpty)
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(journal)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await albums(lib, titled: "Reise").count == 1)
        #expect(resumed.record?.adoptedKeys.isEmpty == true)
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
