import Foundation

/// Reference to a folder that already exists or is created earlier in the same plan.
public enum FolderRef: Hashable, Sendable, Codable {
    case topLevel
    case existing(CollectionID)
    case planned(String)
}

/// Reference to an album that already exists or is created earlier in the same plan.
public enum AlbumRef: Hashable, Sendable, Codable {
    case existing(CollectionID)
    case planned(String)
}

/// The complete, closed set of operations Albumist can perform (prompt §16.1).
/// There is deliberately no operation that deletes, modifies or copies original media.
public enum PlannedOperation: Hashable, Sendable, Codable {
    case createFolder(key: String, title: String, parent: FolderRef)
    case createAlbum(key: String, title: String, parent: FolderRef)
    case addAssets(album: AlbumRef, assets: [AssetID])
    case renameCollection(CollectionID, from: String, to: String)
    case moveCollection(CollectionID, from: CollectionID?, to: FolderRef)
    /// Removes album *memberships* only (merge or undo). Originals stay in the library.
    case removeAssets(album: CollectionID, assets: [AssetID])
    /// Deletes an album or folder *container*. Originals stay in the library.
    case deleteCollection(CollectionID, title: String)

    public var isStructural: Bool {
        switch self {
        case .renameCollection, .moveCollection, .removeAssets, .deleteCollection: true
        default: false
        }
    }
}

public enum StepState: Hashable, Sendable, Codable {
    case pending
    /// Started but not confirmed – must be reconciled with the library before retrying.
    case running(startedAt: Date)
    case succeeded(createdID: CollectionID?, verifiedAt: Date)
    case failed(reason: String)
    case skipped(reason: String)

    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .skipped: true
        default: false
        }
    }

    var isFailedOrSkipped: Bool {
        switch self {
        case .failed, .skipped: true
        default: false
        }
    }
}

public struct PlanStep: Hashable, Sendable, Codable, Identifiable {
    /// Deterministic idempotency key: plan id + index + content hash.
    public var id: String
    public var operation: PlannedOperation
    public var sourceID: SortlyID?
    public var state: StepState

    public init(id: String, operation: PlannedOperation, sourceID: SortlyID?, state: StepState = .pending) {
        self.id = id
        self.operation = operation
        self.sourceID = sourceID
        self.state = state
    }
}

public enum PlanConflict: Hashable, Sendable, Codable {
    /// Two new albums with the same title in the same folder.
    case duplicatePlannedTitle(title: String, folderPath: [String], sources: [SortlyID])
    /// An unrelated album with this title already exists in the target folder.
    case titleExistsInFolder(title: String, existing: CollectionID)
    case albumMissing(CollectionID)
    case albumNotEditable(CollectionID)
    case albumChangedSincePreview(CollectionID)
    case assetsUnavailable(count: Int)
    case writeAccessMissing

    /// Blocking conflicts prevent execution until the user decides again (prompt §7, Schritt 7/9).
    public var isBlocking: Bool {
        switch self {
        case .titleExistsInFolder: false
        default: true
        }
    }
}

/// Non-blocking information shown with the plan.
public enum PlanNote: Hashable, Sendable, Codable {
    case respectedManualRemovals(count: Int)
    case skippedDeletedByUser(SortlyID)
    case skippedRejected(SortlyID)
    case optionalItemsNotIncluded(count: Int)
}

public enum PlanStatus: String, Sendable, Codable {
    case draft, confirmed, running, completed, completedWithErrors, cancelled
}

