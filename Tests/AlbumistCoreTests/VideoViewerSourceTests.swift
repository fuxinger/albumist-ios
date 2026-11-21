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
        #expect(Self.squeezed(play).contains("VideoStart(reduceMotion:reduceMotion,autoplayVideos:UIAccessibility.isVideoAutoplayEnabled,"
                                             + "lowPowerMode:ProcessInfo.processInfo.isLowPowerModeEnabled)"), "\(play)")
        #expect(play.contains("await video.open(id,"))
        let look = try #require(AppSource.body(of: "private func lookAtCurrent(", in: viewer))
        #expect(Self.inOrder(["await PhotoBasics.of(id)", "await playVideo(id)", "await checkSharing(id)"], in: look))
        #expect(try #require(AppSource.body(of: ".onChange(of: current)", in: viewer)).contains("video.keepOnly(current)"))
        #expect(try #require(AppSource.body(of: "private func closed(", in: viewer)).contains("video.close()"))
        // It pauses in the background, told by the scene's phase or by the app's notification: a
        // full-screen cover has not always been told its scene's phase (review F, F18).
        let pager = Self.squeezed(try #require(AppSource.body(of: "private var pager", in: viewer)))
        #expect(pager.contains(".onChange(of:scenePhase){_,phaseinifphase==.background{video.pause()}}"),
                "a video plays on in the background")
        #expect(pager.contains(".onReceive(NotificationCenter.default.publisher(for:UIApplication.didEnterBackgroundNotification)){_invideo.pause()}"),
                "a video plays on in the background where the cover misses the scene's phase")
        // It stops at once when the photo view closes, by the button, the pull or VoiceOver's
        // escape: its sound does not run on over the grid while the view slides away (review F,
        // F15; `closed` lets its player go only after that).
        let closeNow = try #require(AppSource.body(of: "private func closeNow(", in: viewer))
        #expect(Self.inOrder(["video.pause()", "dismiss()"], in: closeNow), "\(closeNow)")
        #expect(Self.count(#"(?<![\w.])dismiss\(\)"#, in: viewer) == 1, "a way to close that leaves the video playing")
        #expect(Self.count(#"(?<!func )closeNow\(\)"#, in: viewer) == 3, "the button, the pull and the escape")

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
        // As often as the thumb glides, 30 times a second for a short clip (review F, F13), at
        // most 10 times in Low Power Mode (review V14).
        #expect(Self.inOrder(["let interval = CMTime(seconds: VideoPosition.tickInterval(for: length, lowPowerMode: start.lowPowerMode),",
                              "preferredTimescale: 600)", "addPeriodicTimeObserver(forInterval: interval,"], in: make), "\(make)")
        // A looping video lets the iPhone lock after its first play (review F, F8), unless its
        // sound is on: then it is watched (review V3).
        let tick = try #require(AppSource.body(of: "private func ticked(", in: model))
        #expect(Self.inOrder(["let keepsOn = start.keepsScreenOn(loopsDone: looper?.loopCount ?? 0, soundOn: sound.isOn)",
                              "player.value.preventsDisplaySleepDuringVideoPlayback = keepsOn"], in: tick), "\(tick)")
        let leave = try #require(AppSource.body(of: "private func stop(", in: model))
        for step in ["removeTimeObserver(", "pause()", "removeAllItems()", "looper = nil", "player = nil"] {
            #expect(leave.contains(step), "\(step): the player stays alive off screen")
        }
        #expect(Self.inOrder(["looper?.disableLooping()", "removeAllItems()"], in: leave), "the looper fills the emptied queue again")
        let keep = try #require(AppSource.body(of: "func keepOnly(", in: model))
        #expect(keep.contains("guard id != current else { return }"))
        // The slider's length is what plays (review F, F7): the item's once the core's rule
        // prefers it to the asset's, which `open` keeps.
        #expect(open.contains("assetLength = length"))
        let ticked = try #require(AppSource.body(of: "private func ticked(", in: model))
        #expect(ticked.contains("VideoDuration.playing(asset: assetLength, item: item.duration.seconds)"), "\(ticked)")
        // Scrubbing as Apple's QA1820: one exact seek at a time, the last place when it ends.
        #expect(model.contains("ChaseSeek()"))
        #expect(model.contains("toleranceBefore: .zero, toleranceAfter: .zero"))
        #expect(try #require(AppSource.body(of: "private func seekEnded(", in: model)).contains("chase.finished()"))
        // Its picture: fitted as the still, under no finger, hidden from VoiceOver (the page says it).
        let surface = try Self.file("VideoSurface.swift")
        #expect(surface.contains("UIViewRepresentable"))
        #expect(surface.contains("AVPlayerLayer.self"))
        #expect(surface.contains("videoGravity = .resizeAspect"))
        #expect(surface.contains("isUserInteractionEnabled = false"))
        #expect(surface.contains("player = nil"), "the layer holds the player after it went")
        let photo = try #require(AppSource.body(of: "private func photo(_ image: UIImage?, in size: CGSize)", in: viewer))
        #expect(Self.squeezed(photo).contains("ifletplayer{VideoSurface(player:player).allowsHitTesting(false).accessibilityHidden(true)"))
        #expect(Self.inOrder(["still(image)", "VideoSurface(", ".scaleEffect("], in: photo), "the video does not zoom with its still")
        // A video that plays is its own sharp picture (review F, F6): it shows while its still
        // comes and when none came sharp (a small poster frame), over the grid's thumbnail from
        // memory or the black page; the page says "not available" only without a player, and for
        // a video only once it is known not to play (review V1, `ViewerPage`).
        let zoomable = try #require(AppSource.body(of: "private struct ZoomablePhoto", in: viewer))
        let page = try #require(AppSource.body(of: "private var page: ViewerPage", in: zoomable))
        #expect(page.contains("playing: player != nil"), "\(page)")
        let shown = try #require(AppSource.body(of: "private func shown(in size: CGSize)", in: zoomable))
        #expect(shown.contains("case .picture: photo(image, in: size)"), "\(shown)")
        let still = try #require(AppSource.body(of: "private func still(_ image: UIImage?)", in: zoomable))
        #expect(Self.inOrder(["if let still = image ?? ThumbnailCache.shared.thumbnailInMemory(for: id) {", "Image(uiImage: still)",
                              ".scaledToFit()", "} else {", "Color.clear"], in: still), "\(still)")
    }

    /// After the finger lifts from the slider, or a VoiceOver step, the thumb and the play
    /// symbol hold still until the video is at that place: the ticks of the jump, while the
    /// player still waits, move neither back and forth (review F, F9).
    @Test func theSliderSettlesWithoutAFlicker() throws {
        let model = try Self.file("ViewerVideo.swift")
        let end = try #require(AppSource.body(of: "func endScrub(", in: model))
        #expect(Self.inOrder(["scrubbing = false", "chase = ChaseSeek()", "settle(at: time, playing: playsAfterScrub)"], in: end), "\(end)")
        let move = try #require(AppSource.body(of: "func move(by seconds: Double)", in: model))
        #expect(move.contains("settle(at: time, playing: isPlaying)"), "\(move)")
        let settle = try #require(AppSource.body(of: "private func settle(", in: model))
        #expect(Self.inOrder(["settling = true", "seek(to: seconds,"], in: settle))
        let ended = try #require(AppSource.body(of: "private func seekEnded(", in: model))
        #expect(Self.inOrder(["settling = false", "play()", "chase.finished()"], in: ended), "\(ended)")
        let ticked = try #require(AppSource.body(of: "private func ticked(", in: model))
        #expect(Self.inOrder(["guard !scrubbing, !settling else { return }", "time = ", "isPlaying = "], in: ticked), "\(ticked)")
        #expect(try #require(AppSource.body(of: "private func stop(", in: model)).contains("settling = false"))
    }

    /// A seek's end acts only for its own player and the last place asked for, and never against
    /// a pause: a swipe on right after the finger lifted does not start the next video, a pause
    /// right after it keeps the video still (review F, F10).
    @Test func aSeeksEndActsOnlyForItsOwnPlayer() throws {
        let model = try Self.file("ViewerVideo.swift")
        let seek = try #require(AppSource.body(of: "private func seek(to seconds: Double", in: model))
        #expect(seek.contains("completionHandler: Self.seekHandler(self, serial: seekSerial, settles: settles)"), "\(seek)")
        let ended = try #require(AppSource.body(of: "private func seekEnded(", in: model))
        #expect(Self.inOrder(["guard serial == seekSerial else { return }", "if settles {", "guard !scrubbing else { return }",
                              "settling = false", "if resumes {", "resumes = false", "play()", "chase.finished()"], in: ended), "\(ended)")
        for owner in ["private func make(", "private func stop(", "private func settle("] {
            #expect(try #require(AppSource.body(of: owner, in: model)).contains("seekSerial += 1"), "\(owner)")
        }
        #expect(try #require(AppSource.body(of: "private func settle(", in: model)).contains("resumes = playing"))
        #expect(try #require(AppSource.body(of: "func pause(", in: model)).contains("resumes = false"),
                "a pause right after the finger lifted is undone")
    }

    /// The automatic start never overrides what came after it was planned (review V2): a pause
    /// (the button, VoiceOver's two-finger double tap, closing the photo view, the background), a
    /// finger on the slider or a swipe on in its moment of waiting (350 ms and the change of the
    /// app's sound) cancels it. Before, a video swiped to and closed at once started during the
    /// slide away, its sound over the grid, and "Anhalten" in that moment was undone.
    @Test func theAutomaticStartGivesWayToWhatCameAfterIt() throws {
        let model = try Self.file("ViewerVideo.swift")
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(Self.inOrder(["guard start.byItself, startsByItself else { return }", "Task.sleep(for: .milliseconds(350))",
                              "await LiveAudio.settled()", "guard !Task.isCancelled, self.id == id, startsByItself else { return }",
                              "startsByItself = false", "guard sound.isOn || LiveAudio.isReady else { return }", "play()"], in: open),
                "\(open)")
        for owner in ["func pause(", "func beginScrub(", "private func stop("] {
            let body = try #require(AppSource.body(of: owner, in: model))
            #expect(body.contains("startsByItself = false"), "\(owner) leaves the automatic start standing")
        }
        // Closing the photo view (the button, the pull, the escape) and the background pause it
        // first; `close` stops the video.
        #expect(try #require(AppSource.body(of: "func close(", in: model)).contains("stop()"))
        let viewer = try Self.code(Self.viewerPath)
        #expect(Self.inOrder(["video.pause()", "dismiss()"], in: try #require(AppSource.body(of: "private func closeNow(", in: viewer))))
    }

    /// A pause that comes while the video is still asked for, before Photos handed it over, is
    /// remembered too (review X5): the automatic start is planned before the loader is asked, so a
    /// close (the button, the pull, VoiceOver's escape) or "Anhalten" in that moment cancels it,
    /// and nothing plans it anew once the item came. Before, it was planned only after the
    /// answer: a video swiped to and closed at once could start during the slide away, with the
    /// sound on from an earlier video. A video only in iCloud plans nothing.
    @Test func aPauseBeforeTheVideoCameIsRemembered() throws {
        let model = try Self.file("ViewerVideo.swift")
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(Self.inOrder(["stop()", "if onlyInICloud.contains(id) {", "return", "startsByItself = start.byItself",
                              "let answer = await VideoLoader.load(id)", "guard !Task.isCancelled, self.id == id else { return }",
                              "case .item(let item):", "make(item.value)", "guard start.byItself, startsByItself else { return }",
                              "Task.sleep(for: .milliseconds(350))"], in: open), "\(open)")
        #expect(!open.contains("startsByItself = true"), "planned anew after the answer, a pause meanwhile is forgotten: \(open)")
    }

    /// A video its player cannot play (a file it cannot decode) says so calmly, as one Photos
    /// had nothing for, instead of "Anhalten" over its still for good: its player goes, and the
    /// page is not asked again until the user comes back to it (review F, F11).
    @Test func aVideoThatCannotPlaySaysSo() throws {
        let model = try Self.file("ViewerVideo.swift")
        let failed = try #require(AppSource.body(of: "private var failed: Bool", in: model))
        for part in ["player.value.status == .failed", "player.value.currentItem?.status == .failed", "looper?.status == .failed"] {
            #expect(failed.contains(part), "\(part) is missing")
        }
        let fail = try #require(AppSource.body(of: "private func fail(", in: model))
        #expect(Self.inOrder(["let failedID = id", "let found = availability.afterPlayer(failed: true)", "stop()", "id = failedID",
                              "availability = found"], in: fail), "\(fail)")
        let ticked = try #require(AppSource.body(of: "private func ticked(", in: model))
        #expect(Self.inOrder(["guard let player else { return }", "if failed {", "fail()", "return"], in: ticked), "\(ticked)")
        let play = try #require(AppSource.body(of: "private func play(", in: model))
        #expect(Self.inOrder(["if failed {", "fail()", "return", "player.value.play()"], in: play), "\(play)")
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(open.contains("if self.id == id, player != nil || availability != .unknown { return }"), "asked again on every look")
    }

    /// A video whose item fails before it ever played says so at once (review F, F11): no tick
    /// may come then. The status of its item (a video that plays once) or of its looper (a
    /// looping one plays copies of the item) is observed; the change goes to the main actor as
    /// with the other handlers (made outside it, the video held weakly), and a failure ends in
    /// the calm note. The observation goes with the player, before the looper stops.
    @Test func aVideoThatFailsBeforeItPlayedSaysSoAtOnce() throws {
        let model = try Self.file("ViewerVideo.swift")
        let make = try #require(AppSource.body(of: "private func make(", in: model))
        #expect(Self.inOrder(["if start.loops {", "AVPlayerLooper(player: queue, templateItem: item)",
                              "statusObservation = looper.observe(\\.status, options: [.initial, .new], changeHandler: Self.statusHandler(self))",
                              "} else {", "queue.insert(item, after: nil)",
                              "statusObservation = item.observe(\\.status, options: [.initial, .new], changeHandler: Self.statusHandler(self))"],
                             in: make), "\(make)")
        let handler = try #require(AppSource.body(of: "nonisolated private static func statusHandler<", in: model))
        #expect(Self.inOrder(["[weak video]", "guard let video else { return }", "Task { @MainActor in video.statusChanged() }"], in: handler),
                "\(handler)")
        let changed = try #require(AppSource.body(of: "private func statusChanged(", in: model))
        #expect(Self.squeezed(changed) == "{iffailed{fail()}}", "\(changed)")
        let stop = try #require(AppSource.body(of: "private func stop(", in: model))
        #expect(Self.inOrder(["statusObservation?.invalidate()", "statusObservation = nil", "looper?.disableLooping()"], in: stop), "\(stop)")
        let fail = try #require(AppSource.body(of: "private func fail(", in: model))
        #expect(Self.inOrder(["let failedID = id", "availability.afterPlayer(failed: true)", "stop()", "id = failedID"], in: fail), "\(fail)")
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
                              "guard !Task.isCancelled, self.id == id, startsByItself else { return }",
                              "guard sound.isOn || LiveAudio.isReady else { return }", "play()"], in: open), "\(open)")
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
                     ".floatingPanel(", ".monospacedDigit()",
                     "VideoPosition(at:", ".spoken(words)", "VideoPosition.step(for:", ".accessibilityAdjustableAction"] {
            #expect(controls.contains(text), "\(text) is missing")
        }
        // The times side by side, as in Photos, and stacked where a large text size leaves no
        // room for both on a line ("0:12:03" and "−1:02:03" at AX5 are wider than the panel on
        // a 375-pt iPhone): never cut (review F, F12). One line alone is cut there.
        let times = try #require(AppSource.body(of: "private var times", in: controls))
        #expect(Self.inOrder(["ViewThatFits(in: .horizontal) {", "HStack {", "elapsedTime", "Spacer(minLength:", "remainingTime", "}",
                              "VStack(alignment: .leading", "elapsedTime", "remainingTime"], in: times), "\(times)")
        #expect(!times.contains(".lineLimit(") && !times.contains(".truncationMode(") && !times.contains(".minimumScaleFactor("),
                "a time cut or shrunk instead of stacked")
        #expect(try #require(AppSource.body(of: "private var elapsedTime", in: controls)).contains("Text(verbatim: position.elapsedText)"))
        #expect(try #require(AppSource.body(of: "private var remainingTime", in: controls)).contains("Text(verbatim: position.remainingText)"))
        #expect(Self.count(#"\.buttonStyle\(\.borderless\)"#, in: controls) == 2)
        // The 44-pt tap area is the label's own: a frame around a borderless button only adds
        // empty space, and a near miss moves the slider instead (review F, F3).
        for button in ["private var playButton", "private var soundButton"] {
            let label = try #require(AppSource.body(of: [button, "} label:"], in: controls))
            #expect(Self.inOrder(["Label {", "} icon: {", ".labelStyle(.iconOnly)", ".minimumHitTarget()"], in: label),
                    "\(button): tappable on its symbol only")
            let whole = try #require(AppSource.body(of: button, in: controls))
            #expect(Self.count(#"\.minimumHitTarget\(\)"#, in: whole) == 1, "\(button): a frame around the button")
        }
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
        let page = try #require(AppSource.body(of: "private func photo(_ image: UIImage?, in size: CGSize)", in: viewer))
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
        #expect(shown.contains("case .waiting: waiting(in: size)"), "\(shown)")
        let load = try #require(AppSource.body(of: "private func load(in size: CGSize)", in: photo))
        #expect(Self.inOrder(["await PhotoBasics.of(id)", "ThumbnailCache.shared.largeImage(for: id, pixels: pixels)",
                              "guard !Task.isCancelled", "ViewerPicture.choose(", "case .sharp:", "image = loaded",
                              "onPicture(id, true)", "case .unavailable:", "becameUnavailable()"], in: load), "\(load)")
        // The rule judges what Photos delivered; the page waits by itself until then (review F,
        // F19: the rule's own "waiting" was never asked for).
        #expect(Self.squeezed(load).contains("ViewerPicture.choose(delivered:loaded.map(Self.pixelSize(of:)),original:basics?.pixels,screen:screen)"),
                "\(load)")
        #expect(!load.contains(".waiting"))
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

    /// A video's page never says "Dieses Video ist gerade nicht verfügbar" while its video may
    /// still come (review V1): what a page shows is the core's rule (`ViewerPage`), told where the
    /// page's own video is. That is `.unknown` while it is not the video on screen (not asked for
    /// yet, or swiped away): after a swipe away and back the page waits again until Photos answers.
    @Test func aVideosPageWaitsWhileItsVideoMayStillCome() throws {
        let viewer = try Self.code(Self.viewerPath)
        let zoomable = try #require(AppSource.body(of: "private struct ZoomablePhoto", in: viewer))
        let shown = try #require(AppSource.body(of: "private func shown(in size: CGSize)", in: zoomable))
        #expect(Self.inOrder(["switch page {", "case .picture: photo(image, in: size)", "case .unavailable: unavailableNote(in: size)",
                              "case .waiting: waiting(in: size)"], in: shown), "\(shown)")
        let page = try #require(AppSource.body(of: "private var page: ViewerPage", in: zoomable))
        #expect(Self.squeezed(page).contains("ViewerPage.shows(still:picture,playing:player!=nil,video:isVideo?videoAvailability:nil)"),
                "\(page)")
        let picture = try #require(AppSource.body(of: "private var picture: ViewerPicture?", in: zoomable))
        #expect(Self.inOrder(["if image != nil { return .sharp }", "return unavailable ? .unavailable : nil"], in: picture), "\(picture)")
        let worded = try Self.code(Self.viewerPath, keepStrings: true)
        let note = try #require(AppSource.body(of: ["private struct ZoomablePhoto", "private func unavailableNote(in size: CGSize)"], in: worded))
        #expect(Self.inOrder(["ContentUnavailableView {", "if isVideo {", "Dieses Video ist gerade nicht verfügbar.", "} else {",
                              "Dieses Foto ist gerade nicht verfügbar.", ".accessibilityIdentifier(\"viewer.unavailable\")"], in: note), "\(note)")
        let built = try #require(AppSource.body(of: "private func page(at index: Int)", in: viewer))
        #expect(built.contains("videoAvailability: video.availability(for: id)"), "\(built)")
        let model = try Self.file("ViewerVideo.swift")
        let availability = try #require(AppSource.body(of: "func availability(for id: AssetID) -> VideoAvailability", in: model))
        #expect(Self.squeezed(availability) == "{self.id==id?availability:.unknown}", "\(availability)")
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
        // A request at the new side that brings nothing keeps the photo the cell shows: the
        // ground would stand where the photo was (review F, note on `show`).
        let show = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func show("], in: thumbnails))
        #expect(Self.inOrder(["if loaded == nil, image != nil, loadedID == id { return }", "withAnimation(", "image = loaded"], in: show),
                "\(show)")
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
        #expect(lookUp.contains("remember(asset, for: id, at: now)"))
        let remember = try #require(AppSource.body(of: "private func remember(", in: thumbnails))
        #expect(Self.inOrder(["assets.setObject(asset.value, forKey: id as NSString)", "asset.value.mediaType == .video",
                              "videoLengths[id] = asset.value.duration"], in: remember), "\(remember)")
        let length = try #require(AppSource.body(of: "func videoLength(for id: AssetID) -> VideoDuration?", in: thumbnails))
        #expect(!length.contains("await") && length.contains("videoLengths[id.rawValue]"))
        // The records keep what was looked at last: past their limit the older half goes, not
        // all (review F, F14). Where a record went, the length comes from the asset still in
        // memory: a thumbnail from the image cache passes no lookup that would write it again.
        #expect(thumbnails.contains("private var videoLengths = RecentRecords<Double>(limit: ThumbnailCache.recordLimit)"))
        #expect(thumbnails.contains("private var keptSides = RecentRecords<CGFloat>(limit: ThumbnailCache.recordLimit)"))
        for owner in ["private func keep(", "private func lookUpWaiting(", "private func lookUpAsset(", "private func remember("] {
            let body = try #require(AppSource.body(of: owner, in: thumbnails))
            #expect(!body.contains("removeAll()"), "\(owner): the records emptied whole")
        }
        #expect(Self.inOrder(["if let seconds = videoLengths[id.rawValue]", "assets.object(forKey: id.rawValue as NSString)",
                              "asset.mediaType == .video", "VideoDuration(seconds: asset.duration)"], in: length), "\(length)")
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

    /// A video trimmed in Photos: the length on its thumbnail follows (review F, F14 c). The
    /// assets kept in memory are snapshots; on a change in Photos each kept video the change
    /// touched gets its new asset and length, or loses both when it was deleted, worked out on
    /// the lookups' queue (a change's details may read the Photos database). Nothing else goes:
    /// emptied on each change, the grids lost their badges and the photo view its waiting
    /// thumbnail, and Albumist's own albums alone are many changes (they change no photo).
    @Test func aVideosLengthFollowsAChangeInPhotos() throws {
        // Albumist's own albums change no photo: a change during a plan is not kept for the walk
        // (when and how often it runs: `changesInPhotosAreWalkedTogetherInTheirOrder`).
        let watcher = try Self.code("App/Albumist/Platform/LibraryChangeWatcher.swift")
        let changed = try #require(AppSource.body(of: "private func changed(_ change: ThumbnailRequest.Change)", in: watcher))
        #expect(changed.contains("if !AppModel.shared.execution.isRunning { ThumbnailCache.shared.changeArrived(change) }"), "\(changed)")
        let thumbnails = try Self.code(Self.thumbnailsPath)
        let refresh = try #require(AppSource.body(of: "private func libraryChanged(_ changes: [ThumbnailRequest.Change]) async", in: thumbnails))
        #expect(Self.inOrder(["for key in videoLengths.keys", "assets.object(forKey: key as NSString)",
                              "await ThumbnailRequest.changed(kept, by: changes)",
                              "if case .changed(let asset) = answer { assets.setObject(asset.value, forKey: key as NSString) }"],
                             in: refresh), "\(refresh)")
        // Each record as the core's rule says (`aTrimmedVideosCellOnScreenShowsItsNewLength`).
        #expect(!refresh.contains("removeAll"), "the records emptied on every change")
        let details = try #require(AppSource.body(of: "nonisolated static func changed(", in: thumbnails))
        #expect(Self.inOrder(["lookups.async {", "change.value.changeDetails(for: current)", "objectWasDeleted",
                              "objectAfterChanges"], in: details), "\(details)")
    }

    /// The walk over the kept video records for changes in Photos is coalesced (review V11): the
    /// changes reach the main actor in the order Photos told them (its own serial queue, then the
    /// main queue, first in first out) and wait (`ChangeBacklog`); the watcher's debounced task
    /// walks all of them at once, one walk at a time (at once when many wait), never once per
    /// change, and not at all without a video record. Within a walk the changes count in their
    /// order: the last one that touched a video decides, and a deletion is final.
    @Test func changesInPhotosAreWalkedTogetherInTheirOrder() throws {
        let watcher = try Self.code("App/Albumist/Platform/LibraryChangeWatcher.swift")
        let told = try #require(AppSource.body(of: "nonisolated func photoLibraryDidChange(", in: watcher))
        #expect(Self.inOrder(["let change = ThumbnailRequest.Change(changeInstance)", "DispatchQueue.main.async {",
                              "MainActor.assumeIsolated {", "LibraryChangeWatcher.shared.changed(change)"], in: told), "\(told)")
        #expect(!told.contains("libraryChanged"), "a walk per change")
        let changed = try #require(AppSource.body(of: "private func changed(_ change: ThumbnailRequest.Change)", in: watcher))
        #expect(Self.inOrder(["if !AppModel.shared.execution.isRunning { ThumbnailCache.shared.changeArrived(change) }",
                              "scheduleCatchUp()"], in: changed), "\(changed)")
        let debounced = try #require(AppSource.body(of: "private func scheduleCatchUpNow(", in: watcher))
        #expect(Self.inOrder(["pending = Task {", "try? await Task.sleep(for: .seconds(delay))", "guard !Task.isCancelled else { return }",
                              "ThumbnailCache.shared.followChanges()", "if model.analysis.isRunning {"], in: debounced), "\(debounced)")
        let thumbnails = try Self.code(Self.thumbnailsPath)
        #expect(thumbnails.contains("private var backlog = ChangeBacklog<ThumbnailRequest.Change>(limit: ThumbnailCache.changeLimit)"))
        let arrived = try #require(AppSource.body(of: "func changeArrived(_ change: ThumbnailRequest.Change)", in: thumbnails))
        #expect(Self.squeezed(arrived) == "{ifbacklog.arrived(change){followChanges()}}", "\(arrived)")
        let follow = try #require(AppSource.body(of: "func followChanges()", in: thumbnails))
        #expect(Self.inOrder(["guard let waiting = backlog.take(recordsKept: videoLengths.count > 0 || recordsWentUnchecked) else { return }",
                              "Task {",
                              "await libraryChanged(waiting)", "if backlog.walked() { followChanges() }"], in: follow), "\(follow)")
        let refresh = try #require(AppSource.body(of: "private func libraryChanged(_ changes: [ThumbnailRequest.Change]) async", in: thumbnails))
        #expect(refresh.contains("await ThumbnailRequest.changed(kept, by: changes)"), "\(refresh)")
        let details = try #require(AppSource.body(of: "nonisolated static func changed(", in: thumbnails))
        #expect(Self.inOrder(["lookups.async {", "for (key, asset) in kept {", "var current = asset.value", "for change in changes {",
                              "change.value.changeDetails(for: current)", "objectWasDeleted", "found[key] = .deleted", "break",
                              "objectAfterChanges", "current = after", "found[key] = .changed(Asset(after))"], in: details), "\(details)")
    }

    /// A trimmed video's cell on screen shows its new length, on its badge and to VoiceOver,
    /// without being made anew, once the change was walked, some seconds after it (the watcher's
    /// pause; review V4): each record follows the core's rule (`KeptVideoLength`), and a
    /// small observed revision, raised when a length a cell may show changed, makes the cells on
    /// screen read their record again. A record whose asset is no longer in memory cannot be
    /// checked: it goes with the thumbnail kept for it, so the next look asks Photos again (a
    /// thumbnail from memory passes no lookup that would write the record anew).
    @Test func aTrimmedVideosCellOnScreenShowsItsNewLength() throws {
        let thumbnails = try Self.code(Self.thumbnailsPath)
        let refresh = try #require(AppSource.body(of: "func libraryChanged(", in: thumbnails))
        #expect(Self.inOrder(["for key in videoLengths.keys", "if let asset = assets.object(forKey: key as NSString)",
                              "kept[key] = ThumbnailRequest.Asset(asset)", "} else if let seconds = videoLengths[key]",
                              "apply(KeptVideoLength.step(kept: seconds, inMemory: false, found: nil), to: key)",
                              "await ThumbnailRequest.changed(kept, by: ", "guard let seconds = videoLengths[key] else { continue }",
                              "assets.setObject(asset.value, forKey: key as NSString)",
                              "apply(KeptVideoLength.step(kept: seconds, inMemory: true, found: answer.lengthFound), to: key)",
                              "if readAgain { lengthRevision.raise() }"], in: refresh), "\(refresh)")
        let apply = try #require(AppSource.body(of: "private func apply(_ step: KeptVideoLength.Step, to key: String) -> Bool", in: thumbnails))
        #expect(Self.inOrder(["case .keep:", "case .update(let seconds, _):", "videoLengths[key] = seconds", "case .drop(let checked):",
                              "videoLengths[key] = nil", "if checked {", "assets.removeObject(forKey: key as NSString)",
                              "} else if let side = keptSides[key] {", "cache.removeObject(forKey: Self.thumbnailKey(AssetID(key), side))",
                              "keptSides[key] = nil", "return step.readsAgain"], in: apply), "\(apply)")
        let found = try #require(AppSource.body(of: "var lengthFound: KeptVideoLength.Found", in: thumbnails))
        #expect(Self.inOrder(["case .changed(let asset): .changed(seconds: asset.value.duration)", "case .deleted: .deleted"], in: found))
        // The revision is observed (the cache is not), raised only by a correction.
        #expect(thumbnails.contains("let lengthRevision = VideoLengthRevision()"))
        #expect(Self.inOrder(["@MainActor", "@Observable", "final class VideoLengthRevision"], in: thumbnails))
        let revision = try #require(AppSource.body(of: "final class VideoLengthRevision", in: thumbnails))
        #expect(revision.contains("private(set) var value = 0") && revision.contains("value &+= 1"), "\(revision)")
        #expect(Self.count(#"lengthRevision\.raise\(\)"#, in: thumbnails) == 1)
        // The cell on screen reads its record again: the badge and VoiceOver's words follow.
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains(".onChange(of: ThumbnailCache.shared.lengthRevision.value) { readLengthAgain() }"), "\(shown)")
        let again = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func readLengthAgain("], in: thumbnails))
        #expect(Self.inOrder(["guard loadedID == id", "ThumbnailCache.shared.videoLength(for: id)"], in: again), "\(again)")
    }

    /// A cell on screen never loses its video's length because the thumbnails know nothing of it
    /// (review X2): only a length they know replaces what it shows. Nothing known is not "no
    /// video": after a memory warning, or once a record went unchecked, the records of unchanged
    /// videos are gone too, and every older video cell alive lost its badge and its "Video, …"
    /// for VoiceOver at the next correction, until it was made anew.
    @Test func aCellKeepsItsLengthWhileTheThumbnailsKnowNone() throws {
        let thumbnails = try Self.code(Self.thumbnailsPath)
        let again = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func readLengthAgain("], in: thumbnails))
        #expect(again.contains("video = known"), "a known length does not replace what the cell shows: \(again)")
        #expect(!again.contains("video = ThumbnailCache.shared.videoLength(for: id)"), "nothing known takes the badge away: \(again)")
        #expect(!again.contains("video = nil"), "\(again)")
    }

    /// A trimmed video's badge follows also when its asset was no longer in memory as the change
    /// was walked (review X1: after a trip to Photos it may be gone, a memory warning takes all).
    /// The walk tells the cells when it dropped a record unchecked (the core's `readsAgain`), and
    /// the first change after a memory warning is walked without a record too, to tell them. A
    /// cell on screen that shows a length the thumbnails no longer know keeps it and asks Photos
    /// again, then shows what Photos said (`KeptVideoLength.reading`, `afterAsking`). The cells
    /// that ask after one revision wait for one lookup together: no task and no lookup per cell,
    /// one fetch for 30 video cells on screen, of Photos' metadata only (no image, no download).
    @Test func aCellOnScreenAsksPhotosAgainForALengthThatWentUnchecked() throws {
        let thumbnails = try Self.code(Self.thumbnailsPath)
        let start = try #require(AppSource.body(of: ["final class ThumbnailCache", "init()"], in: thumbnails))
        #expect(Self.inOrder(["$0.videoLengths.removeAll()", "$0.recordsWentUnchecked = true"], in: start), "\(start)")
        let follow = try #require(AppSource.body(of: "func followChanges()", in: thumbnails))
        #expect(follow.contains("backlog.take(recordsKept: videoLengths.count > 0 || recordsWentUnchecked)"), "\(follow)")
        let refresh = try #require(AppSource.body(of: "private func libraryChanged(", in: thumbnails))
        #expect(Self.inOrder(["if recordsWentUnchecked {", "recordsWentUnchecked = false", "readAgain = true",
                              "if readAgain { lengthRevision.raise() }"], in: refresh), "\(refresh)")
        // The cell follows the core's rule, and asks through the cache.
        let again = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func readLengthAgain("], in: thumbnails))
        #expect(Self.squeezed(again).contains(
            "switchKeptVideoLength.reading(shown:showsVideoLength?video:nil,known:ThumbnailCache.shared.videoLength(for:id)){"), "\(again)")
        #expect(Self.inOrder(["case .show(let known): video = known", "case .keep: break", "case .askAgain:", "let asked = id",
                              "ThumbnailCache.shared.askLengthAgain(for: asked) { answer in", "guard loadedID == asked else { return }",
                              "video = KeptVideoLength.afterAsking(shown: video, answer: answer)"], in: again), "\(again)")
        for perCell in ["Task {", "Task.detached", "assetLookup(", "lookUp(", "image(for:"] {
            #expect(!again.contains(perCell), "\(perCell): a lookup per cell")
        }
        // One lookup for the cells that ask after one revision: the first ask starts it, the
        // others of the same moment join it before it runs.
        let ask = try #require(AppSource.body(of: "func askLengthAgain(for id: AssetID", in: thumbnails))
        #expect(Self.inOrder(["if lengthAsks.isEmpty { Task { await answerLengthAsks() } }",
                              "lengthAsks[id.rawValue, default: []].append(answered)"], in: ask), "\(ask)")
        #expect(Self.count(#"Task\s*\{"#, in: ask) == 1, "\(ask)")
        let answer = try #require(AppSource.body(of: "private func answerLengthAsks(", in: thumbnails))
        #expect(Self.inOrder(["let asks = lengthAsks", "lengthAsks = [:]", "Self.batchLimit", "await ThumbnailRequest.lookUp(ids)",
                              "remember(asset, for: id, at: now)", "for answered in cells"], in: answer), "\(answer)")
        #expect(Self.count(#"ThumbnailRequest\.lookUp\("#, in: answer) == 1, "\(answer)")
        for request in ["requestImage(", "requestPlayerItem(", "requestAVAsset(", "isNetworkAccessAllowed"] {
            #expect(!answer.contains(request), "\(request): more than Photos' metadata")
        }
        // Kept as the queue's lookups keep what they found; still one fetch in the file.
        let waiting = try #require(AppSource.body(of: "private func lookUpWaiting(", in: thumbnails))
        #expect(waiting.contains("remember(asset, for: id, at: now)"), "\(waiting)")
        #expect(Self.count(#"ThumbnailRequest\.lookUp\("#, in: thumbnails) == 2)
        #expect(Self.count(#"PHAsset\.fetchAssets\("#, in: thumbnails) == 1)
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
