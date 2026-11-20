import Foundation
import Observation
import SortlyCore
#if canImport(UIKit)
import UIKit
#endif

/// What "Anlegen" on a card did, for the card that asked.
enum QuickCreateOutcome: Equatable {
    /// The album is in Photos; the banner "„Name“ angelegt · Widerrufen" shows.
    case created
    /// The suggestion is looked at first (it adds to an album of the user's, needs a name, is
    /// personal, or its plan has something to point out): its page opens (`AppModel.route`).
    case needsLook
    /// The free albums are used up: the purchase sheet opens, the suggestion stays open.
    case needsPurchase
    /// Nothing ran (something else is busy, an interrupted plan comes first, full access is
    /// missing, the plan could not be made). Said in a message where the user can act.
    case notNow
    /// The run did not make the album; said in a message.
    case failed
}

/// "Anlegen" found the free albums used up: the purchase sheet, for this suggestion. After the
/// purchase the album is made as tapped.
struct QuickCreatePurchase: Identifiable, Equatable {
    let proposal: AlbumProposal
    var id: SortlyID { proposal.id }
}

/// What one-tap creating keeps between taps: the banner, the suggestion being made, the purchase
/// sheet it asked for. One per app, like the model; kept apart from `AppModel.swift`.
@MainActor @Observable
final class QuickCreateState {
    static let shared = QuickCreateState()

    var banner: QuickCreateBanner?
    /// The suggestion being made right now: its card's button waits.
    var creating: SortlyID?
    var purchase: QuickCreatePurchase?
    /// Ends the banner after its time; a newer banner or "Widerrufen" ends the older timer.
    @ObservationIgnored var expiry: Task<Void, Never>?
}

/// "Anlegen" on a suggestion's card makes its album at once, then a banner "„Name“ angelegt ·
/// Widerrufen" (design decision 7B). It is the preview's own way, never a second one: the
/// suggestion's plan (`singlePlan`), the preview's run (`execute`: full access, one plan at a
/// time, the interrupted plan first, the free albums, the journal, the history), and for
/// "Widerrufen" the history's undo of exactly that plan (`undo`). Which suggestions and plans
/// may skip the preview is decided in the core (`QuickCreate`, tested on Linux); a card that
/// adds to an album of the user's goes through the preview (Punkt 5).
extension AppModel {
    /// The banner after "Anlegen", nil when none shows.
    var quickCreateBanner: QuickCreateBanner? { QuickCreateState.shared.banner }

    /// The suggestion whose album is being made right now.
    var quickCreating: SortlyID? { QuickCreateState.shared.creating }

    /// The purchase sheet "Anlegen" asked for (the free albums are used up).
    var quickCreatePurchase: QuickCreatePurchase? {
        get { QuickCreateState.shared.purchase }
        set { QuickCreateState.shared.purchase = newValue }
    }

    /// "Anlegen" on a card: makes the suggestion's album now, with the banner to take it back.
    /// What it cannot make at once opens the suggestion's page, the purchase sheet or a message;
    /// it never does nothing without a word.
    @discardableResult
    func createNow(_ proposal: AlbumProposal) async -> QuickCreateOutcome {
        let state = QuickCreateState.shared
        // One at a time: a second tap meanwhile is no second album.
        guard state.creating == nil else { return .notNow }
        // Something else changes Photos or the suggestions right now: said, not dropped.
        guard !isExecutionClaimed, !execution.isRunning, !homeChangeRunning, !analysisResetting else {
            message = .busy
            return .notNow
        }
        // What the suggestion's page would make: the user's choice for it, else its
        // recommendation (with the name the user gave it).
        let chosen = decision(for: proposal)
        let pick = chosen.isAccepted ? chosen : recommendedDecision(for: proposal)
        guard QuickCreate.mayCreateAtOnce(proposal, decision: pick) else {
            route = .suggestion(proposal.id)
            return .needsLook
        }
        state.creating = proposal.id
        defer { state.creating = nil }
        // Selected for this plan only, as "Album anlegen" on its page does, and given back
        // afterwards whatever happened: never left selected without the user's choice. A made
        // suggestion has left the open list by then (`finalize`), and stays made.
        let selection = selectForPreview([(proposal, pick)])
        defer { endPreview(selection) }
        guard let made = await singlePlan(for: proposal) else {
            // Nothing to make (the album was deleted by the user before), or Photos could not
            // be read (said by `singlePlan`): its page says what there is.
            if message == nil { route = .suggestion(proposal.id) }
            return .notNow
        }
        guard QuickCreate.mayRunWithoutPreview(made) else {
            route = .suggestion(proposal.id)
            return .needsLook
        }
        // A plan that was cut off is settled first (plugin review K2), as in the preview.
        if PlanGate.refusal(for: made, interrupted: interruptedPlan) != nil {
            message = quickCreateInterruptedFirst
            return .notNow
        }
        // The free albums: used up, the purchase sheet instead of the album. The suggestion
        // stays open.
        guard Purchases.shared.allows(albums: made.freeAlbumUse(applied: false)) else {
            state.purchase = QuickCreatePurchase(proposal: proposal)
            return .needsPurchase
        }
        // A preview open on another tab keeps its plan: the run ends with no plan on screen.
        let previewed = plan
        await execute(made)
        if plan == nil, let previewed, previewed.id != made.id { plan = previewed }
        return finishQuickCreate(made, proposal: proposal)
    }

