import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Evidence for the sorted ring (device test 15.11.): the same library with the user's own
/// albums, counted the way the app counts. Prints the counts per group of photos.
@Suite("Sorted count evidence")
struct SortedCountEvidence {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Spot { var name: String; var at: GeoCoordinate; var place: PlaceComponents }
    static func spot(_ name: String, _ lat: Double, _ lon: Double, _ code: String, _ country: String, _ region: String, _ town: String) -> Spot {
        Spot(name: name, at: GeoCoordinate(latitude: lat, longitude: lon),
             place: PlaceComponents(isoCountryCode: code, country: country, administrativeArea: region, locality: town))
    }
    static let home = spot("home", 48.1371, 11.5754, "DE", "Deutschland", "Bayern", "München")
    static let trips: [(spot: Spot, from: String, to: String, album: String?)] = [
        (spot("Island", 64.1466, -21.9426, "IS", "Island", "Höfuðborgarsvæðið", "Reykjavík"), "2023-07-10", "2023-07-16", "Island 2023"),
        (spot("Marokko", 31.6295, -7.9811, "MA", "Marokko", "Marrakesch-Safi", "Marrakesch"), "2025-05-03", "2025-05-09", "Marokko"),
        (spot("Kroatien", 43.5081, 16.4402, "HR", "Kroatien", "Split-Dalmatien", "Split"), "2025-08-02", "2025-08-08", "Kroatien Sommer"),
        (spot("Wien", 48.2082, 16.3738, "AT", "Österreich", "Wien", "Wien"), "2024-12-28", "2025-01-01", "Silvester in Wien"),
        (spot("Rom", 41.8986, 12.4769, "IT", "Italien", "Latium", "Rom"), "2024-04-09", "2024-04-12", "Rom 2024"),
        (spot("Florenz", 43.7696, 11.2558, "IT", "Italien", "Toskana", "Florenz"), "2023-10-01", "2023-10-05", "Toskana"),
        (spot("Neapel", 40.8518, 14.2681, "IT", "Italien", "Kampanien", "Neapel"), "2025-10-10", "2025-10-14", nil),
        (spot("Paris", 48.8566, 2.3522, "FR", "Frankreich", "Île-de-France", "Paris"), "2023-05-18", "2023-05-21", nil),
        (spot("Hamburg", 53.5511, 9.9937, "DE", "Deutschland", "Hamburg", "Hamburg"), "2025-06-21", "2025-06-22", "Hamburg"),
    ]

    @Test func countsWithOwnAlbums() async throws {
        var lib = LibraryBuilder()
        var groups: [String: [AssetID]] = [:]
        let skipping = Self.trips.map { ($0.from, $0.to) }
        let homeIDs = lib.daily(from: "2023-01-01", to: "2026-10-31", at: Self.home.at, perDay: 1, skipping: skipping)
        groups["home"] = homeIDs
        for t in Self.trips {
            groups[t.spot.name] = lib.daily(from: t.from, to: t.to, at: t.spot.at, perDay: 20, hour: 9)
        }
        var albums: [CollectionSnapshot] = []
        for t in Self.trips {
            guard let title = t.album else { continue }
            albums.append(CollectionSnapshot(id: CollectionID("own-\(t.spot.name)"), title: title, assetIDs: Set(groups[t.spot.name]!)))
        }
        albums.append(CollectionSnapshot(id: "own-familie", title: "Familie", assetIDs: Set(homeIDs.prefix(150))))
        let inventory = CollectionInventory(albums)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.privacy.allowOnlineGeocoding = true
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets, inventory: inventory)
        let geocoder = FakeGeocoder(answers: [(Self.home.at, Self.home.place)] + Self.trips.map { ($0.spot.at, $0.spot.place) })
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: geocoder, map: Self.map,
            conditions: FakeConditions(pauseAfterChecks: nil), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, batchSize: 50
        )
        _ = try await pipeline.run()
        let snapshot = try await pipeline.latestProposals()
        let facts = try await pipeline.currentFacts()
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let analyzed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
        let states = LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings,
                                           overrides: OverrideSet(try await store.overrides()), contentAnalyzed: analyzed)
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        let p = resolver.progress(states.values)
        print("EVIDENCE total \(p.total) fully \(p.fully) partly \(p.partially) unsorted \(p.unorganized) pending \(p.pending) outside \(p.outsideMainAreas)")
        for proposal in snapshot?.proposals ?? [] where proposal.kind.area == .places || proposal.kind.area == .trips {
            let m = snapshot?.matches[proposal.id]
            print("EVIDENCE proposal \(proposal.kind) '\(proposal.title)' \(proposal.assetIDs.count) -> \(m?.status.rawValue ?? "-") \(m?.best?.albumTitle ?? "")")
        }
        for name in ["home"] + Self.trips.map(\.spot.name) {
            var overall: [String: Int] = [:]
            var areas: [String: Int] = [:]
            for id in groups[name]! {
                guard let s = states[id] else { continue }
                if resolver.isOutsideMainAreas(s) { overall["outside", default: 0] += 1 } else { overall["\(resolver.overall(s))", default: 0] += 1 }
                areas["places=\(s.areas[.places]?.rawValue ?? "-") trips=\(s.areas[.trips]?.rawValue ?? "-")", default: 0] += 1
            }
            print("EVIDENCE group \(name): \(overall.sorted { $0.key < $1.key }) \(areas.sorted { $0.key < $1.key })")
        }
    }
}
