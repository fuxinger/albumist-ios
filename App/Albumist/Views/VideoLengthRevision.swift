import Observation

/// Raised when a change in Photos corrected a length a thumbnail may show (review V4 of design
/// wave 3): the thumbnails on screen read theirs again (`AssetThumbnail`), so a video trimmed in
/// Photos shows its new length on its badge and to VoiceOver once the change was walked, some
/// seconds after it (the photo library watcher's pause), without its cell being made anew.
/// Observed on its own: the cache itself is not.
@MainActor
@Observable
final class VideoLengthRevision {
    private(set) var value = 0

    func raise() {
        value &+= 1
    }
}
