import Foundation

/// What a row of the history ("Verlauf und Rückgängig") says a change did, as parts the app turns
/// into plural strings of the catalog and joins with ", " (`Counted.historyLine`; design wave 3,
/// H12). Counted as the receipt counts: only what the library confirmed
/// (`ChangePlan.confirmedMedia`), each photo once.
///
/// - What a change took back comes first: the albums it removed ("2 entfernt"; not the folders,
///   as "neu" counts albums only) and the different photos it took out of albums ("12 Fotos
///   herausgenommen"), also those of an album the run kept because a photo came into it.
/// - Then what it made: the albums it made ("25 neu"), the user's it extended ("3 ergänzt"), the
///   albums it renamed ("1 umbenannt") or moved ("1 verschoben"), and the different photos it put
///   into albums ("236 Fotos"). A plan that made or extended albums reads as it always did; "N
///   Fotos" is said only when photos came (review M2 of design wave 3: "1 neu", not "1 neu, 0
///   Fotos").
/// - A change of nothing at all says so, never "0 Fotos": a removal of albums Albumist made
///   ("Album entfernen", `PlanReceipt.Kind.removed`) that removed nothing (declined in the iOS
///   question, failed, not confirmed by Photos) "Nichts entfernt", any other change "Nichts
///   geändert" (every addition failed, or its photos were no longer there).
///
/// The history lists no undo today: an undo marks the plan it took back, "Rückgängig gemacht".
/// Its line follows the same rule (what it removed, then what it brought back).
public enum HistoryLine {
    /// One part of the line, with its number.
    public enum Part: Hashable, Sendable {
        /// "N neu": albums the change made.
        case created(Int)
        /// "N ergänzt": albums of the user's it added photos to.
        case extended(Int)
        /// "N umbenannt": albums it renamed.
        case renamed(Int)
        /// "N verschoben": albums it moved into another folder.
        case moved(Int)
        /// "N Fotos": the different photos it put into albums.
        case photos(Int)
        /// "N entfernt": albums it removed (their photos stay in the library).
        case removed(Int)
        /// "N Fotos herausgenommen": the different photos it took out of albums.
        case takenOut(Int)
        /// "Nichts geändert": a change that changed nothing at all.
        case nothingChanged
        /// "Nichts entfernt": a removal that removed nothing.
        case nothingRemoved
    }

    /// The parts of the line for `plan`, in the order they are said; never empty.
    public static func parts(of plan: ChangePlan) -> [Part] {
        var parts: [Part] = []
        let removed = albumsRemoved(by: plan)
        if removed > 0 { parts.append(.removed(removed)) }
        let takenOut = photosTakenOut(by: plan)
        if takenOut > 0 { parts.append(.takenOut(takenOut)) }
        let summary = PlanSummary(applied: plan)
        if summary.newAlbums > 0 { parts.append(.created(summary.newAlbums)) }
        if summary.extendedAlbums > 0 { parts.append(.extended(summary.extendedAlbums)) }
        // As the receipt counts them: done and confirmed by Photos. Worked out only for a plan
        // that renames or moves (most do neither): the row reads its line as it is drawn.
        if plan.steps.contains(where: { Self.reshapes($0.operation) }) {
            let receipt = PlanReceipt(plan: plan, inventory: CollectionInventory())
            if receipt.renamed > 0 { parts.append(.renamed(receipt.renamed)) }
            if receipt.moved > 0 { parts.append(.moved(receipt.moved)) }
        }
        if summary.distinctAssets > 0 { parts.append(.photos(summary.distinctAssets)) }
        guard parts.isEmpty else { return parts }
        return [PlanReceipt.Kind(plan) == .removed ? .nothingRemoved : .nothingChanged]
    }

    /// A step that renames an album or moves it into another folder.
    static func reshapes(_ operation: PlannedOperation) -> Bool {
        switch operation {
        case .renameCollection, .moveCollection: true
        default: false
        }
    }

    /// Albums `plan` removed: its deletions that happened, of albums, not folders. The run writes
    /// down each album it deletes (`ExecutionRecord.deletedAlbums`, folders never), so a deletion
    /// it did not write down removed no album of its own: one already gone before the run, or a
    /// folder (review M3). Only a plan of a version without a record counts each collection it
    /// removed.
    static func albumsRemoved(by plan: ChangePlan) -> Int {
        plan.steps.reduce(0) { count, step in
            guard case .deleteCollection(let id, _) = step.operation, case .succeeded = step.state,
                  plan.record.map({ $0.deletedAlbums[id] != nil }) ?? true else { return count }
            return count + 1
        }
    }

    /// The different photos `plan` took out of albums, as the library confirmed it: those of its
    /// steps that take photos out, and Albumist's photos of an album the run kept instead of
    /// deleting it, as a photo came into it after the plan was checked (review M1). The run writes
    /// those down for the deletion's step once Photos showed them gone
    /// (`ExecutionRecord.media`); while that step is unconfirmed, none of them counts.
    static func photosTakenOut(by plan: ChangePlan) -> Int {
        var out = Set<AssetID>()
        for step in plan.steps {
            switch step.operation {
            case .removeAssets:
                out.formUnion(plan.confirmedMedia(of: step))
            case .deleteCollection:
                guard let record = plan.record, !record.unverified.contains(step.id) else { continue }
                out.formUnion(record.media[step.id] ?? [])
            default:
                continue
            }
        }
        return out.count
    }
}
