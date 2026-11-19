import Foundation
import Testing
@testable import SortlyCore
import SortlyWorldMap
import SortlyTestSupport

/// Disputed areas on the map (decision Fuchs 18.11.2026, review P1-11): Albumist says "nicht
/// sicher" there instead of taking one side's view. The map put Yalta in "Russland" and
/// El Aaiún in "Marokko" and called that certain.
@Suite("Disputed areas")
struct DisputedAreaTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    func at(_ lat: Double, _ lon: Double) -> OfflineWorldMap.Match { Self.map.lookup(GeoCoordinate(latitude: lat, longitude: lon)) }

    @Test(arguments: [
        ("Jalta", 44.4952, 34.1663, "crimea"),
        ("Sewastopol", 44.6166, 33.5254, "crimea"),
        ("Simferopol", 44.9521, 34.1024, "crimea"),
        ("El Aaiún", 27.1253, -13.1625, "western-sahara"),
        ("Dakhla", 23.6848, -15.9580, "western-sahara"),
        ("Smara", 26.7384, -11.6719, "western-sahara"),
        ("Srinagar", 34.0837, 74.7973, "kashmir"),
        ("Leh", 34.1526, 77.5771, "kashmir"),
        ("Muzaffarabad", 34.3700, 73.4711, "kashmir"),
        ("Gilgit", 35.9208, 74.3089, "kashmir"),
        ("Aksai Chin", 35.2, 79.5, "kashmir"),
        ("Kyrenia", 35.3364, 33.3199, "northern-cyprus"),
        ("Famagusta", 35.1250, 33.9417, "northern-cyprus"),
        ("Pristina", 42.6629, 21.1655, "kosovo"),
        ("Taipeh", 25.0330, 121.5654, "taiwan"),
        ("Kaohsiung", 22.6273, 120.3014, "taiwan"),
        ("Majdal Shams", 33.2700, 35.7700, "golan"),
        ("Katzrin", 32.9925, 35.6914, "golan"),
        ("Suchumi", 43.0015, 41.0234, "abkhazia"),
        ("Banias", 33.2486, 35.6944, "golan"),
        // At sea, where the map draws no country (second review of 752ba07): the area's own
        // waters say "nicht sicher" too, whatever Apple's lookup would answer.
        ("vor El Aaiún, 20 km", 27.15, -13.45, "western-sahara"),
        ("vor Jalta, 5 km", 44.45, 34.20, "crimea"),
        ("Krim-Brücke, Mitte", 45.30, 36.53, "crimea"),
        // Islands the map does not draw.
        ("Liuqiu", 22.34, 120.37, "taiwan"),
        ("Matsu, Nangan", 26.1597, 119.95, "taiwan"),
        ("Pratas", 20.70, 116.72, "taiwan"),
    ])
    func disputedPointsTakeNoSide(name: String, lat: Double, lon: Double, area: String) throws {
        let m = at(lat, lon)
        #expect(m.disputedArea?.id == area, "\(name)")
        #expect(m.country == nil, "\(name): no country of either side")
        #expect(m.region == nil, "\(name)")
        let c = try #require(m.components(language: .german))
        #expect(c.isoCountryCode == nil)
        #expect(c.administrativeArea == nil)
        #expect(c.disputedArea == area)
        #expect(c.country == DisputedAreas.area(id: area)?.nameDE)
    }

    @Test(arguments: [
        ("Cherson", 46.6354, 32.6169, "UA"),
        ("Odessa", 46.4825, 30.7233, "UA"),
        ("Agadir", 30.4278, -9.5981, "MA"),
        ("Tindouf", 27.6711, -8.1474, "DZ"),
        ("Amritsar", 31.6340, 74.8723, "IN"),
        ("Islamabad", 33.6844, 73.0479, "PK"),
        ("Limassol", 34.7071, 33.0226, "CY"),
        ("Larnaka", 34.9003, 33.6232, "CY"),
        ("Niš", 43.3209, 21.8958, "RS"),
        ("Xiamen", 24.4798, 118.0894, "CN"),
        ("Tiberias", 32.7940, 35.5300, "IL"),
        ("Damaskus", 33.5138, 36.2765, "SY"),
        ("Tiflis", 41.7151, 44.8271, "GE"),
        // Israel below the Golan (second review of 752ba07: the outline reached into the Hula valley).
        ("Gonen", 33.1200, 35.6450, "IL"),
        ("Kfar Szold", 33.1930, 35.6570, "IL"),
        ("Kibbutz Dan", 33.2386, 35.6522, "IL"),
        ("Tel Dan", 33.2487, 35.6522, "IL"),
        ("She'ar Yashuv", 33.2250, 35.6450, "IL"),
        // An outline only overrides the countries the map gives the area: the Syrian-held
        // Golan east of the 1974 line and Mauritania along 12° W keep their country.
        ("Hader", 33.2700, 35.8000, "SY"),
        ("Mauretanien an 12° W", 23.8000, -12.0000, "MR"),
        // The sea outlines do not reach the land next to them.
        ("Skadowsk", 46.1100, 32.9100, "UA"),
        ("Lianjiang", 26.2000, 119.5400, "CN"),
    ])
    func nearbyPointsKeepTheirCountry(name: String, lat: Double, lon: Double, code: String) {
        let m = at(lat, lon)
        #expect(m.disputedArea == nil, "\(name)")
        #expect(m.country?.isoCode == code, "\(name)")
        #expect(m.components(language: .german)?.isoCountryCode == code, "\(name)")
    }

    /// Northern Cyprus has "CY" in the map too: Apple's "CY" for a photo in south Nicosia, near
    /// the Green Line (the map is not sure there), names the Republic of Cyprus.
    @Test func appleCodeOfCyprusNamesTheRepublic() {
        #expect(Self.map.country(code: "CY")?.nameDE == "Republik Zypern")
        #expect(Self.map.country(code: "DE")?.nameDE == "Deutschland")
    }

    @Test func everyAreaHasNamesAndAUniqueID() {
        #expect(Set(DisputedAreas.all.map(\.id)).count == DisputedAreas.all.count)
        for area in DisputedAreas.all {
            #expect(!area.nameDE.isEmpty && !area.nameEN.isEmpty)
            #expect(DisputedAreas.area(id: area.id) == area)
        }
    }

    /// The map's countries and regions the table names exist, so a new map cannot drop one unseen.
    @Test func tableNamesWhatTheMapHas() {
        let countries = Set(Self.map.regions.filter { $0.level == .country }.map(\.nameEN))
        let regions = Set(Self.map.regions.filter { $0.level == .region }.map(\.isoCode))
        for area in DisputedAreas.all {
            for name in area.mapCountries { #expect(countries.contains(name), "\(area.id): \(name)") }
            for code in area.mapRegions { #expect(regions.contains(code), "\(area.id): \(code)") }
        }
    }

    @Test func keyAndNameFollowTheAreaNotTheLanguage() throws {
        let de = try #require(at(44.4952, 34.1663).components(language: .german))
        let en = try #require(at(44.4952, 34.1663).components(language: .english))
        #expect(de.country == "Krim")
        #expect(en.country == "Crimea")
        #expect(de.key(at: .country) == en.key(at: .country))
        #expect(de.key(at: .country)?.path == "disputed-crimea")
        #expect(de.continent == .europe)
        // Renaming a stored place (review P1-12) keeps the area.
        let renamed = Self.map.renamed(de, to: .english)
        #expect(renamed.country == "Crimea")
        #expect(renamed.disputedArea == "crimea")
        #expect(renamed.isoCountryCode == nil)
    }

    // MARK: With Apple's lookup

    func service(level: PlaceLevel, geocoder: FakeGeocoder) -> PlaceResolutionService {
        PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: level, onlineAllowed: true, language: .german),
            throttle: .apple, time: ManualTime().source
        )
    }

    /// Apple names the country by the country of the device. Whatever it says, the photo gets
    /// the area's name and keeps the town.
    @Test(arguments: ["RU", "UA"])
    func appleCannotPickASide(code: String) async throws {
        let yalta = GeoCoordinate(latitude: 44.4952, longitude: 34.1663)
        let geocoder = FakeGeocoder(answers: [(yalta, PlaceComponents(isoCountryCode: code, country: code == "RU" ? "Russland" : "Ukraine",
                                                                         administrativeArea: "Krim", locality: "Jalta"))])
        let collector = ResultCollector()
        _ = try await service(level: .locality, geocoder: geocoder)
            .resolve([.init(assetID: AssetID("y"), coordinate: yalta, priority: 0)]) { await collector.add($0) }
        let place = try #require(await collector.places[AssetID("y")]?.components)
        #expect(place.country == "Krim")
        #expect(place.isoCountryCode == nil)
        #expect(place.administrativeArea == nil)
        #expect(place.locality == "Jalta")
        #expect(place.disputedArea == "crimea")
    }

    /// Where the map is not sure (a border, the sea next to it), Apple's country decides the
    /// side; an answer that names a disputed area is still "nicht sicher" (second review of
    /// 752ba07: a Kherson photo became "Russland, Autonome Republik Krim", a Serbian one
    /// "Kosovo" with its own country code).
    @Test(arguments: [
        ("Cherson an der Krim", 46.122, 33.61, "RU", "crimea"),
        ("Serbien am Kosovo", 42.95, 21.23, "XK", "kosovo"),
    ])
    func appleNamingADisputedAreaAtABorderIsNotSure(name: String, lat: Double, lon: Double, code: String, area: String) async throws {
        let point = GeoCoordinate(latitude: lat, longitude: lon)
        let before = Self.map.lookup(point)
        #expect(before.disputedArea == nil && !before.countryIsCertain, "\(name): the map is not sure here")
        let geocoder = FakeGeocoder(answers: [(point, PlaceComponents(isoCountryCode: code, country: code, locality: "Ort"))])
        let collector = ResultCollector()
        _ = try await service(level: .locality, geocoder: geocoder)
            .resolve([.init(assetID: AssetID("b"), coordinate: point, priority: 0)]) { await collector.add($0) }
        let place = try #require(await collector.places[AssetID("b")]?.components)
        #expect(place.disputedArea == area, "\(name)")
        #expect(place.isoCountryCode == nil, "\(name)")
        #expect(place.country == DisputedAreas.area(id: area)?.nameDE, "\(name)")
    }

    /// The same border points keep their country when Apple names that one.
    @Test(arguments: [("Cherson an der Krim", 46.122, 33.61, "UA"), ("Serbien am Kosovo", 42.95, 21.23, "RS")])
    func appleNamingTheMapsCountryAtABorderKeepsIt(name: String, lat: Double, lon: Double, code: String) async throws {
        let point = GeoCoordinate(latitude: lat, longitude: lon)
        let geocoder = FakeGeocoder(answers: [(point, PlaceComponents(isoCountryCode: code, country: code, locality: "Ort"))])
        let collector = ResultCollector()
        _ = try await service(level: .locality, geocoder: geocoder)
            .resolve([.init(assetID: AssetID("b"), coordinate: point, priority: 0)]) { await collector.add($0) }
        let place = try #require(await collector.places[AssetID("b")]?.components)
        #expect(place.disputedArea == nil, "\(name)")
        #expect(place.isoCountryCode == code, "\(name)")
    }

    /// One online lookup names a whole 5 km cell. When the cell's sample photo lies on the
    /// other side of the line, its town is not this photo's (second review of 752ba07).
    @Test func aTownFromAcrossTheLineIsNotTaken() async throws {
        let kosovo = GeoCoordinate(latitude: 43.120, longitude: 20.932)
        let serbia1 = GeoCoordinate(latitude: 43.124, longitude: 20.984), serbia2 = GeoCoordinate(latitude: 43.124, longitude: 20.988)
        #expect(GeoCell(kosovo, sizeMeters: 5_000) == GeoCell(serbia1, sizeMeters: 5_000))
        #expect(GeoCell(kosovo, sizeMeters: 5_000) == GeoCell(serbia2, sizeMeters: 5_000))
        let geocoder = FakeGeocoder(answers: [(serbia1, PlaceComponents(isoCountryCode: "RS", country: "Serbien", locality: "Kuršumlija"))])
        let collector = ResultCollector()
        _ = try await service(level: .locality, geocoder: geocoder).resolve([
            .init(assetID: AssetID("k"), coordinate: kosovo), .init(assetID: AssetID("s1"), coordinate: serbia1),
            .init(assetID: AssetID("s2"), coordinate: serbia2),
        ]) { await collector.add($0) }
        #expect(geocoder.calls == [serbia1], "one lookup for the cell, at the photo nearest its middle")
        let k = try #require(await collector.places[AssetID("k")]?.components)
        #expect(k.disputedArea == "kosovo")
        #expect(k.locality == nil, "Kuršumlija is in Serbia")
        #expect(await collector.places[AssetID("s1")]?.components.locality == "Kuršumlija")
    }

    /// And the other way round: a Serbian photo does not take the town of a sample photo in
    /// Kosovo, even when Apple names Serbia for it.
    @Test func aTownFromInsideTheAreaIsNotTakenOutside() async throws {
        let kosovo1 = GeoCoordinate(latitude: 43.120, longitude: 20.932), kosovo2 = GeoCoordinate(latitude: 43.120, longitude: 20.936)
        let serbia = GeoCoordinate(latitude: 43.124, longitude: 20.984)
        let geocoder = FakeGeocoder(answers: [(kosovo2, PlaceComponents(isoCountryCode: "RS", country: "Serbien", locality: "Podujevo"))])
        let collector = ResultCollector()
        _ = try await service(level: .locality, geocoder: geocoder).resolve([
            .init(assetID: AssetID("k1"), coordinate: kosovo1), .init(assetID: AssetID("k2"), coordinate: kosovo2),
            .init(assetID: AssetID("s"), coordinate: serbia),
        ]) { await collector.add($0) }
        #expect(geocoder.calls == [kosovo2])
        let s = try #require(await collector.places[AssetID("s")]?.components)
        #expect(s.isoCountryCode == "RS")
        #expect(s.locality == nil, "Podujevo is in Kosovo")
        #expect(await collector.places[AssetID("k1")]?.components.locality == "Podujevo")
    }

    /// A Kosovo photo near the Serbian border: the map sees both countries within its margin,
    /// but the area is the final answer, so countries only need no online lookup there.
    @Test func aDisputedPointAtTheBorderNeedsNoLookupForCountries() async throws {
        let point = GeoCoordinate(latitude: 42.99, longitude: 21.21)
        let geocoder = FakeGeocoder()
        let collector = ResultCollector()
        _ = try await service(level: .country, geocoder: geocoder)
            .resolve([.init(assetID: AssetID("m"), coordinate: point, priority: 0)]) { await collector.add($0) }
        #expect(geocoder.calls.isEmpty)
        #expect(await collector.places[AssetID("m")]?.components.country == "Kosovo")
    }

    @Test func countriesOnlyNeedNoOnlineLookup() async throws {
        let geocoder = FakeGeocoder()
        let collector = ResultCollector()
        _ = try await service(level: .country, geocoder: geocoder)
            .resolve([.init(assetID: AssetID("t"), coordinate: GeoCoordinate(latitude: 25.0330, longitude: 121.5654), priority: 0)]) { await collector.add($0) }
        #expect(geocoder.calls.isEmpty)
        #expect(await collector.places[AssetID("t")]?.components.country == "Taiwan")
    }

    // MARK: Suggestions

    func fact(_ n: Int, _ place: PlaceComponents) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: AssetID("p\(n)"), creationDate: Fixture.date("2024-05-0\(1 + n % 9)")),
                   place: place, placeSource: .gpsReverseGeocoded)
    }

    @Test func disputedCountrySuggestionIsUncertainAndNeverAPick() throws {
        var settings = OrganizationSettings()
        settings.enabledAreas = [.places]
        settings.places.includesCities = true
        let crimea = PlaceComponents(locality: "Jalta").inDisputedArea(try #require(DisputedAreas.area(id: "crimea")), language: .german)
        let italy = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom")
        let facts = (0..<12).map { fact($0, crimea) } + (12..<24).map { fact($0, italy) }
        let proposals = ProposalEngine(settings: settings).placeProposals(facts)

        let krim = try #require(proposals.first { $0.title == "Krim" })
        #expect(krim.reliability == .uncertain)
        #expect(krim.reasons.contains(.disputedArea(place: "Krim")))
        #expect(!ProposalDecision.isSafeToAcceptUnseen(krim, match: nil))
        #expect(!proposals.contains { $0.title == "Russland" || $0.title == "Ukraine" })
        // The town is not in dispute; the country next door is certain as before.
        #expect(proposals.first { $0.title == "Jalta" }?.reliability == .certain)
        #expect(proposals.first { $0.title == "Italien" }?.reliability == .certain)
    }

    @Test func atlasCountsNoDisputedAreaAsACountry() throws {
        let kosovo = PlaceComponents(locality: "Pristina").inDisputedArea(try #require(DisputedAreas.area(id: "kosovo")), language: .german)
        let facts = (0..<5).map { fact($0, kosovo) }
        #expect(TravelAtlas.compute(facts: facts).countryCodes.isEmpty)
    }

    /// Not a country, but a trip there is a trip and its towns are towns (second review of
    /// 752ba07: a Taiwan trip was missing from the atlas altogether).
    @Test func atlasCountsTripsAndTownsInADisputedArea() throws {
        let taiwan = PlaceComponents(locality: "Taipeh").inDisputedArea(try #require(DisputedAreas.area(id: "taiwan")), language: .german)
        let italy = PlaceComponents(isoCountryCode: "IT", country: "Italien", locality: "Rom")
        let tw = SortlyID.stable("trip", "tw"), it = SortlyID.stable("trip", "it")
        var facts = (0..<6).map { n -> AssetFacts in var f = fact(n, taiwan); f.tripID = tw; return f }
        facts += (10..<13).map { n -> AssetFacts in
            var f = AssetFacts(asset: AssetSnapshot(id: AssetID("p\(n)"), creationDate: Fixture.date("2023-07-0\(n - 9)")), place: italy, placeSource: .gpsReverseGeocoded)
            f.tripID = it
            return f
        }
        let atlas = TravelAtlas.compute(facts: facts)
        #expect(atlas.countryCodes == ["IT"])
        #expect(atlas.tripCount == 2)
        #expect(atlas.cityCount == 2)
        #expect(atlas.longestTripDays == 6)
        let longest = try #require(atlas.longestTrip)
        #expect(longest.areaName == "Taiwan")
        #expect(longest.countryCode.isEmpty)
        #expect(atlas.trips.first { $0.countryCode == "IT" }?.areaName == nil)
        #expect(atlas.sinceYear == 2023)
        #expect(TravelAtlas.years(facts: facts) == [2024, 2023])
    }

    /// The facts for "Deine Foto-Geschichte" name the area where a country would be, and never
    /// count it as a country.
    @Test func photoStoryNamesTheAreaOfATrip() throws {
        let taiwan = PlaceComponents(locality: "Taipeh").inDisputedArea(try #require(DisputedAreas.area(id: "taiwan")), language: .german)
        let trip = SortlyID.stable("trip", "tw")
        let facts = (0..<6).map { n -> AssetFacts in var f = fact(n, taiwan); f.tripID = trip; return f }
        let lines = PhotoStory.facts(.trips, facts: facts)
        #expect(lines.contains("Erste Reise: Taipeh, Taiwan, 2024, 6 Tage"), "\(lines)")
        #expect(lines.contains("Längste Reise: Taipeh, Taiwan, 2024, 6 Tage"))
        #expect(lines.contains { $0.hasPrefix("Länder insgesamt: 0,") })
        #expect(!lines.contains { $0.contains(", ,") })
        let twoTrips = facts + (20..<26).map { n -> AssetFacts in
            var f = AssetFacts(asset: AssetSnapshot(id: AssetID("p\(n)"), creationDate: Fixture.date("2025-05-0\(n - 19)")), place: taiwan, placeSource: .gpsReverseGeocoded)
            f.tripID = SortlyID.stable("trip", "tw2")
            return f
        }
        let all = PhotoStory.facts(.all, facts: twoTrips)
        #expect(!all.contains { $0.hasPrefix("Am häufigsten bereistes Land") }, "\(all)")
        let year = PhotoStory.facts(.year(2024), facts: facts)
        #expect(year.contains("Reisen in diesem Jahr: Taipeh (Taiwan, 6 Tage)"), "\(year)")
    }

    /// "Ausland" (second review of 752ba07): a German library's Taiwan photos are abroad, and
    /// for a library at home in Taiwan the trips to Japan are, not the photos at home.
    @Test func abroadSearchKnowsDisputedAreas() throws {
        let taiwan = PlaceComponents(locality: "Taipeh").inDisputedArea(try #require(DisputedAreas.area(id: "taiwan")), language: .german)
        let germany = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")
        let japan = PlaceComponents(isoCountryCode: "JP", country: "Japan", locality: "Tokio")
        let german = (0..<10).map { fact($0, taiwan) } + (100..<140).map { fact($0, germany) }
        #expect(Set(SearchIndex(facts: german).search("Ausland").ids) == Set((0..<10).map { AssetID("p\($0)") }))
        let taiwanese = (0..<40).map { fact($0, taiwan) } + (100..<110).map { fact($0, japan) }
        #expect(Set(SearchIndex(facts: taiwanese).search("Ausland").ids) == Set((100..<110).map { AssetID("p\($0)") }))
        // With "Kein Zuhause"-like fallback (no everyday places: every photo on a trip).
        let onTrips = taiwanese.map { f -> AssetFacts in var f = f; f.tripID = SortlyID.stable("trip", "x"); return f }
        #expect(Set(SearchIndex(facts: onTrips).search("Ausland").ids) == Set((100..<110).map { AssetID("p\($0)") }))
    }

    /// A home in a disputed area keeps its area (second review of 752ba07): its key is the
    /// area's, not the name's, so it matches the photos there.
    @Test func homeCandidatesKeepTheArea() throws {
        let area = try #require(DisputedAreas.area(id: "taiwan"))
        var lib = LibraryBuilder()
        let taipei = GeoCoordinate(latitude: 25.0330, longitude: 121.5654)
        lib.daily(from: "2026-01-01", to: "2026-01-10", at: taipei, perDay: 1)
        let place = PlaceComponents(locality: "Taipeh").inDisputedArea(area, language: .german)
        let facts = lib.assets.map { AssetFacts(asset: $0, place: place, placeSource: .gpsReverseGeocoded) }
        let candidate = try #require(HomeCandidates.make(facts: facts, calendar: Fixture.calendar).first)
        #expect(candidate.components.disputedArea == "taiwan")
        #expect(candidate.homePlace.keys.contains(PlaceKey(level: .country, path: "disputed-taiwan")))
        let named = try #require(HomeName.components(near: taipei, facts: facts))
        #expect(named.disputedArea == "taiwan")
        let offline = place.inDisputedArea(area, language: .german)
        var regionOnly = offline; regionOnly.locality = nil
        let regionFacts = lib.assets.map { AssetFacts(asset: $0, place: regionOnly, placeSource: .gpsReverseGeocoded) }
        #expect(HomeName.components(near: taipei, facts: regionFacts)?.disputedArea == "taiwan")
    }

    @Test func searchFindsTheAreaByName() throws {
        let crimea = PlaceComponents(locality: "Jalta").inDisputedArea(try #require(DisputedAreas.area(id: "crimea")), language: .german)
        let index = SearchIndex(facts: [fact(0, crimea)])
        #expect(index.search("Krim").ids == [AssetID("p0")])
        #expect(index.search("Jalta").ids == [AssetID("p0")])
    }

    @Test func storedPlacesWithoutTheFieldStillDecode() throws {
        let old = Data(#"{"isoCountryCode":"DE","country":"Deutschland","locality":"München"}"#.utf8)
        let place = try JSONDecoder().decode(PlaceComponents.self, from: old)
        #expect(place.disputedArea == nil)
        #expect(place.key(at: .country)?.path == "de")
        // And a normal place is stored as before (no new field written).
        let encoded = String(decoding: try JSONEncoder().encode(place), as: UTF8.self)
        #expect(!encoded.contains("disputedArea"))
    }
}
