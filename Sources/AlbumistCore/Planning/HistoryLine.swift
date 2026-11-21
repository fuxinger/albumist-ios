import Foundation

/// What a row of the history ("Verlauf und Rückgängig") says a change did, as parts the app turns
/// into plural strings of the catalog and joins with ", " (`Counted.historyLine`; design wave 3,
/// H12). Counted as the receipt counts: only what the library confirmed
/// (`ChangePlan.confirmedMedia`), each photo once.
///
/// - A plan that made or extended albums (`PlanReceipt.Kind.created`), as always: the albums it
///   made ("25 neu") and the user's it extended ("3 ergänzt") when there are any, then the
///   different photos it put into albums ("236 Fotos"), also when none came.
/// - A removal of albums Albumist made ("Album entfernen", `PlanReceipt.Kind.removed`) and an
///   undo say what they did; they said "0 Fotos" for it, as they put no photo into an album.
///   First what they took back: the albums they removed ("2 entfernt"; not the folders, as "neu"
///   counts albums only) and the different photos they took out of albums ("12 Fotos
///   herausgenommen"); then what an undo of a removal brought back ("1 neu", "12 Fotos"). Only a
///   change of nothing at all says "0 Fotos". (The history lists no undo today: an undo marks
///   the plan it took back, "Rückgängig gemacht". Its line follows the same rule.)
public enum HistoryLine {
    /// One part of the line, with its number.
    public enum Part: Hashable, Sendable {
        /// "N neu": albums the change made.
        case created(Int)
        /// "N ergänzt": albums of the user's it added photos to.
        case extended(Int)
        /// "N Fotos": the different photos it put into albums.
        case photos(Int)
        /// "N entfernt": albums it removed (their photos stay in the library).
        case removed(Int)
        /// "N Fotos herausgenommen": the different photos it took out of albums.
        case takenOut(Int)
    }

    /// The parts of the line for `plan`, in the order they are said.
    public static func parts(of plan: ChangePlan) -> [Part] {
        let summary = PlanSummary(applied: plan)
        var put: [Part] = []
        if summary.newAlbums > 0 { put.append(.created(summary.newAlbums)) }
        if summary.extendedAlbums > 0 { put.append(.extended(summary.extendedAlbums)) }
        guard PlanReceipt.Kind(plan) != .created else { return put + [.photos(summary.distinctAssets)] }
        if summary.distinctAssets > 0 { put.append(.photos(summary.distinctAssets)) }
        var taken: [Part] = []
        let removed = albumsRemoved(by: plan)
        if removed > 0 { taken.append(.removed(removed)) }
        let takenOut = photosTakenOut(by: plan)
        if takenOut > 0 { taken.append(.takenOut(takenOut)) }
        let parts = taken + put
        return parts.isEmpty ? [.photos(0)] : parts
    }

    /// Albums `plan` removed: its deletions that happened, of albums, not folders. The run writes
    /// down each album it deletes (`ExecutionRecord.deletedAlbums`, folders never); a plan from a
    /// version that wrote down none counts each collection it removed.
    static func albumsRemoved(by plan: ChangePlan) -> Int {
        let albums = plan.record?.deletedAlbums ?? [:]
        return plan.steps.reduce(0) { count, step in
            guard case .deleteCollection(let id, _) = step.operation, case .succeeded = step.state,
                  albums.isEmpty || albums[id] != nil else { return count }
            return count + 1
        }
    }

    /// The different photos `plan` took out of albums, as the library confirmed it.
    static func photosTakenOut(by plan: ChangePlan) -> Int {
        var out = Set<AssetID>()
        for step in plan.steps {
            guard case .removeAssets = step.operation else { continue }
            out.formUnion(plan.confirmedMedia(of: step))
        }
        return out.count
    }
}
