import SwiftUI
import SortlyCore
import SortlyEngine

/// Existing albums and folders as Photos shows them, plus merge suggestions for albums
/// that hold mostly the same photos (prompt §3).
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The merge preview is pushed onto the tab's path (`AppScreen`), not presented with
    /// `navigationDestination(isPresented:)`.
    @Environment(Navigator.self) private var navigator: Navigator?
    /// On screen: a merge plan that is ready while another tab is chosen waits for this screen
    /// (`Navigator.push(_:on:ifStill:visible:)`, `waiting`).
    @State private var visible = false
    /// The suggestion whose merge plan is being prepared: its row shows a spinner and the
    /// rows do not take a second tap meanwhile (design review N13). Albums and folders do not
    /// open meanwhile either: the plan would be pushed while the user goes back from one.
    @State private var preparing: [CollectionID]?
    /// A merge plan that was ready while another tab was chosen: pushed when this screen shows
    /// again, if it is still current (`showWaiting()`).
    @State private var waiting: WaitingMerge?

    private struct WaitingMerge {
        let plan: ChangePlan
        let before: Navigator.Mark?
        /// The album list when the merge was tapped (`AppModel.inventoryVersion`).
        let inventory: Int
    }

    private var topLevel: [CollectionSnapshot] {
        model.inventory.collections.values
            .filter { $0.parentID == nil && $0.kind != .smartAlbum }
            .sorted(by: Self.order)
    }

    private var suggestions: [AlbumOverlapAnalyzer.MergeSuggestion] { model.mergeSuggestions }

    static func order(_ a: CollectionSnapshot, _ b: CollectionSnapshot) -> Bool {
        if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    var body: some View {
        List {
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.albumIDs) { suggestion in
                        Button {
                            // The tap is on this screen, so it is showing, whatever a swipe
                            // back that was called off did to `visible`.
                            visible = true
                            waiting = nil
                            preparing = suggestion.albumIDs
                            let before = navigator?.mark
                            let inventory = model.inventoryVersion
                            Task {
                                let plan = await model.mergePlan(suggestion)
                                preparing = nil
                                guard let plan else { return }
                                if Navigator.push(.prebuiltPlan(PlanToken(plan)), on: navigator, ifStill: before, visible: visible) == .waiting {
                                    waiting = WaitingMerge(plan: plan, before: before, inventory: inventory)
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.albumIDs.compactMap { model.inventory[$0]?.title }.formatted(.list(type: .and)))
                                        .font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text("\(suggestion.albumIDs.count) Alben mit vielen gleichen Fotos · \(suggestion.distinctAssetCount) Fotos insgesamt")
                                        .font(.footnote).foregroundStyle(.secondary)
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
                    }
                } header: {
                    Text("Ähnliche Alben")
                } footer: {
                    Text("Albumist ergänzt das größte Album um die fehlenden Fotos. Die anderen Alben bleiben erhalten.")
                }
            }

            let fromSortly = model.managedAlbums.compactMap { model.inventory[$0.albumID] }
            if !fromSortly.isEmpty {
                Section {
                    ForEach(fromSortly.sorted(by: Self.order)) { collection in
                        CollectionRow(collection: collection)
                            .disabled(preparing != nil)
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

            Section("Deine Alben") {
                if model.access == .limited {
                    // iOS shows an app no albums at all while only some photos are shared.
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Deine Alben sind nicht sichtbar, solange du Albumist nur ausgewählte Fotos freigibst. So regelt iOS das.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Button("Alle Fotos erlauben") { openURL(url) }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 4)
                } else if topLevel.isEmpty {
                    Text("Noch keine Alben").foregroundStyle(.secondary)
                }
                ForEach(topLevel) { collection in
                    CollectionRow(collection: collection)
                        .disabled(preparing != nil)
                }
            }
        }
        .navigationTitle("Alben")
        .onAppear {
            visible = true
            showWaiting()
        }
        .onDisappear { visible = false }
        .refreshable { await model.refreshDerived() }
    }

    /// The merge plan that was ready while another tab was chosen, now that this screen shows
    /// again: pushed if nothing was pushed or popped on this stack, the album list was not read
    /// again (after a plan, an analysis or a refresh it may differ) and no plan runs. Otherwise
    /// it is dropped, and a tap on the suggestion makes a new one. Taken once, never pushed twice.
    private func showWaiting() {
        guard let ready = waiting else { return }
        waiting = nil
        guard model.inventoryVersion == ready.inventory, !model.execution.isRunning else { return }
        Navigator.push(.prebuiltPlan(PlanToken(ready.plan)), on: navigator, ifStill: ready.before, visible: true)
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
                // The newest photo, as Photos shows albums (design review N4).
                AssetThumbnail(id: PreviewPicker.newest(collection.assetIDs, dates: model.creationDates) ?? AssetID(""), side: 44)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title).font(.body)
                detail.font(.footnote).foregroundStyle(.secondary).monospacedDigit()
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
                        .font(.footnote).foregroundStyle(.secondary)
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
