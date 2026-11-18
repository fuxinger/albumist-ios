import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import SortlyCore

enum PhotoKitError: Error, LocalizedError {
    case collectionNotFound(String)
    case changeFailed(String)

    var errorDescription: String? {
        switch self {
        case .collectionNotFound: String(localized: "Das Album wurde inzwischen gelöscht oder verschoben.")
        case .changeFailed(let message): message
        }
    }
}

/// Small thread-safe box for values produced inside PhotoKit change blocks.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Reads and writes the user's photo library through PhotoKit. Only the closed set of
/// album/folder operations exists here: no API that deletes or modifies media.
struct PhotoKitLibrary: PhotoLibraryReading, PhotoLibraryWriting {
    // MARK: Bounded waits (app-speed, 18.11.2026; docs/DECISIONS.md)

    /// Every fetch and change request below waits a bounded time for Photos (`PhotosDeadline`):
    /// a Photos that never answers (assetsd or photolibraryd stuck) froze the analysis or a
    /// plan for good before. While a call waits longer than 10 s, the analysis card says
    /// "Fotos antwortet gerade nicht" (`AppModel.updateCard`). Not bounded: the question for
    /// photo access (`requestAccess`, the user decides) and the status reads (local, no answer
    /// from Photos needed). Image requests for the analysis have their own limit
    /// (`ImageLoader`, 30 s, 180 s from iCloud); the fetch of a photo before it is bounded on the
    /// image lane (`imageFetchLimit`), apart from these reads, so a photo that hangs never holds
    /// up a plan.
    static let deadline = PhotosDeadline()
    /// Fetching one photo (or a few) before its image is asked for: the analysis, the grid, the
    /// atlas (second review of the PhotoKit limits, 4).
    static let imageFetchLimit: Duration = .seconds(30)
    /// A read without an answer, or a long read without a sign of progress.
    static let readLimit: Duration = .seconds(60)
    /// A change request. Photos answers within a second or two, adding thousands of photos
    /// within seconds.
    static let writeLimit: Duration = .seconds(60)
    /// Deleting albums or photos: iOS asks the user first, and the request waits for the answer.
    static let deletionLimit: Duration = .seconds(300)

    /// A read of Photos, bounded (`readLimit` without an answer or a `beat`), on the deadline's
    /// own queue, not on Swift's shared pool (a hanging fetch holds none of its threads).
    static func read<T: Sendable>(_ what: String, limit: Duration = readLimit, lane: PhotosDeadline.Lane = .read,
                                  _ work: @escaping @Sendable (PhotosDeadline.Heartbeat) throws -> T) async throws -> T {
        try await deadline.runBlocking(what, lane: lane, limit: limit) { beat in try work(beat) }
    }

    /// PHAsset is thread-safe but not marked Sendable; a fetched asset is only handed on.
    struct FetchedAssets: @unchecked Sendable {
        let assets: [PHAsset]
    }

    /// The photos among `ids` that Photos knows, fetched on the image lane (`imageFetchLimit`):
    /// for one photo's image (the analysis, the atlas cover), apart from the plan's reads.
    /// Throws `PhotosNotResponding` when Photos does not answer in time.
    static func fetchAssets(_ ids: [AssetID], what: String = "fetchAsset") async throws -> FetchedAssets {
        try await read(what, limit: imageFetchLimit, lane: .image) { _ in
            var assets: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
                .enumerateObjects { asset, _, _ in assets.append(asset) }
            return FetchedAssets(assets: assets)
        }
    }

    /// One change request, bounded. Without an answer in time the caller gets
    /// `PhotosNotResponding`: the outcome is not known (Photos may still carry it out), and no
    /// other change goes out until this one has returned (`PhotosDeadline`).
    static func change(_ what: String, limit: Duration = writeLimit, asksUser: Bool = false,
                       _ block: @escaping @Sendable () -> Void) async throws {
        try await deadline.run(what, lane: .write, limit: limit, reportsSlow: !asksUser) { _ in
            try await PHPhotoLibrary.shared().performChanges(block)
        }
    }

    // MARK: Access

