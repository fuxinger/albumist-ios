import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Screenshot categories are decided while the full text is in memory; only a minimised copy
/// is stored. So a better classifier (first device test 15.11.: "Flugmodus" in Settings
/// screenshots counted as a flight booking) only reaches screenshots that are read again.
/// The text version makes every stored screenshot be read once more after an update.
@Suite("Classifier update")
struct ClassifierUpdateTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    @Test func screenshotsReadWithAnOlderClassifierAreReadAgainOnce() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-03-01", to: "2026-03-20", at: Fixture.Places.munichHome, perDay: 1)
        let shots = (1...6).map { day in lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        let store = try SortlyStore(url: nil)
        let analyzer = FakeContentAnalyzer(cloudOnly: [], labels: { _ in [] }, text: { _ in "Einstellungen\nFlugmodus\nWLAN\nBluetooth" })
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer, geocoder: FakeGeocoder(),
            map: Self.map, conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        #expect(analyzer.counts.withLock { $0.text } == shots.count)

        // As stored by an app version with the older classifier: a wrong category, old version.
        for id in shots {
            var old = try #require(try await store.result(TextResult.self, kind: "text", asset: id))
            old.screenshotCategories = ["flight"]
            try await store.saveResult(old, kind: "text", asset: id, version: AnalysisPipeline.textVersion - 1)
        }
        _ = try await pipeline.run()
        #expect(analyzer.counts.withLock { $0.text } == shots.count * 2)
        for id in shots {
            let now = try #require(try await store.result(TextResult.self, kind: "text", asset: id))
            #expect(!now.screenshotCategories.contains("flight"))
        }
        // Once only: a third run reads nothing again.
        _ = try await pipeline.run()
        #expect(analyzer.counts.withLock { $0.text } == shots.count * 2)
    }
}
