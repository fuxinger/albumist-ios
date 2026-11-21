import Foundation
import Photos

/// One answer from Photos for an async caller of the photo view (its Live Photo,
/// `LivePhotoLoader`, and its share, `PhotoShare`), as `ThumbnailRequest` waits for its images:
/// the request runs outside the main actor, the first answer counts, and a caller that goes
/// away (a swipe to the next photo) or Photos taking too long (`limit`) answers with the
/// fallback at once and stops the request. Photos' callbacks come on its own threads, hence the
/// lock.
final class PhotoKitAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallback: Value
    private var continuation: CheckedContinuation<Value, Never>?
    private var request: PHImageRequestID?
    /// Answered, given up or cancelled: nothing more is waited for.
    private var over = false

    init(fallback: Value) {
        self.fallback = fallback
    }

    /// Takes the caller's continuation. False when the caller was cancelled (or the time ran
    /// out) before the request could begin: then it is answered with the fallback here.
    func begin(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        let open: Bool = lock.withLock {
            if !over { self.continuation = continuation }
            return !over
        }
        if !open { continuation.resume(returning: fallback) }
        return open
    }

    /// The request Photos began; stopped at once when the answer was given up meanwhile.
    func started(_ id: PHImageRequestID) {
        let late: Bool = lock.withLock {
            request = id
            return over
        }
        if late { PHImageManager.default().cancelImageRequest(id) }
    }

    /// Photos' answer; a later one changes nothing.
    func finish(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            over = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    /// The caller went away, or Photos took too long: the fallback, and the request stops.
    func cancel() {
        let (waiting, id): (CheckedContinuation<Value, Never>?, PHImageRequestID?) = lock.withLock {
            // Answered already (the time limit runs out after the answer): nothing to stop.
            guard !over else { return (nil, nil) }
            over = true
            defer { continuation = nil }
            return (continuation, request)
        }
        waiting?.resume(returning: fallback)
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }

    /// Gives up after `duration`: Photos may never answer while it is busy with the photo.
    func limit(_ duration: Duration) {
        Task { [self] in
            try? await Task.sleep(for: duration)
            cancel()
        }
    }
}
