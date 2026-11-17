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
    ///
    /// Lookups wait in a queue and run one batch at a time (one fetch for all waiting ids), so a
    /// screen full of thumbnails costs one database read and never a pile of blocked threads.
    /// Each id is looked up once even if several cells ask; an id whose cells all went away
    /// before its batch ran is skipped; an id Photos does not know is not asked again for a
    /// few seconds (a deleted photo stays deleted, and a cell that asks again soon gets the
    /// same answer).
    private func photoAsset(for id: AssetID) async -> ThumbnailRequest.Asset? {
        let key = id.rawValue
        // The empty id is the placeholder of cards that have no photo yet.
        guard !key.isEmpty else { return nil }
        if let known = assets.object(forKey: key as NSString) { return ThumbnailRequest.Asset(known) }
        if let since = missing[key], ContinuousClock.now - since < Self.missingKept { return nil }
        nextToken &+= 1
        let token = nextToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.enqueue(key, token: token, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(for: key, token: token) }
        }
    }

    private struct Waiter {
        let token: UInt64
        let continuation: CheckedContinuation<ThumbnailRequest.Asset?, Never>
    }
    /// Cells waiting for an asset, by id; every waiter is resumed exactly once, always here
    /// on the main actor and after leaving this list.
    private var waiting: [String: [Waiter]] = [:]
    /// Ids not yet in a batch, in the order they were asked for.
    private var queued: [String] = []
    private var lookingUp = false
    private var nextToken: UInt64 = 0
    private var missing: [String: ContinuousClock.Instant] = [:]
    private static let missingKept = Duration.seconds(5)
    /// One fetch reads at most this many ids, so a long wait for Photos stays one wait.
    private static let batchLimit = 400

    private func enqueue(_ key: String, token: UInt64, _ continuation: CheckedContinuation<ThumbnailRequest.Asset?, Never>) {
        if Task.isCancelled {
            continuation.resume(returning: nil)
            return
        }
        if waiting[key] == nil { queued.append(key) }
        waiting[key, default: []].append(Waiter(token: token, continuation: continuation))
        guard !lookingUp else { return }
        lookingUp = true
        Task { await lookUpWaiting() }
    }

    private func stopWaiting(for key: String, token: UInt64) {
        guard var waiters = waiting[key], let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiting[key] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: nil)
    }

    private func lookUpWaiting() async {
        while !queued.isEmpty {
            var seen = Set<String>()
            let wanted = queued.filter { waiting[$0] != nil && seen.insert($0).inserted }
            let ids = Array(wanted.prefix(Self.batchLimit))
            queued = Array(wanted.dropFirst(Self.batchLimit))
            guard !ids.isEmpty else { continue }
            let found = await ThumbnailRequest.lookUp(ids)
            let now = ContinuousClock.now
            if missing.count > 1000 { missing = missing.filter { now - $0.value < Self.missingKept } }
            for id in ids {
                let asset = found[id]
                if let asset {
                    assets.setObject(asset.value, forKey: id as NSString)
                    missing[id] = nil
                } else {
                    missing[id] = now
                }
                for waiter in waiting.removeValue(forKey: id) ?? [] { waiter.continuation.resume(returning: asset) }
            }
        }
        lookingUp = false
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

    /// Asset lookups wait while Photos writes its database, so they run on their own serial
    /// queue: neither the main thread nor the few threads of Swift's shared pool (the analysis
    /// runs there) wait for them, and only one thread ever does.
    private static let lookups = DispatchQueue(label: "app.albumist.thumbnail-lookup", qos: .userInitiated)

    /// The assets Photos knows among `ids`, by local identifier, in one fetch.
    nonisolated static func lookUp(_ ids: [String]) async -> [String: Asset] {
        await withCheckedContinuation { continuation in
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
        let delivered = await request(asset, size: size, manager: manager, contentMode: contentMode)
        guard let delivered, !Task.isCancelled else { return delivered }
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
            MainThreadWatch.shared.report("UI_THUMB_OVERSIZE Photos delivered \(Int(pixels.width))x\(Int(pixels.height)) px for \(Int(target.width))x\(Int(target.height)) px; scaled down off the main thread")
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
            .task(id: id) {
                let loaded = await ThumbnailCache.shared.image(for: id, side: side)
                // A cell that moved on to another photo keeps the new one's image.
                guard !Task.isCancelled else { return }
                image = loaded
            }
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
