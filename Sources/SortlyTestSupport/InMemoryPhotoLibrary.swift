import Foundation
import SortlyCore

/// In-memory photo library for tests and previews. Mirrors the PhotoKit semantics Albumist
/// relies on: collections have identities, albums reference assets (no copies), deleting an
/// album never deletes media.
public actor InMemoryPhotoLibrary: PhotoLibraryWriting {
    public private(set) var assets: Set<AssetID>
    public private(set) var inventory: CollectionInventory
    public var writeAllowed = true
    /// Simulates a crash: the write call number `failAfterWrites + 1` fails.
    public var failAfterWrites: Int?
    /// If true the failing write is applied before the error is thrown (crash between the
    /// PhotoKit commit and Albumist's journal update).
    public var crashAfterApplying = false
    public private(set) var writeCount = 0
    private var nextID = 1

    public struct SimulatedCrash: Error {}

    public init(assets: Set<AssetID>, collections: [CollectionSnapshot] = []) {
        self.assets = assets
        self.inventory = CollectionInventory(collections)
    }

    public func setFailAfterWrites(_ n: Int?, afterApplying: Bool = false) {
        failAfterWrites = n
        crashAfterApplying = afterApplying
        writeCount = 0
    }
    public func setWriteAllowed(_ allowed: Bool) { writeAllowed = allowed }

    /// Simulates a manual change by the user in the Photos app.
    public func userEdit(_ change: (inout CollectionInventory) -> Void) { change(&inventory) }

    private var pendingCrash = false

    private func countWrite() throws {
        if let limit = failAfterWrites, writeCount >= limit {
            if crashAfterApplying { pendingCrash = true } else { throw SimulatedCrash() }
        }
        writeCount += 1
    }

    private func finishWrite() throws {
        if pendingCrash {
            pendingCrash = false
            failAfterWrites = 0
            crashAfterApplying = false
            writeCount = 0
            throw SimulatedCrash()
        }
    }

    private func newID(_ prefix: String) -> CollectionID {
        defer { nextID += 1 }
        return CollectionID("\(prefix)-mem-\(nextID)")
    }

    public func canWrite() async -> Bool { writeAllowed }
    /// How often the whole album list was read (execution should read single albums).
    public private(set) var inventoryReads = 0
    public func currentInventory() async throws -> CollectionInventory {
        inventoryReads += 1
        if blankReadsToSkip > 0 {
            blankReadsToSkip -= 1
        } else if blankReads > 0 {
            blankReads -= 1
            return CollectionInventory()
        }
        return inventory
    }
    /// Simulates Photos handing out an empty album list for a moment: after `skipping` normal
    /// reads, the next `n` reads of the whole list come back empty.
    public func setBlankInventoryReads(_ n: Int, skipping: Int = 0) {
        blankReads = n
        blankReadsToSkip = skipping
    }
    private var blankReads = 0
    private var blankReadsToSkip = 0
    /// Simulates reads of single albums that fail (a Photos hiccup right after a change).
    public private(set) var failingCollectionReads = 0
    public func setFailingCollectionReads(_ n: Int) { failingCollectionReads = n }
    public struct ReadFailure: Error {}
    public func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        if failingCollectionReads > 0 {
            failingCollectionReads -= 1
            throw ReadFailure()
        }
        return inventory[id]
    }
    public func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { Set(ids).intersection(assets) }

    public func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await createFolder(title: title, parent: parent, noted: { _ in })
    }

    public func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await createAlbum(title: title, parent: parent, noted: { _ in })
    }

    /// Like PhotoKit: `noted` hears the new id inside the change, before it is stored (the
    /// placeholder's identifier), and the change waits for it. A crash before the request
    /// (`failAfterWrites`) gives no id; one after applying it leaves the id heard.
    public func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
        try await create(title: title, parent: parent, kind: .folder, noted: noted)
    }

    public func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
        try await create(title: title, parent: parent, kind: .userAlbum, noted: noted)
    }

    private func create(title: String, parent: CollectionID?, kind: CollectionKind,
                        noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
        try countWrite()
        let id = newID(kind == .folder ? "folder" : "album")
        await noted(id)
        inventory.upsert(CollectionSnapshot(id: id, title: title, kind: kind, parentID: parent))
        if let parent, var p = inventory[parent] { p.childIDs.append(id); inventory.upsert(p) }
        try finishWrite()
        return id
    }

    public func addAssets(_ ids: [AssetID], to album: CollectionID) async throws {
        try countWrite()
        guard var a = inventory[album], a.isEditableAlbum else { throw CocoaLikeError.notEditable }
        a.assetIDs.formUnion(Set(ids).intersection(assets))
        inventory.upsert(a)
        try finishWrite()
    }

    public func removeAssets(_ ids: [AssetID], from album: CollectionID) async throws {
        try countWrite()
        guard var a = inventory[album] else { throw CocoaLikeError.missing }
        a.assetIDs.subtract(ids)
        inventory.upsert(a)
        try finishWrite()
    }

    public func renameCollection(_ id: CollectionID, to title: String) async throws {
        try countWrite()
        guard var c = inventory[id] else { throw CocoaLikeError.missing }
        c.title = title
        inventory.upsert(c)
        try finishWrite()
    }

    public func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        try countWrite()
        guard var c = inventory[id] else { throw CocoaLikeError.missing }
        // Like the PhotoKit adapter: a target folder that is gone changes nothing.
        if let newParent, inventory[newParent]?.kind != .folder { throw CocoaLikeError.missing }
        if let old = c.parentID, var p = inventory[old] { p.childIDs.removeAll { $0 == id }; inventory.upsert(p) }
        c.parentID = newParent
        inventory.upsert(c)
        if let newParent, var p = inventory[newParent] { p.childIDs.append(id); inventory.upsert(p) }
        try finishWrite()
    }

    public func deleteCollection(_ id: CollectionID) async throws {
        try countWrite()
        guard let c = inventory[id] else { return }
        if let parent = c.parentID, var p = inventory[parent] { p.childIDs.removeAll { $0 == id }; inventory.upsert(p) }
        // Like Photos: deleting a folder deletes the albums and folders inside it as well.
        var doomed = [id]
        while let next = doomed.popLast() {
            doomed.append(contentsOf: inventory.collections.values.filter { $0.parentID == next }.map(\.id))
            inventory.remove(next)
        }
        try finishWrite()
        // Media are untouched – exactly like PhotoKit.
    }

    /// How often a batch deletion was requested (each one is one question from Photos).
    public private(set) var deleteRequests = 0

    /// What Photos does with the next batch deletions (seen on an iPhone, 15.11.).
    public enum DeletionBehavior: Sendable {
        case deletes
        /// The user taps "Don't Allow" in the iOS question.
        case declined
        /// No error, but nothing is gone (the adapter on the device reports `.notApplied`).
        case silentlyIgnored
    }
    public private(set) var deletionBehavior: DeletionBehavior = .deletes
    /// Behaves like this for the next `times` batch deletions, then deletes again.
    public func setDeletionBehavior(_ behavior: DeletionBehavior, times: Int = .max) {
        deletionBehavior = behavior
        deletionBehaviorLeft = times
    }
    private var deletionBehaviorLeft = 0

    public func deleteCollections(_ ids: [CollectionID]) async throws {
        try countWrite()
        deleteRequests += 1
        if deletionBehavior != .deletes {
            let behavior = deletionBehavior
            deletionBehaviorLeft -= 1
            if deletionBehaviorLeft <= 0 { deletionBehavior = .deletes }
            if behavior == .declined { throw LibraryWriteFailure.declinedByUser }
            return
        }
        for id in ids {
            guard let c = inventory[id] else { continue }
            if let parent = c.parentID, var p = inventory[parent] { p.childIDs.removeAll { $0 == id }; inventory.upsert(p) }
            var doomed = [id]
            while let next = doomed.popLast() {
                doomed.append(contentsOf: inventory.collections.values.filter { $0.parentID == next }.map(\.id))
                inventory.remove(next)
            }
        }
        try finishWrite()
    }

    public enum CocoaLikeError: Error { case missing, notEditable }
}

/// Plan store that keeps every saved version (lets tests inspect the journal).
public actor InMemoryPlanStore: PlanJournal {
    public private(set) var saved: [ChangePlan] = []
    public init() {}
    public func save(_ plan: ChangePlan) async throws { saved.append(plan) }
    public func save(_ plans: [ChangePlan]) async throws { saved.append(contentsOf: plans) }
    public func plan(_ id: SortlyID) async throws -> ChangePlan? { saved.last { $0.id == id } }
    /// Added to the plan as it is stored (`ChangePlanStoring.noteCreated`).
    public func noteCreated(_ id: CollectionID, key: String, in plan: ChangePlan) async throws {
        var noted = saved.last { $0.id == plan.id } ?? plan
        if noted.record == nil { noted.record = ExecutionRecord() }
        noted.record?.noteRequested(id, key: key)
        saved.append(noted)
    }
    public var latest: ChangePlan? { saved.last }
}
