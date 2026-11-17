import Foundation
import Testing
@testable import SortlyCore
import SortlyWorldMap
import SortlyTestSupport

/// Review evidence (uncommitted): places saved in parts of 2,000.
@Suite("Review evidence: offline places in parts")
struct ReviewPlacesEvidenceTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    func requests(_ place: GeoCoordinate, count: Int, prefix: String) -> [PlaceResolutionService.Request] {
        (0..<count).map { i in
            .init(assetID: AssetID("\(prefix)-\(i)"), coordinate: Fixture.jitter(place, seed: i, meters: 300), priority: 0)
        }
    }

    func service(level: PlaceLevel, geocoder: FakeGeocoder?) -> PlaceResolutionService {
        PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: level, onlineAllowed: true, language: .german),
            throttle: .apple, time: ManualTime().source
        )
    }

    /// Default settings (trips on, so towns): each photo is one resolved place. The country
    /// saved early from the map is subtracted when the town comes (`offlineOnly[$0] != nil`),
    /// but `offlineOnly` now holds only the last part: the earlier parts count twice.
    @Test func eachPlaceCountedOnceAtTownLevel() async throws {
        let n = 2 * PlaceResolutionService.offlineChunk + 500
        let outcome = try await service(level: .locality, geocoder: FakeGeocoder())
            .resolve(requests(Fixture.Places.rome, count: n, prefix: "r")) { _ in }
        #expect(outcome.resolved == n, "resolved \(outcome.resolved) for \(n) photos")
    }

    /// The stress run (default settings, offline): "0 von 50.233 Orten" for a minute. At town
    /// level every request needs the online lookup, so the parts save countries but the count
    /// stays at 0 until the loop ends; offline it stays 0 for the whole step.
    @Test func countMovesDuringTheMapPassAtTownLevel() async throws {
        // Adapted with the fix: the count of places stays honest (no town is final before its
        // lookup, so it stays 0 offline); what moves is the pass's own "geprüft" count.
        actor Log { var counts: [Int] = []; var final: [Int] = []; func add(_ n: Int) { counts.append(n) }; func addFinal(_ n: Int) { final.append(n) } }
        let log = Log()
        let n = 2 * PlaceResolutionService.offlineChunk + 500
        _ = try await service(level: .locality, geocoder: FakeGeocoder(failures: [.offline]))
            .resolve(requests(Fixture.Places.rome, count: n, prefix: "r"), progress: { await log.addFinal($0) },
                     checked: { await log.add($0) }) { _ in }
        let counts = await log.counts
        #expect(Set(counts).count > 1, "counts while the map pass ran: \(counts)")
        #expect(counts == counts.sorted() && counts.last == n)
        #expect(await log.final.allSatisfy { $0 == 0 }, "places counted before their town was known")
    }
}
