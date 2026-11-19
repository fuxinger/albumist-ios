import Foundation

// The ways out of a plan that was cut off (the app ended while it ran, I16): "Fortsetzen",
// "So lassen" and "Rückgängig". The app runs them; what they decide, and in which order, lives
// here, so it is tested without PhotoKit (plugin review 15.11., K1 and K2, and its review).

extension ChangePlan {
    /// "So lassen" for an interrupted plan, once `ChangeExecutor.reconcileInterrupted` has
    /// settled the steps the interruption left open: what already happened stays and counts
    /// like a finished plan (Albumist's albums, history, receipt, undo later); steps that
    /// never ran are left out. The plan is cancelled only when it changed nothing that could
    /// be taken back. An album Photos created before its check failed counts as a change too:
    /// it is recorded instead of staying in Photos without a trace.
    /// - Parameter current: the library now.
    public func keptAsIs(current: CollectionInventory) -> ChangePlan {
        var kept = self
        for index in kept.steps.indices where !kept.steps[index].state.isFinished {
            kept.steps[index].state = .skipped(reason: StepState.leftByUserReason)
        }
        let succeeded = kept.steps.filter { if case .succeeded = $0.state { true } else { false } }.count
        if succeeded > 0 && succeeded == kept.steps.count {
            kept.status = .completed
        } else if succeeded > 0 || !UndoPlanner().undoPlan(for: kept, current: current).steps.isEmpty
                    || !(kept.record?.mayStillLand(resolved: kept.resolvedKeys).isEmpty ?? true) {
            // Also when an album Albumist asked for may still land: the plan stays in the
            // history, so the album records and its undo take that album as Albumist's.
            kept.status = .completedWithErrors
        } else {
            kept.status = .cancelled
        }
        return kept
    }

    /// Suggestions this plan carried out at least in part: a step of theirs succeeded, or Photos
    /// made their album (its id was written down) whatever the step says since: its check failed
    /// (audit 2, 1.7), or the user deleted it meanwhile. Only these leave the selection when the
    /// plan is finalized. A suggestion whose steps never ran (an interrupted plan kept or taken
    /// back) or all failed stays selected (review of 6c6ef79): nothing of it is done.
    public var appliedSources: Set<SortlyID> {
        var result = Set<SortlyID>()
        for step in steps {
            guard let source = step.sourceID else { continue }
            switch step.operation {
            case .createFolder:
                // A folder carries the id of the first suggestion that needed it, but making
                // only the folder carries out no suggestion (review of 6b34b20).
                continue
            case .createAlbum(let key, _, _):
                if case .succeeded = step.state { result.insert(source) } else if resolvedKeys[key] != nil { result.insert(source) }
            default:
                if case .succeeded = step.state { result.insert(source) }
            }
        }
        return result
    }
}

/// "Rückgängig" for an interrupted plan (plugin review K1).
///
/// Before, the plan was stored as cancelled before its undo ran. When the undo then did not
/// get everything back (the user answered "Nicht erlauben" in the iOS question, Photos did
/// not carry out the deletion), the albums stayed in Photos with no history, no receipt, no
/// second undo and no free-album count. Now what the plan did is first kept like "So lassen"
/// (recorded, in the history), and then taken back by an ordinary undo of that plan. Only a
/// completed undo cancels the plan again, so it leaves the history as before; after any other
/// ending it stays there, and "Rest rückgängig machen" takes back what is left.
public struct InterruptedPlanUndo: Sendable {
    /// The interrupted plan as it is kept until its undo has completed (`ChangePlan.keptAsIs`):
    /// cancelled at once when there is nothing to take back.
    public var kept: ChangePlan
    /// The confirmed undo of what the plan did, or nil when there is nothing to take back.
    public var undo: ChangePlan?
    /// What the plan may have left in Photos that the undo leaves alone, because Albumist
    /// cannot prove it was its own (review P2-01): an album found by its name, photos in the
    /// user's own album. While it is not empty the plan is never dropped: it stays in the
    /// history, and the app names what stays.
    public var remainder: UndoRemainder

    /// - Parameter settled: the interrupted plan after `ChangeExecutor.reconcileInterrupted`.
    public init(settled: ChangePlan, current: CollectionInventory, undoID: SortlyID = SortlyID(), now: Date = Date()) {
        var kept = settled.keptAsIs(current: current)
        let remainder = UndoRemainder(plan: kept, current: current)
        self.remainder = remainder
        var undo = UndoPlanner().undoPlan(for: kept, current: current, id: undoID, now: now)
        if undo.steps.isEmpty {
            // Nothing left that could be taken back (also after a rename the user changed
            // again meanwhile): the plan goes away, as it always did, unless something of it
            // may still be in Photos. Then it stays in the history (review P2-01).
            if remainder.isEmpty {
                kept.status = .cancelled
            } else if kept.status == .cancelled {
                kept.status = .completedWithErrors
            }
            self.kept = kept
            self.undo = nil
            return
        }
        undo.status = .confirmed
        undo.confirmedAt = now
        self.kept = kept
        self.undo = undo
    }

    /// Whether the plan is cancelled once the undo ran: only after this undo completed (nothing
    /// of the plan is left in Photos) or when there was nothing to take back, and never while
    /// something the undo cannot take back may be left (`remainder`). `result` is the undo as
    /// it ended, nil when it could not run.
    public func cancelsPlan(after result: ChangePlan?) -> Bool {
        guard remainder.isEmpty else { return false }
        guard let undo else { return true }
        return result?.id == undo.id && result?.status == .completed
    }

