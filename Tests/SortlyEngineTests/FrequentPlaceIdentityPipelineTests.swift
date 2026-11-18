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

    /// Update from build 36: the stored places have the old IDs (rounded centre; the two places
    /// of one cell share one). Everything the user attached to an ID stays with the place it
    /// was made for, because the place keeps that ID: the typed title ("Dahoam", `user.titles`
    /// in the app), the name in the settings, "Nicht jetzt" (a rejection) and every other record
    /// keyed by the suggestion ID (decisions, overrides by source, album links, answers).
    @Test func namesAndRejectionsSurviveTheUpdate() async throws {
        let home = GeoCoordinate(latitude: 48.1500, longitude: 11.5600)
        var lib = LibraryBuilder()
        func visits(_ c: GeoCoordinate, from start: String, weeks: Int) {
            for week in 0..<weeks {
                let day = Fixture.date(start).addingTimeInterval(Double(week * 7) * 86_400 + 10 * 3_600)
                for k in 0..<4 { _ = lib.photo(at: day.addingTimeInterval(Double(k) * 60), c, jitterMeters: 0) }
            }
        }
        visits(home, from: "2026-01-01", weeks: 12)
        visits(Self.a, from: "2026-01-02", weeks: 5)   // photographed first, fewer days
        visits(Self.b, from: "2026-01-03", weeks: 9)   // the one build 36 showed under the shared ID
        func oldID(_ c: GeoCoordinate) -> SortlyID { .stable("frequent", String(format: "%.3f,%.3f", c.latitude, c.longitude)) }
        var stored = FrequentPlaceDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        // Since build 36 the first place got more days than the shown one: a fresh assignment
        // would now give it the cell's ID; the stored places decide.
        visits(Self.a, from: "2026-04-02", weeks: 8)
        for i in stored.indices { stored[i].id = oldID(stored[i].centroid) }
        #expect(stored.count == 3)
        #expect(Set(stored.map(\.id)).count == 2)
        let homeID = oldID(home), sharedID = oldID(Self.b)

        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.frequentPlaces.names[homeID] = "Dahoam"
        let store = try SortlyStore(url: nil)
        try await store.setValue(stored, forKey: "analysis.frequentPlaces")
        try await store.setValue([homeID: "Dahoam"], forKey: "user.titles")
        try await store.addOverride(UserOverride(scope: .source(sharedID), decision: .rejectProposal))
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: FakeContentAnalyzer(labels: { _ in [] }, text: { _ in "" }),
            geocoder: FakeGeocoder(), map: PipelineTests.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        let places = try await places(store)
        let homePlace = try #require(places.first { GeoMath.distance($0.centroid, home) < 10 })
        let shown = try #require(places.first { GeoMath.distance($0.centroid, Self.b) < 10 })
        let other = try #require(places.first { GeoMath.distance($0.centroid, Self.a) < 10 })
        #expect(homePlace.id == homeID)
        #expect(homePlace.userName == "Dahoam")
        #expect(shown.id == sharedID)
        #expect(other.id != sharedID)

        let snapshot = try #require(try await pipeline.latestProposals())
        let titles = try #require(try await store.value([SortlyID: String].self, forKey: "user.titles"))
        let named = try #require(snapshot.proposals.first { $0.id == homeID })
        #expect((titles[named.id] ?? named.title) == "Dahoam")
        // "Nicht jetzt" stays on the place it was given for; the other place is a new suggestion.
        #expect(snapshot.dismissed.map(\.id).contains(sharedID))
        #expect(!snapshot.proposals.contains { $0.id == sharedID })
        #expect(snapshot.proposals.contains { $0.id == other.id })
    }
}
