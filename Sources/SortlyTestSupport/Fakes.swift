import Foundation
import Synchronization
import SortlyCore

/// Fake geocoder: answers from a table of nearest fixture places, records calls.
public final class FakeGeocoder: ReverseGeocoding, @unchecked Sendable {
    public let lock = Mutex<[GeoCoordinate]>([])
    public var failures: [GeocodingError] = []
    public let answers: [(GeoCoordinate, PlaceComponents)]

    public init(failures: [GeocodingError] = [], answers: [(GeoCoordinate, PlaceComponents)] = FakeGeocoder.defaultAnswers) {
        self.failures = failures
        self.answers = answers
    }

    public static let defaultAnswers: [(GeoCoordinate, PlaceComponents)] = [
        (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Germany", administrativeArea: "Bavaria", locality: "München")),
        (Fixture.Places.rome, .init(isoCountryCode: "IT", country: "Italy", administrativeArea: "Lazio", locality: "Rom")),
        (GeoCoordinate(latitude: 47.5903, longitude: 7.5893), .init(isoCountryCode: "CH", country: "Switzerland", administrativeArea: "Basel-City", locality: "Basel")),
        (Fixture.Places.gardaLake, .init(isoCountryCode: "IT", country: "Italy", administrativeArea: "Veneto", locality: "Malcesine")),
    ]

    public var calls: [GeoCoordinate] { lock.withLock { $0 } }

    public func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        let failure: GeocodingError? = lock.withLock { calls in
            calls.append(coordinate)
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure { throw failure }
        return answers.min { GeoMath.distance(coordinate, $0.0) < GeoMath.distance(coordinate, $1.0) }?.1
    }
}

public actor MemoryPlaceCache: PlaceCaching {
    public var cells: [String: PlaceComponents] = [:]
    public init() {}
    public func cachedPlace(cell: GeoCell) async throws -> PlaceComponents? { cells[cell.description] }
    public func cachePlace(_ components: PlaceComponents, cell: GeoCell, resolvedAt: Date) async throws { cells[cell.description] = components }
}

/// Manual time: sleeping advances the clock instantly.
public final class ManualTime: @unchecked Sendable {
    public let now = Mutex<Duration>(.zero)
    public init() {}
    public var source: TimeSource {
        TimeSource(elapsed: { self.now.withLock { $0 } }, sleep: { d in self.now.withLock { $0 += d } })
    }
}

public actor ResultCollector {
    public var places: [AssetID: ResolvedPlace] = [:]
    public init() {}
    public func add(_ batch: [AssetID: ResolvedPlace]) { places.merge(batch) { $1 } }
}


/// Photo library reader backed by fixtures.
///
/// Keeps a change history like PhotoKit's (`changes(since:)`): every `set` notes what it
/// changed. `expireHistory()` forgets it (an expired token), `history: false` has none (every
/// run reads the whole library). Counts its work: whole reads, photos read, album walks.
public actor InMemoryLibraryReader: PhotoLibraryReading {
    public private(set) var assets: [AssetSnapshot]
    public private(set) var inventory: CollectionInventory
    public var accessLevel: LibraryAccess
    /// Photos in the Hidden album: only read when the user lets Albumist see them.
    public private(set) var hidden: Set<AssetID>

    /// Whole reads of the library (`fetchAssets(includeHidden:knownDetails:)`).
    public private(set) var wholeReads = 0
    /// Photos read, in whole reads and in reads of changed photos.
    public private(set) var photosRead = 0
    /// Walks over all albums (`currentInventory`).
    public private(set) var inventoryReads = 0

    private let hasHistory: Bool
    /// Tells this library's marks from another one's.
    private let libraryID = UUID()
    private var history: [LibraryChanges] = []
    /// Marks before this are gone (`expireHistory`).
    private var historyStart = 0

    public init(assets: [AssetSnapshot], inventory: CollectionInventory = CollectionInventory(), access: LibraryAccess = .full,
                hidden: Set<AssetID> = [], history: Bool = true) {
        self.assets = assets
        self.inventory = inventory
        self.accessLevel = access
        self.hidden = hidden
        self.hasHistory = history
    }

    public func set(assets new: [AssetSnapshot]) {
        let old = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.map(\.id))
        note(assets: Set(new.filter { old[$0.id] != $0 }.map(\.id)), deleted: Set(old.keys).subtracting(newIDs))
        assets = new
    }
    public func set(inventory new: CollectionInventory) {
        if new != inventory { note(other: true) }
        inventory = new
    }
    public func set(access: LibraryAccess) { accessLevel = access }
    /// Called for each photo a read of changed photos reads (a test pauses there).
    private var onChangedRead: (@Sendable (AssetID) -> Void)?
    public func set(onChangedRead hook: (@Sendable (AssetID) -> Void)?) { onChangedRead = hook }
    public func set(hidden new: Set<AssetID>) {
        note(assets: new.symmetricDifference(hidden))
        hidden = new
    }
    /// The history before now is gone: a mark from before gets no answer (PhotoKit's
    /// `persistentChangeTokenExpired`).
    public func expireHistory() { historyStart = history.count }

    private func note(assets changed: Set<AssetID> = [], deleted: Set<AssetID> = [], other: Bool = false) {
        guard !changed.isEmpty || !deleted.isEmpty || other else { return }
        history.append(LibraryChanges(assets: changed, deleted: deleted, other: other, mark: mark(history.count + 1)))
    }

