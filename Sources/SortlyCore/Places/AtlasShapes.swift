import Foundation

/// One shape of the travel atlas map: a country a visit fills, or a disputed area that is
/// painted as unvisited land over the countries it lies in (decision Fuchs 18.11.2026; review
/// of bundle-i, 19.11.: Crimea lit up with Russia, Northern Cyprus with Cyprus, Kashmir with
/// India and Pakistan, in the atlas and in the share picture).
public struct AtlasShape: Sendable, Hashable {
    /// The two-letter code a visit fills. Empty for a shape no visit fills: a disputed area the
    /// map draws as a country of its own (Taiwan, Kosovo, Northern Cyprus, Western Sahara,
    /// Siachen), a map area without a code, and every neutral shape.
    public let code: String
    public let rings: [[GeoCoordinate]]
    /// For a disputed area inside other countries' shapes: their codes. Drawn after the visited
    /// countries in the colour of unvisited land, and only inside these countries' shapes.
    public let neutralOver: Set<String>

    public var isNeutral: Bool { !neutralOver.isEmpty }

    /// Even-odd containment over all rings, like the map draws them.
    public func contains(_ c: GeoCoordinate) -> Bool {
        rings.reduce(false) { $0 != DisputedArea.contains($1.map { ($0.latitude, $0.longitude) }, c.latitude, c.longitude) }
    }
}

public enum AtlasShapes {
    /// Every country of the map (not Antarctica), then the neutral shapes of the disputed
    /// areas: the map's regions in them (Crimea in Russia, Kashmir's parts in India and
    /// Pakistan, Abkhazia in Georgia) and the outlines drawn over land (Western Sahara over
    /// Morocco, Aksai Chin over China and India, the Golan over Israel). Outlines over the sea
    /// only (the waters of Crimea) are left out: they would draw land on the sea.
    public static func make(from map: OfflineWorldMap, minimumStepDegrees: Double = 0.3) -> [AtlasShape] {
        func code(_ region: OfflineWorldMap.Region) -> String {
            DisputedAreas.area(mapCountry: region.nameEN, mapRegion: nil) == nil ? String(region.isoCode.prefix(2)).uppercased() : ""
        }
        let countries = map.regions.filter { $0.level == .country && $0.isoCode != "AQ" }
        var shapes = countries.map { AtlasShape(code: code($0), rings: map.outline(of: $0, minimumStepDegrees: minimumStepDegrees), neutralOver: []) }
        for area in DisputedAreas.all {
            for region in map.regions where region.level == .region && area.mapRegions.contains(region.isoCode) {
                guard let parent = region.parent.map({ code(map.regions[$0]) }), !parent.isEmpty else { continue }
                let rings = map.outline(of: region, minimumStepDegrees: minimumStepDegrees)
                if !rings.isEmpty { shapes.append(AtlasShape(code: "", rings: rings, neutralOver: [parent])) }
            }
            let over = Set(countries.filter { area.outlineCountries.contains($0.nameEN) }.map(code).filter { !$0.isEmpty })
            if !over.isEmpty, !area.outlines.isEmpty {
                let rings = area.outlines.map { $0.map { GeoCoordinate(latitude: $0.0, longitude: $0.1) } }
                shapes.append(AtlasShape(code: "", rings: rings, neutralOver: over))
            }
        }
        return shapes
    }

    /// The visited country the map shows filled at `point`, or nil (unvisited land, the sea, or
    /// a disputed area). The atlas map draws by the same rule.
    public static func filledCode(at point: GeoCoordinate, in shapes: [AtlasShape], visited: Set<String>) -> String? {
        guard let country = shapes.first(where: { !$0.isNeutral && visited.contains($0.code) && $0.contains(point) }) else { return nil }
        if shapes.contains(where: { $0.neutralOver.contains(country.code) && $0.contains(point) }) { return nil }
        return country.code
    }
}
