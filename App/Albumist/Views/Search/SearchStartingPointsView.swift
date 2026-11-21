import SwiftUI
import AlbumistCore

/// The starting points of the empty search as photo tiles (design wave 3, DS-13), as Photos
/// offers its suggestions: the user's towns, the trips, the newest year, a topic and a kind, each
/// with a photo of its own (`SearchStartingPoints`). A tap searches the tile's words, as its chip
/// did. Laid out as the albums tab lays out albums (`AlbumGrid`, `PhotoCard` tiles, draft E4):
/// two square photos side by side on the smallest iPhone, name and count below them, no text on
/// a photo; at the accessibility text sizes one tile per row, its photo a wide strip, nothing
/// cut off. The page pads the grid; it adds no margins of its own.
struct SearchStartingPointGrid: View {
    let points: [SearchStartingPoint]
    /// The tile's chip: the page searches its words.
    let choose: @MainActor (SearchSuggestion) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The albums tab's narrowest column; `AlbumGrid` is generic, so it is read through a
        // concrete content type.
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .top)]
            : [GridItem(.adaptive(minimum: AlbumGrid<EmptyView>.minimumColumn, maximum: 260), spacing: Theme.Spacing.l, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(points) { point in
                SearchStartingPointTile(point: point) { choose(point.suggestion) }
            }
        }
    }
}

/// One starting point: its photo with the round corners of an album tile, the name below it and
/// the number of photos the search finds in the note grey. For assistive technologies one
/// button: the name, the count as its value ("Rom", "15 Fotos").
struct SearchStartingPointTile: View {
    let point: SearchStartingPoint
    let action: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let suggestion = point.suggestion
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                // Sharp from the device or a calm placeholder with the chip's symbol, never a big
                // blurry image (`CoverPhoto`); the candidates are never sensitive.
                CoverPhoto(ids: point.coverIDs, aspectRatio: typeSize.isAccessibilitySize ? 3 : 1,
                           cornerRadius: Theme.Radius.photoTile, placeholderSymbol: SearchView.symbol(suggestion.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: suggestion.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .compactLineLimit(2)
                    Text("\(suggestion.count) \(suggestion.count.formatted()) Fotos")
                        .font(.footnote)
                        .foregroundStyle(.noteText)
                        .monospacedDigit()
                        .compactLineLimit(2)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: suggestion.label))
        .accessibilityValue(Text("\(suggestion.count) \(suggestion.count.formatted()) Fotos"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("search.example")
    }
}
