import Foundation

// The ways out of a plan that was cut off (the app ended while it ran, I16): "Fortsetzen",
// "So lassen" and "Rückgängig". The app runs them; what they decide lives here, so it is
// tested without PhotoKit (plugin review 15.11., K1 and K2).

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
        } else if succeeded > 0 || !UndoPlanner().undoPlan(for: kept, current: current).steps.isEmpty {
            kept.status = .completedWithErrors
        } else {
            kept.status = .cancelled
        }
        return kept
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

    /// - Parameter settled: the interrupted plan after `ChangeExecutor.reconcileInterrupted`.
    public init(settled: ChangePlan, current: CollectionInventory, undoID: SortlyID = SortlyID(), now: Date = Date()) {
        var kept = settled.keptAsIs(current: current)
        var undo = UndoPlanner().undoPlan(for: kept, current: current, id: undoID, now: now)
        if undo.steps.isEmpty {
            // Nothing left that could be taken back (also after a rename the user changed
            // again meanwhile): the plan goes away, as it always did.
            kept.status = .cancelled
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
    /// of the plan is left in Photos) or when there was nothing to take back. `result` is the
    /// undo as it ended, nil when it could not run.
    public func cancelsPlan(after result: ChangePlan?) -> Bool {
        guard let undo else { return true }
        return result?.id == undo.id && result?.status == .completed
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
