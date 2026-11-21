import SwiftUI
import AlbumistCore

extension View {
    /// The long press on a photo of a grid (design wave 2, DS-06a; draft E4 "lang drücken"): the
    /// photo lifted larger, and what this place offers for it (`PhotoMenu`), also as VoiceOver's
    /// actions of the photo. `perform` runs "Ansehen", "Zu Album hinzufügen …" and "Aus
    /// Vorschlag entfernen" the place's way; "Ignorieren" and "Nicht mehr ignorieren" are the
    /// model's, the same everywhere, with "Widerrufen" on the screen (`IgnoreUndoBar`).
    func photoMenu(_ id: AssetID, place: PhotoMenu.Place, selecting: Bool = false, available: Bool = true,
                   perform: @escaping @MainActor (PhotoMenu.Item) -> Void) -> some View {
        modifier(PhotoLongPress(id: id, place: place, selecting: selecting, available: available, perform: perform))
    }
}

/// Apple's long press: the menu and the lifted photo; the same items for VoiceOver, Voice
/// Control and Switch Control on the photo itself.
private struct PhotoLongPress: ViewModifier {
    @Environment(AppModel.self) private var model
    var id: AssetID
    var place: PhotoMenu.Place
    var selecting: Bool
    var available: Bool
    var perform: @MainActor (PhotoMenu.Item) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                items(forVoiceOver: false)
            } preview: {
                liftedPhoto
            }
            .accessibilityActions {
                items(forVoiceOver: true)
            }
    }

    private func items(forVoiceOver: Bool) -> PhotoMenuItems {
        PhotoMenuItems(model: model, id: id, place: place, selecting: selecting, available: available,
                       forVoiceOver: forVoiceOver, perform: perform)
    }

    /// The lifted photo, its size read here from its facts: the system draws it apart from the
    /// screen, so it gets everything handed in.
    private var liftedPhoto: PhotoPreview {
        let asset = model.factsByID[id]?.asset
        return PhotoPreview(id: id, size: PhotoMenu.previewSize(pixelWidth: asset?.pixelWidth ?? 0,
                                                                pixelHeight: asset?.pixelHeight ?? 0))
    }
}

/// The items of a photo's long press (`PhotoMenu`) in their groups, or, for VoiceOver, its
/// actions: every item but "Ansehen", the photo's own (a double tap opens it). Reads the model,
/// handed in by the photo, only when the menu is drawn: nothing from the environment (the
/// system draws the menu apart from the grid).
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

/// A photo larger, as the long press lifts it out of its grid: whole, in its own proportions
/// (`PhotoMenu.previewSize`), only what is on the device, sharp or the calm placeholder, never a
/// big blurry picture (`CoverPhoto`; Albumist never loads from iCloud). Decorative: the menu
/// says what can be done with it.
struct PhotoPreview: View {
    var id: AssetID
    var size: PhotoMenu.PreviewSize

    var body: some View {
        CoverPhoto(ids: [id], aspectRatio: CGFloat(size.aspectRatio), cornerRadius: 0, placeholderSymbol: "photo")
            .frame(width: CGFloat(size.width), height: CGFloat(size.height))
    }
}
