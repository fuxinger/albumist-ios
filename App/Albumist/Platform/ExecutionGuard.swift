import UIKit

/// Keeps a running plan from being cut off by the device. A plan of a few hundred albums
/// takes minutes; auto-lock would suspend Albumist in the middle of it, and the user would
/// come back to an interrupted plan to sort out. So the screen stays on while Albumist
/// writes to Photos, and if the user switches away anyway, iOS grants the usual short
/// background time, so the step in progress can finish and be written down.
@MainActor
final class ExecutionGuard {
    private let background: BackgroundAssertion
    private let idleTimerWasDisabled: Bool
    private var ended = false

    init() {
        background = BackgroundAssertion(name: "Albumist plan")
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Gives both back. Auto-lock returns only if it was on before the plan started.
    func end() {
        guard !ended else { return }
        ended = true
        background.end()
        if !idleTimerWasDisabled { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
