import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The photo view's calm waits, search's calm tiles and the new words (SwiftLint's file length).
extension VideoViewerSourceTests {
    // MARK: The photo view waits calmly

    /// While a photo comes the photo view shows the thumbnail the grid showed, from memory, as
    /// Photos does (black without one), and VoiceOver hears "Foto wird geladen"; no spinner. The
    /// large picture shows only when the core calls it sharp; otherwise the calm note says why,
    /// never a big blurry picture (design rule 6).
    @Test func thePhotoViewWaitsWithTheGridsThumbnail() throws {
        let viewer = try Self.viewer(keepStrings: true)
        // The page of one photo: `ZoomablePhoto` and its extensions (its loading is in a file of its own).
        let photo = AppSource.code(try PhotoViewerSource.readZoomable(), keepStrings: true)
        let waiting = try #require(AppSource.body(of: "private func waiting(in size: CGSize)", in: photo))
        #expect(waiting.contains("ThumbnailCache.shared.thumbnailInMemory(for: id)"))
        #expect(waiting.contains(".scaledToFit()"), "the preview not fitted as the photo will be")
        // It follows the finger as the photo does: a pull down to close, a pinch.
        #expect(waiting.contains(".scaleEffect(scale * (1 - min(pull / 2000, 0.15)))")
                && waiting.contains(".offset(x: offset.width, y: offset.height + pull)"), "the preview stands still under a pull")
        #expect(waiting.contains("Text(\"Foto wird geladen\")") && waiting.contains("Text(\"Video wird geladen\")"))
        let shown = try #require(AppSource.body(of: "private func shown(in size: CGSize)", in: photo))
        #expect(shown.contains("case .waiting: waiting(in: size)"), "\(shown)")
        let load = try #require(AppSource.body(of: "func load(in size: CGSize)", in: photo))
        #expect(Self.inOrder(["await PhotoBasics.of(id)", "ThumbnailCache.shared.largeImage(for: id, pixels: pixels)",
                              "guard !Task.isCancelled", "ViewerPicture.choose(", "case .sharp:", "image = loaded",
                              "onPicture(id, true)", "case .unavailable:", "becameUnavailable()"], in: load), "\(load)")
        // The rule judges what Photos delivered; the page waits by itself until then (review F,
        // F19: the rule's own "waiting" was never asked for).
        #expect(Self.squeezed(load).contains("ViewerPicture.choose(delivered:loaded.map(Self.pixelSize(of:)),original:basics?.pixels,screen:screen)"),
                "\(load)")
        #expect(!load.contains(".waiting"))
        #expect(try #require(AppSource.body(of: "func giveUp(", in: photo)).contains("becameUnavailable()"))
        #expect(try #require(AppSource.body(of: "private func becameUnavailable(", in: photo)).contains("onPicture(id, false)"))
        // The photo view leaves out a video's note only under a page that says it is not
        // available now: a page that came sharp later (swiped away and back) has it again.
        let came = try #require(AppSource.body(of: "private func pictureCame(", in: viewer))
        #expect(Self.inOrder(["if sharp", "unavailablePictures.remove(id)", "unavailablePictures.insert(id)"], in: came))
        #expect(try #require(AppSource.body(of: "private func page(at index: Int)", in: viewer))
            .contains("onPicture: { pictureCame($0, sharp: $1) }"))
        let basics = try Self.file("PhotoBasics.swift")
        #expect(basics.contains("PixelSize(width: Double(asset.value.pixelWidth), height: Double(asset.value.pixelHeight))"))
        #expect(basics.contains("asset.value.mediaType == .video"))
        #expect(basics.contains("VideoDuration(seconds: asset.value.duration)"))
        // The thumbnail in memory: the side the grid kept it at, from memory only.
        let thumbnails = try Self.thumbnails()
        let inMemory = try #require(AppSource.body(of: "func thumbnailInMemory(for id: AssetID) -> UIImage?", in: thumbnails))
        #expect(inMemory.contains("keptSides[id.rawValue]"))
        #expect(!inMemory.contains("await"))
        let keep = try #require(AppSource.body(of: "private func keep(", in: thumbnails))
        #expect(keep.contains("keptSides[id.rawValue] = side"))
        // The core's measure of sharp is the grids' and the covers'.
        #expect(thumbnails.contains("static let sharpShare: CGFloat = \(ViewerPicture.sharpShare)"))
    }

    /// A video's page never says "Dieses Video ist gerade nicht verfügbar" while its video may
    /// still come (review V1): what a page shows is the core's rule (`ViewerPage`), told where the
    /// page's own video is. That is `.unknown` while it is not the video on screen (not asked for
    /// yet, or swiped away): after a swipe away and back the page waits again until Photos answers.
    @Test func aVideosPageWaitsWhileItsVideoMayStillCome() throws {
        let viewer = try Self.viewer()
        let zoomable = try #require(AppSource.body(of: "struct ZoomablePhoto", in: viewer))
        let shown = try #require(AppSource.body(of: "private func shown(in size: CGSize)", in: zoomable))
        #expect(Self.inOrder(["switch page {", "case .picture: photo(image, in: size)", "case .unavailable: unavailableNote(in: size)",
                              "case .waiting: waiting(in: size)"], in: shown), "\(shown)")
        let page = try #require(AppSource.body(of: "private var page: ViewerPage", in: zoomable))
        #expect(Self.squeezed(page).contains("ViewerPage.shows(still:picture,playing:player!=nil,kind:kind)"), "\(page)")
        let picture = try #require(AppSource.body(of: "private var picture: ViewerPicture?", in: zoomable))
        #expect(Self.inOrder(["if image != nil { return .sharp }", "return unavailable ? .unavailable : nil"], in: picture), "\(picture)")
        let worded = try Self.viewer(keepStrings: true)
        let note = try #require(AppSource.body(of: ["struct ZoomablePhoto", "private func unavailableNote(in size: CGSize)"], in: worded))
        #expect(Self.inOrder(["ContentUnavailableView {", "if isVideo {", "Dieses Video ist gerade nicht verfügbar.", "} else {",
                              "Dieses Foto ist gerade nicht verfügbar.", ".accessibilityIdentifier(\"viewer.unavailable\")"], in: note), "\(note)")
        let built = try #require(AppSource.body(of: "private func page(at index: Int)", in: viewer))
        #expect(built.contains("kind: kind(of: id)"), "\(built)")
        let kind = try #require(AppSource.body(of: "private func kind(of id: AssetID) -> PageKind", in: viewer))
        #expect(Self.squeezed(kind).contains("video:video.availability(for:id)"), "\(kind)")
        let model = try Self.file("ViewerVideo.swift")
        let availability = try #require(AppSource.body(of: "func availability(for id: AssetID) -> VideoAvailability", in: model))
        #expect(Self.squeezed(availability) == "{self.id==id?availability:.unknown}", "\(availability)")
    }

    /// A page whose kind the photo view does not know yet (no facts, Photos not asked: a new
    /// video beside the page on screen) waits calmly instead of saying "Dieses Foto ist gerade
    /// nicht verfügbar" (review X6, the core's `PageKind`). The page on screen reads its kind
    /// (`lookAtCurrent`): answered or not, it counts as asked then, so the page on screen never
    /// waits for good. A look that a swipe on cancelled marks nothing and opens no video (it would
    /// stop the next page's).
    @Test func aPageWaitsUntilItsKindIsKnown() throws {
        let viewer = try Self.viewer()
        let kind = try #require(AppSource.body(of: "private func kind(of id: AssetID) -> PageKind", in: viewer))
        #expect(Self.squeezed(kind).contains("PageKind(isVideo:knownVideo(id),asked:kindsAsked.contains(id),video:video.availability(for:id))"),
                "\(kind)")
        let known = try #require(AppSource.body(of: "private func knownVideo(_ id: AssetID) -> Bool?", in: viewer))
        #expect(Self.inOrder(["if let known = basics[id] { return known.isVideo }",
                              "return model.factsByID[id].map { $0.asset.kind == .video }"], in: known), "\(known)")
        let isVideo = try #require(AppSource.body(of: "private func isVideo(_ id: AssetID) -> Bool", in: viewer))
        #expect(Self.squeezed(isVideo) == "{knownVideo(id)??false}", "\(isVideo)")
        let look = try #require(AppSource.body(of: "private func lookAtCurrent(", in: viewer))
        #expect(Self.inOrder(["await PhotoBasics.of(id)", "guard !Task.isCancelled else { return }", "kindsAsked.insert(id)",
                              "await playVideo(id)", "await checkSharing(id)"], in: look), "\(look)")
        let zoomable = try #require(AppSource.body(of: "struct ZoomablePhoto", in: viewer))
        let isVideoPage = try #require(AppSource.body(of: "private var isVideo: Bool", in: zoomable))
        #expect(Self.squeezed(isVideoPage) == "{kind.isVideo}", "\(isVideoPage)")
    }

    // MARK: Search

    /// Search waits on calm tiles where its hits will be, not on spinners: the first answer and
    /// the next page of hits, each said once to VoiceOver.
    @Test func searchWaitsOnCalmTiles() throws {
        let search = try Self.code("App/Albumist/Views/SearchView.swift", keepStrings: true)
        #expect(!search.contains("ProgressView("))
        #expect(Self.count(#"Text\("Suche läuft"\)"#, in: search) == 1)
        #expect(Self.count(#"Text\("Weitere Treffer werden geladen"\)"#, in: search) == 1)
        #expect(search.contains("\"search.loadingMore\""))
        let tiles = try #require(AppSource.body(of: "private func waitingTiles(", in: search))
        #expect(tiles.contains("ThumbnailGround()"))
        #expect(tiles.contains(".accessibilityElement(children: .ignore)"))
    }

    // MARK: Words

    /// The new words are in the catalog with their English.
    @Test func theNewWordsAreTranslated() throws {
        let catalog = try StringCatalogTests.catalog()
        let english = [
            "Abspielen": "Play",
            "Anhalten": "Pause",
            "Ton an": "Unmute",
            "Ton aus": "Mute",
            "Wiedergabeposition": "Playback position",
            "Video wird geladen": "Loading video",
            "Dieses Video ist gerade nicht verfügbar.": "This Video Isn\u{2019}t Available Right Now",
            "Das Video liegt nur in iCloud. Abspielen kannst du es in der Fotos-App.":
                "The video is only in iCloud. You can play it in the Photos app.",
            "Dieses Video lässt sich gerade nicht abspielen.": "This video can\u{2019}t be played right now.",
        ]
        for (german, wanted) in english {
            let entry = try #require(catalog[german], "\(german) is not in the catalog")
            let value = (StringCatalogTests.localization(entry, "en")?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(value == wanted, "\(german): \(value ?? "no English")")
        }
    }
}
