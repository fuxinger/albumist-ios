import Photos
import UIKit
import AlbumistCore

/// PhotoKit request outside the main actor (its callbacks must not inherit main-actor
/// isolation, see the demo-library crash) with proper cancellation.
enum ThumbnailRequest {
    /// PHImageManager and PHAsset are thread-safe but not marked Sendable.
    struct Manager: @unchecked Sendable {
        let value: PHCachingImageManager
        init(_ value: PHCachingImageManager) { self.value = value }
    }
    struct Asset: @unchecked Sendable {
        let value: PHAsset
        init(_ value: PHAsset) { self.value = value }
    }
    /// What changed in Photos; read on any thread, but not marked Sendable either.
    struct Change: @unchecked Sendable {
        let value: PHChange
        init(_ value: PHChange) { self.value = value }
    }

    /// What a change in Photos did to a kept asset it touched.
    enum Changed: Sendable {
        case changed(Asset)
        case deleted

        /// What it says of a video's length (`KeptVideoLength`).
        var lengthFound: KeptVideoLength.Found {
            switch self {
            case .changed(let asset): .changed(seconds: asset.value.duration)
            case .deleted: .deleted
            }
        }
    }

    /// Asset lookups wait while Photos writes its database, so they run on their own serial
    /// queue: neither the main thread nor the few threads of Swift's shared pool (the analysis
    /// runs there) wait for them, and only one thread ever does.
    private static let lookups = DispatchQueue(label: "app.albumist.thumbnail-lookup", qos: .userInitiated)

