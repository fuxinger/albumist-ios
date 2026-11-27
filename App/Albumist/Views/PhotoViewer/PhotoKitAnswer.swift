import Foundation
import Photos
import AlbumistCore

/// One answer from Photos for an async caller of the photo view (its Live Photo,
/// `LivePhotoLoader`, and its share check and share, `PhotoShare`), as `ThumbnailRequest` waits
/// for its images: the request runs outside the main actor, the first answer counts, and a
/// caller that goes away (a swipe to the next photo) or Photos taking too long (`limit`) answers
/// with the fallback at once and stops the request. The rules are `OneAnswer`'s, tested in the
/// core (review D, L9); here only how each kind of request is stopped.
enum PhotoKitAnswer {
    /// For an image or Live Photo request of `PHImageManager`.
    static func image<Value: Sendable>(fallback: Value) -> OneAnswer<Value, PHImageRequestID> {
        OneAnswer(fallback: fallback) { PHImageManager.default().cancelImageRequest($0) }
    }

    /// For a data request of `PHAssetResourceManager`.
    static func resource<Value: Sendable>(fallback: Value) -> OneAnswer<Value, PHAssetResourceDataRequestID> {
        OneAnswer(fallback: fallback) { PHAssetResourceManager.default().cancelDataRequest($0) }
    }

    /// For `PHAssetResourceManager.writeData`, which has no id and cannot be stopped: the answer
    /// only ends the wait.
    static func write<Value: Sendable>(fallback: Value) -> OneAnswer<Value, Never> {
        OneAnswer(fallback: fallback) { _ in }
    }
}
