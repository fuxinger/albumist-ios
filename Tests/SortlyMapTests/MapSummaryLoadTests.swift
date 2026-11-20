import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyTestSupport

/// The map summary of a 50,000-photo library (concept §9: "Zusammenfassung für 50.000 Fotos unter
/// 300 ms"). Runs in every Linux test run; the bound there is loose because debug builds on CI
/// are several times slower than the app, and the real figure is printed (MAP_PERF) and kept in
/// the test plan.
@Suite("Map summary speed")
struct MapSummaryLoadTests {
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }

    @Test func fiftyThousandPhotos() throws {
        let library = MapLibrary(count: 50_000)
        let input = MapInput(facts: library.facts, trips: library.trips, homeSettings: library.homeSettings,
                             calendar: MapFixture.calendar, now: MapFixture.date("2026-11-20"))
        let clock = ContinuousClock()
        var summary: MapSummary?
        // Warm once (first-use costs of Foundation), then the best of three.
        _ = MapSummary.build(input)
        var best = Duration.seconds(1_000)
        for _ in 0..<3 {
            let time = clock.measure { summary = MapSummary.build(input) }
            best = min(best, time)
        }
        let result = try #require(summary)
        // The steps on their own, to see where the time goes.
        var airborne: Set<AssetID> = []
        let airborneTime = clock.measure { airborne = AirborneFilter.airborne(input.facts.map(\.asset)) }
        let homesTime = clock.measure { _ = MapHome.homes(for: input.trips, facts: input.facts, settings: input.homeSettings, detected: nil) }
        let countriesTime = clock.measure { _ = MapCountries.compute(facts: input.facts, airborne: airborne, tripStarts: [:]) }
        print(String(format: "MAP_PERF photos %d trips %d: summary %.0f ms (airborne %.0f, homes %.0f, countries %.0f) | places %d, arcs %d, pins %d",
                     library.facts.count, result.trips.count, Self.ms(best), Self.ms(airborneTime), Self.ms(homesTime), Self.ms(countriesTime),
                     result.trips.reduce(0) { $0 + $1.geometry.places.count }, result.arcs.count, result.pins.count))
        #expect(library.facts.count >= 50_000)
        #expect(result.trips.count >= 100)
        #expect(result.arcs.count <= MapSummary.maxArcs)
        #expect(result.trips.allSatisfy { $0.geometry.route.count <= TripGeometry.maxRoutePoints })
        // Every photo out of the plane window was found, and no photo on the ground.
        #expect(library.windowPhotos.count >= 9)
        #expect(airborne == library.windowPhotos)
        // Debug build on a shared CI machine: the bound catches a quadratic step, the printed
        // figure is the one that matters (the app runs a release build).
        #expect(Self.ms(best) < 3_000)
    }
}
