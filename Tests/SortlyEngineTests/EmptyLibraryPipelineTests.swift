import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// An App Review device (plugin review K6): a handful of photos, often without a place. The
/// whole analysis runs through, makes no suggestion, and the overview has an explanation for
/// each case instead of "0 von 0 sortiert" alone.
@Suite("Analysis of an almost empty library")
struct EmptyLibraryPipelineTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    /// Runs the real analysis on `assets` and returns what the overview decides from it.
    func overviewState(_ assets: [AssetSnapshot], access: LibraryAccess = .full) async throws -> (EmptyLibraryState?, AnalysisPipeline.Report) {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: try SortlyStore(url: nil), reader: InMemoryLibraryReader(assets: assets, access: access), analyzer: FakeContentAnalyzer(),
            geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source
        )
        let report = try await pipeline.run()
        let proposals = try await pipeline.latestProposals()?.proposals.count ?? 0
        let state = EmptyLibraryState.evaluate(.init(
            photos: assets.count, photosWithPlace: assets.filter { $0.location != nil }.count, proposals: proposals,
            analysisRunning: false, analysisPaused: report.pausedBecause != nil, analysedOnce: report.isComplete,
            limitedAccess: access == .limited))
        return (state, report)
    }

    @Test func emptyLibrary() async throws {
        let (state, report) = try await overviewState([])
        #expect(report.isComplete)
        #expect(state == .emptyLibrary)
    }

    @Test func emptySelectionWithLimitedAccess() async throws {
        let (state, _) = try await overviewState([], access: .limited)
        #expect(state == .nothingShared)
    }

    @Test func onePhoto() async throws {
        var lib = LibraryBuilder()
        _ = lib.photo(at: Fixture.date("2026-05-12 10:00"), Fixture.Places.rome)
        let (state, report) = try await overviewState(lib.assets)
        #expect(report.isComplete)
        #expect(state == .fewPhotos(1))
    }

    /// The simulator's own sample photos and many review devices: a few photos, no place.
    @Test func handfulOfPhotosWithoutGPS() async throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-03-01", to: "2026-03-06", at: nil, perDay: 1)
        let (state, report) = try await overviewState(lib.assets)
        #expect(report.isComplete)
        #expect(state == .fewPhotos(6))
    }

    @Test func manyPhotosWithoutGPS() async throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-03-01", to: "2026-03-20", at: nil, perDay: 2)
        let (state, _) = try await overviewState(lib.assets)
        #expect(state == .noPlaces(40))
    }

    /// A real trip is enough: the explanation goes away as soon as there is a suggestion.
    @Test func aTripMakesSuggestions() async throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-02-28", at: Fixture.Places.munichHome, perDay: 1)
        lib.daily(from: "2026-05-12", to: "2026-05-16", at: Fixture.Places.rome, perDay: 4)
        let (state, _) = try await overviewState(lib.assets)
        #expect(state == nil)
    }
}
