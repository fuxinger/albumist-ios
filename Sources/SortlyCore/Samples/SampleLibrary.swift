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
        public var plansToGiveBack: [SortlyID]

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
            .filter { $0.createdBySortly }
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
        let plans = history.filter { plan in
            guard plan.reverts == nil else { return false }
            let made = Set(plan.steps.compactMap { step -> CollectionID? in
                guard case .createAlbum(let key, _, _) = step.operation else { return nil }
                return plan.resolvedKeys[key]
            })
            let touched = made.union(plan.extendedAlbums)
            return !touched.isEmpty && touched.isSubset(of: Set(albums))
        }
        // Albums before the folders they are in.
        let folders = going.subtracting(albums).sorted()
        return Removal(assets: assets, albums: albums.sorted() + folders, plansToGiveBack: plans.map(\.id))
    }
}
