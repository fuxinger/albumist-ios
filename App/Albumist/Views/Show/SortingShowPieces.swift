import SwiftUI
import UIKit
import AlbumistCore

// The pieces of the sorting show (`SortingShow`, DS-17): the photos on the pile and in flight,
// and the album with its real cover.

/// The photos of the sorting show that are sharp on the device at the size they are drawn: only
/// those lie on the pile and fly (design rule 7, "nur scharf vom Gerät"). Asked of Photos without
/// iCloud (`ThumbnailCache`, `isNetworkAccessAllowed = false`); a photo whose original is only in
/// iCloud has only a small preview on the device, which is not sharp at this size and stays away
/// (`ThumbnailRequest.isSharp`). Each photo is asked for once per size; one loaded for a larger
/// size serves a smaller one (the scene is measured after it starts).
@MainActor @Observable
final class ShowPhotos {
    private var images: [AssetID: UIImage] = [:]
    /// The largest side each photo was asked for, sharp or not: not asked again at that size.
    @ObservationIgnored private var asked: [AssetID: CGFloat] = [:]

    /// The photo, when it is sharp at `pixels`.
    func image(_ id: AssetID, sharpAt pixels: CGSize) -> UIImage? {
        guard let image = images[id], ThumbnailRequest.isSharp(image, for: pixels) else { return nil }
        return image
    }

    /// Loads `ids` at `side` points, one after the other, keeping the sharp ones.
    func load(_ ids: some Sequence<AssetID>, side: CGFloat, scale: CGFloat) async {
        guard side >= 1, scale > 0 else { return }
        let pixels = CGSize(width: side * scale, height: side * scale)
        for id in ids {
            if Task.isCancelled { return }
            if image(id, sharpAt: pixels) != nil { continue }
            if let earlier = asked[id], earlier >= side { continue }
            asked[id] = side
            let loaded = await ThumbnailCache.shared.image(for: id, side: side)
            guard !Task.isCancelled else {
                asked[id] = nil
                return
            }
            if let loaded, ThumbnailRequest.isSharp(loaded, for: pixels) { images[id] = loaded }
        }
    }
}

/// A photo as a print: rounded edge in the card colour (white in light mode, a quiet rim in dark
/// mode), soft shadow. Drawn only from a sharp image (`ShowPhotos`).
struct ShowPhotoChip: View {
    var image: UIImage
    var side: CGFloat
    var radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.card, lineWidth: 3) }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

/// The album the photos fly into: its real cover (DS-17, "Album mit Titelbild statt blassem
/// Kästchen"), two layers of a stack above it, its name and count below.
///
/// - The cover is the album's own (`SortingShowAlbum.cover`): sharp from the device or its calm
///   placeholder (`CoverPhoto`), "Vorschau ausgeblendet" for a personal album.
/// - Waiting for its step, the cover stands in grey; filled, it takes its colours, with a check
///   on a solid ring (never a mark straight on the photo). A colour change, no glow; with Reduce
///   Motion a cross-fade, as everything else.
/// - The name hangs below the cover without moving it, so the cover's centre is where the
///   layout says (`SortingShowLayout.coverCenterY`), whatever the name's length.
struct ShowAlbumCover: View {
    var album: SortingShow.Album
    var filled: Bool
    /// The album in the centre; neighbours hide their names (the screen's edges would cut them).
    var focused: Bool
    var layout: SortingShowLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cover = CGFloat(layout.cover)
        let layers = CGFloat(layout.layers)
        let shape = RoundedRectangle(cornerRadius: CGFloat(layout.coverRadius), style: .continuous)
        ZStack {
            shape
                .fill(Theme.card)
                .frame(width: cover - 2 * layers + 6, height: cover - 2 * layers + 6)
                .offset(y: -layers)
                .opacity(0.7)
            shape
                .fill(Theme.card)
                .frame(width: cover - layers + 3, height: cover - layers + 3)
                .offset(y: -layers / 2)
            CoverPhoto(ids: album.cover, aspectRatio: 1, cornerRadius: CGFloat(layout.coverRadius),
                       hidesPreview: album.hidesPreview, placeholderSymbol: "rectangle.stack")
                .frame(width: cover, height: cover)
                .saturation(filled ? 1 : 0)
                .overlay(alignment: .bottomTrailing) {
                    if filled {
                        check
                            .padding(max(8, cover * 0.05))
                            .transition(reduceMotion ? AnyTransition.opacity
                                        : AnyTransition.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
        .frame(width: cover, height: cover)
        // The name and count hang below the cover: the cover keeps its place in the scene.
        .overlay(alignment: .bottom) {
            label
                .alignmentGuide(.bottom) { $0[.top] - CGFloat(SortingShowLayout.labelGap) }
                .opacity(focused ? 1 : 0)
        }
    }

    /// The check of a filled album, on a ring in the card's colour: it never sits straight on the
    /// photo (design rule 1).
    private var check: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: max(24, CGFloat(layout.cover) * 0.15), weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Theme.onAccent, Theme.accent)
            .background(Circle().fill(Theme.card).padding(-2.5))
    }

    /// Up to two lines, so trip names with dates stay whole. The hidden copy keeps room for two
    /// lines; the count follows the name directly and nothing below jumps.
    private var label: some View {
        ZStack(alignment: .top) {
            labelLines(title: "A\nA", count: 0).hidden()
            labelLines(title: album.title, count: album.assets.count)
        }
        .frame(width: CGFloat(layout.cover) + 56)
    }

    private func labelLines(title: String, count: Int) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(count) \(count.formatted()) Fotos")
                .font(.caption)
                .foregroundStyle(.noteText)
                .monospacedDigit()
        }
    }
}

struct ShowFlight: Identifiable {
    let id = UUID()
    let asset: AssetID
    let image: UIImage
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let angle: Double
    let delay: Double
    let duration: Double
}

/// One photo on its way: it lifts (grows, deeper shadow), swings along a curve and shrinks into
/// the album.
struct ShowFlyingPhoto: View {
    let flight: ShowFlight
    let side: CGFloat
    let radius: CGFloat
    @State private var progress: CGFloat = 0

    var body: some View {
        ShowPhotoChip(image: flight.image, side: side, radius: radius)
            .modifier(ShowArcFlight(progress: progress, from: flight.from, control: flight.control,
                                    to: flight.to, angle: flight.angle))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: flight.duration).delay(flight.delay)) {
                    progress = 1
                }
            }
    }
}

/// Position on a quadratic Bézier curve plus lift, turn and fade, driven by one number so
/// SwiftUI can animate it frame by frame.
struct ShowArcFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let angle: Double

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = progress
        let u = 1 - t
        let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
        let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
        // Lift first (+8 %, deeper shadow, squares up), then sink and shrink into the album.
        let lift = sin(CGFloat.pi * min(1, t / 0.6))
        let settle = max(0, (t - 0.5) / 0.5)
        let scale = (1 + 0.08 * lift) * (1 - 0.38 * settle * settle)
        let appear = Double(min(1, t / 0.08))
        let fade: Double = t > 0.9 ? Double((1 - t) / 0.1) : 1
        return content
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle * Double(u * u)))
            .shadow(color: .black.opacity(0.18 * Double(lift)), radius: 12 * lift, y: 8 * lift)
            .opacity(appear * fade)
            .position(x: x, y: y)
    }
}
