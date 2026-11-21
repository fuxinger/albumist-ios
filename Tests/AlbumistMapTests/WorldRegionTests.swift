import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// The world tables: a region for every country `Continent` knows, on the same continent, and the
/// 195 states "Länder" are counted against.
@Suite("World regions and states")
struct WorldRegionTests {
    /// The code lists of `Continent`'s table (Sources/AlbumistCore/Places/Continent.swift), copied
    /// here because the table is private: every one of them needs a region.
    static let continentTable: [(codes: String, continent: Continent)] = [
        ("AD AL AT AX BA BE BG BY CH CY CZ DE DK EE ES FI FO FR GB GG GI GR HR HU IE IM IS IT JE LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM TR UA VA XK", .europe),
        ("AE AF AM AZ BD BH BN BT CC CN CX GE HK ID IL IN IO IQ IR JO JP KG KH KP KR KW KZ LA LB LK MM MN MO MV MY NP OM PH PK PS QA SA SG SY TH TJ TL TM TW UZ VN YE", .asia),
        ("AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW", .africa),
        ("AG AI AW BB BL BM BQ BS BZ CA CR CU CW DM DO GD GL GP GT HN HT JM KN KY LC MF MQ MS MX NI PA PM PR SV SX TC TT US VC VG VI", .northAmerica),
        ("AR BO BR CL CO EC FK GF GY PE PY SR UY VE GS", .southAmerica),
        ("AS AU CK FJ FM GU KI MH MP NC NF NR NU NZ PF PG PN PW SB TK TO TV UM VU WF WS", .oceania),
        ("AQ BV HM TF", .antarctica),
    ]

    static var continentCodes: [String] { continentTable.flatMap { $0.codes.split(separator: " ").map(String.init) } }

    /// The 193 members of the United Nations, in the order of the UN's own list (by English
    /// name: Afghanistan, Albania, Algeria, ... Zimbabwe), written independently of
    /// `WorldStates.codes`, which lists them by continent.
    static let unMembers = """
        AF AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BY BE BZ BJ BT BO BA BW BR BN BG BF BI CV KH CM CA CF TD CL CN CO KM CG CR \
        CI HR CU CY CZ KP CD DK DJ DM DO EC EG SV GQ ER EE SZ ET FJ FI FR GA GM GE DE GH GR GD GT GN GW GY HT HN HU IS IN ID IR \
        IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MG MW MY MV ML MT MH MR MU MX FM MC MN ME MA MZ MM NA NR \
        NP NL NZ NI NE NG MK NO OM PK PW PA PG PY PE PH PL PT QA KR MD RO RU RW KN LC VC WS SM ST SA SN RS SC SL SG SK SI SB SO \
        ZA SS ES LK SD SR SE CH SY TJ TH TL TG TO TT TN TR TM TV UG UA AE GB TZ US UY UZ VU VE VN YE ZM ZW
        """.split(separator: " ").map(String.init)

    @Test func everyCodeOfTheContinentTableHasARegionOnItsContinent() throws {
        let codes = Self.continentCodes
        #expect(codes.count == 250)
        #expect(Set(codes).count == codes.count)
        for code in codes {
            let region = try #require(WorldRegion.of(countryCode: code), "\(code) has no region")
            #expect(region.continent == Continent.forCountryCode(code), "\(code): \(region) is not on \(String(describing: Continent.forCountryCode(code)))")
        }
    }

    @Test func everyRegionHasCountriesOnItsContinent() {
        var used = Set<WorldRegion>()
        for code in Self.continentCodes { if let region = WorldRegion.of(countryCode: code) { used.insert(region) } }
        #expect(used == Set(WorldRegion.allCases))
        #expect(WorldRegion.westernEurope.continent == .europe)
        #expect(WorldRegion.middleAfrica.continent == .africa)
        #expect(WorldRegion.caribbean.continent == .northAmerica)
        #expect(WorldRegion.centralAmerica.continent == .northAmerica)
        #expect(WorldRegion.southAmerica.continent == .southAmerica)
        #expect(WorldRegion.southEasternAsia.continent == .asia)
        #expect(WorldRegion.polynesia.continent == .oceania)
        #expect(WorldRegion.antarctica.continent == .antarctica)
    }

    @Test func regionsFollowTheUNGeoscheme() {
        func expect(_ codes: String, _ region: WorldRegion, sourceLocation: SourceLocation = #_sourceLocation) {
            for code in codes.split(separator: " ") {
                #expect(WorldRegion.of(countryCode: String(code)) == region, "\(code)", sourceLocation: sourceLocation)
            }
        }
        expect("IT ES PT GR HR SI MT VA SM AD AL", .southernEurope)
        expect("DE FR NL AT CH BE LU LI MC", .westernEurope)
        expect("GB IE IS NO SE DK FI EE LV LT FO", .northernEurope)
        expect("PL CZ SK HU RO BG UA BY MD", .easternEurope)
        expect("JP CN KR KP MN HK MO", .easternAsia)
        expect("TH VN ID MY SG PH KH LA MM BN TL", .southEasternAsia)
        expect("IN PK BD LK NP BT MV IR AF", .southernAsia)
        expect("KZ UZ KG TJ TM", .centralAsia)
        expect("IL JO LB SA AE QA OM YE IQ SY KW BH", .westernAsia)
        expect("MA DZ TN LY SD EH", .northernAfrica)
        expect("NG GH SN CI ML CV", .westernAfrica)
        expect("CD CG CM GA AO TD", .middleAfrica)
        expect("KE TZ ET UG MG RE MU", .easternAfrica)
        expect("ZA NA BW LS SZ", .southernAfrica)
        expect("US CA GL BM PM", .northernAmerica)
        expect("MX GT CR PA NI", .centralAmerica)
        expect("CU JM DO HT PR BS TT BB", .caribbean)
        expect("BR AR CL PE CO VE FK", .southAmerica)
        expect("AU NZ NF", .australiaAndNewZealand)
        expect("FJ PG SB VU NC", .melanesia)
        expect("GU PW FM MH KI NR", .micronesia)
        expect("WS TO PF CK TV", .polynesia)
        expect("AQ", .antarctica)
    }

