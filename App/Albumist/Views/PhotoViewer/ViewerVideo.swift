import AVFoundation
import Observation
import SwiftUI
import AlbumistCore

/// The video on screen in the photo view (design wave 3, DS-16), played as Photos plays it:
///
/// - It starts by itself once the swipe has come to rest and starts over at its end, where
///   motion is welcome; with Reduce Motion or "Auto-Play Video Previews" off it waits for
///   "Abspielen" and stops at its end, in Low Power Mode it plays once (`VideoStart`). Looping,
///   it lets the iPhone lock after its first play.
/// - Without sound until the user turns it on; the choice holds for the next videos of this
///   photo view (`VideoSound`, `LiveAudio.videoSound`).
/// - Only from the iPhone (`VideoLoader`): a video only in iCloud is said to be there and not
///   asked for again while the photo view is open.
/// - One player at most: the video that leaves the screen (a swipe, the photo view closing)
///   stops and lets its player go; the app going to the background pauses it.
/// - The slider seeks to the exact frame, one seek at a time (`ChaseSeek`, Apple's QA1820), and
///   the video goes on after it if it played before.
///
/// Its picture is `VideoSurface` over the still on the photo's page; its controls are
/// `VideoControls` under it.
@MainActor
@Observable
final class ViewerVideo {
    /// `AVQueuePlayer` for the views, which hand it to the player layer; never off the main actor.
    struct Player: Equatable {
        let value: AVQueuePlayer

        static func == (a: Player, b: Player) -> Bool { a.value === b.value }
    }

    /// The video asked for or shown; nil while no video is on screen.
    private(set) var id: AssetID?
    private(set) var availability = VideoAvailability.unknown
    private(set) var player: Player?
    private(set) var isPlaying = false
    /// Where the video is, in seconds; where the finger is while it moves the slider.
    private(set) var time: Double = 0
    private(set) var length: VideoDuration?
    private(set) var sound = VideoSound()

    /// The length Photos' asset says; what plays may differ (`length`, `VideoDuration.playing`).
    @ObservationIgnored private var assetLength: VideoDuration?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var start = VideoStart(reduceMotion: true, autoplayVideos: false, lowPowerMode: false)
    @ObservationIgnored private var seek = ChaseSeek()
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var playsAfterScrub = false
    /// Videos Photos said are only in iCloud: not asked again while the photo view is open.
    @ObservationIgnored private var onlyInICloud: Set<AssetID> = []

    /// The player of `id`'s page, while it is the video on screen.
    func surface(for id: AssetID) -> Player? {
        self.id == id ? player : nil
    }

    /// The video `id` came on screen: asks Photos for it, only from the iPhone, and plays it
    /// where it starts by itself, after a moment for the swipe to come to rest (as a Live
    /// Photo's short motion waits). Ends quietly with the task that asked (a swipe on).
    func open(_ id: AssetID, length: VideoDuration?, start: VideoStart) async {
        if self.id == id, player != nil || availability != .unknown { return }
        stop()
        self.id = id
        self.length = length
        assetLength = length
        self.start = start
        if onlyInICloud.contains(id) {
            availability = .onlyInICloud
            return
        }
        let answer = await VideoLoader.load(id)
        guard !Task.isCancelled, self.id == id else { return }
        switch answer {
        case .item(let item):
            availability = .onDevice
            make(item.value)
            guard start.byItself else { return }
            try? await Task.sleep(for: .milliseconds(350))
            // Only once the app's sound mixes with the user's music (`LiveAudio`), or with the
            // sound the user turned on: before, even this muted start would stop their music.
            await LiveAudio.settled()
            guard !Task.isCancelled, self.id == id, sound.isOn || LiveAudio.isReady else { return }
            play()
        case .missing(let found):
            if found == .onlyInICloud { onlyInICloud.insert(id) }
            availability = found
        }
    }

    /// The photo on screen is `current`: a video that is not it stops and lets its player go.
    func keepOnly(_ current: AssetID) {
        guard id != current else { return }
        stop()
    }

    /// The photo view closes: the video stops and lets its player go; then, if its sound stopped
    /// the user's music, the app's sound mixes again and the music is told it may go on
    /// (`LiveAudio.videoSoundEnded`, only now: under a running player it would stop the video).
    func close() {
        stop()
        if sound.interruptedOthers {
            LiveAudio.videoSoundEnded()
        }
        sound = VideoSound()
    }

    // MARK: Playing

    func togglePlay() {
        if isPlaying { pause() } else { playAfterSoundChange() }
    }

    /// "Abspielen": after the change of the app's sound that may still run (`LiveAudio.settled`),
    /// so a tap right after the photo view opened or after "Ton an" plays in the session meant
    /// for it; then it plays even if that change failed, as the user asked. The button says
    /// "Anhalten" at once; a second tap meanwhile keeps the video still.
    private func playAfterSoundChange() {
        guard let asked = player else { return }
        isPlaying = true
        Task {
            await LiveAudio.settled()
            guard player == asked, isPlaying else { return }
            play()
        }
    }

