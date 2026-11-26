import Foundation
import AlbumistCore

extension CountryGeometry {
    /// Every country's land area and a point well inside it, per two-letter ISO code, from the
    /// offline world map (Natural Earth, simplified to about 330 m). Worked out once per app
    /// start, in well under a second for the whole map.
    ///
    /// - A country is every region of the map with its code but the disputed ones, which are no
    ///   country in the app (decision 18.11.2026). The map gives several regions one code:
    ///   Clipperton Island and France "FR", three territories and Australia "AU", Baikonur and
    ///   Kazakhstan "KZ", Somaliland and Somalia "SO", Northern Cyprus and Cyprus "CY". So
    ///   `OfflineWorldMap.country(code:)`, which answers with the first of them that is not
    ///   disputed, is right for Cyprus but would make France Clipperton Island: small, with its
    ///   middle in the Pacific. Codes that are not two letters (the map's unclaimed areas and
    ///   military bases) are left out.
    /// - The area: its rings' areas on the sphere, the holes (enclaves: Lesotho in South Africa,
    ///   San Marino in Italy, Azerbaijan's in Armenia) taken away (`CountryGeometryBuilder.Shape`).
    /// - The centre: the pole of inaccessibility of its largest ring, the main land, with the
    ///   holes kept out: the point inside farthest from coast and borders, found coarsely. Not
    ///   the plain centroid, which can lie outside (Croatia's lies in Bosnia, an island state's in
    ///   the sea).
    public init(map: OfflineWorldMap) {
        var areas: [String: Double] = [:]
        var centers: [String: GeoCoordinate] = [:]
        for country in CountryGeometryBuilder.countries(of: map) {
            areas[country.code] = country.squareKilometers
            centers[country.code] = country.center
        }
        self.init(squareKilometers: areas, centers: centers)
    }
}

/// The work of `CountryGeometry(map:)`.
enum CountryGeometryBuilder {
    struct Country: Hashable, Sendable {
        var code: String
        var squareKilometers: Double
        var center: GeoCoordinate
    }

    /// The countries of `map`, by code.
    static func countries(of map: OfflineWorldMap) -> [Country] {
        var regionsByCode: [String: [OfflineWorldMap.Region]] = [:]
        for region in map.regions where region.level == .country {
            let code = region.isoCode.uppercased()
            guard isCountryCode(code) else { continue }
            regionsByCode[code, default: []].append(region)
        }
        return regionsByCode.keys.sorted().compactMap { code in
            country(code, shapes: (regionsByCode[code] ?? []).map { Shape(rings: map.outline(of: $0)) }, map: map)
        }
    }

    /// A country of the regions with one code, in the map's order.
    static func country(_ code: String, shapes: [Shape], map: OfflineWorldMap) -> Country? {
        var kept = shapes.filter { $0.center != nil }
        // Which region is disputed only the map's lookup knows (the list of disputed areas is the
        // core's own): asked at each region's own middle, it names the disputed area there. A
        // code of only disputed regions (Taiwan, Western Sahara, Kosovo) keeps them, as
        // `OfflineWorldMap.country(code:)` does: places there carry no code, so no home's
        // country is ever one of these.
        if kept.count > 1 {
            let undisputed = kept.filter { shape in shape.center.map { map.lookup($0).disputedArea == nil } ?? false }
            if !undisputed.isEmpty { kept = undisputed }
        }
        // The first of equally large main lands, in the map's order.
        guard let main = kept.max(by: { $0.largestArea < $1.largestArea }), let center = main.center else { return nil }
        let steradians = kept.reduce(0) { $0 + $1.area }
        let squareKilometers = steradians * GeoMath.earthRadiusMeters * GeoMath.earthRadiusMeters / 1_000_000
        return Country(code: code, squareKilometers: squareKilometers, center: center)
    }

    /// Two letters A to Z: an ISO 3166-1 alpha-2 code ("-99" and "" are not).
    static func isCountryCode(_ code: String) -> Bool {
        code.unicodeScalars.count == 2 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }

    // MARK: Area

    /// One region of the map: its rings with their areas, which of them are holes, and its middle.
    ///
    /// The map's rings carry no hole flag (they are read with the even-odd rule), but each keeps
    /// the turning sense of Natural Earth's polygons, where holes turn the other way round than
    /// land. So a ring turning against the region's largest ring is a hole (the test
    /// `holesTurnAgainstTheirLand` checks that for every ring of the map against containment).
    struct Shape: Sendable {
        let rings: [[GeoCoordinate]]
        /// Per ring, its area on the sphere in steradians.
        let ringAreas: [Double]
        /// Per ring, whether it is a hole.
        let holes: [Bool]
        /// The ring with the largest area (the first of equally large ones), nil without rings.
        let largest: Int?
        /// The pole of inaccessibility of the largest ring; nil without rings.
        let center: GeoCoordinate?
        /// What finding `center` cost.
        let work: SearchWork

        init(rings: [[GeoCoordinate]]) {
            let signed = rings.map(CountryGeometryBuilder.signedArea)
            var largest: Int?
            for i in signed.indices where largest.map({ abs(signed[i]) > abs(signed[$0]) }) ?? true { largest = i }
            let land = largest.map { signed[$0] >= 0 } ?? true
            let holes = signed.map { ($0 >= 0) != land }
            var work = SearchWork()
            self.rings = rings
            self.ringAreas = signed.map { abs($0) }
            self.holes = holes
            self.largest = largest
            self.center = largest.map { CountryGeometryBuilder.poleOfInaccessibility(rings, outer: $0, holes: holes, work: &work) }
            self.work = work
        }

        /// Land: the rings' areas, holes taken away.
        var area: Double {
            max(0, ringAreas.indices.reduce(0) { $0 + (holes[$1] ? -ringAreas[$1] : ringAreas[$1]) })
        }

        var largestArea: Double { largest.map { ringAreas[$0] } ?? 0 }
    }

    /// The area of a ring on the unit sphere, signed by the way it turns: the spherical excess
    /// summed over the triangles of each edge with the south pole (d3-geo's `geoArea`, after
    /// Todhunter, Spherical Trigonometry (1871), §103). Right across the antimeridian (only sine
    /// and cosine of longitude differences enter) and for a ring round the south pole
    /// (Antarctica's). Of the two parts a ring cuts the sphere into, the smaller one counts: no
    /// country is larger than a hemisphere.
    static func signedArea(_ ring: [GeoCoordinate]) -> Double {
        guard ring.count >= 3, let last = ring.last else { return 0 }
        var sum = 0.0
        // Of the previous point: its longitude, and half its angular distance from the south pole.
        var lambda0 = last.longitude * .pi / 180
        let halfColatitude0 = last.latitude * .pi / 360 + .pi / 4
        var cosPhi0 = cos(halfColatitude0), sinPhi0 = sin(halfColatitude0)
        for point in ring {
            let lambda = point.longitude * .pi / 180
            let halfColatitude = point.latitude * .pi / 360 + .pi / 4
            let dLambda = lambda - lambda0
            let cosPhi = cos(halfColatitude), sinPhi = sin(halfColatitude)
            let k = sinPhi0 * sinPhi
            sum += atan2(k * sin(dLambda), cosPhi0 * cosPhi + k * cos(dLambda))
            lambda0 = lambda
            cosPhi0 = cosPhi
            sinPhi0 = sinPhi
        }
        let area = 2 * sum
        // More than a hemisphere: the other part, turning the other way round.
        if abs(area) > 2 * .pi { return area > 0 ? area - 4 * .pi : area + 4 * .pi }
        return area
    }
}
