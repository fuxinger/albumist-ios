import Foundation

/// The only write interface to the photo library. Implemented with PhotoKit in the app
/// and in memory for tests. It has no method that could delete or alter original media.
public protocol PhotoLibraryWriting: Sendable {
    func canWrite() async -> Bool
    func currentInventory() async throws -> CollectionInventory
    /// Which of the given assets still exist and are accessible.
    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID>
    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID
    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID
    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws
    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws
    func renameCollection(_ id: CollectionID, to title: String) async throws
    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws
    /// Removes an album or folder container. Media stay in the library.
    func deleteCollection(_ id: CollectionID) async throws
    /// Removes several albums and folders in one request. Photos asks the user before it
    /// deletes albums, once per request: one request means one question instead of one per album.
    func deleteCollections(_ ids: [CollectionID]) async throws
    /// One album or folder, read on its own. Execution checks every step this way instead of
    /// reading the whole album list (minutes saved on large plans).
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot?
    /// Like `createFolder` and `createAlbum`; `noted` hears the new id as soon as Photos assigns
    /// it, before the change is committed, so a request Photos does not answer in time
    /// (`PhotosNotResponding`) leaves its id behind (second review of the PhotoKit limits, 1).
    func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) -> Void) async throws -> CollectionID
    func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) -> Void) async throws -> CollectionID
    /// A change request sent earlier has not been answered yet: Photos may still carry it out,
    /// so what the library shows now is not final (`PhotosDeadline`).
    func hasUnansweredWrites() async -> Bool
}

/// Why Photos did not carry out a deletion, as far as the library adapter can tell. Other
/// errors keep their system text (reduced to domain and code in the diagnostic report).
public enum LibraryWriteFailure: Error, Sendable, Equatable {
    /// The user answered "Don't Allow" when iOS asked to confirm the deletion.
    case declinedByUser
    /// Photos reported success, but the albums or folders were still there afterwards.
    case notApplied
}

extension PhotoLibraryWriting {
    public func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        try await currentInventory()[id]
    }

    public func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) -> Void) async throws -> CollectionID {
        let id = try await createFolder(title: title, parent: parent)
        noted(id)
        return id
    }

    public func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) -> Void) async throws -> CollectionID {
        let id = try await createAlbum(title: title, parent: parent)
        noted(id)
        return id
    }

    public func hasUnansweredWrites() async -> Bool { false }

    /// One by one: albums first, then folders from the inside out.
    public func deleteCollections(_ ids: [CollectionID]) async throws {
        let inventory = try await currentInventory()
        func depth(_ id: CollectionID) -> Int {
            var d = 0, cursor = inventory[id]?.parentID
            while let parent = cursor { d += 1; cursor = inventory[parent]?.parentID }
            return d
        }
        let ordered = ids.sorted { a, b in
            let fa = inventory[a]?.kind == .folder, fb = inventory[b]?.kind == .folder
            if fa != fb { return !fa }
            return depth(a) > depth(b)
        }
        for id in ordered { try await deleteCollection(id) }
    }
}

/// Persists plans so execution can resume after a crash (prompt §16.3).
public protocol ChangePlanStoring: Sendable {
    func save(_ plan: ChangePlan) async throws
}

/// The plan journal as the ways out of an interrupted plan use it (`SortlyStore` in the app).
public protocol PlanJournal: ChangePlanStoring {
    /// Several plans in one transaction: all of them are stored, or none.
    func save(_ plans: [ChangePlan]) async throws
    func plan(_ id: SortlyID) async throws -> ChangePlan?
}

public enum ExecutionEvent: Sendable, Hashable {
    case stepStarted(index: Int, total: Int)
    case stepFinished(index: Int, state: StepState)
}

/// Validates a plan against the current library right before execution (prompt §16.2).
public struct PlanValidator: Sendable {
    public init() {}

    public func validate(_ plan: ChangePlan, current: CollectionInventory, canWrite: Bool, availableAssets: Set<AssetID>) -> [PlanConflict] {
        var conflicts: [PlanConflict] = []
        if !canWrite { conflicts.append(.writeAccessMissing) }
        for (id, fingerprint) in plan.baseline.sorted(by: { $0.key < $1.key }) {
            guard let c = current[id] else { conflicts.append(.albumMissing(id)); continue }
            if c.kind != .folder && !c.isEditableAlbum { conflicts.append(.albumNotEditable(id)) }
            if c.fingerprint != fingerprint { conflicts.append(.albumChangedSincePreview(id)) }
        }
        var requested = Set<AssetID>()
        for step in plan.steps where !step.state.isFinished {
            if case .addAssets(_, let assets) = step.operation { requested.formUnion(assets) }
        }
        let unavailable = requested.subtracting(availableAssets).count
        if unavailable > 0 { conflicts.append(.assetsUnavailable(count: unavailable)) }
        return conflicts
    }
}

