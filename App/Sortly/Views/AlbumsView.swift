import SwiftUI
import SortlyCore
import SortlyEngine

/// The tab "Alben" (design 5C, approved 20.11.2026, draft E4): on top a shelf of what Albumist
/// created or extended ("Von Albumist", "angelegt oder ergänzt", "Alle 12"), then rows for the
/// folders Albumist's new albums lie in, "Verlauf und Rückgängig" (moved here from the settings)
/// and "Ähnliche Alben", then the user's other albums and folders as Photos shows them ("Deine
/// Alben"). Every album and folder stands once (`AlbumTabSections`). Albums are photo tiles
/// (covers at least half the screen wide, design rule 6); a long press on one of Albumist's has
/// "Rückgängig machen", which undoes only that album (`albumUndo`), as a note under the shelf
/// says.
///
/// Everything here is pushed by value (`AppScreen`): an album, a folder, the list of all of
/// Albumist's albums, the history, the similar albums, and the preview of an undo.
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(Navigator.self) private var navigator: Navigator?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var viewing: PhotoViewer.Start?
    @State private var undoing: ManagedAlbumState?

    var body: some View {
        let sections = AlbumTabSections(inventory: model.inventory, managed: model.managedAlbums, history: model.history,
                                        undone: model.undonePlans, moreHistory: model.historyHasMore,
                                        interrupted: model.interruptedPlan != nil, similar: model.mergeSuggestions.count)
        // Two covers side by side on the iPhone, the third peeking in; four on the iPad. At the
        // accessibility text sizes the shelf is a column across the screen: three tiles at most,
        // so "Verlauf und Rückgängig" stays near (second review of wave 1). "Alle N" stands when
        // there are more than the shelf shows at once.
        let column = typeSize.isAccessibilitySize
        let side = sizeClass == .regular ? 4 : 2
        let shelf = sections.shelf(limit: column ? AlbumTabSections.columnLimit : AlbumTabSections.shelfLimit)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !shelf.isEmpty {
                    AlbumSectionHeader(Text("Von Albumist"), subtitle: Text("angelegt oder ergänzt")) {
                        if sections.showsAll(visible: column ? AlbumTabSections.columnLimit : side) {
                            allButton(count: sections.albumistAlbums.count)
                        }
                    }
                    .padding(.top, Theme.Spacing.s)
                    CardShelf(count: side) {
                        ForEach(shelf) { album in
                            AlbumTile(album: album.collection, managed: album.state,
                                      viewPhotos: { viewing = $0 }, undo: { undoing = $0 })
                        }
                    }
                    .padding(.top, Theme.Spacing.m)
                    undoNote
                        .padding(.top, Theme.Spacing.s)
                }

                AlbumRowsCard(rows: sections.rows)
                    .padding(.top, shelf.isEmpty ? Theme.Spacing.s : Theme.Spacing.m)

                // Left out while every album is Albumist's: "Noch keine Alben" under the shelf read
                // as wrong (UI run 44570945716). With limited access it always explains why.
                if sections.showsYourAlbums || model.access == .limited {
                    AlbumSectionHeader(Text("Deine Alben"))
                        .padding(.top, 28)
                        .padding(.bottom, Theme.Spacing.m)
                    if model.access == .limited {
                        limitedNote
                    } else if sections.saysNoAlbums {
                        Text("Noch keine Alben")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.l)
                    }
                    AlbumGrid {
                        ForEach(sections.yours) { collection in
                            if collection.kind == .folder {
                                FolderTile(folder: collection)
                            } else {
                                AlbumTile(album: collection, viewPhotos: { viewing = $0 })
                            }
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .navigationTitle("Alben")
        .refreshable { await model.refreshDerived() }
        .albumUndo($undoing)
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
        }
    }

    /// "Alle 12" beside "Von Albumist": every album Albumist created or extended.
    private func allButton(count: Int) -> some View {
        Button {
            Navigator.push(.managedAlbums, on: navigator)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text("Alle \(count)")
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.accent)
            .minimumHitTarget()
        }
        .accessibilityLabel(Text("Alle \(count) Alben anzeigen"))
        .accessibilityIdentifier("albums.managed")
    }

    /// Under the shelf, how to undo one of the albums, and in "Mehr erfahren" where they are in
    /// Photos: "Alle N" leads to the same words only from three albums on (second review of
    /// wave 1).
    private var undoNote: some View {
        LearnMore(short: Text("Halte ein Album gedrückt oder tippe im Album auf „…“, um es rückgängig zu machen."),
                  full: Text("\(ManagedAlbumsView.howToUndo) \(ManagedAlbumsView.place(root: model.settings.rootFolderTitle))"),
                  title: Text("Alben von Albumist"))
            .padding(.horizontal, Theme.Spacing.l)
    }

    /// iOS shows an app no albums at all while only some photos are shared.
    private var limitedNote: some View {
        Card {
            Text("Deine Alben sind nicht sichtbar, solange du Albumist nur ausgewählte Fotos freigibst. So regelt iOS das.")
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Alle Fotos erlauben") { openURL(url) }
                    .font(.subheadline.weight(.semibold))
                    .minimumHitTarget()
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

/// The rows between the shelf and "Deine Alben" (draft E4), on one card: "Ordner „Reisen“" for
/// each folder Albumist's new albums lie in (with 40 trips a shelf finds nothing), "Verlauf und
/// Rückgängig", and "Ähnliche Alben" while there are any. Plain numbers at the end, as in the
/// rows of Photos; VoiceOver says what they count.
private struct AlbumRowsCard: View {
    var rows: [AlbumTabSections.Row]
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.largeCard, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    // Where the words start: after the symbol's column, at the accessibility
                    // sizes at the edge (the symbol stands above them).
                    Divider()
                        .padding(.leading, typeSize.isAccessibilitySize ? Theme.Spacing.l : Theme.Spacing.l + symbolWidth + Theme.Spacing.m)
                }
                link(row)
            }
        }
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    @ViewBuilder
    private func link(_ row: AlbumTabSections.Row) -> some View {
        switch row {
        case .folder(let folder, let albums):
            let title = Text("Ordner „\(folder.title)“")
            PushLink(.folder(folder.id), chevron: false) {
                line(symbol: "folder", title: title, value: Text(albums.formatted()))
            }
            .accessibilityLabel(title)
            .accessibilityValue(Text("\(albums) Alben"))
            .accessibilityIdentifier("albums.folders")
        case .history(let changes, let more, let interrupted):
            let shown = changes.formatted() + (more ? "+" : "")
            PushLink(.history, chevron: false) {
                line(symbol: "clock.arrow.circlepath", title: Text("Verlauf und Rückgängig"),
                     value: interrupted ? Text("Unterbrochen") : changes > 0 ? Text(verbatim: shown) : nil)
            }
            .accessibilityLabel(Text("Verlauf und Rückgängig"))
            .accessibilityValue(interrupted ? Text("Unterbrochen")
                                : more ? Text("Mehr als \(changes) Änderungen") : Text("\(changes) Änderungen"))
            .accessibilityIdentifier("albums.history")
        case .similar(let count):
            PushLink(.similarAlbums, chevron: false) {
                line(symbol: "arrow.triangle.merge", title: Text("Ähnliche Alben"), value: Text(count.formatted()))
            }
            .accessibilityLabel(Text("Ähnliche Alben"))
            .accessibilityValue(Text("\(count) Vorschläge"))
            .accessibilityIdentifier("albums.similar")
        }
    }

    /// One row: the symbol in the accent, the title, the number, a chevron; 52 pt high or more.
    /// The number stands beside the title while both fit on one line, else under it, as in the
    /// value rows of Settings: beside a title that wraps, "Unterbrochen" broke inside the word
    /// from the text size xxLarge on (review A of design wave 1, finding 5). At the accessibility
    /// sizes the symbol and the chevron stand above the words, which get the whole width (as
    /// "Alle Vorschläge" on the start page).
    private func line(symbol: String, title: Text, value: Text?) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        icon(symbol)
                        Spacer(minLength: Theme.Spacing.s)
                        chevron
                    }
                    words(title, value)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.m) {
                        icon(symbol)
                        title
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let value {
                            value
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                        chevron
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        icon(symbol)
                        words(title, value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        chevron
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    /// The symbol in the accent. Beside the words its column is as wide in every row, so the
    /// titles start in one line; above the words it stands at the edge.
    @ViewBuilder
    private func icon(_ symbol: String) -> some View {
        let image = Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
        if typeSize.isAccessibilitySize {
            image
        } else {
            image.frame(width: symbolWidth)
        }
    }

    /// The title and, under it, the number; both wrap between their words.
    private func words(_ title: Text, _ value: Text?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let value {
                value
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A folder's albums and folders as tiles (draft E4), folders first, then by name as in Photos.
/// Albumist's albums carry "Neu" or "+12", and their long press has "Rückgängig machen". Shown as
/// the folder is now; when it is gone, the screen says so.
struct FolderScreen: View {
    @Environment(AppModel.self) private var model
    var id: CollectionID
    @State private var viewing: PhotoViewer.Start?
    @State private var undoing: ManagedAlbumState?
    @State private var lastTitle = ""

    var body: some View {
        Group {
            if let folder = model.inventory[id] {
                let children = AlbumTabCache.shared.children(of: folder, model: model)
                // The first record of an album, as the undo reads it (`AlbumTabSections`).
                let managed = Dictionary(model.managedAlbums.map { ($0.albumID, $0) }, uniquingKeysWith: { first, _ in first })
                ScrollView {
                    if children.isEmpty {
                        Text("Leerer Ordner")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.l)
                    }
                    AlbumGrid {
                        ForEach(children) { child in
                            if child.kind == .folder {
                                FolderTile(folder: child)
                            } else {
                                AlbumTile(album: child, managed: managed[child.id],
                                          viewPhotos: { viewing = $0 }, undo: { undoing = $0 })
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.l)
                }
                .navigationTitle(folder.title)
            } else {
                ContentUnavailableView("Den Ordner „\(lastTitle)“ gibt es nicht mehr.", systemImage: "folder")
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.inventory[id]?.title, initial: true) { _, title in
            if let title { lastTitle = title }
        }
        .albumUndo($undoing)
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
        }
    }
}

/// Every photo of an album, oldest first like an album in Photos; a tap opens it large (design
/// review W12: only 200 photos with "+N" and taps did nothing). Under the title the number of
/// photos and, for an album of Albumist's, what Albumist did with it; at the top right "…" with
/// "Rückgängig machen" (decision 17.11.: the main way; the long press on the tile is the
/// shortcut). Shown as the album is now: after an undo deleted it, the screen says so.
struct AlbumScreen: View {
    @Environment(AppModel.self) private var model
    var id: CollectionID
    @State private var viewing: PhotoViewer.Start?
    @State private var undoing: ManagedAlbumState?
    @State private var lastTitle = ""
    @Namespace private var zoom

    var body: some View {
        Group {
            if let album = model.inventory[id] {
                photos(album)
            } else {
                ContentUnavailableView("Das Album „\(lastTitle)“ gibt es nicht mehr.", systemImage: "rectangle.stack")
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let state = undoable {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        AlbumUndoMenuItem(state: state, album: model.inventory[id]) { undoing = state }
                    } label: {
                        Label("Weitere Aktionen", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("album.more")
                }
            }
        }
        .onChange(of: model.inventory[id]?.title, initial: true) { _, title in
            if let title { lastTitle = title }
        }
        .albumUndo($undoing)
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
                .navigationTransition(.zoom(sourceID: start.id, in: zoom))
        }
    }

    /// Albumist's record of the album while something of Albumist's is in it (an album of the
    /// user's whose added photos the user took out again has nothing left to undo).
    private var undoable: ManagedAlbumState? {
        guard model.inventory[id] != nil,
              let state = model.managedAlbums.first(where: { $0.albumID == id }),
              AlbumTabSections.mark(state) != nil else { return nil }
        return state
    }

    private func photos(_ album: CollectionSnapshot) -> some View {
        // Sorted once per album and album list (`AlbumTabCache`), not each time the screen is drawn.
        let ids = AlbumTabCache.shared.photos(of: album, model: model)
        let managed = model.managedAlbums.first { $0.albumID == album.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                AlbumTile.line(album, managed: managed)
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                if !album.isEditableAlbum {
                    Label("Dieses Album kann Albumist nicht verändern.", systemImage: "lock")
                        .font(.footnote).foregroundStyle(.noteText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
                    ForEach(ids, id: \.self) { photo in
                        Button {
                            viewing = PhotoViewer.Start(id: photo, ids: ids)
                        } label: {
                            AssetThumbnail(id: photo, side: 110)
                                .aspectRatio(1, contentMode: .fill)
                                .matchedTransitionSource(id: photo, in: zoom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(model.creationDates[photo]?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
                        .accessibilityIdentifier("album.photo")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            .padding(Theme.Spacing.l)
        }
        .navigationTitle(album.title)
    }
}

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
                                    Text("\(suggestion.albumIDs.count) Alben mit vielen gleichen Fotos · \(suggestion.distinctAssetCount) \(suggestion.distinctAssetCount.formatted()) Fotos insgesamt")
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
