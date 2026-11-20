import Foundation
import SortlyCore

// The world tables of "Deine Welt": the region each country lies in (the far-away globe's pins,
// "Südeuropa · 5 Länder", concept §4.2 and §13 "Weltgegend je Land") and the 195 states the
// collection counts against ("14 von 195 Ländern", "Europa 12 von 46", concept §4.8 and §5).

extension WorldRegion {
    /// The region of a country or territory by its ISO 3166-1 alpha-2 code, in any case. Known
    /// for every code `Continent` knows (Kosovo's XK included); `nil` for anything else, such as
    /// a disputed area's key ("disputed-crimea"), which is no country.
    public static func of(countryCode: String) -> WorldRegion? {
        m49Table[countryCode.uppercased()]
    }

    /// The app's continent the region lies in.
    public var continent: Continent {
        switch self {
        case .northernEurope, .westernEurope, .southernEurope, .easternEurope: .europe
        case .northernAfrica, .westernAfrica, .middleAfrica, .easternAfrica, .southernAfrica: .africa
        case .northernAmerica, .centralAmerica, .caribbean: .northAmerica
        case .southAmerica: .southAmerica
        case .centralAsia, .easternAsia, .southEasternAsia, .southernAsia, .westernAsia: .asia
        case .australiaAndNewZealand, .melanesia, .micronesia, .polynesia: .oceania
        case .antarctica: .antarctica
        }
    }

    /// The UN geoscheme (M49) subregions, with Latin America and Sub-Saharan Africa split into
    /// their intermediate regions as the enum has them. Where M49 and `Continent` disagree,
    /// `Continent` wins, so a region always lies in its country's continent and "Europa" on the
    /// globe and in the numbers is the same set of countries:
    /// - Turkey and Cyprus (M49: Western Asia) are Southern Europe, beside Greece.
    /// - The British Indian Ocean Territory (M49: Eastern Africa) is Southern Asia, beside the
    ///   Maldives; Christmas Island and the Cocos Islands (M49: Australia and New Zealand) are
    ///   South-eastern Asia, beside Indonesia.
    /// - Bouvet Island (M49: South America), Heard and McDonald Islands (M49: Australia and New
    ///   Zealand) and the French Southern Territories (M49: Eastern Africa) are Antarctica.
    /// - Codes M49 leaves out follow their neighbours: Kosovo (XK) Southern Europe, Taiwan Eastern
    ///   Asia.
    private static let m49Table: [String: WorldRegion] = {
        var table: [String: WorldRegion] = [:]
        func add(_ codes: String, _ region: WorldRegion) {
            for code in codes.split(separator: " ") { table[String(code)] = region }
        }
        add("AX DK EE FI FO GB GG IE IM IS JE LT LV NO SE SJ", .northernEurope)
        add("AT BE CH DE FR LI LU MC NL", .westernEurope)
        add("AD AL BA CY ES GI GR HR IT ME MK MT PT RS SI SM TR VA XK", .southernEurope)
        add("BG BY CZ HU MD PL RO RU SK UA", .easternEurope)
        add("DZ EG EH LY MA SD TN", .northernAfrica)
        add("BF BJ CI CV GH GM GN GW LR ML MR NE NG SH SL SN TG", .westernAfrica)
        add("AO CD CF CG CM GA GQ ST TD", .middleAfrica)
        add("BI DJ ER ET KE KM MG MU MW MZ RE RW SC SO SS TZ UG YT ZM ZW", .easternAfrica)
        add("BW LS NA SZ ZA", .southernAfrica)
        add("BM CA GL PM US", .northernAmerica)
        add("BZ CR GT HN MX NI PA SV", .centralAmerica)
        add("AG AI AW BB BL BQ BS CU CW DM DO GD GP HT JM KN KY LC MF MQ MS PR SX TC TT VC VG VI", .caribbean)
        add("AR BO BR CL CO EC FK GF GS GY PE PY SR UY VE", .southAmerica)
        add("KG KZ TJ TM UZ", .centralAsia)
        add("CN HK JP KP KR MN MO TW", .easternAsia)
        add("BN CC CX ID KH LA MM MY PH SG TH TL VN", .southEasternAsia)
        add("AF BD BT IN IO IR LK MV NP PK", .southernAsia)
        add("AE AM AZ BH GE IL IQ JO KW LB OM PS QA SA SY YE", .westernAsia)
        add("AU NF NZ", .australiaAndNewZealand)
        add("FJ NC PG SB VU", .melanesia)
        add("FM GU KI MH MP NR PW UM", .micronesia)
        add("AS CK NU PF PN TK TO TV WF WS", .polynesia)
        add("AQ BV HM TF", .antarctica)
        return table
    }()
}

/// The 195 states "Länder" are counted against ("14 von 195 Ländern · 7,2 % der Welt"): the 193
/// members of the United Nations, the Vatican (VA) and Palestine (PS), the two observer states.
/// A territory with its own code (Puerto Rico, Greenland, Hong Kong) is a country of the map with
/// its own flag and stamp, but not one of the 195; Kosovo and Taiwan are disputed areas
/// (decision 18.11.2026) and not among them either.
public enum WorldStates {
    /// ISO 3166-1 alpha-2, upper case. Listed by continent as `Continent` assigns them
    /// (transcontinental states follow their capital: Turkey, Cyprus and Russia are Europe, Egypt
    /// is Africa), which gives Africa 54, Asia 46, Europe 46, North America 23, South America 12
    /// and Oceania 14. The UN's own grouping has Europe 44: it counts Turkey and Cyprus to Asia.
    public static let codes: Set<String> = Set([
        // Africa
        "AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RW SC SD SL SN SO SS ST SZ TD TG TN TZ UG ZA ZM ZW",
        // Asia
        "AE AF AM AZ BD BH BN BT CN GE ID IL IN IQ IR JO JP KG KH KP KR KW KZ LA LB LK MM MN MV MY NP OM PH PK PS QA SA SG SY TH TJ TL TM UZ VN YE",
        // Europe
        "AD AL AT BA BE BG BY CH CY CZ DE DK EE ES FI FR GB GR HR HU IE IS IT LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SK SM TR UA VA",
        // North America
        "AG BB BS BZ CA CR CU DM DO GD GT HN HT JM KN LC MX NI PA SV TT US VC",
        // South America
        "AR BO BR CL CO EC GY PE PY SR UY VE",
        // Oceania
        "AU FJ FM KI MH NR NZ PG PW SB TO TV VU WS",
    ].flatMap { $0.split(separator: " ").map(String.init) })

    /// Whether `code` (any case) is one of the 195.
    public static func isState(_ code: String) -> Bool {
        codes.contains(code.uppercased())
    }

    /// How many of the 195 lie on `continent` ("Afrika 0 von 54"); 0 for Antarctica.
    public static func count(on continent: Continent) -> Int {
        perContinent[continent] ?? 0
    }

    private static let perContinent: [Continent: Int] = {
        var counts: [Continent: Int] = [:]
        for code in codes {
            if let continent = Continent.forCountryCode(code) { counts[continent, default: 0] += 1 }
        }
        return counts
    }()
}
