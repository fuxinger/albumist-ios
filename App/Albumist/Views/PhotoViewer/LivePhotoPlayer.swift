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
/// Albumist plays no other sound.
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
        Task.detached(priority: .utility) {
            let done = (try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])) != nil
            await LiveAudio.finished(done)
        }
    }

    private static func finished(_ done: Bool) {
        setting = false
        isReady = done
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
