import SwiftUI
import AlbumistCore

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
                // The 44 pt tap area on the label, where the button takes the tap.
                Button { openURL(url) } label: {
                    Text("Alle Fotos erlauben").minimumHitTarget()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
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
    /// "Zu Album hinzufügen …" from a photo's long press.
    @State private var addingToAlbum: [AssetID]?
    @Namespace private var zoom
    /// The side a photo's thumbnail is asked for, and its long press lifts that image.
    private static let photoSide: CGFloat = 110

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
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {}
                .sheetSize(.page)
        }
        // "Widerrufen" after "Ignorieren" from a photo's long press, as in "Unsortiert".
        .safeAreaInset(edge: .bottom) { IgnoreUndoBar() }
        .animation(.snappy, value: model.lastIgnored)
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
                        tile(photo, ids: ids)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            .padding(Theme.Spacing.l)
        }
        .navigationTitle(album.title)
    }

    /// One photo of the album: a tap opens it; the long press lifts it with what an album's
    /// photo offers (DS-06a).
    private func tile(_ photo: AssetID, ids: [AssetID]) -> some View {
        Button {
            open(photo, ids: ids)
        } label: {
            AssetThumbnail(id: photo, side: Self.photoSide)
                .aspectRatio(1, contentMode: .fill)
                .matchedTransitionSource(id: photo, in: zoom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AssetThumbnail.spokenDate(model.creationDates[photo], facts: model.factsByID[photo])))
        .accessibilityIdentifier("album.photo")
        .photoMenu(photo, place: .album, side: Self.photoSide) { action in
            perform(action, on: photo, ids: ids)
        }
    }

    /// The photo large, the album's photos to swipe through.
    private func open(_ photo: AssetID, ids: [AssetID]) {
        viewing = PhotoViewer.Start(id: photo, ids: ids)
    }

    /// An item of a photo's long press, an album's way: "Ansehen" as a tap, "Zu Album
    /// hinzufügen …" the sheet "Unsortiert" opens (then the preview).
    private func perform(_ action: PhotoMenu.Item, on photo: AssetID, ids: [AssetID]) {
        switch action {
        case .view: open(photo, ids: ids)
        case .addToAlbum: addingToAlbum = [photo]
        // Ignoring is the model's, the same everywhere (`PhotoMenuItems`); a suggestion's own.
        case .ignore, .stopIgnoring, .removeFromSuggestion: break
        }
    }
}
