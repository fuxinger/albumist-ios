import SwiftUI
import SortlyCore

/// The photos of the "Startpaket" card (draft E1): one large cover on the left, two smaller ones
/// stacked on the right (with a fourth id the lower right one is split in two), 4 pt apart, the
/// outer corners round, the inner ones nearly square. Each tile is a `CoverPhoto` (sharp from the
/// device or its calm placeholder); a tile whose photo is not sharp tries the ids beyond the
/// tiles, every tile its own ones, so no photo shows twice. With one id it is one cover, with
/// none the calm placeholder. Decorative for VoiceOver: the card says what it is.
struct StarterSetMosaic: View {
    private let ids: [AssetID]
    private let aspectRatio: CGFloat

    /// `ids`: one cover per album of the starter set, best first (`PreviewPicker.coverCandidates`
    /// of each). `aspectRatio` of the whole mosaic: the draft's 337 × 124 pt.
    init(ids: [AssetID], aspectRatio: CGFloat = 337.0 / 124.0) {
        self.ids = ids
        self.aspectRatio = max(aspectRatio, 0.1)
    }

    private static let gap: CGFloat = 4
    private static let outerRadius: CGFloat = 16
    private static let innerRadius: CGFloat = 4

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    tiles(in: proxy.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.outerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    /// The ids of tile `index` of `count`: its own first, then every `count`-th one after the
    /// tiles (tile 0 of 3 gets ids 0, 3, 6, 9; tile 1 gets 1, 4, 7, 10).
    private func chain(_ index: Int, of count: Int) -> [AssetID] {
        Array(stride(from: index, to: ids.count, by: max(count, 1)).map { ids[$0] }.prefix(CoverLoader.attempts))
    }

    @ViewBuilder private func tiles(in size: CGSize) -> some View {
        let count = min(ids.count, 4)
        let gap = Self.gap
        let bigWidth = count >= 2 ? ((size.width - gap) * 0.64).rounded() : size.width
        let sideWidth = max(size.width - gap - bigWidth, 1)
        let halfHeight = max((size.height - gap) / 2, 1)
        HStack(spacing: gap) {
            tile(chain(0, of: count), width: bigWidth, height: size.height)
            if count == 2 {
                tile(chain(1, of: count), width: sideWidth, height: size.height)
            } else if count >= 3 {
                VStack(spacing: gap) {
                    tile(chain(1, of: count), width: sideWidth, height: halfHeight)
                    if count == 3 {
                        tile(chain(2, of: count), width: sideWidth, height: halfHeight)
                    } else {
                        let quarterWidth = max((sideWidth - gap) / 2, 1)
                        HStack(spacing: gap) {
                            tile(chain(2, of: count), width: quarterWidth, height: halfHeight)
                            tile(chain(3, of: count), width: quarterWidth, height: halfHeight)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ ids: [AssetID], width: CGFloat, height: CGFloat) -> some View {
        CoverPhoto(ids: ids, aspectRatio: width / max(height, 1), cornerRadius: Self.innerRadius)
            .frame(width: width, height: height)
    }
}
