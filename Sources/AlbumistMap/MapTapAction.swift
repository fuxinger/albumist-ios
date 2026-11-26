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
        if members.count > 1 { return zoom(on: members.map(\.coordinate)) }
        return action(for: members.first ?? group.pin)
    }

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
