import Foundation
import Synchronization

/// Whether a change Albumist is about to make deletes albums or folders in Photos, said in its
/// confirmation before it runs: iOS asks once more then ("delete 15 albums and 9 folders"),
/// and Albumist announces it (review 18.11., P3-07).
public struct DeleteQuestion: Sendable {
    /// The album list, read from Photos.
    public var listAlbums: @Sendable () async throws -> CollectionInventory
    /// One album or folder, read on its own.
    public var lookUp: @Sendable (CollectionID) async throws -> CollectionSnapshot?
    /// How long the confirmation waits for Photos.
    public var limit: Duration

    public init(listAlbums: @escaping @Sendable () async throws -> CollectionInventory,
                lookUp: @escaping @Sendable (CollectionID) async throws -> CollectionSnapshot?,
                limit: Duration = .seconds(3)) {
        self.listAlbums = listAlbums
        self.lookUp = lookUp
        self.limit = limit
    }

    public init(library: any PhotoLibraryWriting, limit: Duration = .seconds(3)) {
        self.init(listAlbums: { try await library.currentInventory() },
                  lookUp: { try await library.collection($0) },
                  limit: limit)
    }

    /// "Rückgängig machen" of `executed`, planned as `AppModel.undo` plans it: from Albumist's
    /// album records `albums`, with the results of plans still waiting to be stored (`waiting`,
    /// oldest first) folded in, as the undo stores them before it plans (third review,
    /// SHOULD-1), from the album list read now.
    /// `keptForOthers`: the photos other changes still want (P2-09): an album holding any stays.
    public func undo(_ executed: ChangePlan, albums: [ManagedAlbumState], waiting: [ChangePlan],
                     earlierUndos: [ChangePlan], keptForOthers: [CollectionID: Set<AssetID>] = [:], cached: CollectionInventory) async -> Bool {
        let made = executed.collectionsMade
        func deletes(_ current: CollectionInventory) -> Bool {
            let records = waiting.reduce(albums) { ManagedAlbumTracker().record($1, into: $0, inventory: current) }
            return UndoPlanner().undoPlan(for: executed, albums: records, current: current, keptForOthers: keptForOthers,
                                          earlierUndos: earlierUndos).deletesCollections
        }
        // Every album Albumist keeps a record of is looked up when the list lacks it, as the
        // undo's own check completes the list (fourth review, NIT-2: an album an earlier plan
        // made that this undo empties and deletes).
        let recorded = Set(albums.map(\.albumID)).union(waiting.flatMap(\.collectionsMade))
        if let current = await read(adding: made.union(recorded)) { return deletes(current) }
        return deletes(cached) || !made.isEmpty
    }

    /// "Alles rückgängig machen" of the interrupted plan `interrupted`.
    public func interruptedUndo(_ interrupted: ChangePlan, cached: CollectionInventory) async -> Bool {
        let made = interrupted.collectionsMade
        if let current = await read(adding: made) {
            return InterruptedPlanUndo.deletesCollections(interrupted: interrupted, current: current)
        }
        return InterruptedPlanUndo.deletesCollections(interrupted: interrupted, current: cached) || !made.isEmpty
    }

    /// The album list now, with every album or folder of `made` it lacks looked up on its own
    /// (W3, as `ManagedAlbumCheck` does: a list that lacks albums for a while hides none the
    /// change deletes, and one that is really gone, deleted by the user or a removal, or a
    /// create that never landed, is not counted, NIT-1). Nil when Photos does not answer, or
    /// not within `limit` (SHOULD-2: the confirmation does not wait for a slow or hanging
    /// Photos); the caller then answers on the safe side.
    private func read(adding made: Set<CollectionID>) async -> CollectionInventory? {
        let listAlbums = listAlbums, lookUp = lookUp
        return await Self.within(limit) {
            guard var current = try? await listAlbums() else { return nil }
            for id in made.sorted() where current[id] == nil {
                // A look-up that fails is no answer: the safe side (fourth review, NIT-1).
                let found: CollectionSnapshot?
                do { found = try await lookUp(id) } catch { return nil }
                if Task.isCancelled { return nil }
                if let found { current.upsert(found) }
            }
            return Task.isCancelled ? nil : current
        }
    }

