import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyWorldMap

/// Countries' land areas and middles from the offline world map (`CountryGeometry(map:)`): the
/// share images start their arcs in the middle of the home country, and not at all in a country
/// smaller than 30,000 km² (concept §8).
@Suite("Country geometry")
struct CountryGeometryTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    static let geometry = CountryGeometry(map: map)

    func area(_ code: String) throws -> Double { try #require(Self.geometry.squareKilometers[code]) }
    func center(_ code: String) throws -> GeoCoordinate { try #require(Self.geometry.centers[code]) }

    // MARK: Areas

    @Test(arguments: [
        // Official totals (land and inland water). France with its overseas departments (French
        // Guiana, Guadeloupe, Martinique, Réunion, Mayotte), which Natural Earth's France holds.
        ("DE", 357_592.0), ("FR", 643_801.0), ("US", 9_833_520.0), ("RU", 17_098_246.0), ("IS", 103_000.0),
        // South Africa without Lesotho, which is a hole in it; Kazakhstan with Baikonur, a region
        // of its own with Kazakhstan's code and a hole in the rest.
        ("ZA", 1_221_037.0), ("KZ", 2_724_900.0),
    ])
    func areasAreCloseToTheOfficialOnes(code: String, official: Double) throws {
        let area = try area(code)
        #expect(abs(area - official) / official < 0.1, "\(code): \(Int(area)) km²")
    }

    @Test func smallCountriesAreSmall() {
        for code in ["LU", "MT", "LI", "SG", "AD", "MC", "SM", "VA"] {
            #expect(Self.geometry.isSmall(code), "\(code)")
            #expect(Self.geometry.shareOrigin(countryCode: code) == nil, "\(code)")
        }
        for code in ["DE", "AT", "CH", "NL", "IT"] {
            #expect(!Self.geometry.isSmall(code), "\(code)")
            #expect(Self.geometry.shareOrigin(countryCode: code) != nil, "\(code)")
        }
    }

    /// Countries close to 30,000 km², pinned to what the map gives (simplified to about 330 m,
    /// its areas come out up to 2 % below the official ones).
    @Test func borderlineCountriesArePinned() throws {
        // Albania, officially 28,748 km²: the map gives about 28,300.
        #expect(Self.geometry.isSmall("AL"))
        #expect(try (28_000...28_600).contains(area("AL")))
        // Armenia, officially 29,743 km²: the map gives about 29,550 with the two Azerbaijani
        // exclaves taken away (counted as land, it would come close to 29,600).
        #expect(Self.geometry.isSmall("AM"))
        #expect(try (29_300...29_800).contains(area("AM")))
        // Belgium, officially 30,689 km²: the map gives about 30,560.
        #expect(!Self.geometry.isSmall("BE"))
        #expect(try (30_300...30_700).contains(area("BE")))
        // Lesotho, officially 30,355 km²: the map gives about 30,150, just not small.
        #expect(!Self.geometry.isSmall("LS"))
    }

    @Test func holesAreTakenAwayAndKeptOutOfTheMiddle() throws {
        // Lesotho lies inside South Africa: neither its area nor the middle belong to South Africa.
        #expect(try area("ZA") < 1_240_000)
        #expect(try Self.map.lookup(center("ZA")).country?.isoCode == "ZA")
        // San Marino lies inside Italy.
        #expect(try Self.map.lookup(center("IT")).country?.isoCode == "IT")
    }

    /// The map's rings carry no hole flag; the geometry tells holes by the way they turn. Here
    /// every ring of the map is checked against containment: a ring inside an odd number of the
    /// region's other rings is a hole, and only such a ring turns against the region's largest.
    @Test func holesTurnAgainstTheirLand() {
        var holes = 0
        for region in Self.map.regions where region.level == .country {
            let rings = Self.map.outline(of: region)
            let shape = CountryGeometryBuilder.Shape(rings: rings)
            let boxes = rings.map(Box.init)
            for (i, ring) in rings.enumerated() {
                let corner = ring[0]
                var depth = 0
                for (j, other) in rings.enumerated() where j != i && boxes[j].contains(corner) && Self.contains(other, corner) { depth += 1 }
                #expect(shape.holes[i] == (depth % 2 == 1), "\(region.nameEN) ring \(i)")
                if depth % 2 == 1 { holes += 1 }
            }
        }
        // Lesotho, San Marino, Llívia, Baikonur, the enclaves of the Fergana valley, ...
        #expect(holes >= 15)
    }

    // MARK: Middles

    /// Every country of 30,000 km² or more has its middle inside it, as the map's own lookup
    /// tells. The exceptions are the disputed areas with a code of their own (Western Sahara,
    /// Taiwan): the lookup takes no side there, so it names no country.
    @Test func everyLargeCountryHasItsMiddleInside() throws {
        var disputed: [String] = []
        var checked = 0
        for (code, area) in Self.geometry.squareKilometers.sorted(by: { $0.key < $1.key }) where area >= CountryGeometry.smallCountrySquareKilometers {
            let match = Self.map.lookup(try center(code))
            checked += 1
            if match.disputedArea != nil {
                disputed.append(code)
                continue
            }
            #expect(match.country?.isoCode == code, "\(code) has its middle in \(match.country?.isoCode ?? "no country")")
        }
        #expect(disputed == ["EH", "TW"])
        #expect(checked > 140)
    }

    @Test func middlesLieInTheMainLand() throws {
        // Croatia's crescent: the centroid of its main land lies in Bosnia, the middle does not.
        let croatia = try #require(Self.map.country(code: "HR"))
        let mainLand = try #require(Self.map.outline(of: croatia).max { $0.count < $1.count })
        #expect(Self.map.lookup(try #require(GeoMath.centroid(mainLand))).country?.isoCode == "BA")
        #expect(try Self.map.lookup(center("HR")).country?.isoCode == "HR")
        // Vietnam's centroid lies in Laos.
        #expect(try Self.map.lookup(center("VN")).country?.isoCode == "VN")
        // Mainland France, not French Guiana or Corsica.
        let france = try center("FR")
        #expect((43.0...50.0).contains(france.latitude) && (-2.0...7.0).contains(france.longitude))
        // The contiguous United States, not Alaska or Hawaii.
        let us = try center("US")
        #expect((24.5...49.5).contains(us.latitude) && (-125.0 ... -66.9).contains(us.longitude))
        #expect(try Self.map.lookup(center("US")).country?.isoCode == "US")
        #expect(try Self.map.lookup(center("RU")).country?.isoCode == "RU")
        // Fiji's main island, Viti Levu; Antarctica's middle on the ice, round the pole.
        let fiji = try center("FJ")
        #expect(fiji.longitude > 177 && fiji.longitude < 179)
        #expect(try Self.map.lookup(center("FJ")).country?.isoCode == "FJ")
        #expect(try Self.map.lookup(center("AQ")).country?.isoCode == "AQ")
        #expect(try center("AQ").latitude < -75)
    }

    // MARK: Codes

    /// The map gives several regions one code. `OfflineWorldMap.country(code:)` answers with the
    /// first that is not disputed, which for "FR" is Clipperton Island; the geometry takes them
    /// all but the disputed ones.
    @Test func regionsSharingACodeMakeOneCountry() throws {
        #expect(Self.map.country(code: "FR")?.nameEN == "Clipperton Island")
        #expect(try area("FR") > 600_000)
        #expect(try area("AU") > 7_500_000)
        #expect(try area("KZ") > 2_700_000)
        // Somalia with Somaliland, which Apple's lookup also calls "SO".
        #expect(try area("SO") > 600_000)
        #expect(try Self.map.lookup(center("SO")).country?.isoCode == "SO")
        // Northern Cyprus is a disputed area, no part of Cyprus (nor a country).
        #expect(try area("CY") < 6_500)
        let cyprus = Self.map.lookup(try center("CY"))
        #expect(cyprus.disputedArea == nil && cyprus.country?.nameEN == "Cyprus")
    }

    @Test func onlyTwoLetterCodesAreKept() {
        let codes = Self.geometry.squareKilometers.keys
        #expect(codes.count > 230)
        #expect(codes.allSatisfy { $0.count == 2 && $0.allSatisfy { ("A"..."Z").contains($0) } })
        #expect(Set(codes) == Set(Self.geometry.centers.keys))
        #expect(CountryGeometryBuilder.isCountryCode("DE"))
        for code in ["-99", "", "D", "DEU", "de", "D1"] { #expect(!CountryGeometryBuilder.isCountryCode(code), "\(code)") }
    }

    // MARK: The antimeridian and the poles

    @Test func ringsAcrossTheAntimeridianAndRoundAPoleKeepTheirShape() throws {
        // A square of 1° at the equator has the same area on either side of 180°.
        func square(_ lon: Double) -> [GeoCoordinate] {
            [MapFixture.at(-0.5, lon - 0.5), MapFixture.at(-0.5, MapHome.normalizedLongitude(lon + 0.5)),
             MapFixture.at(0.5, MapHome.normalizedLongitude(lon + 0.5)), MapFixture.at(0.5, lon - 0.5)]
        }
        let greenwich = abs(CountryGeometryBuilder.signedArea(square(0)))
        let dateLine = abs(CountryGeometryBuilder.signedArea(square(180)))
        let squareKilometers = greenwich * GeoMath.earthRadiusMeters * GeoMath.earthRadiusMeters / 1_000_000
        #expect(abs(squareKilometers - 12_364) < 50)
        #expect(abs(dateLine - greenwich) < 1e-12)
        // Its middle lies on the date line, not on the other side of the Earth.
        let middle = try #require(CountryGeometryBuilder.Shape(rings: [square(180)]).center)
        #expect(abs(middle.latitude) < 0.05 && abs(abs(middle.longitude) - 180) < 0.05)
        // A ring round the south pole at 80° S: a cap of 3.87 million km², its middle at the pole.
        let ring = stride(from: -180.0, to: 180, by: 5).map { MapFixture.at(-80, $0) }
        let cap = abs(CountryGeometryBuilder.signedArea(ring)) * GeoMath.earthRadiusMeters * GeoMath.earthRadiusMeters / 1_000_000
        #expect(abs(cap - 3_873_000) / 3_873_000 < 0.01)
        #expect(try #require(CountryGeometryBuilder.Shape(rings: [ring]).center).latitude < -89)
        // A ring larger than a hemisphere counts as the smaller part.
        let north = stride(from: -180.0, to: 180, by: 5).map { MapFixture.at(10, $0) }
        let small = abs(CountryGeometryBuilder.signedArea(north))
        #expect(small < 2 * .pi)
    }

    // MARK: Speed and order

    /// It runs once per app start: well under a second for the whole map, in this unoptimised
    /// test build too (about 0.3 s alone; the fastest of three runs counts, so a busy machine
    /// does not fail it). The search for the middles, most of the work, is also counted, which
    /// does not depend on the machine: about 18,000 squares and 1.5 million edge distances.
    @Test func buildsTheWholeMapWellUnderASecond() {
        let clock = ContinuousClock()
        var fastest = Duration.seconds(60)
        for _ in 0..<3 {
            var geometry = CountryGeometry()
            let elapsed = clock.measure { geometry = CountryGeometry(map: Self.map) }
            fastest = min(fastest, elapsed)
            #expect(geometry == Self.geometry)
        }
        #expect(fastest < .seconds(1), "\(fastest)")
        var work = CountryGeometryBuilder.SearchWork()
        for region in Self.map.regions where region.level == .country && CountryGeometryBuilder.isCountryCode(region.isoCode) {
            let shape = CountryGeometryBuilder.Shape(rings: Self.map.outline(of: region))
            work.cells += shape.work.cells
            work.edges += shape.work.edges
        }
        #expect(work.cells < 25_000, "\(work.cells) squares")
        #expect(work.edges < 2_000_000, "\(work.edges) edge distances")
    }

    // MARK: Helpers

    /// Even-odd containment in plain degrees: the map's rings are cut at the antimeridian, and
    /// Antarctica's, which runs along the pole, is a band in degrees, as the map's lookup reads it.
    static func contains(_ ring: [GeoCoordinate], _ p: GeoCoordinate) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude),
               p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    struct Box {
        var minLatitude = Double.infinity, maxLatitude = -Double.infinity
        var minLongitude = Double.infinity, maxLongitude = -Double.infinity

        init(_ ring: [GeoCoordinate]) {
            for c in ring {
                minLatitude = min(minLatitude, c.latitude); maxLatitude = max(maxLatitude, c.latitude)
                minLongitude = min(minLongitude, c.longitude); maxLongitude = max(maxLongitude, c.longitude)
            }
        }

        func contains(_ c: GeoCoordinate) -> Bool {
            (minLatitude...maxLatitude).contains(c.latitude) && (minLongitude...maxLongitude).contains(c.longitude)
        }
    }
}
