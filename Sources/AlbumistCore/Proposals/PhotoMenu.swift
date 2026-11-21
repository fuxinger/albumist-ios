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
        guard !selecting, available else {
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