    /// How "Rückgängig" ended, for what the app says and what the receipt then offers.
    public enum Outcome: Hashable, Sendable {
        /// Nothing had changed in Photos: the plan is gone.
        case nothingToTakeBack
        /// Everything Albumist can prove was its own is taken back, but something the plan may
        /// have done stays in Photos (`remainder`): the plan stays in the history, and the app
        /// says what stays (review P2-01). Before, the plan was dropped without a word.
        case leftUnclear
        /// Everything is taken back: the plan is cancelled and leaves the history, as before.
        case undone
        /// The undo ran but did not get everything back ("Nicht erlauben" in the iOS question):
        /// the plan stays in the history, its receipt offers "Rest rückgängig machen".
        case partlyUndone
        /// The undo was refused before its first step (the write access is gone, Photos or the
        /// store could not be read): it is dropped, so it is not offered as an interrupted plan,
        /// and the plan stays in the history, where its receipt offers "Rückgängig machen".
        case notStarted
        /// The undo was cut off: it is offered to continue or keep, like any interrupted plan.
        case undoInterrupted
        /// The plan's results could not be stored: nothing is taken back yet. The undo is offered
        /// to continue and runs once they are stored (at the latest after the next launch).
        case resultsNotStored
    }

    /// "Rückgängig" for the interrupted plan, in an order where every step leaves a journal the
    /// next launch can go on from (plugin review K1, review of 6c6ef79):
    /// 1. The plan as kept and its confirmed undo are stored in one transaction. From here on the
    ///    tap is not lost: if the app ends now, the next launch stores the plan's results first
    ///    (the app keeps the plan on its list of plans to finalize) and offers the undo to
    ///    continue. Before, the undo was written only when it started, after the results.
    /// 2. The plan's results are stored (`finalize`, the app's): its albums are Albumist's
    ///    records before the undo changes them, so nothing the undo does can later be taken for
    ///    the user's doing.
    /// 3. The undo runs (`run`, the app's).
    /// 4. Only an undo that completed cancels the plan; one that never started is dropped.
    public func carryOut(journal: any PlanJournal, finalize: @Sendable (ChangePlan) async -> Bool,
                         run: @Sendable (ChangePlan) async -> Void) async throws -> Outcome {
        guard let undo else {
            try await journal.save(kept)
            if remainder.isEmpty { return .nothingToTakeBack }
            // Kept like "So lassen": its results are stored (or, if that fails, at the next
            // launch), so its albums are Albumist's records like those of any plan in the history.
            _ = await finalize(kept)
            return .leftUnclear
        }
        try await journal.save([kept, undo])
        guard await finalize(kept) else { return .resultsNotStored }
        await run(undo)
        let ended = try await journal.plan(undo.id)
        if cancelsPlan(after: ended) {
            if var plan = try await journal.plan(kept.id) {
                plan.status = .cancelled
                try await journal.save(plan)
            }
            return .undone
        }
        if ended?.id == undo.id, ended?.status == .completed {
            // Everything that is provably Albumist's is back; what may not be stays, named.
            return .leftUnclear
        }
        switch ended?.status {
        case .completedWithErrors?:
            return .partlyUndone
        case .running?:
            return .undoInterrupted
        default:
            // Refused before its first step: a plan in the history without an undo offers
            // "Rückgängig machen" again, and the message says so.
            if var dropped = ended, dropped.status == .confirmed || dropped.status == .draft {
                dropped.status = .cancelled
                try await journal.save(dropped)
            }
            return .notStarted
        }
    }

    /// The suggestions to select again once "Rückgängig" ended with `outcome` (they left the
    /// selection when the plan's results were stored): everything is taken back, so the
    /// selection is as it was before "Jetzt umsetzen" (as before K1). After any other ending,
    /// what the plan did stays in Photos, and its suggestions stay out of the selection like
    /// those of any plan that ran (also `leftUnclear`: the plan stays in the history).
    public func selectionToRestore(after outcome: Outcome) -> Set<SortlyID> {
        outcome == .undone ? kept.appliedSources : []
    }
}

/// One plan at a time, counting a plan that was cut off (plugin review K2).
///
/// While an interrupted plan is still open (offered to continue, take back or keep), its
/// suggestions are still selected: a new plan would make the same albums a second time
/// ("Paris" twice, the second only with a warning), the interrupted plan would fill the first
/// one when it is continued, and the free albums it holds back would be used twice. Leaving
/// its suggestions out of new plans would still let a second plan be cut off next to it, and
/// Albumist keeps track of one open plan only. So nothing new runs until the user has chosen
/// a way out; "So lassen" always works, so this never locks anyone in.
public enum PlanGate {
    public enum Refusal: Hashable, Sendable {
        /// A plan that was cut off has to be continued, taken back or kept first.
        case interruptedPlanOpen
    }

    /// Why `plan` may not run now, nil when it may. The interrupted plan itself (continued)
    /// and the undo that takes it back are the ways out and always may.
    public static func refusal(for plan: ChangePlan, interrupted: ChangePlan?) -> Refusal? {
        guard let interrupted, plan.id != interrupted.id, plan.reverts != interrupted.id else { return nil }
        return .interruptedPlanOpen
    }
}
