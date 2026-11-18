import Foundation
import UIKit
import SortlyCore
#if canImport(SQLite3)
import SQLite3
#endif

#if DEBUG
/// Debug builds reach Photos through a wrapper that can play device faults for the UI tests
/// (see `UITestSwitches.swift`); without a switch it only hands every call on. Release builds
/// use `PhotoKitLibrary` itself.
typealias AppPhotoLibrary = UITestPhotoLibrary
#else
typealias AppPhotoLibrary = PhotoKitLibrary
#endif

#if DEBUG

/// A thread-safe counter for the "first time" and "n-th time" rules of the switches.
final class UITestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Counts one more and returns the new count (1 for the first call).
    func next() -> Int { lock.withLock { count += 1; return count } }
    var current: Int { lock.withLock { count } }
}

// MARK: Photo library

/// The real PhotoKit library with the faults a phone can show: access reported as limited, no
/// photos at all, slow changes, a full disk after the first change, a deletion that is declined
/// or silently not carried out. Every protocol method is handed on explicitly, so none falls
/// back to a default implementation the real library replaces.
struct UITestPhotoLibrary: PhotoLibraryReading, PhotoLibraryWriting {
    private let base = PhotoKitLibrary()
    private static let deletions = UITestCounter()
    private static let changes = UITestCounter()

    init() {}

    // MARK: Access

    func access() async -> LibraryAccess { Self.reported(await base.access()) }

    func requestAccess() async -> LibraryAccess { Self.reported(await base.requestAccess()) }

    private static func reported(_ real: LibraryAccess) -> LibraryAccess {
        UITestSupport.reportsLimitedAccess && real == .full ? .limited : real
    }

    // MARK: Reading

    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] {
        if UITestSupport.emptyLibrary { return [] }
        return try await base.fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails)
    }

    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                     progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> [AssetSnapshot] {
        if UITestSupport.emptyLibrary { return [] }
        return try await base.fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails, progress: progress)
    }

    func currentInventory() async throws -> CollectionInventory {
        if UITestSupport.emptyLibrary { return CollectionInventory() }
        return try await base.currentInventory()
    }

    func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        try await base.collection(id)
    }

    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> {
        try await base.availableAssets(ids)
    }

    func canWrite() async -> Bool { await base.canWrite() }

    // MARK: Writing

    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await Self.beforeChange()
        let id = try await base.createFolder(title: title, parent: parent)
        Self.afterChange()
        return id
    }

    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        try await Self.beforeChange()
        let id = try await base.createAlbum(title: title, parent: parent)
        Self.afterChange()
        return id
    }

    /// The forms that report Photos' placeholder ID go to the real adapter too, so the
    /// executor can record "maybe created" before Photos answers.
    func createFolder(
        title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void
    ) async throws -> CollectionID {
        try await Self.beforeChange()
        let id = try await base.createFolder(title: title, parent: parent, noted: noted)
        Self.afterChange()
        return id
    }

    func createAlbum(
        title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void
    ) async throws -> CollectionID {
        try await Self.beforeChange()
        let id = try await base.createAlbum(title: title, parent: parent, noted: noted)
        Self.afterChange()
        return id
    }

    func hasUnansweredWrites() async -> Bool { await base.hasUnansweredWrites() }

    func createAnswered(_ id: CollectionID) async -> Bool { await base.createAnswered(id) }

    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws {
        try await Self.beforeChange()
        try await base.addAssets(assets, to: album)
        Self.afterChange()
    }

    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws {
        try await Self.beforeChange()
        try await base.removeAssets(assets, from: album)
        Self.afterChange()
    }

    func renameCollection(_ id: CollectionID, to title: String) async throws {
        try await Self.beforeChange()
        try await base.renameCollection(id, to: title)
        Self.afterChange()
    }

    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        try await Self.beforeChange()
        try await base.moveCollection(id, from: oldParent, to: newParent)
        Self.afterChange()
    }

    func deleteCollection(_ id: CollectionID) async throws {
        try await Self.beforeChange()
        try await base.deleteCollection(id)
        Self.afterChange()
    }

    /// The first deletion of this launch can fail the way it failed on the first iPhone: the
    /// user tapped "Nicht erlauben", or Photos reported success and kept every album (the real
    /// adapter then throws `.notApplied` after reading the albums back). Photos is not asked
    /// in either case, so the albums really stay.
    func deleteCollections(_ ids: [CollectionID]) async throws {
        try await Self.beforeChange()
        if Self.deletions.next() == 1 {
            switch UITestSupport.deletionFault {
            case "declined": throw LibraryWriteFailure.declinedByUser
            case "ignored": throw LibraryWriteFailure.notApplied
            default: break
            }
        }
        try await base.deleteCollections(ids)
        Self.afterChange()
    }

    /// The first change of a launch goes through at once and every later one waits 30 s:
    /// a test that closes the app a few seconds after "Jetzt umsetzen" then always finds one
    /// step done and the rest open, however slow the simulator is (a fixed 3 s per change
    /// let a short plan finish before the app was closed in UI run 43763236960).
    private static func beforeChange() async throws {
        guard UITestSupport.slowsPlan, changes.next() > 1 else { return }
        try await Task.sleep(for: .seconds(30))
    }

    private static func afterChange() {
        if UITestSupport.diskFullDuring == "plan" { StorageFault.fill() }
    }
}

