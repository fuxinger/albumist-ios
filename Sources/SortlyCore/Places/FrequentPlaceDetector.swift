import Foundation

/// A place where the user photographs repeatedly (prompt §4.3).
/// Albumist never labels such a place as "home" or "work" by itself – it only reports facts.
public struct FrequentPlace: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
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

    public init(configuration: Configuration = .init(), calendar: Calendar = .sortlyDefault) {
        self.configuration = configuration
        self.calendar = calendar
    }

    public func detect(in assets: [AssetSnapshot]) -> [FrequentPlace] {
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
            let days = Set(members.map { calendar.startOfDay(for: $0.2) })
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
        return Self.separatingSharedIDs(places)
            .sorted { ($0.distinctDays, $0.photoCount) > ($1.distinctDays, $1.photoCount) }
    }

    /// A place's identity: its centre rounded to three decimals (a cell of about 110 m × 75 m in
    /// Munich). Stored names, "Nicht jetzt" and decisions are keyed by it, so it is the same
    /// for the same photos in every analysis, and it is the identity places had before 18.11.2026.
    static func cellID(of centroid: GeoCoordinate) -> SortlyID {
        .stable("frequent", cellKey(of: centroid))
    }

    private static func cellKey(of centroid: GeoCoordinate) -> String {
        String(format: "%.3f,%.3f", centroid.latitude, centroid.longitude)
    }

    /// Places are told apart from 120 m on, but the centres of two of them up to about 150 m
    /// apart can round to the same cell, and both had one ID: a name, "Nicht jetzt" or a
    /// decision for one applied to both (review 18.11.2026, G1-04 and P1-01). Within one cell
    /// the place photographed first keeps the cell's ID, so every ID stored before stays with
    /// one place and a place alone in its cell keeps its ID as it was; each further place gets
    /// the cell and its rank by first photo (2, 3, …). Photos taken later do not change the
    /// first photo of a place, so the ranks do not swap between analyses. Ties are
    /// broken by the centre and the photos, never by the order of the input.
    static func separatingSharedIDs(_ places: [FrequentPlace]) -> [FrequentPlace] {
        var result = places
        let shared = Dictionary(grouping: places.indices, by: { places[$0].id }).values.filter { $0.count > 1 }
        for indices in shared {
            let ranked = indices.sorted { a, b in
                let pa = places[a], pb = places[b]
                if pa.firstDate != pb.firstDate { return pa.firstDate < pb.firstDate }
                if pa.centroid.latitude != pb.centroid.latitude { return pa.centroid.latitude < pb.centroid.latitude }
                if pa.centroid.longitude != pb.centroid.longitude { return pa.centroid.longitude < pb.centroid.longitude }
                return pa.assetIDs.lexicographicallyPrecedes(pb.assetIDs)
            }
            let key = cellKey(of: places[ranked[0]].centroid)
            for (rank, index) in ranked.enumerated() where rank > 0 {
                result[index].id = .stable("frequent", key, String(rank + 1))
            }
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
    static var sortlyDefault: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = .current
        return calendar
    }
}
