import Foundation
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// "Bist du hier öfter?" through the whole analysis: the answer is stored next to the trip
/// corrections (`user.recurringPlaces`), applied by every later run, kept by "Analyse neu
/// aufbauen", part of the decisions copy in the backup, and can be taken back.
@Suite("Recurring places in the analysis")
struct RecurringPlacePipelineTests {
    /// A year in Munich with four days at Lake Garda every month.
    func setup() throws -> (AnalysisPipeline, AlbumistStore, [AssetID]) {
        var lib = LibraryBuilder()
        var stays: [(String, String)] = []
        for month in 1...12 {
            let start = String(format: "2026-%02d-05", month)
            stays.append((start, String(format: "2026-%02d-08", month)))
        }
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19, skipping: stays)
        let garda = stays.flatMap { lib.daily(from: $0.0, to: $0.1, at: Fixture.Places.gardaLake, perDay: 5, hour: 10) }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try AlbumistStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: FakeContentAnalyzer(labels: { _ in [] }, text: { _ in "" }),
            geocoder: FakeGeocoder(), map: PipelineTests.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source
        )
        return (pipeline, store, garda)
    }

    @Test func answerChangesTripsIntoOnePlaceAlbumAndBack() async throws {
        let (pipeline, store, garda) = try setup()
        _ = try await pipeline.run()
        let before = try #require(try await pipeline.latestProposals()).proposals
        let trips = before.filter { $0.kind == .trip }
        #expect(trips.count == 12)
        let report = try #require(try await pipeline.recurringPlaceReport())
        let question = try #require(report.candidates.first)
        #expect(report.candidates.count == 1)
        #expect(Set(question.tripIDs) == Set(trips.map(\.id)))
        #expect(trips.allSatisfy { report.tripPlaces[$0.id] != nil })

        // "Ja, hier bin ich öfter".
        let yes = try await pipeline.recurringPlaceAnswers().answering(true, at: question.center, name: "Malcesine", date: Fixture.date("2026-12-31"))
        try await pipeline.setRecurringPlaceAnswers(yes)
        _ = try await pipeline.run()
        let after = try #require(try await pipeline.latestProposals()).proposals
        #expect(after.filter { $0.kind == .trip }.isEmpty)
        let entry = try #require(yes.places.first)
        let placeID = RecurringPlaces.proposalID(for: entry.id)
        let place = try #require(after.first { $0.id == placeID })
        #expect(place.kind == .frequentPlace)
        #expect(place.title == "Malcesine")
        #expect(place.folderPath == ["Orte"])
        #expect(place.assetIDs == Set(garda))
        #expect(try await pipeline.recurringPlaceReport()?.candidates.isEmpty == true)

        // Part of the decisions copy (the derived report is not), and kept by a rebuild.
        let backup = try await store.safetyBackup()
        #expect(backup.values.contains { $0.key == "user.recurringPlaces" })
        #expect(!backup.values.contains { $0.key == "analysis.recurringPlaces" })
        let restored = try AlbumistStore(url: nil)
        #expect(try await restored.restore(backup, includingLibraryState: false))
        #expect(try await restored.value(RecurringPlaceAnswers.self, forKey: "user.recurringPlaces") == yes)
        try await store.resetAnalysis()
        #expect(try await pipeline.recurringPlaceAnswers() == yes)
        _ = try await pipeline.run()
        #expect(try await pipeline.latestProposals()?.proposals.contains { $0.id == placeID } == true)

        // Taken back in the settings: the trips come back with their ids, nothing is asked.
        try await pipeline.setRecurringPlaceAnswers(yes.withdrawing(entry.id, date: Fixture.date("2027-01-02")))
        _ = try await pipeline.run()
        let back = try #require(try await pipeline.latestProposals()).proposals
        #expect(Set(back.filter { $0.kind == .trip }.map(\.id)) == Set(trips.map(\.id)))
        #expect(!back.contains { $0.id == placeID })
        #expect(try await pipeline.recurringPlaceReport()?.candidates.isEmpty == true)
    }
}
