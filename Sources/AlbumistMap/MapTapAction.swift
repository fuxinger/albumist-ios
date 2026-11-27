import Foundation
import AlbumistCore

/// What tapping a pin on the map does (Fuchs, 26.11.2026: "Die Ziele kann ich hier auch nicht
/// klicken"; the map must work for laypeople). Every pin answers a tap:
/// - a group of several pins zooms in on them,
/// - a world region zooms in on it,
/// - a country opens its trips and photos,
/// - a trip opens the trip (with its one main button),
/// - a place opens its photos.
public enum MapTapAction: Hashable, Sendable {
    case zoom(MapFocus)
    case showRegion(WorldRegion)
    case showCountry(String)
    case showTrip(AlbumistID)
    case showPlace(trip: AlbumistID, placeIndex: Int)

    /// The smallest zoom target: closer than this, a map shows streets, not places of a trip.
    public static let minimumZoomRadiusMeters = 5_000.0
    /// The zoom target is this much wider than the group's pins, so none sits at the edge.
    public static let zoomMargin = 1.3

    /// The action for a tapped group. `pins` are the pins the group was made of, by id (members
    /// not among them are left out). A pin missing what its level needs (a country pin without a
    /// country) zooms in on itself instead of doing nothing.
    public static func action(for group: MapPinGroup, pins: [String: MapPin]) -> MapTapAction {
        let members = group.memberIDs.compactMap { pins[$0] }
        guard members.count > 1 else { return action(for: members.first ?? group.pin) }
        let coordinates = members.map(\.coordinate).filter(\.isPlausible)
        let center = GeoMath.centroid(coordinates) ?? group.pin.coordinate
        let spread = coordinates.reduce(0) { max($0, GeoMath.distance(center, $1)) }
        // Pins on one spot stay one group however far the map zooms in: a tap opens them
        // instead (their trip, or the pin with the most photos) and never does nothing.
        if spread < sameSpotMeters {
            let trips = Set(members.compactMap(\.tripID))
            if trips.count == 1, let trip = trips.first, members.allSatisfy({ $0.tripID != nil }) { return .showTrip(trip) }
            let best = members.max { a, b in a.count != b.count ? a.count < b.count : a.id > b.id }
            return action(for: best ?? group.pin)
        }
        return zoom(on: coordinates)
    }

    /// Group members closer together than this count as one spot.
    public static let sameSpotMeters = 2_500.0

    public static func action(for pin: MapPin) -> MapTapAction {
        switch pin.level {
        case .worldRegion:
            if let region = pin.region { return .showRegion(region) }
        case .country:
            if let key = pin.countryKey { return .showCountry(key) }
        case .trip:
            if let trip = pin.tripID { return .showTrip(trip) }
        case .place:
            if let trip = pin.tripID, let index = pin.placeIndex { return .showPlace(trip: trip, placeIndex: index) }
            if let trip = pin.tripID { return .showTrip(trip) }
        }
        return zoom(on: [pin.coordinate])
    }

    static func zoom(on coordinates: [GeoCoordinate]) -> MapTapAction {
        let points = coordinates.filter(\.isPlausible)
        let center = GeoMath.centroid(points) ?? points.first ?? GeoCoordinate(latitude: 0, longitude: 0)
        let farthest = points.reduce(0) { max($0, GeoMath.distance(center, $1)) }
        return .zoom(MapFocus(center: center, radiusMeters: max(minimumZoomRadiusMeters, farthest * zoomMargin)))
    }
}
