import Photos
import SwiftUI
import UIKit
import SortlyCore

/// Thumbnails come straight from Photos every time; Albumist stores no copies.
/// The in-memory cache is limited by decoded bytes, asset lookups are cached, and requests for
/// cells scrolled out of view are cancelled so fast scrolling stays smooth.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let manager = ThumbnailRequest.Manager(PHCachingImageManager())
    private let cache = NSCache<NSString, UIImage>()
    private let assets = NSCache<NSString, PHAsset>()

    init() {
        cache.totalCostLimit = 80 * 1024 * 1024
        cache.countLimit = 2000
        assets.countLimit = 6000
    }

    func image(for id: AssetID, side: CGFloat) async -> UIImage? {
        let key = "\(id.rawValue)#\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let asset = await photoAsset(for: id) else { return nil }
        let scale = UITraitCollection.current.displayScale
        let size = CGSize(width: side * scale, height: side * scale)
        let image = await ThumbnailRequest.load(asset, size: size, manager: manager)
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// A large version for the full-screen viewer: not kept in the cache (a few of them would
    /// push out hundreds of thumbnails), and only what is on the device (no download).
    func largeImage(for id: AssetID, pixels: CGSize) async -> UIImage? {
        guard let asset = await photoAsset(for: id) else { return nil }
        return await ThumbnailRequest.load(asset, size: pixels, manager: manager, contentMode: .aspectFit)
    }

    /// The PhotoKit asset of `id`, looked up once and then kept. The lookup never runs on the
    /// main thread: it reads the Photos database, and while Photos writes to it (new photos,
    /// the albums of a plan) each lookup waits. On the main actor every thumbnail on screen
    /// waited in turn: UI run 43930277920 measured the main thread blocked for up to 65 s
    /// right after a plan ran (the sorting show prefetches its photos while Photos writes),
    /// and the UI tests' accessibility queries timed out.
    private func photoAsset(for id: AssetID) async -> ThumbnailRequest.Asset? {
        let key = id.rawValue as NSString
        if let known = assets.object(forKey: key) { return ThumbnailRequest.Asset(known) }
        guard let fetched = await ThumbnailRequest.lookUp(id) else { return nil }
        assets.setObject(fetched.value, forKey: key)
        return fetched
    }
}

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

    /// Asset lookups wait while Photos writes its database, so they run on their own queue:
    /// neither the main thread nor the few threads of Swift's shared pool (the analysis runs
    /// there) wait for them.
    private static let lookups = DispatchQueue(label: "app.albumist.thumbnail-lookup", qos: .userInitiated, attributes: .concurrent)

    nonisolated static func lookUp(_ id: AssetID) async -> Asset? {
        await withCheckedContinuation { continuation in
            lookups.async {
                let found = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject
                continuation.resume(returning: found.map { Asset($0) })
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

    nonisolated static func load(_ asset: Asset, size: CGSize, manager: Manager, contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
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
                        let pixels = min(image.size.width * image.scale, image.size.height * image.scale)
                        if pixels >= min(size.width, size.height) * 0.7 { state.finish(image) } else { state.keep(image) }
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

struct AssetThumbnail: View {
    var id: AssetID
    var side: CGFloat = 80
    /// Which part stays visible when the photo is cropped; screenshots keep their top.
    var anchor: Alignment = .center
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay(alignment: anchor) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: id) { image = await ThumbnailCache.shared.image(for: id, side: side) }
            .accessibilityHidden(true)
    }
}

/// Grid of thumbnails with a "+N" tile. Few photos get larger tiles; screenshots and
/// documents are shown upright from the top, where their title is.
struct ThumbnailGrid: View {
    var ids: [AssetID]
    /// All photos behind the preview, when `ids` is only a selection of them.
    var total: Int? = nil
    var columns = 4
    var limit = 12
    var portrait = false

    var body: some View {
        let all = total ?? ids.count
        let shown = Array(ids.prefix(limit))
        let count = min(columns, max(shown.count, 2))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: count), spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                AssetThumbnail(id: id, side: count <= 2 ? 200 : (count == 3 ? 140 : 100), anchor: portrait ? .top : .center)
                    .aspectRatio(portrait ? 0.75 : 1, contentMode: .fill)
                    .overlay {
                        if index == shown.count - 1 && all > shown.count {
                            Color.black.opacity(0.45)
                            Text("+\(all - shown.count + 1)").font(.headline).foregroundStyle(.white)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
