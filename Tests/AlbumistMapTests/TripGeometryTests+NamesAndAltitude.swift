import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Names, photos and altitude of a place: its name, its cover candidates (analysed photos,
/// favourites first, then the largest) as the cover picker sorts them, its altitude and a
/// summit's.
extension TripGeometryTests {
    // MARK: Names, photos and altitude of a place

    @Test func placeNames() throws {
        func name(_ components: [PlaceComponents?]) -> String? {
            let facts = components.enumerated().map { i, place in
                var fact = MapFixture.photo("n-\(i)", at: MapFixture.date("2023-08-01 10:00").addingTimeInterval(Double(i) * 60),
                                            Fixture.jitter(Places.florence, seed: i, meters: 200))
                fact.place = place
                fact.placeSource = place == nil ? nil : .gpsReverseGeocoded
                return fact
            }
            return Self.build(facts).places.first?.name
        }
        let uffizi = PlaceComponents(isoCountryCode: "IT", country: "Italia", administrativeArea: "Toscana", subAdministrativeArea: "Firenze",
                                     locality: "Firenze", areaOfInterest: "Uffizi")
        let town = PlaceComponents(isoCountryCode: "IT", country: "Italia", administrativeArea: "Toscana", subAdministrativeArea: "Firenze",
                                   locality: "Firenze")
        // A point of interest naming half the photos names the place; fewer, the town.
        #expect(name([uffizi, uffizi, town, town]) == "Uffizi")
        #expect(name([uffizi, town, town, town]) == "Firenze")
        // Photos not geocoded yet count against the point of interest.
        #expect(name([uffizi, uffizi, nil, nil, nil]) == "Firenze")
        // Without a town the district, then the region, then the country.
        #expect(name([PlaceComponents(country: "Italia", administrativeArea: "Toscana", subAdministrativeArea: "Chianti")] + Array(repeating: nil, count: 3))
                == "Chianti")
        #expect(name(Array(repeating: PlaceComponents(country: "Italia", administrativeArea: "Toscana"), count: 3)) == "Toscana")
        #expect(name(Array(repeating: PlaceComponents(isoCountryCode: "IT", country: "Italia"), count: 3)) == "Italia")
        // Ties alphabetically; empty names are no names.
        let fiesole = PlaceComponents(isoCountryCode: "IT", locality: "Fiesole"), empty = PlaceComponents(isoCountryCode: "IT", locality: "")
        #expect(name([town, fiesole, town, fiesole, empty, empty, empty]) == "Fiesole")
        #expect(name([nil, nil, nil]) == nil)
    }

    @Test func coverCandidatesAreAnalysedPhotosFavouritesFirstThenTheLargest() throws {
        let start = MapFixture.date("2023-08-02 10:00")
        func photo(_ id: String, _ i: Int, favorite: Bool = false, pixels: (Int, Int) = (4032, 3024), kind: MediaKind = .image,
                   analysed: Bool = true, document: Bool = false) -> AssetFacts {
            var fact = MapFixture.photo(id, at: start.addingTimeInterval(Double(i) * 60), Fixture.jitter(Places.porto, seed: i, meters: 200),
                                        country: "PT", town: "Porto", favorite: favorite, analysed: analysed, kind: kind)
            fact.asset.pixelWidth = pixels.0
            fact.asset.pixelHeight = pixels.1
            fact.looksLikeDocument = document
            return fact
        }
        let facts = [
            photo("a-small", 0, pixels: (1000, 1000)), photo("b-large", 1, pixels: (8000, 6000)), photo("c-fav-small", 2, favorite: true, pixels: (800, 600)),
            photo("d-fav-large", 3, favorite: true), photo("e-video", 4, favorite: true, kind: .video), photo("f-unknown", 5, favorite: true, analysed: false),
            photo("g-document", 6, favorite: true, document: true), photo("h-same", 7), photo("i-same", 8), photo("j-same", 9),
        ]
        let place = try #require(Self.build(Self.shuffled(facts, seed: 9)).places.first)
        #expect(place.photoCount == 10)
        #expect(place.coverCandidates == ["d-fav-large", "c-fav-small", "b-large", "h-same", "i-same", "j-same"])

        // Only ordinary photos: the six largest. An id given twice is one photo, with the facts
        // `isKept(_:over:)` prefers whatever their order: "o2" again, later and as a favourite, is
        // the same photo in another state, and the facts kept (the earlier, no favourite) decide.
        let ordinary = (0..<9).map { photo("o\($0)", $0, pixels: (1_000 + $0 * 100, 1_000)) }
        let again = [photo("o8", 9, pixels: (1_800, 1_000)), photo("o2", 10, favorite: true, pixels: (1_200, 1_000))]
        #expect(!TripGeometryBuilder.isKept(again[1], over: ordinary[2]) && TripGeometryBuilder.isKept(ordinary[2], over: again[1]))
        for seed in [1, 2, 3] as [UInt64] {
            let best = try #require(Self.build(Self.shuffled(ordinary + again, seed: seed)).places.first)
            #expect(best.photoCount == 9)
            #expect(best.coverCandidates == ["o8", "o7", "o6", "o5", "o4", "o3"])
        }
    }

    @Test func coverPickerGivesWhatSortingGives() {
        // One pass keeping the best six gives the first six ids of all of them sorted, an id that
        // comes again (with another rank) taken once.
        var random = MapRandom(seed: 6)
        for _ in 0..<300 {
            let covers = (0..<random.int(0..<30)).compactMap { i -> TripGeometryBuilder.Cover? in
                var fact = MapFixture.photo("p\(random.int(0..<12))", at: MapFixture.date("2023-08-02 10:00"), Places.porto,
                                            favorite: random.int(0..<3) == 0)
                fact.asset.pixelWidth = 100 * random.int(1..<4)
                return TripGeometryBuilder.Cover(fact, at: i)
            }
            var picker = TripGeometryBuilder.CoverPicker(limit: TripGeometry.coverCandidateLimit)
            for cover in covers { picker.add(cover) }
            var expected: [AssetID] = []
            for cover in covers.sorted(by: { $0.ranks(before: $1) })
            where expected.count < TripGeometry.coverCandidateLimit && !expected.contains(cover.id) {
                expected.append(cover.id)
            }
            #expect(picker.ids == expected)
        }
    }

    @Test func placeAltitude() throws {
        func altitude(_ values: [Double?], at place: GeoCoordinate) -> Double? {
            let facts = values.indices.map { i in
                MapFixture.photo("alt-\(i)", at: MapFixture.date("2023-08-03 09:00").addingTimeInterval(Double(i) * 600),
                                 Fixture.jitter(place, seed: i, meters: 300), country: "CH")
            }
            var altitudes: [AssetID: Double] = [:]
            for (i, value) in values.enumerated() { altitudes[facts[i].id] = value }
            return Self.build(facts, altitudes: altitudes).places.first?.altitude
        }
        let zermatt = MapFixture.at(46.0207, 7.7491)
        // Three agreeing: their mean.
        #expect(altitude([1_600, 1_620, 1_640], at: zermatt) == 1_620)
        // 150 m apart still agree, 400 m do not.
        #expect(altitude([1_600, 1_675, 1_750], at: zermatt) == 1_675)
        #expect(altitude([1_400, 1_600, 1_800], at: zermatt) == nil)
        // Only scattered altitudes, no three within 150 m: none.
        #expect(altitude([1_000, 1_200, 1_400, 1_600, 1_800, 2_000], at: zermatt) == nil)
        // One above 6,000 m (a plane's, if not filtered) does not count; the others do.
        #expect(altitude([1_600, 1_620, 7_000], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, 1_640, 7_000], at: zermatt) == 1_620)
        // A cable car from the valley to the top within the place's 3 km: the highest group.
        #expect(altitude([1_610, 1_600, 3_100, 1_620, 3_050, 3_000, 2_400], at: zermatt) == 3_050)
        // Fewer than three photos with an altitude: none; one that is no number does not count.
        #expect(altitude([1_600, 1_620, nil, nil, nil], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, .nan], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, 1_610, .nan], at: zermatt) == 1_610)
        // Below sea level is fine (the Dead Sea shore).
        #expect(altitude([-420, -415, -410], at: MapFixture.at(31.5590, 35.4732)) == -415)
    }

    /// "Höchstes Foto" (concept §5): the mean of the highest group of at least three photos of a
    /// place whose altitudes lie within `TripGeometry.altitudeSpreadMeters` of each other (review:
    /// summit photos from 2,600 to 2,962 m got no altitude, and the record went to a lake at 600 m).
    @Test func aSummitKeepsItsAltitude() throws {
        // The Eibsee one day; the next, the Zugspitze: the glacier at 2,600 m, the way up, the
        // summit at 2,962 m, all within 1.5 km.
        let lake = MapFixture.at(47.4571, 10.9813), summit = MapFixture.at(47.4211, 10.9853)
        let lakeAltitudes = [600.0, 602, 598, 601]
        let summitAltitudes = [2_600.0, 2_650, 2_700, 2_780, 2_870, 2_930, 2_945, 2_955, 2_962]
        let photos = lakeAltitudes.indices.map { i in
            MapFixture.photo("lake-\(i)", at: MapFixture.date("2023-08-04 10:00").addingTimeInterval(Double(i) * 600),
                             Fixture.jitter(lake, seed: i, meters: 300), country: "DE", town: "Eibsee", timeZone: "Europe/Berlin")
        } + summitAltitudes.indices.map { i in
            let below = Double(summitAltitudes.count - 1 - i)
            return MapFixture.photo("top-\(i)", at: MapFixture.date("2023-08-05 09:00").addingTimeInterval(Double(i) * 600),
                                    Self.offset(summit, east: -below * 150, north: -below * 100), country: "DE", town: "Zugspitze",
                                    timeZone: "Europe/Berlin")
        }
        var altitudes: [AssetID: Double] = [:]
        for (i, value) in lakeAltitudes.enumerated() { altitudes[AssetID("lake-\(i)")] = value }
        for (i, value) in summitAltitudes.enumerated() { altitudes[AssetID("top-\(i)")] = value }
        let geometry = Self.build(photos, altitudes: altitudes)
        #expect(geometry.places.map(\.name) == ["Eibsee", "Zugspitze"])
        #expect(geometry.places[0].altitude == 600.25)
        // The summit's group: everything within 150 m below its highest photo, 2,870 to 2,962 m.
        let top = try #require(geometry.places[1].altitude)
        #expect(abs(top - (2_870 + 2_930 + 2_945 + 2_955 + 2_962) / 5) < 1e-9)
        #expect(geometry.places.max { ($0.altitude ?? -.infinity) < ($1.altitude ?? -.infinity) }?.name == "Zugspitze")
    }
}
