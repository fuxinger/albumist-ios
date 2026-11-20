import SwiftUI
import SortlyCore

/// "Erster Scan als Show": during the first analysis the user's own photos form a mosaic
/// that a soft light sweeps across (draft E6 "Analyse läuft": two rows of six under the ring
/// card, the last three paler, as if still being looked at). The trips Albumist finds meanwhile
/// are cards right under it ("Schon gefunden", `StartPage`). Only during the first analysis
/// (Fuchs 16.11.; `ScanShowRule`, one switch): later analyses show only the calm ring card.
struct ScanShow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = 6
    private let rows = 2
    /// The last tiles are paler (draft E6).
    private let paler = 3

    var body: some View {
        mosaic
    }

    /// Photos spread over the whole library, so the mosaic shows years, not one afternoon.
    private var mosaicPhotos: [AssetID] {
        MainThreadWatch.shared.section("scan show photos") { pickMosaicPhotos() }
    }

    /// Ordinary photos only where the library has them: no screenshot, document or bank card
    /// in the mosaic (`PreviewPicker.evenly`).
    private func pickMosaicPhotos() -> [AssetID] {
        PreviewPicker.evenly(model.facts, count: columns * rows, ranks: model.previewRanks) { $0.id }
    }

    private var mosaic: some View {
        let photos = mosaicPhotos
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Group {
            if photos.count >= columns {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                    ForEach(Array(photos.enumerated()), id: \.element) { index, id in
                        AssetThumbnail(id: id, side: 64)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(shape)
                            .compositingGroup() // fade photo and its placeholder as one
                            .opacity(index < photos.count - paler ? 1 : 0.55)
                    }
                }
                .overlay {
                    // The sweep moves only while the analysis really works (`ScanShowRule.animates`:
                    // not with Reduce Motion, not in the background, not when the phone is hot).
                    // Not in UI runs either, like the atlas reveal: the screen then comes to rest.
                    if model.scanShowAnimates(reduceMotion: reduceMotion), !UITestSupport.isRunning {
                        MosaicSweep()
                    }
                }
                .clipShape(shape)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.6), value: photos.count)
        // The photos are decoration; the ring card says what happens.
        .accessibilityHidden(true)
    }
}

/// A soft light band across the mosaic, one pass every 2.4 seconds: one repeating animation
/// that the system runs by itself. It used to be a 10-per-second timeline that recomputed every
/// tile, so the screen changed ten times a second during the first analysis.
private struct MosaicSweep: View {
    @State private var moving = false

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.35)
                .offset(x: moving ? geometry.size.width : -geometry.size.width * 0.35)
                .blendMode(.plusLighter)
                .onAppear {
                    withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { moving = true }
                }
                .onDisappear { moving = false }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
