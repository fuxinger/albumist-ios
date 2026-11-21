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

/// Opens a way of a card's long press on the page that shows the card (`suggestionMenuFlows()`).
struct SuggestionMenuFlowAction {
    var open: @MainActor (SuggestionMenuFlow) -> Void = { _ in }
}

private struct SuggestionMenuFlowKey: EnvironmentKey {
    static var defaultValue: SuggestionMenuFlowAction { SuggestionMenuFlowAction() }
}

extension EnvironmentValues {
    /// Set by `suggestionMenuFlows()` for the cards of its page; elsewhere it opens nothing.
    var openSuggestionMenuFlow: SuggestionMenuFlowAction {
        get { self[SuggestionMenuFlowKey.self] }
        set { self[SuggestionMenuFlowKey.self] = newValue }
    }
}

extension View {
    /// What the long press on this page's suggestion cards opens: "Anpassen", the trip workshop
    /// and the question before "Keine Reise, hier bin ich öfter", the sheets and the question
    /// of the open suggestion's "…" (`ProposalDetailView`).
    func suggestionMenuFlows() -> some View {
        modifier(SuggestionMenuFlows())
    }
}

/// Shown by the page, not by the card: a card in a shelf may leave the screen, and with it what
/// it presents, while its sheet is open. Each way is the open suggestion's: the same sheet in
/// its own stack, the same question with the same words; what they change shows on the cards.
private struct SuggestionMenuFlows: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var adjusting: AlbumProposal?
    @State private var reshaping: AlbumProposal?
    @State private var askingNotATrip: AlbumProposal?

    func body(content: Content) -> some View {
        content
            .environment(\.openSuggestionMenuFlow, SuggestionMenuFlowAction(open: { flow in open(flow) }))
            .sheet(item: $adjusting) { proposal in
                adjustSheet(proposal)
            }
            .sheet(item: $reshaping) { proposal in
                workshopSheet(proposal)
            }
            .confirmationDialog("Keine Reise?", isPresented: asking, titleVisibility: .visible, presenting: askingNotATrip) { proposal in
                Button("Keine Reise, hier bin ich öfter") { answer(proposal) }
            } message: { _ in
                Text("Aufenthalte an diesem Ort werden keine Reisen mehr, auch bei jeder neuen Analyse. Albumist schlägt stattdessen ein Album für den Ort vor. Rückgängig machen kannst du das in den Einstellungen.")
            }
    }

    private func open(_ flow: SuggestionMenuFlow) {
        switch flow.kind {
        case .adjust: adjusting = flow.proposal
        case .reshapeTrip: reshaping = flow.proposal
        case .notATrip: askingNotATrip = flow.proposal
        }
    }

    /// "Anpassen" as the open suggestion shows it; a place only the user can name gets its name
    /// in "Titel" there (no name field of a page to share it with).
    private func adjustSheet(_ proposal: AlbumProposal) -> some View {
        NavigationRoot { AdjustProposalView(proposal: proposal) }
            .presentationDetents([.medium, .large])
    }

    /// The trip workshop (I07). A split or merged trip leaves the suggestions by itself; its
    /// "Zu den Reisen" closes the sheet.
    private func workshopSheet(_ proposal: AlbumProposal) -> some View {
        NavigationRoot { TripWorkshopView(proposal: proposal) {} }
    }

    private var asking: Binding<Bool> {
        Binding(get: { askingNotATrip != nil }, set: { if !$0 { askingNotATrip = nil } })
    }

    /// "Keine Reise, hier bin ich öfter", answered as in the open suggestion: the suggestions are
    /// made again, and the trips there become one album of the place.
    private func answer(_ proposal: AlbumProposal) {
        Task { _ = await model.answerRecurringPlace(true, for: proposal) }
    }
}
