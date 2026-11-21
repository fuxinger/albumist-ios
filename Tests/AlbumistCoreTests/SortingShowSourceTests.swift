import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// DS-17 (design wave 3) as the App draws the sorting show: bigger photos from the layout, the
/// album as its real cover, the count in Apple's wide figures, only sharp photos from the
/// device, the albums' photos and covers by the same care as the result's stack, and a calm
/// version in Low Power Mode. The sizes and the photos are core rules (`SortingShowStageTests`);
/// the App does not build on Linux, so these tests read its code (`AppSource`). What it keeps
/// from before (the skip, its end into the result, the scene's scale, VoiceOver and Reduce Motion)
/// is guarded in `LargestTextFitTests` and `MomentsSourceTests`.
@Suite("Sorting show in the App (DS-17)")
struct SortingShowSourceTests {
    static let show = "App/Albumist/Views/SortingShow.swift"
    static let pieces = "App/Albumist/Views/Show/SortingShowPieces.swift"
    static let review = "App/Albumist/Views/PlanReviewView.swift"
    static let model = "App/Albumist/Model/AppModel+SortingShow.swift"
    static let theme = "App/Albumist/DesignSystem/Theme.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try #require(AppSource.body(of: path, in: file), "\(path) is not there")
    }

    static func count(_ text: String, in code: String) -> Int {
        code.components(separatedBy: text).count - 1
    }

    /// The sizes come from the layout for the width on screen; no fixed 76 pt photo, 124 pt album
    /// or 360 pt scene is left.
    @Test func theSceneTakesItsSizesFromTheLayout() throws {
        let show = try Self.code(Self.show)
        let stage = try Self.body(["struct SortingShow", "var stage: SortingShowLayout"], in: show)
        #expect(stage.contains("SortingShowLayout(width: Double(available), largeText: typeSize >= .xxLarge)"), "\(stage)")
        let height = try Self.body(["struct SortingShow", "var sceneHeight: CGFloat"], in: show)
        #expect(height.contains("stage.height"), "\(height)")
        for literal in [/side:\s*76\b/, /sceneHeight:\s*CGFloat\s*=\s*360\b/, /:\s*CGFloat\s*=\s*124\b/, /y:\s*78\b/, /y:\s*252\b/] {
            #expect(!show.contains(literal), "a fixed size of the old show is left")
        }
        let pieces = try Self.code(Self.pieces)
        #expect(!pieces.contains(/=\s*124\b/) && !pieces.contains(/side:\s*76\b/), "a fixed size of the old show is left")
        // The cover's centre is where the layout says; the name hangs below it.
        let carousel = try Self.body(["struct SortingShow", "var carousel: some View"], in: show)
        #expect(carousel.contains(".position(x: coverCenter.x + offset * spacing, y: coverCenter.y)"), "\(carousel)")
        #expect(carousel.contains("SortingShowLayout.neighbourScale"), "\(carousel)")
        #expect(show.contains("CGPoint(x: width / 2, y: CGFloat(stage.coverCenterY))"))
        #expect(show.contains("CGPoint(x: width / 2, y: CGFloat(stage.pileCenterY))"))
    }

    /// The album is its real cover (`CoverPhoto`: sharp from the device or its calm placeholder,
    /// "Vorschau ausgeblendet" for a personal album), grey while it waits and in its colours once
    /// filled; the check stands on a solid ring, never straight on the photo.
    @Test func theAlbumIsItsRealCover() throws {
        let pieces = try Self.code(Self.pieces)
        let album = try Self.body(["struct ShowAlbumCover", "var body: some View"], in: pieces)
        #expect(album.contains("CoverPhoto(ids: album.cover, aspectRatio: 1,"), "\(album)")
        #expect(album.contains("hidesPreview: album.hidesPreview"), "\(album)")
        #expect(album.contains(".saturation(filled ? 1 : 0)"), "\(album)")
        let check = try Self.body(["struct ShowAlbumCover", "var check: some View"], in: pieces)
        #expect(check.contains(".background(Circle().fill(Theme.card)"), "\(check)")
        // No glow and no gradient in the show.
        for file in [pieces, try Self.code(Self.show)] {
            #expect(!file.contains("Gradient("), "a gradient in the show")
            #expect(!file.contains(".blur("), "a glow in the show")
        }
    }

    /// The count in Apple's wide figures and the accent, as the result's count that follows the
    /// show; no rounded font of its own any more.
    @Test func theCountIsInTheWideFigures() throws {
        let show = try Self.code(Self.show)
        let header = try Self.body(["struct SortingShow", "var header: some View"], in: show)
        #expect(header.contains(".font(.wideNumber(size: 56))"), "\(header)")
        #expect(header.contains(".foregroundStyle(Theme.accent)"), "\(header)")
        #expect(!show.contains("design: .rounded"), "the rounded figures are back")
        let theme = try Self.code(Self.theme)
        let wide = try #require(AppSource.body(of: "static func wideNumber(size: CGFloat", in: theme), "no fixed-size wide figures")
        #expect(wide.contains(".width(.expanded).monospacedDigit()"), "\(wide)")
        // What VoiceOver says and the identifiers the UI tests use stay as they were.
        #expect(header.contains(".accessibilityLabel(Text(\"Fotos werden einsortiert\"))"), "\(header)")
        #expect(header.contains(".accessibilityAddTraits(.updatesFrequently)"), "\(header)")
        #expect(show.contains(".accessibilityIdentifier(\"show.skip\")"))
    }

    /// Only photos that are sharp on the device at the size they are drawn lie on the pile and
    /// fly: asked of Photos without iCloud (`ThumbnailCache`), kept only when sharp
    /// (`ThumbnailRequest.isSharp`), drawn only from that store.
    @Test func onlySharpPhotosFromTheDeviceFly() throws {
        let pieces = try Self.code(Self.pieces)
        let load = try Self.body(["final class ShowPhotos", "func load("], in: pieces)
        #expect(load.contains("ThumbnailCache.shared.image(for: id, side: side)"), "\(load)")
        #expect(load.contains("ThumbnailRequest.isSharp(loaded, for: pixels)"), "\(load)")
        let image = try Self.body(["final class ShowPhotos", "func image("], in: pieces)
        #expect(image.contains("ThumbnailRequest.isSharp(image, for: pixels)"), "\(image)")
        #expect(!pieces.contains("isNetworkAccessAllowed"), "the show asks Photos itself")
        let show = try Self.code(Self.show)
        // No thumbnail that may show a blurry preview: every photo comes from the sharp store.
        #expect(!show.contains("AssetThumbnail(") && !pieces.contains("AssetThumbnail("), "a photo that may be blurry")
        let pile = try Self.body(["struct SortingShow", "var pile: some View"], in: show)
        #expect(pile.contains("photos.image($0, sharpAt: pixels) != nil"), "\(pile)")
        let launch = try Self.body(["struct SortingShow", "func launch("], in: show)
        #expect(launch.contains("photos.image(id, sharpAt: pixels)"), "\(launch)")
        #expect(launch.contains("if flies {"), "\(launch)")
    }

    /// Low Power Mode: the calm version. Nothing flies (`flies`), the albums still fill one after
    /// the other with their tap; with Reduce Motion or VoiceOver the albums are riffled through
    /// quietly, as before. The haptic stays the one soft tap at a landing, no more.
    @Test func lowPowerModeIsTheCalmVersion() throws {
        let show = try Self.code(Self.show)
        #expect(show.contains("@State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled"))
        let flies = try Self.body(["struct SortingShow", "var flies: Bool"], in: show)
        #expect(flies.contains("!reduceMotion && !voiceOver && !lowPower"), "\(flies)")
        #expect(Self.count(".sensoryFeedback(", in: show) == 1, "the show has another haptic")
        #expect(show.contains(".sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: landings)"))
        #expect(!(try Self.code(Self.pieces)).contains("sensoryFeedback"), "a piece of the show has a haptic")
        let land = try Self.body(["struct SortingShow", "func land("], in: show)
        #expect(land.contains("if quietly { return }"), "\(land)")
        #expect(land.contains("if index < 3 || index == albums.count - 1 { landings += 1 }"), "\(land)")
        #expect(Self.count("landings += 1", in: show) == 1)
    }

    /// The screen hands the show the albums with their photos and covers taken by the model, by
    /// the same care as the result's stack (`resultCoverSources`: cards' covers, personal
    /// suggestions); the show never builds its albums from the plan's photos alone.
    @Test func theScreenTakesTheAlbumsFromTheModel() throws {
        let review = try Self.code(Self.review)
        let button = try Self.body(["struct PlanReviewView", "func applyButton("], in: review)
        #expect(button.contains("let albums = SortingShow.albums(from: model.sortingShowAlbums(facts.filledAlbums, plan: plan))"), "\(button)")
        let model = try Self.code(Self.model)
        let albums = try #require(AppSource.body(of: "func sortingShowAlbums(", in: model))
        #expect(albums.contains("resultCoverSources(for: plan)"), "\(albums)")
        #expect(albums.contains("SortingShowAlbum.cast(filled, plan: plan, cardCovers: sources.covers, personal: sources.personal,"), "\(albums)")
        #expect(albums.contains("ranks: previewRanks"), "\(albums)")
        let show = try Self.code(Self.show)
        #expect(!show.contains("filledAlbums"), "the show builds its albums from the plan's photos")
        let builder = try Self.body(["struct SortingShow", "static func albums(from cast: [SortingShowAlbum])"], in: show)
        #expect(builder.contains("shown: $0.flying, cover: $0.cover, hidesPreview: $0.hidesPreview"), "\(builder)")
    }

    /// The covers load ahead at exactly the pixels the album's `CoverPhoto` asks for (whole points
    /// times the screen's scale, square): it finds them kept and shows them at once.
    @Test func theCoverLoadsAheadAtTheSizeItIsDrawn() throws {
        let show = try Self.code(Self.show)
        let prefetch = try Self.body(["struct SortingShow", "func prefetch("], in: show)
        #expect(prefetch.contains("let side = CGFloat(stage.cover) * displayScale"), "\(prefetch)")
        #expect(prefetch.contains("CoverLoader.Request(ids: Array(album.cover.prefix(CoverLoader.attempts))"), "\(prefetch)")
        #expect(prefetch.contains("pixels: CGSize(width: side, height: side)"), "\(prefetch)")
        #expect(prefetch.contains("guard !album.hidesPreview"), "\(prefetch)")
        // The cover is drawn exactly at the layout's whole-point side, square.
        let pieces = try Self.code(Self.pieces)
        let album = try Self.body(["struct ShowAlbumCover", "var body: some View"], in: pieces)
        #expect(album.contains(".frame(width: cover, height: cover)"), "\(album)")
        // What `CoverPhoto` asks for: the drawn width rounded up, times the screen's scale.
        let coverPhoto = try Self.code("App/Albumist/DesignSystem/CoverPhoto.swift")
        let request = try #require(AppSource.body(of: "private var request: CoverLoader.Request?", in: coverPhoto))
        #expect(request.contains("CGSize(width: width.rounded(.up), height: (width / aspectRatio).rounded(.up))"), "\(request)")
        #expect(request.contains("points.width * displayScale"), "\(request)")
    }
}
