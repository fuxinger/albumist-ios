import SwiftUI
import SortlyCore

/// "Erster Scan als Show": during the first analysis the user's own photos form a mosaic
/// that a soft light sweeps across, and every trip Albumist finds pops up as a card.
/// Only during the first analysis (Fuchs 16.11.; `ScanShowRule`, one switch): later analyses
/// show only the calm progress card.
struct ScanShow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = 6
    private let rows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            mosaic
            found
        }
    }

    /// Photos spread over the whole library, so the mosaic shows years, not one afternoon.
    private var mosaicPhotos: [AssetID] {
        MainThreadWatch.shared.section("scan show photos") { pickMosaicPhotos() }
    }

    private func pickMosaicPhotos() -> [AssetID] {
        let facts = model.facts
        let count = columns * rows
        guard facts.count > count else { return facts.map(\.id) }
        return (0..<count).map { facts[$0 * (facts.count - 1) / (count - 1)].id }
    }

    private var mosaic: some View {
        let photos = mosaicPhotos
        return Group {
            if photos.count >= columns {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                    ForEach(photos, id: \.self) { id in
                        AssetThumbnail(id: id, side: 64)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .opacity(0.6)
                    }
                }
                .overlay {
                    // The sweep moves only while the analysis really works (`ScanShowRule.animates`:
                    // not with Reduce Motion, not in the background, not when the phone is hot).
                    if model.scanShowAnimates(reduceMotion: reduceMotion) {
                        MosaicSweep()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.6), value: photos.count)
        // The photos are decoration; the progress card says what happens.
        .accessibilityHidden(true)
    }

    /// Trips found so far, newest first; each appears with a small spring.
    private var found: some View {
        let trips = model.proposals
            .filter { $0.kind == .trip }
            .sorted { ($0.dateRange?.start ?? .distantPast) > ($1.dateRange?.start ?? .distantPast) }
            .prefix(3)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !trips.isEmpty {
                Text("Schon gefunden")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            ForEach(Array(trips)) { trip in
                HStack(spacing: Theme.Spacing.m) {
                    AssetThumbnail(id: trip.coverAssetID ?? AssetID(""), side: 44)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.userTitles[trip.id] ?? trip.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(trip.assetIDs.count) Aufnahmen")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "airplane")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .transition(reduceMotion ? AnyTransition.opacity
                            : AnyTransition.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.45, dampingFraction: 0.7), value: trips.map(\.id))
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
