import Photos
import UIKit
import AlbumistCore

/// Thumbnails come straight from Photos every time; Albumist stores no copies.
/// The in-memory cache is limited by decoded bytes, asset lookups are cached, and requests for
/// cells scrolled out of view are cancelled so fast scrolling stays smooth.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    let manager = ThumbnailRequest.Manager(PHCachingImageManager())
    private let cache = NSCache<NSString, UIImage>()
    /// The covers of the photo cards (`CoverPhoto`), apart from the thumbnails: a cover across
    /// the page is about 3 MB at 3x, and twenty of them in the thumbnails' store would push out
    /// hundreds of the grids' thumbnails. Only sharp covers are kept (`keepCover`).
    let covers = NSCache<NSString, CachedCover>()
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
    /// Raised when a change in Photos corrected a length a thumbnail may show, or dropped one it
    /// could not check: the cells on screen read theirs again (reviews V4, X1).
    let lengthRevision = VideoLengthRevision()
    /// Changes in Photos waiting for one walk over the video records (review V11).
    private var backlog = ChangeBacklog<ThumbnailRequest.Change>(limit: ThumbnailCache.changeLimit)
    /// A long iCloud sync restarts the watcher's pause with each change: with this many waiting
    /// the walk starts at once.
    private static let changeLimit = 32
    /// A memory warning took the records unchecked, while the cells on screen keep the lengths
    /// they show (review X1): the next change is walked even without a record, and tells them.
    private var recordsWentUnchecked = false
    /// The cells on screen that asked Photos again for their video's length (`askLengthAgain`),
    /// by id, waiting for one lookup together.
    private var lengthAsks: [String: [@MainActor (KeptVideoLength.Answer) -> Void]] = [:]

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
            $0.recordsWentUnchecked = true
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

    /// A change in Photos came (`LibraryChangeWatcher`, in the order Photos told them): it waits
    /// for the watcher's debounced walk, which starts at once when many wait (review V11).
    func changeArrived(_ change: ThumbnailRequest.Change) {
        if backlog.arrived(change) { followChanges() }
    }

    /// The video records follow the changes that waited, all at once, one walk at a time, never
    /// once per change (review V11): from the watcher's debounced task. Nothing to walk without
    /// a video record, unless a memory warning took them: the walk then tells the cells on screen
    /// (review X1).
    func followChanges() {
        guard let waiting = backlog.take(recordsKept: videoLengths.count > 0 || recordsWentUnchecked) else { return }
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
    /// show changed or went, also unchecked or with a memory warning, the cells on screen read
    /// theirs again (`lengthRevision`, reviews V4, X1): one that shows a length nobody knows now
    /// asks Photos again (`askLengthAgain`).
    private func libraryChanged(_ changes: [ThumbnailRequest.Change]) async {
        var kept: [String: ThumbnailRequest.Asset] = [:]
        var readAgain = false
        for key in videoLengths.keys {
            if let asset = assets.object(forKey: key as NSString) {
                kept[key] = ThumbnailRequest.Asset(asset)
            } else if let seconds = videoLengths[key] {
                // `apply` first: each record gets its step, whatever the others said.
                readAgain = apply(KeptVideoLength.step(kept: seconds, inMemory: false, found: nil), to: key) || readAgain
            }
        }
        if !kept.isEmpty {
            for (key, answer) in await ThumbnailRequest.changed(kept, by: changes) {
                // Gone meanwhile (a memory warning): nothing to correct.
                guard let seconds = videoLengths[key] else { continue }
                if case .changed(let asset) = answer { assets.setObject(asset.value, forKey: key as NSString) }
                readAgain = apply(KeptVideoLength.step(kept: seconds, inMemory: true, found: answer.lengthFound), to: key) || readAgain
            }
        }
        // The records a memory warning took went unchecked too (review X1).
        if recordsWentUnchecked {
            recordsWentUnchecked = false
            readAgain = true
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

    /// For a cell on screen that shows a length the thumbnails no longer know (its record went
    /// unchecked, or a memory warning took it, review X1): Photos is asked again for the video,
    /// and `answered` gets what it said (`KeptVideoLength.afterAsking`). The cells that ask after
    /// one revision (`lengthRevision`) wait for one lookup together: the first ask starts it, the
    /// others of the same moment join it before it runs, so 30 video cells on screen cost one
    /// fetch, never one each. Photos' metadata only, of what is on the iPhone: no image, no
    /// download.
    func askLengthAgain(for id: AssetID, answered: @escaping @MainActor (KeptVideoLength.Answer) -> Void) {
        if lengthAsks.isEmpty { Task { await answerLengthAsks() } }
        lengthAsks[id.rawValue, default: []].append(answered)
    }

    /// The one lookup for the cells that asked (`askLengthAgain`), at most `batchLimit` ids a
    /// fetch as in the queue's lookups: each asset found is kept as a lookup keeps it, a video's
    /// record with its length now, and each cell gets its answer. On the main actor only as much
    /// as the cells that asked, never as the library.
    private func answerLengthAsks() async {
        let asks = lengthAsks
        lengthAsks = [:]
        var waiting = Array(asks.keys)
        var answers: [String: KeptVideoLength.Answer] = [:]
        while !waiting.isEmpty {
            let ids = Array(waiting.prefix(Self.batchLimit))
            waiting.removeFirst(ids.count)
            let found = await ThumbnailRequest.lookUp(ids)
            let now = ContinuousClock.now
            for id in ids {
                // Photos did not answer in time: nothing is known, the cell keeps what it shows.
                guard let found else {
                    answers[id] = .noAnswer
                    continue
                }
                let asset = found[id]
                remember(asset, for: id, at: now)
                if let asset, asset.value.mediaType == .video {
                    answers[id] = .length(seconds: asset.value.duration)
                } else {
                    answers[id] = .noLength
                }
            }
        }
        for (id, cells) in asks {
            for answered in cells { answered(answers[id] ?? .noAnswer) }
        }
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
    func photoAsset(for id: AssetID) async -> ThumbnailRequest.Asset? {
        if case .found(let asset) = await lookUpAsset(id) { return asset }
        return nil
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
}

/// The asset lookups (`photoAsset`): one queue on the main actor, one batch at a time.
extension ThumbnailCache {
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
                remember(asset, for: id, at: now)
                let answer: AssetLookup = asset.map { .found($0) } ?? .unknown
                for waiter in waiting.removeValue(forKey: id) ?? [] { waiter.continuation.resume(returning: answer) }
            }
        }
        lookingUp = false
    }

    /// What a lookup found for `id`: its asset is kept, and a video's length with it; an id
    /// Photos does not know is not asked again for a few seconds (`missingKept`).
    private func remember(_ asset: ThumbnailRequest.Asset?, for id: String, at now: ContinuousClock.Instant) {
        guard let asset else {
            missing[id] = now
            return
        }
        assets.setObject(asset.value, forKey: id as NSString)
        missing[id] = nil
        // A video's length comes with its asset (DS-16): no fetch of its own.
        if asset.value.mediaType == .video {
            videoLengths[id] = asset.value.duration
        }
    }
}