// MARK: Analysis

/// The real analyzer with photos that cannot be read yet and documents that are only in
/// iCloud; it also fills the disk part way through an analysis when a test asks for it.
struct UITestAnalyzer: ContentAnalyzing {
    private let base: any ContentAnalyzing
    private let unreadable = UnreadablePhotos()
    private let analysed = UITestCounter()

    init(base: any ContentAnalyzing) { self.base = base }

    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        // Like a photo whose preview is still syncing: the same error the Vision analyzer
        // throws when PhotoKit hands back no image.
        if unreadable.contains(asset.id) { throw AnalysisError.unreadable }
        let result = try await base.analyzeContent(asset, request: request)
        if UITestSupport.diskFullDuring == "analysis", analysed.next() == 25 { StorageFault.fill() }
        return result
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        // Without the network the original cannot be downloaded (the Vision analyzer says the
        // same when PhotoKit reports the image as in iCloud).
        if UITestSupport.documentsOnlyInICloud, !allowNetwork { throw AnalysisError.originalNotAvailable }
        return try await base.recognizeText(asset, allowNetwork: allowNetwork)
    }

    func willAnalyze(_ upcoming: [AssetSnapshot]) async {
        await base.willAnalyze(upcoming)
    }

    func contentEnded() {
        base.contentEnded()
    }
}

/// The first `UITestSupport.unreadablePhotos` photos the analysis asks for stay unreadable for
/// the whole launch, so the overview's count is known to the test.
final class UnreadablePhotos: @unchecked Sendable {
    private let lock = NSLock()
    private var picked = Set<AssetID>()

    func contains(_ id: AssetID) -> Bool {
        let limit = UITestSupport.unreadablePhotos
        guard limit > 0 else { return false }
        return lock.withLock {
            if picked.contains(id) { return true }
            guard picked.count < limit else { return false }
            picked.insert(id)
            return true
        }
    }
}

/// No network: every lookup fails the way `SystemGeocoder` fails offline.
struct OfflineGeocoder: ReverseGeocoding {
    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        throw GeocodingError.offline
    }
}

/// The device as a script (`-SortlyUITestPace`): each check of the analysis takes the next step.
/// After the script the real device state counts again.
final class ScriptedConditions: AnalysisConditions, @unchecked Sendable {
    enum Step: String { case normal, gentle, hot, battery, lowpower }

    private let base: DeviceConditions
    private let steps: [(step: Step, checks: Int?)]
    private let checks = UITestCounter()
    /// The app went to the background: the next check ends the run (`-SortlyUITestExpireInBackground`).
    private let expired = LockedBox(false)
    /// Keeps the app awake in the background until that end has reached the model.
    private let backgroundTask = LockedBox(UIBackgroundTaskIdentifier.invalid.rawValue)

    @MainActor
    init(base: DeviceConditions, script: String, expiresInBackground: Bool) {
        self.base = base
        steps = script.split(separator: ",").compactMap { part in
            let pieces = part.split(separator: ":")
            guard let name = pieces.first, let step = Step(rawValue: String(name)) else { return nil }
            return (step, pieces.count > 1 ? Int(pieces[1]) : nil)
        }
        guard expiresInBackground else { return }
        let expired = expired, backgroundTask = backgroundTask
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // As with a background task: the app keeps running for a moment, then the
                // time is over and the run ends while the app is still in the background.
                let id = UIApplication.shared.beginBackgroundTask(withName: "Albumist UI test expiry") {
                    MainActor.assumeIsolated { ScriptedConditions.end(backgroundTask) }
                }
                backgroundTask.value = id.rawValue
                expired.value = true
            }
        }
    }

    @MainActor
    private static func end(_ task: LockedBox<Int>) {
        let id = UIBackgroundTaskIdentifier(rawValue: task.value)
        guard id != .invalid else { return }
        task.value = UIBackgroundTaskIdentifier.invalid.rawValue
        UIApplication.shared.endBackgroundTask(id)
    }

    /// The step for this check, or nil after the script.
    private func step(advancing: Bool) -> Step? {
        var index = (advancing ? checks.next() : checks.current + 1)
        for entry in steps {
            guard let count = entry.checks else { return entry.step }
            if index <= count { return entry.step }
            index -= count
        }
        return nil
    }

    func pace() async -> AnalysisPace {
        if expired.value {
            expired.value = false
            // The model needs a moment to record that the run ended (and to ask for a resume)
            // before iOS suspends the app.
            let task = backgroundTask
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                ScriptedConditions.end(task)
            }
            return .stop(.timeBudget)
        }
        guard let step = step(advancing: true) else { return await base.pace() }
        switch step {
        case .normal, .lowpower: return .normal // Low Power Mode does not stop a run in the app.
        case .gentle: return .gentle
        case .hot: return .wait(.thermal)
        case .battery: return .wait(.batteryLow)
        }
    }

    func pauseReason() async -> PauseReason? {
        switch step(advancing: false) {
        case .hot?: return .thermal
        case .battery?: return .batteryLow
        case .lowpower?: return .lowPower
        case .normal?, .gentle?: return nil
        case nil: return await base.pauseReason()
        }
    }

    func isOnWiFi() async -> Bool { await base.isOnWiFi() }
}

