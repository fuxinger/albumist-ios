import SwiftUI
import UIKit
import AlbumistCore

/// Fills the width at `aspectRatio`, loads only what is on the device, tries `ids` in order and shows the first
/// one that is sharp enough for its size; if none is: a calm tinted placeholder, never a big blurry image.
///
/// - Only from the device (`ThumbnailCache`, `isNetworkAccessAllowed = false`: the owner's
///   promise). With "iPhone-Speicher optimieren" Photos often keeps only a small preview of an
///   older photo; stretched over a card it would be a big blurry picture (design rule 7).
/// - Sharp enough: the image brings at least 70 % of the pixels it fills, per side, at the size
///   the cover is drawn (`ThumbnailRequest.isSharp`). Only sharp covers are kept, in a store of
///   their own apart from the grids' thumbnails (`ThumbnailCache.keepCover`).
/// - At most `CoverLoader.attempts` ids are tried, one after the other, each asked for at the
///   drawn size; Photos is asked off the main thread (`ThumbnailRequest`), the asset lookups go
///   through the cache's batched lookup, and leaving the screen cancels what is still asked.
/// - Photos does not answer (busy, as right after "Anlegen"): nothing is known, so nothing is
///   told or counted; the cover asks again after a second or two, a few times
///   (`CoverLoader.retryDelays`), and once more whenever it is shown again.
/// - None sharp: a calm surface in the colours of the first small preview there was (four
///   colours, never the picture), or a soft accent tint when there was none; the same tint while
///   a photo loads, never an empty grey. Counted for the diagnostic report (`CoverStats`).
/// - `hidesPreview`: "Vorschau ausgeblendet" on a neutral ground, nothing is loaded.
/// - `placeholderSymbol`: an SF Symbol on the calm placeholder once it is clear there is no
///   sharp photo (a suggestion of screenshots or documents has no cover candidates at all,
///   `PreviewPicker.coverCandidates`), so the card looks meant that way, not empty.
/// - `onOutcome`: told once per `ids` whether the cover found a sharp photo, for a card that
///   turns smaller when there is none ("ein anderes Foto oder die kleine Karte"). Only the first
///   answer counts (`CoverOutcomeLatch`): the smaller card draws its cover at another size,
///   where the same photo may count as sharp, and it is not told again then, nor when it comes
///   back into view; a cover made anew (a lazy row scrolled far away and back) tells it again,
///   so the card keeps its decision in its own state. Not told while the preview is hidden or
///   while Photos does not answer.
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
    @State private var latch = CoverOutcomeLatch()

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
        Self.candidates(ids)
    }

    /// The ids a cover for `ids` tries, in order: the first `CoverLoader.attempts` real ones. The
    /// page's colour reads the same (`CoverTintReader`).
    static func candidates(_ ids: [AssetID]) -> [AssetID] {
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
                    if !hidesPreview && candidates.isEmpty { tell(.noSharpPhoto, for: []) }
                    return
                }
                let started = ContinuousClock.now
                var waits = CoverLoader.retryDelays[...]
                while true {
                    let result = await CoverLoader.load(request)
                    guard !Task.isCancelled else { return }
                    show(result, since: started)
                    if let counted = result.counted, let outcome = result.outcome {
                        CoverStats.note(counted, for: request)
                        tell(outcome, for: request.ids)
                        return
                    }
                    // Photos did not answer: asked again a little later, a few times.
                    guard let wait = waits.popFirst() else { return }
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                }
            }
            .accessibilityHidden(true)
    }

    /// How a cover that took a moment comes in: a short cross-fade, calm with Reduce Motion too
    /// (nothing moves). A suggestion's page brings its colour in with it (`CoverTintReader`).
    static let fade = Animation.easeOut(duration: 0.2)

    /// A cover from the cache is there at once; one that took a moment fades in (`fade`).
    private func show(_ result: CoverLoader.Loaded, since started: ContinuousClock.Instant) {
        if ContinuousClock.now - started > .milliseconds(60) {
            withAnimation(Self.fade) { loaded = result }
        } else {
            loaded = result
        }
    }

    /// Tells the card, once per ids (`CoverOutcomeLatch`).
    private func tell(_ outcome: CoverOutcome, for ids: [AssetID]) {
        guard let told = latch.take(outcome, for: ids) else { return }
        onOutcome?(told)
    }

    /// The loaded result, when it belongs to these ids (a reused view that got another
    /// suggestion's ids does not show the old photo while the new one loads).
    private var current: CoverLoader.Loaded? {
        guard let loaded, loaded.ids == candidates else { return nil }
        return loaded
    }

    @ViewBuilder private var content: some View {
        if hidesPreview {
            HiddenCoverPreview()
        } else if let current, case .photo(let image, let focus) = current.shown {
            GeometryReader { proxy in
                CroppedCover(image: image, focus: focus, size: proxy.size)
            }
            .transition(.opacity)
        } else if let current, case .placeholder(let colors) = current.shown {
            // The symbol only once it is clear that no photo comes (not while Photos is silent).
            CoverPlaceholder(colors: colors, symbol: current.outcome == nil ? nil : placeholderSymbol)
        } else {
            // Loading, or nothing to load: the same calm surface, the symbol only once it is
            // clear that no photo comes (no flash of it while a photo loads).
            CoverPlaceholder(colors: [], symbol: candidates.isEmpty ? placeholderSymbol : nil)
        }
    }
}

/// Tells a card its cover's outcome once per ids (`CoverPhoto`'s `onOutcome`): a card that turns
/// smaller when no photo is sharp would otherwise be told again at its new size, perhaps the
/// other way round, and back and forth.
struct CoverOutcomeLatch {
    private var told: [AssetID]?

    /// `outcome` when nothing was told for `ids` yet, otherwise nil.
    mutating func take(_ outcome: CoverOutcome, for ids: [AssetID]) -> CoverOutcome? {
        guard told != ids else { return nil }
        told = ids
        return outcome
    }
}

/// The image filling `size`, cropped around `focus` (a share of the image) as far as the
/// image reaches: the focus sits in the middle of the cover unless that would leave an edge
/// of the cover empty (`CoverLoader.placement`).
private struct CroppedCover: View {
    let image: UIImage
    let focus: UnitPoint
    let size: CGSize

    var body: some View {
        let drawn = CoverLoader.placement(imageSize: image.size, focus: focus, filling: size)
        Image(uiImage: image)
            .resizable()
            .frame(width: drawn.width, height: drawn.height)
            .offset(x: drawn.minX, y: drawn.minY)
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
                // Decorative (the card says what it is), on a disc in the card's colour: a
                // photo's colours can make the wash as light or as dark as the grey itself
                // (down to 1.4:1), the disc keeps it at the note grey's 5.9:1 light, 7.5:1 dark
                // and 6.1:1 in a sheet.
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.noteText)
                    .padding(Theme.Spacing.m)
                    .background(Theme.card, in: Circle())
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
