import SwiftUI
import AlbumistCore
import AlbumistEngine

/// Albums that hold mostly the same photos, with the offer to merge them (prompt §3; the row
/// "Ähnliche Alben" in the tab "Alben"). A tap makes the merge plan and shows it in the preview.
struct SimilarAlbumsView: View {
    @Environment(AppModel.self) private var model
    /// The merge preview is pushed onto the tab's path (`AppScreen`), not presented with
    /// `navigationDestination(isPresented:)`.
    @Environment(Navigator.self) private var navigator: Navigator?
    /// The suggestion whose merge plan is being prepared: its row shows a spinner and the rows
    /// do not take a second tap meanwhile (design review N13); the others say why they wait.
    @State private var preparing: [CollectionID]?
    /// A merge plan that was ready while another tab was chosen: offered again when this tab
    /// shows (`showWaiting()`).
    @State private var waiting: WaitingMerge?

    private struct WaitingMerge {
        let plan: ChangePlan
        let suggestion: AlbumOverlapAnalyzer.MergeSuggestion
        let request: PlanRequest
    }

    private var suggestions: [AlbumOverlapAnalyzer.MergeSuggestion] { model.mergeSuggestions }

    var body: some View {
        List {
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.albumIDs) { suggestion in
                        Button {
                            merge(suggestion)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.albumIDs.compactMap { model.inventory[$0]?.title }.formatted(.list(type: .and)))
                                        .font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text("""
                                        \(suggestion.albumIDs.count) Alben mit vielen gleichen Fotos · \
                                        \(suggestion.distinctAssetCount) \(suggestion.distinctAssetCount.formatted()) Fotos insgesamt
                                        """)
                                        .font(.footnote).foregroundStyle(.noteText)
                                }
                                Spacer(minLength: 8)
                                if preparing == suggestion.albumIDs {
                                    ProgressView()
                                        .accessibilityLabel(Text("Vorschau wird vorbereitet"))
                                        .accessibilityIdentifier("merge.preparing")
                                }
                            }
                        }
                        .disabled(preparing != nil)
                        // The row being prepared says so with its spinner.
                        .accessibilityHint(preparing == nil || preparing == suggestion.albumIDs ? Text(verbatim: "") : Text("Vorschau wird vorbereitet"))
                        .accessibilityIdentifier("merge.suggestion")
                    }
                } footer: {
                    Text("Albumist ergänzt das größte Album um die fehlenden Fotos. Die anderen Alben bleiben erhalten.")
                }
            }
        }
        .overlay {
            if suggestions.isEmpty {
                ContentUnavailableView("Keine ähnlichen Alben", systemImage: "rectangle.stack")
            }
        }
        .navigationTitle("Ähnliche Alben")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { showWaiting() }
        // The tab shows again (`Navigator.appearances`): a result that waited is offered now.
        .onChange(of: navigator?.appearances) { showWaiting() }
    }

    /// Makes the merge plan of `suggestion`; the row shows a spinner meanwhile.
    private func merge(_ suggestion: AlbumOverlapAnalyzer.MergeSuggestion, attempt: Int = 1) {
        waiting = nil
        preparing = suggestion.albumIDs
        let request = PlanRequest(model: model, navigator: navigator)
        Task {
            let plan = await model.mergePlan(suggestion)
            preparing = nil
            guard let plan else { return }
            offer(WaitingMerge(plan: plan, suggestion: suggestion, request: request), attempt: attempt)
        }
    }

    /// A merge plan that is ready, or that waited for this tab: shown if it is still current,
    /// kept while another tab is chosen, made again once when the album list changed meanwhile
    /// (a second change says Albumist is busy), dropped when the user went elsewhere on this
    /// stack. Never pushed twice: `waiting` holds it only while it is not shown.
    private func offer(_ ready: WaitingMerge, attempt: Int) {
        switch ready.request.verdict(model: model, navigator: navigator) {
        case .show:
            Navigator.push(.prebuiltPlan(PlanToken(ready.plan)), on: navigator, ifStill: ready.request.mark)
        case .wait:
            waiting = ready
        case .gone:
            break
        case .busy:
            model.message = .busy
        case .stale:
            if attempt > 1 {
                model.message = .busy
            } else if let current = suggestions.first(where: { $0.albumIDs == ready.suggestion.albumIDs }) {
                merge(current, attempt: attempt + 1)
            }
            // Otherwise the suggestion is gone (merged meanwhile): its row went away with it.
        }
    }

    /// The tab shows again: a merge plan that was ready meanwhile is offered now.
    private func showWaiting() {
        guard let ready = waiting, navigator?.showing == true else { return }
        waiting = nil
        offer(ready, attempt: 1)
    }
}
