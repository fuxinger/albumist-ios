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

    static func run(_ assets: [AssetSnapshot], geocoder: FakeGeocoder = FakeGeocoder(),
                    levels: [PlaceLevel] = [.country, .administrativeArea]) throws -> Run {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.places.levels = levels
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: geocoder, map: PipelineTests.map,
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

    // MARK: Second review: ids of towns and regions

    static func placeIDs(_ run: Run) async throws -> [String: SortlyID] {
        var ids: [String: SortlyID] = [:]
        let snapshot = try await run.pipeline.latestProposals()
        for p in (snapshot?.proposals ?? []) + (snapshot?.dismissed ?? []) {
            guard let key = p.placeKeys.first, key.level == .administrativeArea || key.level == .locality else { continue }
            // Named by the photos they hold, which do not change with the language.
            ids["\(key.level):\(p.assetIDs.map(\.rawValue).sorted().first ?? "")"] = p.id
        }
        return ids
    }

    /// Second review of P1-12: the key of a town or region held the region's name, so after the
    /// switch "locality:de/bayern/…" became "locality:de/bavaria/…": a new id, and the user's
    /// "Nicht jetzt", own names and "do not create a deleted album again" were lost. A decision
    /// on a town and on a region survives a switch to English and back, and the ids stay.
    @Test func decisionsOnTownsAndRegionsSurviveALanguageSwitch() async throws {
        var run = try Self.townsAndRegions()
        #expect(try await run.pipeline.run().isComplete)
        let german = try await Self.placeIDs(run)
        let town = german.first { $0.key.hasPrefix("locality") }?.value
        let region = german.first { $0.key.hasPrefix("administrativeArea") }?.value
        #expect(town != nil && region != nil, "\(german)")
        guard let town, let region else { return }
        try await run.store.addOverride(UserOverride(scope: .source(town), decision: .rejectProposal))
        try await run.store.addOverride(UserOverride(scope: .source(region), decision: .doNotRecreateAlbum))

        for language in [TitleLanguage.english, .german, .english] {
            run.settings.titleLanguage = language
            await run.pipeline.update(settings: run.settings)
            #expect(try await run.pipeline.run().isComplete)
            #expect(try await Self.placeIDs(run) == german, "\(language)")
            let snapshot = try #require(try await run.pipeline.latestProposals())
            let open = Set(snapshot.proposals.map(\.id))
            #expect(!open.contains(town) && !open.contains(region), "\(language): a decided suggestion is back")
            #expect(Set(snapshot.dismissed.map(\.id)).isSuperset(of: [town, region]), "\(language)")
        }
        // The names did follow the language.
        #expect(try await run.store.places().values.contains { $0.components.administrativeArea == "Veneto" })
    }

    /// An install from before the fix: places stored without a fixed region key. Its ids stay
    /// what they were, in its language and after switching to the other one.
    @Test func anExistingLibraryKeepsItsIDs() async throws {
        var run = try Self.townsAndRegions()
        #expect(try await run.pipeline.run().isComplete)
        let german = try await Self.placeIDs(run)
        #expect(german.count >= 2, "\(german)")
        // As stored before: no keys, no table.
        var places = try await run.store.places()
        #expect(places.values.contains { $0.components.administrativeAreaKey != nil })
        for id in places.keys { places[id]?.components.administrativeAreaKey = nil }
        try await run.store.setPlaces(places)
        try await run.store.removeValue(forKey: AnalysisPipeline.Key.regionKeys)
        let old = Set(places.values.compactMap { $0.components.key(at: .administrativeArea)?.description })
        #expect(old.contains("administrativeArea:it/venetien"), "\(old)")

        #expect(try await run.pipeline.run().isComplete)
        #expect(try await Self.placeIDs(run) == german)
        run.settings.titleLanguage = .english
        await run.pipeline.update(settings: run.settings)
        #expect(try await run.pipeline.run().isComplete)
        #expect(try await Self.placeIDs(run) == german)
        let keys = Set(try await run.store.places().values.compactMap { $0.components.key(at: .administrativeArea)?.description })
        #expect(keys == old)
    }

    /// Two trips to Rome (an album for the town) and to Lake Garda and Venice (one for Veneto).
    static func townsAndRegions() throws -> Run {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                      skipping: [("2025-05-10", "2025-05-17"), ("2025-09-10", "2025-09-17"), ("2026-04-01", "2026-04-08"), ("2026-06-01", "2026-06-08")])
        _ = lib.daily(from: "2025-05-10", to: "2025-05-17", at: Fixture.Places.rome, perDay: 4, hour: 10)
        _ = lib.daily(from: "2025-09-10", to: "2025-09-17", at: Fixture.Places.rome, perDay: 4, hour: 10)
        _ = lib.daily(from: "2026-04-01", to: "2026-04-08", at: Fixture.Places.gardaLake, perDay: 4, hour: 10)
        let venice = GeoCoordinate(latitude: 45.4408, longitude: 12.3155)
        _ = lib.daily(from: "2026-06-01", to: "2026-06-08", at: venice, perDay: 4, hour: 10)
        let geocoder = FakeGeocoder(answers: FakeGeocoder.defaultAnswers
            + [(venice, PlaceComponents(isoCountryCode: "IT", country: "Italy", administrativeArea: "Veneto", locality: "Venedig"))])
        return try Self.run(lib.assets, geocoder: geocoder, levels: [.country, .administrativeArea, .locality])
    }
}
