import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Geography")
struct GeoTests {
    @Test func haversineDistanceMunichRome() {
        let d = GeoMath.distance(Fixture.Places.munichHome, Fixture.Places.rome)
        #expect(abs(d - 698_000) < 10_000) // ≈ 698 km great-circle
    }

    @Test func centroidAcrossAntimeridian() throws {
        let c = try #require(GeoMath.centroid([
            GeoCoordinate(latitude: 0, longitude: 179.5),
            GeoCoordinate(latitude: 0, longitude: -179.5),
        ]))
        #expect(abs(abs(c.longitude) - 180) < 0.01)
    }

    @Test func implausibleCoordinatesAreIgnored() {
        #expect(!GeoCoordinate(latitude: 0, longitude: 0).isPlausible)
        #expect(!GeoCoordinate(latitude: 91, longitude: 0).isPlausible)
        let asset = AssetSnapshot(id: "a", location: GeoCoordinate(latitude: 48, longitude: 11), locationAccuracy: 20_000)
        #expect(asset.usableLocation == nil)
    }

    @Test func spatialIndexFindsAllNeighboursIncludingAcrossCells() {
        var points: [(GeoCoordinate, Int)] = []
        for i in 0..<400 {
            let lat = 47.9 + Double(i % 20) * 0.0012
            let lon = 11.4 + Double(i / 20) * 0.0017
            points.append((GeoCoordinate(latitude: lat, longitude: lon), i))
        }
        let index = GeoSpatialIndex(cellSize: 200, points: points)
        for probe in stride(from: 0, to: 400, by: 37) {
            let center = points[probe].0
            let expected = Set(points.filter { GeoMath.distance($0.0, center) <= 200 }.map(\.1))
            let actual = Set(index.query(near: center, radius: 200).map(\.element))
            #expect(expected == actual)
        }
    }

    /// G1-01 (review 18.11.2026): far in the north the query looked at 25 sample points instead
    /// of every cell the circle touches, and a photo within the radius could be missed (78° N
    /// Spitzbergen, 85° N, 88.5° N, across the antimeridian). The query must find exactly what a
    /// check of every point finds, at any latitude, also with a radius below the cell size.
    @Test(arguments: [0.0, 48.1, 60.0, 71.0, 78.2, 85.0, 88.5, 89.6, -54.8, -78.0, -89.7])
    func spatialIndexFindsEveryNeighbourAtAnyLatitude(latitude: Double) {
        var rng = SeededRandom(seed: UInt64(bitPattern: Int64(latitude * 1_000)))
        for (cellSize, radius) in [(5_000.0, 5_000.0), (5_000.0, 3_100.0), (200.0, 200.0)] {
            var points: [(GeoCoordinate, Int)] = []
            var centers: [GeoCoordinate] = []
            for i in 0..<60 {
                // Half of the centres right at the antimeridian.
                let lon = i.isMultiple(of: 2) ? rng.double(-180, 180) : (rng.double(0, 1) < 0.5 ? 179.99 : -179.99)
                let center = GeoCoordinate(latitude: max(-90, min(90, latitude + rng.double(-0.02, 0.02))), longitude: lon)
                centers.append(center)
                for _ in 0..<40 {
                    // Points in every direction up to a bit beyond the radius.
                    let distance = rng.double(0, 1.15 * radius), bearing = rng.double(0, 2 * .pi)
                    points.append((Self.destination(center, distance: distance, bearing: bearing), points.count))
                }
                // Straight north and south at the radius: the latitude band of a cell is not a
                // degree of the earth's own size.
                points.append((Self.destination(center, distance: 0.999 * radius, bearing: 0), points.count))
                points.append((Self.destination(center, distance: 0.999 * radius, bearing: .pi), points.count))
            }
            let index = GeoSpatialIndex(cellSize: cellSize, points: points)
            var missed = 0, extra = 0
            for center in centers {
                let expected = Set(points.filter { GeoMath.distance($0.0, center) <= radius }.map(\.1))
                let actual = Set(index.query(near: center, radius: radius).map(\.element))
                missed += expected.subtracting(actual).count
                extra += actual.subtracting(expected).count
            }
            #expect(missed == 0, "latitude \(latitude), cell \(cellSize) m, radius \(radius) m: \(missed) points within the radius missed")
            #expect(extra == 0)
        }
    }

    /// The point `distance` metres from `start` in direction `bearing` (radians from north), on
    /// the sphere `GeoMath.distance` measures on.
    static func destination(_ start: GeoCoordinate, distance: Double, bearing: Double) -> GeoCoordinate {
        let d = distance / GeoMath.earthRadiusMeters
        let lat1 = start.latitude * .pi / 180, lon1 = start.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        var lon = lon2 * 180 / .pi
        while lon > 180 { lon -= 360 }
        while lon < -180 { lon += 360 }
        return GeoCoordinate(latitude: lat2 * 180 / .pi, longitude: lon)
    }

    @Test func dbscanSeparatesTwoDenseAreasAndNoise() {
        var coords: [GeoCoordinate] = []
        for i in 0..<30 { coords.append(Fixture.jitter(Fixture.Places.munichHome, seed: i, meters: 80)) }
        for i in 0..<20 { coords.append(Fixture.jitter(Fixture.Places.rome, seed: i + 100, meters: 80)) }
        coords.append(Fixture.Places.tegernsee)
        let result = GeoClusterer(epsilonMeters: 100, minPoints: 4).cluster(coords)
        #expect(result.clusters.count == 2)
        #expect(result.clusters[0].memberIndices.count == 30)
        #expect(result.clusters[1].memberIndices.count == 20)
        #expect(result.noise == [50])
    }

    @Test func continentLookup() {
        #expect(Continent.forCountryCode("it") == .europe)
        #expect(Continent.forCountryCode("JP") == .asia)
        #expect(Continent.forCountryCode("BR") == .southAmerica)
        #expect(Continent.forCountryCode("XX") == nil)
    }

    @Test func placeKeysIncludeParentsAndNormalize() throws {
        let rome = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", subLocality: "Centro Storico")
        #expect(rome.key(at: .country)?.path == "it")
        #expect(rome.key(at: .locality)?.path == "it/latium/rom")
        #expect(rome.key(at: .subLocality)?.path == "it/latium/rom/centro-storico")
        #expect(rome.key(at: .subAdministrativeArea) == nil)
        let frankfurtMain = PlaceComponents(isoCountryCode: "DE", administrativeArea: "Hessen", locality: "Frankfurt am Main")
        let frankfurtOder = PlaceComponents(isoCountryCode: "DE", administrativeArea: "Brandenburg", locality: "Frankfurt (Oder)")
        #expect(frankfurtMain.key(at: .locality) != frankfurtOder.key(at: .locality))
        #expect(PlaceKey.normalize("Düsseldorf") == "dusseldorf")
        #expect(PlaceKey.normalize("Straße") == "strasse")
    }
}
