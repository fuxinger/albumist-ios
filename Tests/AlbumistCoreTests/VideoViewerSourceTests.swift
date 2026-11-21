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

    /// A video plays in the photo view as in Photos: it starts by itself and loops where motion
    /// is welcome (the core's `VideoStart` with Reduce Motion and "Auto-Play Video Previews"),
    /// after a moment for the swipe to rest; it stops and lets its player go when it leaves the
    /// screen (one player at most) and pauses in the background; its picture is Apple's player
    /// layer fitted as the still under it, zoomed and pulled with it, and takes no touch.
    @Test func aVideoPlaysAsInPhotos() throws {
        let viewer = try Self.code(Self.viewerPath)
        let play = try #require(AppSource.body(of: "private func playVideo(", in: viewer))
        #expect(play.contains("VideoStart(reduceMotion: reduceMotion, autoplayVideos: UIAccessibility.isVideoAutoplayEnabled)"))
        #expect(play.contains("await video.open(id,"))
        let look = try #require(AppSource.body(of: "private func lookAtCurrent(", in: viewer))
        #expect(Self.inOrder(["await PhotoBasics.of(id)", "await playVideo(id)", "await checkSharing(id)"], in: look))
        #expect(try #require(AppSource.body(of: ".onChange(of: current)", in: viewer)).contains("video.keepOnly(current)"))
        #expect(try #require(AppSource.body(of: "private func closed(", in: viewer)).contains("video.close()"))
        #expect(viewer.contains(".onChange(of: scenePhase)"))
        #expect(viewer.contains("video.pause()"), "a video plays on in the background")

        let model = try Self.file("ViewerVideo.swift")
        #expect(model.contains("@MainActor"))
        #expect(model.contains("@Observable"))
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(Self.inOrder(["await VideoLoader.load(id)", "guard !Task.isCancelled", "start.byItself",
                              "Task.sleep(for: .milliseconds(350))", "guard !Task.isCancelled", "play()"], in: open),
                "\(open)")
        let make = try #require(AppSource.body(of: "private func make(", in: model))
        #expect(make.contains("if start.loops {"))
        #expect(make.contains("AVPlayerLooper(player:"))
        #expect(make.contains("actionAtItemEnd = .pause"), "a video that does not loop moves on at its end")
        #expect(make.contains("isMuted = !sound.isOn"))
        #expect(make.contains("addPeriodicTimeObserver("))
        let leave = try #require(AppSource.body(of: "private func stop(", in: model))
        for step in ["removeTimeObserver(", "pause()", "removeAllItems()", "looper = nil", "player = nil"] {
            #expect(leave.contains(step), "\(step): the player stays alive off screen")
        }
        #expect(Self.inOrder(["looper?.disableLooping()", "removeAllItems()"], in: leave), "the looper fills the emptied queue again")
        let keep = try #require(AppSource.body(of: "func keepOnly(", in: model))
        #expect(keep.contains("guard id != current else { return }"))
        // Scrubbing as Apple's QA1820: one exact seek at a time, the last place when it ends.
        #expect(model.contains("ChaseSeek()"))
        #expect(model.contains("toleranceBefore: .zero, toleranceAfter: .zero"))
        #expect(try #require(AppSource.body(of: "private func seekEnded(", in: model)).contains("seek.finished()"))
        // Its picture: fitted as the still, under no finger, hidden from VoiceOver (the page says it).
        let surface = try Self.file("VideoSurface.swift")
        #expect(surface.contains("UIViewRepresentable"))
        #expect(surface.contains("AVPlayerLayer.self"))
        #expect(surface.contains("videoGravity = .resizeAspect"))
        #expect(surface.contains("isUserInteractionEnabled = false"))
        #expect(surface.contains("player = nil"), "the layer holds the player after it went")
        let photo = try #require(AppSource.body(of: "private func photo(_ image: UIImage, in size: CGSize)", in: viewer))
        #expect(Self.squeezed(photo).contains("ifletplayer{VideoSurface(player:player).allowsHitTesting(false).accessibilityHidden(true)"))
        #expect(Self.inOrder(["Image(uiImage: image)", "VideoSurface(", ".scaleEffect("], in: photo), "the video does not zoom with its still")
    }

    /// A video starts without sound; "Ton an" gives it sound, which stops the user's music and
    /// plays with the silent switch on, as in Photos; "Ton aus" lets the app's sound mix again,
    /// and once the photo view closes, after its player is gone, the user's music is told it may
    /// go on (never under a running player: that would stop the video, review F, F1). The audio
    /// server is called off the main thread, one change after the other, beside H8's `LiveAudio`
    /// and never against it.
    @Test func aVideosSoundIsTheUsersChoice() throws {
        let model = try Self.file("ViewerVideo.swift")
        let toggle = try #require(AppSource.body(of: "func toggleSound(", in: model))
        #expect(Self.inOrder(["sound.toggle()", "isMuted = !sound.isOn", "LiveAudio.videoSound(sound.isOn)"], in: toggle))
        let close = try #require(AppSource.body(of: "func close(", in: model))
        #expect(Self.inOrder(["stop()", "if sound.interruptedOthers", "LiveAudio.videoSoundEnded()", "sound = VideoSound()"], in: close),
                "the music told to go on while the player still runs")
        let audio = try Self.file("LivePhotoPlayer.swift")
        let sound = try #require(AppSource.body(of: "static func videoSound(", in: audio))
        #expect(Self.inOrder(["isReady = false", "Task.detached(", "await previous?.value", "setCategory(.playback",
                              "setActive(true)", "setCategory(.ambient", "await LiveAudio.videoSoundSet("], in: sound), "\(sound)")
        #expect(!sound.contains("setActive(false"), "\"Ton aus\" ends the session under the running player")
        let ended = try #require(AppSource.body(of: "static func videoSoundEnded(", in: audio))
        #expect(Self.inOrder(["isReady = false", "Task.detached(", "await previous?.value", "setCategory(.ambient",
                              "setActive(false, options: .notifyOthersOnDeactivation)", "await LiveAudio.videoSoundSet("], in: ended),
                "\(ended)")
        // The session ends there only, and only when the photo view closes.
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = try Self.code(path)
            let ends = Self.count(#"session\.setActive\(false"#, in: code)
            #expect(ends == (path.hasSuffix("/LivePhotoPlayer.swift") ? 1 : 0), "\(path): \(ends) ends of the session")
            let told = AppSource.calls(of: "LiveAudio.videoSoundEnded(", in: code).count
            #expect(told == (path.hasSuffix("/ViewerVideo.swift") ? 1 : 0), "\(path): the music told \(told) times")
        }
        #expect(Self.squeezed(try #require(AppSource.body(of: "private static func videoSoundSet(", in: audio))).contains("isReady=!on&&done"))
        // A video plays only in the session meant for it (review F, F2). One that starts by
        // itself waits for the pending change and starts only once the app's sound mixes with
        // the user's (or the user turned the sound on), as a Live Photo's short motion waits:
        // under iOS's default session even a muted start stops the user's music. "Abspielen"
        // waits for the pending change too, then plays even if it failed: the user asked.
        let settled = try #require(AppSource.body(of: "static func settled() async", in: audio))
        #expect(Self.inOrder(["while let pending = soundChange", "await pending.value", "if soundChange == pending { return }"],
                             in: settled), "\(settled)")
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(Self.inOrder(["start.byItself", "Task.sleep(for: .milliseconds(350))", "await LiveAudio.settled()",
                              "guard !Task.isCancelled, self.id == id, sound.isOn || LiveAudio.isReady else { return }", "play()"],
                             in: open), "\(open)")
        let tap = try #require(AppSource.body(of: "func togglePlay(", in: model))
        #expect(Self.squeezed(tap) == "{ifisPlaying{pause()}else{playAfterSoundChange()}}", "\(tap)")
        let asked = try #require(AppSource.body(of: "private func playAfterSoundChange(", in: model))
        #expect(Self.inOrder(["guard let asked = player else { return }", "isPlaying = true", "Task {", "await LiveAudio.settled()",
                              "guard player == asked, isPlaying else { return }", "play()"], in: asked), "\(asked)")
        #expect(!asked.contains("isReady"), "\"Abspielen\" does nothing after a change that failed")
        // The photo view's own setting when it opens takes its turn too: "Ton an" right after it
        // is never undone by it.
        let prepare = try #require(AppSource.body(of: "static func prepare(", in: audio))
        #expect(Self.inOrder(["let previous = soundChange", "soundChange = Task.detached(", "await previous?.value",
                              "setCategory(.ambient", "await LiveAudio.finished(done)"], in: prepare), "\(prepare)")
        // The short motion of a Live Photo waits while the category changes (`isReady`).
        #expect(Self.count("assumeIsolated", in: audio) == 1)
    }

    /// Everyone can play, pause, seek and turn on the sound: the buttons say what they do
    /// (VoiceOver and Voice Control read the words), the slider says where the video is in words
    /// and moves by a step that fits the length, VoiceOver's two-finger double tap plays and
    /// pauses; the controls stand under the video on a solid ground (design rule 1), go with the
    /// bars on a tap as in Photos and stay with VoiceOver and Switch Control (`ViewerChrome`).
    @Test func everyoneCanControlAVideo() throws {
        let controls = try Self.file("VideoControls.swift", keepStrings: true)
        for text in ["Text(\"Anhalten\")", "Text(\"Abspielen\")", "Text(\"Ton aus\")", "Text(\"Ton an\")",
                     "Text(\"Wiedergabeposition\")", "\"viewer.video.play\"", "\"viewer.video.sound\"", "\"viewer.video.position\"",
                     ".labelStyle(.iconOnly)", ".minimumHitTarget()", ".floatingPanel(", ".monospacedDigit()",
                     "VideoPosition(at:", ".spoken(words)", "VideoPosition.step(for:", ".accessibilityAdjustableAction"] {
            #expect(controls.contains(text), "\(text) is missing")
        }
        #expect(!controls.contains(".lineLimit(1)"), "a time cut off at a large text size")
        #expect(Self.count(#"\.buttonStyle\(\.borderless\)"#, in: controls) == 2)
        let slider = try #require(AppSource.body(of: "private var slider", in: controls))
        #expect(slider.contains("onEditingChanged:") || slider.contains("{ editing in"))
        #expect(slider.contains("video.beginScrub()") && slider.contains("video.endScrub()"))
        let viewer = try Self.code(Self.viewerPath, keepStrings: true)
        let notes = try #require(AppSource.body(of: "private var notes", in: viewer))
        #expect(notes.contains("if chrome.isShown && video.id == current {"))
        #expect(Self.inOrder(["ShareInICloudNote()", "videoPanel", "IgnoreUndoBar()"], in: notes))
        let panel = try #require(AppSource.body(of: "private var videoPanel", in: viewer))
        #expect(panel.contains("if video.availability.plays {"))
        #expect(panel.contains("VideoControls(video: video, words: model.proposalWords)"))
        #expect(panel.contains("!unavailablePictures.contains(current)"), "the note twice when the page says it")
        // VoiceOver's two-finger double tap plays and pauses a video, on its page and on its
        // controls; on a photo it stays the system's, which pauses the user's music.
        let page = try #require(AppSource.body(of: "private func photo(_ image: UIImage, in size: CGSize)", in: viewer))
        #expect(page.contains(".modifier(PlayPauseOnMagicTap(isVideo: isVideo, action: onPlayPause))"))
        let magic = try #require(AppSource.body(of: ["struct PlayPauseOnMagicTap", "func body(content: Content)"], in: viewer))
        #expect(Self.squeezed(magic).contains("ifisVideo{content.accessibilityAction(.magicTap,action)}else{content}"))
        #expect(Self.count(#"\.accessibilityAction\(\.magicTap"#, in: viewer) == 1, "the magic tap taken from the user's music")
        let built = try #require(AppSource.body(of: "private func page(at index: Int)", in: viewer))
        #expect(built.contains("onPlayPause: { if video.id == id { video.togglePlay() } }"))
        #expect(Self.count(#"\.accessibilityAction\(\.magicTap\) \{ video\.togglePlay\(\) \}"#, in: controls) == 3)
        // The page says it is a video and how long, after where and when.
        let label = try #require(AppSource.body(of: "private func label(of id: AssetID)", in: viewer))
        #expect(Self.inOrder(["title(of: id).spoken(live:", "videoLength(of: id)", ".spoken(model.proposalWords)"], in: label))
        // "Teilen" stays for photos only (DS-10).
        #expect(try #require(AppSource.body(of: "private var shareButton", in: viewer)).contains("if isImage"))
    }

    /// A video only in iCloud shows its still where a sharp one is on the iPhone and says calmly
    /// why it does not play, under it with the bars; never a spinner that waits for a download.
    @Test func aVideoOnlyInICloudSaysWhyCalmly() throws {
        let controls = try Self.file("VideoControls.swift", keepStrings: true)
        let note = try #require(AppSource.body(of: "struct VideoNoteView", in: controls))
        #expect(note.contains("case .onlyInICloud: Text(\"Das Video liegt nur in iCloud. Abspielen kannst du es in der Fotos-App.\")"))
        #expect(note.contains("case .unavailable: Text(\"Dieses Video lässt sich gerade nicht abspielen.\")"))
        #expect(note.contains(".floatingPanel("))
        #expect(note.contains("\"viewer.videoNote\""))
        for path in [Self.viewerPath] + AppSource.swiftFiles(under: Self.folder) {
            #expect(!(try Self.code(path)).contains("ProgressView("), "\(path): a spinner in the photo view")
        }
        let model = try Self.file("ViewerVideo.swift")
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(open.contains("onlyInICloud.contains(id)"), "a video only in iCloud asked again on every swipe")
    }

    // MARK: The photo view waits calmly

    /// While a photo comes the photo view shows the thumbnail the grid showed, from memory, as
    /// Photos does (black without one), and VoiceOver hears "Foto wird geladen"; no spinner. The
    /// large picture shows only when the core calls it sharp; otherwise the calm note says why,
    /// never a big blurry picture (design rule 6).
    @Test func thePhotoViewWaitsWithTheGridsThumbnail() throws {
        let viewer = try Self.code(Self.viewerPath, keepStrings: true)
        let photo = try #require(AppSource.body(of: "private struct ZoomablePhoto", in: viewer))
        let waiting = try #require(AppSource.body(of: "private func waiting(in size: CGSize)", in: photo))
        #expect(waiting.contains("ThumbnailCache.shared.thumbnailInMemory(for: id)"))
        #expect(waiting.contains(".scaledToFit()"), "the preview not fitted as the photo will be")
        // It follows the finger as the photo does: a pull down to close, a pinch.
        #expect(waiting.contains(".scaleEffect(scale * (1 - min(pull / 2000, 0.15)))")
                && waiting.contains(".offset(x: offset.width, y: offset.height + pull)"), "the preview stands still under a pull")
        #expect(waiting.contains("Text(\"Foto wird geladen\")") && waiting.contains("Text(\"Video wird geladen\")"))
        let shown = try #require(AppSource.body(of: "private func shown(in size: CGSize)", in: photo))
        #expect(Self.inOrder(["if let image {", "} else if unavailable {", "} else {", "waiting(in: size)"], in: shown))
        let load = try #require(AppSource.body(of: "private func load(in size: CGSize)", in: photo))
        #expect(Self.inOrder(["await PhotoBasics.of(id)", "ThumbnailCache.shared.largeImage(for: id, pixels: pixels)",
                              "guard !Task.isCancelled", "ViewerPicture.choose(", "case .sharp:", "image = loaded",
                              "onPicture(id, true)", "case .unavailable:", "becameUnavailable()"], in: load), "\(load)")
        #expect(load.contains("original: basics?.pixels"))
        #expect(try #require(AppSource.body(of: "private func giveUp(", in: photo)).contains("becameUnavailable()"))
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
        let thumbnails = try Self.code(Self.thumbnailsPath)
        let inMemory = try #require(AppSource.body(of: "func thumbnailInMemory(for id: AssetID) -> UIImage?", in: thumbnails))
        #expect(inMemory.contains("keptSides[id.rawValue]"))
        #expect(!inMemory.contains("await"))
        let keep = try #require(AppSource.body(of: "private func keep(", in: thumbnails))
        #expect(keep.contains("keptSides[id.rawValue] = side"))
        // The core's measure of sharp is the grids' and the covers'.
        #expect(thumbnails.contains("static let sharpShare: CGFloat = \(ViewerPicture.sharpShare)"))
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
