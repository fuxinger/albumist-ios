import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import AlbumistCore

/// What a Live Photo is to do next (design wave 2, DS-10): its short motion (`hint`), the whole
/// motion with its sound (`full`), or stop. `serial` tells a new command from the one the view
/// followed already, so a view drawn again does not play again.
struct LiveCommand: Equatable {
    enum Kind: Equatable {
        case hint, full, stop
    }

    private(set) var kind = Kind.stop
    private(set) var serial = 0

    mutating func next(_ kind: Kind) {
        self.kind = kind
        serial += 1
    }
}

/// A Live Photo's motion in Photos' own view (`PHLivePhotoView`), over the still the photo view
/// shows. It shows only while it plays: otherwise the still is what the user sees, as sharp as
/// it is on the iPhone (the "Schärfe-Probe" reads the photo view). It takes no touch of its own;
/// the photo view's gestures decide (a long press plays, a tap hides the bars, a double tap
/// zooms), and VoiceOver plays it from the photo's actions.
struct LivePhotoPlayer: UIViewRepresentable {
    var livePhoto: PHLivePhoto
    var command: LiveCommand

    /// A new view follows only the commands given after it was made.
    func makeCoordinator() -> Coordinator { Coordinator(followed: command.serial) }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.playbackGestureRecognizer.isEnabled = false
        view.alpha = 0
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        context.coordinator.follow(command)
    }

    /// As large as offered: the motion fits itself into it as the still does (aspect fit).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PHLivePhotoView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.delegate = nil
        view.stopPlayback()
    }

    @MainActor
    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        weak var view: PHLivePhotoView?
        private var followed: Int

        init(followed: Int) {
            self.followed = followed
        }

        func follow(_ command: LiveCommand) {
            guard command.serial != followed, let view else { return }
            followed = command.serial
            switch command.kind {
            case .hint:
                // Only once the app's sound mixes with the user's: before, even this muted
                // motion would stop their music (`LiveAudio`).
                guard LiveAudio.isReady else { return }
                view.isMuted = true
                view.startPlayback(with: .hint)
            case .full:
                // With its sound, unless the user listens to something: that keeps playing.
                view.isMuted = AVAudioSession.sharedInstance().isOtherAudioPlaying
                view.startPlayback(with: .full)
            case .stop:
                view.stopPlayback()
            }
        }

        nonisolated func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            showOnMain(playing: true)
        }

        nonisolated func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            showOnMain(playing: false)
        }

        /// PhotoKit does not say on which thread it calls its delegate (the view plays through
        /// an `AVPlayer`): on the main thread at once, from any other after a hop there, never a
        /// trap (review D, M4). Only a `Bool` and this main-actor object cross.
        nonisolated private func showOnMain(playing: Bool) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.show(playing: playing) }
            } else {
                Task { @MainActor in self.show(playing: playing) }
            }
        }

        private func show(playing: Bool) {
            view?.alpha = playing ? 1 : 0
        }
    }
}

/// The app's sound mixes with what the user listens to and follows the silent switch
/// (`.ambient`), so a Live Photo never stops the user's music or podcast (review D, H2): with
/// iOS's default session, other apps' audio stops as soon as a Live Photo plays, even muted.
/// The only other sound is a video's, once the user turns it on (`videoSound`, design wave 3).
///
/// Set when the photo view opens, off the main thread (review D2, N9: it is a synchronous call
/// to the audio server, and it ran where the first Live Photo starts to move, right after a
/// swipe), and kept only once it worked: a failure (the session busy during a call) is tried
/// again when the photo view opens next. Until then the short motion waits (`isReady`).
@MainActor
enum LiveAudio {
    /// The category is set: the app's sound mixes with the user's.
    private(set) static var isReady = false
    private static var setting = false

    static func prepare() {
        guard !isReady, !setting else { return }
        setting = true
        // In turn with a video's sound (`videoSound`): "Ton an" right after the photo view opened
        // is never undone by this.
        let previous = soundChange
        soundChange = Task.detached(priority: .utility) {
            await previous?.value
            let done = (try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])) != nil
            await LiveAudio.finished(done)
        }
    }

    private static func finished(_ done: Bool) {
        setting = false
        isReady = done
    }
}

