import AVFoundation
import Foundation
import Photos
import AlbumistCore

/// A video's player item for the photo view (design wave 3, DS-16), only from what is on the
/// iPhone: the network stays off (the owner's promise, Albumist never loads from iCloud), so a
/// video whose file is only in iCloud is said to be there (`VideoAvailability.onlyInICloud`), never
/// downloaded behind a spinner. The version Photos shows (edits and slow motion included) at the
/// best quality on the iPhone, never a small copy that would play blurry. As the Live Photo
/// (`LivePhotoLoader`) and the share check (`PhotoShare`): the asset from the thumbnails' own
/// lookup, the request outside the main actor, one answer (`OneAnswer`), stopped when the user
/// swipes on or Photos does not answer in time.
enum VideoLoader {
    /// `AVPlayerItem` is not marked Sendable; Photos makes it, and it goes to the main actor once.
    struct Item: @unchecked Sendable {
        let value: AVPlayerItem
    }

    enum Answer: Sendable {
        case item(Item)
        /// Why there is none: only in iCloud, or nothing to play now.
        case missing(VideoAvailability)
    }

    @MainActor
    static func load(_ id: AssetID) async -> Answer {
        switch await ThumbnailCache.shared.assetLookup(for: id) {
        case .found(let asset):
            guard asset.value.mediaType == .video else { return .missing(.unavailable) }
            return await request(asset)
        case .unknown, .noAnswer:
            return .missing(.unavailable)
        }
    }

    /// Photos' answer, read by the core's rule (`VideoAvailability.afterRequest`): an item, or
    /// "in the cloud", or the errors (Photos' "network access required" may come under another).
    private static func request(_ asset: ThumbnailRequest.Asset) async -> Answer {
        assert(PHPhotosError.errorDomain == ShareAvailability.photosErrorDomain
               && PHPhotosError.Code.networkAccessRequired.rawValue == ShareAvailability.networkAccessRequired,
               "The core's numbers for Photos' network error are not PhotoKit's")
        let answer = PhotoKitAnswer.image(fallback: Answer.missing(.unavailable))
        answer.limit(.seconds(15))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard answer.begin(continuation) else { return }
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.version = .current
                options.deliveryMode = .highQualityFormat
                let id = PHImageManager.default().requestPlayerItem(forVideo: asset.value, options: options) { item, info in
                    let info = (info as [AnyHashable: Any]?) ?? [:]
                    let inCloud = (info[PHImageResultIsInCloudKey] as? Bool) ?? false
                    let errors = PhotoShare.errorChain(of: info[PHImageErrorKey] as? Error)
                    let found = VideoAvailability.afterRequest(gotItem: item != nil, inCloud: inCloud, errors: errors)
                    if found == .onDevice, let item {
                        answer.finish(.item(Item(value: item)))
                    } else {
                        answer.finish(.missing(found))
                    }
                }
                answer.started(id)
            }
        } onCancel: {
            answer.cancel()
        }
    }
}
