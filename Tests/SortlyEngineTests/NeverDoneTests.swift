import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Photos that could never count as done, whatever the user does (review 18.11.2026, P1-03,
/// P1-08, P1-09): the ring or the analysis count stayed below "fertig" for good. Counted the way
/// `AppModel.refreshDerived` counts.
@Suite("Photos that could never count as done")
struct NeverDoneTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    static let today = Fixture.date("2026-11-18 06:00")
    static let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)

    struct World {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var pipeline: AnalysisPipeline
        var settings: OrganizationSettings

        func derived() async throws -> DerivedLibraryStatus {
            DerivedLibraryStatus.derive(
                facts: try await pipeline.currentFacts(), snapshot: try await pipeline.latestProposals(), settings: settings,
                overrides: OverrideSet(try await store.overrides()),
                contents: try await store.results(ContentAnalysis.self, kind: "content"),
                managed: [], inventory: try await store.loadInventory(), scope: .all, calendar: Fixture.calendar)
        }

        func places(_ d: DerivedLibraryStatus, _ ids: [AssetID]) -> [String] {
            ids.map { d.states[$0]?.areas[.places]?.rawValue ?? "-" }
        }
    }

    static func world(_ assets: [AssetSnapshot], analyzer: any ContentAnalyzing = FakeContentAnalyzer(),
                      geocoder: any ReverseGeocoding = FakeGeocoder(),
                      now: @escaping @Sendable () -> Date = { NeverDoneTests.today },
                      configure: (inout OrganizationSettings) -> Void = { _ in }) throws -> World {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        configure(&settings)
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map, conditions: FakeConditions(),
            settings: settings, calendar: Fixture.calendar, time: ManualTime().source, now: now
        )
        return World(store: store, reader: reader, pipeline: pipeline, settings: settings)
    }

    // MARK: P1-03 photos dated in the future

    /// Everyday life in Munich and three photos from Paris, too few for an album of their own:
    /// such photos leave the ring ("kein eigenes Album"). Three more from Paris carry the date
    /// 2031 (a camera with its clock set wrong). They were in the library when the suggestions
    /// were made, so they count exactly like the others, not as "unsortiert" for good (the rule
    /// meant photos taken after the suggestions, and compared the capture date).
    @Test func photosDatedInTheFutureCountLikeTheOthers() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1)
        let normal = (0..<3).map { lib.photo(at: Fixture.date("2026-03-0\($0 + 1) 12:00"), Self.paris) }
        let future = (0..<3).map { lib.photo(at: Fixture.date("2031-08-0\($0 + 1) 12:00"), Self.paris) }
        let w = try Self.world(lib.assets)
        for _ in 0..<2 {
            #expect(try await w.pipeline.run().isComplete)
            let d = try await w.derived()
            #expect(w.places(d, future) == w.places(d, normal), "the same photos, only the date differs")
            #expect(d.progress.unorganized == 0, "\(d.progress.unorganized) photos unsorted for good")
            #expect(d.leftOut.noAlbum == 6)
        }
    }

    /// The rule itself stays: a photo taken after the suggestions were made counts as unsorted
    /// until the next analysis has made its suggestions, also when its date is later than the
    /// moment it is looked at; one dated later that the analysis saw counts like the others.
    @Test func aPhotoTakenAfterTheSuggestionsStillCountsAsUnsorted() throws {
        let made = Fixture.date("2026-11-01 12:00")
        var settings = OrganizationSettings()
        settings.primaryAreas = [.places]
        func facts(_ id: String, _ date: String) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: Fixture.date(date), location: Self.paris),
                       place: PlaceComponents(isoCountryCode: "FR", country: "Frankreich"), placeSource: .gpsReverseGeocoded)
        }
        let photos = [facts("seen", "2026-10-01 12:00"), facts("seen-2031", "2031-08-01 12:00"),
                      facts("new", "2026-11-02 12:00"), facts("new-2031", "2031-08-02 12:00")]
        var snapshot = ProposalSnapshot(generatedAt: made, scope: .all, proposals: [], matches: [:])
        snapshot.datedAfterwards = ["seen-2031"]
        let states = LibraryStatus.compute(facts: photos, snapshot: snapshot, settings: settings,
                                           contentAnalyzed: Set(photos.map(\.id)))
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        #expect(resolver.isOutsideMainAreas(try #require(states["seen"])))
        #expect(resolver.isOutsideMainAreas(try #require(states["seen-2031"])))
        #expect(states["new"]?.areas[.places] == .unorganized)
        #expect(states["new-2031"]?.areas[.places] == .unorganized)
    }
}
