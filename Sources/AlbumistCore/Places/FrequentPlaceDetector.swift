import Foundation

/// A place where the user photographs repeatedly (prompt §4.3).
/// Albumist never labels such a place as "home" or "work" by itself – it only reports facts.
public struct FrequentPlace: Hashable, Sendable, Codable, Identifiable {
    public var id: AlbumistID
    public var centroid: GeoCoordinate
    /// Radius covering 90 % of the photos, in metres.
    public var radiusMeters: Double
    public var assetIDs: [AssetID]
    public var distinctDays: Int
    public var firstDate: Date
    public var lastDate: Date
    /// Name given or confirmed by the user ("Zuhause", "Garten", ...). Never auto-filled.
    public var userName: String?

    public var photoCount: Int { assetIDs.count }
}

public struct FrequentPlaceDetector: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Neighbourhood radius for density clustering. Larger values treat a large
        /// premises as one place ("großes Gelände"), smaller values separate neighbours.
        public var clusterRadiusMeters: Double = 120
        public var minPhotosPerCore: Int = 4
        /// Minimum number of different days with photos.
        public var minDistinctDays: Int = 5
        /// Minimum time between first and last visit.
        public var minSpan: TimeInterval = 14 * 86_400
        /// Clusters whose centroids are closer than this are merged (user option).
        public var mergeRadiusMeters: Double = 0

        public init() {}
    }

    public var configuration: Configuration
    public var calendar: Calendar

    public init(configuration: Configuration = .init(), calendar: Calendar = .albumistDefault) {
        self.configuration = configuration
        self.calendar = calendar
    }

    /// - Parameter previous: the places of the previous analysis (`analysis.frequentPlaces`):
    ///   each place keeps the ID of the one it mostly is (`carryOver`).
    /// - Parameter zones: the time zone each photo's place tells, where one is known (review
    ///   P1-15): a place's days are those of the clocks where its photos were taken; photos
    ///   without one are read in `calendar`'s zone.
    public func detect(in assets: [AssetSnapshot], previous: [FrequentPlace] = [], zones: [AssetID: TimeZone] = [:]) -> [FrequentPlace] {
        let usable = assets.compactMap { asset -> (AssetSnapshot, GeoCoordinate, Date)? in
            guard let c = asset.usableLocation, let d = asset.creationDate else { return nil }
            return (asset, c, d)
        }
        guard !usable.isEmpty else { return [] }

        let clusterer = GeoClusterer(epsilonMeters: configuration.clusterRadiusMeters, minPoints: configuration.minPhotosPerCore)
        var groups = clusterer.cluster(usable.map(\.1)).clusters.map(\.memberIndices)

        if configuration.mergeRadiusMeters > 0 {
            groups = mergeNearby(groups, coordinates: usable.map(\.1))
        }

        let places = groups.compactMap { indices -> FrequentPlace? in
            let members = indices.map { usable[$0] }
            let days = Set(members.map { LocalTime.day(LocalTime.wallClock($0.2, in: zones[$0.0.id] ?? calendar.timeZone)) })
            guard days.count >= configuration.minDistinctDays,
                  let first = members.map(\.2).min(), let last = members.map(\.2).max(),
                  last.timeIntervalSince(first) >= configuration.minSpan,
                  let centroid = GeoMath.centroid(members.map(\.1))
            else { return nil }
            let distances = members.map { GeoMath.distance($0.1, centroid) }.sorted()
            let p90 = distances[min(distances.count - 1, Int(Double(distances.count) * 0.9))]
            let ids = members.map(\.0.id).sorted()
            return FrequentPlace(
                id: Self.cellID(of: centroid),
                centroid: centroid,
                radiusMeters: max(p90, 25),
                assetIDs: ids,
                distinctDays: days.count,
                firstDate: first,
                lastDate: last,
                userName: nil
            )
        }
        return Self.carryOver(places, from: previous).sorted(by: Self.listOrder)
    }

    /// The order the app lists places in: most days, then most photos (then the first photo,
    /// so ties do not depend on the order of the input).
    static func listOrder(_ a: FrequentPlace, _ b: FrequentPlace) -> Bool {
        if a.distinctDays != b.distinctDays { return a.distinctDays > b.distinctDays }
        if a.photoCount != b.photoCount { return a.photoCount > b.photoCount }
        return (a.assetIDs.first?.rawValue ?? "") < (b.assetIDs.first?.rawValue ?? "")
    }

    /// The ID a new place gets: its centre rounded to three decimals (a cell of about
    /// 110 m × 75 m in Munich), the identity every place had before 18.11.2026.
    static func cellID(of centroid: GeoCoordinate) -> AlbumistID {
        .stable("frequent", cellKey(of: centroid))
    }

    private static func cellKey(of centroid: GeoCoordinate) -> String {
        String(format: "%.3f,%.3f", centroid.latitude, centroid.longitude)
    }

    /// Gives each place its ID. Stored names, "Nicht jetzt", decisions and the album Albumist
    /// made are keyed by it, so a place keeps its ID by its photos, like a trip
    /// (`TripIdentity.carryOver`), and never takes over the ID of another place (review
    /// 18.11.2026, G1-04 and P1-01, and the second review of the fix).
    ///
    /// - A place keeps the ID of the place of the previous analysis (`previous`, as stored
    ///   under `analysis.frequentPlaces`, in the app's order) it shares at least half of the
    ///   smaller one's photos with. The biggest shared part is paired first (ties: the place
    ///   with the smaller first photo ID, then the earlier previous place); each previous ID
    ///   goes to one place. After a split, the bigger part keeps it.
    /// - An ID that several previous places had (two places in one cell before 18.11.) belongs
    ///   to the first of them: until then every lookup of a shared ID found the first suggestion
    ///   in this order, so its name, decisions and album are the ones the user saw.
    /// - Any other place is new: it gets its cell's ID if no place of this or the previous
    ///   analysis has it (a place alone in its cell gets the ID it had before 18.11.), else an ID
    ///   from its cell and its first photo. New places take their turn in the app's order.
    static func carryOver(_ places: [FrequentPlace], from previous: [FrequentPlace]) -> [FrequentPlace] {
        var owner: [AssetID: Int] = [:]
        var owned = Set<AlbumistID>()
        for (index, place) in previous.enumerated() where owned.insert(place.id).inserted {
            for asset in place.assetIDs where owner[asset] == nil { owner[asset] = index }
        }
        struct Pair { var shared: Int; var current: Int; var previous: Int }
        var pairs: [Pair] = []
        for (c, place) in places.enumerated() {
            var counts: [Int: Int] = [:]
            for asset in place.assetIDs {
                if let p = owner[asset] { counts[p, default: 0] += 1 }
            }
            for (p, shared) in counts where shared * 2 >= min(place.photoCount, previous[p].photoCount) {
                pairs.append(Pair(shared: shared, current: c, previous: p))
            }
        }
        func firstPhoto(_ c: Int) -> String { places[c].assetIDs.first?.rawValue ?? "" }
        pairs.sort { x, y in
            if x.shared != y.shared { return x.shared > y.shared }
            if x.current != y.current { return firstPhoto(x.current) < firstPhoto(y.current) }
            return x.previous < y.previous
        }
        var result = places
        var carried = Set<Int>(), usedPrevious = Set<Int>()
        for pair in pairs where !carried.contains(pair.current) && !usedPrevious.contains(pair.previous) {
            carried.insert(pair.current)
            usedPrevious.insert(pair.previous)
            result[pair.current].id = previous[pair.previous].id
        }
        var taken = Set(carried.map { result[$0].id }).union(previous.map(\.id))
        let new = result.indices.filter { !carried.contains($0) }.sorted { listOrder(result[$0], result[$1]) }
        for index in new {
            let key = cellKey(of: result[index].centroid), first = result[index].assetIDs.first?.rawValue ?? ""
            var id = cellID(of: result[index].centroid)
            var salt = 0
            while taken.contains(id) {
                id = salt == 0 ? .stable("frequent", key, first) : .stable("frequent", key, first, String(salt))
                salt += 1
            }
            result[index].id = id
            taken.insert(id)
        }
        return result
    }

    private func mergeNearby(_ groups: [[Int]], coordinates: [GeoCoordinate]) -> [[Int]] {
        var merged: [[Int]] = []
        var centroids: [GeoCoordinate] = []
        for group in groups {
            guard let c = GeoMath.centroid(group.map { coordinates[$0] }) else { continue }
            if let target = centroids.firstIndex(where: { GeoMath.distance($0, c) <= configuration.mergeRadiusMeters }) {
                merged[target].append(contentsOf: group)
                centroids[target] = GeoMath.centroid(merged[target].map { coordinates[$0] }) ?? centroids[target]
            } else {
                merged.append(group)
                centroids.append(c)
            }
        }
        return merged
    }
}

public extension Calendar {
    /// Gregorian calendar in the device time zone, Monday as first weekday (ISO 8601 weeks).
    static var albumistDefault: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = .current
        return calendar
    }
}
