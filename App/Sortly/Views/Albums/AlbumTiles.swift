import SwiftUI
import SortlyCore

// The pieces of the tab "Alben" (design 5C, draft E4): albums and folders as photo tiles, the
// grid they stand in, the section titles, and what a long press on an album shows.

/// What an album shows as its cover (design rules 7 and 9): the photos that can be a big cover,
/// newest first as Photos picks an album's cover (`PreviewPicker.coverCandidates`: never a
/// screenshot, a document or a sensitive document; `CoverPhoto` shows the first one that is
/// sharp on the device), and whether its preview stays hidden: an album of nothing but sensitive
/// documents shows "Vorschau ausgeblendet", as every preview of them does. Views take it from
/// `AlbumTabCache`, which works it out once per album.
struct AlbumCover: Equatable, Sendable {
    var ids: [AssetID]
    var hidden: Bool

    init(_ album: CollectionSnapshot, dates: [AssetID: Date], ranks: [AssetID: PreviewRank], count: Int = 4) {
        ids = PreviewPicker.coverCandidates(album.assetIDs, cover: nil, dates: dates, ranks: ranks, count: count)
        // `newest` is nil only when every photo is a sensitive document; an album of only
        // screenshots or documents has no candidates either, and shows the calm placeholder.
        hidden = ids.isEmpty && !album.assetIDs.isEmpty
            && PreviewPicker.newest(album.assetIDs, dates: dates, ranks: ranks) == nil
    }
}

extension CardBadge {
    /// "Neu" for an album Albumist created, "+12" for the photos it added to one of the user's.
    init(_ mark: AlbumTabSections.Mark) {
        switch mark {
        case .new: self = .new
        case .added(let count): self = .added(count)
        }
    }
}

// MARK: - Album

/// One album as a photo tile (draft E4): its cover with the round corners of Photos, the name
/// and the number of photos below it, "Neu" or "+12" on a white ground for an album of
/// Albumist's. A tap opens the album (`AlbumScreen`). A long press shows it large with "Fotos
/// ansehen" and, for an album of Albumist's, "Rückgängig machen" with the line that says what it
/// does: the same item as "…" in the album, which is the main way (decision 17.11.). For
/// assistive technologies the tile is the card's container (`PhotoCard`): its body opens the
/// album and has the long press's items as its actions (VoiceOver: swipe up or down).
struct AlbumTile: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator: Navigator?
    private let album: CollectionSnapshot
    private let managed: ManagedAlbumState?
    private let viewPhotos: @MainActor (PhotoViewer.Start) -> Void
    private let undo: @MainActor (ManagedAlbumState) -> Void

    /// - Parameters:
    ///   - managed: Albumist's record of the album, when Albumist created or extended it.
    ///   - viewPhotos: "Fotos ansehen": the screen shows the photos in full screen.
    ///   - undo: "Rückgängig machen": the screen asks first (`albumUndo`).
    init(album: CollectionSnapshot, managed: ManagedAlbumState? = nil,
         viewPhotos: @escaping @MainActor (PhotoViewer.Start) -> Void,
         undo: @escaping @MainActor (ManagedAlbumState) -> Void = { _ in }) {
        self.album = album
        self.managed = managed
        self.viewPhotos = viewPhotos
        self.undo = undo
    }

    var body: some View {
        let cover = AlbumTabCache.shared.cover(of: album, model: model)
        let mark = managed.flatMap { AlbumTabSections.mark($0) }
        // Only an album whose changes are still there can be undone: an album of the user's
        // whose added photos the user took out again has nothing of Albumist's left.
        let undoable = mark == nil ? nil : managed
        let hasPhotos = !album.assetIDs.isEmpty
        PhotoCard(coverIDs: cover.ids, title: Text(verbatim: album.title), subtitle: Self.photoCount(album),
                  badge: mark.map { CardBadge($0) }, hidesPreview: cover.hidden, aspectRatio: 1, style: .tile,
                  placeholderSymbol: "rectangle.stack",
                  onOpen: { Navigator.push(.album(album.id), on: navigator) }) {
            // No buttons: a tap opens the album, the long press has the rest.
        } menu: {
            if hasPhotos {
                Button { showPhotos(cover) } label: {
                    Label("Fotos ansehen", systemImage: "photo")
                }
                .accessibilityIdentifier("album.viewPhotos")
            }
            if let undoable {
                if hasPhotos { Divider() }
                AlbumUndoMenuItem(state: undoable, album: album) { undo(undoable) }
            }
        } preview: {
            AlbumPreview(cover: cover, title: album.title, line: Self.line(album, managed: managed))
        }
        // Names the card, a container: its body ("Rom, 16 Fotos", "Neu") is the button that opens
        // the album, with the long press's items as its actions.
        .accessibilityIdentifier("album.tile")
    }

    /// The album's photos in full screen, oldest first as in the album, starting at the photo
    /// the preview showed.
    private func showPhotos(_ cover: AlbumCover) {
        let ids = AlbumTabCache.shared.photos(of: album, model: model)
        guard let first = cover.ids.first ?? ids.last else { return }
        viewPhotos(PhotoViewer.Start(id: first, ids: ids))
    }

    /// "16 Fotos", the line under an album's name.
    static func photoCount(_ album: CollectionSnapshot) -> Text {
        let count = album.assetIDs.count
        return Text("\(count) \(count.formatted()) Fotos")
    }

    /// The number of photos and, for an album of Albumist's, what Albumist did with it ("16 Fotos ·
    /// angelegt von Albumist", "57 Fotos · ergänzt von Albumist"): under the large album of a long
    /// press and under the title of the album.
    static func line(_ album: CollectionSnapshot, managed: ManagedAlbumState?) -> Text {
        let count = album.assetIDs.count
        switch managed.flatMap({ AlbumTabSections.mark($0) }) {
        case .some(.new): return Text("\(count) \(count.formatted()) Fotos · angelegt von Albumist")
        case .some(.added): return Text("\(count) \(count.formatted()) Fotos · ergänzt von Albumist")
        case .none: return photoCount(album)
        }
    }
}