    /// Where the UN geoscheme and `Continent` disagree, `Continent` wins.
    @Test func transcontinentalCountriesFollowTheContinent() {
        #expect(WorldRegion.of(countryCode: "TR") == .southernEurope)
        #expect(WorldRegion.of(countryCode: "CY") == .southernEurope)
        #expect(WorldRegion.of(countryCode: "RU") == .easternEurope)
        #expect(WorldRegion.of(countryCode: "GE") == .westernAsia)
        #expect(WorldRegion.of(countryCode: "AM") == .westernAsia)
        #expect(WorldRegion.of(countryCode: "AZ") == .westernAsia)
        #expect(WorldRegion.of(countryCode: "EG") == .northernAfrica)
        #expect(WorldRegion.of(countryCode: "KZ") == .centralAsia)
        #expect(WorldRegion.of(countryCode: "PA") == .centralAmerica)
        #expect(WorldRegion.of(countryCode: "ID") == .southEasternAsia)
        #expect(WorldRegion.of(countryCode: "PG") == .melanesia)
        // M49 puts these on another continent than the app does.
        #expect(WorldRegion.of(countryCode: "IO") == .southernAsia)
        #expect(WorldRegion.of(countryCode: "CX") == .southEasternAsia)
        #expect(WorldRegion.of(countryCode: "CC") == .southEasternAsia)
        #expect(WorldRegion.of(countryCode: "TF") == .antarctica)
        #expect(WorldRegion.of(countryCode: "BV") == .antarctica)
        #expect(WorldRegion.of(countryCode: "HM") == .antarctica)
        // Not in M49 at all.
        #expect(WorldRegion.of(countryCode: "XK") == .southernEurope)
        #expect(WorldRegion.of(countryCode: "TW") == .easternAsia)
    }

    @Test func lookupIgnoresCaseAndKnowsNoOtherKeys() {
        #expect(WorldRegion.of(countryCode: "it") == .southernEurope)
        #expect(WorldRegion.of(countryCode: "De") == .westernEurope)
        #expect(WorldRegion.of(countryCode: "disputed-crimea") == nil)
        #expect(WorldRegion.of(countryCode: "") == nil)
        #expect(WorldRegion.of(countryCode: "ZZ") == nil)
        #expect(WorldRegion.of(countryCode: "DEU") == nil)
    }

    @Test func thereAre195StatesTheUNMembersVaticanAndPalestine() {
        #expect(Self.unMembers.count == 193)
        #expect(Set(Self.unMembers).count == 193)
        #expect(WorldStates.codes.count == 195)
        #expect(WorldStates.codes == Set(Self.unMembers + ["VA", "PS"]))
        for code in WorldStates.codes {
            #expect(Continent.forCountryCode(code) != nil, "\(code) has no continent")
            #expect(WorldRegion.of(countryCode: code) != nil, "\(code) has no region")
            #expect(code == code.uppercased())
        }
        // Disputed areas and territories are countries of the map, but not among the 195.
        for code in ["XK", "TW", "HK", "MO", "PR", "GL", "FO", "GI", "RE", "EH", "AQ"] {
            #expect(!WorldStates.isState(code), "\(code)")
        }
        #expect(WorldStates.isState("de"))
        #expect(WorldStates.isState("VA"))
        #expect(WorldStates.isState("ps"))
        #expect(!WorldStates.isState("disputed-crimea"))
        #expect(!WorldStates.isState(""))
    }

    /// Our continents put Turkey, Cyprus and Russia in Europe and Egypt in Africa: Europe has 46
    /// (the UN's grouping, with Turkey and Cyprus in Asia, has 44, as the concept's draft image
    /// "Europa 12 von 44" shows).
    @Test func statesPerContinentAddUpTo195() {
        #expect(WorldStates.count(on: .africa) == 54)
        #expect(WorldStates.count(on: .asia) == 46)
        #expect(WorldStates.count(on: .europe) == 46)
        #expect(WorldStates.count(on: .northAmerica) == 23)
        #expect(WorldStates.count(on: .southAmerica) == 12)
        #expect(WorldStates.count(on: .oceania) == 14)
        #expect(WorldStates.count(on: .antarctica) == 0)
        #expect(Continent.allCases.reduce(0) { $0 + WorldStates.count(on: $1) } == 195)
        // Counted from the list itself, not from the table the counts come from.
        for continent in Continent.allCases {
            #expect(WorldStates.count(on: continent) == WorldStates.codes.count { Continent.forCountryCode($0) == continent }, "\(continent)")
        }
    }
}
