import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
@testable import SortlyStore
import SortlyTestSupport

extension SortlyStore {
    /// The stored payload of `key` as damage would leave it (not JSON at all).
    func reReviewRawPayload(_ bytes: Data, forKey key: String) throws {
        try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(key), .blob(bytes)])
    }
}

/// Re-review of "Dein Zuhause" (16.11.): the scenarios of its findings, kept as tests.
@Suite("Dein Zuhause: damaged stored values")
struct HomeDamagedValuesTests {
    /// `readable` catches only `DecodingError`. The values read with `defaults:` (`user.home`,
    /// `user.recurringPlaces`) go through `StoredDefaults.decode`, which reports bytes that are not
    /// JSON as `DecodingError.dataCorrupted`: such a value is read as not stored.
    @Test func damagedHomeBytesDoNotStopTheAnalysis() async throws {
        var lib = LibraryBuilder()
        HomePipelineTests.munichAndRome(&lib)
        for key in ["user.home", "user.recurringPlaces"] {
            let store = try SortlyStore(url: nil)
            let p = HomeReviewStoreTests().pipeline(store, reader: InMemoryLibraryReader(assets: lib.assets))
            try await store.reReviewRawPayload(Data("{\"version\":1,\"mode\":\"confirmed\",\"confi".utf8), forKey: key)
            var runError: (any Error)?
            do { _ = try await p.run() } catch { runError = error }
            #expect(runError == nil)
            var readError: (any Error)?
            do { _ = try await p.homeSettings(); _ = try await p.recurringPlaceAnswers() } catch { readError = error }
            #expect(readError == nil)
        }
    }
}
