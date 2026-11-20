import Foundation
import Testing
import SortlyCore
@testable import SortlyMap

/// The visited countries and towns: as the atlas counts them, from GPS places only, without
/// photos in flight, without disputed areas.
@Suite("Map countries")
struct MapCountriesTests {
    typealias Places = MapFixture.Places

    /// One photo with a place as `source` gives it (a GPS place unless stated).
    static func fact(_ id: String, _ date: String?, _ code: String?, town: String? = nil, disputed: String? = nil,
                     source: PlaceSource = .gpsReverseGeocoded, trip: String? = nil, at coordinate: GeoCoordinate = Places.rome) -> AssetFacts {
        let place = PlaceComponents(isoCountryCode: code, country: code ?? disputed, locality: town, disputedArea: disputed)
        return AssetFacts(asset: AssetSnapshot(id: AssetID(id), kind: .image, creationDate: date.map(MapFixture.date), location: coordinate),
                          place: place, placeSource: source, tripID: trip.map(SortlyID.init), contentKnown: true)
    }

    static func facts(_ prefix: String, _ count: Int, _ date: String, _ code: String?, town: String? = nil, disputed: String? = nil,
                      source: PlaceSource = .gpsReverseGeocoded, trip: String? = nil) -> [AssetFacts] {
        (0..<count).map { fact("\(prefix)-\($0)", date, code, town: town, disputed: disputed, source: source, trip: trip) }
    }

    /// A small library: everyday photos at home in Germany, a trip to Iceland, one to Portugal,
    /// two photos in Rome (too few for a country).
    static var library: (facts: [AssetFacts], starts: [SortlyID: Date]) {
        let iceland = SortlyID("iceland"), portugal = SortlyID("portugal")
        let facts = MapFixture.everyday("home", from: "2023-01-01", to: "2023-01-10", at: Places.regensburg, country: "DE")
            + MapFixture.burst("rvk", count: 5, at: Places.reykjavik, day: "2023-06-14", country: "IS", town: "Reykjavík", trip: iceland)
            + MapFixture.burst("vik", count: 4, at: Places.vik, day: "2023-06-16", country: "IS", town: "Vík", trip: iceland)
            + MapFixture.burst("lis", count: 6, at: Places.lisbon, day: "2024-04-02", country: "PT", town: "Lissabon", trip: portugal)
            + MapFixture.burst("rom", count: 2, at: Places.rome, day: "2024-09-01", country: "IT", town: "Rom")
        return (facts, [iceland: MapFixture.date("2023-06-14 10:00"), portugal: MapFixture.date("2024-04-02 10:00")])
    }

