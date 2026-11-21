import SwiftUI
import UIKit
import AlbumistCore

extension View {
    /// The long press on a photo of a grid (design wave 2, DS-06a; draft E4 "lang drücken"): the
    /// photo lifted larger, and what this place offers for it (`PhotoMenu`), also as VoiceOver's
    /// actions of the photo. `side`: the side the cell's thumbnail is asked for
    /// (`AssetThumbnail`), whose image is lifted. `gridWidth`: the width of a grid that zooms
    /// (`PhotoGrid`), whose photo is lifted at least as large as at three in a row, from the
    /// sharpest image kept of it (review L9 of design wave 3); nil elsewhere. `perform` runs
    /// "Ansehen", "Zu Album hinzufügen …" and "Aus Vorschlag entfernen" the place's way;
    /// "Ignorieren" and "Nicht mehr ignorieren" are the model's, the same everywhere, with
    /// "Widerrufen" on the screen (`IgnoreUndoBar`).
    func photoMenu(_ id: AssetID, place: PhotoMenu.Place, side: CGFloat, gridWidth: CGFloat? = nil, selecting: Bool = false,
                   available: Bool = true, perform: @escaping @MainActor (PhotoMenu.Item) -> Void) -> some View {
        modifier(PhotoLongPress(id: id, place: place, side: side, gridWidth: gridWidth, selecting: selecting,
                                available: available, perform: perform))
    }
}

/// Apple's long press: the menu and the lifted photo; the same items for VoiceOver, Voice
/// Control and Switch Control on the photo itself.
///
/// A photo without a menu now gets no context menu and no actions at all. A menu closure that
/// returns nothing beside a preview of its own is not documented to switch the lift off (UIKit
/// shows a preview without actions), and a lift there would take the press that ticks a photo
/// while the grid selects (review C2 of design wave 2, N1). The switch rebuilds the photo's
/// cell, unseen: it is not animated, and the rebuilt thumbnail starts with the image in memory
/// (`AssetThumbnail.init`).
private struct PhotoLongPress: ViewModifier {
    @Environment(AppModel.self) private var model
    var id: AssetID
    var place: PhotoMenu.Place
    var side: CGFloat
    var gridWidth: CGFloat?
    var selecting: Bool
    var available: Bool
    var perform: @MainActor (PhotoMenu.Item) -> Void

    func body(content: Content) -> some View {
        Group {
            if offered {
                content
                    .contextMenu {
                        items(forVoiceOver: false)
                    } preview: {
                        PhotoPreview(id: id, side: side, gridWidth: gridWidth)
                    }
                    .accessibilityActions {
                        items(forVoiceOver: true)
                    }
            } else {
                content
            }
        }
        // At once: the pages toggle "Auswählen" in `withAnimation` (their bars move), which
        // would cross-fade every photo on screen into its rebuilt cell.
        .transaction(value: offered) { $0.animation = nil }
    }

    /// Whether the photo has a menu now (`PhotoMenu.isOffered`): not while the grid selects or
    /// the photo cannot open. Without one it gets no context menu and no actions (see above).
    private var offered: Bool {
        PhotoMenu.isOffered(selecting: selecting, available: available)
    }

    private func items(forVoiceOver: Bool) -> PhotoMenuItems {
        PhotoMenuItems(model: model, id: id, place: place, selecting: selecting, available: available,
                       forVoiceOver: forVoiceOver, perform: perform)
    }
}

/// The items of a photo's long press (`PhotoMenu`) in their groups, or, for VoiceOver, its
/// actions: every item but "Ansehen", the photo's own (a double tap opens it). Reads the model,
/// handed in by the photo, in its own body, not in the cell's, and nothing from the environment
/// (the system draws the menu apart from the grid). SwiftUI evaluates these items to show the
/// menu, and to give the photo's actions to an assistive technology or a UI test that asks for
/// them: while one of those is on, every photo on screen follows the photos the user ignored
/// and the analysis' states (`isIgnored`), which a recount sets anew (review C2 of design wave
/// 2, N3).
struct PhotoMenuItems: View {
    var model: AppModel
    var id: AssetID
    var place: PhotoMenu.Place
    var selecting: Bool
    var available: Bool
    var forVoiceOver: Bool
    var perform: @MainActor (PhotoMenu.Item) -> Void