    func access() async -> LibraryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> LibraryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Reading

    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] {
        try await fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails) { _, _ in true }
    }

    /// Bounded by `readLimit` without progress: a large first read takes minutes, and it says
    /// every 250 photos that it moves.
    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                     progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> [AssetSnapshot] {
        try await Self.read("fetchAssets") { beat -> [AssetSnapshot] in
            try Self.readAssets(includeHidden: includeHidden, knownDetails: knownDetails) { read, total in
                beat.beat()
                return progress(read, total)
            }
        }
    }

    private static func readAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                                   progress: @escaping (Int, Int) -> Bool) throws -> [AssetSnapshot] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = includeHidden
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)

        // Original file names and RAW detection need PHAssetResource, which costs a few
        // milliseconds per asset. They are read for assets the store does not have them for
        // (new, imported with an old date, or a rebuilt database) and for changed ones; the
        // store keeps the earlier values for the rest.
        var snapshots: [AssetSnapshot] = []
        let total = result.count
        snapshots.reserveCapacity(total)
        if !progress(0, total) { throw LibraryReadPaused(read: []) }
        var stopped = false
        result.enumerateObjects { asset, index, stop in
            // Ended (the app's time ran out, "Analyse neu aufbauen"): stop reading. The
            // partial list is never returned, it would count the rest as deleted.
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            // PhotoKit objects and resource lists are autoreleased: without a pool per photo a
            // first run over tens of thousands of photos kept all of them until the walk ended.
            autoreleasepool {
                let needsResources = knownDetails[AssetID(asset.localIdentifier)].map { known in
                    !AssetSnapshot.sameModification(known, asset.modificationDate)
                } ?? true
                snapshots.append(Self.snapshot(asset, withResources: needsResources))
            }
            // Every 250 photos: a few a second while the file details are read, so the count
            // moves (stress run 43833158673: minutes without a change on a first read), and
            // Pause ends the read there (review of d612bc0: Pause waited for the whole read).
            if (index + 1) % 250 == 0, !progress(index + 1, total) {
                stopped = true
                stop.pointee = true
            }
        }
        if stopped { throw LibraryReadPaused(read: snapshots) }
        _ = progress(snapshots.count, total)
        try Task.checkCancellation()
        return snapshots
    }

    static func snapshot(_ asset: PHAsset, withResources: Bool) -> AssetSnapshot {
        var subtypes = subtypes(from: asset.mediaSubtypes)
        if asset.burstIdentifier != nil { subtypes.insert(.burst) }
        var filename: String?
        var uti: String?
        if withResources {
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            filename = primary?.originalFilename
            uti = primary?.uniformTypeIdentifier
            if resources.contains(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }) {
                subtypes.insert(.raw)
            }
        }
        return AssetSnapshot(
            id: AssetID(asset.localIdentifier),
            kind: kind(asset.mediaType),
            subtypes: subtypes,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            location: asset.location.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            locationAccuracy: asset.location.map { $0.horizontalAccuracy },
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite,
            originalFilename: filename,
            uniformTypeIdentifier: uti
        )
    }

    static func kind(_ type: PHAssetMediaType) -> MediaKind {
        switch type {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default: .unknown
        }
    }

    static func subtypes(from s: PHAssetMediaSubtype) -> MediaSubtypes {
        var result: MediaSubtypes = []
        if s.contains(.photoPanorama) { result.insert(.panorama) }
        if s.contains(.photoHDR) { result.insert(.hdr) }
        if s.contains(.photoScreenshot) { result.insert(.screenshot) }
        if s.contains(.photoLive) { result.insert(.livePhoto) }
        if s.contains(.photoDepthEffect) { result.insert(.depthEffect) }
        if s.contains(.videoStreamed) { result.insert(.streamed) }
        if s.contains(.videoHighFrameRate) { result.insert(.slowMotion) }
        if s.contains(.videoTimelapse) { result.insert(.timelapse) }
        if s.contains(.videoCinematic) { result.insert(.cinematic) }
        if s.contains(.spatialMedia) { result.insert(.spatial) }
        if s.contains(.videoScreenRecording) { result.insert(.screenRecording) }
        return result
    }

    /// Bounded by `readLimit` without progress: every album read is a sign of progress.
    func currentInventory() async throws -> CollectionInventory {
        try await Self.read("currentInventory") { beat -> CollectionInventory in
            let collector = InventoryCollector(beat: beat)
            collector.walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), parent: nil)
            return CollectionInventory(collector.snapshots)
        }
    }

    /// One album or folder without reading the whole list (used to verify every plan step).
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        let raw = id.rawValue
        return try await Self.read("collection") { _ -> CollectionSnapshot? in
            let found: PHCollection? = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil).firstObject
                ?? PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject
            guard let found else { return nil }
            let parent = PHCollectionList.fetchCollectionListsContaining(found, options: nil).firstObject.map { CollectionID($0.localIdentifier) }
            return InventoryCollector.snapshot(of: found, parent: parent)
        }
    }

    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> {
        guard !ids.isEmpty else { return [] }
        return try await Self.read("availableAssets") { beat -> Set<AssetID> in
            var found = Set<AssetID>()
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: chunk.map(\.rawValue), options: nil)
                result.enumerateObjects { asset, _, _ in found.insert(AssetID(asset.localIdentifier)) }
                beat.beat()
            }
            return found
        }
    }

    // MARK: Writing (closed operation set, prompt §16)

    /// A missing parent folder (deleted on another device) must stop the step: creating the
    /// album anyway would put it at the top level of the library.
    private static func requireFolder(_ id: String?) throws {
        guard let id else { return }
        guard PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject != nil else {
            throw PhotoKitError.collectionNotFound(id)
        }
    }

    func canWrite() async -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// A change request has no answer yet: Photos may still carry it out (`PhotosDeadline`).
    func hasUnansweredWrites() async -> Bool {
        Self.deadline.hangingCalls(.write) > 0
    }

    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await createFolder(title: title, parent: parent, noted: { _ in })
    }

    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await createAlbum(title: title, parent: parent, noted: { _ in })
    }

    /// `noted` hears the placeholder's id inside the change block, before Photos commits it: a
    /// request without an answer in time leaves the id in the plan's journal, and the album is
    /// known as Albumist's if it lands later (`ExecutionRecord.maybeCreated`).
    func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) -> Void) async throws -> CollectionID {
        let created = LockedBox<String?>(nil)
        let parentID = parent?.rawValue
        try await Self.read("requireFolder") { _ in try Self.requireFolder(parentID) }
        try await Self.change("createFolder") {
            // Into its folder or not at all (see `parentRequest`).
            guard let folder = Self.parentRequest(parentID) else { return }
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let placeholder = request.placeholderForCreatedCollectionList
            created.value = placeholder.localIdentifier
            noted(CollectionID(placeholder.localIdentifier))
            folder?.addChildCollections([placeholder] as NSArray)
        }
        guard let id = created.value else { throw parentID.map { PhotoKitError.collectionNotFound($0) } ?? PhotoKitError.changeFailed("folder") }
        return CollectionID(id)
    }

    func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) -> Void) async throws -> CollectionID {
        let created = LockedBox<String?>(nil)
        let parentID = parent?.rawValue
        try await Self.read("requireFolder") { _ in try Self.requireFolder(parentID) }
        try await Self.change("createAlbum") {
            // Into its folder or not at all (see `parentRequest`).
            guard let folder = Self.parentRequest(parentID) else { return }
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let placeholder = request.placeholderForCreatedAssetCollection
            created.value = placeholder.localIdentifier
            noted(CollectionID(placeholder.localIdentifier))
            folder?.addChildCollections([placeholder] as NSArray)
        }
        guard let id = created.value else { throw parentID.map { PhotoKitError.collectionNotFound($0) } ?? PhotoKitError.changeFailed("album") }
        return CollectionID(id)
    }

    /// Inside a change block: the request that puts something into folder `id`. `.some(nil)`
    /// for the top level; `nil` when the folder is gone or cannot take it. The folder is
    /// checked before the change block too, but it can go in between (deleted on another
    /// device); creating or moving anyway would put the album at the top of the library
    /// instead of in its folder, without an error. So the caller then changes nothing and
    /// reports the folder as missing.
    private static func parentRequest(_ id: String?) -> PHCollectionListChangeRequest?? {
        guard let id else { return .some(nil) }
        guard let list = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject,
              let request = PHCollectionListChangeRequest(for: list) else { return nil }
        return .some(request)
    }

    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws {
        let albumID = album.rawValue
        let ids = assets.map(\.rawValue)
        let exists = try await Self.read("album") { _ -> Bool in
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject != nil
        }
        guard exists else { throw PhotoKitError.collectionNotFound(albumID) }
        try await Self.change("addAssets") {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetCollectionChangeRequest(for: collection)?.addAssets(fetched)
        }
    }

    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws {
        let albumID = album.rawValue
        let ids = assets.map(\.rawValue)
        try await Self.change("removeAssets") {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            // Removes only the album membership; the media stay in the library.
            PHAssetCollectionChangeRequest(for: collection)?.removeAssets(fetched)
        }
    }

    func renameCollection(_ id: CollectionID, to title: String) async throws {
        let raw = id.rawValue
        try await Self.change("renameCollection") {
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil).firstObject {
                PHAssetCollectionChangeRequest(for: album)?.title = title
            } else if let list = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject {
                PHCollectionListChangeRequest(for: list)?.title = title
            }
        }
    }

    /// `oldParent` is the folder the album is in now (the executor reads it right before).
    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        let raw = id.rawValue
        let oldRaw = oldParent?.rawValue
        let newRaw = newParent?.rawValue
        let moved = LockedBox(false)
        try await Self.change("moveCollection") {
            let collection: PHCollection? = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil).firstObject
                ?? PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject
            // The target first: if it is gone, the album is not taken out of its folder at all
            // (it would end up at the top of the library).
            guard let collection, let target = Self.parentRequest(newRaw) else { return }
            if let oldRaw, let old = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [oldRaw], options: nil).firstObject {
                PHCollectionListChangeRequest(for: old)?.removeChildCollections([collection] as NSArray)
            }
            target?.addChildCollections([collection] as NSArray)
            moved.value = true
        }
        guard moved.value else { throw PhotoKitError.collectionNotFound(newRaw ?? raw) }
    }

    /// One request for everything: Photos asks the user once ("Delete 37 albums?") instead of
    /// once per album. A folder goes only if all it holds goes too (Photos deletes a folder's
    /// contents with it); this is checked here again, not only in the executor.
    ///
    /// First iPhone test (15.11.): undo ran, iOS never asked, nothing was deleted and Photos
    /// reported no error. So nothing here is taken on trust:
    /// - albums and folders are found by walking the folder tree, the way `currentInventory`
    ///   (and so the executor) sees them, not by lookups by identifier (the earlier code mixed
    ///   album and folder identifiers in one lookup and returned silently when it found
    ///   nothing), and the request carries those objects themselves;
    /// - the request waits until Albumist is on screen: iOS shows its question only then;
    /// - the result is read back the same way. What is still there is asked for once more
    ///   only if Photos answered faster than anyone can read and answer its question (so the
    ///   user saw none); after a real answer a second question would surprise them. Still
    ///   there afterwards: `.notApplied`, never a silent return. "Don't Allow" becomes
    ///   `.declinedByUser`.
    /// The last outcome, with how long Photos took, goes into the diagnostic report.
    func deleteCollections(_ ids: [CollectionID]) async throws {
        var log = DeletionLog.Entry(requested: ids.count)
        defer { DeletionLog.record(log) }
        var target = try await Self.deletableNow(ids.map(\.rawValue), log: &log)
        guard !target.isEmpty else {
            log.outcome = "nothing deletable"
            return
        }
        for attempt in 1...2 {
            log.attempts = attempt
            let ready = await Self.waitUntilOnScreen()
            if !ready { log.notOnScreen += 1 }
            let request = target
            let started = Date()
            do {
                // iOS asks the user first: a long limit, and the wait is not "Fotos antwortet
                // gerade nicht". Without an answer by then the outcome is not known (the user may
                // still answer): `PhotosNotResponding`, never "deleted" or "not applied".
                try await Self.change("deleteCollections", limit: Self.deletionLimit, asksUser: true) {
                    // Deletes only the album/folder containers. PhotoKit keeps the media.
                    if !request.albums.isEmpty { PHAssetCollectionChangeRequest.deleteAssetCollections(request.albums as NSArray) }
                    if !request.folders.isEmpty { PHCollectionListChangeRequest.deleteCollectionLists(request.folders as NSArray) }
                }
            } catch let hung as PhotosNotResponding {
                log.seconds.append(Date().timeIntervalSince(started))
                log.outcome = "no answer"
                throw hung
            } catch {
                log.seconds.append(Date().timeIntervalSince(started))
                let ns = error as NSError
                if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.Code.userCancelled.rawValue {
                    log.outcome = "declined"
                    throw LibraryWriteFailure.declinedByUser
                }
                log.outcome = "error \(ns.domain) \(ns.code)"
                throw error
            }
            let took = Date().timeIntervalSince(started)
            log.seconds.append(took)
            // Photos may need a moment before the deletion shows in a new read.
            let requested = request.ids
            var left = try await Self.read("stillThere") { _ in Self.stillThere(requested) }
            var polls = 0
            while !left.isEmpty, polls < 8 {
                try? await Task.sleep(for: .milliseconds(250))
                left = try await Self.read("stillThere") { _ in Self.stillThere(requested) }
                polls += 1
            }
            if left.isEmpty {
                log.outcome = "deleted"
                return
            }
            log.stillThere = left.count
            guard attempt == 1, took < Self.fastestAnswer else { break }
            // Found again from the tree, with the folder check again: only what is still
            // there, and a folder only if everything in it still goes.
            var again = DeletionLog.Entry(requested: left.count)
            target = try await Self.deletableNow(Array(left), log: &again)
            if target.isEmpty { break }
            // A question that could not be shown (a dialog was still closing) shows now.
            try? await Task.sleep(for: .seconds(1))
        }
        log.outcome = "not applied"
        throw LibraryWriteFailure.notApplied
    }

    /// `deletable` over a fresh walk of the tree, bounded like every read.
    private static func deletableNow(_ raws: [String], log: inout DeletionLog.Entry) async throws -> DeletionTarget {
        let before = log
        let (target, entry) = try await read("deletable") { _ -> (DeletionTarget, DeletionLog.Entry) in
            var entry = before
            let target = deletable(raws, in: CollectionTree(), log: &entry)
            return (target, entry)
        }
        log = entry
        return target
    }

    /// Less time than anyone needs to read the iOS question and tap an answer: a request
    /// that came back faster was not shown to the user.
    private static let fastestAnswer: TimeInterval = 0.8

    /// The albums and folders of one deletion request. PHObjects are immutable and may be
    /// used on any thread (Photos documentation), so they can go into the change block.
    private struct DeletionTarget: @unchecked Sendable {
        var albums: [PHAssetCollection] = []
        var folders: [PHCollectionList] = []
        var isEmpty: Bool { albums.isEmpty && folders.isEmpty }
        var ids: [String] { albums.map(\.localIdentifier) + folders.map(\.localIdentifier) }
    }

    /// Every user album and folder, found by walking the folder tree from the top, exactly as
    /// `currentInventory` finds them.
    private struct CollectionTree {
        var byID: [String: PHCollection] = [:]
        var children: [String: [String]] = [:]

        init() {
            walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), parent: nil, depth: 0)
        }

        private mutating func walk(_ result: PHFetchResult<PHCollection>, parent: String?, depth: Int) {
            // Photos has no folder cycles; the depth limit only keeps a broken library from
            // looping forever.
            guard depth < 64 else { return }
            for index in 0..<result.count {
                let collection = result.object(at: index)
                let id = collection.localIdentifier
                byID[id] = collection
                if let parent { children[parent, default: []].append(id) }
                if let list = collection as? PHCollectionList {
                    children[id] = children[id] ?? []
                    walk(PHCollection.fetchCollections(in: list, options: nil), parent: id, depth: depth + 1)
                }
            }
        }
    }

    /// The albums, and the folders whose whole content goes too. Something Photos does not
    /// let Albumist delete is left out (it would fail the whole request) and counted.
    private static func deletable(_ raws: [String], in tree: CollectionTree, log: inout DeletionLog.Entry) -> DeletionTarget {
        var target = DeletionTarget()
        var lists: [PHCollectionList] = []
        for raw in Set(raws).sorted() {
            let found = tree.byID[raw]
            if let album = found as? PHAssetCollection {
                if album.canPerform(.delete) { target.albums.append(album) } else { log.notDeletable += 1 }
            } else if let list = found as? PHCollectionList {
                if list.canPerform(.delete) { lists.append(list) } else { log.notDeletable += 1 }
            } else {
                log.missing += 1
            }
        }
        var going = Set(target.albums.map(\.localIdentifier))
        var changed = true
        while changed {
            changed = false
            for list in lists where !going.contains(list.localIdentifier) {
                if (tree.children[list.localIdentifier] ?? []).allSatisfy(going.contains) {
                    going.insert(list.localIdentifier)
                    target.folders.append(list)
                    changed = true
                }
            }
        }
        log.albums = target.albums.count
        log.folders = lists.count
        log.foldersKept = lists.count - target.folders.count
        return target
    }

    /// Which of these albums and folders a new walk of the tree still finds.
    private static func stillThere(_ ids: [String]) -> Set<String> {
        let tree = CollectionTree()
        return Set(ids.filter { tree.byID[$0] != nil })
    }

    /// iOS asks before it deletes albums, and it can show that question only while Albumist
    /// is on screen and no dialog of its own is still opening or closing (a deletion started
    /// from a confirmation dialog). A request that comes up while the user switched away
    /// waits until they are back, up to a limit; then it is sent anyway, and the read-back
    /// says what happened. Returns whether Albumist was ready to show the question.
    @MainActor
    private static func waitUntilOnScreen(limit: Duration = .seconds(30)) async -> Bool {
        func ready() -> Bool {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard scenes.contains(where: { $0.activationState == .foregroundActive }) else { return false }
            return !scenes.contains { scene in
                var controller = scene.keyWindow?.rootViewController
                while let current = controller {
                    if current.isBeingPresented || current.isBeingDismissed { return true }
                    controller = current.presentedViewController
                }
                return false
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !ready(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return ready()
    }

    func deleteCollection(_ id: CollectionID) async throws {
        let raw = id.rawValue
        // Never delete a folder that still holds something: Photos would delete its contents.
        let holdsSomething = try await Self.read("folderContents") { _ -> Bool in
            guard let list = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject else { return false }
            return PHCollection.fetchCollections(in: list, options: nil).count > 0
        }
        if holdsSomething { return }
        try await Self.change("deleteCollection", limit: Self.deletionLimit, asksUser: true) {
            // Deletes only the album/folder container. PhotoKit keeps the media.
            let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil)
            if albums.count > 0 {
                PHAssetCollectionChangeRequest.deleteAssetCollections(albums)
            } else {
                let lists = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil)
                if lists.count > 0 { PHCollectionListChangeRequest.deleteCollectionLists(lists) }
            }
        }
    }
}

