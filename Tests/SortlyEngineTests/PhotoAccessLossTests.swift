import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Photo access taken away in Settings after the start (plugin review W4). The app used to
/// show the introduction again, which ended with "Analyse starten" for the whole library: a
/// year chosen at the start was replaced without the user asking. Now it shows a screen of
/// its own, and once access is back the analysis goes on with the part chosen before.
@Suite("Photo access taken away after the start")
struct PhotoAccessLossTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    @Test func chosenYearStaysWhenAccessIsTakenAwayAndComesBack() async throws {
        var lib = LibraryBuilder()
        let old = lib.daily(from: "2025-03-01", to: "2025-03-20", at: Fixture.Places.munichHome, perDay: 1)
        let new = lib.daily(from: "2026-03-01", to: "2026-03-20", at: Fixture.Places.munichHome, perDay: 1)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let analyzer = FakeContentAnalyzer(cloudOnly: [], labels: { _ in [] }, text: { _ in "" })
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source, batchSize: 10
        )
        // The start: "Nur 2026", stored before the first run (as `startAnalysis(scope:)` does).
        try await pipeline.setScope(.year(2026))
        let first = try await pipeline.run()
        #expect(first.isComplete)
        #expect(first.contentAnalyzed == new.count)

        // Access taken away: its own screen, not the introduction; nothing is read, the year stays.
        await reader.set(access: .denied)
        #expect(StartScreen.after(onboardingDone: true, access: await reader.access()) == .noPhotoAccess)
        let refused = try await pipeline.run()
        #expect(refused.pausedBecause == .accessRevoked)
        #expect(try await pipeline.storedScope() == .year(2026))

        // Access back: the app goes on with a run without a scope (as at every launch), which
        // is still the year chosen at the start; the photos of 2025 are not looked at.
        await reader.set(access: .full)
        #expect(StartScreen.after(onboardingDone: true, access: await reader.access()) == .main)
        let resumed = try await pipeline.run()
        #expect(resumed.isComplete)
        #expect(resumed.contentAnalyzed == 0)
        #expect(try await pipeline.storedScope() == .year(2026))
        #expect(try #require(try await pipeline.latestProposals()).scope == .year(2026))
        #expect(analyzer.counts.withLock { $0.content } == new.count)
        #expect(!old.isEmpty)
    }
}
