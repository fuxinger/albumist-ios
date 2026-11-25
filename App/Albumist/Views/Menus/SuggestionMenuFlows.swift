import SwiftUI
import AlbumistCore

/// A way a suggestion card's long press opens (`SuggestionMenuItems`).
struct SuggestionMenuFlow {
    enum Kind {
        /// "Anpassen".
        case adjust
        /// "Reise teilen oder zusammenlegen".
        case reshapeTrip
        /// "Keine Reise, hier bin ich öfter", asked first.
        case notATrip
    }

    var kind: Kind
    var proposal: AlbumProposal
}

/// Opens a way of a card's long press on the page that shows the card, and holds which one is
/// open (`suggestionMenuFlows(_:)`). One per page, kept in the page's own state (`OverviewView`,
/// `ProposalListView`): the cards get the same object each time the page is drawn, so handing it
/// down redraws no card. A closure made anew at each drawing would, at every change of the
/// analysis, once the start page's scroll view hands it down (review C of design wave 2, M1).
/// Made when the page is made, not by the modifier: a modifier's state made a new object at
/// every drawing of the page, which SwiftUI threw away (review C2 of design wave 2, N2).
@MainActor @Observable
final class SuggestionMenuFlowAction {
    /// The suggestion whose "Anpassen" is open.
    fileprivate var adjusting: AlbumProposal?
    /// The trip whose workshop is open.
    fileprivate var reshaping: AlbumProposal?
    /// The suggestion "Keine Reise?" asks about.
    fileprivate var askingNotATrip: AlbumProposal?

    func open(_ flow: SuggestionMenuFlow) {
        switch flow.kind {
        case .adjust: adjusting = flow.proposal
        case .reshapeTrip: reshaping = flow.proposal
        case .notATrip: askingNotATrip = flow.proposal
        }
    }
}

private struct SuggestionMenuFlowKey: EnvironmentKey {
    static var defaultValue: SuggestionMenuFlowAction? { nil }
}

extension EnvironmentValues {
    /// Set by `suggestionMenuFlows(_:)` for the cards of its page; elsewhere nil, and a card's
    /// menu opens nothing.
    var openSuggestionMenuFlow: SuggestionMenuFlowAction? {
        get { self[SuggestionMenuFlowKey.self] }
        set { self[SuggestionMenuFlowKey.self] = newValue }
    }
}

extension View {
    /// What the long press on this page's suggestion cards opens: "Anpassen", the trip workshop
    /// and the question before "Keine Reise, hier bin ich öfter", the sheets and the question
    /// of the open suggestion's "…" (`ProposalDetailView`). `flows`: the page's own, kept in its
    /// state (`@State private var menuFlows = SuggestionMenuFlowAction()`).
    func suggestionMenuFlows(_ flows: SuggestionMenuFlowAction) -> some View {
        modifier(SuggestionMenuFlows(flows: flows))
    }
}

/// Shown by the page, not by the card: a card in a shelf may leave the screen, and with it what
/// it presents, while its sheet is open. On the page's scroll view, so the question comes from
/// the screen, not from the middle of all its cards (iOS 26 anchors it to its view; review C of
/// design wave 2, M1). Each way is the open suggestion's: the same sheet in its own stack, the
/// same question with the same words; what they change shows on the cards.
private struct SuggestionMenuFlows: ViewModifier {
    @Environment(AppModel.self) private var model
    /// The page's (`suggestionMenuFlows(_:)`).
    var flows: SuggestionMenuFlowAction

    func body(content: Content) -> some View {
        @Bindable var flows = flows
        content
            .environment(\.openSuggestionMenuFlow, flows)
            .sheet(item: $flows.adjusting) { proposal in
                adjustSheet(proposal).sheetSize(.short)
            }
            .sheet(item: $flows.reshaping) { proposal in
                workshopSheet(proposal).sheetSize(.page)
            }
            .confirmationDialog("Keine Reise?", isPresented: asking, titleVisibility: .visible,
                                presenting: flows.askingNotATrip) { proposal in
                Button("Keine Reise, hier bin ich öfter") { answer(proposal) }
            } message: { _ in
                Text("""
                    Aufenthalte an diesem Ort werden keine Reisen mehr, auch bei jeder neuen Analyse. \
                    Albumist schlägt stattdessen ein Album für den Ort vor. Rückgängig machen kannst du das in den Einstellungen.
                    """)
            }
    }

    /// "Anpassen" as the open suggestion shows it; a place only the user can name gets its name
    /// in "Titel" there (no name field of a page to share it with).
    private func adjustSheet(_ proposal: AlbumProposal) -> some View {
        NavigationRoot { AdjustProposalView(proposal: proposal) }
    }

    /// The trip workshop (I07). A split or merged trip leaves the suggestions by itself; its
    /// "Zu den Reisen" closes the sheet.
    private func workshopSheet(_ proposal: AlbumProposal) -> some View {
        NavigationRoot { TripWorkshopView(proposal: proposal) {} }
    }

    private var asking: Binding<Bool> {
        Binding(get: { flows.askingNotATrip != nil }, set: { if !$0 { flows.askingNotATrip = nil } })
    }

    /// "Keine Reise, hier bin ich öfter", answered as in the open suggestion: the suggestions are
    /// made again, and the trips there become one album of the place. For the suggestion as it
    /// is now: the question can stay open while the analysis goes on (review C of design wave
    /// 2, H1).
    private func answer(_ proposal: AlbumProposal) {
        guard let current = model.currentSuggestion(proposal) else { return }
        Task { _ = await model.answerRecurringPlace(true, for: current) }
    }
}
