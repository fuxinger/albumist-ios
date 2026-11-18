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

    // MARK: The app ends before the new id is written down (review P2-01, 18.11.2026)

    /// The app ends at a chosen save: that save and every one after it never reach the
    /// journal (`EndingPlanStore` refuses only the one save and goes on storing).
    actor DyingPlanStore: ChangePlanStoring {
        private(set) var saved: [ChangePlan] = []
        private var dead = false
        private let diesAt: @Sendable (ChangePlan) -> Bool
        init(diesAt: @escaping @Sendable (ChangePlan) -> Bool) { self.diesAt = diesAt }
        func save(_ plan: ChangePlan) async throws {
            if !dead, diesAt(plan) { dead = true }
            guard !dead else { throw EndingPlanStore.Ended() }
            saved.append(plan)
        }
    }

    /// Photos created the album or folder, and the app ended before Albumist wrote its id
    /// into the journal (the save right after the create never happened). Before, the next
    /// launch found it by its name only, took it over as "adopted", and "Alles zurücknehmen"
    /// left it behind, empty, without a word. Now its id is written down inside the change,
    /// before Photos stores it (as the sample photos do): it is provably Albumist's, and the
    /// undo removes it. The library is then exactly as before the plan.
    @Test(arguments: ["Albumist", "Reisen", "Rom", "Paris"])
    func undoAfterTheAppEndedBeforeTheNewIdWasWrittenLeavesNothing(title: String) async throws {
        let library = representativeLibrary()
        let before = try await library.currentInventory()
        let plan = representativePlan(before)
        // The app ends at the save that would write down the id Photos returned for `title`.
        let store = DyingPlanStore { plan in
            plan.steps.contains { step in
                switch step.operation {
                case .createAlbum(let key, title, _), .createFolder(let key, title, _): plan.resolvedKeys[key] != nil
                default: false
                }
            }
        }
        _ = try? await ChangeExecutor(library: library, store: store).execute(plan)
        let interrupted = try #require(await store.saved.last)
        #expect(try await library.currentInventory().collections.values.contains { $0.title == title }, "\(title) was created")

        let journal = InMemoryPlanStore()
        let executor = ChangeExecutor(library: library, store: journal)
        let settled = try await executor.reconcileInterrupted(interrupted)
        #expect(settled.record?.adoptedKeys.isEmpty == true, "\(title): proven Albumist's, not adopted")
        let way = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
        let outcome = try await way.carryOut(journal: journal, finalize: { _ in true }, run: { undo in
            _ = try? await executor.execute(undo)
        })
        #expect(outcome == .undone, "\(title)")
        let after = try await library.currentInventory()
        #expect(after == before, "\(title): \(after.collections.values.map(\.title).sorted())")
        #expect(await library.assets == allAssets)
    }

    /// Photos added Albumist's photos to the user's own album, and the app ended before the
    /// step was settled. Whether Albumist or the user put them there cannot be proven, so the
    /// undo leaves them. Before, "Alles zurücknehmen" then cancelled the plan: it left the
    /// history, and nobody was told that 10 photos stayed in "Sommer". Now the plan stays in
    /// the history and the outcome names what stays.
    @Test func undoAfterTheAppEndedWhileAddingToTheUsersAlbumKeepsThePlanAndNamesTheRest() async throws {
        let library = representativeLibrary()
        let plan = representativePlan(try await library.currentInventory())
        let addToSommer = try #require(plan.steps.first { if case .addAssets(.existing("sommer"), _) = $0.operation { true } else { false } })
        // The app ends at the save that would settle the add (the photos are in "Sommer").
        let store = DyingPlanStore { plan in
            plan.record?.media[addToSommer.id] != nil && plan.record?.unverified.contains(addToSommer.id) == false
        }
        _ = try? await ChangeExecutor(library: library, store: store).execute(plan)
        let interrupted = try #require(await store.saved.last)
        #expect(try await library.currentInventory()["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<110)))

        let journal = InMemoryPlanStore()
        let executor = ChangeExecutor(library: library, store: journal)
        let settled = try await executor.reconcileInterrupted(interrupted)
        let way = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
        let outcome = try await way.carryOut(journal: journal, finalize: { _ in true }, run: { undo in
            _ = try? await executor.execute(undo)
        })
        let inv = try await library.currentInventory()
        // The app is told what stays, in which album, and how many photos.
        #expect(outcome == .leftUnclear)
        #expect(way.remainder.collections.isEmpty)
        #expect(way.remainder.photos.map(\.album) == ["sommer"])
        #expect(way.remainder.photos.first?.assets == ids("a", 100..<110))
        // Read again after the undo (for the history): the same photos, under the album's name now.
        let after = UndoRemainder(plan: try #require(try await journal.plan(plan.id)), current: inv)
        #expect(after.photos.map(\.title) == ["Sommer"])
        #expect(after.photos.first?.assets == ids("a", 100..<110))
        // Everything Albumist provably made is gone; the photos in "Sommer" stay (unprovable).
        #expect(inv.collections.values.map(\.title).sorted() == ["Familie", "Sommer"])
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<110)))
        // The plan is not dropped silently: it stays in the history.
        let kept = try #require(try await journal.plan(plan.id))
        #expect(kept.status != .cancelled)
    }

    /// The journal cannot take the id inside the change (a full disk for that moment): the
    /// album is made all the same, recorded by the save once Photos answers, and the plan
    /// and its undo run as before.
    @Test func aJournalThatCannotTakeTheIdInsideTheChangeStopsNothing() async throws {
        actor NoNoteStore: ChangePlanStoring {
            struct Full: Error {}
            private(set) var saved: [ChangePlan] = []
            func save(_ plan: ChangePlan) async throws { saved.append(plan) }
            func noteCreated(_ id: CollectionID, key: String, in plan: ChangePlan) async throws { throw Full() }
        }
        let library = representativeLibrary()
        let before = try await library.currentInventory()
        let store = NoNoteStore()
        let executed = try await ChangeExecutor(library: library, store: store).execute(representativePlan(before))
        #expect(executed.status == .completed)
        #expect(executed.record?.adoptedKeys.isEmpty == true)
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        #expect(try await ChangeExecutor(library: library, store: store).execute(undo).status == .completed)
        #expect(try await library.currentInventory() == before)
    }

    /// P2-07: only the first open step of a resumed plan can have run without its journal
    /// entry. Photos the user put into their own album during the interruption, for a step
    /// further on, are never taken for "maybe Albumist's" (nothing is named after the undo).
    /// (A first run never finds them: a change to the album since the preview blocks it.)
    @Test func photosTheUserAddedBeforeAStepRanAreNeverUnclear() async throws {
        let again = representativeLibrary()
        let second = representativePlan(try await again.currentInventory())
        let store = DyingPlanStore { plan in plan.steps.contains { if case .succeeded = $0.state { true } else { false } } }
        _ = try? await ChangeExecutor(library: again, store: store).execute(second)
        let interrupted = try #require(await store.saved.last)
        await again.userEdit { inv in
            var sommer = inv["sommer"]!
            sommer.assetIDs.formUnion(ids("a", 100..<103))
            inv.upsert(sommer)
        }
        let resumed = try await ChangeExecutor(library: again, store: InMemoryPlanStore()).execute(interrupted)
        #expect(resumed.status == .completed)
        #expect(resumed.record?.unclear.isEmpty == true)
        let undo = confirmed(UndoPlanner().undoPlan(for: resumed, current: try await again.currentInventory()))
        _ = try await ChangeExecutor(library: again, store: InMemoryPlanStore()).execute(undo)
        let inv = try await again.currentInventory()
        #expect(UndoRemainder(plan: resumed, current: inv).isEmpty)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<103)))
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
        // Seen to be still there: nothing written down. Not verifiable either way: what the
        // album held stays written down (plugin review N6), and an undo brings it back only if
        // Photos, asked for it on its own, says it is gone (PluginReviewLaunchTests).
        #expect(undone.record?.deletedAlbums.isEmpty == (blankReads == 1))
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

    // MARK: Interruption at every write (C3)

    /// Trips when the library "crashes" (the write `setFailAfterWrites` chose): from then on
    /// the app is gone, so nothing more reaches the journal.
    final class KillSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var tripped: Bool { lock.withLock { value } }
        func trip() { lock.withLock { value = true } }
    }

    struct KillableLibrary: PhotoLibraryWriting {
        let inner: InMemoryPhotoLibrary
        let kill: KillSwitch
        private func write<T>(_ call: () async throws -> T) async throws -> T {
            do { return try await call() } catch let crash as InMemoryPhotoLibrary.SimulatedCrash { kill.trip(); throw crash }
        }
        func canWrite() async -> Bool { await inner.canWrite() }
        func currentInventory() async throws -> CollectionInventory { try await inner.currentInventory() }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await inner.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await inner.collection(id) }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await write { try await inner.createFolder(title: title, parent: parent) } }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID { try await write { try await inner.createAlbum(title: title, parent: parent) } }
        // Like PhotoKit, the new id is heard inside the change, before Photos stores it.
        func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await write { try await inner.createFolder(title: title, parent: parent, noted: noted) }
        }
        func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await write { try await inner.createAlbum(title: title, parent: parent, noted: noted) }
        }
        func addAssets(_ assets: [AssetID], to album: CollectionID) async throws { try await write { try await inner.addAssets(assets, to: album) } }
        func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await write { try await inner.removeAssets(assets, from: album) } }
        func renameCollection(_ id: CollectionID, to title: String) async throws { try await write { try await inner.renameCollection(id, to: title) } }
        func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
            try await write { try await inner.moveCollection(id, from: oldParent, to: newParent) }
        }
        func deleteCollection(_ id: CollectionID) async throws { try await write { try await inner.deleteCollection(id) } }
        func deleteCollections(_ ids: [CollectionID]) async throws { try await write { try await inner.deleteCollections(ids) } }
    }

    /// The user's library before the plan: an own album with own photos and an own folder.
    static let ownPhotos = ids("a", 250..<255)
    func representativeLibrary() -> InMemoryPhotoLibrary {
        InMemoryPhotoLibrary(assets: allAssets, collections: [
            CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: Self.ownPhotos),
            CollectionSnapshot(id: "familie", title: "Familie", kind: .folder),
        ])
    }

    /// New albums in new and existing folders, one filled in two parts, an own album renamed
    /// and extended.
    func representativePlan(_ inventory: CollectionInventory) -> ChangePlan {
        confirmed(planner.makePlan(from: [
            newAlbum("r", "Rom", ["Reisen"], ids("a", 0..<60)),
            newAlbum("p", "Paris", ["Reisen"], ids("a", 60..<70)),
            ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ids("a", 100..<110)),
                              decision: .renameExisting("sommer", newTitle: "Sommer 2024", extend: true)),
        ], inventory: inventory))
    }

    /// What may be in the library after a resumed run: never a second album or folder of the
    /// same name in one place, no photo in an album it was not planned for, the user's own
    /// photos untouched, media unchanged. Steps that did not finish say why; the only reason
    /// allowed is the deliberate "not added again by itself".
    func expectSane(_ plan: ChangePlan, _ library: InMemoryPhotoLibrary, case label: String) async throws {
        let inv = try await library.currentInventory()
        var seen = Set<String>()
        for c in inv.collections.values {
            let first = seen.insert("\(c.parentID?.rawValue ?? "-")/\(c.kind == .folder)/\(c.title)").inserted
            #expect(first, "duplicate \(c.title) (\(label))")
        }
        let planned: [String: Set<AssetID>] = ["Rom": ids("a", 0..<60), "Paris": ids("a", 60..<70)]
        for title in planned.keys {
            #expect(inv.albums.filter { $0.title == title }.count == 1, "\(title) (\(label))")
        }
        for album in inv.albums where album.id != "sommer" {
            #expect(album.assetIDs.isSubset(of: planned[album.title] ?? []), "\(album.title) (\(label))")
        }
        let sommer = try #require(inv["sommer"])
        #expect(sommer.assetIDs.isSuperset(of: Self.ownPhotos), "\(label)")
        #expect(sommer.assetIDs.isSubset(of: Self.ownPhotos.union(ids("a", 100..<110))), "\(label)")
        #expect(inv["familie"] != nil, "\(label)")
        #expect(await library.assets == allAssets)
        for step in plan.steps {
            switch step.state {
            case .succeeded: break
            case .failed(let reason): #expect(reason == StepState.unclearReason, "\(reason) (\(label))")
            default: Issue.record("step left \(step.state) (\(label))")
            }
        }
    }

    /// After an undo the library is as it was before the plan, or the app names what stays
    /// (`UndoRemainder`, review P2-01): an album found by its name after an interruption (never
    /// deleted, it is empty) with the folders holding it, and photos an interrupted add may
    /// have put into the user's album (it cannot be proven whether Albumist or the user did).
    /// Before, these were simply allowed, and "Alles zurücknehmen" left them without a word.
    func expectUndone(_ executed: ChangePlan, _ undone: ChangePlan, _ library: InMemoryPhotoLibrary, case label: String) async throws {
        #expect(undone.status == .completed, "\(label): \(undone.steps.map(\.state))")
        let inv = try await library.currentInventory()
        let remainder = UndoRemainder(plan: executed, current: inv)
        let named = Set(remainder.collections.map(\.id))
        for c in inv.collections.values where c.id != "sommer" && c.id != "familie" {
            let holdsNamed = inv.collections.values.contains { named.contains($0.id) && inv.path(of: $0.id).contains(c.title) }
            #expect(named.contains(c.id) || holdsNamed, "\(c.title) left behind without a word (\(label))")
            #expect(c.assetIDs.isEmpty, "\(c.title) still holds photos (\(label))")
        }
        let sommer = try #require(inv["sommer"])
        #expect(sommer.title == "Sommer", "\(label)")
        #expect(inv["familie"] != nil, "\(label)")
        // Albumist's photos leave the user's album; photos that stay are named.
        let namedInSommer = remainder.photos.first { $0.album == "sommer" }?.assets ?? []
        #expect(remainder.photos.allSatisfy { $0.album == "sommer" }, "\(label)")
        #expect(sommer.assetIDs == Self.ownPhotos.union(namedInSommer), "\(label)")
        #expect(await library.assets == allAssets)
    }

    @Test(arguments: [false, true])
    func interruptionAtEveryWriteResumesAndUndoesCleanly(afterApplying: Bool) async throws {
        // How many writes a clean run makes.
        let probe = representativeLibrary()
        _ = try await ChangeExecutor(library: probe, store: InMemoryPlanStore()).execute(representativePlan(try await probe.currentInventory()))
        let writes = await probe.writeCount
        #expect(writes >= 8)

        for k in 0..<writes {
            for resume in [true, false] {
                let label = "write \(k), \(afterApplying ? "after" : "before") applying, \(resume ? "resume" : "undo")"
                let library = representativeLibrary()
                let kill = KillSwitch()
                let plan = representativePlan(try await library.currentInventory())
                await library.setFailAfterWrites(k, afterApplying: afterApplying)
                let store = EndingPlanStore { _ in kill.tripped }
                _ = try? await ChangeExecutor(library: KillableLibrary(inner: library, kill: kill), store: store).execute(plan)
                #expect(kill.tripped, "\(label)")
                let interrupted = try #require(await store.saved.last)
                await library.setFailAfterWrites(nil)
                let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())

                if resume {
                    let resumed = try await executor.execute(interrupted)
                    try await expectSane(resumed, library, case: label)
                    let undo = confirmed(UndoPlanner().undoPlan(for: resumed, current: try await library.currentInventory()))
                    try await expectUndone(resumed, try await executor.execute(undo), library, case: label)
                } else {
                    let settled = try await executor.reconcileInterrupted(interrupted)
                    let undo = confirmed(UndoPlanner().undoPlan(for: settled, current: try await library.currentInventory()))
                    try await expectUndone(settled, try await executor.execute(undo), library, case: label)
                }
            }
        }
    }

    /// The undo itself is cut off at each of its writes, then resumed: the result is the same
    /// as an undo that ran through.
    @Test(arguments: [false, true])
    func undoInterruptedAtEveryWriteFinishesCleanly(afterApplying: Bool) async throws {
        let probe = representativeLibrary()
        let probed = try await ChangeExecutor(library: probe, store: InMemoryPlanStore()).execute(representativePlan(try await probe.currentInventory()))
        await probe.setFailAfterWrites(nil)
        _ = try await ChangeExecutor(library: probe, store: InMemoryPlanStore())
            .execute(confirmed(UndoPlanner().undoPlan(for: probed, current: try await probe.currentInventory())))
        let writes = await probe.writeCount
        #expect(writes >= 3)

        for k in 0..<writes {
            let label = "undo write \(k), \(afterApplying ? "after" : "before") applying"
            let library = representativeLibrary()
            let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(representativePlan(try await library.currentInventory()))
            #expect(executed.status == .completed)
            let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
            let kill = KillSwitch()
            await library.setFailAfterWrites(k, afterApplying: afterApplying)
            let store = EndingPlanStore { _ in kill.tripped }
            _ = try? await ChangeExecutor(library: KillableLibrary(inner: library, kill: kill), store: store).execute(undo)
            #expect(kill.tripped, "\(label)")
            let interrupted = try #require(await store.saved.last)
            await library.setFailAfterWrites(nil)
            let finished = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(interrupted)
            try await expectUndone(executed, finished, library, case: label)
            let inv = try await library.currentInventory()
            #expect(inv["sommer"]?.assetIDs == Self.ownPhotos, "\(label)")
            #expect(inv.collections.count == 2, "\(label)")
        }
    }

    // MARK: Undo twice (C7)

    /// Taking back a plan that is already taken back finds nothing to do and changes nothing,
    /// also not the user's own albums.
    @Test func undoOfAnAlreadyUndonePlanChangesNothing() async throws {
        let library = representativeLibrary()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(representativePlan(try await library.currentInventory()))
        _ = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory())))
        let afterFirst = try await library.currentInventory()
        #expect(afterFirst.collections.count == 2)

        let second = UndoPlanner().undoPlan(for: executed, current: afterFirst)
        #expect(second.steps.isEmpty)
        let ran = try await executor.execute(confirmed(second))
        #expect(ran.status == .completed)
        #expect(try await library.currentInventory() == afterFirst)
        #expect(await library.deleteRequests == 1)
    }

    /// The first undo is declined in the iOS question after Albumist's photos left the user's
    /// album; "Rest rückgängig machen" removes exactly the rest, and a third undo has nothing
    /// left to do.
    @Test func partialUndoThenTheRestThenNothing() async throws {
        let library = representativeLibrary()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(representativePlan(try await library.currentInventory()))
        await library.setDeletionBehavior(.declined, times: 1)
        let first = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory())))
        #expect(first.status == .completedWithErrors)
        #expect(try await library.currentInventory()["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(try await library.currentInventory()["sommer"]?.title == "Sommer")

        let rest = UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory())
        #expect(rest.steps.allSatisfy { if case .deleteCollection = $0.operation { true } else { false } })
        let second = try await executor.execute(confirmed(rest))
        try await expectUndone(executed, second, library, case: "rest")
        #expect(try await library.currentInventory().collections.count == 2)
        #expect(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()).steps.isEmpty)
    }

    // MARK: Plans stored by older versions (C8)

    /// A plan saved before the execution journal existed (no record, no delete guards, no
    /// finalization time) and one with an early journal (media only): both load, and undo
    /// removes exactly what Albumist made, keeping the user's own photos.
    @Test(arguments: [["record", "deleteGuards", "finalizedAt", "retries", "albumsFromRetriedPlan"],
                      ["record.unverified", "record.adoptedKeys", "record.deletedAlbums", "record.unavailable", "record.names", "finalizedAt"]])
    func undoOfAPlanStoredByAnOlderVersion(dropping keys: [String]) async throws {
        let library = representativeLibrary()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        var executed = try await executor.execute(representativePlan(try await library.currentInventory()))
        executed.finalizedAt = Date()
        // Encoded the way the store does it, then written back in the older shape.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(executed)) as? [String: Any])
        for key in keys {
            let parts = key.split(separator: ".").map(String.init)
            if parts.count == 2, var record = json[parts[0]] as? [String: Any] {
                record[parts[1]] = nil
                json[parts[0]] = record
            } else {
                json[key] = nil
            }
        }
        let old = try JSONDecoder().decode(ChangePlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.steps == executed.steps)

        // The user put an own photo into "Paris" since.
        let paris = try #require(try await library.currentInventory().albums.first { $0.title == "Paris" }?.id)
        await library.userEdit { inv in
            var album = inv[paris]!
            album.assetIDs.insert("a-299")
            inv.upsert(album)
        }
        let undo = confirmed(UndoPlanner().undoPlan(for: old, current: try await library.currentInventory()))
        let undone = try await executor.execute(undo)
        #expect(undone.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.title == "Sommer")
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(inv.albums.first { $0.title == "Rom" } == nil)
        #expect(inv[paris]?.assetIDs == ["a-299"]) // the user's photo and its album stay
        #expect(inv["familie"] != nil)
        #expect(await library.assets == allAssets)
    }

    // MARK: Large plan (C2)

    /// Keeps only the newest version (the app's store writes changed steps only).
    actor LatestPlanStore: ChangePlanStoring {
        private(set) var saves = 0
        private(set) var latest: ChangePlan?
        func save(_ plan: ChangePlan) async throws {
            saves += 1
            latest = plan
        }
    }

    /// 300 albums in 12 folders with 20,100 photos: it runs through, verifies, and undo takes
    /// it all back with a single question from Photos, both in reasonable time.
    @Test func threeHundredAlbumsWithTwentyThousandPhotosRunAndUndo() async throws {
        let assets = ids("big", 0..<20_100)
        let library = InMemoryPhotoLibrary(assets: assets)
        let items = (0..<300).map { n in
            newAlbum("big\(n)", "Album \(n)", ["Reisen", "Jahr \(n % 12)"], ids("big", (n * 67)..<(n * 67 + 67)))
        }
        let plan = confirmed(OrganizationPlanner(rootFolderTitle: "Albumist").makePlan(from: items, inventory: try await library.currentInventory()))
        #expect(plan.summary.newAlbums == 300)
        #expect(plan.summary.distinctAssets == 20_100)
        let store = LatestPlanStore()
        let executor = ChangeExecutor(library: library, store: store)
        let clock = ContinuousClock()

        var executed: ChangePlan?
        let runTime = try await clock.measure { executed = try await executor.execute(plan) }
        let result = try #require(executed)
        #expect(result.status == .completed)
        #expect(try await library.currentInventory().albums.count == 300)
        #expect(result.appliedSummary.distinctAssets == 20_100)

        var undone: ChangePlan?
        let undo = confirmed(UndoPlanner().undoPlan(for: result, current: try await library.currentInventory()))
        let undoTime = try await clock.measure { undone = try await executor.execute(undo) }
        #expect(undone?.status == .completed)
        #expect(try await library.currentInventory().collections.isEmpty)
        #expect(await library.deleteRequests == 1)
        #expect(await library.assets == assets)
        // Generous bounds for a debug build on a slow machine: they catch work that grows
        // with the square of the plan, not ordinary speed.
        #expect(runTime < .seconds(60), "run took \(runTime)")
        #expect(undoTime < .seconds(60), "undo took \(undoTime)")
    }

    // MARK: Removing one of Albumist's albums, and taking that back (C9)

    /// "Album entfernen" in Albumist's album list deletes an album Albumist made; taking that
    /// removal back brings the album back (as a new album, Photos cannot restore the old one)
    /// in its folder with the same photos. In an album the user extended, only Albumist's
    /// photos leave, and they come back.
    @Test func removingAManagedAlbumAndTakingItBack() async throws {
        let library = representativeLibrary()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(representativePlan(try await library.currentInventory()))
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let rom = try #require(states.first { $0.lastKnownTitle == "Rom" })
        let romFolder = try await library.currentInventory()[rom.albumID]?.parentID
        let sommer = try #require(states.first { $0.albumID == "sommer" })

        var removals: [ChangePlan] = []
        for state in [rom, sommer] {
            let removal = confirmed(tracker.removalPlan(for: state, current: try await library.currentInventory()))
            let removed = try await executor.execute(removal)
            #expect(removed.status == .completed)
            removals.append(removed)
        }
        var inv = try await library.currentInventory()
        #expect(inv[rom.albumID] == nil)
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos)
        #expect(await library.deleteRequests == 1)

        // Both removals taken back, newest first.
        for removed in removals.reversed() {
            let undo = confirmed(UndoPlanner().undoPlan(for: removed, current: try await library.currentInventory()))
            let undone = try await executor.execute(undo)
            #expect(undone.status == .completed)
        }
        inv = try await library.currentInventory()
        let back = try #require(inv.albums.first { $0.title == "Rom" })
        #expect(back.id != rom.albumID)
        #expect(back.parentID == romFolder)
        #expect(back.assetIDs == ids("a", 0..<60))
        #expect(inv["sommer"]?.assetIDs == Self.ownPhotos.union(ids("a", 100..<110)))
        #expect(inv.albums.filter { $0.title == "Rom" }.count == 1)
        #expect(await library.assets == allAssets)
    }

    // MARK: An interrupted undo is not the user's doing

    /// The undo deleted an album and then the app ended. Until that undo is settled, the
    /// album list check must not take the missing album for one the user deleted (which would
    /// stop its suggestion from ever coming back).
    @Test func interruptedUndoIsNotTakenForTheUsersDeletion() async throws {
        let library = representativeLibrary()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let executed = try await executor.execute(representativePlan(try await library.currentInventory()))
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        // The app ends right after Photos deleted the albums, before the steps were marked.
        let store = EndingPlanStore { plan in plan.steps.contains { if case .succeeded = $0.state, case .deleteCollection = $0.operation { true } else { false } } }
        _ = try? await ChangeExecutor(library: library, store: store).execute(undo)
        let interrupted = try #require(await store.saved.last)
        let now = try await library.currentInventory()
        #expect(!now.albums.contains { $0.title == "Rom" })

        let naive = tracker.reconcile(states, with: now)
        #expect(naive.newOverrides.contains { $0.decision == .doNotRecreateAlbum })
        let careful = tracker.reconcile(states, with: now, changing: interrupted.touchedCollections)
        #expect(careful.changes.isEmpty)
        #expect(careful.newOverrides.isEmpty)
        #expect(careful.updatedStates == states)

        // "So lassen": what the undo did is settled and recorded; nothing is left of Rom.
        var settled = try await executor.reconcileInterrupted(interrupted)
        for i in settled.steps.indices where !settled.steps[i].state.isFinished { settled.steps[i].state = .skipped(reason: StepState.leftByUserReason) }
        let recorded = tracker.record(settled, into: careful.updatedStates, inventory: now)
        #expect(!recorded.contains { $0.lastKnownTitle == "Rom" })
        #expect(tracker.reconcile(recorded, with: now).newOverrides.isEmpty)
    }
}