/// Executes confirmed plans step by step with journaling, verification and safe resume.
///
/// Guarantees (tested in `PlanningExecutionTests` and `ExecutionSafetyTests`):
/// - every step is persisted as `running` before it touches the library, together with the
///   media it is about to add or remove (the intent);
/// - a step found `running` after a restart is reconciled with the real library first:
///   nothing is created twice (Scenario J), media the user took out after an interrupted
///   add stay out, and an album found by name is never claimed as Albumist's own; an add the
///   interruption kept from reaching Photos is completed only in an album this plan created
///   (nothing of it arrived there), never in the user's own albums without a preview;
/// - success is recorded only after the change was read back and verified, and the record
///   keeps exactly what changed, so undo and the managed-album list never act on media the
///   user added or removed by hand;
/// - an album is deleted only while it holds nothing but the media its guard allows.
public actor ChangeExecutor {
    private let library: any PhotoLibraryWriting
    private let store: any ChangePlanStoring
    private let clock: @Sendable () -> Date

    public init(library: any PhotoLibraryWriting, store: any ChangePlanStoring, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.store = store
        self.clock = clock
    }

    public enum ExecutionError: Error, Equatable {
        case notConfirmed
        case blocked([PlanConflict])
    }

    /// Runs (or resumes) a plan. `onEvent` reports progress for the UI.
    public func execute(_ input: ChangePlan, onEvent: @Sendable (ExecutionEvent) -> Void = { _ in }) async throws -> ChangePlan {
        guard input.confirmedAt != nil, input.status != .draft, input.status != .cancelled else { throw ExecutionError.notConfirmed }
        // An earlier change request has no answer yet: what the library shows is not final (an
        // album may still land), so nothing is decided or sent from it. The plan stays as it is.
        try await requireAnsweredWrites()
        var plan = input
        if plan.record == nil { plan.record = ExecutionRecord() }

        let inventory = try await library.currentInventory()
        var requested: [AssetID] = []
        for step in plan.steps where !step.state.isFinished {
            if case .addAssets(_, let assets) = step.operation { requested.append(contentsOf: assets) }
        }
        let available = try await library.availableAssets(requested)
        // Fingerprint checks only apply before the first step ran; afterwards our own
        // changes legitimately alter the fingerprints. Interrupted steps are reconciled one
        // by one instead (see `perform`).
        let started = plan.steps.contains { $0.state != .pending }
        let conflicts = PlanValidator()
            .validate(started ? plan.withoutBaseline : plan, current: inventory, canWrite: await library.canWrite(), availableAssets: available)
            .filter { if case .assetsUnavailable = $0 { return false }; return true }
        if !conflicts.isEmpty {
            throw ExecutionError.blocked(conflicts)
        }

        plan.status = .running
        let snapshot = plan
        plan.record?.recordNames(of: snapshot, inventory: inventory)
        try await store.save(plan)

        for index in plan.steps.indices {
            if Task.isCancelled { break }
            let step = plan.steps[index]
            if step.state.isFinished { continue }

            // Consecutive deletions run as one request (one question from Photos, not one per album).
            if case .deleteCollection = step.operation {
                var batch = [index]
                var next = index + 1
                while next < plan.steps.count, case .deleteCollection = plan.steps[next].operation, !plan.steps[next].state.isFinished {
                    batch.append(next)
                    next += 1
                }
                try await deleteBatch(batch, plan: &plan, onEvent: onEvent)
                continue
            }

            onEvent(.stepStarted(index: index, total: plan.steps.count))
            let wasRunning: Bool
            if case .running = step.state { wasRunning = true } else { wasRunning = false }
            // The journal before this step, for a step of which nothing reached Photos.
            let beforeStep = plan

            // Adding and removing media journal `running` together with their intent (in
            // `perform`); the other steps are journaled here.
            if !wasRunning && !step.operation.changesMembership {
                plan.steps[index].state = .running(startedAt: clock())
                try await store.save(plan)
            }

            let state: StepState
            var sent = false
            do {
                state = try await perform(index, plan: &plan, reconcile: wasRunning, available: available, sent: &sent)
            } catch let notResponding as PhotosNotResponding {
                // Photos did not answer (app-speed, docs/DECISIONS.md): the outcome of this step
                // is not known, Photos may still carry it out. It is neither done nor failed: it
                // stays journaled as running, with its intent (and the id Photos gave a new album,
                // `maybeCreated`), like a step the app was closed in, and the run stops here. The
                // ways out of an interrupted plan settle it later from what the library shows
                // then. A step of which nothing reached Photos (the request was never sent, or a
                // read before it got no answer) is as it was before (second review, 9).
                if !wasRunning && !sent { plan = beforeStep }
                try await store.save(plan)
                throw notResponding
            } catch {
                await settleAfterError(step, plan: &plan)
                state = .failed(reason: String(describing: error))
            }
            plan.steps[index].state = state
            if case .succeeded(let created?, _) = state, let key = step.operation.plannedKey {
                plan.resolvedKeys[key] = created
            }
            try await store.save(plan)
            onEvent(.stepFinished(index: index, state: state))
        }

        let finished = plan.steps.allSatisfy(\.state.isFinished)
        let anyFailed = plan.steps.contains { if case .failed = $0.state { return true }; return false }
        plan.status = finished ? (anyFailed ? .completedWithErrors : .completed) : .running
        try await store.save(plan)
        return plan
    }

    /// Settles every step an interruption left `running`, by reading the library only (it
    /// writes nothing). Used before an interrupted plan is taken back, so the undo sees what
    /// the interrupted run really did (an album created or media added right before the app
    /// was closed). Steps that never started stay as they are.
    public func reconcileInterrupted(_ input: ChangePlan) async throws -> ChangePlan {
        // Not while an earlier change request may still land: settled from a library that is
        // not final, a late album would be left behind by the undo.
        try await requireAnsweredWrites()
        var plan = input
        if plan.record == nil { plan.record = ExecutionRecord() }
        let inventory = try await library.currentInventory()
        let now = clock()
        for index in plan.steps.indices {
            guard case .running = plan.steps[index].state else { continue }
            let step = plan.steps[index]
            var state: StepState = .failed(reason: "interrupted")
            switch step.operation {
            case .createFolder(let key, let title, let parentRef), .createAlbum(let key, let title, let parentRef):
                let isFolder: Bool = if case .createFolder = step.operation { true } else { false }
                if let made = plan.resolvedKeys[key] {
                    // Photos returned this id before the app stopped: created by this run, so
                    // undo may remove it (not merely found, which undo would have to keep).
                    if inventory[made] != nil { state = .succeeded(createdID: made, verifiedAt: now) }
                } else if let maybe = plan.record?.maybeCreated[key], inventory[maybe] != nil {
                    // Photos gave this id to this run's request, which then got no answer in time:
                    // it landed, so it is Albumist's like any album it made (undo removes it).
                    plan.resolvedKeys[key] = maybe
                    plan.record?.maybeCreated[key] = nil
                    state = .succeeded(createdID: maybe, verifiedAt: now)
                } else if let parent = resolve(parentRef, plan),
                   let found = adoptionCandidate(title: title, parent: parent, folder: isFolder, plan: plan, inventory: inventory) {
                    plan.resolvedKeys[key] = found
                    plan.record?.adoptedKeys.insert(key)
                    state = .succeeded(createdID: found, verifiedAt: now)
                }
            case .addAssets(let ref, _):
                if let albumID = resolve(ref, plan), let album = inventory[albumID], let intent = plan.record?.media[step.id] {
                    let arrived = intent.filter { album.assetIDs.contains($0) }
                    if plan.createdVerifiably(albumID) {
                        // An album this run made: what is in it came from this run.
                        plan.record?.settle(step.id, arrived)
                        if !arrived.isEmpty { state = .succeeded(createdID: nil, verifiedAt: now) }
                    } else if intent.isEmpty {
                        plan.record?.settle(step.id, [])
                        state = .succeeded(createdID: nil, verifiedAt: now)
                    } else if arrived.count == intent.count {
                        // Everything is there, but the user may have put it there: it stays
                        // unconfirmed, so undo leaves these photos alone (audit 2, 1.1).
                        state = .succeeded(createdID: nil, verifiedAt: now)
                    } else {
                        state = .failed(reason: StepState.unclearReason)
                    }
                }
            case .removeAssets(let albumID, _):
                if let album = inventory[albumID], let intent = plan.record?.media[step.id] {
                    let gone = intent.filter { !album.assetIDs.contains($0) }
                    plan.record?.settle(step.id, gone)
                    if !gone.isEmpty { state = .succeeded(createdID: nil, verifiedAt: now) }
                }
            case .renameCollection(let id, _, let to):
                if inventory[id]?.title == to { state = .succeeded(createdID: nil, verifiedAt: now) }
            case .moveCollection(let id, _, let toRef):
                if let target = resolve(toRef, plan), let c = inventory[id], c.parentID == target {
                    state = .succeeded(createdID: nil, verifiedAt: now)
                }
            case .deleteCollection(let id, _):
                if inventory[id] == nil {
                    state = .succeeded(createdID: nil, verifiedAt: now)
                } else {
                    plan.record?.deletedAlbums[id] = nil
                }
            }
            plan.steps[index].state = state
        }
        return plan
    }

    private func resolve(_ ref: FolderRef, _ plan: ChangePlan) -> CollectionID?? {
        switch ref {
        case .topLevel: return .some(nil)
        case .existing(let id): return .some(id)
        case .planned(let key): return plan.resolvedKeys[key].map { .some($0) } ?? nil
        }
    }

    private func resolve(_ ref: AlbumRef, _ plan: ChangePlan) -> CollectionID? {
        switch ref {
        case .existing(let id): id
        case .planned(let key): plan.resolvedKeys[key]
        }
    }

    /// An earlier change request has no answer yet (`PhotoLibraryWriting.hasUnansweredWrites`).
    private func requireAnsweredWrites() async throws {
        if await library.hasUnansweredWrites() {
            throw PhotosNotResponding(lane: .write, what: "earlierChange", notSent: true)
        }
    }

    /// A write of a step: `sent` once it may have reached Photos (all but a request that was
    /// never sent, `PhotosNotResponding.notSent`).
    private func sending<T>(_ sent: inout Bool, _ write: () async throws -> T) async throws -> T {
        do {
            let result = try await write()
            sent = true
            return result
        } catch let quiet as PhotosNotResponding where quiet.notSent {
            throw quiet
        } catch {
            sent = true
            throw error
        }
    }

    private func perform(_ index: Int, plan: inout ChangePlan, reconcile: Bool, available: Set<AssetID>,
                         sent: inout Bool) async throws -> StepState {
        let now = clock()
        let step = plan.steps[index]
        switch step.operation {
        case .createFolder(let key, let title, let parentRef), .createAlbum(let key, let title, let parentRef):
            let isFolder: Bool = if case .createFolder = step.operation { true } else { false }
            guard let parent = resolve(parentRef, plan) else {
                return .skipped(reason: "parent folder was not created")
            }
            if reconcile, let made = plan.resolvedKeys[key] {
                // Photos had returned the new id and it was written down before the app
                // stopped (audit 2, 1.7): the album is provably this run's own. It is taken as
                // it is; the search by title below excludes ids the plan already resolved and
                // would make a second album next to it, leaving the first one behind after undo.
                guard let found = try await library.collection(made) else {
                    // Created, and gone now: the user deleted it meanwhile. Not made again.
                    return .skipped(reason: StepState.deletedByUserReason)
                }
                guard found.title == title, found.parentID == parent else {
                    return .failed(reason: "created collection could not be verified")
                }
                return .succeeded(createdID: made, verifiedAt: now)
            }
            if reconcile, let maybe = plan.record?.maybeCreated[key] {
                // Photos gave this id to this run's request, which then got no answer in time
                // (second review of the PhotoKit limits, 1). It landed: provably Albumist's, taken
                // as made by this run (undo removes it), never made a second time. Not there: the
                // request did not land (no request is unanswered any more, `execute`), and the
                // album is made below as after any interruption.
                if let found = try await library.collection(maybe) {
                    plan.resolvedKeys[key] = maybe
                    plan.record?.maybeCreated[key] = nil
                    try await store.save(plan)
                    guard found.title == title, found.parentID == parent else {
                        return .failed(reason: "created collection could not be verified")
                    }
                    return .succeeded(createdID: maybe, verifiedAt: now)
                }
                plan.record?.maybeCreated[key] = nil
            }
            if reconcile {
                // The app stopped while this was being created. A collection with the same
                // title in the same place is not proof that Albumist made it (the user may
                // have made one meanwhile). Only a single, still empty candidate is taken
                // over, and it is marked as adopted: undo will never delete it.
                let inventory = try await library.currentInventory()
                let same = inventory.collections.values.filter {
                    ($0.kind == .folder) == isFolder && $0.title == title && $0.parentID == parent
                        && !plan.baselineCollectionIDs.contains($0.id) && !Set(plan.resolvedKeys.values).contains($0.id)
                }
                if let found = adoptionCandidate(title: title, parent: parent, folder: isFolder, plan: plan, inventory: inventory) {
                    plan.record?.adoptedKeys.insert(key)
                    return .succeeded(createdID: found, verifiedAt: now)
                }
                if !same.isEmpty {
                    return .failed(reason: "a collection with this title appeared meanwhile")
                }
            }
            // An album an undo brings back: only if the old one is really gone. Its deletion
            // may not have been verified (plugin review N6), and the album list the undo was
            // planned with can lack albums for a moment (W3); asked on its own, Photos knows.
            if !isFolder, let original = step.operation.restoredAlbum, try await library.collection(original) != nil {
                return .skipped(reason: StepState.stillThereReason)
            }
            // The folder may have been deleted meanwhile (e.g. on another device): never fall
            // back to the top level of the library.
            if let parent, try await library.collection(parent) == nil {
                return .failed(reason: "parent folder no longer exists")
            }
            // The id Photos gives the new album, heard before the change is committed: a request
            // without an answer in time leaves it in the journal (`maybeCreated`).
            let noted = NotedID()
            let id: CollectionID
            do {
                id = try await sending(&sent) {
                    isFolder
                        ? try await library.createFolder(title: title, parent: parent, noted: { noted.note($0) })
                        : try await library.createAlbum(title: title, parent: parent, noted: { noted.note($0) })
                }
            } catch let quiet as PhotosNotResponding {
                if let maybe = noted.id { plan.record?.maybeCreated[key] = maybe }
                throw quiet
            }
            // Photos returned the new id: it is written down before the check, so a failed
            // check never leads to a second album on retry, and undo can still remove this
            // one (audit 2, 1.7).
            plan.resolvedKeys[key] = id
            try await store.save(plan)
            let created: CollectionSnapshot?
            do {
                created = try await library.collection(id)
            } catch let quiet as PhotosNotResponding {
                // No answer to the check: the step stays running with the id written down, and is
                // checked again when the plan goes on (second review, 8).
                throw quiet
            } catch {
                return .failed(reason: "created collection could not be verified")
            }
            guard let created, created.title == title, created.parentID == parent else {
                return .failed(reason: "created collection could not be verified")
            }
            return .succeeded(createdID: id, verifiedAt: now)

        case .addAssets(let albumRef, let assets):
            guard let albumID = resolve(albumRef, plan) else { return .skipped(reason: "target album was not created") }
            guard let album = try await library.collection(albumID) else { return .failed(reason: "album no longer exists") }
            if reconcile, plan.record?.unverified.contains(step.id) == true, let intent = plan.record?.media[step.id] {
                // After an interruption the library alone cannot tell whether the request went
                // through: a photo in the album may be Albumist's or the user's, a missing one
                // may never have been added or been taken out by the user (audit 2, 1.1, 1.2).
                // In the user's albums nothing is added again by itself: "Fehlendes erneut
                // versuchen" shows the missing photos first and adds them only after the user
                // confirms. In an album this plan created, an add of which nothing arrived is
                // completed (below).
                let arrived = intent.filter { album.assetIDs.contains($0) }
                if intent.isEmpty {
                    plan.record?.settle(step.id, [])
                    return .succeeded(createdID: nil, verifiedAt: now)
                }
                if plan.createdVerifiably(albumID) {
                    // An album this run made: what is in it came from this run. A Photos change
                    // is all or nothing, so once something arrived the request went through and
                    // what is missing now was taken out by the user afterwards: it stays out.
                    if !arrived.isEmpty {
                        plan.record?.settle(step.id, arrived)
                        return .succeeded(createdID: nil, verifiedAt: now)
                    }
                    // Nothing arrived: the request did not reach Photos (the app was closed
                    // before or while it was sent). "Rest anlegen" was the user's confirmation
                    // to finish this album, so it is filled below like a first run; before, it
                    // stayed empty (UI run 43949880264, test07). Only this plan's own album:
                    // whatever is added is recorded as Albumist's and undo takes exactly that
                    // out again. The user's own albums never get this (below).
                } else {
                    // Someone else's album: nothing is claimed (the step stays unconfirmed, and
                    // undo leaves these photos where they are), and nothing is added without a
                    // preview (audit 2, 1.1, 1.2).
                    return arrived.count == intent.count ? .succeeded(createdID: nil, verifiedAt: now) : .failed(reason: StepState.unclearReason)
                }
            }
            // Idempotent: only add what is missing and still available.
            let missing = assets.filter { !album.assetIDs.contains($0) && available.contains($0) }
            let unavailable = assets.count - assets.filter { available.contains($0) }.count
            if unavailable > 0 { plan.record?.unavailable[step.id] = unavailable }
            plan.record?.begin(step.id, missing)
            plan.steps[index].state = .running(startedAt: now)
            try await store.save(plan)
            if !missing.isEmpty { try await sending(&sent) { try await library.addAssets(missing, to: albumID) } }
            guard let verified = try await library.collection(albumID) else {
                plan.record?.settle(step.id, [])
                return .failed(reason: "album no longer exists")
            }
            let arrived = missing.filter { verified.assetIDs.contains($0) }
            plan.record?.settle(step.id, arrived)
            guard arrived.count == missing.count else { return .failed(reason: "added media could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .renameCollection(let id, _, let to):
            guard let c = try await library.collection(id) else { return .failed(reason: "album no longer exists") }
            if c.title != to { try await sending(&sent) { try await library.renameCollection(id, to: to) } }
            guard try await library.collection(id)?.title == to else { return .failed(reason: "rename could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .moveCollection(let id, _, let toRef):
            guard let target = resolve(toRef, plan) else { return .skipped(reason: "target folder was not created") }
            guard let c = try await library.collection(id) else { return .failed(reason: "album no longer exists") }
            if c.parentID != target {
                // A target folder deleted meanwhile (on another device, say) stops the step:
                // taken out of its folder, the album would end up at the top of the library.
                if let target, try await library.collection(target) == nil {
                    return .failed(reason: "parent folder no longer exists")
                }
                // Out of the folder it is in now, not the one it was in when the plan was
                // made: the user may have moved it since (an undo runs long after its plan).
                try await sending(&sent) { try await library.moveCollection(id, from: c.parentID, to: target) }
            }
            guard try await library.collection(id)?.parentID == target else { return .failed(reason: "move could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .removeAssets(let albumID, let assets):
            guard let album = try await library.collection(albumID) else { return .failed(reason: "album no longer exists") }
            if reconcile, plan.record?.unverified.contains(step.id) == true, let intent = plan.record?.media[step.id] {
                let gone = intent.filter { !album.assetIDs.contains($0) }
                if intent.isEmpty || !gone.isEmpty {
                    // Went through before the interruption (or had nothing to do); media back
                    // in the album now were put there by the user and stay.
                    plan.record?.settle(step.id, gone)
                    return .succeeded(createdID: nil, verifiedAt: now)
                }
            }
            let present = assets.filter { album.assetIDs.contains($0) }
            plan.record?.begin(step.id, present)
            plan.steps[index].state = .running(startedAt: now)
            try await store.save(plan)
            if !present.isEmpty { try await sending(&sent) { try await library.removeAssets(present, from: albumID) } }
            guard let after = try await library.collection(albumID) else {
                plan.record?.settle(step.id, [])
                return .failed(reason: "album no longer exists")
            }
            let gone = present.filter { !after.assetIDs.contains($0) }
            plan.record?.settle(step.id, gone)
            guard gone.count == present.count else { return .failed(reason: "removal could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .deleteCollection:
            // Deletions always run through `deleteBatch` (guards, one request, read-back).
            try await deleteBatch([index], plan: &plan, onEvent: { _ in })
            return plan.steps[index].state
        }
    }

    /// A library call threw: whatever of the intent is visible in the library now did happen.
    /// If the album cannot even be read, the intent stays unverified (undo checks it again).
    private func settleAfterError(_ step: PlanStep, plan: inout ChangePlan) async {
        guard plan.record?.unverified.contains(step.id) == true, let intent = plan.record?.media[step.id] else { return }
        switch step.operation {
        case .addAssets(let ref, _):
            guard let albumID = resolve(ref, plan), let album = try? await library.collection(albumID) else { return }
            plan.record?.settle(step.id, intent.filter { album.assetIDs.contains($0) })
        case .removeAssets(let albumID, _):
            guard let album = try? await library.collection(albumID) else { return }
            plan.record?.settle(step.id, intent.filter { !album.assetIDs.contains($0) })
        default:
            break
        }
    }

    /// Deletes the albums and folders of several steps together. A folder goes only if
    /// everything inside it goes too: Photos deletes a folder's contents with it. An album
    /// with a delete guard goes only while it holds nothing but the guarded media; otherwise
    /// it stays and only those media leave it.
    private func deleteBatch(_ indices: [Int], plan: inout ChangePlan, onEvent: @Sendable (ExecutionEvent) -> Void) async throws {
        let now = clock()
        // The journal before this batch, for a batch of which nothing reached Photos.
        let beforeBatch = plan
        var sent = false
        for i in indices {
            onEvent(.stepStarted(index: i, total: plan.steps.count))
            if case .running = plan.steps[i].state { continue }
            plan.steps[i].state = .running(startedAt: now)
        }

        var targets: [Int: CollectionID] = [:]
        for i in indices {
            if case .deleteCollection(let id, _) = plan.steps[i].operation { targets[i] = id }
        }
        var states: [Int: StepState] = [:]
        var deletionError: (any Error)?
        var allowed = Set<CollectionID>()
        var kept: [Int: (album: CollectionID, ours: [AssetID])] = [:]
        var before = CollectionInventory()
        do {
            before = try await library.currentInventory()
            for (i, id) in targets {
                guard let album = before[id], album.kind != .folder, let guarded = plan.deleteGuards?[id] else { continue }
                if !album.assetIDs.isSubset(of: guarded) {
                    kept[i] = (id, album.assetIDs.intersection(guarded).sorted())
                }
            }
            let keptIDs = Set(kept.values.map(\.album))
            let requested = Set(targets.values).subtracting(keptIDs)
            var changed = true
            while changed {
                changed = false
                for id in requested.sorted() where !allowed.contains(id) && before[id] != nil {
                    let inside = before.collections.values.filter { $0.parentID == id }
                    if inside.allSatisfy({ allowed.contains($0.id) }) {
                        allowed.insert(id)
                        changed = true
                    }
                }
            }
            // What goes is written down first, so the deletion can be taken back later.
            for id in allowed {
                guard let c = before[id], c.kind != .folder else { continue }
                plan.record?.deletedAlbums[id] = DeletedAlbumRecord(title: c.title, parentID: c.parentID, members: c.assetIDs.sorted())
            }
            for (i, k) in kept {
                // An interrupted earlier attempt may already have taken some of them out.
                let stepID = plan.steps[i].id
                let earlier = plan.record?.unverified.contains(stepID) == true ? plan.record?.media[stepID] ?? [] : []
                plan.record?.begin(stepID, Array(Set(earlier).union(k.ours)).sorted())
            }
            try await store.save(plan)
            if !allowed.isEmpty {
                // Said per step below, from what the library shows afterwards.
                do {
                    try await sending(&sent) { try await library.deleteCollections(allowed.sorted()) }
                } catch let notResponding as PhotosNotResponding {
                    throw notResponding
                } catch {
                    deletionError = error
                }
            }
            // Taking Albumist's photos out of a kept album needs no question from iOS: it
            // runs even when the deletion was declined or not carried out, and a failure here
            // is only this album's.
            for (i, k) in kept.sorted(by: { $0.key < $1.key }) where !k.ours.isEmpty {
                do {
                    try await sending(&sent) { try await library.removeAssets(k.ours, from: k.album) }
                } catch let notResponding as PhotosNotResponding {
                    throw notResponding
                } catch {
                    states[i] = .failed(reason: String(describing: error))
                }
            }
        } catch let notResponding as PhotosNotResponding {
            // As in `execute`: the deletion may still happen (iOS may still be asking the
            // user). The steps stay running, with what goes written down, and the run stops.
            // Nothing sent (never sent, or a read before it got no answer): as before the batch.
            if !sent { plan = beforeBatch }
            try await store.save(plan)
            throw notResponding
        } catch {
            for i in indices { states[i] = .failed(reason: String(describing: error)) }
        }
        // Why an album or folder that should have gone is still there, in words the user can
        // act on: they declined in the iOS question, Photos raised an error (its own text,
        // reduced to domain and code in the diagnostic report), or Photos took the request
        // without an error and did nothing.
        let failure = deletionError as? LibraryWriteFailure
        let notGone: String = if failure == .declinedByUser {
            StepState.deletionDeclinedReason
        } else if let deletionError, failure == nil {
            String(describing: deletionError)
        } else {
            StepState.deletionNotAppliedReason
        }
        // Read back: success only for what is really gone.
        if let after = await readBack(after: before, deleting: allowed) {
            for (i, id) in targets {
                if let k = kept[i] {
                    let stepID = plan.steps[i].id
                    let intent = plan.record?.media[stepID] ?? k.ours
                    let gone = intent.filter { !(after[id]?.assetIDs.contains($0) ?? false) }
                    plan.record?.settle(stepID, gone)
                    if states[i] == nil {
                        states[i] = k.ours.allSatisfy({ !(after[id]?.assetIDs.contains($0) ?? false) })
                            ? .skipped(reason: "kept: the album holds photos added meanwhile; only Albumist's photos were taken out")
                            : .failed(reason: "removal could not be verified")
                    }
                } else if after[id] == nil {
                    states[i] = .succeeded(createdID: nil, verifiedAt: now)
                } else {
                    plan.record?.deletedAlbums[id] = nil
                    if states[i] == nil {
                        // A folder that now holds something that was not to go stays on purpose.
                        let holdsOther = after.collections.values.contains { $0.parentID == id && !allowed.contains($0.id) }
                        states[i] = .failed(reason: !allowed.contains(id) || holdsOther ? "folder is not empty" : notGone)
                    }
                }
            }
        }
        let unread = deletionError == nil ? StepState.deletionUnverifiedReason : notGone
        for i in indices { plan.steps[i].state = states[i] ?? .failed(reason: unread) }
        // A verified deletion keeps what was written down as going, and so does one whose
        // outcome the album list could not show (plugin review N6: the album may well be gone,
        // and without the entry an undo could never bring it back). An undo restores such an
        // album only once Photos, asked for that album on its own, says it is gone (see
        // `perform`, `restoredAlbum`). Every other album still there loses the entry.
        for (i, id) in targets {
            if case .succeeded = plan.steps[i].state { continue }
            if case .failed(let reason) = plan.steps[i].state, reason == StepState.deletionUnverifiedReason { continue }
            plan.record?.deletedAlbums[id] = nil
        }
        try await store.save(plan)
        for i in indices { onEvent(.stepFinished(index: i, state: plan.steps[i].state)) }
    }

    /// The album list after a batch deletion, as proof of what is gone. A read that lost
    /// albums or folders the batch did not touch is not proof: Photos can hand out an
    /// incomplete list for a moment (iCloud, a library being updated), and every album
    /// missing from it would count as deleted while it is still there, and the plan as undone
    /// for good. Such a read is repeated once after a short pause; if it stays like that, the
    /// deletion counts as not verified. Nil when the list cannot be read.
    private func readBack(after before: CollectionInventory, deleting allowed: Set<CollectionID>) async -> CollectionInventory? {
        func trustworthy(_ after: CollectionInventory) -> Bool {
            !before.collections.keys.contains { !allowed.contains($0) && after[$0] == nil }
        }
        guard let first = try? await library.currentInventory() else { return nil }
        if trustworthy(first) { return first }
        try? await Task.sleep(for: .milliseconds(500))
        guard let second = try? await library.currentInventory(), trustworthy(second) else { return nil }
        return second
    }

    /// After an interruption: the one collection this step may have created. It must be new
    /// since planning, not yet used by this plan, the only one with this title in this place,
    /// and still empty. Anything else is not taken over.
    private func adoptionCandidate(title: String, parent: CollectionID?, folder: Bool, plan: ChangePlan, inventory: CollectionInventory) -> CollectionID? {
        let alreadyResolved = Set(plan.resolvedKeys.values)
        let candidates = inventory.collections.values
            .filter { ($0.kind == .folder) == folder && $0.title == title && $0.parentID == parent }
            .filter { !plan.baselineCollectionIDs.contains($0.id) && !alreadyResolved.contains($0.id) }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        let isEmpty = folder
            ? !inventory.collections.values.contains { $0.parentID == only.id }
            : only.assetIDs.isEmpty
        return isEmpty ? only.id : nil
    }
}

extension PlannedOperation {
    /// The album an undo's "restore-…" step brings back (see `UndoPlanner`, step 4).
    var restoredAlbum: CollectionID? {
        guard case .createAlbum(let key, _, _) = self, key.hasPrefix(Self.restorePrefix) else { return nil }
        return CollectionID(String(key.dropFirst(Self.restorePrefix.count)))
    }

    static let restorePrefix = "restore-"

    var plannedKey: String? {
        switch self {
        case .createFolder(let key, _, _), .createAlbum(let key, _, _): key
        default: nil
        }
    }

    /// Adds or removes album memberships (journaled together with their intent).
    var changesMembership: Bool {
        switch self {
        case .addAssets, .removeAssets: true
        default: false
        }
    }

    var removedAssets: [AssetID] {
        if case .removeAssets(_, let assets) = self { return assets }
        return []
    }
}

extension ChangePlan {
    /// Whether this plan itself created the album (not one found after an interruption).
    /// Only there can media of an interrupted step be attributed to Albumist; in any other
    /// album a photo may just as well have been put there by the user (audit 2, 1.1).
    public func createdVerifiably(_ album: CollectionID) -> Bool {
        steps.contains { step in
            guard case .createAlbum(let key, _, _) = step.operation, resolvedKeys[key] == album,
                  record?.adoptedKeys.contains(key) != true else { return false }
            switch step.state {
            case .succeeded: return true
            case .failed: return true // created, only the check afterwards failed (1.7)
            default: return false
            }
        }
    }

    var withoutBaseline: ChangePlan {
        var copy = self
        copy.baseline = [:]
        return copy
    }

    /// Distinct media this plan really put into albums (planned media of succeeded steps for
    /// plans saved by older versions).
    public var appliedAssets: Set<AssetID> {
        var result = Set<AssetID>()
        for step in steps {
            guard case .addAssets(_, let assets) = step.operation else { continue }
            if let media = record?.media[step.id], record?.unverified.contains(step.id) != true {
                result.formUnion(media)
            } else if case .succeeded = step.state, record?.media[step.id] == nil {
                result.formUnion(assets)
            }
        }
        return result
    }

    /// Albums and folders this plan changes or may already have changed: existing ones its
    /// steps name and the ones it created. While the plan is unfinished, a difference in them
    /// may be Albumist's own doing (see `ManagedAlbumTracker.reconcile`).
    public var touchedCollections: Set<CollectionID> {
        var result = Set(resolvedKeys.values)
        for step in steps {
            switch step.operation {
            case .addAssets(.existing(let id), _), .removeAssets(let id, _), .renameCollection(let id, _, _),
                 .moveCollection(let id, _, _), .deleteCollection(let id, _):
                result.insert(id)
            default:
                break
            }
        }
        return result
    }

    /// Suggestions whose album a plan took photos out of or deleted (a removal from the list
    /// of Albumist's albums). Taking such a plan back lets these suggestions return.
    public var removalSources: Set<SortlyID> {
        Set(steps.compactMap { step in
            switch step.operation {
            case .removeAssets, .deleteCollection: step.sourceID
            default: nil
            }
        })
    }

    /// The plan with the user's newer decisions applied to the steps that have not run yet,
    /// and to the add step an interruption left running: before an interrupted plan is resumed,
    /// photos the user has taken out of an album since (or ignored or excluded) are not added
    /// anymore.
    /// Albums for suggestions whose album the user deleted since are not made again, nor the
    /// folders that would only have held them, nor filled (audit 2, 1.3).
    public func respecting(_ overrides: OverrideSet) -> ChangePlan {
        var copy = self
        var dropped = Set<String>()
        for index in copy.steps.indices where copy.steps[index].state == .pending {
            guard case .createAlbum(let key, _, _) = copy.steps[index].operation,
                  let source = copy.steps[index].sourceID, overrides.mustNotRecreate(source) else { continue }
            copy.steps[index].state = .skipped(reason: StepState.deletedByUserReason)
            dropped.insert(key)
        }
        var foldersChanged = !dropped.isEmpty
        while foldersChanged {
            foldersChanged = false
            for index in copy.steps.indices where copy.steps[index].state == .pending {
                guard case .createFolder(let key, _, _) = copy.steps[index].operation else { continue }
                var children = 0
                var kept = 0
                for other in copy.steps {
                    switch other.operation {
                    case .createAlbum(let child, _, .planned(key)), .createFolder(let child, _, .planned(key)):
                        children += 1
                        if !dropped.contains(child) { kept += 1 }
                    case .moveCollection(_, _, .planned(key)):
                        children += 1
                        kept += 1
                    default:
                        break
                    }
                }
                guard children > 0, kept == 0 else { continue }
                copy.steps[index].state = .skipped(reason: StepState.deletedByUserReason)
                dropped.insert(key)
                foldersChanged = true
            }
        }
        // Also the add step the interruption left running: in an album the plan made itself,
        // "Rest anlegen" may still add its photos (see `perform`), and photos the user ignored
        // or excluded since are not among them (second review of resume-fill, D1). Its journaled
        // intent stays as it was; the reconciliation reads that, not this list.
        for index in copy.steps.indices {
            let open: Bool = switch copy.steps[index].state {
            case .pending, .running: true
            default: false
            }
            guard open, case .addAssets(let ref, let assets) = copy.steps[index].operation else { continue }
            if copy.steps[index].state == .pending, case .planned(let key) = ref, dropped.contains(key) {
                copy.steps[index].state = .skipped(reason: StepState.deletedByUserReason)
                continue
            }
            let album: CollectionID? = switch ref {
            case .existing(let id): id
            case .planned(let key): resolvedKeys[key]
            }
            let source = copy.steps[index].sourceID
            let kept = assets.filter { asset in
                if let album, !overrides.mayAdd(asset, toAlbum: album) { return false }
                if let source, !overrides.mayAdd(asset, toSource: source) { return false }
                return true
            }
            if kept.count != assets.count {
                copy.steps[index].operation = .addAssets(album: ref, assets: kept)
            }
        }
        return copy
    }
}

/// Builds a plan that safely reverts the changes of an executed plan (prompt §16.5).
/// Manual changes made in between are respected: user-added media are never removed and
/// albums the user filled with own content are not deleted.
///
/// It works from what execution really did (`ChangePlan.record`), not from what was planned:
/// media that were already in an album, or were added by the user while the plan ran, are
/// not Albumist's and stay. Plans saved by older versions fall back to their succeeded steps.
public struct UndoPlanner: Sendable {
    public init() {}

    /// - Parameter owned: media Albumist still owns per album, from the managed-album records
    ///   after the latest reconciliation. Media the user took out and later put back by hand
    ///   are no longer Albumist's and stay. An album without a record holds nothing of
    ///   Albumist's any more: its record goes once Albumist took its photos out ("Album
    ///   entfernen", an undo), and what is in it after that is the user's (review of 6c6ef79).
    ///   A record is not lost to an album list that lacks albums for a while: the album check
    ///   looks such an album up on its own first (plugin review W3). Pass `nil` only for a plan
    ///   whose results were never stored (an interrupted one); the app stores a finished plan's
    ///   results before its undo is planned.
    /// - Parameter earlierUndos: undos of the same plan that ran before and did not get
    ///   everything back (plugin review W1). An album one of them brought back is used again
    ///   and only gets the photos still missing, instead of a second album of the same name.
    /// - Parameter createdByAlbumist: albums another plan of Albumist created (managed-album
    ///   records). Such an album that this plan only extended goes away when nothing but this
    ///   plan's photos is left in it (plugin review N5: P creates A, Q adds to A; taking back
    ///   P and then Q left A behind empty).
    public func undoPlan(for executed: ChangePlan, current: CollectionInventory, owned: [CollectionID: Set<AssetID>]? = nil,
                         createdByAlbumist: Set<CollectionID> = [],
                         earlierUndos: [ChangePlan] = [], id: SortlyID = SortlyID(), now: Date = Date()) -> ChangePlan {
        var steps: [PlanStep] = []
        var notes: [PlanNote] = []
        var guards: [CollectionID: Set<AssetID>] = [:]
        func append(_ op: PlannedOperation, source: SortlyID? = nil) {
            steps.append(PlanStep(id: "\(id.rawValue)-\(steps.count)-\(StableHash.hex(String(describing: op)).prefix(12))", operation: op, sourceID: source ?? executed.id))
        }
        let record = executed.record
        func resolved(_ ref: AlbumRef) -> CollectionID? {
            switch ref {
            case .existing(let id): id
            case .planned(let key): executed.resolvedKeys[key]
            }
        }
        /// What a membership step really changed. An unverified intent counts as far as the
        /// library shows it happened (a Photos change is all or nothing).
        /// Only in an album the plan created itself; elsewhere a photo that is there now may be
        /// the user's and stays (audit 2, 1.1).
        func changed(_ step: PlanStep, album: CollectionID, planned: [AssetID], added: Bool) -> [AssetID] {
            if let media = record?.media[step.id] {
                guard record?.unverified.contains(step.id) == true else { return media }
                guard executed.createdVerifiably(album) else { return [] }
                let members = current[album]?.assetIDs ?? []
                return media.filter { members.contains($0) == added }
            }
            if case .succeeded = step.state { return planned }
            return []
        }

        var addedByUs: [CollectionID: Set<AssetID>] = [:]
        var createdAlbums: [CollectionID] = []
        var createdFolders: [CollectionID] = []
        for step in executed.steps {
            switch step.operation {
            case .createAlbum(let key, _, _), .createFolder(let key, _, _):
                // An album found after an interruption is never deleted: Albumist cannot prove it made it.
                guard record?.adoptedKeys.contains(key) != true else { continue }
                let made: CollectionID? = switch step.state {
                case .succeeded(let created, _): created ?? executed.resolvedKeys[key]
                case .failed: executed.resolvedKeys[key] // created, only the check failed (1.7)
                default: nil
                }
                guard let created = made else { continue }
                if case .createAlbum = step.operation { createdAlbums.append(created) } else { createdFolders.append(created) }
            case .addAssets(let ref, let assets):
                guard let albumID = resolved(ref) else { continue }
                let added = changed(step, album: albumID, planned: assets, added: true)
                if !added.isEmpty { addedByUs[albumID, default: []].formUnion(added) }
            default: break
            }
        }
        if let owned {
            for (albumID, ours) in addedByUs { addedByUs[albumID] = ours.intersection(owned[albumID] ?? []) }
        }

        // 1. Revert renames and moves if nobody changed them again.
        /// Where the moves of this undo put an album or folder back (nil: the top level).
        var movedBack: [CollectionID: CollectionID?] = [:]
        for step in executed.steps.reversed() {
            guard case .succeeded = step.state else { continue }
            switch step.operation {
            case .renameCollection(let cid, let from, let to):
                if current[cid]?.title == to { append(.renameCollection(cid, from: to, to: from)) }
            case .moveCollection(let cid, let from, let toRef):
                let to: CollectionID? = switch toRef {
                case .topLevel: nil
                case .existing(let id): id
                case .planned(let key): executed.resolvedKeys[key]
                }
                // The folder it came from was deleted meanwhile: there is no way back, and the
                // top of the library is not where the user had it. It stays where it is (and
                // so does the folder holding it).
                if let from, current[from] == nil { continue }
                if let c = current[cid], c.parentID == to, movedBack[cid] == nil {
                    append(.moveCollection(cid, from: to, to: from.map { .existing($0) } ?? .topLevel))
                    movedBack[cid] = .some(from)
                }
            default: break
            }
        }
        /// The folder an album or folder is in once the moves above ran.
        func parentAfterUndo(_ c: CollectionSnapshot) -> CollectionID? {
            if let back = movedBack[c.id] { return back }
            return c.parentID
        }

        // 2. Created albums: delete only if they contain nothing the user added himself. The
        //    deletion carries a guard: if the user puts a photo in before it runs, the album
        //    stays and only Albumist's photos leave it. Deletions are collected and run
        //    together at the end (one question from Photos).
        let createdSet = Set(createdAlbums)
        var albumDeletions: [PlannedOperation] = []
        for albumID in createdAlbums {
            guard let album = current[albumID] else { continue }
            let ours = addedByUs[albumID] ?? []
            if album.assetIDs.isSubset(of: ours) {
                albumDeletions.append(.deleteCollection(albumID, title: album.title))
                guards[albumID] = ours
            } else {
                let removable = album.assetIDs.intersection(ours).sorted()
                if !removable.isEmpty { append(.removeAssets(album: albumID, assets: removable)) }
                notes.append(.respectedManualRemovals(count: album.assetIDs.subtracting(ours).count))
            }
        }
        // 3. Extended existing albums (and adopted ones): remove only our additions that are still there.
        for (albumID, ours) in addedByUs.sorted(by: { $0.key < $1.key }) where !createdSet.contains(albumID) {
            guard let album = current[albumID] else { continue }
            if createdByAlbumist.contains(albumID), !album.assetIDs.isEmpty, album.assetIDs.isSubset(of: ours) {
                // Albumist's own album, made by another plan that was taken back already: once
                // these photos are out it would stay empty. It goes, guarded like the albums
                // above (a photo the user puts in before the deletion runs keeps it).
                albumDeletions.append(.deleteCollection(albumID, title: album.title))
                guards[albumID] = ours
                continue
            }
            let removable = album.assetIDs.intersection(ours).sorted()
            if !removable.isEmpty { append(.removeAssets(album: albumID, assets: removable)) }
        }
        // 4. A plan that took Albumist's photos back out of albums (or deleted its album) is
        //    reverted too: the photos go back, a deleted album comes back with its photos (as
        //    a new album: Photos cannot restore the old one). Undo plans themselves are not
        //    reverted this way.
        if executed.reverts == nil {
            // What earlier undos of this plan already did (W1): the albums they brought back,
            // and the photos they verifiably put back. A photo they put back that is missing
            // again was taken out by the user since and stays out.
            var restoredBefore: [String: CollectionID] = [:]
            var putBackBefore: [CollectionID: Set<AssetID>] = [:]
            for earlier in earlierUndos where earlier.reverts == executed.id {
                for step in earlier.steps {
                    switch step.operation {
                    case .createAlbum(let key, _, _) where key.hasPrefix(PlannedOperation.restorePrefix):
                        // Photos returned an id: the album was made (or found after an
                        // interruption), whatever its check said afterwards.
                        if let made = earlier.resolvedKeys[key], restoredBefore[key] == nil { restoredBefore[key] = made }
                    case .addAssets(let ref, _):
                        let album: CollectionID? = switch ref {
                        case .existing(let id): id
                        case .planned(let key): earlier.resolvedKeys[key]
                        }
                        if let album { putBackBefore[album, default: []].formUnion(earlier.confirmedMedia(of: step)) }
                    default:
                        break
                    }
                }
            }
            for step in executed.steps {
                let albumID: CollectionID
                switch step.operation {
                case .removeAssets(let cid, _): albumID = cid
                case .deleteCollection(let cid, _):
                    // A deletion that kept the album (it held the user's photos) only took
                    // Albumist's photos out.
                    if case .succeeded = step.state { continue }
                    albumID = cid
                default: continue
                }
                guard let album = current[albumID] else { continue }
                let removed = changed(step, album: albumID, planned: step.operation.removedAssets, added: false)
                let back = removed.filter { !album.assetIDs.contains($0) && !(putBackBefore[albumID]?.contains($0) ?? false) }
                if !back.isEmpty { append(.addAssets(album: .existing(albumID), assets: back), source: step.sourceID) }
            }
            for step in executed.steps {
                guard case .deleteCollection(let cid, _) = step.operation, step.state.deletionMayHaveHappened,
                      let gone = record?.deletedAlbums[cid], current[cid] == nil else { continue }
                let key = PlannedOperation.restorePrefix + cid.rawValue
                if let restored = restoredBefore[key] {
                    // An earlier undo brought the album back already: never a second one. It
                    // gets the photos that undo could not put back. If the user deleted it
                    // since, it stays deleted.
                    guard let album = current[restored] else { continue }
                    let missing = gone.members.filter { !album.assetIDs.contains($0) && !(putBackBefore[restored]?.contains($0) ?? false) }
                    if !missing.isEmpty { append(.addAssets(album: .existing(restored), assets: missing), source: step.sourceID) }
                    continue
                }
                let parent: FolderRef = gone.parentID.flatMap { current[$0] != nil ? FolderRef.existing($0) : nil } ?? .topLevel
                append(.createAlbum(key: key, title: gone.title, parent: parent), source: step.sourceID)
                if !gone.members.isEmpty { append(.addAssets(album: .planned(key), assets: gone.members), source: step.sourceID) }
            }
        }
        albumDeletions.forEach { append($0) }
        // 5. Folders we created, deepest first, only if nothing else is left inside. Deleting a
        //    folder in Photos also deletes everything in it, so a folder that still holds any
        //    album or folder (the user's own, or one from a later plan) is always kept, and
        //    so are all folders above it.
        var goingAway = Set(steps.compactMap { if case .deleteCollection(let id, _) = $0.operation { return id }; return nil })
        for folderID in createdFolders.reversed() {
            guard let folder = current[folderID] else { continue }
            // Counted after the moves above: a folder that only held an album this undo moves
            // back out goes too, instead of staying behind empty. Should that move fail, the
            // deletion finds the album still inside and keeps the folder.
            let keepsSomething = current.collections.values.contains { parentAfterUndo($0) == folderID && !goingAway.contains($0.id) }
            if !keepsSomething {
                append(.deleteCollection(folderID, title: folder.title))
                goingAway.insert(folderID)
            }
        }

        var plan = ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: [:],
            baselineCollectionIDs: Set(current.collections.keys),
            steps: steps,
            conflicts: [],
            notes: notes,
            resolvedKeys: [:],
            reverts: executed.id
        )
        plan.deleteGuards = guards
        return plan
    }
}

/// The id Photos gives a new album or folder, heard from inside the change request
/// (`PhotoLibraryWriting.createAlbum(title:parent:noted:)`), possibly after the caller stopped
/// waiting.
final class NotedID: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CollectionID?

    func note(_ id: CollectionID) { lock.withLock { value = id } }
    var id: CollectionID? { lock.withLock { value } }
}
