import SwiftUI
import AlbumistCore

// The covers of the changes Albumist made (design wave 3, DS-15): one per change in the history
// ("Verlauf und Rückgängig"), one per album in the receipt ("Änderungen"), larger than the 44 pt
// pictures the rows had. Which photos each one tries is decided in the core (`PlanCovers`);
// `CoverPhoto` shows the first one that is sharp on the device and never loads from iCloud.
// Decorative for VoiceOver: the rows say what the change did.

/// The sizes the covers of the history and the receipt share.
enum ChangeCoverMetrics {
    /// A cover's side beside the words of its row, growing a little with the text.
    static let side: CGFloat = 72
    /// At most this large beside the words, so they keep their room up to the largest standard
    /// text size (at the accessibility sizes the cover is a strip above them).
    static let largestSide: CGFloat = 96
    /// Between the albums of a change's cover, as in a folder's tile.
    static let gap: CGFloat = 2
    /// At the accessibility text sizes a cover is a strip across the row, above its words, three
    /// times as wide as high (as the albums' tiles there).
    static let stripAspectRatio: CGFloat = 3
}

extension PlanReceipt.Kind {
    /// The symbol on the calm ground of a change that has no photo to show: albums for one that
    /// made or extended some (of screenshots only), a removed album for a removal from "Alben von
    /// Albumist" (as the receipt shows one), the way back for an undo.
    var coverSymbol: String {
        switch self {
        case .created: "rectangle.stack"
        case .removed: "rectangle.stack.badge.minus"
        case .undone: "arrow.uturn.backward"
        }
    }
}

/// An album's cover beside its row in the receipt: the photos the change added to it, as the tab
/// "Alben" shows the album (`PlanCovers.cover`); "Vorschau ausgeblendet" when every one is a
/// sensitive document; a symbol on the calm ground when there is no photo to try. 72 pt beside
/// the words, a strip across the row above them at the accessibility text sizes. The preview's
/// album rows (DS-15 part 2) and the merge rows of "Reise anpassen" (review G8) show theirs so.
struct AlbumRowCover: View {
    var ids: [AssetID]
    var hidesPreview = false
    /// Shown once it is clear that no photo comes; nil while the photos are worked out.
    var placeholderSymbol: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = ChangeCoverMetrics.side

    var body: some View {
        let strip = typeSize.isAccessibilitySize
        CoverPhoto(ids: ids, aspectRatio: strip ? ChangeCoverMetrics.stripAspectRatio : 1, cornerRadius: Theme.Radius.tile,
                   hidesPreview: hidesPreview, placeholderSymbol: placeholderSymbol)
            .frame(width: strip ? nil : min(side, ChangeCoverMetrics.largestSide))
    }
}

/// A change's cover in the history: the albums of that run (`PlanCovers.mosaic`), as a folder's
/// tile shows its albums (`FolderTile`), without an empty place: one album fills it, two share it
/// side by side, three are one large and two small, four a square of four. At the accessibility
/// text sizes a strip across the row, the albums side by side. "Vorschau ausgeblendet" when every
/// photo of the change is a sensitive document; the change's symbol on the calm ground when it has
/// no photo to show (an undo, a removal, albums of screenshots only).
struct ChangeCover: View {
    /// Nil while the history works it out: the calm ground, no symbol yet.
    var mosaic: PlanCovers.Mosaic?
    /// `PlanReceipt.Kind.coverSymbol` of the change.
    var symbol: String

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = ChangeCoverMetrics.side

    var body: some View {
        let tiles = mosaic?.tiles ?? []
        Group {
            if typeSize.isAccessibilitySize {
                strip(tiles)
            } else {
                square(tiles, side: min(side, ChangeCoverMetrics.largestSide))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityHidden(true)
    }

    /// No album to show: "Vorschau ausgeblendet", or the change's symbol once it is clear that no
    /// photo comes.
    private func whole(aspectRatio: CGFloat) -> some View {
        CoverPhoto(ids: [], aspectRatio: aspectRatio, cornerRadius: 0, hidesPreview: mosaic?.hidden ?? false,
                   placeholderSymbol: mosaic == nil ? nil : symbol)
    }

    /// One album's place, `width` × `height`: the photos it tries, the calm ground without one
    /// (no symbol: it would not fit a quarter).
    private func tile(_ ids: [AssetID], width: CGFloat, height: CGFloat) -> some View {
        CoverPhoto(ids: ids, aspectRatio: width / max(height, 1), cornerRadius: 0)
            .frame(width: width, height: height)
    }

    /// Beside the words: a square of `side`.
    @ViewBuilder
    private func square(_ tiles: [[AssetID]], side: CGFloat) -> some View {
        let gap = ChangeCoverMetrics.gap
        let half = (side - gap) / 2
        switch tiles.count {
        case 0:
            whole(aspectRatio: 1)
                .frame(width: side, height: side)
        case 1:
            tile(tiles[0], width: side, height: side)
        case 2:
            HStack(spacing: gap) {
                tile(tiles[0], width: half, height: side)
                tile(tiles[1], width: half, height: side)
            }
        case 3:
            HStack(spacing: gap) {
                tile(tiles[0], width: half, height: side)
                VStack(spacing: gap) {
                    tile(tiles[1], width: half, height: half)
                    tile(tiles[2], width: half, height: half)
                }
            }
        default:
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                GridRow {
                    tile(tiles[0], width: half, height: half)
                    tile(tiles[1], width: half, height: half)
                }
                GridRow {
                    tile(tiles[2], width: half, height: half)
                    tile(tiles[3], width: half, height: half)
                }
            }
        }
    }

    /// At the accessibility text sizes: a strip across the row, the albums side by side in equal
    /// parts.
    @ViewBuilder
    private func strip(_ tiles: [[AssetID]]) -> some View {
        if tiles.isEmpty {
            whole(aspectRatio: ChangeCoverMetrics.stripAspectRatio)
        } else {
            HStack(spacing: ChangeCoverMetrics.gap) {
                ForEach(tiles.indices, id: \.self) { index in
                    CoverPhoto(ids: tiles[index], aspectRatio: ChangeCoverMetrics.stripAspectRatio / CGFloat(tiles.count), cornerRadius: 0)
                }
            }
        }
    }
}