    private func mark(_ position: Int) -> LibraryChangeMark {
        LibraryChangeMark(Data("\(libraryID.uuidString)|\(position)".utf8))
    }

    private func readable(_ asset: AssetSnapshot, includeHidden: Bool) -> Bool {
        includeHidden || !hidden.contains(asset.id)
    }

    /// Like PhotoKit: file details (name, type, RAW flag) only for assets that are new to the
    /// store or changed since their details were stored.
    private func read(_ asset: AssetSnapshot, knownDetails: [AssetID: Date]) -> AssetSnapshot {
        photosRead += 1
        guard let known = knownDetails[asset.id], AssetSnapshot.sameModification(known, asset.modificationDate) else { return asset }
        var bare = asset
        bare.uniformTypeIdentifier = nil
        bare.originalFilename = nil
        bare.subtypes.remove(.raw)
        return bare
    }

    public func access() async -> LibraryAccess { accessLevel }
    public func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] {
        wholeReads += 1
        return assets.filter { readable($0, includeHidden: includeHidden) }.map { read($0, knownDetails: knownDetails) }
    }
    public func currentInventory() async throws -> CollectionInventory {
        inventoryReads += 1
        return inventory
    }

    public func changeMark() async -> LibraryChangeMark? {
        hasHistory ? mark(history.count) : nil
    }

    public func changes(since mark: LibraryChangeMark) async throws -> LibraryChanges? {
        guard hasHistory else { return nil }
        let parts = String(decoding: mark.data, as: UTF8.self).split(separator: "|")
        guard parts.count == 2, parts[0] == Substring(libraryID.uuidString), let position = Int(parts[1]),
              position >= historyStart, position <= history.count else { return nil }
        var out = LibraryChanges(mark: self.mark(history.count))
        for change in history[position...] {
            // A photo deleted and back (or added after it was deleted) is read again; one
            // changed and then deleted is gone.
            out.assets.subtract(change.deleted)
            out.deleted.formUnion(change.deleted)
            out.deleted.subtract(change.assets)
            out.assets.formUnion(change.assets)
            out.other = out.other || change.other
        }
        return out
    }

    public func fetchAssets(_ ids: Set<AssetID>, includeHidden: Bool, knownDetails: [AssetID: Date],
                            progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> ChangedAssets {
        let visible = assets.filter { readable($0, includeHidden: includeHidden) }
        var read: [AssetSnapshot] = []
        for asset in visible where ids.contains(asset.id) {
            read.append(self.read(asset, knownDetails: knownDetails))
            onChangedRead?(asset.id)
            if !progress(read.count, ids.count) { throw LibraryReadPaused(read: read) }
        }
        return ChangedAssets(assets: read, libraryCount: visible.count)
    }
}

/// Deterministic content analyzer: labels and text come from closures, chosen assets are
/// "only in iCloud" and need the network for text recognition.
public final class FakeContentAnalyzer: ContentAnalyzing, @unchecked Sendable {
    public let labels: @Sendable (AssetSnapshot) -> [LabelScore]
    public let text: @Sendable (AssetSnapshot) -> String
    public let cloudOnly: Set<AssetID>
    public let counts = Mutex<(content: Int, text: Int)>((0, 0))

    public init(
        cloudOnly: Set<AssetID> = [],
        labels: @escaping @Sendable (AssetSnapshot) -> [LabelScore] = { _ in [] },
        text: @escaping @Sendable (AssetSnapshot) -> String = { _ in "" }
    ) {
        self.cloudOnly = cloudOnly
        self.labels = labels
        self.text = text
    }

    public func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        counts.withLock { $0.content += 1 }
        let labels = request.classify ? labels(asset) : []
        return ContentAnalysis(labels: labels, looksLikeDocument: labels.contains { $0.identifier == "document" }, source: .localPreview)
    }

    public func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        counts.withLock { $0.text += 1 }
        if cloudOnly.contains(asset.id) && !allowNetwork { throw AnalysisError.originalNotAvailable }
        return TextAnalysis(text: text(asset), source: .original)
    }
}

/// Device conditions for tests: optionally pauses after a number of checks.
public final class FakeConditions: AnalysisConditions, @unchecked Sendable {
    public let state = Mutex<(checks: Int, pauseAfter: Int?, wifi: Bool)>((0, nil, true))

    public init(pauseAfterChecks: Int? = nil, wifi: Bool = true) {
        state.withLock { $0 = (0, pauseAfterChecks, wifi) }
    }

    public func set(pauseAfterChecks: Int?, wifi: Bool = true) {
        state.withLock { $0 = (0, pauseAfterChecks, wifi) }
    }

    public func pauseReason() async -> PauseReason? {
        state.withLock { s in
            s.checks += 1
            if let limit = s.pauseAfter, s.checks > limit { return .thermal }
            return nil
        }
    }

    /// Scripted answers for runs in the app, one per check; the last one stays. Empty: the
    /// thermal pause above ends the run, as before.
    public let paces = Mutex<[AnalysisPace]>([])
    public let paceChecks = Mutex(0)

    public func pace() async -> AnalysisPace {
        paceChecks.withLock { $0 += 1 }
        let scripted: AnalysisPace? = paces.withLock { list in
            guard let first = list.first else { return nil }
            if list.count > 1 { list.removeFirst() }
            return first
        }
        if let scripted { return scripted }
        if let reason = await pauseReason() { return .stop(reason) }
        return .normal
    }

    public func isOnWiFi() async -> Bool { state.withLock { $0.wifi } }
}
