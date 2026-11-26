import Foundation
import Testing
@testable import AlbumistStore
import AlbumistCore
import AlbumistTestSupport

/// Boundary values for the store's lists (rebuild stage 3, 26.11.2026; the app's lists in
/// `ListBoundaryTests`): with 0, 1, 2,999, 3,000, 3,001, 10,000 and 50,000 photos the store counts
/// every photo, lists every photo, and the analysis reads every photo page by page exactly once,
/// also where several photos share one time at a page's edge (the cursor goes by time, then id).
/// Marking all of them analysed at once (more ids than SQLite takes in one statement) leaves none.
@Suite("Store lists at boundary sizes")
struct ListBoundaryStoreTests {
    static let sizes = [0, 1, 2_999, 3_000, 3_001, 10_000, 50_000]
    /// The analysis pipeline's page (`AnalysisPipeline.batchSize`).
    static let page = 50

    @Test(arguments: sizes)
    func everyPhotoIsCountedListedAndReadOnce(count: Int) async throws {
        let store = try AlbumistStore(url: nil)
        let start = Fixture.date("2020-01-01")
        // Seven photos share each time (burst shots), so many pages end inside a group of equal times.
        let assets = (0..<count).map { AssetSnapshot(id: AssetID(String(format: "edge-%06d", $0)), creationDate: start.addingTimeInterval(Double($0 / 7) * 60)) }
        try await store.upsertAssets(assets)
        #expect(try await store.assetCount() == count)
        #expect(try await store.allAssets().count == count)
        #expect(try await store.countNeedingAnalysis(version: 1) == count)

        var read: [AssetID] = []
        var cursor: AssetSnapshot?
        while case let batch = try await store.assetsNeedingAnalysis(version: 1, limit: Self.page, olderThan: cursor), !batch.isEmpty {
            read += batch.map(\.id)
            cursor = batch.last
            if read.count > count { break }
        }
        #expect(read.count == count, "\(count) photos: every one read")
        #expect(Set(read).count == read.count, "\(count) photos: none read twice")
        #expect(read.last == assets.first?.id, "\(count) photos: the oldest one is read last")

        try await store.markAnalyzed(assets.map(\.id), version: 1)
        #expect(try await store.countNeedingAnalysis(version: 1) == 0, "\(count) photos: all marked in one call")
        #expect(try await store.assetsNeedingAnalysis(version: 1, limit: Self.page).isEmpty)
    }
}
