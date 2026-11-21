import Foundation

extension Trip {
    /// A trip made outside the detector, with the values the detector stores: for the map's demo
    /// trip on the prototype page (concept 2.0 §13, a made-up trip round Iceland), which another
    /// module builds and so cannot call the memberwise initializer.
    public static func make(id: AlbumistID, start: Date, end: Date, geotaggedAssetIDs: [AssetID], inferredAssetIDs: [AssetID] = [],
                            centroid: GeoCoordinate, maxDistanceFromHomeMeters: Double, distinctStops: Int, kind: TripKind) -> Trip {
        Trip(id: id, start: start, end: end, geotaggedAssetIDs: geotaggedAssetIDs, inferredAssetIDs: inferredAssetIDs, centroid: centroid,
             maxDistanceFromHomeMeters: maxDistanceFromHomeMeters, distinctStops: distinctStops, kind: kind)
    }
}