/// A concrete, persisted change plan. Only confirmed plans are executed (prompt §16).
public struct ChangePlan: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var createdAt: Date
    public var confirmedAt: Date?
    public var status: PlanStatus
    /// Fingerprints of every existing collection the plan touches, taken at preview time.
    public var baseline: [CollectionID: String]
    /// Collection ids that existed at preview time (to recognize albums created by us).
    public var baselineCollectionIDs: Set<CollectionID>
    public var steps: [PlanStep]
    public var conflicts: [PlanConflict]
    public var notes: [PlanNote]
    /// Planned key → created collection id, filled during execution.
    public var resolvedKeys: [String: CollectionID]
    /// Set on an undo plan: the plan whose changes it takes back.
    public var reverts: SortlyID? = nil
    /// What execution really did, step by step (written before every library call, settled
    /// after it). Undo, the managed-album records, the result screen and the free-album count
    /// use it instead of the planned operations. Missing in plans saved by older versions.
    public var record: ExecutionRecord? = nil
    /// Albums this plan may delete only while they hold nothing but these media (undo and
    /// removal plans). An album that got other photos meanwhile is kept; only these leave it.
    public var deleteGuards: [CollectionID: Set<AssetID>]? = nil
    /// Set once everything that follows a run (managed albums, decisions, free albums) is
    /// stored. A finished plan without it is completed again at the next launch.
    public var finalizedAt: Date? = nil
    /// Set on a retry plan ("Erneut versuchen"): the plan whose unfinished steps it runs.
    public var retries: SortlyID? = nil
    /// Albums the retried plan created. Adding to them now does not use another free album.
    public var albumsFromRetriedPlan: Set<CollectionID>? = nil

    public var summary: PlanSummary { PlanSummary(self) }

    /// Albums this plan uses from the free allowance: new albums and extended existing ones,
    /// except albums an earlier run of the same changes created (counted with that run).
    /// `applied` counts what really happened, otherwise what is planned. An album Photos made
    /// whose check failed afterwards (its id is written down) counts as made: it is in Photos,
    /// and undo removes it like any other (plugin review N4: it was never counted).
    public func freeAlbumUse(applied: Bool) -> Int {
        var newAlbums = 0
        var extended = Set<CollectionID>()
        for step in steps {
            let succeeded: Bool = if case .succeeded = step.state { true } else { false }
            switch step.operation {
            case .createAlbum(let key, _, _):
                if !applied || succeeded || resolvedKeys[key] != nil { newAlbums += 1 }
            case .addAssets(.existing(let id), let assets):
                let added = applied ? confirmedMedia(of: step) : assets
                if !added.isEmpty { extended.insert(id) }
            default:
                break
            }
        }
        return newAlbums + extended.subtracting(albumsFromRetriedPlan ?? []).count
    }

    /// Existing albums this plan verifiably added media to (the ones `freeAlbumUse(applied:
    /// true)` counts as extended).
    public var extendedAlbums: Set<CollectionID> {
        var extended = Set<CollectionID>()
        for step in steps {
            if case .addAssets(.existing(let id), _) = step.operation, !confirmedMedia(of: step).isEmpty { extended.insert(id) }
        }
        return extended
    }
    /// What really happened (planned counts for plans from older versions).
    public var appliedSummary: PlanSummary { PlanSummary(applied: self) }

    /// Media an add or remove step verifiably changed: the settled journal entry, and nothing
    /// while the outcome is unclear (interrupted, or the read-back failed), so an intent is
    /// never counted as done (audit 2, 6.2). Plans from versions without a journal fall back
    /// to their succeeded steps. Summary, free albums and receipt all count with this.
    public func confirmedMedia(of step: PlanStep) -> [AssetID] {
        let planned: [AssetID]
        switch step.operation {
        case .addAssets(_, let assets), .removeAssets(_, let assets): planned = assets
        default: return []
        }
        let succeeded: Bool = if case .succeeded = step.state { true } else { false }
        if record?.unverified.contains(step.id) == true { return [] }
        return record?.media[step.id] ?? (succeeded ? planned : [])
    }
}

extension ChangePlan {
    /// This plan with the ids written down for its new albums and folders in `stored` (the same
    /// plan's record as it is stored) that it lacks (`ExecutionRecord.takeNotedIDs`).
    @discardableResult
    public mutating func takeNotedIDs(from stored: ExecutionRecord?) -> Bool {
        guard let stored, !stored.maybeCreated.isEmpty || !stored.earlierMaybeCreated.isEmpty else { return false }
        var merged = record ?? ExecutionRecord()
        guard merged.takeNotedIDs(from: stored) else { return false }
        record = merged
        return true
    }
}

