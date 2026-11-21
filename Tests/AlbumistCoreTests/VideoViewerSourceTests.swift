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

    // MARK: Videos: only from the iPhone

    /// A video comes only from the iPhone (the owner's promise): one request for its player item,
    /// with the network off, ended by a time limit, its answer read by the core's rule; no other
    /// way to a video's data anywhere in the app, and nothing that allows the network.
    @Test func videosComeOnlyFromTheIPhone() throws {
        let loader = try Self.file("VideoLoader.swift")
        #expect(loader.contains("PHVideoRequestOptions()"))
        #expect(loader.contains("options.isNetworkAccessAllowed = false"))
        let requests = AppSource.calls(of: "requestPlayerItem(", in: loader)
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.contains("options: options") }, "the request without its options")
        #expect(loader.contains("answer.limit("), "a video Photos never answers for would wait for good")
        let request = try #require(AppSource.body(of: "private static func request(", in: loader))
        #expect(request.contains("VideoAvailability.afterRequest(gotItem: item != nil, inCloud: inCloud, errors:"))
        #expect(request.contains("PHImageResultIsInCloudKey"))
        #expect(request.contains("PhotoShare.errorChain(of:"))
        #expect(request.contains("withTaskCancellationHandler"), "a swipe on would leave the request running")
        // The asset from the thumbnails' own lookup: no second read of the Photos database.
        let load = try #require(AppSource.body(of: "static func load(", in: loader))
        #expect(load.contains("ThumbnailCache.shared.assetLookup(for: id)"))
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = try Self.code(path)
            for other in ["requestAVAsset(", "requestExportSession("] {
                #expect(AppSource.calls(of: other, in: code).isEmpty, "\(path): \(other)")
            }
            if !path.hasSuffix("/VideoLoader.swift") {
                #expect(AppSource.calls(of: "requestPlayerItem(", in: code).isEmpty, "\(path): a second way to a video")
            }
            #expect(Self.count(#"isNetworkAccessAllowed\s*=\s*true"#, in: code) == 0, "\(path) loads from iCloud")
        }
    }

    // MARK: Videos play as in Photos

    /// A video starts without sound; "Ton an" gives it sound, which stops the user's music and
    /// plays with the silent switch on, as in Photos; off, and when the photo view closes, the
    /// app's sound mixes again and the user's music may go on. The audio server is called off the
    /// main thread, one change after the other, beside H8's `LiveAudio` and never against it.
    @Test func aVideosSoundIsTheUsersChoice() throws {
        let model = try Self.file("ViewerVideo.swift")
        let toggle = try #require(AppSource.body(of: "func toggleSound(", in: model))
        #expect(Self.inOrder(["sound.toggle()", "isMuted = !sound.isOn", "LiveAudio.videoSound(sound.isOn)"], in: toggle))
        let close = try #require(AppSource.body(of: "func close(", in: model))
        #expect(Self.inOrder(["stop()", "if sound.isOn", "LiveAudio.videoSound(false)", "sound = VideoSound()"], in: close))
        let audio = try Self.file("LivePhotoPlayer.swift")
        let sound = try #require(AppSource.body(of: "static func videoSound(", in: audio))
        #expect(Self.inOrder(["isReady = false", "Task.detached(", "await previous?.value", "setCategory(.playback",
                              "setActive(true)", "setCategory(.ambient", "setActive(false, options: .notifyOthersOnDeactivation)",
                              "await LiveAudio.videoSoundSet("], in: sound), "\(sound)")
        #expect(Self.squeezed(try #require(AppSource.body(of: "private static func videoSoundSet(", in: audio))).contains("isReady=!on&&done"))
        // The photo view's own setting when it opens takes its turn too: "Ton an" right after it
        // is never undone by it.
        let prepare = try #require(AppSource.body(of: "static func prepare(", in: audio))
        #expect(Self.inOrder(["let previous = soundChange", "soundChange = Task.detached(", "await previous?.value",
                              "setCategory(.ambient", "await LiveAudio.finished(done)"], in: prepare), "\(prepare)")
        // The short motion of a Live Photo waits while the category changes (`isReady`).
        #expect(Self.count("assumeIsolated", in: audio) == 1)
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
