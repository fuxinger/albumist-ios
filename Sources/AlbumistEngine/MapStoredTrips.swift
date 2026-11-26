import Foundation
import AlbumistCore
import AlbumistStore

extension AnalysisPipeline {
    /// The trips of the last analysis as stored (`Key.trips`), with their remembered ids: what the
    /// map summary is made of besides the facts (concept 2.0 §9). Empty before the first analysis.
    public static func storedTrips(in store: AlbumistStore) async throws -> [Trip] {
        try await store.value([Trip].self, forKey: Key.trips) ?? []
    }
}
