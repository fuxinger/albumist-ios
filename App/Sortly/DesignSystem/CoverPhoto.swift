import SwiftUI
import UIKit
import SortlyCore

/// Fills the width at `aspectRatio`, loads only what is on the device, tries `ids` in order and shows the first
/// one that is sharp enough for its size; if none is: a calm tinted placeholder, never a big blurry image.
///
/// - Only from the device (`ThumbnailCache`, `isNetworkAccessAllowed = false`: the owner's
///   promise). With "iPhone-Speicher optimieren" Photos often keeps only a small preview of an
///   older photo; stretched over a card it would be a big blurry picture (design rule 7).
/// - Sharp enough: the image brings at least 70 % of the pixels it fills, per side, at the size
///   the cover is drawn (`ThumbnailRequest.isSharp`).
/// - At most `CoverLoader.attempts` ids are tried, one after the other, each asked for at the
///   drawn size; Photos is asked off the main thread (`ThumbnailRequest`), the asset lookups go
///   through the cache's batched lookup, and leaving the screen cancels what is still asked.
/// - None sharp: a calm surface in the colours of the first small preview there was (four
///   colours, never the picture), or a soft accent tint when there was none; the same tint while
///   a photo loads, never an empty grey. Counted for the diagnostic report (`CoverStats`).
/// - `hidesPreview`: "Vorschau ausgeblendet" on a neutral ground, nothing is loaded.
/// - `placeholderSymbol`: an SF Symbol on the calm placeholder once it is clear there is no
///   sharp photo (a suggestion of screenshots or documents has no cover candidates at all,
///   `PreviewPicker.coverCandidates`), so the card looks meant that way, not empty.
/// - `onOutcome`: told once the cover knows whether it shows a sharp photo, for a card that
///   turns smaller when there is none ("ein anderes Foto oder die kleine Karte").
/// - Crop ("Bildausschnitt", `CoverLoader.focus`): screenshots keep their top; a photo cut at top
///   and bottom keeps its upper part (portraits centred a third down, where faces and heads are,
///   landscapes 40 % down); cut at the sides, around the middle. Cheap: no image analysis.
///
/// Decorative for VoiceOver: the card around it says what it shows.
struct CoverPhoto: View {
    private let ids: [AssetID]
    private let aspectRatio: CGFloat
    private let cornerRadius: CGFloat
    private let hidesPreview: Bool
    private let placeholderSymbol: String?
    private let onOutcome: (@MainActor (CoverOutcome) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0
    @State private var loaded: CoverLoader.Loaded?

    init(ids: [AssetID], aspectRatio: CGFloat = 4.0 / 3.0, cornerRadius: CGFloat = Theme.Radius.card, hidesPreview: Bool = false,
         placeholderSymbol: String? = nil, onOutcome: (@MainActor (CoverOutcome) -> Void)? = nil) {
        self.ids = ids
        self.aspectRatio = max(aspectRatio, 0.1)
        self.cornerRadius = cornerRadius
        self.hidesPreview = hidesPreview
        self.placeholderSymbol = placeholderSymbol
        self.onOutcome = onOutcome
    }

    /// The ids that are tried: the first `CoverLoader.attempts` real ones.
    private var candidates: [AssetID] {
        Array(ids.lazy.filter { !$0.rawValue.isEmpty }.prefix(CoverLoader.attempts))
    }

    /// What is asked of Photos: the candidates at the drawn size in pixels (whole points, so a
    /// layout pass that moves the width by a fraction asks nothing again); nil while hidden or
    /// before the first layout.
    private var request: CoverLoader.Request? {
        let candidates = self.candidates
        guard !hidesPreview, width >= 1, !candidates.isEmpty else { return nil }
        let points = CGSize(width: width.rounded(.up), height: (width / aspectRatio).rounded(.up))
        return CoverLoader.Request(ids: candidates, pixels: CGSize(width: points.width * displayScale,
                                                                  height: points.height * displayScale))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let request = self.request
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content }
            .clipShape(shape)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: request) {
                guard let request else {
                    // No photo to try at all (only screenshots or documents): known at once.
                    if !hidesPreview && candidates.isEmpty { onOutcome?(.noSharpPhoto) }
                    return
                }
                let started = ContinuousClock.now
                let result = await CoverLoader.load(request)
                guard !Task.isCancelled else { return }
                // A cover from the cache is there at once; one that took a moment fades in
                // (a cross-fade, calm with Reduce Motion too).
                if ContinuousClock.now - started > .milliseconds(60) {
                    withAnimation(.easeOut(duration: 0.2)) { loaded = result }
                } else {
                    loaded = result
                }
                onOutcome?(result.outcome)
            }
            .accessibilityHidden(true)
    }

    /// The loaded result, when it belongs to these ids (a reused view that got another
    /// suggestion's ids does not show the old photo while the new one loads).
    private var current: CoverLoader.Shown? {
        guard let loaded, loaded.ids == candidates else { return nil }
        return loaded.shown
    }

    @ViewBuilder private var content: some View {
        if hidesPreview {
            HiddenCoverPreview()
        } else if case .photo(let image, let focus)? = current {
            GeometryReader { proxy in
                CroppedCover(image: image, focus: focus, size: proxy.size)
            }
            .transition(.opacity)
        } else if case .placeholder(let colors)? = current {
            CoverPlaceholder(colors: colors, symbol: placeholderSymbol)
        } else {
            // Loading, or nothing to load: the same calm surface, the symbol only once it is
            // clear that no photo comes (no flash of it while a photo loads).
            CoverPlaceholder(colors: [], symbol: candidates.isEmpty ? placeholderSymbol : nil)
        }
    }
}

