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
    static let folder = "App/Albumist/Views/PhotoViewer"

    static func code(_ path: String, keepStrings: Bool = false) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: keepStrings)
    }

    /// The photo view's code, in all the files it is in (`PhotoViewerSource`).
    static func viewer(keepStrings: Bool = false) throws -> String {
        AppSource.code(try PhotoViewerSource.read(), keepStrings: keepStrings)
    }

    /// The thumbnails' code, in all the files it is in (`ThumbnailSource`).
    static func thumbnails(keepStrings: Bool = false) throws -> String {
        AppSource.code(try ThumbnailSource.read(), keepStrings: keepStrings)
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
        let viewer = try Self.viewer()
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
        let pager = Self.squeezed(try #require(AppSource.body(of: "var pager", in: viewer)))
        #expect(pager.contains(".onChange(of:scenePhase){_,phaseinifphase==.background{video.pause()}}"),
                "a video plays on in the background")
        #expect(pager.contains(".onReceive(NotificationCenter.default.publisher(for:UIApplication.didEnterBackgroundNotification)){_invideo.pause()}"),
                "a video plays on in the background where the cover misses the scene's phase")
        // It stops at once when the photo view closes, by the button, the pull or VoiceOver's
        // escape: its sound does not run on over the grid while the view slides away (review F,
        // F15; `closed` lets its player go only after that).
        let closeNow = try #require(AppSource.body(of: "func closeNow(", in: viewer))
        #expect(Self.inOrder(["video.pause()", "dismiss()"], in: closeNow), "\(closeNow)")
        #expect(Self.count(#"(?<![\w.])dismiss\(\)"#, in: viewer) == 1, "a way to close that leaves the video playing")
        #expect(Self.count(#"(?<!func )closeNow\(\)"#, in: viewer) == 3, "the button, the pull and the escape")

        try Self.theVideoModelPlaysAsInPhotos()
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
        let zoomable = try #require(AppSource.body(of: "struct ZoomablePhoto", in: viewer))
        let page = try #require(AppSource.body(of: "private var page: ViewerPage", in: zoomable))
        #expect(page.contains("playing: player != nil"), "\(page)")
        let shown = try #require(AppSource.body(of: "private func shown(in size: CGSize)", in: zoomable))
        #expect(shown.contains("case .picture: photo(image, in: size)"), "\(shown)")
        let still = try #require(AppSource.body(of: "private func still(_ image: UIImage?)", in: zoomable))
        #expect(Self.inOrder(["if let still = image ?? ThumbnailCache.shared.thumbnailInMemory(for: id) {", "Image(uiImage: still)",
                              ".scaledToFit()", "} else {", "Color.clear"], in: still), "\(still)")
    }

    /// `aVideoPlaysAsInPhotos`: the player of the video on screen (`ViewerVideo`), how it starts,
    /// loops, ticks and goes.
    static func theVideoModelPlaysAsInPhotos() throws {
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
        let viewer = try Self.viewer()
        #expect(Self.inOrder(["video.pause()", "dismiss()"], in: try #require(AppSource.body(of: "func closeNow(", in: viewer))))
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
}