    var body: some View {
        let ignored = place != .suggestion && model.isIgnored(id)
        let menu = PhotoMenu(place: place, isIgnored: ignored, selecting: selecting, available: available)
        if forVoiceOver {
            ForEach(menu.accessibilityItems) { item in
                button(item)
            }
        } else {
            ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                ForEach(section) { item in
                    button(item)
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ item: PhotoMenu.Item) -> some View {
        switch item {
        case .view:
            Button { perform(.view) } label: { Label("Ansehen", systemImage: "photo") }
                .accessibilityIdentifier("photoMenu.view")
        case .addToAlbum:
            Button { perform(.addToAlbum) } label: { Label("Zu Album hinzufügen …", systemImage: "rectangle.stack.badge.plus") }
                .accessibilityIdentifier("photoMenu.addToAlbum")
        case .ignore:
            // Not red: nothing is deleted, and "Widerrufen" takes it back (design review D4).
            Button { model.ignore([id]) } label: { Label("Ignorieren", systemImage: "eye.slash") }
                .accessibilityIdentifier("photoMenu.ignore")
        case .stopIgnoring:
            Button { model.unignore([id]) } label: { Label("Nicht mehr ignorieren", systemImage: "eye") }
                .accessibilityIdentifier("photoMenu.unignore")
        case .removeFromSuggestion:
            // Asked first by the suggestion's photos (`ProposalPhotosView`), as "Auswählen" asks.
            Button(role: .destructive) { perform(.removeFromSuggestion) } label: {
                Label("Aus Vorschlag entfernen", systemImage: "minus.circle")
            }
            .accessibilityIdentifier("photoMenu.removeFromSuggestion")
        }
    }
}

/// A photo larger, as the long press lifts it out of its grid (review C of design wave 2, M2):
/// the image its cell shows, from the thumbnails' memory, at once, whole, in its own
/// proportions, as large as it is sharp (`PhotoMenu.liftSize`: never smaller than the cell, at
/// most 320 × 427 pt). So never an empty surface where the cell shows a photo, never a blurry
/// enlargement, nothing loaded from iCloud, and no lift counted as a cover (`CoverStats` counts
/// the cards' covers). In a grid that zooms (`gridWidth`) at least as large as at three in a
/// row, also at five and seven in a row, from the sharpest image kept of it at the grid's sizes
/// (review L9 of design wave 3); nothing is asked of Photos for the lift. Gone from memory (a
/// memory warning) while its cell still shows it: that large, asked for again as the cell asks.
/// Worked out in its own body, when SwiftUI draws the preview, not in the cell's; gets
/// everything handed in (the system draws it apart from the screen).
/// Decorative: the menu says what can be done with it.
struct PhotoPreview: View {
    var id: AssetID
    /// The side its cell's thumbnail is asked for (`AssetThumbnail.side`), in points.
    var side: CGFloat
    /// The width of a grid that zooms (`PhotoGrid`), nil elsewhere.
    var gridWidth: CGFloat? = nil
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The lift's floor: the cell's side, in a zooming grid as at three in a row.
        let lifted = gridWidth.map { CGFloat(PhotoGridZoom.liftSide(cell: Double(side), gridWidth: Double($0))) } ?? side
        if let image = sharpestInMemory {
            let size = PhotoMenu.liftSize(imageWidth: Double(image.size.width * image.scale),
                                          imageHeight: Double(image.size.height * image.scale),
                                          scale: Double(displayScale), cellSide: Double(lifted))
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                .clipped()
                .accessibilityHidden(true)
        } else {
            AssetThumbnail(id: id, side: side)
                .environment(\.thumbnailShowsVideoLength, false) // the lifted photo, as from memory
                .frame(width: lifted, height: lifted)
        }
    }

    /// The sharpest image of the photo kept in memory (`PhotoGridZoom.sharpestKept`): its cell's,
    /// one of a zooming grid's other sizes, or the one a grid showed last.
    private var sharpestInMemory: UIImage? {
        let cache = ThumbnailCache.shared
        var sides = [side]
        if let gridWidth { sides += PhotoGridZoom.sides(width: Double(gridWidth)).map { CGFloat($0) } }
        var images = sides.compactMap { cache.cachedThumbnail(for: id, side: $0) }
        if let last = cache.thumbnailInMemory(for: id) { images.append(last) }
        let pixels = images.map { (width: Double($0.size.width * $0.scale), height: Double($0.size.height * $0.scale)) }
        return PhotoGridZoom.sharpestKept(pixels).map { images[$0] }
    }
}
