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
    /// Changes the value in one step (a get and a set apart could lose a change in between).
    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
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

    /// A read a change makes before its change request (does the album or folder exist):
    /// without an answer, nothing of the call reached Photos as a change, and the executor
    /// leaves the step as it was (`PhotosNotResponding.beforeAnyChange`, review of f7439fb,
    /// SF1). Before, such a step stayed running, and adding to the user's own album was then
    /// settled as "outcome unclear" although nothing had been sent.
    static func readBeforeChange<T: Sendable>(_ what: String, _ work: @escaping @Sendable (PhotosDeadline.Heartbeat) throws -> T) async throws -> T {
        do {
            return try await read(what, work)
        } catch let quiet as PhotosNotResponding {
            throw quiet.beforeAnyChange
        }
    }

    /// PHAsset is thread-safe but not marked Sendable; a fetched asset is only handed on.
    struct FetchedAssets: @unchecked Sendable {
        let assets: [PHAsset]
    }

    /// The photos among `ids` that Photos knows, fetched on the image lane (`imageFetchLimit`):
    /// for one photo's image (the analysis, the atlas cover), apart from the plan's reads.
    /// Throws `PhotosNotResponding` when Photos does not answer in time.
    /// `lane`: `.thumbnail` for pictures on screen, so a hanging one never stops the analysis.
    static func fetchAssets(_ ids: [AssetID], what: String = "fetchAsset", lane: PhotosDeadline.Lane = .image) async throws -> FetchedAssets {
        try await read(what, limit: imageFetchLimit, lane: lane) { _ in
            var assets: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
                .enumerateObjects { asset, _, _ in assets.append(asset) }
            return FetchedAssets(assets: assets)
        }
    }

    /// One change request, bounded. Without an answer in time the caller gets
    /// `PhotosNotResponding`: the outcome is not known (Photos may still carry it out), and no
    /// other change goes out until this one has returned (`PhotosDeadline`).
    /// `answered` runs once Photos answers, also after the caller stopped waiting.
    static func change(_ what: String, limit: Duration = writeLimit, asksUser: Bool = false,
                       answered: (@Sendable () -> Void)? = nil,
                       _ block: @escaping @Sendable () -> Void) async throws {
        try await deadline.run(what, lane: .write, limit: limit, reportsSlow: !asksUser) { _ in
            defer { answered?() }
            try await PHPhotoLibrary.shared().performChanges(block)
        }
    }

    /// Ids of new albums and folders whose create request returned in this launch, also after
    /// its caller stopped waiting: such an album is there or never comes (`createAnswered`).
    private static let answeredCreates = LockedBox<Set<String>>([])

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
            try Self.readAssets(includeHidden: includeHidden, knownDetails: knownDetails, stopped: { beat.isCancelled }) { read, total in
                beat.beat()
                return progress(read, total)
            }
        }
    }

    /// `stopped`: nobody waits for the read any more (it runs on the deadline's queue, where
    /// `Task.isCancelled` is always false).
    private static func readAssets(includeHidden: Bool, knownDetails: [AssetID: Date], stopped isStopped: @escaping () -> Bool,
                                   progress: @escaping (Int, Int) -> Bool) throws -> [AssetSnapshot] {
        let options = libraryOptions(includeHidden: includeHidden)
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
            if Task.isCancelled || isStopped() {
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
        if isStopped() { throw CancellationError() }
        return snapshots
    }

    /// The photos a whole read returns: the user's own library (and synced from a computer),
    /// hidden ones only when the user lets Albumist see them.
    private static let librarySources: PHAssetSourceType = [.typeUserLibrary, .typeiTunesSynced]

    private static func libraryOptions(includeHidden: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = includeHidden
        options.includeAssetSourceTypes = librarySources
        // A burst as the whole read sees it, also when fetched by identifier (Photos' default,
        // set here so both reads say so).
        options.includeAllBurstAssets = false
        return options
    }

    // MARK: Changes since the last run (review P4-03)

    // Photos keeps a history of its changes (iOS 16): a run reads only the photos added,
    // changed or deleted since the token stored with the last read, instead of every photo
    // and every album at every launch. A token that is too old or of another library, or any
    // error, gets `nil`: the run reads the whole library, as before. Asked only with full
    // access (`AnalysisPipeline.readChanges`).

    /// Photos' change token now, archived (`PHPersistentChangeToken` is `NSSecureCoding`).
    func changeMark() async -> LibraryChangeMark? {
        try? await Self.read("changeMark") { _ -> LibraryChangeMark? in
            Self.mark(PHPhotoLibrary.shared().currentChangeToken)
        }
    }

    private static func mark(_ token: PHPersistentChangeToken) -> LibraryChangeMark? {
        (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)).map { LibraryChangeMark($0) }
    }

    /// Bounded like every read; every change in the history is a sign of progress.
    func changes(since mark: LibraryChangeMark, limit: Int) async throws -> LibraryChanges? {
        let data = mark.data
        return try await Self.read("libraryChanges") { beat -> LibraryChanges? in
            guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data),
                  // Taken before the history is read: a change made meanwhile is read next time too.
                  let now = Self.mark(PHPhotoLibrary.shared().currentChangeToken) else { return nil }
            let history: PHPersistentChangeFetchResult
            do {
                history = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            } catch {
                // `persistentChangeTokenExpired`, `persistentChangeDetailsUnavailable`, a token of
                // another library: not known.
                return nil
            }
            var out = LibraryChanges(mark: now)
            var known = true
            history.enumerateChanges { change, stop in
                if beat.isCancelled {
                    known = false
                    stop.pointee = true
                    return
                }
                do {
                    // Oldest first: a photo deleted after a change counts as deleted, one added
                    // again after a deletion as changed. The pipeline asks for both kinds again
                    // either way, so the order only saves work.
                    let assets = try change.changeDetails(for: .asset)
                    let changed = Set(assets.insertedLocalIdentifiers.union(assets.updatedLocalIdentifiers).map { AssetID($0) })
                    let deleted = Set(assets.deletedLocalIdentifiers.map { AssetID($0) })
                    out.assets.subtract(deleted)
                    out.deleted.formUnion(deleted)
                    out.deleted.subtract(changed)
                    out.assets.formUnion(changed)
                    if out.assets.count + out.deleted.count > limit {
                        // More than the caller reads one by one: stop here, without holding the rest.
                        out = LibraryChanges(mark: out.mark, tooMany: true)
                        stop.pointee = true
                        return
                    }
                    var named = !changed.isEmpty || !deleted.isEmpty
                    for type in [PHObjectType.assetCollection, .collectionList] {
                        let details = try change.changeDetails(for: type)
                        if !details.insertedLocalIdentifiers.isEmpty || !details.updatedLocalIdentifiers.isEmpty
                            || !details.deletedLocalIdentifiers.isEmpty {
                            out.other = true
                            named = true
                        }
                    }
                    // A change that names nothing of these: something changed all the same.
                    // How often Photos writes such changes (iCloud, its own housekeeping) is
                    // not measured: if a quiet library always has some, the albums are walked
                    // every run (as before this change). To measure on a device (TEST_PLAN 📱).
                    if !named { out.other = true }
                } catch {
                    known = false
                    stop.pointee = true
                }
                beat.beat()
            }
            if beat.isCancelled { throw CancellationError() }
            return known ? out : nil
        }
    }

    /// Fetched by identifier with the whole read's options (`libraryOptions`, also for bursts),
    /// then held to its rules by hand as well: whether a fetch by identifier leaves out hidden
    /// photos or other sources is not taken on trust. Bounded like `fetchAssets`, every photo a sign of progress.
    func fetchAssets(_ ids: Set<AssetID>, includeHidden: Bool, knownDetails: [AssetID: Date],
                     progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> ChangedAssets {
        let wanted = ids.map(\.rawValue).sorted()
        return try await Self.read("fetchChangedAssets") { beat -> ChangedAssets in
            let options = Self.libraryOptions(includeHidden: includeHidden)
            var snapshots: [AssetSnapshot] = []
            var paused = false
            for start in stride(from: 0, to: wanted.count, by: 500) {
                if beat.isCancelled { throw CancellationError() }
                let chunk = Array(wanted[start..<min(start + 500, wanted.count)])
                PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: options).enumerateObjects { asset, _, stop in
                    if beat.isCancelled {
                        stop.pointee = true
                        return
                    }
                    guard includeHidden || !asset.isHidden, Self.librarySources.contains(asset.sourceType) else { return }
                    autoreleasepool {
                        let needsResources = knownDetails[AssetID(asset.localIdentifier)].map { known in
                            !AssetSnapshot.sameModification(known, asset.modificationDate)
                        } ?? true
                        snapshots.append(Self.snapshot(asset, withResources: needsResources))
                    }
                    beat.beat()
                    // Pause, as in the whole read (fewer photos, so more often).
                    if snapshots.count % 50 == 0, !progress(snapshots.count, wanted.count) {
                        paused = true
                        stop.pointee = true
                    }
                }
                if paused { throw LibraryReadPaused(read: snapshots) }
            }
            if beat.isCancelled { throw CancellationError() }
            // How many photos a whole read would return: the pipeline checks the store against it.
            let count = PHAsset.fetchAssets(with: options).count
            return ChangedAssets(assets: snapshots, libraryCount: count)
        }
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
                if beat.isCancelled { throw CancellationError() }
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

    func createAnswered(_ id: CollectionID) async -> Bool {
        Self.answeredCreates.value.contains(id.rawValue)
    }

    /// Notes that the create that gave Photos `id` returned.
    private static func noteAnswered(_ id: String?) {
        guard let id else { return }
        answeredCreates.update { $0.insert(id) }
    }

    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await createFolder(title: title, parent: parent, noted: { _ in })
    }

    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await createAlbum(title: title, parent: parent, noted: { _ in })
    }

    /// `noted` hears the placeholder's id inside the change block, before Photos commits it, and
    /// the block waits for it (`waitInsideChange`): the executor writes the id into the plan's
    /// journal there, the way the sample photos write theirs down (`SamplePhotos.save`). An app
    /// ended right after Photos made the album, or a request without an answer in time, leaves
    /// the id behind, and the album is known as Albumist's (`ExecutionRecord.maybeCreated`,
    /// review P2-01).
    func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
        let created = LockedBox<String?>(nil)
        let parentID = parent?.rawValue
        try await Self.readBeforeChange("requireFolder") { _ in try Self.requireFolder(parentID) }
        try await Self.change("createFolder", answered: { Self.noteAnswered(created.value) }) {
            // Into its folder or not at all (see `parentRequest`).
            guard let folder = Self.parentRequest(parentID) else { return }
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let placeholder = request.placeholderForCreatedCollectionList
            created.value = placeholder.localIdentifier
            let made = CollectionID(placeholder.localIdentifier)
            Self.waitInsideChange { await noted(made) }
            folder?.addChildCollections([placeholder] as NSArray)
        }
        guard let id = created.value else { throw parentID.map { PhotoKitError.collectionNotFound($0) } ?? PhotoKitError.changeFailed("folder") }
        return CollectionID(id)
    }

    func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
        let created = LockedBox<String?>(nil)
        let parentID = parent?.rawValue
        try await Self.readBeforeChange("requireFolder") { _ in try Self.requireFolder(parentID) }
        try await Self.change("createAlbum", answered: { Self.noteAnswered(created.value) }) {
            // Into its folder or not at all (see `parentRequest`).
            guard let folder = Self.parentRequest(parentID) else { return }
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let placeholder = request.placeholderForCreatedAssetCollection
            created.value = placeholder.localIdentifier
            let made = CollectionID(placeholder.localIdentifier)
            Self.waitInsideChange { await noted(made) }
            folder?.addChildCollections([placeholder] as NSArray)
        }
        guard let id = created.value else { throw parentID.map { PhotoKitError.collectionNotFound($0) } ?? PhotoKitError.changeFailed("album") }
        return CollectionID(id)
    }

    /// Inside a change block: runs `work` (writing the new id into the journal) and waits for
    /// it, so it is on disk before Photos stores the change. Photos runs change blocks on its
    /// own serial queue, never on Swift's shared pool, so waiting there holds none of the
    /// threads `work` needs. At most `limit`: a journal that does not answer must not hold up
    /// Photos; the id is then written once the create returns, as before (review P2-01).
    private static func waitInsideChange(limit: TimeInterval = 10, _ work: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await work()
            done.signal()
        }
        _ = done.wait(timeout: .now() + limit)
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
        let exists = try await Self.readBeforeChange("album") { _ -> Bool in
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
        try await deleteCollections(ids, onlyHolding: [:])
    }

    /// `allowed`: what each album may hold when the change counts again (review P2-08).
    func deleteCollections(_ ids: [CollectionID], onlyHolding allowed: [CollectionID: Set<AssetID>]) async throws {
        let allowedRaw: [String: Set<String>] = Dictionary(uniqueKeysWithValues: allowed.map { ($0.key.rawValue, Set($0.value.map(\.rawValue))) })
        var log = DeletionLog.Entry(requested: ids.count)
        defer { DeletionLog.record(log) }
        // Before any request: no answer here means nothing of this call reached Photos.
        var target: DeletionTarget
        do {
            target = try await Self.deletableNow(ids.map(\.rawValue), log: &log)
        } catch let quiet as PhotosNotResponding {
            log.outcome = quiet.neverBegan ? "not sent (tree read never began)" : "not sent (no answer to the tree read)"
            throw quiet.beforeAnyChange
        } catch {
            log.outcome = "error before the request"
            throw error
        }
        guard !target.isEmpty else {
            log.outcome = "nothing deletable"
            return
        }
        // Once the first request went out, nothing after it in this call is "not sent": the
        // read-back, the second walk of the tree and a second request report the deletion as
        // not known (`afterAChangeWasSent`, review of 045f297, M2). Before, a read-back that got
        // no thread made the executor forget the albums it had deleted, and undo lost them.
        var sentOnce = false
        do {
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
                        // Counted again here, in the change itself (as `SamplePhotos.delete` does for
                        // folders): an album that got a photo it may not hold since it was read
                        // (the 30 s wait for the screen above, iCloud) stays, and so does every folder
                        // holding it. Only the time the iOS question is open is left (P2-08).
                        let going = Self.stillGoing(request, allowed: allowedRaw)
                        // Deletes only the album/folder containers. PhotoKit keeps the media.
                        if !going.albums.isEmpty { PHAssetCollectionChangeRequest.deleteAssetCollections(going.albums as NSArray) }
                        if !going.folders.isEmpty { PHCollectionListChangeRequest.deleteCollectionLists(going.folders as NSArray) }
                    }
                } catch let hung as PhotosNotResponding {
                    log.seconds.append(Date().timeIntervalSince(started))
                    // Never sent (no thread in time, or an earlier change hangs): not "no answer".
                    log.outcome = hung.neverBegan ? "not sent (never began)" : hung.notSent ? "not sent" : "no answer"
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
                sentOnce = true
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
        } catch let quiet as PhotosNotResponding where sentOnce {
            // A second request has its outcome logged above; a read after a request has not.
            if quiet.lane != .write { log.outcome = "no answer after the request (\(quiet.what))" }
            throw quiet.afterAChangeWasSent
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

    /// Inside a change block: the part of `target` that may still go now (`DeletionCheck.going`),
    /// read from Photos as it is at this moment. An album with an entry in `allowed` goes only
    /// while it holds nothing else; a folder only while everything in it goes too.
    private static func stillGoing(_ target: DeletionTarget, allowed: [String: Set<String>]) -> DeletionTarget {
        var members: [CollectionID: Set<AssetID>] = [:]
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        for album in target.albums where allowed[album.localIdentifier] != nil {
            var inside = Set<AssetID>()
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in inside.insert(AssetID(asset.localIdentifier)) }
            members[CollectionID(album.localIdentifier)] = inside
        }
        var children: [CollectionID: [CollectionID]] = [:]
        for folder in target.folders {
            var inside: [CollectionID] = []
            PHCollection.fetchCollections(in: folder, options: nil).enumerateObjects { child, _, _ in inside.append(CollectionID(child.localIdentifier)) }
            children[CollectionID(folder.localIdentifier)] = inside
        }
        let albumIDs = Set(target.albums.map { CollectionID($0.localIdentifier) })
        let may = Dictionary(uniqueKeysWithValues: allowed.map { (CollectionID($0.key), Set($0.value.map { AssetID($0) })) })
        let going = Set(DeletionCheck.going(target.ids.map { CollectionID($0) }, allowed: may, members: { id in
            albumIDs.contains(id) ? members[id] ?? [] : nil
        }, children: { children[$0] }))
        var result = DeletionTarget()
        result.albums = target.albums.filter { going.contains(CollectionID($0.localIdentifier)) }
        result.folders = target.folders.filter { going.contains(CollectionID($0.localIdentifier)) }
        return result
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
        let holdsSomething = try await Self.readBeforeChange("folderContents") { _ -> Bool in
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
        // Nobody waits for the walk any more: it stops (the result is dropped anyway).
        if beat?.isCancelled == true { return }
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
