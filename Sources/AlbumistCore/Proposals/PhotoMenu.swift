import Foundation

/// What the long press on a photo of a grid offers (design wave 2, DS-06a; draft E4 "lang
/// drücken": "Lang drücken gibt es auf allen Karten, Alben und Fotos"), in groups, in order:
/// only what that place already offers for one photo, run the way it runs there. No "Teilen":
/// that is the photo view's.
///
/// - "Unsortiert", an album's photos, the search: "Ansehen" (the tap) and "Zu Album hinzufügen …"
///   (the sheet, then the preview), then "Ignorieren" (with "Widerrufen" after it) or, for an
///   ignored photo, "Nicht mehr ignorieren", as its "Info" offers them.
/// - A suggestion's photos: "Ansehen", then "Aus Vorschlag entfernen", asked first as
///   "Auswählen" › "… aus Vorschlag entfernen" asks.
/// - Nothing while the grid selects (a press ticks), or while the photo cannot be opened.
public struct PhotoMenu: Equatable, Sendable {
    /// Where the photo is shown.
    public enum Place: Equatable, Sendable {
        /// The tab "Unsortiert".
        case unsorted
        /// The photos of an open suggestion.
        case suggestion
        /// The photos of an album.
        case album
        /// The hits of a search.
        case search
    }

    public enum Item: String, Equatable, Hashable, Sendable, Identifiable {
        /// "Ansehen": the photo large (`PhotoViewer`), as a tap opens it.
        case view
        /// "Zu Album hinzufügen …" (`AddToAlbumSheet`, then the preview).
        case addToAlbum
        /// "Ignorieren", with "Widerrufen" right after it (`IgnoreUndoBar`).
        case ignore
        /// "Nicht mehr ignorieren".
        case stopIgnoring
        /// "Aus Vorschlag entfernen", asked first.
        case removeFromSuggestion

        public var id: String { rawValue }
    }

    /// The groups of the menu, in order; none when there is no menu now.
    public let sections: [[Item]]

    /// - Parameters:
    ///   - isIgnored: the photo is ignored (its "Info" offers "Nicht mehr ignorieren").
    ///   - selecting: the grid selects photos.
    ///   - available: the photo can be opened now (a search hit has its facts; a suggestion's
    ///     photos are not waiting for its album).
    public init(place: Place, isIgnored: Bool = false, selecting: Bool = false, available: Bool = true) {
        guard Self.isOffered(selecting: selecting, available: available) else {
            sections = []
            return
        }
        switch place {
        case .unsorted, .album, .search:
            sections = [[.view, .addToAlbum], [isIgnored ? .stopIgnoring : .ignore]]
        case .suggestion:
            sections = [[.view], [.removeFromSuggestion]]
        }
    }

    /// No menu: the long press does nothing.
    public var isEmpty: Bool { sections.isEmpty }

    /// Every item, in order.
    public var items: [Item] { sections.flatMap { $0 } }

    /// The items that are also actions of the photo for VoiceOver: all but "Ansehen", which is
    /// the photo's own (a double tap opens it).
    public var accessibilityItems: [Item] { items.filter { $0 != .view } }

    /// Whether the photo has a menu at all, known from its grid alone: none while the grid
    /// selects or the photo cannot be opened. The app switches the long press off with it (an
    /// empty menu closure: no lift, no menu, no actions; review C of design wave 2, M4).
    public static func isOffered(selecting: Bool, available: Bool) -> Bool {
        !selecting && available
    }

    /// Whether the photo is ignored, so its menu offers "Nicht mehr ignorieren". With a state, as
    /// its "Info" says it (`OrganizationStatusResolver.overall`: an excluded photo shows as
    /// excluded, also when the user ignored it too). A photo without a state (an album's photo
    /// the analysis has not read yet) gets none from "Ignorieren", only its place in `ignored`
    /// (the store's, with the taps since laid over it, `IgnoreChange`): that decides for it
    /// (review C of design wave 2, L6).
    public static func isIgnored(_ id: AssetID, ignored: Set<AssetID>, state: AssetOrganizationState?) -> Bool {
        guard let state else { return ignored.contains(id) }
        return !OrganizationStatusResolver.isExcluded(state) && OrganizationStatusResolver.isIgnored(state)
    }

    /// The size of the lifted photo, in points.
    public struct PreviewSize: Equatable, Sendable {
        public let width: Double
        public let height: Double

        /// Width to height.
        public var aspectRatio: Double { width / height }
    }

    /// The largest box the lifted photo fills: the width of an album's lifted preview
    /// (`AlbumPreview`, 320 pt), as high as a photo taken upright (3:4) is at that width. Small
    /// enough to leave room for the menu on the smallest iPhone.
    public static let previewBounds = (width: 320.0, height: 320.0 * 4 / 3)
    /// Proportions beyond any camera are held here, so the preview is never a line.
    public static let previewAspectRange: ClosedRange<Double> = 0.25...6
    /// How much of the pixels it fills an image must bring, per side, to count as sharp: the
    /// covers' rule (`ThumbnailRequest.sharpShare` in the app, the same 70 %).
    public static let sharpShare = 0.7

    /// The size of the lifted photo, in points: the image its cell shows (the grid's thumbnail,
    /// `imageWidth` × `imageHeight` pixels, on a screen of `scale`), whole, in its own
    /// proportions, as large as it is sharp (`sharpShare`), at most `previewBounds` (review C of
    /// design wave 2, M2: lifted at once from what the cell shows, never a placeholder or a
    /// blurry enlargement). Never smaller than its cell (`cellSide` points on its short side),
    /// which shows the image that large already; a square of the cell when the image is not
    /// known.
    public static func liftSize(imageWidth: Double, imageHeight: Double, scale: Double, cellSide: Double) -> PreviewSize {
        guard imageWidth > 0, imageHeight > 0, scale > 0 else { return PreviewSize(width: cellSide, height: cellSide) }
        let ratio = min(max(imageWidth / imageHeight, previewAspectRange.lowerBound), previewAspectRange.upperBound)
        let pixelsPerPoint = scale * sharpShare
        // As high as the image is sharp, on the side that decides in these proportions.
        var height = min(imageHeight / pixelsPerPoint, imageWidth / pixelsPerPoint / ratio)
        // At least as large as its cell shows it (filled: its short side is the cell's side).
        let shortSide = min(height * ratio, height)
        if shortSide < cellSide { height *= cellSide / shortSide }
        height = min(height, previewBounds.height, previewBounds.width / ratio)
        return PreviewSize(width: height * ratio, height: height)
    }

    /// The lifted photo whole, in its own proportions, as large as fits in `previewBounds`; 4:3
    /// when its size is not known.
    public static func previewSize(pixelWidth: Int, pixelHeight: Int) -> PreviewSize {
        let known = pixelWidth > 0 && pixelHeight > 0
        let raw = known ? Double(pixelWidth) / Double(pixelHeight) : 4.0 / 3.0
        let ratio = min(max(raw, previewAspectRange.lowerBound), previewAspectRange.upperBound)
        let width = min(previewBounds.width, previewBounds.height * ratio)
        return PreviewSize(width: width, height: width / ratio)
    }
}