/// The journal of what a plan really changed.
public struct ExecutionRecord: Hashable, Sendable, Codable {
    /// Step id → media the step added (addAssets) or removed (removeAssets, or our media
    /// taken out of an album that was kept instead of deleted). While a step id is in
    /// `unverified` this is the intent written before the library call; afterwards it is
    /// exactly what the library shows changed.
    public var media: [String: [AssetID]] = [:]
    /// Steps whose library call may or may not have happened (interrupted, or the read-back failed).
    public var unverified: Set<String> = []
    /// Planned keys whose album or folder was found after an interruption instead of being
    /// created verifiably by this run. Albumist cannot prove it made them, so it never
    /// deletes them; undo only takes its own media back out.
    public var adoptedKeys: Set<String> = []
    /// Albums this plan deleted, with what they held, so the deletion can be taken back.
    public var deletedAlbums: [CollectionID: DeletedAlbumRecord] = [:]
    /// Step id → number of planned media that were no longer in the library.
    public var unavailable: [String: Int] = [:]
    /// Existing albums and folders the plan touched, with the name and folder path they had
    /// when it ran, so the receipt keeps showing those names after a later rename (audit 2, 7.2).
    public var names: [CollectionID: RecordedName] = [:]
    /// Planned key → the id Photos gave the new album or folder, written down inside the change
    /// before Photos stored it (`noteRequested`, review P2-01), or of a request that then got no
    /// answer in time (`PhotosNotResponding`, with `maybeCreatedAt`): it may land later, and is
    /// never forgotten. If it
    /// is there when the plan goes on or is taken back, it is this plan's own (made, not
    /// adopted), never made a second time. While it may still land, no second one is made
    /// (`ChangeExecutor.lateCreateWait`); one that lands after the plan made the album anyway is
    /// still Albumist's: the album records keep it and undo deletes it (`mayStillLand`; second
    /// and third review of the PhotoKit limits, 1 and N2).
    public var maybeCreated: [String: CollectionID] = [:]
    /// When the request of `maybeCreated[key]` was given up (only for a request that got no
    /// answer: an id merely written down inside the change is not waited for).
    public var maybeCreatedAt: [String: Date] = [:]
    /// Earlier `maybeCreated` ids of a key whose later request got no answer either.
    public var earlierMaybeCreated: [CollectionID] = []
    /// Step id → photos of an add step that were already in someone else's album when a
    /// resumed plan reached it, while the journal may have been one entry behind Photos (review
    /// P2-07): Albumist may have put them there, or the user. Never claimed (undo leaves them),
    /// but named after an undo (`UndoRemainder`).
    public var unclear: [String: [AssetID]] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case media, unverified, adoptedKeys, deletedAlbums, unavailable, names, maybeCreated, maybeCreatedAt, earlierMaybeCreated, unclear
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decodeIfPresent([String: [AssetID]].self, forKey: .media) ?? [:]
        unverified = try c.decodeIfPresent(Set<String>.self, forKey: .unverified) ?? []
        adoptedKeys = try c.decodeIfPresent(Set<String>.self, forKey: .adoptedKeys) ?? []
        deletedAlbums = try c.decodeIfPresent([CollectionID: DeletedAlbumRecord].self, forKey: .deletedAlbums) ?? [:]
        unavailable = try c.decodeIfPresent([String: Int].self, forKey: .unavailable) ?? [:]
        names = try c.decodeIfPresent([CollectionID: RecordedName].self, forKey: .names) ?? [:]
        maybeCreated = try c.decodeIfPresent([String: CollectionID].self, forKey: .maybeCreated) ?? [:]
        maybeCreatedAt = try c.decodeIfPresent([String: Date].self, forKey: .maybeCreatedAt) ?? [:]
        earlierMaybeCreated = try c.decodeIfPresent([CollectionID].self, forKey: .earlierMaybeCreated) ?? []
        unclear = try c.decodeIfPresent([String: [AssetID]].self, forKey: .unclear) ?? [:]
    }

    /// Photos gave this id to the new album or folder of `key`, inside the change and before
    /// it stored it (`ChangePlanStoring.noteCreated`, review P2-01): if it is in the library,
    /// Albumist made it. Unlike `noteMaybeCreated` nothing waits for it: after an app that
    /// ended, Photos has stored the change or never will. An earlier id of the same key stays
    /// Albumist's (`earlierMaybeCreated`).
    public mutating func noteRequested(_ id: CollectionID, key: String) {
        guard maybeCreated[key] != id else { return }
        if let earlier = maybeCreated[key], !earlierMaybeCreated.contains(earlier) {
            earlierMaybeCreated.append(earlier)
        }
        maybeCreated[key] = id
        maybeCreatedAt[key] = nil
    }

    /// Takes the ids written down for new albums and folders in `stored` (the same plan as it is
    /// stored) that this copy lacks: an id written from inside a change that Photos ran only
    /// after the run stopped waiting reaches the stored plan, not the copy the app or a run
    /// holds (second review of P2-01, S1). Never drops anything: a key this copy lacks takes the
    /// stored id (and when it was given up); a different stored id for a key this copy knows
    /// stays Albumist's as an earlier one (`earlierMaybeCreated`, which is joined too). Returns
    /// whether anything was taken.
    @discardableResult
    public mutating func takeNotedIDs(from stored: ExecutionRecord) -> Bool {
        var changed = false
        // Only the entries that differ are sorted (a save of a large plan usually has none).
        let differing = stored.maybeCreated.filter { maybeCreated[$0.key] != $0.value }
        for (key, id) in differing.sorted(by: { $0.key < $1.key }) {
            if let mine = maybeCreated[key] {
                if mine != id, !earlierMaybeCreated.contains(id) {
                    earlierMaybeCreated.append(id)
                    changed = true
                }
            } else {
                maybeCreated[key] = id
                if let at = stored.maybeCreatedAt[key] { maybeCreatedAt[key] = at }
                changed = true
            }
        }
        guard !stored.earlierMaybeCreated.isEmpty else { return changed }
        let current = Set(maybeCreated.values)
        for id in stored.earlierMaybeCreated where !earlierMaybeCreated.contains(id) && !current.contains(id) {
            earlierMaybeCreated.append(id)
            changed = true
        }
        return changed
    }

    /// Until when the create of `key`, whose request got no answer (`maybeCreatedAt`), may
    /// still land if it is not in the library (`ChangeExecutor.lateCreateWait`); nil when it
    /// cannot any more: its request returned in this launch (`answered`), the wait is over, or
    /// it was only written down inside the change (an app that ended, not a request without
    /// an answer). A clock set back never makes it wait longer than the wait (round-3 review, L2).
    public func lateCreateWaitsUntil(_ key: String, answered: Bool, now: Date) -> Date? {
        guard maybeCreated[key] != nil, let since = maybeCreatedAt[key], !answered else { return nil }
        let until = since.addingTimeInterval(ChangeExecutor.lateCreateWait)
        if until.timeIntervalSince(now) > ChangeExecutor.lateCreateWait { return nil }
        return now < until ? until : nil
    }

    /// A request that got no answer gave Photos this id for a new album or folder.
    mutating func noteMaybeCreated(_ id: CollectionID, key: String, at date: Date) {
        if let earlier = maybeCreated[key], earlier != id, !earlierMaybeCreated.contains(earlier) {
            earlierMaybeCreated.append(earlier)
        }
        maybeCreated[key] = id
        maybeCreatedAt[key] = date
    }

    /// Albums and folders Albumist asked Photos for that may still land, or landed, next to
    /// the one the plan settled on for their key: Albumist's own, never the user's.
    public func mayStillLand(resolved: [String: CollectionID]) -> [CollectionID] {
        let latest = maybeCreated.sorted { $0.key < $1.key }.compactMap { key, id in resolved[key] == id ? nil : id }
        return earlierMaybeCreated.filter { !resolved.values.contains($0) } + latest
    }

    /// Notes the current name and path of every existing album or folder the plan refers to,
    /// once: a resumed run keeps the names from its first start.
    mutating func recordNames(of plan: ChangePlan, inventory: CollectionInventory) {
        func note(_ id: CollectionID) {
            guard names[id] == nil, let node = inventory[id] else { return }
            var path: [String] = []
            var parent = node.parentID
            while let p = parent, let folder = inventory[p], path.count < 32 {
                path.insert(folder.title, at: 0)
                parent = folder.parentID
            }
            names[id] = RecordedName(title: node.title, folderPath: path)
        }
        for step in plan.steps {
            switch step.operation {
            case .addAssets(.existing(let id), _), .removeAssets(let id, _), .renameCollection(let id, _, _), .deleteCollection(let id, _):
                note(id)
            case .createFolder(_, _, .existing(let id)), .createAlbum(_, _, .existing(let id)):
                note(id)
            default:
                break
            }
        }
    }

    /// Writes the intent of a step before its library call.
    mutating func begin(_ step: String, _ assets: [AssetID]) {
        media[step] = assets
        unverified.insert(step)
    }

    /// Replaces the intent with what really changed.
    mutating func settle(_ step: String, _ assets: [AssetID]) {
        media[step] = assets
        unverified.remove(step)
    }
}

