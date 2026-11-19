import Foundation

/// The time zone of a place known only from the offline map (review P1-15): its country's zone
/// from the IANA time zone database, and in a country with several zones the zone whose
/// reference place is nearest (`CountryTimeZoneTable.swift`, made by
/// `tools/gen_country_time_zones.py` from zone.tab and the places in
/// `tools/country_time_zones_extra.txt`). Within some 50 km of a border between two zones it can
/// be the neighbouring zone (Bullhead City, Arizona, gets the time of Laughlin, Nevada, across
/// the river); the online lookup names the place's own zone, which wins (`LocalTime.zone(of:at:)`).
public enum CountryTimeZones {
    struct Reference: Sendable {
        let zone: String
        let latitude: Double
        let longitude: Double
        /// The place as a point on the unit sphere: the nearest place to a photo is the one with
        /// the largest dot product (the smallest great-circle distance), without a sine per place.
        let point: (x: Double, y: Double, z: Double)

        /// The only zone of a country: no place needed.
        init(_ zone: String) {
            self.init(zone, .nan, .nan)
        }

        init(_ zone: String, _ latitude: Double, _ longitude: Double) {
            self.zone = zone
            self.latitude = latitude
            self.longitude = longitude
            point = Self.unit(latitude, longitude)
        }

        static func unit(_ latitude: Double, _ longitude: Double) -> (x: Double, y: Double, z: Double) {
            let φ = latitude * .pi / 180, λ = longitude * .pi / 180
            return (cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
        }
    }

    /// The IANA identifier of the zone a place in `country` (ISO 3166 code) is in. A country with
    /// several zones needs the place: it is rounded to 0.01° (about a kilometre) first, so photos a
    /// few metres apart never get different zones. Nil for a code the table does not know, and in
    /// a country with several zones without a place. Only zones this system knows count (`usable`).
    public static func zone(country: String, near coordinate: GeoCoordinate?) -> String? {
        guard let references = usable[country.uppercased()], let first = references.first else { return nil }
        guard references.count > 1 else { return first.zone }
        guard let coordinate else { return nil }
        let rounded = rounded(coordinate)
        let p = Reference.unit(rounded.latitude, rounded.longitude)
        var best = first.zone, closest = -Double.infinity
        for reference in references {
            let q = reference.point
            let dot = q.x * p.x + q.y * p.y + q.z * p.z
            if dot > closest { (best, closest) = (reference.zone, dot) }
        }
        return best
    }

    /// The zone of a disputed area (`DisputedAreas`, which has no country code): that of the clocks
    /// there. Nil for the areas the table leaves out (Kashmir, the Golan Heights, Abkhazia).
    public static func zone(disputedArea: String, near coordinate: GeoCoordinate?) -> String? {
        areas[disputedArea].flatMap { zone(country: $0, near: coordinate) }
    }

    /// Whether the zone of a place in `country` depends on where in the country it is.
    public static func dependsOnPlace(country: String) -> Bool {
        (usable[country.uppercased()]?.count ?? 0) > 1
    }

    /// The table without the zones this system's time zone database does not know: one newer than
    /// the database (America/Coyhaique, tzdata 2025b, on an older system) would leave its places
    /// without a zone, so they get the nearest zone of the country the system knows.
    static let usable: [String: [Reference]] = {
        var known: [String: Bool] = [:]
        return table.compactMapValues { references in
            let kept = references.filter { reference in
                if let k = known[reference.zone] { return k }
                let k = TimeZone(identifier: reference.zone) != nil
                known[reference.zone] = k
                return k
            }
            guard let zone = kept.first?.zone else { return nil }
            return kept.allSatisfy { $0.zone == zone } ? [Reference(zone)] : kept
        }
    }()

    /// The place `zone(country:near:)` measures from.
    static func rounded(_ c: GeoCoordinate) -> GeoCoordinate {
        GeoCoordinate(latitude: (c.latitude * 100).rounded() / 100, longitude: (c.longitude * 100).rounded() / 100)
    }

    /// Every zone the table names.
    static var allZones: Set<String> { Set(table.values.flatMap { $0.map(\.zone) }) }
}
