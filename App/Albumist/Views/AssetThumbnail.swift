import SwiftUI
import UIKit
import AlbumistCore

/// A photo's square thumbnail in a grid, straight from Photos (`ThumbnailCache`).
///
/// Design wave 3 (DS-18, "ruhige Platzhalter beim Laden statt grauer Flächen"): while the photo
/// comes the tile shows a soft tinted ground (`ThumbnailGround`), no grey slab; a photo that
/// took a moment fades in, one from memory or that came at once is simply there, so a rebuilt
/// or scrolled-back cell never flickers (`ThumbnailAppearance`). A cell drawn at another size
/// (a grid zoomed to other columns) asks for its photo at that size and shows the one it has
/// meanwhile.
///
/// DS-16: a video says how long it is, "0:15" on a small solid ground in its bottom-leading
/// corner where it fits (`VideoLengthBadge`), and VoiceOver hears "Video, 15 Sekunden" with the
/// cell around it (its label stays the cell's own, the date). The length comes from the asset
/// the thumbnails' lookup fetches anyway (`ThumbnailCache.videoLength`): no fetch per cell.
/// Covers and the mosaic of a card leave it out (`thumbnailShowsVideoLength`).
struct AssetThumbnail: View {
    var id: AssetID
    var side: CGFloat
    /// Which part stays visible when the photo is cropped; screenshots keep their top.
    var anchor: Alignment
    @State private var image: UIImage?
    /// The photo `image` shows: when the same view gets another `id` (a trip's cover), the old
    /// photo is not shown while the new one loads.
    @State private var loadedID: AssetID?
    /// How long the photo `loadedID` is when it is a video.
    @State private var video: VideoDuration?
    @Environment(\.thumbnailShowsVideoLength) private var showsVideoLength

    /// What the app's words are in ("Video, 15 Sekunden"), as the photo view's title has them.
    private static let words = ProposalWords(localization: Bundle.main.preferredLocalizations.first,
                                             region: Locale.current.region?.identifier)

    /// What the task asks for: the photo at the side it is drawn at.
    private struct Slot: Equatable {
        var id: AssetID
        var side: CGFloat
    }

    /// Starts with the thumbnail the cache holds in memory, if it has one: a thumbnail made anew
    /// (a grid cell rebuilt when its photo's long press is switched on or off as "Auswählen"
    /// toggles, `photoMenu`) shows its photo from its first frame, not its ground until the
    /// task below has read the cache again (review C2 of design wave 2, N1). Only from memory:
    /// nothing is asked of Photos here, the task asks for what is not in memory, as before.
    init(id: AssetID, side: CGFloat = 80, anchor: Alignment = .center) {
        self.id = id
        self.side = side
        self.anchor = anchor
        let kept = ThumbnailCache.shared.cachedThumbnail(for: id, side: side)
        _image = State(initialValue: kept)
        _loadedID = State(initialValue: kept == nil ? nil : id)
        _video = State(initialValue: kept == nil ? nil : ThumbnailCache.shared.videoLength(for: id))
    }