    /// After the purchase the sheet asked for: the suggestion is made as tapped, in its state
    /// now when the analysis still has it.
    func continueQuickCreate(after purchase: QuickCreatePurchase) async {
        let current = proposals.first(where: { $0.id == purchase.id }) ?? purchase.proposal
        await createNow(current)
    }

    /// "Widerrufen" in the banner: takes back exactly the plan that made the album, through the
    /// history's undo (free album, suggestion and album records come back with it). It finds
    /// out first whether the album is deleted, so the banner can say that iOS asks once more
    /// (P3-07). Something left or refused is said, and the banner stays for another try.
    func undoQuickCreate() async {
        let state = QuickCreateState.shared
        guard let banner = state.banner, banner.canUndo else { return }
        guard !isExecutionClaimed, !execution.isRunning, !homeChangeRunning, !analysisResetting else {
            message = .busy
            return
        }
        state.expiry?.cancel()
        state.banner?.phase = .checking
        let deletes = await undoDeletesCollections(banner.plan)
        guard state.banner?.id == banner.id else { return }
        state.banner?.phase = .undoing(deletesAlbum: deletes)
        let previewed = plan
        let before = execution
        await undo(banner.plan)
        if plan == nil, let previewed { plan = previewed }
        let undoRan = execution.planID != before.planID
        if undonePlans.contains(banner.plan.id) {
            if state.banner?.id == banner.id { state.banner = nil }
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: String(localized: "„\(banner.title)“ rückgängig gemacht"))
            #endif
        } else {
            if message == nil {
                if undoRan, let finished = execution.finished, finished.reverts == banner.plan.id {
                    let failed = PlanReceipt(plan: finished, inventory: inventory).failedSteps
                    message = AppMessage(title: String(localized: "Teilweise rückgängig gemacht"),
                                         text: String(localized: "\(failed) Schritte konnten nicht ausgeführt werden. Was Albumist nicht rückgängig machen konnte, bleibt, wie es ist."))
                } else if undoRan, let failure = execution.failure {
                    message = .failure(failure)
                } else {
                    // Nothing ran: another plan took the turn first.
                    message = .busy
                }
            }
            if state.banner?.id == banner.id {
                state.banner?.phase = .shown
                expireQuickCreateBanner(banner.id)
            }
        }
        // The undo's result belongs to the banner, not to a preview opened later.
        if undoRan, !execution.isRunning { execution = ExecutionState() }
    }

    /// What follows the run of a plan made from a card: the banner, or why there is none.
    private func finishQuickCreate(_ made: ChangePlan, proposal: AlbumProposal) -> QuickCreateOutcome {
        guard execution.planID == made.id else {
            // It did not start: full access missing (said by `execute`), or another plan took
            // the turn first.
            if message == nil { message = .busy }
            return .notNow
        }
        let ended = execution.finished
        let failure = execution.failure
        // The result belongs to the banner, not to a preview opened later or open elsewhere.
        if !execution.isRunning { execution = ExecutionState() }
        guard let finished = ended, finished.id == made.id else {
            message = .failure(failure ?? String(localized: "Das Album konnte nicht angelegt werden. Versuch es gleich noch einmal."))
            return .failed
        }
        switch QuickCreate.ending(of: finished) {
        case .notCreated:
            message = .failure(failure ?? String(localized: "Das Album konnte nicht angelegt werden. Versuch es gleich noch einmal."))
            return .failed
        case .createdWithGaps(let failed):
            message = AppMessage(title: String(localized: "Teilweise fertig"),
                                 text: String(localized: "\(failed) Schritte konnten nicht ausgeführt werden. Die fehlenden Fotos schlägt Albumist bei der nächsten Analyse wieder vor."))
        case .created:
            break
        }
        if let banner = QuickCreateBanner(plan: finished, proposalID: proposal.id) {
            showQuickCreateBanner(banner)
        }
        return .created
    }

    private func showQuickCreateBanner(_ banner: QuickCreateBanner) {
        QuickCreateState.shared.banner = banner
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "„\(banner.title)“ angelegt"))
        #endif
        expireQuickCreateBanner(banner.id)
    }

    /// The banner goes after `QuickCreate.bannerDuration`, unless it is being taken back or a
    /// newer one replaced it.
    private func expireQuickCreateBanner(_ id: SortlyID) {
        let state = QuickCreateState.shared
        state.expiry?.cancel()
        #if canImport(UIKit)
        let assistive = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        let assistive = false
        #endif
        let duration = QuickCreate.bannerDuration(assistive: assistive || UITestSupport.isRunning)
        state.expiry = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if state.banner?.id == id, state.banner?.canUndo == true { state.banner = nil }
        }
    }

    /// Why "Anlegen" waits while a plan that was cut off is open, and where to settle it.
    private var quickCreateInterruptedFirst: AppMessage {
        interruptedPlan?.reverts != nil
            ? AppMessage(title: String(localized: "Erst das unterbrochene Rückgängigmachen abschließen"),
                         text: String(localized: "Ein früheres Rückgängigmachen wurde unterbrochen. Entscheide auf der Seite „Vorschläge“, wie es weitergeht; danach kannst du dieses Album anlegen."))
            : AppMessage(title: String(localized: "Erst das unterbrochene Anlegen abschließen"),
                         text: String(localized: "Ein früheres Anlegen wurde unterbrochen. Entscheide auf der Seite „Vorschläge“, wie es weitergeht; danach kannst du dieses Album anlegen."))
    }
}
