import Foundation
import Testing
@testable import AlbumistCore
import AlbumistWorldMap
import AlbumistTestSupport

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
        // The map's Israel reaches past the 1974 line's outline in the east and on the Hermon
        // (review of bundle-i, 19.11.): Alonei HaBashan was "Israel" and called certain.
        ("Alonei HaBashan", 33.0447, 35.8347, "golan"),
        ("Golan-Ostrand bei Ein Zivan", 33.17, 35.83, "golan"),
        ("Hermon, israelisch gehalten", 33.34, 35.77, "golan"),
        // At sea, where the map draws no country (second review of 752ba07): the area's own
        // waters say "nicht sicher" too, whatever Apple's lookup would answer.
        ("vor El Aaiún, 20 km", 27.15, -13.45, "western-sahara"),
        ("vor Jalta, 5 km", 44.45, 34.20, "crimea"),
        ("Krim-Brücke, Mitte", 45.30, 36.53, "crimea"),
        // Islands the map does not draw.
        ("Liuqiu", 22.34, 120.37, "taiwan"),
        ("Matsu, Nangan", 26.1597, 119.95, "taiwan"),
        ("Pratas", 20.70, 116.72, "taiwan"),
        // Taiwan-held islands off Xiamen and Fujian the map does not draw either (review of
        // bundle-i, 19.11.: Apple's "CN" made them "China").
        ("Lieyu (Klein-Kinmen)", 24.43, 118.24, "taiwan"),
        ("Dadan", 24.383, 118.133, "taiwan"),
        ("Erdan", 24.367, 118.117, "taiwan"),
        ("Wuqiu", 24.983, 119.45, "taiwan"),
        // Dongding, 25 km south of Kinmen (second review of bundle-i).
        ("Dongding", 24.163, 118.232, "taiwan"),
        // The waters of Northern Cyprus (review of bundle-i: 3 km off Kyrenia Apple's "CY"
        // made it "Republik Zypern").
        ("vor Kyrenia, 3 km", 35.37, 33.32, "northern-cyprus"),
        ("vor Varosha", 35.11, 34.02, "northern-cyprus"),
        ("Bucht von Morphou", 35.25, 32.85, "northern-cyprus"),
        ("vor Kap Apostolos Andreas", 35.72, 34.65, "northern-cyprus"),
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
        ("Snir", 33.2430, 35.6680, "IL"),
        ("Ein Gev", 32.7820, 35.6400, "IL"),
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

    /// Israel inside its 1949 lines lies west of 35.70° E between the Yarmouk and the Hermon;
    /// everything the map gives Israel east of it is the Golan (review of bundle-i, 19.11.: a
    /// strip along the 1974 line and the Hermon were "Israel", certain).
    @Test func theMapsIsraelEastOfTheHulaValleyIsAllGolan() {
        var leaks: [String] = []
        for i in 0...70 {
            for j in 0...25 {
                let lat = 32.70 + Double(i) * 0.01, lon = 35.70 + Double(j) * 0.01
                let m = at(lat, lon)
                if m.disputedArea == nil, m.countryCandidates.first?.isoCode == "IL" { leaks.append("\(lat),\(lon)") }
            }
        }
        #expect(leaks.isEmpty, "\(leaks)")
    }

    /// Sea and undrawn land next to the new outlines keep no area: Apple's answer decides there
    /// as before (review of bundle-i, 19.11.).
    @Test(arguments: [
        ("Xiamen, Ostküste", 24.45, 118.18), ("Gulangyu", 24.447, 118.067), ("Dadeng", 24.56, 118.32),
        ("vor Larnaka", 34.88, 33.70), ("vor Limassol", 34.62, 33.08), ("vor Paphos", 34.74, 32.35),
        ("vor Protaras", 35.04, 34.11), ("Bucht von Polis", 35.08, 32.40), ("vor Kato Pyrgos und Kokkina", 35.21, 32.65),
        // North-east of Protaras and off Kapparis the Republic's coast is nearer than Varosha
        // (second review of bundle-i: the outline's corner on 35.075° N took these waters).
        ("vor Kapparis, 3 km", 35.077, 34.035), ("nordöstlich von Protaras", 35.08, 34.08), ("vor Pernera, 8 km", 35.10, 34.10),
    ])
    func seaAndIslandsNextToTheOutlinesTakeNoArea(name: String, lat: Double, lon: Double) {
        let m = at(lat, lon)
        #expect(m.disputedArea == nil, "\(name)")
    }

    // MARK: Atlas map

    /// The atlas map never fills a disputed area as a visited country (review of bundle-i,
    /// 19.11.: Crimea lit up with Russia, Northern Cyprus with Cyprus, Kashmir with India and
    /// Pakistan, also in the share picture). Every country is visited here; full detail.
    @Test(arguments: [
        ("Simferopol", 44.9521, 34.1024), ("Srinagar", 34.0837, 74.7973), ("Leh", 34.1526, 77.5771),
        ("Gilgit", 35.9208, 74.3089), ("Muzaffarabad", 34.3700, 73.4711), ("Aksai Chin", 35.2, 79.5),
        ("Kyrenia", 35.3364, 33.3199), ("Pristina", 42.6629, 21.1655), ("Taipeh", 25.0330, 121.5654),
        ("Katzrin", 32.9925, 35.6914), ("El Aaiún", 27.1253, -13.1625), ("Smara", 26.7384, -11.6719),
        ("Abchasien", 43.05, 41.20),
    ])
    func atlasNeverFillsADisputedArea(name: String, lat: Double, lon: Double) {
        let point = GeoCoordinate(latitude: lat, longitude: lon)
        #expect(AtlasShapes.filledCode(at: point, in: Self.shapes, visited: Self.everyCode) == nil, "\(name)")
    }

    @Test(arguments: [
        ("Moskau", 55.7558, 37.6173, "RU"), ("Kiew", 50.4501, 30.5234, "UA"), ("Delhi", 28.6139, 77.2090, "IN"),
        ("Lahore", 31.5204, 74.3587, "PK"), ("Tiflis", 41.7151, 44.8271, "GE"), ("Tel Aviv", 32.0853, 34.7818, "IL"),
        ("Rabat", 34.0209, -6.8416, "MA"), ("Peking", 39.9042, 116.4074, "CN"), ("Limassol", 34.7071, 33.0226, "CY"),
        ("Belgrad", 44.7866, 20.4489, "RS"), ("Damaskus", 33.5138, 36.2765, "SY"),
        // Syrian-held Golan east of the line: the Golan outline is painted over Israel only.
        ("Hader", 33.2670, 35.8500, "SY"),
    ])
    func atlasFillsTheCountriesAround(name: String, lat: Double, lon: Double, code: String) {
        let point = GeoCoordinate(latitude: lat, longitude: lon)
        #expect(AtlasShapes.filledCode(at: point, in: Self.shapes, visited: Self.everyCode) == code, "\(name)")
    }

    /// A tap on the atlas map opens the visited country there, or the nearest one within a
    /// few points (small countries); in a disputed area it opens nothing: the area is never a
    /// side's country and has no screen of its own (second review of bundle-i: a tap on the
    /// grey Crimea opened "Russland"). 12° is about the app's 12 points on a phone (a map about
    /// 330 points wide: 13°).
    @Test(arguments: [
        ("Simferopol", 44.9521, 34.1024), ("Srinagar", 34.0837, 74.7973), ("Leh", 34.1526, 77.5771),
        ("Gilgit", 35.9208, 74.3089), ("Muzaffarabad", 34.3700, 73.4711), ("Aksai Chin", 35.2, 79.5),
        ("Kyrenia", 35.3364, 33.3199), ("Pristina", 42.6629, 21.1655), ("Taipeh", 25.0330, 121.5654),
        ("Katzrin", 32.9925, 35.6914), ("El Aaiún", 27.1253, -13.1625), ("Smara", 26.7384, -11.6719),
        ("Abchasien", 43.05, 41.20),
    ])
    func atlasTapInADisputedAreaOpensNothing(name: String, lat: Double, lon: Double) {
        let point = GeoCoordinate(latitude: lat, longitude: lon)
        #expect(AtlasShapes.tappedCode(at: point, in: Self.shapes, visited: Self.everyCode, slackDegrees: 12) == nil, "\(name)")
    }

    @Test(arguments: [
        ("Moskau", 55.7558, 37.6173, "RU"), ("Kiew", 50.4501, 30.5234, "UA"), ("Limassol", 34.7071, 33.0226, "CY"),
        ("Belgrad", 44.7866, 20.4489, "RS"), ("Hader", 33.2670, 35.8500, "SY"), ("Tel Aviv", 32.0853, 34.7818, "IL"),
        ("Rabat", 34.0209, -6.8416, "MA"), ("Delhi", 28.6139, 77.2090, "IN"),
    ])
    func atlasTapOpensTheVisitedCountry(name: String, lat: Double, lon: Double, code: String) {
        let point = GeoCoordinate(latitude: lat, longitude: lon)
        #expect(AtlasShapes.tappedCode(at: point, in: Self.shapes, visited: Self.everyCode, slackDegrees: 12) == code, "\(name)")
    }

    /// The slack finds a small visited country next to the finger, measured to its coast and
    /// borders: a tap in Paris with only Russia visited opened Russia before, whose box spans
    /// the whole map from 41° N up.
    @Test func atlasTapSlackFindsTheNearCountryOnly() {
        // The detailed shapes and the app's (0.3° steps) give the same answer.
        let app = AtlasShapes.make(from: Self.map, minimumStepDegrees: 0.3)
        func tap(_ lat: Double, _ lon: Double, _ visited: Set<String>, _ slack: Double) -> String? {
            let point = GeoCoordinate(latitude: lat, longitude: lon)
            let code = AtlasShapes.tappedCode(at: point, in: Self.shapes, visited: visited, slackDegrees: slack)
            #expect(AtlasShapes.tappedCode(at: point, in: app, visited: visited, slackDegrees: slack) == code, "\(lat), \(lon) in the app's shapes")
            return code
        }
        #expect(tap(50.85, 4.35, ["LU"], 2) == "LU") // Brussels, Luxembourg 1.5° away
        #expect(tap(48.8566, 2.3522, ["RU"], 2) == nil) // Paris
        #expect(tap(48.8566, 2.3522, ["RU", "LU"], 6) == "LU")
        #expect(tap(20, -40, ["BR"], 2) == nil) // the Atlantic
        // The coast and borders of a disputed area are not the country's: the slack measures to
        // what the map fills (review of b376999: a tap on the sea off the grey Crimea opened
        // Russia, one in Mauritania beside the grey Western Sahara Morocco).
        #expect(tap(44.35, 33.8, ["RU"], 1) == nil) // the sea off Yalta
        #expect(tap(21.0, -15.0, ["MA"], 2) == nil) // Mauritania, 0.3° off Western Sahara
        #expect(tap(44.5, 37.7, ["RU"], 1) == "RU") // the sea off Novorossiysk
        #expect(tap(30.4, -10.5, ["MA"], 1) == "MA") // the Atlantic off Agadir
    }

    /// With Russia visited, nothing of the Crimea and its coast is filled at the app's 0.3°
    /// steps (review of b376999): simplified each on its own, the map's Russia and its Crimea
    /// regions no longer met, and the visited colour showed in a strip between Sevastopol and
    /// the rest of the Crimea, off Yevpatoria and at Perekop. The box reaches past Perekop and
    /// keeps out Taman (east of 36.2° E).
    @Test func atlasFillsNoSliverOfRussiaRoundTheCrimea() {
        let app = AtlasShapes.make(from: Self.map, minimumStepDegrees: 0.3)
        var filled: [String] = []
        for lat in stride(from: 44.30, through: 46.20, by: 0.02) {
            for lon in stride(from: 32.40, through: 36.20, by: 0.02)
            where AtlasShapes.filledCode(at: GeoCoordinate(latitude: lat, longitude: lon), in: app, visited: ["RU"]) != nil {
                filled.append(String(format: "%.2f,%.2f", lat, lon))
            }
        }
        // One point off Foros, where the map's Russia and its region differ by a few metres at
        // full detail, far under a pixel. Before: 140 of these points.
        #expect(filled.count <= 1, "\(filled.count) points, \(filled.prefix(5))")
        // Russia on the other side of the Kerch Strait is filled.
        #expect(AtlasShapes.filledCode(at: GeoCoordinate(latitude: 45.25, longitude: 36.95), in: app, visited: ["RU"]) == "RU")
    }

    @Test func atlasShapesForTheApp() {
        let coarse = AtlasShapes.make(from: Self.map, minimumStepDegrees: 0.3)
        #expect(coarse.filter { !$0.isNeutral }.count > 200)
        #expect(!coarse.contains { $0.code == "AQ" })
        // Northern Cyprus shares "CY" in the map: it is never filled with the Republic.
        #expect(coarse.filter { $0.code == "CY" }.count == 1)
        for shape in coarse where shape.isNeutral {
            #expect(shape.code.isEmpty && !shape.rings.isEmpty)
            #expect(shape.neutralOver.allSatisfy { $0.count == 2 })
        }
        // No outline over the sea only (the waters of Crimea) is painted: it would draw land.
        #expect(Set(coarse.flatMap(\.neutralOver)) == ["RU", "IN", "PK", "GE", "CN", "IL", "MA"])
    }

    static let shapes = AtlasShapes.make(from: map, minimumStepDegrees: 0)
    static let everyCode = Set(shapes.map(\.code).filter { !$0.isEmpty })

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
        let tw = AlbumistID.stable("trip", "tw"), it = AlbumistID.stable("trip", "it")
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
        let trip = AlbumistID.stable("trip", "tw")
        let facts = (0..<6).map { n -> AssetFacts in var f = fact(n, taiwan); f.tripID = trip; return f }
        let lines = PhotoStory.facts(.trips, facts: facts)
        #expect(lines.contains("Erste Reise: Taipeh, Taiwan, 2024, 6 Tage"), "\(lines)")
        #expect(lines.contains("Längste Reise: Taipeh, Taiwan, 2024, 6 Tage"))
        #expect(lines.contains { $0.hasPrefix("Länder insgesamt: 0,") })
        #expect(!lines.contains { $0.contains(", ,") })
        let twoTrips = facts + (20..<26).map { n -> AssetFacts in
            var f = AssetFacts(asset: AssetSnapshot(id: AssetID("p\(n)"), creationDate: Fixture.date("2025-05-0\(n - 19)")), place: taiwan, placeSource: .gpsReverseGeocoded)
            f.tripID = AlbumistID.stable("trip", "tw2")
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
        let onTrips = taiwanese.map { f -> AssetFacts in var f = f; f.tripID = AlbumistID.stable("trip", "x"); return f }
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