    /// What `work` gives within `limit`, or nil: the work is cancelled then and not waited for.
    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let worker = Task { once.finish(await work()) }
            once.timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                worker.cancel()
                once.finish(nil)
            }
        }
    }
}

/// Resumes its continuation once, with whichever answer comes first, and stops the timer.
private final class Once<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var timer: Task<Void, Never>?
        var done = false
    }
    private let state: Locked<State>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        state = Locked(State(continuation: continuation))
    }

    var timer: Task<Void, Never>? {
        get { state.withLock { $0.timer } }
        set {
            let done = state.withLock { s in
                s.timer = newValue
                return s.done
            }
            if done { newValue?.cancel() }
        }
    }

    func finish(_ value: T?) {
        let (continuation, timer) = state.withLock { s -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?) in
            defer { s.continuation = nil; s.done = true }
            return (s.continuation, s.timer)
        }
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}

extension UndoPlanner {
    /// The undo of `executed` from Albumist's album records `albums` (`owned`, `createdByAlbumist`):
    /// the user's own photos and albums stay. `AppModel.undo` and the question before it plan
    /// it the same way.
    /// `keptForOthers`: what the other changes the user still has want (`keptForOthers(undoing:plans:undone:)`).
    public func undoPlan(for executed: ChangePlan, albums: [ManagedAlbumState], current: CollectionInventory,
                         keptForOthers: [CollectionID: Set<AssetID>] = [:],
                         earlierUndos: [ChangePlan], id: AlbumistID = AlbumistID(), now: Date = Date()) -> ChangePlan {
        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in albums { owned[state.albumID, default: []].formUnion(state.addedByAlbumist) }
        // An album another plan made, left with only this plan's photos, goes too (plugin review N5).
        let created = Set(albums.filter(\.createdByAlbumist).map(\.albumID))
        return undoPlan(for: executed, current: current, owned: owned, createdByAlbumist: created, keptForOthers: keptForOthers,
                        earlierUndos: earlierUndos, id: id, now: now)
    }

    /// Per album the undo of `executed` touches, the photos other changes the user still has
    /// want there (review P2-09): every finished plan in `plans` that is no undo, was not taken
    /// back (`undone`: the targets of completed undos) and is not the same change as
    /// `executed` (a retry of it, or the plan it retries). A plan whose undo was only partial
    /// still counts: its photos may still be there.
    public static func keptForOthers(undoing executed: ChangePlan, plans: [ChangePlan], undone: Set<AlbumistID>) -> [CollectionID: Set<AssetID>] {
        let albums = Set(executed.wantedMembers().keys).union(executed.touchedCollections)
        guard !albums.isEmpty else { return [:] }
        let finished = plans.filter { $0.status == .completed || $0.status == .completedWithErrors }
        var retriedFrom: [AlbumistID: AlbumistID] = [:]
        for plan in plans { if let r = plan.retries { retriedFrom[plan.id] = r } }
        let removals = Self.removals(in: finished, albums: albums, undone: undone)
        var result: [CollectionID: Set<AssetID>] = [:]
        for plan in finished where plan.reverts == nil && !undone.contains(plan.id) && !executed.isSameChange(as: plan, retriedFrom: retriedFrom) {
            for (album, assets) in plan.wantedMembers() where albums.contains(album) {
                var still = assets
                for removal in removals where removal.album == album && removal.at > plan.createdAt { still.subtract(removal.assets) }
                if !still.isEmpty { result[album, default: []].formUnion(still) }
            }
        }
        return result
    }

    /// Photos a later change took out of an album ("Album entfernen", not taken back): a wish
    /// from before it no longer holds for them (second review of P2-09).
    private struct Removal {
        let at: Date
        let album: CollectionID
        let assets: Set<AssetID>
    }

    private static func removals(in finished: [ChangePlan], albums: Set<CollectionID>, undone: Set<AlbumistID>) -> [Removal] {
        var removals: [Removal] = []
        for plan in finished where plan.reverts == nil && !undone.contains(plan.id) {
            for step in plan.steps {
                guard case .removeAssets(let album, _) = step.operation, albums.contains(album) else { continue }
                let taken = plan.confirmedMedia(of: step)
                if !taken.isEmpty { removals.append(Removal(at: plan.createdAt, album: album, assets: Set(taken))) }
            }
        }
        return removals
    }
}