    var body: some View {
        ThumbnailGround()
            .overlay(alignment: anchor) {
                if let image, loadedID == id {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsVideoLength, loadedID == id, let video {
                    BadgeCorner { VideoLengthBadge(length: video) }
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: Slot(id: id, side: side)) {
                let asked = ContinuousClock.now
                let seeded = image != nil && loadedID == id
                let loaded = await ThumbnailCache.shared.image(for: id, side: side)
                // A cell that moved on to another photo keeps the new one's image.
                guard !Task.isCancelled else { return }
                show(loaded, seeded: seeded, since: asked)
            }
            .onChange(of: ThumbnailCache.shared.lengthRevision.value) { readLengthAgain() }
            // Only a video says something, with the cell around it: its length as a value.
            .accessibilityElement(children: .ignore)
            .accessibilityValue(spokenLength.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            .accessibilityHidden(spokenLength == nil)
    }

    /// The photo, and how long it is when it is a video; it fades in when it took a moment. A
    /// request at another side (a grid zoomed) that brought nothing keeps the photo shown.
    private func show(_ loaded: UIImage?, seeded: Bool, since asked: ContinuousClock.Instant) {
        if loaded == nil, image != nil, loadedID == id { return }
        let fade = ThumbnailAppearance.fade(seeded: seeded, waited: (ContinuousClock.now - asked) / .seconds(1))
        withAnimation(fade.map { Animation.easeOut(duration: $0) }) {
            image = loaded
            loadedID = id
            video = ThumbnailCache.shared.videoLength(for: id)
        }
    }

    /// A change in Photos corrected or dropped a video's record (a video trimmed in Photos,
    /// reviews V4 and X1): the cell on screen reads it again, so its badge and VoiceOver's words
    /// follow without the cell being made anew, some seconds after the change: once it was
    /// walked, after the photo library watcher's pause (3 s, up to 20 s right after an analysis).
    /// Only a length the thumbnails know replaces what the cell shows (review X2). One it shows
    /// and they no longer know (its record went unchecked, a memory warning took it) it keeps,
    /// asks Photos again with the other cells that ask now, and then shows what Photos said
    /// (`KeptVideoLength`). A cover, which shows no length, asks nothing.
    private func readLengthAgain() {
        guard loadedID == id else { return }
        switch KeptVideoLength.reading(shown: showsVideoLength ? video : nil, known: ThumbnailCache.shared.videoLength(for: id)) {
        case .show(let known): video = known
        case .keep: break
        case .askAgain:
            let asked = id
            ThumbnailCache.shared.askLengthAgain(for: asked) { answer in
                // A cell that moved on to another photo keeps the new one's length.
                guard loadedID == asked else { return }
                video = KeptVideoLength.afterAsking(shown: video, answer: answer)
            }
        }
    }

    /// "Video, 15 Sekunden" for the cell around it; nil for a photo, while it loads, and where
    /// the length is left out.
    private var spokenLength: String? {
        guard showsVideoLength, loadedID == id, let video else { return nil }
        return video.spoken(Self.words)
    }
}

extension AssetThumbnail {
    /// What a photo's cell is called for VoiceOver outside the day grids (a search result, an
    /// album's photo): its date and time on the clock where it was taken, as the grids
    /// (`PhotoGrid`) and the photo view's title say it (decision of 19.11.2026, "Ortszeit am
    /// Aufnahmeort wie Apple Fotos"); before, these cells told the iPhone's clock. Facts without a
    /// zone of their own and a photo Albumist has no facts of yet count on the iPhone's clock
    /// (`InboxDays.clock`). "Foto" without a date.
    static func spokenDate(_ date: Date?, facts: AssetFacts?) -> String {
        guard let date else { return String(localized: "Foto") }
        let zone = InboxDays.clock(of: facts, homeZone: nil, currentZone: .current)
        return LocalTime.wallClock(date, in: zone).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .gmt))
    }
}

/// The ground of a thumbnail while its photo comes (design wave 3, DS-18): the card with a soft
/// wash of the accent, top-leading to bottom-trailing, the family of the covers' placeholder
/// (`CoverPhoto`), never the flat grey slab of before; a little stronger in dark mode and with
/// Increase Contrast (`ThumbnailGroundTint`). It does not move.
struct ThumbnailGround: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = ThumbnailGroundTint(dark: scheme == .dark, increasedContrast: contrast == .increased)
        Rectangle()
            .fill(Theme.card)
            .overlay {
                LinearGradient(colors: [Theme.accent.opacity(tint.top), Theme.accent.opacity(tint.bottom)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .accessibilityHidden(true)
    }
}

/// A video's length on its thumbnail (DS-16): "0:15" on a small solid light ground, in dark mode
/// too, so it reads the same on any photo (design rule 1: no text right on a photo), with a
/// hairline edge that keeps its shape on a white sky, a firmer one with Increase Contrast (the
/// look of `CardBadgeLabel`). Like the mosaic's "+N" it stops growing at the first accessibility
/// size and keeps to one line; where it would cover too much of the photo it gives way
/// (`BadgeCorner`). VoiceOver hears the length with the cell (`AssetThumbnail`), not here.
struct VideoLengthBadge: View {
    var length: VideoDuration
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(verbatim: length.text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.black.opacity(contrast == .increased ? 0.6 : 0.08), lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityHidden(true)
    }
}

/// Places its badge in the bottom-leading corner of the tile, a little in, where it leaves most
/// of the photo free (`VideoBadge.fits`); otherwise out of the tile, which clips it.
private struct BadgeCorner: Layout {
    private static let inset: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let fits = VideoBadge.fits(badgeWidth: Double(size.width + Self.inset), tileWidth: Double(bounds.width))
                && size.height + Self.inset * 2 <= bounds.height
            let corner = CGPoint(x: bounds.minX + Self.inset, y: fits ? bounds.maxY - Self.inset : bounds.maxY + size.height + Self.inset)
            subview.place(at: corner, anchor: .bottomLeading, proposal: ProposedViewSize(size))
        }
    }
}

private struct ThumbnailShowsVideoLengthKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a thumbnail says a video's length (DS-16): on in the grids, off for covers and
    /// the mosaic of a card, where a photo stands for an album or a suggestion.
    var thumbnailShowsVideoLength: Bool {
        get { self[ThumbnailShowsVideoLengthKey.self] }
        set { self[ThumbnailShowsVideoLengthKey.self] = newValue }
    }
}

/// A cover: the photo, or, when there is none to show because every photo is a sensitive
/// document (`PreviewRank`), a quiet tile with the symbol Photos uses for hidden photos.
/// `hidden: false` for a cover that is missing for another reason (an empty album): the calm
/// ground of a thumbnail (DS-18). A cover says no video length: it stands for its album.
struct CoverThumbnail: View {
    var id: AssetID?
    var side: CGFloat = 80
    var hidden = true

    var body: some View {
        if let id {
            AssetThumbnail(id: id, side: side)
                .environment(\.thumbnailShowsVideoLength, false)
        } else if hidden {
            HiddenThumbnail()
        } else {
            ThumbnailGround()
        }
    }
}

/// The tile of a cover whose every photo is a sensitive document: a neutral ground (design rule
/// 9) with the symbol Photos uses for hidden photos.
private struct HiddenThumbnail: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                Image(systemName: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary) // secondary-text: system (a symbol on a placeholder tile, not text: 3:1 is enough)
            }
            .accessibilityHidden(true)
    }
}

/// Grid of thumbnails with a "+N" tile. Few photos get larger tiles; screenshots and
/// documents are shown upright from the top, where their title is. Sensitive documents are
/// never among `ids` (`PreviewPicker`): with too few other photos the grid has fewer tiles,
/// and with none a single tile says the preview is hidden. "+N" counts from `total`.
struct ThumbnailGrid: View {
    var ids: [AssetID]
    /// All photos behind the preview, when `ids` is only a selection of them.
    var total: Int? = nil
    var columns = 4
    var limit = 12
    var portrait = false

    var body: some View {
        let all = total ?? ids.count
        let shown = Array(ids.prefix(limit))
        let count = min(columns, max(shown.count, 2))
        if shown.isEmpty && all > 0 {
            hiddenPreview
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: count), spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                    AssetThumbnail(id: id, side: count <= 2 ? 200 : (count == 3 ? 140 : 100), anchor: portrait ? .top : .center)
                        .aspectRatio(portrait ? 0.75 : 1, contentMode: .fill)
                        .overlay {
                            if index == shown.count - 1, let more = PreviewPicker.moreCount(total: all, shown: shown.count) {
                                Color.black.opacity(0.45)
                                // Shown in full at every size (review P3-18: "+…" instead of
                                // "+24" at the largest text, in a quarter of the small iPhone's
                                // width). Like a badge on a photo it stops growing at the first
                                // accessibility size, keeps to one line and shrinks a little
                                // rather than end in "…". VoiceOver reads the full count in the
                                // label of the button around the mosaic ("Alle 31 Fotos ansehen").
                                Text("+\(more)").font(.headline).foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .padding(.horizontal, Theme.Spacing.xs)
                                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                                    .accessibilityIdentifier("thumbnails.more")
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            // A preview of a suggestion or album: no video lengths on it (DS-16).
            .environment(\.thumbnailShowsVideoLength, false)
        }
    }

    /// Every photo is a sensitive document: no picture of one, but a tile that still leads to
    /// all photos (the grid is the button that opens them).
    private var hiddenPreview: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "eye.slash").font(.title2)
                .accessibilityHidden(true)
            Text("Vorschau ausgeblendet").font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.noteText)
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.Spacing.m)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
