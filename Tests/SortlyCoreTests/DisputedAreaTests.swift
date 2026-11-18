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
