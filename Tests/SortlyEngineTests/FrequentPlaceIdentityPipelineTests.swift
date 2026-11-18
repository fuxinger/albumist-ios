import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Second review of the frequent-place IDs (18.11.2026) through the whole analysis: each run
/// carries the IDs over from the places the run before stored (`analysis.frequentPlaces`), so
/// a place keeps its ID by its photos and never takes over the ID of another one.
@Suite("Frequent place IDs carried over between analyses")
struct FrequentPlaceIdentityPipelineTests {
    static let a = GeoCoordinate(latitude: 48.13751, longitude: 11.57551)
    static let b = GeoCoordinate(latitude: 48.13849, longitude: 11.57649)

    func places(_ store: SortlyStore) async throws -> [FrequentPlace] {
        try await store.value([FrequentPlace].self, forKey: "analysis.frequentPlaces") ?? []
    }

    @Test func thePlaceThatStaysKeepsItsIDWhenTheOtherDropsOut() async throws {
        var lib = LibraryBuilder()
        var aIDs: [AssetID] = []
        for week in 0..<8 {
            let day = Fixture.date("2026-01-01").addingTimeInterval(Double(week * 7) * 86_400 + 10 * 3_600)
            for k in 0..<4 { aIDs.append(lib.photo(at: day.addingTimeInterval(Double(k) * 60), Self.a, jitterMeters: 0)) }
        }
        for week in 0..<5 {
            let day = Fixture.date("2026-01-03").addingTimeInterval(Double(week * 7) * 86_400 + 10 * 3_600)
            for k in 0..<4 { _ = lib.photo(at: day.addingTimeInterval(Double(k) * 60), Self.b, jitterMeters: 0) }
        }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(labels: { _ in [] }, text: { _ in "" }),
            geocoder: FakeGeocoder(), map: PipelineTests.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        let first = try await places(store)
        #expect(first.count == 2)
        let idA = try #require(first.first { GeoMath.distance($0.centroid, Self.a) < 10 }).id
        let idB = try #require(first.first { GeoMath.distance($0.centroid, Self.b) < 10 }).id
        #expect(idA != idB)

        // Most photos at the first place deleted: it is no frequent place any more.
        let gone = Set(aIDs.dropFirst(8))
        await reader.set(assets: lib.assets.filter { !gone.contains($0.id) })
        _ = try await pipeline.run()
        let second = try await places(store)
        #expect(second.map(\.id) == [idB])
        let proposals = try #require(try await pipeline.latestProposals()).proposals
        #expect(!proposals.contains { $0.id == idA })
    }
}
