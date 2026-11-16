import Foundation
import Observation
import SortlyCore

/// The App Store rating question (decision Fuchs, 16.11.2026) at the moment `ReviewPromptPolicy` allows.
///
/// The result of a plan ("Fertig" with "Rückgängig machen", `ResultCard`) and its receipt
/// (`PlanReceiptView`) report when they come and go; the model reports every plan that ended,
/// every undo and a plan that was cut off. When the user leaves the result of a plan that made
/// new albums, `due` changes. `MainTabs` then waits a moment (and briefly for the check for new
/// photos that follows every plan) and asks with SwiftUI's `requestReview` if `confirm` still
/// says yes. Never at a start: the session begins empty at every launch, and nothing but a
/// result seen in this run can make the question due.
@MainActor
@Observable
final class ReviewPrompt {
    static let shared = ReviewPrompt()

    /// A result counts as seen after this long on screen, not when it only flashed by (the sheet
    /// of "Zu Album hinzufügen" closes as soon as its plan is done).
    nonisolated static let seenAfter: Duration = .seconds(1)
    /// After the result was left: the next screen settles first, so the question never covers
    /// the result or its receipt.
    nonisolated static let delay: Duration = .milliseconds(1500)
    /// The check for new photos that follows every plan is waited for this long at most. A first
    /// analysis that is still running takes longer: then nothing is asked (no analysis may run).
    nonisolated static let analysisWait: Duration = .seconds(15)
    /// The last question (`ReviewPromptPolicy.State`), one value in the user defaults.
    nonisolated private static let stateKey = "review.prompt"

    /// Changes when the user has left the result of a plan that may ask; nil when nothing waits.
    private(set) var due: UUID?
    @ObservationIgnored private var session = ReviewPromptPolicy.Session()

    // MARK: Reports from the screens and the model

    /// The result of `plan` has been on screen for `seenAfter`.
    func resultSeen(_ plan: ChangePlan) {
        session.resultSeen(plan)
    }

    /// A result or receipt came on screen.
    func screenAppeared() {
        session.screenAppeared()
    }

    /// A result or receipt left the screen. UI tests never get the question (nothing may cover
    /// the screen they tap next); `confirm` says no to them as well.
    func screenDisappeared() {
        if session.screenDisappeared(), !UITestSupport.isRunning { due = UUID() }
    }

    /// "Rückgängig machen" for `plan`, from its result, its receipt or the history.
    func undoStarted(_ plan: SortlyID) {
        session.undoStarted(plan)
    }

    /// A plan ran (applied, taken back, continued, tried again); nil when it stopped with an error.
    func planEnded(_ result: ChangePlan?, resultsStored: Bool) {
        session.planEnded(result, resultsStored: resultsStored)
    }

    /// A plan that was cut off is open (at launch, or one that stopped half way).
    func interruptedPlanFound() {
        session.interruptedPlanFound()
    }

    // MARK: Asking

    /// Right before `requestReview`, for the moment `due` named: whether to ask now. The question
    /// is written down at once (version and date); iOS may still decide not to show it.
    func confirm(_ moment: UUID, model: AppModel) -> Bool {
        guard moment == due else { return false }
        due = nil
        // Nil while the result or its receipt is on screen again: it waits until they are left.
        guard let plan = session.takeWaiting() else { return false }
        let now = Date()
        let version = Self.appVersion
        let situation = ReviewPromptPolicy.Situation(
            planRunning: model.execution.isRunning,
            analysisRunning: model.analysis.isRunning || model.analysisResetting,
            homeChangeRunning: model.homeChangeRunning,
            planInterrupted: model.interruptedPlan != nil,
            onScreen: model.isOnScreen,
            messageShown: model.message != nil,
            samplePhotos: Self.samplePhotosInLibrary,
            uiTest: UITestSupport.isRunning
        )
        let state = ReviewPromptPolicy.State(stored: UserDefaults.standard.data(forKey: Self.stateKey))
        guard ReviewPromptPolicy.refusal(after: plan, session: session, situation: situation,
                                         state: state, version: version, now: now) == nil else { return false }
        if let data = ReviewPromptPolicy.State.asked(version: version, at: now).stored {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
        return true
    }

    /// The version people see in the App Store ("1.0.0"); the App Store has one build per version.
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Albumist's sample photos ("Mit Beispielfotos ausprobieren": an App Review device) and, in
    /// the simulator, the demo library (Appetize, App Store screenshots).
    private static var samplePhotosInLibrary: Bool {
        #if targetEnvironment(simulator)
        if DemoLibrary.shared.isDone { return true }
        #endif
        return SamplePhotos.shared.arePresent
    }
}
