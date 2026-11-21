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
///
/// Which photo the cover shows decides, at the size it shows: the first of the candidates kept
/// at that size, as `CoverPhoto` shows the first sharp one. A tint worked out before for another
/// size of the page (turned, another text size) is used only when that photo is the one kept at
/// this size (second review, K5).
@MainActor
final class PhotoTints {
    static let shared = PhotoTints()
    private var tints: [AssetID: PhotoTint] = [:]
    /// Photos without a colour of their own.
    private var plain: Set<AssetID> = []
    static let limit = 400

    /// What is known, without waiting, of the colour of the cover that shows for `ids` at `pixels`.
    enum Known: Equatable {
        /// Worked out before: its tint, nil for a photo without a colour of its own.
        case tint(PhotoTint?)
        /// Its cover is kept, its tint is not worked out yet (`tint(for:pixels:)`).
        case notYet
        /// None of them is kept at that size (yet): which photo shows is not known.
        case noCover
    }

    /// The colour of the cover that shows for `ids` at `pixels`, when it is known: a page opened
    /// again takes it at once (`CoverTintReader`).
    func known(for ids: [AssetID], pixels: CGSize) -> Known {
        for id in ids {
            guard ThumbnailCache.shared.cachedCover(for: id, pixels: pixels) != nil else { continue }
            if let known = tints[id] { return .tint(known) }
            if plain.contains(id) { return .tint(nil) }
            return .notYet
        }
        return .noCover
    }

    /// The tint of the cover that shows for `ids` at `pixels`: the first of them whose cover is
    /// kept at that size, as `CoverPhoto` shows the first sharp one. Nil while none is kept, or
    /// when its photo has no colour of its own.
    func tint(for ids: [AssetID], pixels: CGSize) async -> PhotoTint? {
        for id in ids {
            guard let kept = ThumbnailCache.shared.cachedCover(for: id, pixels: pixels) else { continue }
            if let known = tints[id] { return known }
            if plain.contains(id) { return nil }
            guard let image = kept.image.cgImage else { return nil }
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
/// wide as this view) while it shows a sharp photo (`sharp`), into `tint`: at once when the
/// photo's tint is known, in a slow cross-fade when it was just worked out
/// (`PhotoTintGround.arrival`). The page's own ground again (in the cross-fade) when the cover
/// stops being a sharp photo or its preview becomes hidden (second review, K5 and K8).
///
/// A colour known for the cover kept at this size is there from the page's first frame: taken as
/// the page is measured for the first time, before the cover tells that it shows a photo, never
/// for a hidden preview (`seed`; verification review V5).
struct CoverTintReader: ViewModifier {
    let ids: [AssetID]
    let aspectRatio: CGFloat
    /// The cover tells that it shows a sharp photo (`CoverPhoto`'s outcome).
    let sharp: Bool
    /// "Vorschau ausgeblendet": no colour, not even one known before.
    let hidden: Bool
    @Binding var tint: PhotoTint?
    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0

    private struct Key: Equatable {
        var ids: [AssetID]
        var pixels: CGSize
        var sharp: Bool
    }

    /// How long the reader waits for the cover at a new size (turned, another text size), every
    /// quarter of a second: until `CoverPhoto` keeps it there, which photo shows is not known.
    /// As long as a cover asks Photos again when it did not answer (`CoverLoader.retryDelays`).
    private static let coverWaits = 24

    /// The pixels `CoverPhoto` asks for and keeps its cover at.
    private var pixels: CGSize { pixels(at: width) }

    /// The pixels of the cover `width` points wide, as `CoverPhoto` asks for and keeps it: the
    /// width in whole points, the height from the aspect ratio, times the screen's scale.
    private func pixels(at width: CGFloat) -> CGSize {
        let ratio = max(aspectRatio, 0.1)
        return CGSize(width: width.rounded(.up) * displayScale, height: (width / ratio).rounded(.up) * displayScale)
    }

    func body(content: Content) -> some View {
        let key = Key(ids: CoverPhoto.candidates(ids), pixels: pixels, sharp: sharp && !hidden)
        return content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                // Measured for the first time: a colour known for this cover is there at once.
                if width < 1 { seed(width: new) }
                width = new
            }
            .task(id: key) {
                guard !Task.isCancelled, key.pixels.width >= 1 else { return }
                // Not a sharp photo: a colour taken for the cover kept at this size stays while
                // the cover is still to tell (`seed`); otherwise (the placeholder, "Vorschau
                // ausgeblendet", its photos taken out) the page's own ground again.
                guard key.sharp else {
                    if tint != nil, hidden || PhotoTints.shared.known(for: key.ids, pixels: key.pixels) != .tint(tint) {
                        withAnimation(PhotoTintGround.arrival) { tint = nil }
                    }
                    return
                }
                await follow(key)
            }
    }

    /// The page is measured for the first time (`width` points): the colour known for the cover
    /// kept at that size, the one `CoverPhoto` is about to show, at once, without the fade, so a
    /// page opened again starts in it instead of switching to it a few frames later, once the
    /// cover told (verification review V5). Nothing for a hidden preview or a cover not kept yet.
    private func seed(width: CGFloat) {
        guard !hidden, tint == nil, width >= 1 else { return }
        if case .tint(let known?) = PhotoTints.shared.known(for: CoverPhoto.candidates(ids), pixels: pixels(at: width)) {
            tint = known
        }
    }

    /// The colour of the cover on screen: one worked out before at once, with its cover (a page
    /// opened again starts in its colour, not on grey); one worked out now, and a change from one
    /// colour to another, in the slow cross-fade.
    private func follow(_ key: Key) async {
        for _ in 0..<Self.coverWaits {
            switch PhotoTints.shared.known(for: key.ids, pixels: key.pixels) {
            case .tint(let known):
                guard known != tint else { return }
                if tint == nil { tint = known } else { withAnimation(PhotoTintGround.arrival) { tint = known } }
                return
            case .notYet:
                let found = await PhotoTints.shared.tint(for: key.ids, pixels: key.pixels)
                guard !Task.isCancelled, found != tint else { return }
                withAnimation(PhotoTintGround.arrival) { tint = found }
                return
            case .noCover:
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
        }
        // Still no cover of these kept at this size: which photo shows is not known, no colour.
        if tint != nil { withAnimation(PhotoTintGround.arrival) { tint = nil } }
    }
}

extension View {
    /// The calm colour of the cover this view draws (DS-11), into `tint`; see `CoverTintReader`.
    /// `sharp`: the cover told that it shows a sharp photo; `hidden`: its preview is hidden.
    func coverTint(of ids: [AssetID], aspectRatio: CGFloat, sharp: Bool, hidden: Bool, into tint: Binding<PhotoTint?>) -> some View {
        modifier(CoverTintReader(ids: ids, aspectRatio: aspectRatio, sharp: sharp, hidden: hidden, tint: tint))
    }
}
