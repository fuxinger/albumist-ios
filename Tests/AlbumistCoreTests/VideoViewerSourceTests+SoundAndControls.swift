import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// A video's sound, its controls for everyone and the calm note of a video only in iCloud (SwiftLint's file length).
extension VideoViewerSourceTests {
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
        let viewer = try Self.viewer(keepStrings: true)
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
        for path in PhotoViewerSource.views + AppSource.swiftFiles(under: Self.folder) {
            #expect(!(try Self.code(path)).contains("ProgressView("), "\(path): a spinner in the photo view")
        }
        let model = try Self.file("ViewerVideo.swift")
        let open = try #require(AppSource.body(of: "func open(", in: model))
        #expect(open.contains("onlyInICloud.contains(id)"), "a video only in iCloud asked again on every swipe")
    }
}
