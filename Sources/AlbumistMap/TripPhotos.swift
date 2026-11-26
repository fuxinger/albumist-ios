import Foundation
import AlbumistCore

/// The photos of one trip on the map for laypeople: all of them in time order, and per place of
/// the trip (`TripGeometry.places`) those taken nearest to it. A station of the film
/// (`TripFilmStation`) shows the photos of all its places. Photos without a location belong to
/// the trip but to no place; photos without a date come last.
public struct TripPhotos: Hashable, Sendable {
    public var all: [AssetID]
    /// Index = place index.
    public var byPlace: [[AssetID]]

    public init(all: [AssetID], byPlace: [[AssetID]]) {
        self.all = all
        self.byPlace = byPlace
    }

    /// `facts` may be the whole library; only the trip's own photos (`AssetFacts.tripID`) count.
    public static func collect(geometry: TripGeometry, facts: [AssetFacts]) -> TripPhotos {
        let own = facts.filter { $0.tripID == geometry.id }
        return collect(geometry: geometry, ownFacts: own)
    }

    /// `ownFacts`: the trip's photos only (say, grouped once for all trips).
    public static func collect(geometry: TripGeometry, ownFacts: [AssetFacts]) -> TripPhotos {
        let sorted = ownFacts.sorted { a, b in
            let (da, db) = (a.asset.creationDate ?? .distantFuture, b.asset.creationDate ?? .distantFuture)
            return da != db ? da < db : a.asset.id.rawValue < b.asset.id.rawValue
        }
        var byPlace = Array(repeating: [AssetID](), count: geometry.places.count)
        let places = geometry.places.enumerated().filter { $0.element.coordinate.isPlausible }
        for fact in sorted {
            guard let location = fact.asset.location, location.isPlausible else { continue }
            let nearest = places.min { GeoMath.distance($0.element.coordinate, location) < GeoMath.distance($1.element.coordinate, location) }
            if let nearest { byPlace[nearest.offset].append(fact.asset.id) }
        }
        return TripPhotos(all: sorted.map(\.asset.id), byPlace: byPlace)
    }

    /// The photos of these places, in time order (the order of `all`).
    public func photos(ofPlaces indices: [Int]) -> [AssetID] {
        let wanted = Set(indices.filter { byPlace.indices.contains($0) }.flatMap { byPlace[$0] })
        return all.filter { wanted.contains($0) }
    }
}
