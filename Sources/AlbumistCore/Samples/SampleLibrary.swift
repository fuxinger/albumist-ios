import Foundation

/// "Mit Beispielfotos ausprobieren" (plugin review K6, option 1 chosen by Fuchs, 16.11.2026):
/// an App Review device or a new iPhone with an empty or nearly empty library can try Albumist
/// with a small set of sample photos that look like a real year: everyday life at home and four
/// trips, each photo with a date and a place.
///
/// The photos really go into the Photos library (only there can Albumist make albums of them),
/// so the app says that before it adds anything. The images are drawn by Albumist itself
/// (sky, sea, hills, houses in the colours of each trip): no third-party pictures, no licence
/// question, and nothing that exists only in the simulator. Albumist writes down the
/// identifier of every sample photo it adds; "Beispielfotos wieder entfernen" deletes exactly
/// those (with the iOS question) and the albums Albumist made only of them, never anything else.
public enum SampleLibrary {
    /// What a sample photo shows (the app draws it).
    public enum Scene: String, CaseIterable, Hashable, Sendable {
        case home, beach, city, mountains, lake
    }

    public struct Spec: Hashable, Sendable {
        public var index: Int
        public var date: Date
        public var location: GeoCoordinate
        public var scene: Scene
        /// The file name Photos shows ("Albumist-Beispiel-012.jpg").
        public var filename: String { String(format: "Albumist-Beispiel-%03d.jpg", index) }
    }

    struct Trip {
        var place: GeoCoordinate
        var scene: Scene
        var year: Int, month: Int, day: Int, days: Int, photos: Int
    }

    /// Home in Hamburg, trips to Lisbon, Copenhagen, Rome and the Dolomites.
    static let home = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let trips: [Trip] = [
        Trip(place: GeoCoordinate(latitude: 41.9028, longitude: 12.4964), scene: .city, year: 2024, month: 10, day: 3, days: 4, photos: 14),
        Trip(place: GeoCoordinate(latitude: 46.5405, longitude: 11.8930), scene: .mountains, year: 2025, month: 2, day: 14, days: 5, photos: 14),
        Trip(place: GeoCoordinate(latitude: 38.7223, longitude: -9.1393), scene: .beach, year: 2025, month: 5, day: 22, days: 5, photos: 14),
        Trip(place: GeoCoordinate(latitude: 55.6761, longitude: 12.5683), scene: .lake, year: 2025, month: 8, day: 8, days: 3, photos: 12),
    ]
    static let homePhotos = 24

