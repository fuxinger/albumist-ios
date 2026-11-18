import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Small findings of the plugin review (15.11.) about free albums and undo: N4 the free-album
/// count, N5 an album left empty after two undos in the other order, N6 a deletion whose
/// read-back failed. (N7 is in `SortlyStoreTests`, K6 in `EmptyLibraryStateTests`.)
@Suite("Plugin review: free-album count, undo order, unverified deletions")
struct PluginReviewLaunchTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)
    let allAssets: Set<AssetID> = ids("a", 0..<100)
    let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))

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

    func extend(_ id: String, _ album: CollectionID, _ assets: Set<AssetID>) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: SortlyID(id), kind: .trip, title: "Rom", folderPath: ["Reisen"], assetIDs: assets),
                          decision: .extendExisting(album))
    }

    func plan(_ steps: [PlanStep], resolved: [String: CollectionID] = [:], record: ExecutionRecord? = nil) -> ChangePlan {
        var p = ChangePlan(id: SortlyID("first"), createdAt: Date(), confirmedAt: Date(), status: .completedWithErrors, baseline: [:],
                           baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [], resolvedKeys: resolved)
        p.record = record
        return p
    }

    // MARK: N4 Free albums

    /// The first run filled an existing album partly; "Erneut versuchen" fills it up. That album
    /// was counted with the first run and must not be counted again.
    @Test func retryDoesNotCountAPartlyFilledExistingAlbumTwice() {
        var record = ExecutionRecord()
        record.media["0"] = ["x"] // only x arrived, y did not
        let first = plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("e"), assets: ["x", "y"]), sourceID: SortlyID("s"),
                     state: .failed(reason: "added media could not be verified")),
        ], record: record)
        #expect(first.freeAlbumUse(applied: true) == 1)
        #expect(first.extendedAlbums == ["e"])
        let current = CollectionInventory([CollectionSnapshot(id: "e", title: "Familie", assetIDs: ["mine", "x"])])
        let retry = try! #require(RetryPlanner().retryPlan(for: first, current: current, id: SortlyID("r")))
        #expect(retry.steps.map(\.operation) == [.addAssets(album: .existing("e"), assets: ["y"])])
        #expect(retry.freeAlbumUse(applied: false) == 0)
        var applied = retry
        applied.steps[0].state = done
        #expect(applied.freeAlbumUse(applied: true) == 0)

        // An album the first run did not get anything into is counted with the retry.
        let nothing = plan([PlanStep(id: "0", operation: .addAssets(album: .existing("e"), assets: ["y"]), sourceID: nil,
                                     state: .failed(reason: "x"))], record: ExecutionRecord())
        #expect(nothing.freeAlbumUse(applied: true) == 0)
        #expect(RetryPlanner().retryPlan(for: nothing, current: current)?.freeAlbumUse(applied: false) == 1)
    }

    /// Photos made the album, then its check failed: it is in Photos (and undo removes it),
    /// so it counts. An album that was never made does not.
    @Test func albumMadeWhoseCheckFailedIsCounted() {
        let made = plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil,
                     state: .failed(reason: "created collection could not be verified")),
            PlanStep(id: "1", operation: .createAlbum(key: "B", title: "Paris", parent: .topLevel), sourceID: nil,
                     state: .failed(reason: "interrupted")),
        ], resolved: ["A": "a1"])
        #expect(made.freeAlbumUse(applied: true) == 1)
        #expect(made.freeAlbumUse(applied: false) == 2)
    }

    /// The real run: Photos creates "Rom", the check right after it fails.
    @Test func albumMadeWhoseCheckFailedIsCountedEndToEnd() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        // The album read right after creating it fails once.
        let p = confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10))], inventory: CollectionInventory()))
        let failingCheck = FailingCheckLibrary(inner: library, title: "Rom")
        let result = try await ChangeExecutor(library: failingCheck, store: InMemoryPlanStore()).execute(p)
        let rome = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" })
        #expect(result.steps.contains { if case .failed(let r) = $0.state { r == "created collection could not be verified" } else { false } })
        #expect(result.freeAlbumUse(applied: true) == 1)
        // Undo removes it, and gives that one album back.
        let undo = UndoPlanner().undoPlan(for: result, current: try await library.currentInventory())
        #expect(undo.steps.contains { $0.operation == .deleteCollection(rome.id, title: "Rom") })
    }

    /// Undo of an interrupted plan (the way since K1): what it did is first counted like
    /// "So lassen", then given back with the undo. The old total from earlier versions is
    /// never touched, and the count ends where it started.
    @Test func undoOfAnInterruptedPlanGivesBackOnlyWhatWasCounted() async throws {
        var ledger = FreeAlbumLedger(legacyUsed: 4)
        let settled = plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: done),
            PlanStep(id: "1", operation: .createAlbum(key: "B", title: "Paris", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], resolved: ["A": "a1"])
        let current = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom")])
        let way = InterruptedPlanUndo(settled: settled, current: current)
        ledger.record(plan: way.kept.id, albums: way.kept.freeAlbumUse(applied: true))
        #expect(ledger.used == 5)
        ledger.giveBack(plan: way.kept.id, albums: way.kept.freeAlbumUse(applied: true))
        #expect(ledger.used == 4)
        #expect(ledger.legacyLeft == 4)

        // A plan that made nothing is never counted, and giving it back takes nothing off the old total.
        var other = FreeAlbumLedger(legacyUsed: 4)
        let nothing = plan([PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil,
                                     state: .skipped(reason: StepState.leftByUserReason))])
        other.record(plan: nothing.id, albums: nothing.freeAlbumUse(applied: true))
        other.giveBack(plan: nothing.id, albums: nothing.freeAlbumUse(applied: true))
        #expect(other.used == 4)
        #expect(other.legacyLeft == 4)
    }

    /// Second review 18.11.: one copy counted a plan per plan, the other gave the same plan
    /// back from the older total. Put together, the plan comes back once, not twice.
    @Test func aPlanCountedInOneCopyAndGivenBackFromTheOldTotalInTheOtherComesBackOnce() {
        var perPlan = FreeAlbumLedger(legacyUsed: 4)
        perPlan.record(plan: SortlyID("p"), albums: 2)
        #expect(perPlan.used == 6)
        var fromOld = FreeAlbumLedger(legacyUsed: 4)
        fromOld.giveBack(plan: SortlyID("p"), albums: 2)
        #expect(fromOld.legacyLeft == 2)
        let merged = perPlan.merged(with: fromOld)
        #expect(merged.used == 4)
        #expect(fromOld.merged(with: perPlan) == merged)
        #expect(merged.merged(with: perPlan) == merged)
    }

    /// Deleting and installing Albumist again: the user defaults are empty, the keychain copy
    /// still has the count. Put together, nothing used is lost and nothing given back counts.
    @Test func keychainCopySurvivesANewInstall() {
        var kept = FreeAlbumLedger()
        kept.record(plan: SortlyID("p1"), albums: 6)
        kept.record(plan: SortlyID("p2"), albums: 3)
        kept.giveBack(plan: SortlyID("p2"), albums: 3)
        let afterReinstall = FreeAlbumLedger()
        let merged = afterReinstall.merged(with: kept)
        #expect(merged.used == 6)
        #expect(merged.remaining(limit: 10) == 4)
        #expect(merged == kept)
        // Both orders give the same, and merging again changes nothing.
        #expect(kept.merged(with: afterReinstall) == merged)
        #expect(merged.merged(with: kept) == merged)

        // The two copies went apart (an app ended between the two writes): the union counts.
        var defaults = kept
        defaults.record(plan: SortlyID("p3"), albums: 1)
        var keychain = kept
        keychain.giveBack(plan: SortlyID("p1"), albums: 6)
        let both = defaults.merged(with: keychain)
        #expect(both.byPlan == ["p3": 1])
        #expect(both.returned == ["p1", "p2"])
        #expect(FreeAlbumLedger(legacyUsed: 7).merged(with: FreeAlbumLedger(legacyUsed: 2)).legacyUsed == 7)
    }

    // MARK: N5 Undo in the other order

    /// P makes "Rom", Q adds to "Rom". Taking back P and then Q left "Rom" behind empty.
    @Test func undoInTheOtherOrderLeavesNoEmptyAlbum() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let tracker = ManagedAlbumTracker()
        let p = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("p", "Rom", ids("a", 0..<10))], inventory: try await library.currentInventory())))
        var states = tracker.record(p, into: [], inventory: try await library.currentInventory())
        let rome = try #require(states.first { $0.lastKnownTitle == "Rom" }).albumID
        let q = try await executor.execute(confirmed(planner.makePlan(from: [extend("q", rome, ids("a", 10..<15))], inventory: try await library.currentInventory())))
        states = tracker.record(q, into: states, inventory: try await library.currentInventory())

        func created() -> Set<CollectionID> { Set(states.filter(\.createdBySortly).map(\.albumID)) }
        func owned() -> [CollectionID: Set<AssetID>] {
            var result: [CollectionID: Set<AssetID>] = [:]
            for s in states { result[s.albumID, default: []].formUnion(s.addedBySortly) }
            return result
        }
        // Undo P first: Rom keeps Q's photos.
        let undoP = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: p, current: try await library.currentInventory(),
                                                                                owned: owned(), createdByAlbumist: created())))
        states = tracker.record(undoP, into: states, inventory: try await library.currentInventory())
        #expect(try await library.currentInventory()[rome]?.assetIDs == ids("a", 10..<15))
        // Then Q: Rom would be empty, and it is Albumist's own album. It goes.
        let undoQ = UndoPlanner().undoPlan(for: q, current: try await library.currentInventory(), owned: owned(), createdByAlbumist: created())
        #expect(undoQ.steps.contains { $0.operation == .deleteCollection(rome, title: "Rom") })
        _ = try await executor.execute(confirmed(undoQ))
        #expect(try await library.currentInventory()[rome] == nil)
        // The photos are untouched.
        #expect(await library.assets == allAssets)
    }

    /// The same, but the album is the user's own, or the user put a photo of their own in:
    /// only Albumist's photos leave it, the album stays.
    @Test func undoKeepsAnAlbumThatIsNotEmptyOrNotAlbumists() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["a-90"])
        let current = CollectionInventory([mine])
        var record = ExecutionRecord()
        record.media["0"] = ["a-1"]
        let q = plan([PlanStep(id: "0", operation: .addAssets(album: .existing("mine"), assets: ["a-1"]), sourceID: nil, state: done)], record: record)
        let withPhoto = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["a-1", "a-90"])])
        // Albumist's album, but with the user's photo in it.
        let undo = UndoPlanner().undoPlan(for: q, current: withPhoto, createdByAlbumist: ["mine"])
        #expect(undo.steps.map(\.operation) == [.removeAssets(album: "mine", assets: ["a-1"])])
        // The user's own album (not made by Albumist): never deleted.
        let onlyOurs = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["a-1"])])
        let undo2 = UndoPlanner().undoPlan(for: q, current: onlyOurs, createdByAlbumist: [])
        #expect(undo2.steps.map(\.operation) == [.removeAssets(album: "mine", assets: ["a-1"])])
        _ = current
    }

    // MARK: N6 Deletion whose read-back failed

    /// Removing "Rom" (Albumist's album): Photos deletes it, but the album list cannot be read
    /// afterwards. The entry with what Rom held stays, so "Rückgängig" can bring it back.
    @Test func unverifiedDeletionKeepsItsRestoreEntry() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["a-99"])])
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let made = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10))], inventory: try await library.currentInventory())))
        let tracker = ManagedAlbumTracker()
        let rome = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first { $0.lastKnownTitle == "Rom" })
        let removalPlan = tracker.removalPlan(for: rome, current: try await library.currentInventory())

        let blind = BlindAfterDeletion(inner: library)
        let removal = try await ChangeExecutor(library: blind, store: InMemoryPlanStore()).execute(confirmed(removalPlan))
        #expect(try await library.currentInventory()[rome.albumID] == nil) // really gone
        let step = try #require(removal.steps.first { if case .deleteCollection(rome.albumID, _) = $0.operation { true } else { false } })
        #expect(step.state == .failed(reason: StepState.deletionUnverifiedReason))
        #expect(removal.record?.deletedAlbums[rome.albumID]?.members.count == 10)

        // Undo brings Rom back with its photos.
        let undo = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: removal, current: try await library.currentInventory())))
        #expect(undo.status == .completed)
        let back = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" })
        #expect(back.assetIDs == ids("a", 0..<10))
    }

    /// The read-back failed and the album is in fact still there (Photos did nothing). An undo
    /// planned with an album list that lacks it for a moment must not make a second "Rom".
    @Test func undoNeverRestoresAnAlbumThatIsStillThere() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["a-99"])])
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let made = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10))], inventory: try await library.currentInventory())))
        let tracker = ManagedAlbumTracker()
        let rome = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first { $0.lastKnownTitle == "Rom" })
        let blind = BlindAfterDeletion(inner: library, deletes: false)
        let removal = try await ChangeExecutor(library: blind, store: InMemoryPlanStore())
            .execute(confirmed(tracker.removalPlan(for: rome, current: try await library.currentInventory())))
        #expect(try await library.currentInventory()[rome.albumID] != nil)
        #expect(removal.record?.deletedAlbums[rome.albumID] != nil)

        // Planned with a list that lacks Rom: the restore step is planned …
        var lacking = try await library.currentInventory()
        lacking.remove(rome.albumID)
        let undo = UndoPlanner().undoPlan(for: removal, current: lacking)
        #expect(undo.steps.contains { $0.operation.restoredAlbum == rome.albumID })
        // … but Photos, asked for Rom on its own, still has it: nothing is made twice.
        let result = try await executor.execute(confirmed(undo))
        #expect(result.steps.contains { $0.state == .skipped(reason: StepState.stillThereReason) })
        #expect(try await library.currentInventory().albums.filter { $0.title == "Rom" }.count == 1)
    }

    /// A deletion Photos said no to (or that verifiably did not happen) never keeps the entry.
    @Test func declinedDeletionKeepsNoRestoreEntry() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let made = try await executor.execute(confirmed(planner.makePlan(from: [newAlbum("r", "Rom", ids("a", 0..<10))], inventory: try await library.currentInventory())))
        let tracker = ManagedAlbumTracker()
        let rome = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first { $0.lastKnownTitle == "Rom" })
        await library.setDeletionBehavior(.declined, times: 1)
        let removal = try await executor.execute(confirmed(tracker.removalPlan(for: rome, current: try await library.currentInventory())))
        #expect(removal.record?.deletedAlbums[rome.albumID] == nil)
        #expect(StepState.failed(reason: StepState.deletionDeclinedReason).deletionMayHaveHappened == false)
        #expect(StepState.failed(reason: StepState.deletionUnverifiedReason).deletionMayHaveHappened)
    }
}

