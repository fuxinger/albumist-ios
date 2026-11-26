import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// The map summary of a 50,000-photo library (concept §9: "Zusammenfassung für 50.000 Fotos unter
/// 300 ms"). Runs in every Linux test run; the bound there is loose because debug builds on CI
/// are several times slower than the app, and the real figure is printed (MAP_PERF) and kept in
/// the test plan. A release build (`swift test -c release -Xswiftc -enable-testing`) checks the
/// 300 ms themselves.
@Suite("Map summary speed")
struct MapSummaryLoadTests {
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }

    @Test func fiftyThousandPhotos() throws {
        let library = MapLibrary(count: 50_000)
        let input = MapInput(facts: library.facts, trips: library.trips, homeSettings: library.homeSettings,
                             calendar: MapFixture.calendar, now: MapFixture.date("2026-11-20"))
        let clock = ThreadCPUClock()
        var summary: MapSummary?
        // Warm once (first-use costs of Foundation), then the best of three.
        _ = MapSummary.build(input)
        var best = Duration.seconds(1_000)
        for _ in 0..<3 {
            let time = clock.measure { summary = MapSummary.build(input) }
            best = min(best, time)
        }
        let result = try #require(summary)
        // The steps on their own, to see where the time goes (the filter as the summary runs it,
        // with the photos maybe taken in flight).
        var judgement = FlightJudgement()
        let airborneTime = clock.measure { judgement = AirborneFilter.judge(input.facts.map(\.asset)) }
        let airborne = judgement.airborne
        let homesTime = clock.measure { _ = MapHome.homes(for: input.trips, facts: input.facts, settings: input.homeSettings, detected: nil) }
        let countriesTime = clock.measure { _ = MapCountries.compute(facts: input.facts, airborne: airborne, tripStarts: [:]) }
        print(String(format: "MAP_PERF photos %d trips %d: summary %.0f ms (airborne %.0f, homes %.0f, countries %.0f) | places %d, arcs %d, pins %d",
                     library.facts.count, result.trips.count, Self.ms(best), Self.ms(airborneTime), Self.ms(homesTime), Self.ms(countriesTime),
                     result.trips.reduce(0) { $0 + $1.geometry.places.count }, result.arcs.count, result.pins.count))
        #expect(library.facts.count >= 50_000)
        #expect(result.trips.count >= 100)
        #expect(result.arcs.count <= MapSummary.maxArcs)
        #expect(result.trips.allSatisfy { $0.geometry.route.count <= TripGeometry.maxRoutePoints })

        // The flights are what the airborne filter meets in a real library: long-haul ones, some
        // with a photo every 2.5 hours, layovers, one burst or two photos only, by train to the
        // airport.
        let flights = library.flights
        print("MAP_FLIGHTS flights \(flights.count) (long-haul \(flights.longHaul), sparse \(flights.sparse), burst only \(flights.burstOnly), "
              + "two \(flights.two), layovers \(flights.layovers), by train \(flights.byTrain)): window photos \(library.windowPhotos.count), "
              + "unseen \(library.unseenWindowPhotos.count), airport and train photos \(library.travelPhotos.count)")
        #expect(flights.count >= 100)
        #expect(flights.longHaul >= 10)
        #expect([flights.sparse, flights.burstOnly, flights.two, flights.layovers, flights.byTrain].allSatisfy { $0 >= 2 })
        // What the rule promises: every window photo it can see is found, none on the ground is,
        // and those it cannot see by design are exactly the documented ones (a regression and an
        // accidental improvement both show here).
        #expect(library.windowPhotos.count >= 1_000)
        #expect(airborne.isSubset(of: library.windowPhotos), "on the ground: \(airborne.subtracting(library.windowPhotos).sorted().prefix(10))")
        #expect(airborne.isDisjoint(with: library.travelPhotos))
        #expect(!library.unseenWindowPhotos.isEmpty)
        let missed = library.windowPhotos.subtracting(airborne).subtracting(library.unseenWindowPhotos).sorted().prefix(10)
        let found = library.unseenWindowPhotos.intersection(airborne).sorted().prefix(10)
        #expect(library.windowPhotos.subtracting(airborne) == library.unseenWindowPhotos, "missed \(missed), found though unseen \(found)")
        // Only photos on the ground count (`FlightJudgement`): those the rules cannot see by
        // design have one flown leg each and are maybe taken in flight; besides them only photos
        // at airports are (a gate photo before a flight without window photos, an arrival photo),
        // never one at a destination or at home.
        let maybe = judgement.maybeInFlight
        print("MAP_MAYBE maybe in flight \(maybe.count): window photos \(maybe.intersection(library.windowPhotos).count), "
              + "airport and train photos \(maybe.intersection(library.travelPhotos).count)")
        #expect(library.unseenWindowPhotos.isSubset(of: maybe))
        #expect(maybe.isSubset(of: library.windowPhotos.union(library.travelPhotos)),
                "\(maybe.subtracting(library.windowPhotos).subtracting(library.travelPhotos).sorted().prefix(10))")
        // Debug build on a shared CI machine: the bound catches a quadratic step, the printed
        // figure is the one that matters (the app runs a release build).
        #expect(Self.ms(best) < 3_000)
        #if !DEBUG
        // A release build, as the app runs: the concept's bound itself.
        #expect(Self.ms(best) < 300, "release build: \(Self.ms(best)) ms")
        #endif
    }

    /// A library listing every photo twice (the same facts, as a caller passing them twice by
    /// mistake) gives the summary of the library listed once, about as quickly (third review: for
    /// 50,000 photos 9.9 s instead of 0.2 s in a release build, nearly all of it picking one of
    /// each two equal facts by their whole text, `MapSummary.precedes`). Equal facts need no
    /// picking.
    @Test func aLibraryListingEveryPhotoTwiceIsSummarizedAsQuicklyAsOnce() {
        let library = MapLibrary(count: 5_000)
        func input(_ facts: [AssetFacts]) -> MapInput {
            MapInput(facts: facts, trips: library.trips, homeSettings: library.homeSettings, calendar: MapFixture.calendar,
                     now: MapFixture.date("2026-11-20"))
        }
        let clock = ThreadCPUClock()
        var once: MapSummary?, twice: MapSummary?
        _ = MapSummary.build(input(library.facts))
        let onceTime = clock.measure { once = MapSummary.build(input(library.facts)) }
        let twiceTime = clock.measure { twice = MapSummary.build(input(library.facts + library.facts)) }
        #expect(twice == once)
        #expect(MapSummary.uniqueFacts(library.facts + library.facts) == library.facts)
        #expect(twiceTime < onceTime * 3, "\(library.facts.count) photos: \(Int(Self.ms(onceTime))) ms listed once, \(Int(Self.ms(twiceTime))) ms twice")
    }
}
