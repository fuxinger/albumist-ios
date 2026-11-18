import Foundation

/// An area whose country is disputed (decision Fuchs 18.11.2026, review P1-11): Albumist says
/// "nicht sicher" there instead of taking one side's view. The offline map (Natural Earth in its
/// default view) put Yalta in "Russland" and El Aaiún in "Marokko" and called that certain;
/// Apple's lookup answers differently depending on the country of the device. A photo in such an
/// area gets the area's own neutral name in place of a country ("Krim", "Westsahara"), no country
/// code, no region, and its country suggestion is "Unsicher": it is never chosen for the user
/// and never counted as a country in the travel atlas. Towns keep their names.
public struct DisputedArea: Sendable, Hashable, Identifiable {
    /// Stable id, stored with a place (`PlaceComponents.disputedArea`) and part of its key, so
    /// the suggestion keeps its id when the language of album names changes.
    public let id: String
    public let nameDE: String
    public let nameEN: String
    public let continent: Continent
    /// Countries of the offline map (by English name) that lie wholly in the area.
    let mapCountries: Set<String>
    /// First-level regions of the offline map (by code) that lie wholly in the area.
    let mapRegions: Set<String>
    /// Outlines (latitude, longitude) for the parts the map does not draw on their own. Coarse,
    /// a few kilometres: they follow the lines of control, not the coast.
    let outlines: [[(Double, Double)]]

    public func name(_ language: TitleLanguage) -> String { language == .german ? nameDE : nameEN }

    public static func == (lhs: DisputedArea, rhs: DisputedArea) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Whether `coordinate` lies inside one of the area's own outlines.
    func outlineContains(_ coordinate: GeoCoordinate) -> Bool {
        outlines.contains { Self.contains($0, coordinate.latitude, coordinate.longitude) }
    }

    /// Even-odd ray casting in plain degrees (the outlines are small and far from the date line).
    static func contains(_ ring: [(Double, Double)], _ lat: Double, _ lon: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let (yi, xi) = ring[i], (yj, xj) = ring[j]
            if (yi > lat) != (yj > lat), lon < (xj - xi) * (lat - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// The disputed areas Albumist knows. A new one is one entry here plus a test point in
/// `DisputedAreaTests`.
public enum DisputedAreas {
    public static let all: [DisputedArea] = [
        DisputedArea(id: "crimea", nameDE: "Krim", nameEN: "Crimea", continent: .europe,
                     mapCountries: [], mapRegions: ["UA-43", "UA-40"], outlines: []),
        DisputedArea(id: "western-sahara", nameDE: "Westsahara", nameEN: "Western Sahara", continent: .africa,
                     mapCountries: ["Western Sahara"], mapRegions: [],
                     // 27°40' N with Morocco, 8°40' W, 26° N, 12° W, 23°27' N, 13° W and 21°20' N with
                     // Mauritania; to the west over the sea, short of the Canary Islands.
                     outlines: [[(27.667, -13.60), (27.667, -8.667), (26.0, -8.667), (26.0, -12.0), (23.45, -12.0),
                                 (23.45, -13.0), (21.333, -15.0), (21.333, -17.06), (21.333, -17.4), (23.5, -16.6),
                                 (26.0, -15.0), (27.3, -13.85)]]),
        DisputedArea(id: "kashmir", nameDE: "Kaschmir", nameEN: "Kashmir", continent: .asia,
                     mapCountries: ["Siachen Glacier"], mapRegions: ["IN-JK", "IN-LA", "PK-JK", "PK-GB"],
                     // Aksai Chin, which the map counts to Xinjiang.
                     outlines: [[(35.65, 77.80), (35.95, 78.40), (35.60, 79.20), (35.30, 80.10), (34.75, 80.25),
                                 (34.30, 79.50), (34.40, 78.80), (34.95, 78.30), (35.40, 77.95)]]),
        DisputedArea(id: "northern-cyprus", nameDE: "Nordzypern", nameEN: "Northern Cyprus", continent: .europe,
                     mapCountries: ["Turkish Republic of Northern Cyprus"], mapRegions: [], outlines: []),
        DisputedArea(id: "kosovo", nameDE: "Kosovo", nameEN: "Kosovo", continent: .europe,
                     mapCountries: ["Kosovo"], mapRegions: [], outlines: []),
        DisputedArea(id: "taiwan", nameDE: "Taiwan", nameEN: "Taiwan", continent: .asia,
                     mapCountries: ["Taiwan"], mapRegions: [], outlines: []),
        DisputedArea(id: "golan", nameDE: "Golanhöhen", nameEN: "Golan Heights", continent: .asia,
                     mapCountries: [], mapRegions: [],
                     // The part west of the 1974 line of separation; the map counts it to Israel.
                     outlines: [[(33.31, 35.70), (33.33, 35.78), (33.29, 35.85), (33.10, 35.81), (32.95, 35.86),
                                 (32.80, 35.84), (32.70, 35.78), (32.68, 35.65), (32.83, 35.645), (32.90, 35.63),
                                 (33.05, 35.62), (33.20, 35.63), (33.25, 35.65)]]),
        DisputedArea(id: "abkhazia", nameDE: "Abchasien", nameEN: "Abkhazia", continent: .asia,
                     mapCountries: [], mapRegions: ["GE-AB"], outlines: []),
    ]

    private static let byID: [String: DisputedArea] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func area(id: String) -> DisputedArea? { byID[id] }

    /// The area of a map country or first-level region, if it is disputed.
    static func area(mapCountry: String?, mapRegion: String?) -> DisputedArea? {
        all.first { area in
            (mapCountry.map(area.mapCountries.contains) ?? false) || (mapRegion.map(area.mapRegions.contains) ?? false)
        }
    }

    /// The area whose own outline holds `coordinate`.
    static func area(outlineContaining coordinate: GeoCoordinate) -> DisputedArea? {
        all.first { $0.outlineContains(coordinate) }
    }
}

extension PlaceComponents {
    /// `self` for a place in `area`: the area's name in place of a country, no country code and
    /// no region (both would take a side), the rest (town, district, time zone) as it is.
    public func inDisputedArea(_ area: DisputedArea, language: TitleLanguage) -> PlaceComponents {
        var result = self
        result.isoCountryCode = nil
        result.country = area.name(language)
        result.administrativeArea = nil
        result.administrativeAreaKey = nil
        result.disputedArea = area.id
        return result
    }
}