    /// Every sample photo, the same on every device.
    public static func specs() -> [Spec] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func date(_ y: Int, _ m: Int, _ d: Int, plusDays: Int = 0, hour: Int, minute: Int) -> Date {
            let start = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
            return calendar.date(byAdding: .day, value: plusDays, to: start)!
        }
        /// A few hundred metres around a place, deterministic.
        func near(_ c: GeoCoordinate, _ i: Int, spread: Double) -> GeoCoordinate {
            let a = Double((i * 7919) % 1000) / 1000 - 0.5, b = Double((i * 104_729) % 1000) / 1000 - 0.5
            return GeoCoordinate(latitude: c.latitude + a * spread, longitude: c.longitude + b * spread)
        }
        var result: [Spec] = []
        func add(_ d: Date, _ c: GeoCoordinate, _ scene: Scene) {
            result.append(Spec(index: result.count + 1, date: d, location: c, scene: scene))
        }
        // Everyday life at home, spread over two years: Albumist learns where home is.
        for i in 0..<homePhotos {
            let year = 2024 + i % 2, month = 1 + (i * 5) % 12
            add(date(year, month, 1 + (i * 7) % 27, hour: 9 + i % 10, minute: (i * 13) % 60), near(home, i, spread: 0.02), .home)
        }
        for trip in trips {
            for i in 0..<trip.photos {
                add(date(trip.year, trip.month, trip.day, plusDays: i % trip.days, hour: 9 + (i * 3) % 10, minute: (i * 17) % 60),
                    near(trip.place, i + result.count, spread: 0.02), trip.scene)
            }
        }
        return result
    }

    /// Below this many photos the library counts as nearly empty.
    public static let nearlyEmptyLimit = 30

    /// Offered only for an empty or nearly empty library, with full access (albums need it,
    /// and a selection would hide the sample photos), and only while none is in the library.
    public static func isOffered(photos: Int, access: LibraryAccess, samplesPresent: Bool) -> Bool {
        access == .full && !samplesPresent && photos < nearlyEmptyLimit
    }

    /// What "Beispielfotos wieder entfernen" deletes.
    public struct Removal: Hashable, Sendable {
        /// Sample photos still in the library: exactly the ones Albumist wrote down.
        public var assets: [AssetID]
        /// Albums Albumist made that hold nothing but sample photos, and the folders Albumist
        /// made that would hold nothing else afterwards.
        public var albums: [CollectionID]
        /// Plans that only made or filled those albums: their free albums are given back.
        public var plansToGiveBack: [AlbumistID]

        public var isEmpty: Bool { assets.isEmpty && albums.isEmpty }
    }

    /// - Parameters:
    ///   - sampleIDs: the identifiers Albumist wrote down when it added the sample photos.
    ///   - libraryAssets: the photos in the library now (nil when unknown: all written-down ones).
    ///   - managedAlbums: Albumist's records of the albums it made or extended.
    ///   - inventory: the albums in Photos now.
    ///   - history: the executed plans.
    public static func removal(sampleIDs: Set<AssetID>, libraryAssets: Set<AssetID>?, managedAlbums: [ManagedAlbumState],
                               inventory: CollectionInventory, history: [ChangePlan]) -> Removal {
        let assets = (libraryAssets.map { sampleIDs.intersection($0) } ?? sampleIDs).sorted()
        // Only albums Albumist created itself (never one it found or only extended), and only
        // while every photo in them is a sample photo: a photo the user put in keeps the album.
        let albums = managedAlbums
            .filter { $0.createdByAlbumist }
            .compactMap { inventory[$0.albumID] }
            .filter { $0.kind != .folder && !$0.assetIDs.isEmpty && $0.assetIDs.isSubset(of: sampleIDs) }
            .map(\.id)
        var going = Set(albums)
        // Folders Albumist made (never one it found after an interruption) that keep nothing
        // once those albums are gone, innermost first.
        let madeFolders = Set(history.flatMap { plan in
            plan.steps.compactMap { step -> CollectionID? in
                guard case .createFolder(let key, _, _) = step.operation, plan.record?.adoptedKeys.contains(key) != true else { return nil }
                return plan.resolvedKeys[key]
            }
        })
        var changed = !going.isEmpty
        while changed {
            changed = false
            for folder in madeFolders.sorted() where !going.contains(folder) && inventory[folder]?.kind == .folder {
                let inside = inventory.collections.values.filter { $0.parentID == folder }
                if !inside.isEmpty, inside.allSatisfy({ going.contains($0.id) }) {
                    going.insert(folder)
                    changed = true
                }
            }
        }
        // Albums before the folders they are in.
        let folders = going.subtracting(albums).sorted()
        return Removal(assets: assets, albums: albums.sorted() + folders, plansToGiveBack: plansToGiveBack(history: history, gone: Set(albums)))
    }

    /// Plans that only made or filled albums that are gone: their free albums are given back.
    /// After the deletion it is asked with the albums really gone (the change itself may have
    /// kept one, review P2-05): a plan with an album still in Photos keeps its count.
    public static func plansToGiveBack(history: [ChangePlan], gone: Set<CollectionID>) -> [AlbumistID] {
        history.filter { plan in
            guard plan.reverts == nil else { return false }
            let made = Set(plan.steps.compactMap { step -> CollectionID? in
                guard case .createAlbum(let key, _, _) = step.operation else { return nil }
                return plan.resolvedKeys[key]
            })
            let touched = made.union(plan.extendedAlbums)
            return !touched.isEmpty && touched.isSubset(of: gone)
        }.map(\.id)
    }

    // MARK: What Albumist wrote down

    /// The sample photos Albumist added, kept in the user defaults. The identifiers are written
    /// inside the same PhotoKit change that creates the photos (review of 3022ca8: an app ended
    /// between saving a chunk and writing it down left photos nobody could remove), and the
    /// start is marked before the first photo, so a cut-off add never brings the offer back.
    public struct Record: Hashable, Sendable, Codable {
        public var ids: Set<String> = []
        /// Set before the first photo is written; cleared only once nothing is left.
        public var addingStarted = false

        public init(ids: Set<String> = [], addingStarted: Bool = false) {
            self.ids = ids
            self.addingStarted = addingStarted
        }

        /// Sample photos are (or may be) in the library: no offer, "entfernen" is shown.
        public var hasSamples: Bool { addingStarted || !ids.isEmpty }

        public mutating func begin() { addingStarted = true }

        public mutating func record(_ new: Set<String>) { ids.formUnion(new) }

        /// After a removal: only what is still there stays written down. With nothing left the
        /// record is cleared, and the offer may come back.
        public mutating func keepOnly(_ existing: Set<String>) {
            ids = ids.intersection(existing)
            if ids.isEmpty { addingStarted = false }
        }
    }

    /// Why "Beispielfotos wieder entfernen" cannot run now (it says so instead of doing nothing).
    public enum RemovalBlock: Hashable, Sendable {
        /// With a selection of photos Albumist sees only part of them, and would forget the
        /// identifiers of sample photos that are still there.
        case needsFullAccess
        /// A plan is changing albums, or one was cut off: the albums to delete are decided
        /// from a settled state.
        case planInProgress
    }

    public static func removalBlock(access: LibraryAccess, planRunning: Bool, planInterrupted: Bool) -> RemovalBlock? {
        if access != .full { return .needsFullAccess }
        if planRunning || planInterrupted { return .planInProgress }
        return nil
    }

    /// Of the folders asked to be deleted, the ones that may go: deleting a folder in Photos
    /// deletes everything in it, so a folder goes only while everything inside it goes too.
    /// Checked again inside the change itself, against the children Photos has right then.
    /// - Parameters:
    ///   - folders: folder id → ids of what is inside it now.
    ///   - albums: the albums being deleted.
    public static func foldersSafeToDelete(_ folders: [String: [String]], deletingAlbums albums: Set<String>) -> Set<String> {
        var safe = Set<String>()
        var changed = true
        while changed {
            changed = false
            for (folder, children) in folders where !safe.contains(folder) {
                if children.allSatisfy({ albums.contains($0) || safe.contains($0) }) {
                    safe.insert(folder)
                    changed = true
                }
            }
        }
        return safe
    }

    // MARK: Checked again inside the deletion (review P2-05, 18.11.2026)

    /// A photo as Photos shows it inside the change that deletes it.
    public struct Seen: Hashable, Sendable {
        /// The original file name of its photo resource.
        public var filename: String?
        public var created: Date?

        public init(filename: String?, created: Date?) {
            self.filename = filename
            self.created = created
        }
    }

    /// File name → date of every sample photo.
    static let dates: [String: Date] = Dictionary(specs().map { ($0.filename, $0.date) }, uniquingKeysWith: { first, _ in first })

    /// Whether a photo is one of Albumist's sample photos: its file name is exactly a sample
    /// photo's name and it carries that photo's date (to the second). A photo of the user's,
    /// even with a written-down id, a similar name or the same date, never is.
    public static func isSample(_ seen: Seen) -> Bool {
        guard let name = seen.filename, let created = seen.created, let date = dates[name] else { return false }
        return abs(created.timeIntervalSince(date)) < 1
    }

    /// What the deletion of sample photos deletes, decided inside the change from Photos as it
    /// is right then. The written-down ids alone are never enough to delete a photo.
    public struct CheckedDeletion: Hashable, Sendable {
        /// The photos that are surely sample photos.
        public var assets: Set<String> = []
        /// The albums that hold nothing but those, and the folders that hold nothing else.
        public var collections: Set<String> = []
        /// Written-down photos that are not (any more) sample photos: they stay.
        public var kept: Set<String> = []

        public init(assets: Set<String> = [], collections: Set<String> = [], kept: Set<String> = []) {
            self.assets = assets
            self.collections = collections
            self.kept = kept
        }
    }

    /// - Parameters:
    ///   - photos: the written-down photos Photos still has, as it shows them now.
    ///   - albums: the albums to delete → the photos in each now.
    ///   - folders: the folders to delete → what is inside each now.
    public static func checkedDeletion(photos: [String: Seen], albums: [String: Set<String>], folders: [String: [String]]) -> CheckedDeletion {
        let assets = Set(photos.filter { isSample($0.value) }.keys)
        let kept = Set(photos.keys).subtracting(assets)
        // The same rule as for every deletion of albums (`DeletionCheck`): an album goes only
        // while it holds nothing but sample photos that go, a folder only while all of it goes.
        let allowed = Dictionary(uniqueKeysWithValues: albums.keys.map { (CollectionID($0), Set(assets.map { AssetID($0) })) })
        let ids = (albums.keys.sorted() + folders.keys.sorted()).map { CollectionID($0) }
        let going = DeletionCheck.going(ids, allowed: allowed,
                                        members: { id in albums[id.rawValue].map { Set($0.map { AssetID($0) }) } },
                                        children: { id in folders[id.rawValue]?.map { CollectionID($0) } })
        return CheckedDeletion(assets: assets, collections: Set(going.map(\.rawValue)), kept: kept)
    }
}