@MainActor
extension LiveAudio {
    /// The last change of the app's sound (`prepare`, `videoSound`): the next one waits for it,
    /// so the changes reach the audio server in the order they were asked for.
    private static var soundChange: Task<Void, Never>?

    /// A video's sound in the photo view (design wave 3, DS-16, `VideoSound`). On: as in Photos
    /// the video's sound stops the user's music and plays with the silent switch on
    /// (`.playback`). Off: the app's sound mixes and follows the switch again (`.ambient`); the
    /// session stays active, as the video plays on (ended under its player, it would stop the
    /// video too: iOS ends it even when it says it is busy, review F, F1). The user's music is
    /// told it may go on when the photo view closes (`videoSoundEnded`). Off the main thread, as
    /// `prepare` (synchronous calls to the audio server), one change after the other. A Live
    /// Photo's short motion waits meanwhile and while the sound is on (`isReady`); it may move
    /// again once `.ambient` is set, and if that failed, `prepare` sets it when the photo view
    /// opens next.
    static func videoSound(_ on: Bool) {
        isReady = false
        let previous = soundChange
        soundChange = Task.detached(priority: .userInitiated) {
            await previous?.value
            let session = AVAudioSession.sharedInstance()
            let done: Bool
            if on {
                done = (try? session.setCategory(.playback, mode: .moviePlayback, options: [])) != nil
                try? session.setActive(true)
            } else {
                done = (try? session.setCategory(.ambient, mode: .default, options: [])) != nil
            }
            await LiveAudio.videoSoundSet(on: on, done: done)
        }
    }

    /// The photo view closed after a video's sound stopped the user's music
    /// (`VideoSound.interruptedOthers`), and its player is gone (`ViewerVideo.close` stops it
    /// first): the app's sound mixes again (`.ambient`) and the session ends, telling the user's
    /// music it may go on (`.notifyOthersOnDeactivation`). In turn with the other changes.
    static func videoSoundEnded() {
        isReady = false
        let previous = soundChange
        soundChange = Task.detached(priority: .userInitiated) {
            await previous?.value
            let session = AVAudioSession.sharedInstance()
            let done = (try? session.setCategory(.ambient, mode: .default, options: [])) != nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            await LiveAudio.videoSoundSet(on: false, done: done)
        }
    }

    private static func videoSoundSet(on: Bool, done: Bool) {
        isReady = !on && done
    }
}

/// A photo's Live Photo for the photo view: only when its motion is on the iPhone (never from
/// iCloud; without it the still stays and nothing moves), at the size the still is shown.
enum LivePhotoLoader {
    /// `PHLivePhoto` does not change once made and may go between threads, but is not marked
    /// Sendable.
    struct Live: @unchecked Sendable {
        let value: PHLivePhoto
    }

    @MainActor
    static func load(_ id: AssetID, pixels: CGSize) async -> Live? {
        guard let asset = await ThumbnailCache.shared.asset(for: id),
              asset.value.mediaSubtypes.contains(.photoLive) else { return nil }
        return await request(asset, pixels: pixels)
    }

    private static func request(_ asset: ThumbnailRequest.Asset, pixels: CGSize) async -> Live? {
        let answer = PhotoKitAnswer.image(fallback: Live?.none)
        answer.limit(.seconds(15))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard answer.begin(continuation) else { return }
                let options = PHLivePhotoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat
                options.version = .current
                let id = PHImageManager.default().requestLivePhoto(for: asset.value, targetSize: pixels, contentMode: .aspectFit,
                                                                   options: options) { livePhoto, info in
                    // A smaller one may come first; the real one follows.
                    let degraded = ((info as [AnyHashable: Any]?)?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded else { return }
                    answer.finish(livePhoto.map(Live.init(value:)))
                }
                answer.started(id)
            }
        } onCancel: {
            answer.cancel()
        }
    }
}