    @Test func countsCountriesAsTheAtlasDoes() throws {
        let (facts, starts) = Self.library
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: starts)
        #expect(countries.map(\.code) == ["DE", "IS", "PT"])
        let germany = try #require(countries.first)
        #expect(germany.firstVisit == MapFixture.date("2023-01-01 12:00"))
        #expect(germany.photoCount == 20)
        #expect(germany.tripIDs.isEmpty)
        #expect(germany.isState && germany.continent == .europe && germany.region == .westernEurope)
        let iceland = countries[1]
        #expect(iceland.firstVisit == MapFixture.date("2023-06-14 10:00"))
        #expect(iceland.photoCount == 9)
        #expect(iceland.tripIDs == [SortlyID("iceland")])
        #expect(iceland.region == .northernEurope)
        #expect(countries[2].photoCount == 6 && countries[2].region == .southernEurope && countries[2].tripIDs == [SortlyID("portugal")])
        // The same countries and first visits as today's atlas, for photos that all have a GPS place.
        let atlas = TravelAtlas.compute(facts: facts, calendar: MapFixture.calendar)
        #expect(Set(countries.map(\.code)) == atlas.countryCodes)
        #expect(Dictionary(uniqueKeysWithValues: countries.map { ($0.code, $0.firstVisit) }) == atlas.firstVisits)
        #expect(countries.map(\.code) == atlas.countriesByFirstVisit)
        // Towns: Reykjavík, Vík, Lissabon and Rom (the everyday photos have no town).
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 4)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == atlas.cityCount)
    }

    @Test func onlyPlacesFromGPSCount() {
        let facts = Self.facts("guess", 5, "2023-05-01 10:00", "FR", town: "Paris", source: .contentInferred)
            + Self.facts("unresolved", 5, "2023-05-01 10:00", "BE", town: "Brügge", source: .gpsUnresolved)
            + Self.facts("chosen", 3, "2023-05-02 10:00", "ES", town: "Sevilla", source: .userAssigned)
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["ES"])
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 1)
    }

    @Test func photosInFlightCountForNothing() throws {
        // Three photos over Greece, one of them from the plane: two are too few.
        var facts = Self.facts("gr", 3, "2023-07-01 10:00", "GR", town: "Athen")
        // Iceland: the photo from the plane on approach is the earliest and the only one of Keflavík.
        let approach = Self.fact("approach", "2023-06-14 08:00", "IS", town: "Keflavík")
        facts += Self.facts("is", 3, "2023-06-14 10:00", "IS", town: "Reykjavík") + [approach]
        let airborne: Set<AssetID> = [AssetID("gr-0"), AssetID("approach")]
        let countries = MapCountries.compute(facts: facts, airborne: airborne, tripStarts: [:])
        #expect(countries.map(\.code) == ["IS"])
        let iceland = try #require(countries.first)
        #expect(iceland.firstVisit == MapFixture.date("2023-06-14 10:00"))
        #expect(iceland.photoCount == 3)
        #expect(MapCountries.cityCount(facts: facts, airborne: airborne) == 2)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 3)
    }

    @Test func aDisputedAreaIsNoCountryButItsTownsCount() {
        let facts = Self.facts("yalta", 6, "2021-08-01 10:00", nil, town: "Jalta", disputed: "crimea")
            + Self.facts("prizren", 4, "2021-09-01 10:00", nil, town: "Prizren", disputed: "kosovo")
            + Self.facts("kyiv", 3, "2021-07-01 10:00", "UA", town: "Kyjiw")
            + Self.facts("nowhere", 3, "2021-07-02 10:00", nil, town: "Atlantis")
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["UA"])
        // Jalta, Prizren and Kyjiw; a place with neither a code nor a disputed area has no country key.
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 3)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == TravelAtlas.compute(facts: facts).cityCount)
    }

    /// A country whose photos all lack a date is left out (no first visit); one dated photo is
    /// enough to date it.
    @Test func aCountryWithoutAnyDateIsLeftOut() throws {
        let facts = Self.facts("no", 4, "2023-01-01", "NO").map { f -> AssetFacts in var f = f; f.asset.creationDate = nil; return f }
            + Self.facts("se", 2, "2023-01-01", "SE").map { f -> AssetFacts in var f = f; f.asset.creationDate = nil; return f }
            + [Self.fact("se-dated", "2023-02-03 09:15", "SE")]
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["SE"])
        let sweden = try #require(countries.first)
        #expect(sweden.photoCount == 3)
        #expect(sweden.firstVisit == MapFixture.date("2023-02-03 09:15"))
        // The atlas counts Norway without a first visit; the map has no year for it.
        #expect(TravelAtlas.compute(facts: facts).countryCodes == ["NO", "SE"])
    }

    @Test func aPhotoListedTwiceCountsOnce() throws {
        let one = Self.fact("same", "2023-03-01 10:00", "FI", town: "Helsinki")
        let estonia = Self.facts("ee", 3, "2023-03-02 10:00", "EE", town: "Tallinn")
        let facts = [one, one, one] + estonia + [estonia[0]]
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["EE"])
        #expect(try #require(countries.first).photoCount == 3)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 2)
    }

    @Test func tripsAreOrderedByStartThenID() throws {
        let facts = Self.facts("b", 1, "2022-05-01 10:00", "IT", trip: "trip-b") + Self.facts("a", 1, "2022-05-01 11:00", "IT", trip: "trip-a")
            + Self.facts("c", 1, "2020-05-01 10:00", "IT", trip: "trip-c") + Self.facts("x", 1, "2019-05-01 10:00", "IT", trip: "trip-x")
            + Self.facts("none", 2, "2018-05-01 10:00", "IT")
        let starts = [SortlyID("trip-a"): MapFixture.date("2022-05-01"), SortlyID("trip-b"): MapFixture.date("2022-05-01"),
                      SortlyID("trip-c"): MapFixture.date("2020-05-01")]
        let italy = try #require(MapCountries.compute(facts: facts, airborne: [], tripStarts: starts).first)
        // Same start: by id; a trip whose start is not known comes last.
        #expect(italy.tripIDs == ["trip-c", "trip-a", "trip-b", "trip-x"].map(SortlyID.init))
        #expect(italy.photoCount == 6)
        #expect(italy.firstVisit == MapFixture.date("2018-05-01 10:00"))
    }

    @Test func orderIsFirstVisitThenCode() {
        let facts = Self.facts("ch", 3, "2023-08-01 10:00", "CH") + Self.facts("at", 3, "2023-08-01 10:00", "AT")
            + Self.facts("li", 3, "2023-07-31 10:00", "LI")
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["LI", "AT", "CH"])
    }

    @Test func territoriesAreCountriesButNoStates() throws {
        let facts = Self.facts("pr", 3, "2024-02-01 10:00", "PR", town: "San Juan") + Self.facts("gl", 3, "2024-03-01 10:00", "GL", town: "Nuuk")
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["PR", "GL"])
        #expect(countries.allSatisfy { !$0.isState && $0.continent == .northAmerica })
        #expect(countries.map(\.region) == [.caribbean, .northernAmerica])
    }

    @Test func theSameInputInAnyOrderGivesTheSameCountries() {
        let (facts, starts) = Self.library
        let more = facts + Self.facts("ch", 3, "2023-08-01 10:00", "CH", trip: "x") + Self.facts("at", 3, "2023-08-01 10:00", "AT", trip: "y")
            + Self.facts("at2", 1, "2023-08-01 10:00", "AT", trip: "x")
        let airborne: Set<AssetID> = [AssetID("rvk-0"), AssetID("lis-3")]
        let reference = MapCountries.compute(facts: more, airborne: airborne, tripStarts: starts)
        let cities = MapCountries.cityCount(facts: more, airborne: airborne)
        for seed in UInt64(1)...5 {
            let shuffled = HandBuilt.shuffled(more, seed: seed)
            #expect(MapCountries.compute(facts: shuffled, airborne: airborne, tripStarts: starts) == reference)
            #expect(MapCountries.cityCount(facts: shuffled, airborne: airborne) == cities)
        }
    }

    @Test func townsAreCountedPerCountryAsTheAtlasDoes() {
        let facts = Self.facts("ffm", 2, "2023-01-01 10:00", "DE", town: "Frankfurt") + Self.facts("ffm-us", 1, "2023-02-01 10:00", "US", town: "Frankfurt")
            + Self.facts("again", 3, "2023-03-01 10:00", "DE", town: "Frankfurt") + Self.facts("plain", 3, "2023-03-01 10:00", "DE")
            + Self.facts("empty", 1, "2023-03-01 10:00", "DE", town: "")
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 2)
    }

    @Test func minimumPhotosIsAParameter() {
        let facts = Self.facts("one", 1, "2023-01-01 10:00", "MT") + Self.facts("three", 3, "2023-02-01 10:00", "CY")
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["CY"])
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:], minimumPhotos: 1).map(\.code) == ["MT", "CY"])
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:], minimumPhotos: 4).isEmpty)
    }

    /// `PlaceComponents.init` makes codes upper case; a place decoded from storage might not be.
    @Test func aLowerCaseCodeIsTheSameCountry() throws {
        var lower = Self.facts("lower", 2, "2023-01-01 10:00", "NL", town: "Utrecht")
        for i in lower.indices { lower[i].place?.isoCountryCode = "nl" }
        let facts = lower + [Self.fact("upper", "2023-01-02 10:00", "NL", town: "Utrecht")]
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["NL"])
        #expect(try #require(countries.first).isState)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 1)
    }

    @Test func emptyInputAndASinglePhoto() {
        #expect(MapCountries.compute(facts: [], airborne: [], tripStarts: [:]).isEmpty)
        #expect(MapCountries.cityCount(facts: [], airborne: []) == 0)
        let one = [Self.fact("one", "2023-01-01 10:00", "DK", town: "Kopenhagen")]
        #expect(MapCountries.compute(facts: one, airborne: [], tripStarts: [:]).isEmpty)
        #expect(MapCountries.cityCount(facts: one, airborne: []) == 1)
        #expect(MapCountries.cityCount(facts: one, airborne: [AssetID("one")]) == 0)
    }
}
