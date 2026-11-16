import Foundation

/// What the suggestions need to know about the library as a whole.
///
/// - Where everyday photos are taken. That country, region or town is never an album of its
///   own: on the first iPhone (15.11.) "Deutschland" held 3,000 of 5,700 photos, which is the
///   whole library again, not something anyone would look for in an album list. It also keeps
///   trip names useful: a weekend in the home region is not called "Bayern".
/// - How big the library is. A theme of 15 photos stands out among 2,000, not among 50,000,
///   so the minimum sizes of themes, screenshot and document albums grow with it.
///
/// Internal to the suggestions and never shown. It decides for the dates the user left to the
/// detection in "Dein Zuhause"; a home the user chose decides for its dates (`HomeContext`).
public struct LibraryProfile: Sendable, Hashable {
    /// Countries, regions and towns (as place keys at their level) of the everyday photos.
    public var everydayPlaces: Set<PlaceKey>
    /// Photos and videos that are not screenshots or screen recordings.
    public var photoCount: Int
    public var screenshotCount: Int
    /// Burst of each photo that belongs to one. A burst is one moment: 30 frames of the same
    /// jump make no trip and no theme (`shots(in:)`).
    public var burstOf: [AssetID: String]

    /// A place holding at least this share of the photos taken outside trips is "where the user
    /// lives". A quarter, so somebody living near a border (or who moved) has two.
    static let everydayShare = 0.25
    /// Fewer photos outside trips than this say nothing about where someone lives. Small on
    /// purpose: twelve photos taken at home make "Deutschland" no better an album.
    static let minimumEverydayPhotos = 5

    public init(everydayPlaces: Set<PlaceKey> = [], photoCount: Int = 0, screenshotCount: Int = 0, burstOf: [AssetID: String] = [:]) {
        self.everydayPlaces = everydayPlaces
        self.photoCount = photoCount
        self.screenshotCount = screenshotCount
        self.burstOf = burstOf
    }

    /// - Parameters:
    ///   - facts: the facts suggestions are made from.
    ///   - trips: all detected trips, also those too small for an album: their photos are not
    ///     everyday photos either.
    public init(facts: [AssetFacts], trips: [Trip]) {
        var onTrip = Set<AssetID>()
        for trip in trips { onTrip.formUnion(trip.geotaggedAssetIDs) }
        var counts: [PlaceKey: Int] = [:]
        var everyday = 0
        var photos = 0, screenshots = 0
        var bursts: [AssetID: String] = [:]
        for f in facts {
            if f.asset.isScreenshotLike { screenshots += 1 } else { photos += 1 }
            if let burst = f.asset.burstIdentifier { bursts[f.id] = burst }
            guard !onTrip.contains(f.id), let place = f.gpsPlace else { continue }
            everyday += 1
            for level in [PlaceLevel.country, .administrativeArea, .subAdministrativeArea, .locality] {
                if let key = place.key(at: level) { counts[key, default: 0] += 1 }
            }
        }
        let needed = Double(everyday) * Self.everydayShare
        self.init(
            everydayPlaces: everyday >= Self.minimumEverydayPhotos ? Set(counts.filter { Double($0.value) >= needed }.keys) : [],
            photoCount: photos,
            screenshotCount: screenshots,
            burstOf: bursts
        )
    }

    public func isEveryday(_ key: PlaceKey) -> Bool { everydayPlaces.contains(key) }

    /// How many photos `ids` are for minimum sizes: every burst counts once.
    public func shots(in ids: some Collection<AssetID>) -> Int {
        guard !burstOf.isEmpty else { return ids.count }
        var bursts = Set<String>()
        var single = 0
        for id in ids {
            if let burst = burstOf[id] { bursts.insert(burst) } else { single += 1 }
        }
        return single + bursts.count
    }

    /// `base`, or `perMille` of `count` when that is more.
    static func scaled(_ base: Int, perMille: Double, of count: Int) -> Int {
        max(base, Int((Double(count) * perMille / 1000).rounded()))
    }
}