// MARK: Full disk

/// A full disk for Albumist's database, at the level where iOS reports it: while `isFull` is
/// set, every write to the database file and its log fails with SQLITE_FULL ("database or disk
/// is full"), exactly as on a phone without free space; reads go on. Installed as SQLite's
/// default VFS before the store opens the database. It wraps the system VFS and changes nothing
/// else; other databases in the process are left alone (`-SortlyUITestDiskFull`).
enum StorageFault {
    static let isFull = LockedBox(false)
    private static let filledOnce = LockedBox(false)

    /// Written once in `install` (before any database is opened) and under `lock` afterwards;
    /// read from SQLite's callbacks, which cannot capture context.
    private nonisolated(unsafe) static var system: UnsafeMutablePointer<sqlite3_vfs>?
    private nonisolated(unsafe) static var wrapped: [UnsafeRawPointer: UnsafeMutableRawPointer] = [:]
    private nonisolated(unsafe) static var fileMarker = ""
    private static let lock = NSLock()
    private static let methodsSize = MemoryLayout<sqlite3_io_methods>.stride

    /// The first time this launch: the disk is full until the app goes to the background.
    static func fill() {
        guard !filledOnce.value else { return }
        filledOnce.value = true
        isFull.value = true
    }

    /// `fileMarker`: only files whose path contains it (the database and its log) are affected.
    static func install(fileMarker marker: String) {
        guard system == nil, let base = sqlite3_vfs_find(nil) else { return }
        system = base
        fileMarker = marker
        let vfs = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        vfs.initialize(to: base.pointee)
        vfs.pointee.pNext = nil
        vfs.pointee.zName = UnsafePointer(strdup("albumist-uitest-disk"))
        vfs.pointee.xOpen = { _, name, file, flags, outFlags in
            guard let system = StorageFault.system, let open = system.pointee.xOpen else { return SQLITE_ERROR }
            let rc = open(system, name, file, flags, outFlags)
            guard rc == SQLITE_OK, let file, let methods = file.pointee.pMethods, let name,
                  String(cString: name).contains(StorageFault.fileMarker) else { return rc }
            file.pointee.pMethods = StorageFault.wrap(methods)
            return rc
        }
        sqlite3_vfs_register(vfs, 1)
        // Space is back once the user left the app (to clear some in Settings).
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            StorageFault.isFull.value = false
        }
    }

    /// The system's I/O table with a write that fails while the disk is full. The system
    /// table's address is kept right behind it, so the write can hand on to it.
    private static func wrap(_ original: UnsafePointer<sqlite3_io_methods>) -> UnsafePointer<sqlite3_io_methods> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = wrapped[UnsafeRawPointer(original)] {
            return UnsafePointer(existing.assumingMemoryBound(to: sqlite3_io_methods.self))
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: methodsSize + MemoryLayout<UnsafeRawPointer>.stride,
                                                   alignment: MemoryLayout<sqlite3_io_methods>.alignment)
        let methods = raw.bindMemory(to: sqlite3_io_methods.self, capacity: 1)
        methods.initialize(to: original.pointee)
        raw.storeBytes(of: UnsafeRawPointer(original), toByteOffset: methodsSize, as: UnsafeRawPointer.self)
        methods.pointee.xWrite = { file, buffer, amount, offset in
            if StorageFault.isFull.value { return SQLITE_FULL }
            guard let file, let ours = file.pointee.pMethods else { return SQLITE_IOERR }
            let original = UnsafeRawPointer(ours).load(fromByteOffset: StorageFault.methodsSize, as: UnsafeRawPointer.self)
                .assumingMemoryBound(to: sqlite3_io_methods.self)
            return original.pointee.xWrite?(file, buffer, amount, offset) ?? SQLITE_IOERR
        }
        wrapped[UnsafeRawPointer(original)] = raw
        return UnsafePointer(methods)
    }
}

#endif