/// The album read right after Photos made an album with `title` fails once (the check of a
/// created album, audit 2, 1.7).
struct FailingCheckLibrary: PhotoLibraryWriting {
    let inner: InMemoryPhotoLibrary
    let title: String
    let failed = Flag()

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var created: CollectionID?
        private var used = false
        func set(_ id: CollectionID) { lock.withLock { created = id } }
        func take(_ id: CollectionID) -> Bool {
            lock.withLock {
                guard !used, created == id else { return false }
                used = true
                return true
            }
        }
    }
    struct ReadFailure: Error {}

    func canWrite() async -> Bool { await inner.canWrite() }
    func currentInventory() async throws -> CollectionInventory { try await inner.currentInventory() }
    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await inner.availableAssets(ids) }
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        if failed.take(id) { throw ReadFailure() }
        return try await inner.collection(id)
    }
    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await inner.createFolder(title: title, parent: parent) }
    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        let id = try await inner.createAlbum(title: title, parent: parent)
        if title == self.title { failed.set(id) }
        return id
    }
    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws { try await inner.addAssets(assets, to: album) }
    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await inner.removeAssets(assets, from: album) }
    func renameCollection(_ id: CollectionID, to title: String) async throws { try await inner.renameCollection(id, to: title) }
    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        try await inner.moveCollection(id, from: oldParent, to: newParent)
    }
    func deleteCollection(_ id: CollectionID) async throws { try await inner.deleteCollection(id) }
    func deleteCollections(_ ids: [CollectionID]) async throws { try await inner.deleteCollections(ids) }
}

/// After a batch deletion the album list cannot be read any more (Photos busy, iCloud): the
/// deletion cannot be verified. `deletes: false` takes the request without doing anything.
struct BlindAfterDeletion: PhotoLibraryWriting {
    let inner: InMemoryPhotoLibrary
    var deletes = true
    let blind = Blind()

    final class Blind: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.withLock { on = true } }
        var isOn: Bool { lock.withLock { on } }
    }
    struct ReadFailure: Error {}

    func canWrite() async -> Bool { await inner.canWrite() }
    func currentInventory() async throws -> CollectionInventory {
        if blind.isOn { throw ReadFailure() }
        return try await inner.currentInventory()
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
    func deleteCollections(_ ids: [CollectionID]) async throws {
        if deletes { try await inner.deleteCollections(ids) }
        blind.set()
    }
}
