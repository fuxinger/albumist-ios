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
    /// Outlines (latitude, longitude) for the parts the map does not draw on their own, and the
    /// area's waters. Coarse, a few kilometres: they follow the lines of control, not the coast.
    let outlines: [[(Double, Double)]]
    /// The map countries (by English name) an outline may override: a point in the outline
    /// belongs to the area only where the map says one of these, or no country at all (the
    /// sea). Everywhere else the map's country stands, so a coarse outline never reaches into
    /// a neighbour (second review of 752ba07: the Golan outline took in Israeli kibbutzim of
    /// the Hula valley, Syrian-held villages east of the 1974 line and a strip of Jordan).
    let outlineCountries: Set<String>

    public func name(_ language: TitleLanguage) -> String { language == .german ? nameDE : nameEN }

    public static func == (lhs: DisputedArea, rhs: DisputedArea) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(id: String, nameDE: String, nameEN: String, continent: Continent, mapCountries: Set<String>, mapRegions: Set<String>,
         outlines: [[(Double, Double)]] = [], outlineCountries: Set<String> = []) {
        self.id = id
        self.nameDE = nameDE
        self.nameEN = nameEN
        self.continent = continent
        self.mapCountries = mapCountries
        self.mapRegions = mapRegions
        self.outlines = outlines
        self.outlineCountries = outlineCountries
    }

    /// Whether `coordinate`, which the map gives to `mapCountry` (nil: no country, the sea),
    /// lies inside one of the area's own outlines where they count (`outlineCountries`).
    func outlineContains(_ coordinate: GeoCoordinate, mapCountry: String?) -> Bool {
        guard mapCountry.map(outlineCountries.contains) ?? true else { return false }
        return outlines.contains { Self.contains($0, coordinate.latitude, coordinate.longitude) }
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
                     mapCountries: [], mapRegions: ["UA-43", "UA-40"],
                     // The waters around the peninsula, about 25 km out, and the Kerch Strait with
                     // the bridge (the map's regions end 1.5 km off the coast). Only the sea: on
                     // land the map's regions decide.
                     outlines: [[(45.95, 32.40), (45.95, 34.60), (45.55, 35.30), (45.62, 36.00), (45.50, 36.58), (45.20, 36.62),
                                 (45.00, 36.55), (44.85, 36.25), (44.80, 35.70), (44.60, 35.20), (44.20, 34.30), (44.25, 33.50),
                                 (44.60, 33.20), (45.30, 32.25)]],
                     outlineCountries: []),
        DisputedArea(id: "western-sahara", nameDE: "Westsahara", nameEN: "Western Sahara", continent: .africa,
                     mapCountries: ["Western Sahara"], mapRegions: [],
                     // 27°40' N with Morocco, 8°40' W, 26° N, 12° W, 23°27' N, 13° W and 21°20' N with
                     // Mauritania; to the west over the sea, short of the Canary Islands.
                     outlines: [[(27.667, -13.60), (27.667, -8.667), (26.0, -8.667), (26.0, -12.0), (23.45, -12.0),
                                 (23.45, -13.0), (21.333, -15.0), (21.333, -17.06), (21.333, -17.4), (23.5, -16.6),
                                 (26.0, -15.0), (27.3, -13.85)]],
                     outlineCountries: ["Morocco", "Western Sahara"]),
        DisputedArea(id: "kashmir", nameDE: "Kaschmir", nameEN: "Kashmir", continent: .asia,
                     mapCountries: ["Siachen Glacier"], mapRegions: ["IN-JK", "IN-LA", "PK-JK", "PK-GB"],
                     // Aksai Chin, which the map counts to Xinjiang.
                     outlines: [[(35.65, 77.80), (35.95, 78.40), (35.60, 79.20), (35.30, 80.10), (34.75, 80.25),
                                 (34.30, 79.50), (34.40, 78.80), (34.95, 78.30), (35.40, 77.95)]],
                     outlineCountries: ["People's Republic of China", "India"]),
        DisputedArea(id: "northern-cyprus", nameDE: "Nordzypern", nameEN: "Northern Cyprus", continent: .europe,
                     mapCountries: ["Turkish Republic of Northern Cyprus"], mapRegions: [],
                     // The waters of the north, about 20 km out: from Limnitis (east of Kato
                     // Pyrgos and Kokkina) round Cape Apostolos Andreas to Varosha, ending at
                     // the line of control north of Deryneia; off Famagusta Bay the edge runs
                     // between Varosha and the Republic's coast at Kapparis and Protaras (second
                     // review of bundle-i: a corner on 35.075° N took their waters). The line
                     // back crosses the island. Only the sea (review of bundle-i: 3 km off
                     // Kyrenia was "Republik Zypern").
                     outlines: [[(35.17, 32.72), (35.45, 32.72), (35.55, 33.40), (35.60, 33.90), (35.80, 34.40), (35.80, 34.75),
                                 (35.55, 34.75), (35.30, 34.30), (35.18, 34.20), (35.10, 34.05), (35.075, 33.97)]],
                     outlineCountries: []),
        DisputedArea(id: "kosovo", nameDE: "Kosovo", nameEN: "Kosovo", continent: .europe,
                     mapCountries: ["Kosovo"], mapRegions: [], outlines: []),
        DisputedArea(id: "taiwan", nameDE: "Taiwan", nameEN: "Taiwan", continent: .asia,
                     mapCountries: ["Taiwan"], mapRegions: [],
                     // The waters of Taiwan with Penghu, Liuqiu, Green Island and Orchid Island;
                     // the Matsu Islands; Pratas; the islands off Xiamen. The map draws some of these islands not at
                     // all. Only the sea and the map's Taiwan: the coast of Fujian keeps its country.
                     outlines: [
                         [(25.50, 121.40), (25.40, 122.15), (24.00, 122.00), (22.60, 121.75), (21.80, 121.70), (21.80, 120.70),
                          (22.25, 120.15), (23.00, 119.25), (23.90, 119.25), (24.60, 120.40), (25.20, 120.95)],
                         [(26.45, 119.89), (26.45, 120.55), (25.92, 120.55), (25.92, 119.89)],
                         [(20.85, 116.65), (20.85, 116.95), (20.55, 116.95), (20.55, 116.65)],
                         // Lieyu (Little Kinmen), Dadan and Erdan off Xiamen, and Wuqiu (review of
                         // bundle-i). Kept 2-4 km clear of Xiamen, Gulangyu and Dadeng, which the
                         // map does not all draw either.
                         [(24.47, 118.215), (24.47, 118.285), (24.395, 118.285), (24.395, 118.215)],
                         [(24.395, 118.12), (24.395, 118.15), (24.372, 118.15), (24.372, 118.12)],
                         [(24.374, 118.105), (24.374, 118.128), (24.355, 118.128), (24.355, 118.105)],
                         [(25.01, 119.42), (25.01, 119.48), (24.96, 119.48), (24.96, 119.42)],
                     ],
                     outlineCountries: ["Taiwan"]),
        DisputedArea(id: "golan", nameDE: "Golanhöhen", nameEN: "Golan Heights", continent: .asia,
                     mapCountries: [], mapRegions: [],
                     // The part west of the 1974 line of separation; the map counts it to Israel.
                     // To the west the 1949 line: the Jordan from the Sea of Galilee to the Bnot
                     // Ya'akov bridge, then the foot of the heights east of the Hula valley
                     // (Gonen, Kfar Szold, Dan, Tel Dan and Snir stay in Israel, Banias is in the area).
                     // To the north and east well past the 1974 line and the Hermon: the outline
                     // only counts where the map says Israel, and the map's Israel reaches up to
                     // 3 km past the line (review of bundle-i: Alonei HaBashan was "Israel").
                     outlines: [[(33.40, 35.70), (33.40, 35.95), (32.88, 35.95), (32.80, 35.84), (32.70, 35.78),
                                 (32.68, 35.65), (32.83, 35.645), (32.90, 35.63), (33.00, 35.628), (33.05, 35.64),
                                 (33.12, 35.66), (33.20, 35.67), (33.245, 35.675), (33.27, 35.655), (33.30, 35.665)]],
                     outlineCountries: ["Israel"]),
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

    /// The area whose own outline holds `coordinate`, which the map gives to `mapCountry`
    /// (nil: no country, the sea); see `DisputedArea.outlineCountries`.
    static func area(outlineContaining coordinate: GeoCoordinate, mapCountry: String?) -> DisputedArea? {
        all.first { $0.outlineContains(coordinate, mapCountry: mapCountry) }
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
