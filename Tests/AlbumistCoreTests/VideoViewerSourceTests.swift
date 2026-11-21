import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The app's wiring of videos (design wave 3, DS-16) and of the calm placeholders while pictures
/// load (DS-18), read from the source (the app does not build on Linux): videos play in the
/// photo view as in Photos, only from the iPhone, with their sound only when the user asks; their
/// thumbnails say how long they are without a fetch of their own; the photo view shows the grid's
/// thumbnail while a photo comes and never a big blurry one; the grids wait on a soft ground
/// and the photos fade in. The rules themselves are tested in the core (`VideoPlaybackTests`,
/// `LoadingPlaceholderTests`).
@Suite("Videos and calm placeholders source (DS-16, DS-18)")
struct VideoViewerSourceTests {
    static let viewerPath = "App/Albumist/Views/PhotoViewer.swift"
    static let folder = "App/Albumist/Views/PhotoViewer"
    static let thumbnailsPath = "App/Albumist/Views/AssetThumbnail.swift"

    static func code(_ path: String, keepStrings: Bool = false) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: keepStrings)
    }

    static func file(_ name: String, keepStrings: Bool = false) throws -> String {
        try code("\(folder)/\(name)", keepStrings: keepStrings)
    }

    static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    static func count(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    /// `parts` in this order in `text`.
    static func inOrder(_ parts: [String], in text: String) -> Bool {
        var from = text.startIndex
        for part in parts {
            guard let found = text.range(of: part, range: from..<text.endIndex) else { return false }
            from = found.upperBound
        }
        return true
    }

    // MARK: Thumbnails

    /// A thumbnail waits on a soft tinted ground (the covers' family, `ThumbnailGroundTint`),
    /// never the flat grey of before; its photo fades in only after a wait (`ThumbnailAppearance`)
    /// and is there at once from memory, so a rebuilt cell never flickers. Hidden previews keep
    /// their neutral ground (design rule 9).
    @Test func thumbnailsWaitOnACalmGround() throws {
        let thumbnails = try Self.code(Self.thumbnailsPath, keepStrings: true)
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains("ThumbnailGround()"))
        #expect(!shown.contains("tertiarySystemFill"))
        #expect(shown.contains(".transition(.opacity)"))
        let show = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func show("], in: thumbnails))
        #expect(show.contains("ThumbnailAppearance.fade(seeded: seeded, waited:"))
        #expect(show.contains("withAnimation(fade.map { Animation.easeOut(duration: $0) })"))
        let ground = try #require(AppSource.body(of: ["struct ThumbnailGround", "var body: some View"], in: thumbnails))
        #expect(ground.contains("ThumbnailGroundTint(dark: scheme == .dark, increasedContrast: contrast == .increased)"))
        #expect(ground.contains("Theme.card"))
        #expect(ground.contains("Theme.accent.opacity(tint.top)") && ground.contains("Theme.accent.opacity(tint.bottom)"))
        #expect(!ground.contains("tertiarySystemFill"))
        // A cover with no photo yet (an empty album) waits on the same ground; a hidden one stays neutral.
        let cover = try #require(AppSource.body(of: ["struct CoverThumbnail", "var body: some View"], in: thumbnails))
        #expect(Self.squeezed(cover).contains("ifhidden{HiddenThumbnail()}else{ThumbnailGround()"))
        let hidden = try #require(AppSource.body(of: ["struct HiddenThumbnail", "var body: some View"], in: thumbnails))
        #expect(hidden.contains("tertiarySystemFill") && hidden.contains("\"eye.slash\""))
    }

    /// A thumbnail is asked for again when its cell is drawn at another size (a grid zoomed to
    /// other columns, H10's DS-06b): the task follows the id and the side, and the image it shows
    /// meanwhile stays (no flash of the ground).
    @Test func aThumbnailIsAskedForAtTheSizeItShows() throws {
        let thumbnails = try Self.code(Self.thumbnailsPath)
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains(".task(id: Slot(id: id, side: side)) {"))
        #expect(shown.contains("let seeded = image != nil && loadedID == id"))
        let slot = try #require(AppSource.body(of: ["struct AssetThumbnail", "private struct Slot"], in: thumbnails))
        #expect(Self.squeezed(slot) == "{varid:AssetIDvarside:CGFloat}")
    }

    /// A video's thumbnail says how long it is, "0:15" on a small solid light ground in its
    /// bottom-leading corner (design rule 1; the grids' selection ring is bottom-trailing), only
    /// where it fits, and VoiceOver hears "Video, 15 Sekunden" with the photo's cell. The length
    /// comes from the asset the thumbnails' lookup fetches anyway: no fetch per cell (100,000
    /// photos in a grid). Covers and the mosaic of a card leave it out.
    @Test func aVideosLengthCostsNoFetch() throws {
        let thumbnails = try Self.code(Self.thumbnailsPath, keepStrings: true)
        #expect(Self.count(#"PHAsset\.fetchAssets\("#, in: thumbnails) == 1, "a second fetch")
        let lookUp = try #require(AppSource.body(of: "private func lookUpWaiting(", in: thumbnails))
        #expect(lookUp.contains("asset.value.mediaType == .video"))
        #expect(lookUp.contains("videoLengths[id] = asset.value.duration"))
        let length = try #require(AppSource.body(of: "func videoLength(for id: AssetID) -> VideoDuration?", in: thumbnails))
        #expect(!length.contains("await") && length.contains("videoLengths[id.rawValue]"))
        // Gone with the assets on a memory warning.
        let start = try #require(AppSource.body(of: ["final class ThumbnailCache", "init()"], in: thumbnails))
        #expect(start.contains("$0.videoLengths.removeAll()") && start.contains("$0.keptSides.removeAll()"))
        // Read with the thumbnail, from memory, in the initializer and when the photo came.
        let made = try #require(AppSource.body(of: ["struct AssetThumbnail", "init(id: AssetID, side: CGFloat = 80, anchor: Alignment = .center)"],
                                               in: thumbnails))
        #expect(Self.squeezed(made).contains("_video=State(initialValue:kept==nil?nil:ThumbnailCache.shared.videoLength(for:id))"))
        let show = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func show("], in: thumbnails))
        #expect(show.contains("video = ThumbnailCache.shared.videoLength(for: id)"))
        // The badge: solid light ground, one line, stops growing, hidden from VoiceOver itself.
        let badge = try #require(AppSource.body(of: ["struct VideoLengthBadge", "var body: some View"], in: thumbnails))
        for part in ["Text(verbatim: length.text)", ".monospacedDigit()", ".lineLimit(1)", ".background(Color.white, in: Capsule())",
                     ".environment(\\.colorScheme, .light)", ".dynamicTypeSize(...DynamicTypeSize.accessibility1)", ".accessibilityHidden(true)"] {
            #expect(badge.contains(part), "\(part) is missing")
        }
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains(".overlay(alignment: .bottomLeading) {"))
        #expect(thumbnails.contains("VideoBadge.fits(badgeWidth:"))
        // VoiceOver: the value of the cell around it; without a video nothing of the thumbnail.
        #expect(shown.contains(".accessibilityValue(spokenLength.map { Text(verbatim: $0) } ?? Text(verbatim: \"\"))"))
        #expect(shown.contains(".accessibilityHidden(spokenLength == nil)"))
        let spoken = try #require(AppSource.body(of: ["struct AssetThumbnail", "private var spokenLength"], in: thumbnails))
        #expect(spoken.contains("showsVideoLength"))
        // Covers and the mosaic leave it out.
        for owner in ["struct CoverThumbnail", "struct ThumbnailGrid"] {
            let body = try #require(AppSource.body(of: [owner, "var body: some View"], in: thumbnails))
            #expect(body.contains(".environment(\\.thumbnailShowsVideoLength, false)"), "\(owner)")
        }
    }
}
