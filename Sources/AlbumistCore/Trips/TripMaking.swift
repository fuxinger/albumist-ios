import Foundation

extension Trip {
    /// A trip made outside the detector, with the values the detector stores: for the map's demo
    /// trip on the prototype page (concept 2.0 §13, a made-up trip round Iceland), which another
    /// module builds and so cannot call the memberwise initializer.
    public static func make(id: AlbumistID, start: Date, end: Date, geotaggedAssetIDs: [AssetID], inferredAssetIDs: [AssetID] = [],
                            profile: Profile) -> Trip {
        Trip(id: id, start: start, end: end, geotaggedAssetIDs: geotaggedAssetIDs, inferredAssetIDs: inferredAssetIDs, centroid: profile.centroid,
             maxDistanceFromHomeMeters: profile.maxDistanceFromHomeMeters, distinctStops: profile.distinctStops, kind: profile.kind)
    }

    /// What the detector works out from a trip's photos besides their ids and their time: where
    /// they centre, how far from home they reach, how many overnight stops they make and what kind
    /// of trip that makes (`Trip.make`).
    public struct Profile: Hashable, Sendable {
        public var centroid: GeoCoordinate
        public var maxDistanceFromHomeMeters: Double
        public var distinctStops: Int
        public var kind: TripKind

        public init(centroid: GeoCoordinate, maxDistanceFromHomeMeters: Double, distinctStops: Int, kind: TripKind) {
            self.centroid = centroid
            self.maxDistanceFromHomeMeters = maxDistanceFromHomeMeters
            self.distinctStops = distinctStops
            self.kind = kind
        }
    }
}
