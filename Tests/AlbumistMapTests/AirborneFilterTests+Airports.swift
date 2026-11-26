import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Airports and layovers stay on the ground: photos at the airports, layovers with several photos
/// or a single one, a quick series at a short-haul layover, window photos on one fix; and a photo
/// with one flown leg and no stay is maybe in flight, so only the ground counts.
extension AirborneFilterTests {
    // MARK: Airports and layovers stay on the ground

    @Test func photosAtTheAirportsStayOnTheGround() {
        // Gate photos 45 to 5 minutes before take-off (the last one on board), window photos every
        // 5 minutes from 5 minutes after take-off to 5 before landing, photos 5, 10 and 20 minutes
        // after landing.
        let journey = Self.flight("apron", from: Self.munichAirport, to: Self.lisbonAirport, takeoff: MapFixture.date("2024-04-04 06:00"),
                                  gate: [45, 30, 20, 10, 5], arrival: [5, 10, 20]) { Self.every(5, of: $0, first: 5, last: 5) }
        let airborne = AirborneFilter.airborne(journey.photos)
        #expect(airborne.isDisjoint(with: journey.ground))
        #expect(airborne == journey.window)
        // And they count: none of them is maybe in flight either (their legs to the window photos
        // are slow).
        #expect(AirborneFilter.judge(journey.photos) == FlightJudgement(airborne: journey.window))
    }

    /// Munich → Dubai → Bangkok: a gate photo in Munich, photos at Dubai airport, Bangkok.
    static func layover(_ name: String, dubai seconds: [Double], window: Bool) -> (journey: Journey, layover: Set<AssetID>) {
        let takeoff = MapFixture.date("2024-01-15 13:00")
        let shape: (Double) -> [Double] = { window ? every(15, of: $0) : [] }
        var first = flight("\(name)-1", from: munichAirport, to: dubaiAirport, takeoff: takeoff, cruiseKmh: 880, gate: [40], arrival: [], window: shape)
        // The photos in Dubai, in seconds after landing; the next flight 40 minutes after the last.
        let stop = seconds.enumerated().map { k, s in
            shot("\(name)-dxb-\(k)", first.path.landing.addingTimeInterval(s), Fixture.jitter(dubaiAirport, seed: k + 3, meters: 1_000))
        }
        let second = flight("\(name)-2", from: dubaiAirport, to: bangkokAirport, takeoff: first.path.landing.addingTimeInterval(seconds.max()! + 40 * 60),
                            cruiseKmh: 880, gate: [], arrival: [25], window: shape)
        first.photos += stop + second.photos
        first.window.formUnion(second.window)
        first.ground.formUnion(second.ground)
        first.ground.formUnion(stop.map(\.id))
        return (first, Set(stop.map(\.id)))
    }

    @Test func aLayoverWithSeveralPhotosStaysOnTheGround() {
        let three: [Double] = [1_200, 2_100, 3_000]
        let series: [Double] = [1_800, 1_803, 1_806]
        let two: [Double] = [1_500, 4_200]
        for (name, shape) in [("three", three), ("series", series), ("two", two)] {
            for window in [false, true] {
                let (journey, layover) = Self.layover("\(name)-\(window)", dubai: shape, window: window)
                let airborne = AirborneFilter.airborne(journey.photos)
                #expect(airborne.isDisjoint(with: layover), "\(name), window photos \(window)")
                #expect(airborne == journey.window, "\(name), window photos \(window)")
                // And they count (`FlightJudgement`): a stay is on the ground.
                #expect(layover.allSatisfy(AirborneFilter.judge(journey.photos).isOnTheGround), "\(name), window photos \(window)")
            }
        }
    }

