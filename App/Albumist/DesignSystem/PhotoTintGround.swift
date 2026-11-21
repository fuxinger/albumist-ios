import SwiftUI
import UIKit
import AlbumistCore

/// Albumist's own handwriting (DS-11, design wave 3): the calm colour of the photo on screen as
/// the ground of its page, as Music lets an album's artwork run into its page (`PhotoTint` says
/// what is taken from Apple and why). Used on one page: behind a suggestion's large cover
/// (`ProposalDetailView`). Never on cards in lists, never behind a photo's own text (there is
/// none), never instead of a cover.
///
/// - A flat colour, no gradient, no glow; pale in light mode, deep in dark mode.
/// - Increase Contrast wins: the plain grouped background then, whatever the photo.
/// - Not known yet, or no colour of its own: the plain grouped background (`Theme.background`),
///   which the tint replaces in a slow cross-fade, never a jump.
enum PhotoTintGround {
    /// The page's ground for `tint`: its light or dark colour, the grouped background without a
    /// tint or with Increase Contrast.
    static func color(_ tint: PhotoTint?) -> Color {
        guard let tint else { return Theme.background }
        let light = UIColor(tint.light), dark = UIColor(tint.dark)
        return Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high { return .systemGroupedBackground }
            return traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// How the ground changes when the tint arrives: a slow cross-fade.
    static let arrival = Animation.easeInOut(duration: 0.45)
}

private extension UIColor {
    convenience init(_ color: SRGB) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

/// The tints of the photos shown as covers (`PhotoTint`), worked out once per photo from the
/// image already in memory: the cover `CoverPhoto` keeps in the covers' store
/// (`ThumbnailCache.cachedCover`). Nothing is asked of Photos for it, nothing comes from iCloud;
/// a cover that is not kept (blurry, or dropped on a memory warning) gives no tint. Its pixels are
/// read off the main thread. Small: two colours per photo, at most `limit` photos.
@MainActor
final class PhotoTints {
    static let shared = PhotoTints()
    private var tints: [AssetID: PhotoTint] = [:]
    /// Photos without a colour of their own.
    private var plain: Set<AssetID> = []
    static let limit = 400

    /// The tint of the cover that shows for `ids` at `pixels`: the first of them whose cover is
    /// kept at that size, as `CoverPhoto` shows the first sharp one. Nil while none is kept, or
    /// when its photo has no colour of its own.
    func tint(for ids: [AssetID], pixels: CGSize) async -> PhotoTint? {
        for id in ids {
            if let known = tints[id] { return known }
            if plain.contains(id) { return nil }
            guard let kept = ThumbnailCache.shared.cachedCover(for: id, pixels: pixels),
                  let image = kept.image.cgImage else { continue }
            let sampled = SampledImage(image: image)
            let tint = await Task.detached(priority: .utility) { Self.sample(sampled.image) }.value
            if tints.count + plain.count >= Self.limit {
                tints.removeAll()
                plain.removeAll()
            }
            if let tint { tints[id] = tint } else { plain.insert(id) }
            return tint
        }
        return nil
    }

    /// The image drawn into 24 × 24 sRGB pixels and read (`PhotoTint.from`).
    nonisolated static func sample(_ image: CGImage) -> PhotoTint? {
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return PhotoTint.from(rgba: bytes, width: side, height: side)
    }
}

/// A cover's pixels on their way off the main thread: a `CGImage` is immutable.
private struct SampledImage: @unchecked Sendable {
    let image: CGImage
}

/// Reads the tint of the cover this view draws (`CoverPhoto` with `ids` at `aspectRatio`, as
/// wide as this view) once it shows a sharp photo (`sharp`), into `tint`: at once when the photo's
/// tint is known, in a slow cross-fade when it arrives (`PhotoTintGround.arrival`).
struct CoverTintReader: ViewModifier {
    let ids: [AssetID]
    let aspectRatio: CGFloat
    let sharp: Bool
    @Binding var tint: PhotoTint?
    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0

    private struct Key: Equatable {
        var ids: [AssetID]
        var pixels: CGSize
        var sharp: Bool
    }

    /// The pixels `CoverPhoto` asks for and keeps its cover at: its width in whole points, the
    /// height from the aspect ratio, times the screen's scale.
    private var pixels: CGSize {
        let ratio = max(aspectRatio, 0.1)
        return CGSize(width: width.rounded(.up) * displayScale, height: (width / ratio).rounded(.up) * displayScale)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: Key(ids: Array(ids.prefix(CoverLoader.attempts)), pixels: pixels, sharp: sharp)) {
                guard sharp, width >= 1 else { return }
                let found = await PhotoTints.shared.tint(for: Array(ids.prefix(CoverLoader.attempts)), pixels: pixels)
                guard !Task.isCancelled, found != tint else { return }
                withAnimation(PhotoTintGround.arrival) { tint = found }
            }
    }
}

extension View {
    /// The calm colour of the cover this view draws (DS-11), into `tint`; see `CoverTintReader`.
    func coverTint(of ids: [AssetID], aspectRatio: CGFloat, sharp: Bool, into tint: Binding<PhotoTint?>) -> some View {
        modifier(CoverTintReader(ids: ids, aspectRatio: aspectRatio, sharp: sharp, tint: tint))
    }
}
