import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Review finding P1-12 (core logic, 18.11.2026): after the language of album names was
/// switched, countries and regions kept the language they were first named in, because
/// stored places were never named again ("Countries/Italien").
@Suite("Language of album names: countries and regions follow it (P1-12)")
struct AlbumNameLanguageTests {
    struct Run {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var pipeline: AnalysisPipeline
        var settings: OrganizationSettings
    }

    static func run(_ assets: [AssetSnapshot]) throws -> Run {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.places.levels = [.country, .administrativeArea]
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: PipelineTests.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source,
            now: { Fixture.date("2026-11-18 06:00") }
        )
        return Run(store: store, reader: reader, pipeline: pipeline, settings: settings)
    }

    static func titles(_ run: Run) async throws -> [String] {
        (try await run.pipeline.latestProposals()?.proposals ?? []).map { ($0.folderPath + [$0.title]).joined(separator: "/") }.sorted()
    }

    /// Daily life in Munich, a trip to Rome in May 2025 and, after the switch, one to Naples.
    static func library() -> (before: [AssetSnapshot], after: [AssetSnapshot]) {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                      skipping: [("2025-05-10", "2025-05-17"), ("2026-05-12", "2026-05-19")])
        _ = lib.daily(from: "2025-05-10", to: "2025-05-17", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let before = lib.assets
        _ = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.naples, perDay: 4, hour: 10)
        return (before, lib.assets)
    }

    /// The reviewer's case: German, then English, then a new trip to the same country.
    @Test func countriesAndRegionsFollowTheLanguageOfAlbumNames() async throws {
        let (before, after) = Self.library()
        var run = try Self.run(before)
        #expect(try await run.pipeline.run().isComplete)
        run.settings.titleLanguage = .english
        await run.pipeline.update(settings: run.settings)
        #expect(try await run.pipeline.run().isComplete)
        await run.reader.set(assets: after)
        #expect(try await run.pipeline.run().isComplete)
        let english = try await Self.titles(run)
        #expect(english.contains("Countries/Italy"), "\(english)")
        #expect(!english.contains { $0.contains("Italien") || $0.contains("Latium") }, "\(english)")
        // Every stored country and region is named in English now.
        let places = try await run.store.places().values.map(\.components)
        #expect(Set(places.compactMap(\.country)) == ["Italy", "Germany"])
        #expect(!places.contains { $0.administrativeArea == "Bayern" || $0.administrativeArea == "Kampanien" })

        // And back: German names again, also for the photos named in English.
        run.settings.titleLanguage = .german
        await run.pipeline.update(settings: run.settings)
        #expect(try await run.pipeline.run().isComplete)
        let german = try await Self.titles(run)
        #expect(german.contains("Länder/Italien"), "\(german)")
        #expect(!german.contains { $0.contains("Italy") }, "\(german)")
        #expect(Set(try await run.store.places().values.compactMap(\.components.country)) == ["Italien", "Deutschland"])
    }

    /// The names change with a run: switching the language starts one, as a change that gives
    /// the places step work.
    @Test func switchingTheLanguageStartsARun() {
        var german = OrganizationSettings()
        german.titleLanguage = .german
        var english = german
        english.titleLanguage = .english
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: german, to: english))
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: english, to: german))
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: german, to: german))
    }

    /// The map's own names: a country by its code, a region by its name in either language.
    @Test func theMapNamesAStoredPlaceInTheOtherLanguage() {
        let map = PipelineTests.map
        let stored = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom")
        let english = map.renamed(stored, to: .english)
        #expect(english.country == "Italy")
        #expect(english.administrativeArea == map.region(Fixture.Places.rome, inCountryCode: "IT")?.region.nameEN)
        #expect(english.locality == "Rom", "towns come from Apple's lookup and are not the map's")
        #expect(map.renamed(english, to: .german) == stored)
        // A region the map does not know keeps its name.
        let unknown = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Nirgendwo")
        #expect(map.renamed(unknown, to: .english).administrativeArea == "Nirgendwo")
    }
}