/// Walks the user's folder/album tree.
private final class InventoryCollector {
    var snapshots: [CollectionSnapshot] = []
    /// Said after every album and folder: the walk is still moving (`PhotoKitLibrary.read`).
    private let beat: PhotosDeadline.Heartbeat?

    init(beat: PhotosDeadline.Heartbeat? = nil) {
        self.beat = beat
    }

    func walk(_ result: PHFetchResult<PHCollection>, parent: CollectionID?) {
        result.enumerateObjects { collection, _, _ in
            self.add(collection, parent: parent)
        }
    }

    private func add(_ collection: PHCollection, parent: CollectionID?) {
        guard let snapshot = Self.snapshot(of: collection, parent: parent) else { return }
        snapshots.append(snapshot)
        beat?.beat()
        if let list = collection as? PHCollectionList {
            walk(PHCollection.fetchCollections(in: list, options: nil), parent: snapshot.id)
        }
    }

    /// One album or folder. Albums count hidden photos too: an album that holds a hidden
    /// photo of the user is not "only Albumist's" and must never be deleted by undo.
    static func snapshot(of collection: PHCollection, parent: CollectionID?) -> CollectionSnapshot? {
        let id = CollectionID(collection.localIdentifier)
        var capabilities: CollectionCapabilities = []
        if collection.canPerform(.addContent) { capabilities.insert(.addContent) }
        if collection.canPerform(.removeContent) { capabilities.insert(.removeContent) }
        if collection.canPerform(.rename) { capabilities.insert(.rename) }
        if collection.canPerform(.delete) { capabilities.insert(.delete) }
        if collection.canPerform(.createContent) { capabilities.insert(.createContent) }

        if let list = collection as? PHCollectionList {
            var childIDs: [CollectionID] = []
            PHCollection.fetchCollections(in: list, options: nil).enumerateObjects { child, _, _ in childIDs.append(CollectionID(child.localIdentifier)) }
            return CollectionSnapshot(id: id, title: list.localizedTitle ?? "", kind: .folder, capabilities: capabilities, parentID: parent, childIDs: childIDs)
        } else if let album = collection as? PHAssetCollection {
            var members = Set<AssetID>()
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in members.insert(AssetID(asset.localIdentifier)) }
            let kind: CollectionKind = switch album.assetCollectionType {
            case .smartAlbum: .smartAlbum
            default: album.assetCollectionSubtype == .albumRegular ? .userAlbum : .restrictedAlbum
            }
            return CollectionSnapshot(id: id, title: album.localizedTitle ?? "", kind: kind, capabilities: capabilities, parentID: parent, assetIDs: members)
        }
        return nil
    }
}