    private func play() {
        guard let player else { return }
        // At its end (a video that does not loop) it plays from the start again.
        if let item = player.value.currentItem, item.duration.seconds.isFinite,
           item.currentTime().seconds >= item.duration.seconds - 0.1 {
            player.value.seek(to: .zero)
        }
        player.value.play()
        isPlaying = true
    }

    func pause() {
        player?.value.pause()
        isPlaying = false
    }

    func toggleSound() {
        sound.toggle()
        player?.value.isMuted = !sound.isOn
        LiveAudio.videoSound(sound.isOn)
    }

    // MARK: The slider

    /// The finger is on the slider: the video holds still under it.
    func beginScrub() {
        guard let player, !scrubbing else { return }
        scrubbing = true
        playsAfterScrub = isPlaying
        player.value.pause()
    }

    /// The finger moved to `seconds`: the picture follows, one exact seek at a time.
    func scrub(to seconds: Double) {
        time = seconds
        if !scrubbing { beginScrub() }
        if let next = seek.want(seconds) { seek(to: next) }
    }

    /// The finger left the slider: the video is where it is, and plays on if it played before.
    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        seek = ChaseSeek()
        seek(to: time, then: playsAfterScrub)
    }

    /// VoiceOver's swipe up or down on the slider: a step on or back (`VideoPosition.step`).
    func move(by seconds: Double) {
        guard let length else { return }
        time = min(max(time + seconds, 0), Double(length.seconds))
        seek(to: time, then: isPlaying)
    }

    // MARK: Player

    private func make(_ item: AVPlayerItem) {
        let queue = AVQueuePlayer()
        queue.isMuted = !sound.isOn
        if start.loops {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        } else {
            queue.actionAtItemEnd = .pause
            queue.insert(item, after: nil)
        }
        // Four times a second, and whenever it starts, stops or jumps (AVFoundation calls it then
        // too): the time and whether it plays, which an end, a call or another app may change.
        observer = queue.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main,
                                                 using: Self.timeHandler(self))
        player = Player(value: queue)
        time = 0
    }

    private func ticked(_ seconds: Double) {
        guard let player else { return }
        // What plays may be longer than the asset says (slow motion) or shorter (trimmed): the
        // item's length, once it knows it and the core prefers it (review F, F7).
        if let item = player.value.currentItem {
            let playing = VideoDuration.playing(asset: assetLength, item: item.duration.seconds)
            if playing != length { length = playing }
        }
        // A looping video lets the iPhone lock after its first play (review F, F8).
        let keepsOn = start.keepsScreenOn(loopsDone: looper?.loopCount ?? 0)
        if player.value.preventsDisplaySleepDuringVideoPlayback != keepsOn {
            player.value.preventsDisplaySleepDuringVideoPlayback = keepsOn
        }
        if !scrubbing { time = seconds.isFinite ? max(seconds, 0) : 0 }
        let playing = player.value.timeControlStatus != .paused
        if !scrubbing, playing != isPlaying { isPlaying = playing }
    }

    private func seek(to seconds: Double, then plays: Bool? = nil) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.value.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: Self.seekHandler(self, then: plays))
    }

    private func seekEnded(then plays: Bool?) {
        if let plays {
            if plays { play() }
            return
        }
        if let next = seek.finished() { seek(to: next) }
    }

    /// What AVFoundation calls with the time, on the main queue (`queue: .main`): handed to the
    /// main actor there. Made outside the main actor, so it is never taken for main-actor code
    /// that AVFoundation could call from elsewhere.
    nonisolated private static func timeHandler(_ video: ViewerVideo) -> @Sendable (CMTime) -> Void {
        { [weak video] time in
            guard let video else { return }
            let seconds = time.seconds
            MainActor.assumeIsolated { video.ticked(seconds) }
        }
    }

    /// The end of a seek, which AVFoundation tells on a queue of its own: a hop to the main actor.
    nonisolated private static func seekHandler(_ video: ViewerVideo, then plays: Bool?) -> @Sendable (Bool) -> Void {
        { [weak video] _ in
            guard let video else { return }
            Task { @MainActor in video.seekEnded(then: plays) }
        }
    }

    /// Stops the video and lets its player go: off screen nothing of it stays alive.
    private func stop() {
        if let observer, let player { player.value.removeTimeObserver(observer) }
        observer = nil
        player?.value.pause()
        // The looper first, so it puts no new copy of the video into the emptied queue.
        looper?.disableLooping()
        player?.value.removeAllItems()
        looper = nil
        player = nil
        id = nil
        availability = .unknown
        isPlaying = false
        time = 0
        length = nil
        assetLength = nil
        seek = ChaseSeek()
        scrubbing = false
        playsAfterScrub = false
    }
}
