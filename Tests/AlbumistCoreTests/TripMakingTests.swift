import Foundation
import Testing
@testable import AlbumistCore

/// `Trip.make`: a trip made outside the detector (the map's demo trip) is the trip the detector
/// would store with the same values.
@Suite("Trip made outside the detector")
struct TripMakingTests {
    @Test func madeIsTheStoredTrip() throws {
        let start = Date(timeIntervalSince1970: 1_686_700_000)
        let made = Trip.make(id: AlbumistID("demo-iceland"), start: start, end: start.addingTimeInterval(8 * 86_400),
                             geotaggedAssetIDs: ["a", "b"], centroid: GeoCoordinate(latitude: 64.1, longitude: -19.5),
                             maxDistanceFromHomeMeters: 2_600_000, distinctStops: 8, kind: .roadTrip)
        let stored = Trip(id: AlbumistID("demo-iceland"), start: start, end: start.addingTimeInterval(8 * 86_400),
                          geotaggedAssetIDs: ["a", "b"], inferredAssetIDs: [], centroid: GeoCoordinate(latitude: 64.1, longitude: -19.5),
                          maxDistanceFromHomeMeters: 2_600_000, distinctStops: 8, kind: .roadTrip)
        #expect(made == stored)
        // And it survives the store's round trip like a detected one.
        let decoded = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(made))
        #expect(decoded == made)
    }
}