    /// The price of long legs (documented in `AirborneFilter`): a single photo at a layover
    /// between two long-haul legs shows no stay and counts as in flight. It makes no place and no
    /// record (three photos within 3 km on one day) and, alone, no country (three photos); only
    /// its town is missing from the cities.
    @Test func aSingleLayoverPhotoCountsAsInFlightAndCostsOnlyItsTown() {
        let (journey, layover) = Self.layover("single", dubai: [1_800.0], window: false)
        let airborne = AirborneFilter.airborne(journey.photos)
        #expect(airborne == layover)
        let trip = AlbumistID("bangkok")
        let facts = journey.photos.map { photo in
            let (country, town) = layover.contains(photo.id) ? ("AE", "Dubai") : photo.id.rawValue.contains("gate") ? ("DE", "Freising") : ("TH", "Bangkok")
            var fact = MapFixture.photo(photo.id.rawValue, at: photo.creationDate!, photo.location, country: country, town: town, trip: trip)
            fact.asset = photo
            return fact
        }
        let unfiltered = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(!unfiltered.contains { $0.code == "AE" })
        #expect(MapCountries.cityCount(facts: facts, airborne: airborne) == MapCountries.cityCount(facts: facts, airborne: []) - 1)
        let geometry = TripGeometry.build(trip: MapFixture.trip(trip, facts), facts: facts, airborne: [], timeZone: MapFixture.utc)
        #expect(!geometry.places.contains { $0.name == "Dubai" })
    }

    /// Finding 9 of the second review: a photo at Berlin airport, three at Vienna airport within
    /// 30 seconds 72 minutes later, one at Athens airport two hours after them. Both legs are flown
    /// (437 and 653 km/h), and on legs of up to two hours only a minute of photos was a stay: the
    /// Vienna photos counted as in flight. Five seconds (`shortestStay`) of photos that did not
    /// move on are a stay now; photos within less may share one fix in a plane, so they count as
    /// in flight, as a single photo does (documented).
    @Test func aQuickSeriesAtAShortHaulLayoverStaysOnTheGround() {
        let berlin = MapFixture.at(52.3667, 13.5033), vienna = MapFixture.at(48.1103, 16.5697), athens = MapFixture.at(37.9364, 23.9445)
        let t = MapFixture.date("2024-05-10 10:00")
        func photos(vienna seconds: [TimeInterval]) -> [AssetSnapshot] {
            let stop = seconds.enumerated().map { k, s in
                Self.shot("vie-\(k)", t.addingTimeInterval(4_320 + s), k == 0 ? vienna : Fixture.jitter(vienna, seed: k, meters: 40))
            }
            return [Self.shot("berlin", t, berlin)] + stop + [Self.shot("athens", t.addingTimeInterval(11_400), athens)]
        }
        #expect(AirborneFilter.airborne(photos(vienna: [0, 15, 30])).isEmpty)
        #expect(AirborneFilter.airborne(photos(vienna: [0, 2.5, 5])).isEmpty)
        #expect(AirborneFilter.airborne(photos(vienna: [0, 2, 4])) == ["vie-0", "vie-1", "vie-2"])
        #expect(AirborneFilter.airborne(photos(vienna: [0])) == ["vie-0"])
    }