    /// The assets Photos knows among `ids`, by local identifier, in one fetch; nil when Photos
    /// does not answer in time (bounded on the lane of pictures on screen, apart from the
    /// analysis's photos, so the grid never waits for good and a hanging thumbnail never stops
    /// a run; the card's "Fotos antwortet gerade nicht" knows of it).
    nonisolated static func lookUp(_ ids: [String]) async -> [String: Asset]? {
        try? await PhotoKitLibrary.deadline.run("lookUpThumbnails", lane: .thumbnail, limit: PhotoKitLibrary.imageFetchLimit) { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<[String: Asset], Never>) in
                lookups.async {
                    let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                    var found: [String: Asset] = [:]
                    for index in 0..<result.count {
                        let asset = result.object(at: index)
                        found[asset.localIdentifier] = Asset(asset)
                    }
                    continuation.resume(returning: found)
                }
            }
        }
    }

    /// The kept assets the changes touched, by key, and what they did to each (review F, F14),
    /// worked out on the lookups' queue: a change's details may read the Photos database, which
    /// waits while Photos writes. The changes count in the order Photos told them (review V11):
    /// the last one that touched an asset decides, and a deletion is final.
    nonisolated static func changed(_ kept: [String: Asset], by changes: [Change]) async -> [String: Changed] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Changed], Never>) in
            lookups.async {
                var found: [String: Changed] = [:]
                for (key, asset) in kept {
                    var current = asset.value
                    for change in changes {
                        guard let details = change.value.changeDetails(for: current) else { continue }
                        if details.objectWasDeleted {
                            found[key] = .deleted
                            break
                        }
                        if let after = details.objectAfterChanges {
                            current = after
                            found[key] = .changed(Asset(after))
                        }
                    }
                }
                continuation.resume(returning: found)
            }
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UIImage?, Never>?
        private var requestID: PHImageRequestID?
        private var cancelled = false
        private var lowResolution: UIImage?

        /// Returns false if the task was cancelled before the request could start.
        func begin(_ c: CheckedContinuation<UIImage?, Never>) -> Bool {
            lock.withLock {
                if cancelled { return false }
                continuation = c
                return true
            }
        }
        /// Returns false if the task was cancelled while the request was being started: the
        /// caller cancels this late id itself (audit 2, 4.3).
        func started(_ id: PHImageRequestID) -> Bool {
            lock.withLock {
                requestID = id
                return !cancelled
            }
        }
        /// A small preview Photos delivers first; used only if the real thumbnail never comes.
        func keep(_ image: UIImage) { lock.withLock { lowResolution = image } }
        var kept: UIImage? { lock.withLock { lowResolution } }
        func finish(_ image: UIImage?) {
            let c: CheckedContinuation<UIImage?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: image)
        }
        func cancel() -> PHImageRequestID? {
            lock.withLock {
                cancelled = true
                return requestID
            }
        }
    }

    /// How much of the pixels it fills an image must bring, per side, to count as sharp: Photos'
    /// small previews of a photo whose original is in iCloud fall far below it (a cover would be
    /// stretched three times and more), a thumbnail made at the asked size is above it.
    static let sharpShare: CGFloat = 0.7

    /// Whether `image` is sharp enough to fill `target` pixels (aspect fill): it is stretched by
    /// at most 1 / `sharpShare` on the side that decides. For a square target this is the
    /// shorter side of the image against the side of the square.
    nonisolated static func isSharp(_ image: UIImage, for target: CGSize) -> Bool {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        guard width >= 1, height >= 1, target.width >= 1, target.height >= 1 else { return false }
        return max(target.width / width, target.height / height) * sharpShare <= 1
    }

    /// A preview Photos delivers first that may be shown at once. Filled: sharp by `isSharp` (a
    /// wide cover must not take a tall preview that is sharp only on its short side, it waits
    /// for the real thumbnail); fitted (the full-screen viewer): its shorter side as before.
    nonisolated private static func nearlySharp(_ image: UIImage, for target: CGSize, fill: Bool) -> Bool {
        if fill { return isSharp(image, for: target) }
        return min(image.size.width * image.scale, image.size.height * image.scale) >= min(target.width, target.height) * sharpShare
    }

    nonisolated static func load(_ asset: Asset, size: CGSize, manager: Manager, contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let delivered = await request(asset, size: size, manager: manager, contentMode: contentMode)
        // Cancelled: nothing, not the raw image (it can be the full original, see `prepared`).
        guard let delivered, !Task.isCancelled else { return nil }
        return prepared(delivered, for: size, fill: contentMode == .aspectFill)
    }

    /// The first thumbnail of a UI run that came much larger than asked was reported.
    private static let oversizeReported = LockedBox(false)

    /// The image as it will be drawn, made here and not on the main thread: an image much
    /// larger than asked (Photos may hand out the original when it has no thumbnail, as on a
    /// simulator whose previews fail) is scaled down, any other one decoded. Otherwise the
    /// main thread decodes and scales each one while it draws the screen.
    nonisolated private static func prepared(_ image: UIImage, for target: CGSize, fill: Bool) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width >= 1, pixels.height >= 1, target.width >= 1, target.height >= 1 else { return image }
        let fx = target.width / pixels.width, fy = target.height / pixels.height
        let factor = fill ? max(fx, fy) : min(fx, fy)
        guard factor < 0.67 else { return image.preparingForDisplay() ?? image }
        if UITestSupport.isRunning, !oversizeReported.value {
            oversizeReported.value = true
            let delivered = "\(Int(pixels.width))x\(Int(pixels.height)) px"
            let wanted = "\(Int(target.width))x\(Int(target.height)) px"
            MainThreadWatch.shared.report("UI_THUMB_OVERSIZE Photos delivered \(delivered) for \(wanted); scaled down off the main thread")
        }
        let size = CGSize(width: max(1, (pixels.width * factor).rounded()), height: max(1, (pixels.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated private static func request(_ asset: Asset, size: CGSize, manager: Manager, contentMode: PHImageContentMode) async -> UIImage? {
        let state = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.begin(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                let id = manager.value.requestImage(for: asset.value, targetSize: size, contentMode: contentMode, options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded {
                        // A preview that is nearly sharp enough is shown at once; a tiny one would
                        // stay blurry in the cache, so it only serves as fallback.
                        guard let image else { return }
                        if nearlySharp(image, for: size, fill: contentMode == .aspectFill) { state.finish(image) } else { state.keep(image) }
                        return
                    }
                    state.finish(image ?? state.kept)
                }
                if !state.started(id) { manager.value.cancelImageRequest(id) }
            }
        } onCancel: {
            if let id = state.cancel() { manager.value.cancelImageRequest(id) }
            state.finish(nil)
        }
    }
}