public struct RecordedName: Hashable, Sendable, Codable {
    public var title: String
    /// Titles of the folders above it, outermost first.
    public var folderPath: [String]
}

public struct DeletedAlbumRecord: Hashable, Sendable, Codable {
    public var title: String
    public var parentID: CollectionID?
    public var members: [AssetID]
}

/// What the final preview shows (prompt §7, Schritt 8).
public struct PlanSummary: Hashable, Sendable {
    public var newFolders = 0
    public var newAlbums = 0
    public var extendedAlbums = 0
    public var renamedCollections = 0
    public var movedCollections = 0
    public var removedMemberships = 0
    public var deletedContainers = 0
    /// Number of different media affected.
    public var distinctAssets = 0
    /// Number of album assignments (one photo in three albums = 3).
    public var totalAssignments = 0
    /// Planned media that were no longer in the library (applied summaries only).
    public var unavailableAssets = 0
    /// Steps that did not complete (applied summaries only).
    public var failedSteps = 0
    /// Structural guarantees – there is no operation type that could change these.
    public let originalsDeleted = 0
    public let originalCopiesCreated = 0

    /// What really happened in an executed plan: only verified changes count. Plans from
    /// versions without an execution record fall back to their succeeded steps.
    public init(applied plan: ChangePlan) {
        let record = plan.record
        var distinct = Set<AssetID>()
        var extended = Set<CollectionID>()
        for step in plan.steps {
            let succeeded: Bool = if case .succeeded = step.state { true } else { false }
            if case .failed = step.state { failedSteps += 1 }
            switch step.operation {
            case .createFolder: if succeeded { newFolders += 1 }
            case .createAlbum: if succeeded { newAlbums += 1 }
            case .addAssets(let album, _):
                let added = plan.confirmedMedia(of: step)
                distinct.formUnion(added)
                totalAssignments += added.count
                if case .existing(let id) = album, !added.isEmpty { extended.insert(id) }
                unavailableAssets += record?.unavailable[step.id] ?? 0
            case .renameCollection: if succeeded { renamedCollections += 1 }
            case .moveCollection: if succeeded { movedCollections += 1 }
            case .removeAssets:
                removedMemberships += plan.confirmedMedia(of: step).count
            case .deleteCollection: if succeeded { deletedContainers += 1 }
            }
        }
        extendedAlbums = extended.count
        distinctAssets = distinct.count
    }

    public init(_ plan: ChangePlan) {
        var distinct = Set<AssetID>()
        var extended = Set<CollectionID>()
        for step in plan.steps {
            switch step.operation {
            case .createFolder: newFolders += 1
            case .createAlbum: newAlbums += 1
            case .addAssets(let album, let assets):
                distinct.formUnion(assets)
                totalAssignments += assets.count
                if case .existing(let id) = album { extended.insert(id) }
            case .renameCollection: renamedCollections += 1
            case .moveCollection: movedCollections += 1
            case .removeAssets(_, let assets): removedMemberships += assets.count
            case .deleteCollection: deletedContainers += 1
            }
        }
        extendedAlbums = extended.count
        distinctAssets = distinct.count
    }
}