    /// Finding 2.5 of the third review: three window photos within six seconds whose location the
    /// iPhone did not update (one fix for all three), between a gate photo 50 minutes before and
    /// the arrival photo. Both legs are flown (940 and 641 km/h), and five seconds of photos that
    /// did not move on looked like a stay: they made France a country, a place and two records.
    /// No plane lands 783 km from the gate within 50 minutes and takes off again
    /// (`landingDuration`): no stay, so they are in flight (rule 2). Each with its own fix, they
    /// are found too; the layover at Vienna stays on the ground
    /// (`aQuickSeriesAtAShortHaulLayoverStaysOnTheGround`).
    ///
    /// The same family: three photos 4 s apart with the gate photo 2 h 45 min before (rule 3),
    /// and one more 70 s later still on the third's fix. That photo was "a minute of photos near
    /// its last", a stay, and the location "came back" near all three, so all four counted. A
    /// repeated fix carries the time of the photo it was first taken for (`FlightTrack.fixTimes`):
    /// no stay, no return, and the photo goes with the series.
    @Test func windowPhotosOnOneFixBetweenTwoFlownLegsAreInFlight() {
        let window: Set<AssetID> = ["window-0", "window-1", "window-2"]
        #expect(AirborneFilter.airborne(Self.lisbonLibrary(gateSecondsBefore: 3_000, windowAt: [0, 3, 6]).facts.map(\.asset)) == window)
        let frozen = Self.lisbonLibrary(gateSecondsBefore: 3_000, windowAt: [0, 3, 6], fix: { _ in 0 })
        #expect(AirborneFilter.airborne(frozen.facts.map(\.asset)) == window)
        let summary = MapSummary.build(frozen)
        #expect(!summary.countries.map(\.code).contains("FR"))
        #expect(!summary.trips.contains { $0.geometry.places.contains { $0.name == "Wolken" } })
        #expect(summary.numbers.record(.northernmost)?.placeName != "Wolken")
        let later = Self.lisbonLibrary(gateSecondsBefore: 9_900, windowAt: [0, 4, 8, 78], fix: { min($0, 8) })
        #expect(AirborneFilter.airborne(later.facts.map(\.asset)) == window.union(["window-3"]))
        #expect(!MapSummary.build(later).countries.map(\.code).contains("FR"))
    }

    // MARK: Maybe in flight: only the ground counts

    /// `FlightJudgement`: a photo with exactly one flown leg that shows no stay is maybe taken in
    /// flight and counts for nothing. Two window photos two seconds apart over France with the
    /// gate photo 2 h 45 min before are missed by the rules (rule 3 needs three photos, rule 2 two
    /// flown legs, and the gate photo is too far for rule 4); they are maybe in flight, and so is
    /// the arrival photo after them (its leg from them is flown). The gate photo is on the ground:
    /// its legs are slow. The price: the gate and arrival photos of a flight without window
    /// photos, whose only flown leg is the flight, are maybe in flight too (each costs its town
    /// where it has no other photo). A layover's photos are judged by rule 2 (both legs flown):
    /// three at Dubai are a stay, on the ground; a single one is in flight.
    @Test func aPhotoWithOneFlownLegAndNoStayIsMaybeInFlight() {
        let pair = AirborneFilter.judge(Self.lisbonLibrary(gateSecondsBefore: 9_900, windowAt: [0, 2]).facts.map(\.asset))
        #expect(pair == FlightJudgement(maybeInFlight: ["window-0", "window-1", "landing"]))
        #expect(pair.isOnTheGround("gate") && !pair.isOnTheGround("window-0"))
        // A flight without window photos, from a morning at home to an afternoon in Lisbon.
        let bare = Self.flight("bare", from: Self.munichAirport, to: Self.lisbonAirport, takeoff: MapFixture.date("2024-04-04 08:00")) { _ in [] }
        let home = Self.shot("home", Self.minutes(bare.path.takeoff, -180), Places.regensburg)
        let city = (0..<6).map { k in
            Self.shot("lisbon-\(k)", Self.minutes(bare.path.landing, 120 + Double(k) * 20), Fixture.jitter(Places.lisbon, seed: k, meters: 300))
        }
        #expect(AirborneFilter.judge([home] + bare.photos + city) == FlightJudgement(maybeInFlight: bare.ground))
        // Layovers between flights without window photos.
        for (shape, airborne) in [([1_200.0, 2_100, 3_000], 0), ([1_800.0], 1)] {
            let (journey, layover) = Self.layover("judged-\(shape.count)", dubai: shape, window: false)
            let judged = AirborneFilter.judge(journey.photos)
            #expect(judged == FlightJudgement(airborne: airborne == 0 ? [] : layover, maybeInFlight: journey.ground.subtracting(layover)))
        }
    }
}
