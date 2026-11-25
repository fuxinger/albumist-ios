import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistEngine
import AlbumistStore

/// `AnalysisPipeline.storedTrips(in:)`: the map reads the trips the analysis stored, under the
/// pipeline's own key, and none before the first analysis.
@Suite("Stored trips for the map")
struct MapStoredTripsTests {
    @Test func readsWhatTheAnalysisStored() async throws {
        let store = try AlbumistStore(url: nil)
        #expect(try await AnalysisPipeline.storedTrips(in: store).isEmpty)
        let start = Date(timeIntervalSince1970: 1_686_700_000)
        let trips = [
            Trip.make(id: AlbumistID("t1"), start: start, end: start.addingTimeInterval(86_400), geotaggedAssetIDs: ["a"],
                      profile: .init(centroid: GeoCoordinate(latitude: 41.9, longitude: 12.5), maxDistanceFromHomeMeters: 900_000,
                                     distinctStops: 1, kind: .weekendTrip)),
            Trip.make(id: AlbumistID("t2"), start: start.addingTimeInterval(30 * 86_400), end: start.addingTimeInterval(39 * 86_400),
                      geotaggedAssetIDs: ["b", "c"], profile: .init(centroid: GeoCoordinate(latitude: 64.1, longitude: -19.5),
                                                                    maxDistanceFromHomeMeters: 2_600_000, distinctStops: 8, kind: .roadTrip)),
        ]
        try await store.setValue(trips, forKey: AnalysisPipeline.Key.trips)
        #expect(try await AnalysisPipeline.storedTrips(in: store) == trips)
    }
}