/// The image filling `size`, cropped around `focus` (a share of the image) as far as the
/// image reaches: the focus sits in the middle of the cover unless that would leave an edge
/// of the cover empty.
private struct CroppedCover: View {
    let image: UIImage
    let focus: UnitPoint
    let size: CGSize

    var body: some View {
        let imageWidth = max(image.size.width, 1), imageHeight = max(image.size.height, 1)
        let scale = max(size.width / imageWidth, size.height / imageHeight)
        let drawn = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let x = min(0, max(size.width - drawn.width, size.width / 2 - focus.x * drawn.width))
        let y = min(0, max(size.height - drawn.height, size.height / 2 - focus.y * drawn.height))
        Image(uiImage: image)
            .resizable()
            .frame(width: drawn.width, height: drawn.height)
            .offset(x: x, y: y)
    }
}

/// A cover with no sharp photo on the device: a calm surface in the photo's own colours (four
/// colours from its small preview, mixed into the card), or a soft accent tint without them.
/// Never the blurry picture itself, never an empty grey (test case 6 of the report).
private struct CoverPlaceholder: View {
    let colors: [Color]
    var symbol: String?

    var body: some View {
        ZStack {
            Theme.card
            if colors.count == 4 {
                MeshGradient(width: 2, height: 2, points: [
                    [0, 0], [1, 0],
                    [0, 1], [1, 1],
                ], colors: colors.map { Theme.card.mix(with: $0, by: 0.55) })
            } else {
                LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if let symbol {
                // Decorative (the card says what it is); the note grey holds 3:1 and more on
                // these light washes, and its dark-mode grey on the dark ones.
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.noteText)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }
}

/// "Vorschau ausgeblendet" on a neutral ground: personal content is never shown as a cover
/// (design rule 9). The words give way to the symbol alone where the cover is too small for them.
private struct HiddenCoverPreview: View {
    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            ViewThatFits(in: .vertical) {
                VStack(spacing: 6) {
                    symbol
                    Text("Vorschau ausgeblendet")
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                symbol
            }
            .foregroundStyle(.noteText)
            .padding(Theme.Spacing.s)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var symbol: some View {
        Image(systemName: "eye.slash").font(.title2)
    }
}

/// What a `CoverPhoto` found at its size, for a card that turns smaller when no photo is sharp.
enum CoverOutcome: Equatable, Sendable {
    /// A photo that is sharp at the drawn size is shown.
    case sharp
    /// No id had a sharp photo on the device (or there was none to try): the calm placeholder.
    case noSharpPhoto
}

/// Loads covers for `CoverPhoto`: the first of the candidates that is sharp at the drawn size.
@MainActor
enum CoverLoader {
    /// How many ids a cover tries at most: each one is a request to Photos, and a suggestion whose
    /// first photos are all only in iCloud has little chance with its next ones.
    static let attempts = 4

    struct Request: Equatable, Sendable {
        var ids: [AssetID]
        /// The drawn size in pixels.
        var pixels: CGSize
    }

    struct Loaded {
        var ids: [AssetID]
        var shown: Shown

        var outcome: CoverOutcome {
            if case .photo = shown { return .sharp }
            return .noSharpPhoto
        }
    }

    enum Shown {
        /// A sharp photo and where its crop is centred.
        case photo(UIImage, focus: UnitPoint)
        /// No sharp photo: the placeholder, in the four colours of the first small preview there
        /// was (the cover's own, when it had one).
        case placeholder([Color])
    }

    static func load(_ request: Request) async -> Loaded {
        var blurry: UIImage?
        for (index, id) in request.ids.enumerated() {
            guard !Task.isCancelled else { break }
            // The first one was not sharp (or not there): the others are looked up together,
            // one wait for Photos instead of one for each.
            if index == 1, request.ids.count > 2 { await ThumbnailCache.shared.lookUp(Array(request.ids.dropFirst())) }
            guard let cover = await ThumbnailCache.shared.cover(for: id, pixels: request.pixels) else { continue }
            if Task.isCancelled { return Loaded(ids: request.ids, shown: .placeholder([])) }
            if ThumbnailRequest.isSharp(cover.image, for: request.pixels) {
                CoverStats.note(index == 0 ? .sharp : .sharpLater, for: request)
                let crop = Self.focus(imageSize: cover.image.size, screenshot: cover.screenshot, target: request.pixels)
                return Loaded(ids: request.ids, shown: .photo(cover.image, focus: crop))
            }
            if blurry == nil { blurry = cover.image }
        }
        guard !Task.isCancelled else { return Loaded(ids: request.ids, shown: .placeholder([])) }
        CoverStats.note(blurry == nil ? .nothing : .onlyBlurry, for: request)
        var colors: [Color] = []
        if let blurry { colors = await palette(of: blurry) }
        return Loaded(ids: request.ids, shown: .placeholder(colors))
    }

    /// Where the crop of a cover is centred, as a share of the image ("Bildausschnitt"; faces and
    /// the subject must not be cut):
    /// - a screenshot keeps its top, where its title is (as `ThumbnailGrid` shows them);
    /// - a photo in portrait format cut at top and bottom keeps its upper part: the crop is
    ///   centred a third down, as far as the image reaches, where faces and heads are in most
    ///   portraits (a portrait in a wide card loses its legs and the ground, not the heads);
    /// - a photo in landscape format cut at top and bottom loses a little more at the bottom than
    ///   at the top (centred 40 % down): heads of people and the tops of buildings and mountains
    ///   stay, the foreground gives way (a 4:3 photo in a 2:1 card keeps 7 % to 73 % of its height);
    /// - cut at the sides (a landscape photo in a square tile): around its middle.
    /// Cheap on purpose: no image analysis per cover (the analysis runs Vision on the same chips
    /// at the same time), only the formats of the image and the cover.
    nonisolated static func focus(imageSize: CGSize, screenshot: Bool, target: CGSize) -> UnitPoint {
        if screenshot { return UnitPoint(x: 0.5, y: 0) }
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return .center }
        let cutAtTopAndBottom = imageSize.width / imageSize.height < target.width / target.height
        guard cutAtTopAndBottom else { return .center }
        return UnitPoint(x: 0.5, y: imageSize.height > imageSize.width ? 1.0 / 3.0 : 0.4)
    }

    /// Four calm colours of a preview, worked out off the main thread (`PhotoPalette.sample`).
    private static func palette(of image: UIImage) async -> [Color] {
        let preview = Preview(image: image)
        return await Task.detached(priority: .utility) { () -> [Color] in
            guard let cgImage = preview.image.cgImage else { return [] }
            return PhotoPalette.sample(cgImage)
        }.value
    }

    /// A preview handed to the task that samples it; it is only read there.
    private struct Preview: @unchecked Sendable { let image: UIImage }
}

/// How the covers of this launch came out, for the diagnostic report (design report, wave 1:
/// "Zähler für unscharfe Titelbilder"): how many found a sharp photo on the device at once, how
/// many only after a blurry one, and how many found none (only a small blurry preview, or
/// nothing at all) and showed the calm placeholder. Each cover counts once per size it is drawn
/// at (its first id and width), however often it is scrolled into view. Thread-safe and cheap: a
/// lock around a few counts.
enum CoverStats {
    enum Outcome: Sendable {
        /// The first candidate was sharp.
        case sharp
        /// A later candidate was sharp after an earlier one was only blurry or missing.
        case sharpLater
        /// No candidate was sharp; at least one had a small blurry preview on the device.
        case onlyBlurry
        /// No candidate had anything on the device (or Photos did not know them).
        case nothing
    }

    private struct Counts: Sendable {
        var outcomes: [Outcome: Int] = [:]
        var seen: Set<String> = []
    }

    private static let counts = LockedBox(Counts())
    /// Covers remembered so they count once; beyond this many each new one still counts.
    private static let seenLimit = 5000

    static func note(_ outcome: Outcome, for request: CoverLoader.Request) {
        let key = "\(request.ids.first?.rawValue ?? "")#\(Int(request.pixels.width))"
        counts.update { counts in
            if counts.seen.contains(key) { return }
            if counts.seen.count < seenLimit { counts.seen.insert(key) }
            counts.outcomes[outcome, default: 0] += 1
        }
    }

    /// The lines for the diagnostic report (`AppModel.diagnosticReport`: `lines += CoverStats.reportLines()`).
    /// Counts only, no photo ids.
    static func reportLines() -> [String] {
        let outcomes = counts.value.outcomes
        let sharp = outcomes[.sharp] ?? 0, later = outcomes[.sharpLater] ?? 0
        let blurry = outcomes[.onlyBlurry] ?? 0, nothing = outcomes[.nothing] ?? 0
        let total = sharp + later + blurry + nothing
        guard total > 0 else { return ["covers none shown yet"] }
        return ["covers \(total): sharp \(sharp), sharp after another \(later), no sharp photo on the device \(blurry + nothing) (only a blurry preview \(blurry), nothing \(nothing))"]
    }
}
