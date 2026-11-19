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

    /// The disputed area (`DisputedArea.id`) of a map country the area makes up, or of a
    /// neutral shape; nil for every other shape. A tap there opens nothing.
    public let disputedArea: String?
    /// Each ring's box, so a tap looks only at the rings near the finger.
    private let boxes: [Box]

    struct Box: Hashable, Sendable {
        var minLat = Double.infinity, maxLat = -Double.infinity, minLon = Double.infinity, maxLon = -Double.infinity
        func distance(to c: GeoCoordinate) -> Double {
            hypot(max(minLon - c.longitude, 0, c.longitude - maxLon), max(minLat - c.latitude, 0, c.latitude - maxLat))
        }
    }

    public init(code: String, rings: [[GeoCoordinate]], neutralOver: Set<String> = [], disputedArea: String? = nil) {
        self.code = code
        self.rings = rings
        self.neutralOver = neutralOver
        self.disputedArea = disputedArea
        boxes = rings.map { ring in
            ring.reduce(into: Box()) { box, c in
                box.minLat = min(box.minLat, c.latitude); box.maxLat = max(box.maxLat, c.latitude)
                box.minLon = min(box.minLon, c.longitude); box.maxLon = max(box.maxLon, c.longitude)
            }
        }
    }

    public var isNeutral: Bool { !neutralOver.isEmpty }

    /// Even-odd containment over all rings, like the map draws them (the test of
    /// `DisputedArea.contains`, without copying the ring: the map's Russia has 26,000 points).
    /// A ring whose box does not hold the point cannot hold it.
    public func contains(_ c: GeoCoordinate) -> Bool {
        var inside = false
        for (ring, box) in zip(rings, boxes) where box.distance(to: c) == 0 {
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.latitude > c.latitude) != (b.latitude > c.latitude),
                   c.longitude < (b.longitude - a.longitude) * (c.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// Distance in degrees (as the flat map draws them) to the nearest coast or border of the
    /// shape, looking only at rings within `limit`; nil beyond it. A nearest point for which
    /// `skipping` is true does not count.
    func edgeDistance(to c: GeoCoordinate, within limit: Double, skipping: (GeoCoordinate) -> Bool = { _ in false }) -> Double? {
        var best: Double?
        for (ring, box) in zip(rings, boxes) where box.distance(to: c) <= limit {
            guard var a = ring.last else { continue }
            for b in ring {
                let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude, length = dx * dx + dy * dy
                let t = length == 0 ? 0 : max(0, min(1, ((c.longitude - a.longitude) * dx + (c.latitude - a.latitude) * dy) / length))
                let d = hypot(c.longitude - a.longitude - t * dx, c.latitude - a.latitude - t * dy)
                if d <= limit, d < (best ?? .infinity),
                   !skipping(GeoCoordinate(latitude: a.latitude + t * dy, longitude: a.longitude + t * dx)) { best = d }
                a = b
            }
        }
        return best
    }

    /// Whether `c` lies in the shape or within `margin` degrees of its edge.
    func covers(_ c: GeoCoordinate, margin: Double) -> Bool {
        boxes.contains { $0.distance(to: c) <= margin } && (contains(c) || edgeDistance(to: c, within: margin) != nil)
    }
}

public enum AtlasShapes {
    /// Every country of the map (not Antarctica), then the neutral shapes of the disputed
    /// areas: the map's regions in them (Crimea in Russia, Kashmir's parts in India and
    /// Pakistan, Abkhazia in Georgia) and the outlines drawn over land (Western Sahara over
    /// Morocco, Aksai Chin over China and India, the Golan over Israel). Outlines over the sea
    /// only (the waters of Crimea) are left out: they would draw land on the sea.
    ///
    /// A country with disputed regions in it (Russia, India, Pakistan, Georgia) and those regions
    /// keep every point of the map: simplified each on its own, their shared coasts and borders
    /// no longer met, and the visited fill showed in the gaps (review of b376999: a strip
    /// between Sevastopol and the rest of the Crimea, slivers off Yevpatoria and at Perekop).
    public static func make(from map: OfflineWorldMap, minimumStepDegrees: Double = 0.3) -> [AtlasShape] {
        func area(_ region: OfflineWorldMap.Region) -> String? { DisputedAreas.area(mapCountry: region.nameEN, mapRegion: nil)?.id }
        func code(_ region: OfflineWorldMap.Region) -> String {
            DisputedAreas.area(mapCountry: region.nameEN, mapRegion: nil) == nil ? String(region.isoCode.prefix(2)).uppercased() : ""
        }
        let countries = map.regions.filter { $0.level == .country && $0.isoCode != "AQ" }
        let disputedRegions = map.regions.filter { region in
            region.level == .region && DisputedAreas.all.contains { $0.mapRegions.contains(region.isoCode) }
        }
        let cut = Set(disputedRegions.compactMap { $0.parent.map { code(map.regions[$0]) } })
        var shapes = countries.map { country in
            AtlasShape(code: code(country), rings: map.outline(of: country, minimumStepDegrees: cut.contains(code(country)) ? 0 : minimumStepDegrees),
                       disputedArea: area(country))
        }
        for area in DisputedAreas.all {
            for region in disputedRegions where area.mapRegions.contains(region.isoCode) {
                guard let parent = region.parent.map({ code(map.regions[$0]) }), !parent.isEmpty else { continue }
                let rings = map.outline(of: region)
                if !rings.isEmpty { shapes.append(AtlasShape(code: "", rings: rings, neutralOver: [parent], disputedArea: area.id)) }
            }
            let over = Set(countries.filter { area.outlineCountries.contains($0.nameEN) }.map(code).filter { !$0.isEmpty })
            if !over.isEmpty, !area.outlines.isEmpty {
                let rings = area.outlines.map { $0.map { GeoCoordinate(latitude: $0.0, longitude: $0.1) } }
                shapes.append(AtlasShape(code: "", rings: rings, neutralOver: over, disputedArea: area.id))
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

    /// The disputed area at `point` as the map draws it: a map country the area makes up, or a
    /// neutral shape inside one of the countries it is painted over; nil elsewhere.
    public static func disputedArea(at point: GeoCoordinate, in shapes: [AtlasShape]) -> String? {
        for shape in shapes where shape.disputedArea != nil && shape.contains(point) {
            if !shape.isNeutral { return shape.disputedArea }
            if shapes.contains(where: { !$0.isNeutral && shape.neutralOver.contains($0.code) && $0.contains(point) }) { return shape.disputedArea }
        }
        return nil
    }

    /// The country screen a tap at `point` opens: the visited country there, else the visited
    /// country whose coast or border is nearest within `slackDegrees` (small countries are hard
    /// to hit). Nothing in a disputed area: it is never a side's country (decision Fuchs
    /// 18.11.2026; second review of bundle-i: a tap on the grey Crimea opened "Russland"), and
    /// it has no screen of its own. The atlas map's taps go through here.
    public static func tappedCode(at point: GeoCoordinate, in shapes: [AtlasShape], visited: Set<String>, slackDegrees: Double) -> String? {
        if disputedArea(at: point, in: shapes) != nil { return nil }
        let candidates = shapes.filter { !$0.isNeutral && !$0.code.isEmpty && visited.contains($0.code) }
        if let hit = candidates.first(where: { $0.contains(point) }) { return hit.code }
        // Measured to what the map fills: a coast or border along a disputed area in the
        // country is the area's (review of b376999: a tap on the sea off the grey Crimea opened
        // Russia). The margin covers the coarse outlines of the areas and the map's 0.3° steps,
        // so the country's own coast a few kilometres across a strait may not count either.
        let areas = shapes.filter(\.isNeutral)
        return candidates.compactMap { shape in
            let own = areas.filter { $0.neutralOver.contains(shape.code) }
            return shape.edgeDistance(to: point, within: slackDegrees, skipping: { q in own.contains { $0.covers(q, margin: 0.35) } })
                .map { (shape.code, $0) }
        }
        .min { $0.1 < $1.1 }?.0
    }
}