/// "Rückgängig machen" for one of Albumist's albums in a menu (the long press on its tile, "…" in
/// the album), with the line that says what it does (draft E4, right): an album Albumist created
/// that holds nothing else goes; from any other album only Albumist's photos come out. Worked
/// out when the menu shows it, from the album as the list holds it, by the rule the
/// confirmation's button follows too (`AlbumTabSections.undoEffect`), so both say the same; no
/// removal is built for it. What the menu item starts asks once more (`albumUndo`).
struct AlbumUndoMenuItem: View {
    var state: ManagedAlbumState
    var album: CollectionSnapshot?
    var action: @MainActor () -> Void

    var body: some View {
        let deletes = AlbumTabSections.undoEffect(state, album: album).deletesAlbum
        Button(role: .destructive) {
            action()
        } label: {
            Label("Rückgängig machen", systemImage: "arrow.uturn.backward")
            // A second Text in the label is the item's second line, as in the suggestion's menu.
            if deletes {
                Text("Entfernt nur dieses Album. Deine Fotos bleiben.")
            } else {
                Text("Nimmt nur Albumists Fotos heraus. Das Album bleibt.")
            }
        }
        .accessibilityIdentifier("album.undo")
    }
}

/// The album large, as a long press shows it (draft E4, right): its cover across, the name and
/// the line below on the card's own ground. Gets everything it shows handed in: the system draws
/// it apart from the screen.
struct AlbumPreview: View {
    var cover: AlbumCover
    var title: String
    var line: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverPhoto(ids: cover.ids, aspectRatio: 1.28, cornerRadius: 0, hidesPreview: cover.hidden,
                       placeholderSymbol: "rectangle.stack")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                line
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.m)
            .padding(.bottom, 14)
        }
        .frame(width: 320)
        .background(Theme.card)
    }
}

// MARK: - Folder

/// A folder as a tile, as Photos shows folders: the covers of up to four of its albums in a
/// square (a strip of four at the accessibility text sizes, like an album's wide cover there),
/// the name and the number of albums in it below. A tap opens it (`FolderScreen`).
struct FolderTile: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator: Navigator?
    @Environment(\.dynamicTypeSize) private var typeSize
    var folder: CollectionSnapshot

    var body: some View {
        let cache = AlbumTabCache.shared
        let albums = cache.albums(in: folder, model: model)
        let covers = albums.prefix(4).map { cache.cover(of: $0, count: 2, model: model) }
        let count = Text("\(albums.count) Alben")
        Button {
            Navigator.push(.folder(folder.id), on: navigator)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                mosaic(covers)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: folder.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .compactLineLimit(2)
                    count
                        .font(.footnote)
                        .foregroundStyle(.noteText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(Text(verbatim: folder.title)), \(count)"))
        .accessibilityValue(Text("Ordner"))
        .accessibilityIdentifier("folder.tile")
    }

    @ViewBuilder
    private func mosaic(_ covers: [AlbumCover]) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.photoTile, style: .continuous)
        if covers.isEmpty {
            // No album in it: the calm placeholder with the folder's symbol.
            CoverPhoto(ids: [], aspectRatio: typeSize.isAccessibilitySize ? 3 : 1, cornerRadius: Theme.Radius.photoTile,
                       placeholderSymbol: "folder")
        } else if typeSize.isAccessibilitySize {
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { cell(covers, $0) }
            }
            .clipShape(shape)
        } else {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    cell(covers, 0)
                    cell(covers, 1)
                }
                GridRow {
                    cell(covers, 2)
                    cell(covers, 3)
                }
            }
            .clipShape(shape)
        }
    }

    /// One album's cover in the mosaic; the calm placeholder where the folder has fewer albums,
    /// and for an album whose preview is hidden ("Vorschau ausgeblendet" does not fit a quarter).
    private func cell(_ covers: [AlbumCover], _ index: Int) -> some View {
        let cover = index < covers.count ? covers[index] : nil
        return CoverPhoto(ids: cover.map { $0.hidden ? [] : $0.ids } ?? [], aspectRatio: 1, cornerRadius: 0)
    }
}

// MARK: - Layout

/// Albums and folders side by side as in Photos: two in a row on every iPhone (172 pt on a 393 pt
/// screen, draft E4; 136 pt with Display Zoom on the small one, 320 pt wide), more on wider
/// screens; one below the other at the accessibility text sizes (design rule 4).
struct AlbumGrid<Content: View>: View {
    /// The narrowest column: two fit beside each other in 320 pt less the margins (288 pt).
    static var minimumColumn: CGFloat { 136 }

    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .top)]
            : [GridItem(.adaptive(minimum: Self.minimumColumn, maximum: 260), spacing: Theme.Spacing.l, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            content
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

/// A section title of the tab, as in Photos: large and bold, a line below it if there is one,
/// an action at its end ("Alle 12"). At the accessibility text sizes the action goes below.
struct AlbumSectionHeader<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let trailing: Trailing

    init(_ title: Text, subtitle: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                title
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                trailing
            }
            if let subtitle {
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

extension AlbumSectionHeader where Trailing == EmptyView {
    init(_ title: Text, subtitle: Text? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
