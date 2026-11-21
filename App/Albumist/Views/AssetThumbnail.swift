import Photos
import SwiftUI
import UIKit
import AlbumistCore

/// Thumbnails come straight from Photos every time; Albumist stores no copies.
/// The in-memory cache is limited by decoded bytes, asset lookups are cached, and requests for
/// cells scrolled out of view are cancelled so fast scrolling stays smooth.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let manager = ThumbnailRequest.Manager(PHCachingImageManager())
    private let cache = NSCache<NSString, UIImage>()
    /// The covers of the photo cards (`CoverPhoto`), apart from the thumbnails: a cover across
    /// the page is about 3 MB at 3x, and twenty of them in the thumbnails' store would push out
    /// hundreds of the grids' thumbnails. Only sharp covers are kept (`keepCover`).
    private let covers = NSCache<NSString, CachedCover>()
    private let assets = NSCache<NSString, PHAsset>()
    /// The length of each video the lookup found, in seconds (design wave 3, DS-16), read from the
    /// asset the lookup fetches anyway: a video's thumbnail says how long it is without a fetch
    /// of its own (100,000 photos in a grid). Only videos; goes on a memory warning and is read
    /// again with the next lookup.
    private var videoLengths = RecentRecords<Double>(limit: ThumbnailCache.recordLimit)
    /// The side each photo's thumbnail was last kept at (DS-18): the photo view shows that
    /// thumbnail from memory while its large picture comes (`thumbnailInMemory`).
    private var keptSides = RecentRecords<CGFloat>(limit: ThumbnailCache.recordLimit)
    /// More entries than any grid shows between two memory warnings: past it the older half of
    /// the records goes (they are only a shortcut to what is in memory, review F, F14).
    private static let recordLimit = 20_000
    /// Raised when a change in Photos corrected a length a thumbnail may show: the cells on
    /// screen read theirs again (review V4).
    let lengthRevision = VideoLengthRevision()
    /// Changes in Photos waiting for one walk over the video records (review V11).
    private var backlog = ChangeBacklog<ThumbnailRequest.Change>(limit: ThumbnailCache.changeLimit)
    /// A long iCloud sync restarts the watcher's pause with each change: with this many waiting
    /// the walk starts at once.
    private static let changeLimit = 32

    static let thumbnailCostLimit = 80 * 1024 * 1024
    static let coverCostLimit = 24 * 1024 * 1024

    init() {
        cache.totalCostLimit = Self.thumbnailCostLimit
        cache.countLimit = 2000
        covers.totalCostLimit = Self.coverCostLimit
        covers.countLimit = 120
        assets.countLimit = 6000
        // On a memory warning the thumbnails and covers go at once (P4-06), and what the image
        // manager keeps; each comes again from Photos when it is shown.
        MemoryPressure.shared.register("thumbnails", owner: self) {
            $0.cache.removeAllObjects()
            $0.covers.removeAllObjects()
            $0.assets.removeAllObjects()
            $0.videoLengths.removeAll()
            $0.keptSides.removeAll()
            $0.manager.value.stopCachingImagesForAllAssets()
        }
    }

    func image(for id: AssetID, side: CGFloat) async -> UIImage? {
        let key = Self.thumbnailKey(id, side)
        if let cached = cache.object(forKey: key) { return cached }
        guard let asset = await photoAsset(for: id) else { return nil }
        let scale = UITraitCollection.current.displayScale
        let size = CGSize(width: side * scale, height: side * scale)
        return await load(asset, pixels: size, id: id, side: side)
    }

    /// A cover (`CoverPhoto`): the photo at `pixels` (filled, cropped later), only from what is
    /// on the device, and whether it is a screenshot (a cropped one keeps its top). The image can
    /// be only the small preview Photos keeps of a photo whose original is in iCloud:
    /// `ThumbnailRequest.isSharp` says whether it is sharp at that size, and only a sharp one is
    /// kept. `.missing` when Photos does not know the photo (deleted) or has nothing of it on the
    /// device; `.noAnswer` when Photos did not answer in time (it is busy, as right after
    /// "Anlegen"): nothing is known then, and the cover asks again a little later.
    func cover(for id: AssetID, pixels: CGSize) async -> CoverFetch {
        guard pixels.width >= 1, pixels.height >= 1 else { return .missing }
        // A kept cover needs no word from Photos: it shows even while Photos is busy.
        if let kept = cachedCover(for: id, pixels: pixels) { return .image(kept.image, screenshot: kept.screenshot) }
        let asset: ThumbnailRequest.Asset
        switch await lookUpAsset(id) {
        case .found(let found): asset = found
        case .unknown: return .missing
        case .noAnswer: return .noAnswer
        }
        let screenshot = asset.value.mediaSubtypes.contains(.photoScreenshot)
        guard let image = await ThumbnailRequest.load(asset, size: pixels, manager: manager) else {
            return Task.isCancelled ? .noAnswer : .missing
        }
        // A cancelled request is not kept: what came back may not be the prepared image.
        if !Task.isCancelled { keepCover(image, screenshot: screenshot, for: id, pixels: pixels) }
        return .image(image, screenshot: screenshot)
    }

    /// Keeps a cover for its id and size, in the covers' own store, only when it is sharp there:
    /// a blurry preview is asked for again the next time (the photo may be on the device by
    /// then, and the cover then shows it). Returns whether it was kept.
    @discardableResult
    func keepCover(_ image: UIImage, screenshot: Bool, for id: AssetID, pixels: CGSize) -> Bool {
        guard ThumbnailRequest.isSharp(image, for: pixels) else { return false }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        covers.setObject(CachedCover(image: image, screenshot: screenshot), forKey: Self.coverKey(id, pixels), cost: cost)
        return true
    }

    /// The kept cover of `id` at `pixels`, if there is one.
    func cachedCover(for id: AssetID, pixels: CGSize) -> CachedCover? {
        covers.object(forKey: Self.coverKey(id, pixels))
    }

    /// The kept thumbnail of `id` at `side` points, if there is one, from memory only: what a
    /// thumbnail made anew shows first (`AssetThumbnail.init`) and a long press lifts
    /// (`PhotoPreview`). Covers never land here (`PhotoCardPiecesTests`).
    func cachedThumbnail(for id: AssetID, side: CGFloat) -> UIImage? {
        cache.object(forKey: Self.thumbnailKey(id, side))
    }

    /// Keeps a thumbnail as `image(for:side:)` does (for the tests).
    func keepThumbnail(_ image: UIImage, for id: AssetID, side: CGFloat) {
        keep(image, id: id, side: side)
    }

    /// The thumbnail a grid last showed of `id`, at the side it was kept at, from memory only:
    /// what the photo view shows while the large picture comes (design wave 3, DS-18), as Photos
    /// does. Nil when it is not in memory (the photo view's page stays black meanwhile).
    func thumbnailInMemory(for id: AssetID) -> UIImage? {
        guard let side = keptSides[id.rawValue] else { return nil }
        return cachedThumbnail(for: id, side: side)
    }

    /// How long the video `id` is, as the lookup found it, from memory only (DS-16); nil for a
    /// photo or while it was not looked up. Where its record went (`recordLimit`), from its asset
    /// while that is in memory: a thumbnail from the image cache passes no lookup that would
    /// write the record again (review F, F14).
    func videoLength(for id: AssetID) -> VideoDuration? {
        if let seconds = videoLengths[id.rawValue] { return VideoDuration(seconds: seconds) }
        guard let asset = assets.object(forKey: id.rawValue as NSString), asset.mediaType == .video else { return nil }
        return VideoDuration(seconds: asset.duration)
    }

    private static func thumbnailKey(_ id: AssetID, _ side: CGFloat) -> NSString {
        "\(id.rawValue)#\(Int(side))" as NSString
    }

    private static func coverKey(_ id: AssetID, _ pixels: CGSize) -> NSString {
        "\(id.rawValue)#\(Int(pixels.width))x\(Int(pixels.height))" as NSString
    }

    /// Looks the ids up in one batch (`photoAsset`), so a cover whose first photo was not sharp
    /// waits for Photos once for all its other candidates, not once for each of them.
    func lookUp(_ ids: [AssetID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = await self.photoAsset(for: id) }
            }
        }
    }

    private func load(_ asset: ThumbnailRequest.Asset, pixels: CGSize, id: AssetID, side: CGFloat) async -> UIImage? {
        let image = await ThumbnailRequest.load(asset, size: pixels, manager: manager)
        // A cancelled request is not kept: what came back may not be the prepared thumbnail.
        if let image, !Task.isCancelled { keep(image, id: id, side: side) }
        return image
    }

    private func keep(_ image: UIImage, id: AssetID, side: CGFloat) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: Self.thumbnailKey(id, side), cost: cost)
        keptSides[id.rawValue] = side
    }

    /// A large version for the full-screen viewer: not kept in the cache (a few of them would
    /// push out hundreds of thumbnails), and only what is on the device (no download).
    func largeImage(for id: AssetID, pixels: CGSize) async -> UIImage? {
        guard let asset = await photoAsset(for: id) else { return nil }
        return await ThumbnailRequest.load(asset, size: pixels, manager: manager, contentMode: .aspectFit)
    }

    /// The PhotoKit asset of `id` for the photo view's Live Photo and its sharing (DS-10,
    /// `LivePhotoLoader`, `PhotoShare`): the thumbnails' own lookup, so it costs no second read
    /// of the Photos database. Nil when Photos does not know the photo or did not answer in time.
    func asset(for id: AssetID) async -> ThumbnailRequest.Asset? {
        await photoAsset(for: id)
    }

    /// A change in Photos came (`LibraryChangeWatcher`, in the order Photos told them): it waits
    /// for the watcher's debounced walk, which starts at once when many wait (review V11).
    func changeArrived(_ change: ThumbnailRequest.Change) {
        if backlog.arrived(change) { followChanges() }
    }

    /// The video records follow the changes that waited, all at once, one walk at a time, never
    /// once per change (review V11): from the watcher's debounced task. Nothing to walk without
    /// a video record.
    func followChanges() {
        guard let waiting = backlog.take(recordsKept: videoLengths.count > 0) else { return }
        Task {
            await libraryChanged(waiting)
            if backlog.walked() { followChanges() }
        }
    }

    /// Photos changed (review F, F14): the assets kept here are snapshots, so a video trimmed in
    /// Photos kept its old length on its badge. Each kept video the changes touched gets its new
    /// asset and length, or loses both when it was deleted; one whose asset is no longer in
    /// memory cannot be checked, and goes with its kept thumbnail so the next look asks Photos
    /// again (`KeptVideoLength`). The rest stays, so the grids keep their badges and the photo
    /// view its waiting thumbnail (emptied, they went on each change). When a length a cell may
    /// show changed, the cells on screen read theirs again (`lengthRevision`, review V4).
    private func libraryChanged(_ changes: [ThumbnailRequest.Change]) async {
        var kept: [String: ThumbnailRequest.Asset] = [:]
        var readAgain = false
        for key in videoLengths.keys {
            if let asset = assets.object(forKey: key as NSString) {
                kept[key] = ThumbnailRequest.Asset(asset)
            } else if let seconds = videoLengths[key] {
                if apply(KeptVideoLength.step(kept: seconds, inMemory: false, found: nil), to: key) { readAgain = true }
            }
        }
        if !kept.isEmpty {
            for (key, answer) in await ThumbnailRequest.changed(kept, by: changes) {
                // Gone meanwhile (a memory warning): nothing to correct.
                guard let seconds = videoLengths[key] else { continue }
                if case .changed(let asset) = answer { assets.setObject(asset.value, forKey: key as NSString) }
                if apply(KeptVideoLength.step(kept: seconds, inMemory: true, found: answer.lengthFound), to: key) { readAgain = true }
            }
        }
        if readAgain { lengthRevision.raise() }
    }

    /// Does what the core's rule says to the record of `key`; true when the cells on screen read
    /// theirs again.
    private func apply(_ step: KeptVideoLength.Step, to key: String) -> Bool {
        switch step {
        case .keep: break
        case .update(let seconds, _):
            videoLengths[key] = seconds
        case .drop(let checked):
            videoLengths[key] = nil
            if checked {
                assets.removeObject(forKey: key as NSString)
            } else if let side = keptSides[key] {
                cache.removeObject(forKey: Self.thumbnailKey(AssetID(key), side))
                keptSides[key] = nil
            }
        }
        return step.readsAgain
    }

    /// `asset(for:)`, telling "Photos does not know the photo" from "Photos did not answer in
    /// time", for the photo view's share: no answer is no verdict (review D, M6).
    func assetLookup(for id: AssetID) async -> AssetLookup {
        await lookUpAsset(id)
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
        if case .found(let asset) = await lookUpAsset(id) { return asset }
        return nil
    }

    /// What a lookup found: the asset, no such photo (Photos answered), or no answer in time
    /// (Photos is busy; nothing is remembered, the next lookup asks again).
    enum AssetLookup: Sendable {
        case found(ThumbnailRequest.Asset)
        case unknown
        case noAnswer
    }

    /// `photoAsset`, telling "Photos does not know it" from "Photos did not answer".
    private func lookUpAsset(_ id: AssetID) async -> AssetLookup {
        let key = id.rawValue
        // The empty id is the placeholder of cards that have no photo yet.
        guard !key.isEmpty else { return .unknown }
        if let known = assets.object(forKey: key as NSString) {
            // Its length again where the records started over (`recordLimit`).
            if known.mediaType == .video, videoLengths[key] == nil { videoLengths[key] = known.duration }
            return .found(ThumbnailRequest.Asset(known))
        }
        if let since = missing[key], ContinuousClock.now - since < Self.missingKept { return .unknown }
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
        let continuation: CheckedContinuation<AssetLookup, Never>
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

    private func enqueue(_ key: String, token: UInt64, _ continuation: CheckedContinuation<AssetLookup, Never>) {
        if Task.isCancelled {
            continuation.resume(returning: .noAnswer)
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
        waiter.continuation.resume(returning: .noAnswer)
    }

    private func lookUpWaiting() async {
        while !queued.isEmpty {
            var seen = Set<String>()
            let wanted = queued.filter { waiting[$0] != nil && seen.insert($0).inserted }
            let ids = Array(wanted.prefix(Self.batchLimit))
            queued = Array(wanted.dropFirst(Self.batchLimit))
            guard !ids.isEmpty else { continue }
            guard let found = await ThumbnailRequest.lookUp(ids) else {
                // Photos did not answer: these cells show no picture for now, and are not
                // remembered as missing (they are asked again when they come into view).
                for id in ids {
                    for waiter in waiting.removeValue(forKey: id) ?? [] { waiter.continuation.resume(returning: .noAnswer) }
                }
                continue
            }
            let now = ContinuousClock.now
            if missing.count > 1000 { missing = missing.filter { now - $0.value < Self.missingKept } }
            for id in ids {
                let asset = found[id]
                if let asset {
                    assets.setObject(asset.value, forKey: id as NSString)
                    missing[id] = nil
                    // A video's length comes with its asset (DS-16): no fetch of its own.
                    if asset.value.mediaType == .video {
                        videoLengths[id] = asset.value.duration
                    }
                } else {
                    missing[id] = now
                }
                let answer: AssetLookup = asset.map { .found($0) } ?? .unknown
                for waiter in waiting.removeValue(forKey: id) ?? [] { waiter.continuation.resume(returning: answer) }
            }
        }
        lookingUp = false
    }
}

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

/// What `ThumbnailCache.cover` found for one photo of a photo card.
enum CoverFetch {
    /// The photo at the asked size, or only the small preview Photos keeps of it
    /// (`ThumbnailRequest.isSharp` tells them apart).
    case image(UIImage, screenshot: Bool)
    /// Photos answered: it does not know the photo (deleted), or has nothing of it on the device.
    case missing
    /// Photos did not answer in time (it is busy), or the request was cancelled: nothing is known.
    case noAnswer
}

/// A kept cover (`ThumbnailCache.keepCover`) and whether it is a screenshot (its crop keeps the top).
final class CachedCover {
    let image: UIImage
    let screenshot: Bool

    init(image: UIImage, screenshot: Bool) {
        self.image = image
        self.screenshot = screenshot
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

/// A photo's square thumbnail in a grid, straight from Photos (`ThumbnailCache`).
///
/// Design wave 3 (DS-18, "ruhige Platzhalter beim Laden statt grauer Flächen"): while the photo
/// comes the tile shows a soft tinted ground (`ThumbnailGround`), no grey slab; a photo that
/// took a moment fades in, one from memory or that came at once is simply there, so a rebuilt
/// or scrolled-back cell never flickers (`ThumbnailAppearance`). A cell drawn at another size
/// (a grid zoomed to other columns) asks for its photo at that size and shows the one it has
/// meanwhile.
///
/// DS-16: a video says how long it is, "0:15" on a small solid ground in its bottom-leading
/// corner where it fits (`VideoLengthBadge`), and VoiceOver hears "Video, 15 Sekunden" with the
/// cell around it (its label stays the cell's own, the date). The length comes from the asset
/// the thumbnails' lookup fetches anyway (`ThumbnailCache.videoLength`): no fetch per cell.
/// Covers and the mosaic of a card leave it out (`thumbnailShowsVideoLength`).
struct AssetThumbnail: View {
    var id: AssetID
    var side: CGFloat
    /// Which part stays visible when the photo is cropped; screenshots keep their top.
    var anchor: Alignment
    @State private var image: UIImage?
    /// The photo `image` shows: when the same view gets another `id` (a trip's cover), the old
    /// photo is not shown while the new one loads.
    @State private var loadedID: AssetID?
    /// How long the photo `loadedID` is when it is a video.
    @State private var video: VideoDuration?
    @Environment(\.thumbnailShowsVideoLength) private var showsVideoLength

    /// What the app's words are in ("Video, 15 Sekunden"), as the photo view's title has them.
    private static let words = ProposalWords(localization: Bundle.main.preferredLocalizations.first,
                                             region: Locale.current.region?.identifier)

    /// What the task asks for: the photo at the side it is drawn at.
    private struct Slot: Equatable {
        var id: AssetID
        var side: CGFloat
    }

    /// Starts with the thumbnail the cache holds in memory, if it has one: a thumbnail made anew
    /// (a grid cell rebuilt when its photo's long press is switched on or off as "Auswählen"
    /// toggles, `photoMenu`) shows its photo from its first frame, not its ground until the
    /// task below has read the cache again (review C2 of design wave 2, N1). Only from memory:
    /// nothing is asked of Photos here, the task asks for what is not in memory, as before.
    init(id: AssetID, side: CGFloat = 80, anchor: Alignment = .center) {
        self.id = id
        self.side = side
        self.anchor = anchor
        let kept = ThumbnailCache.shared.cachedThumbnail(for: id, side: side)
        _image = State(initialValue: kept)
        _loadedID = State(initialValue: kept == nil ? nil : id)
        _video = State(initialValue: kept == nil ? nil : ThumbnailCache.shared.videoLength(for: id))
    }

    var body: some View {
        ThumbnailGround()
            .overlay(alignment: anchor) {
                if let image, loadedID == id {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsVideoLength, loadedID == id, let video {
                    BadgeCorner { VideoLengthBadge(length: video) }
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: Slot(id: id, side: side)) {
                let asked = ContinuousClock.now
                let seeded = image != nil && loadedID == id
                let loaded = await ThumbnailCache.shared.image(for: id, side: side)
                // A cell that moved on to another photo keeps the new one's image.
                guard !Task.isCancelled else { return }
                show(loaded, seeded: seeded, since: asked)
            }
            .onChange(of: ThumbnailCache.shared.lengthRevision.value) { readLengthAgain() }
            // Only a video says something, with the cell around it: its length as a value.
            .accessibilityElement(children: .ignore)
            .accessibilityValue(spokenLength.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            .accessibilityHidden(spokenLength == nil)
    }

    /// The photo, and how long it is when it is a video; it fades in when it took a moment. A
    /// request at another side (a grid zoomed) that brought nothing keeps the photo shown.
    private func show(_ loaded: UIImage?, seeded: Bool, since asked: ContinuousClock.Instant) {
        if loaded == nil, image != nil, loadedID == id { return }
        let fade = ThumbnailAppearance.fade(seeded: seeded, waited: (ContinuousClock.now - asked) / .seconds(1))
        withAnimation(fade.map { Animation.easeOut(duration: $0) }) {
            image = loaded
            loadedID = id
            video = ThumbnailCache.shared.videoLength(for: id)
        }
    }

    /// A change in Photos corrected a video's length (a video trimmed in Photos, review V4): the
    /// cell on screen reads its record again, so its badge and VoiceOver's words follow without
    /// the cell being made anew, some seconds after the change: once it was walked, after the
    /// photo library watcher's pause (3 s, up to 20 s right after an analysis).
    private func readLengthAgain() {
        guard loadedID == id else { return }
        video = ThumbnailCache.shared.videoLength(for: id)
    }

    /// "Video, 15 Sekunden" for the cell around it; nil for a photo, while it loads, and where
    /// the length is left out.
    private var spokenLength: String? {
        guard showsVideoLength, loadedID == id, let video else { return nil }
        return video.spoken(Self.words)
    }
}

/// The ground of a thumbnail while its photo comes (design wave 3, DS-18): the card with a soft
/// wash of the accent, top-leading to bottom-trailing, the family of the covers' placeholder
/// (`CoverPhoto`), never the flat grey slab of before; a little stronger in dark mode and with
/// Increase Contrast (`ThumbnailGroundTint`). It does not move.
struct ThumbnailGround: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = ThumbnailGroundTint(dark: scheme == .dark, increasedContrast: contrast == .increased)
        Rectangle()
            .fill(Theme.card)
            .overlay {
                LinearGradient(colors: [Theme.accent.opacity(tint.top), Theme.accent.opacity(tint.bottom)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .accessibilityHidden(true)
    }
}

/// A video's length on its thumbnail (DS-16): "0:15" on a small solid light ground, in dark mode
/// too, so it reads the same on any photo (design rule 1: no text right on a photo), with a
/// hairline edge that keeps its shape on a white sky, a firmer one with Increase Contrast (the
/// look of `CardBadgeLabel`). Like the mosaic's "+N" it stops growing at the first accessibility
/// size and keeps to one line; where it would cover too much of the photo it gives way
/// (`BadgeCorner`). VoiceOver hears the length with the cell (`AssetThumbnail`), not here.
struct VideoLengthBadge: View {
    var length: VideoDuration
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(verbatim: length.text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.black.opacity(contrast == .increased ? 0.6 : 0.08), lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityHidden(true)
    }
}

/// Places its badge in the bottom-leading corner of the tile, a little in, where it leaves most
/// of the photo free (`VideoBadge.fits`); otherwise out of the tile, which clips it.
private struct BadgeCorner: Layout {
    private static let inset: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let fits = VideoBadge.fits(badgeWidth: Double(size.width + Self.inset), tileWidth: Double(bounds.width))
                && size.height + Self.inset * 2 <= bounds.height
            let corner = CGPoint(x: bounds.minX + Self.inset, y: fits ? bounds.maxY - Self.inset : bounds.maxY + size.height + Self.inset)
            subview.place(at: corner, anchor: .bottomLeading, proposal: ProposedViewSize(size))
        }
    }
}

private struct ThumbnailShowsVideoLengthKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a thumbnail says a video's length (DS-16): on in the grids, off for covers and
    /// the mosaic of a card, where a photo stands for an album or a suggestion.
    var thumbnailShowsVideoLength: Bool {
        get { self[ThumbnailShowsVideoLengthKey.self] }
        set { self[ThumbnailShowsVideoLengthKey.self] = newValue }
    }
}

/// A cover: the photo, or, when there is none to show because every photo is a sensitive
/// document (`PreviewRank`), a quiet tile with the symbol Photos uses for hidden photos.
/// `hidden: false` for a cover that is missing for another reason (an empty album): the calm
/// ground of a thumbnail (DS-18). A cover says no video length: it stands for its album.
struct CoverThumbnail: View {
    var id: AssetID?
    var side: CGFloat = 80
    var hidden = true

    var body: some View {
        if let id {
            AssetThumbnail(id: id, side: side)
                .environment(\.thumbnailShowsVideoLength, false)
        } else if hidden {
            HiddenThumbnail()
        } else {
            ThumbnailGround()
        }
    }
}

/// The tile of a cover whose every photo is a sensitive document: a neutral ground (design rule
/// 9) with the symbol Photos uses for hidden photos.
private struct HiddenThumbnail: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                Image(systemName: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary) // secondary-text: system (a symbol on a placeholder tile, not text: 3:1 is enough)
            }
            .accessibilityHidden(true)
    }
}

/// Grid of thumbnails with a "+N" tile. Few photos get larger tiles; screenshots and
/// documents are shown upright from the top, where their title is. Sensitive documents are
/// never among `ids` (`PreviewPicker`): with too few other photos the grid has fewer tiles,
/// and with none a single tile says the preview is hidden. "+N" counts from `total`.
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
        if shown.isEmpty && all > 0 {
            hiddenPreview
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: count), spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                    AssetThumbnail(id: id, side: count <= 2 ? 200 : (count == 3 ? 140 : 100), anchor: portrait ? .top : .center)
                        .aspectRatio(portrait ? 0.75 : 1, contentMode: .fill)
                        .overlay {
                            if index == shown.count - 1, let more = PreviewPicker.moreCount(total: all, shown: shown.count) {
                                Color.black.opacity(0.45)
                                // Shown in full at every size (review P3-18: "+…" instead of
                                // "+24" at the largest text, in a quarter of the small iPhone's
                                // width). Like a badge on a photo it stops growing at the first
                                // accessibility size, keeps to one line and shrinks a little
                                // rather than end in "…". VoiceOver reads the full count in the
                                // label of the button around the mosaic ("Alle 31 Fotos ansehen").
                                Text("+\(more)").font(.headline).foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .padding(.horizontal, Theme.Spacing.xs)
                                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                                    .accessibilityIdentifier("thumbnails.more")
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            // A preview of a suggestion or album: no video lengths on it (DS-16).
            .environment(\.thumbnailShowsVideoLength, false)
        }
    }

    /// Every photo is a sensitive document: no picture of one, but a tile that still leads to
    /// all photos (the grid is the button that opens them).
    private var hiddenPreview: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "eye.slash").font(.title2)
                .accessibilityHidden(true)
            Text("Vorschau ausgeblendet").font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.noteText)
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.Spacing.m)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
