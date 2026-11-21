import SwiftUI
import AlbumistCore
import AlbumistEngine

/// Existing albums and folders as Photos shows them, plus merge suggestions for albums
/// that hold mostly the same photos (prompt §3).
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The merge preview is pushed onto the tab's path (`AppScreen`), not presented with
    /// `navigationDestination(isPresented:)`.
    @Environment(Navigator.self) private var navigator: Navigator?
    /// The suggestion whose merge plan is being prepared: its row shows a spinner and the
    /// rows do not take a second tap meanwhile (design review N13). Albums and folders do not
    /// open meanwhile either: the plan would be pushed above them (a destination link moves no
    /// `Navigator.mark`). Their hint, and that of the other suggestions, says why they wait.
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

    static func order(_ a: CollectionSnapshot, _ b: CollectionSnapshot) -> Bool { AlbumTabSections.order(a, b) }

    var body: some View {
        // Each album once: "Deine Alben" leaves out Albumist's albums listed above (review P3-16).
        let sections = AlbumTabSections(inventory: model.inventory, managed: model.managedAlbums)
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
                                    Text("\(suggestion.albumIDs.count) Alben mit vielen gleichen Fotos · \(suggestion.distinctAssetCount) Fotos insgesamt")
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
                        .accessibilityHint(preparing == suggestion.albumIDs ? Text(verbatim: "") : waitHint)
                    }
                } header: {
                    Text("Ähnliche Alben")
                } footer: {
                    Text("Albumist ergänzt das größte Album um die fehlenden Fotos. Die anderen Alben bleiben erhalten.")
                }
            }

            if !sections.fromAlbumist.isEmpty {
                Section {
                    ForEach(sections.fromAlbumist) { collection in
                        CollectionRow(collection: collection)
                            .disabled(preparing != nil)
                            .accessibilityHint(waitHint)
                    }
                } header: {
                    Text("Von Albumist angelegt oder ergänzt")
                } footer: {
                    let root = model.settings.rootFolderTitle.trimmingCharacters(in: .whitespaces)
                    if root.isEmpty {
                        Text("Neue Alben liegen in Fotos unter Sammlungen › Alben.")
                    } else {
                        Text("Neue Alben liegen in Fotos im Ordner „\(root)“.")
                    }
                }
            }

            // Left out while every album is Albumist's: "Noch keine Alben" under the list above
            // read as wrong (UI run 44570945716). With limited access it always explains why.
            if sections.showsYourAlbums || model.access == .limited {
                Section("Deine Alben") {
                    if model.access == .limited {
                        // iOS shows an app no albums at all while only some photos are shared.
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("Deine Alben sind nicht sichtbar, solange du Albumist nur ausgewählte Fotos freigibst. So regelt iOS das.")
                                .font(.subheadline).foregroundStyle(.noteText)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                Button("Alle Fotos erlauben") { openURL(url) }
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 4)
                    } else if sections.saysNoAlbums {
                        Text("Noch keine Alben").foregroundStyle(.secondary)
                    }
                    ForEach(sections.yours) { collection in
                        CollectionRow(collection: collection)
                            .disabled(preparing != nil)
                            .accessibilityHint(waitHint)
                    }
                }
            }
        }
        .navigationTitle("Alben")
        .onAppear { showWaiting() }
        // The tab shows again (`Navigator.appearances`): a result that waited is offered now.
        .onChange(of: navigator?.appearances) { showWaiting() }
        .refreshable { await model.refreshDerived() }
    }

    /// Why albums, folders and the other suggestions wait while a merge preview is prepared
    /// (VoiceOver said only "dimmed").
    private var waitHint: Text {
        preparing == nil ? Text(verbatim: "") : Text("Vorschau wird vorbereitet")
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

/// One album or folder; folders open their children.
struct CollectionRow: View {
    @Environment(AppModel.self) private var model
    var collection: CollectionSnapshot

    var body: some View {
        if collection.kind == .folder {
            NavigationLink {
                FolderView(folder: collection)
            } label: {
                label(symbol: "folder", detail: Text("\(collection.childIDs.count) Einträge"))
            }
        } else {
            NavigationLink {
                AlbumDetailView(album: collection)
            } label: {
                label(symbol: collection.kind == .restrictedAlbum ? "person.2" : "rectangle.stack",
                      detail: Text("\(collection.assetIDs.count) Fotos"))
            }
        }
    }

    private func label(symbol: String, detail: Text) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            if collection.kind == .folder {
                IconTile(systemName: symbol, tint: Theme.tint(for: .neutral))
            } else {
                // The newest photo, as Photos shows albums (design review N4), but never a
                // sensitive document such as a bank card (`PreviewRank`).
                CoverThumbnail(id: PreviewPicker.newest(collection.assetIDs, dates: model.creationDates, ranks: model.previewRanks),
                               side: 44, hidden: !collection.assetIDs.isEmpty)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title).font(.body)
                detail.font(.footnote).foregroundStyle(.noteText).monospacedDigit()
            }
        }
    }
}

struct FolderView: View {
    @Environment(AppModel.self) private var model
    var folder: CollectionSnapshot

    var body: some View {
        List {
            let children = folder.childIDs.compactMap { model.inventory[$0] }.sorted(by: AlbumsView.order)
            if children.isEmpty { Text("Leerer Ordner").foregroundStyle(.secondary) }
            ForEach(children) { CollectionRow(collection: $0) }
        }
        .navigationTitle(folder.title)
    }
}

/// Every photo of an album, oldest first like an album in Photos; a tap opens it large
/// (design review W12: only 200 photos with "+N" and taps did nothing).
struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    var album: CollectionSnapshot
    @State private var viewing: PhotoViewer.Start?
    @Namespace private var zoom

    var body: some View {
        let ids = PreviewPicker.chronological(album.assetIDs, dates: model.creationDates)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if !album.isEditableAlbum {
                    Label("Dieses Album kann Albumist nicht verändern.", systemImage: "lock")
                        .font(.footnote).foregroundStyle(.noteText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
                    ForEach(ids, id: \.self) { id in
                        Button {
                            viewing = PhotoViewer.Start(id: id, ids: ids)
                        } label: {
                            AssetThumbnail(id: id, side: 110)
                                .aspectRatio(1, contentMode: .fill)
                                .matchedTransitionSource(id: id, in: zoom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(model.creationDates[id]?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
                        .accessibilityIdentifier("album.photo")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.background)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
                .navigationTransition(.zoom(sourceID: start.id, in: zoom))
        }
    }
}
