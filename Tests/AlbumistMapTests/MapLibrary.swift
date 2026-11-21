import Foundation
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// A synthetic library for the map's end-to-end and speed tests: ten years of everyday photos at
/// home (Hamburg until the end of 2018, then the Regensburg area), and trips of every kind: day
/// trips and weekends nearby, holidays abroad (most of them flown, with photos at the gate, out of
/// the plane window and at the arrival airport), long road trips. Deterministic for a seed.
///
/// Flights as people take photos on them (`Flight`): gate photos 30 to 45 minutes before
/// take-off, window photos every 5 to 15 minutes from about 10 minutes after take-off to about
/// 10 minutes before landing (some of them bursts of 3 to 5 photos seconds apart, on long-haul
/// flights sometimes hours without one), arrival photos after landing. Long-haul flights of 6,000
/// to 12,000 km (some with a window photo only every 2.5 hours): Frankfurt to Tokyo (by train to
/// Frankfurt), Munich to New York and California, Munich to Bangkok with a layover of several
/// photos in Dubai, New Zealand and Fiji via Singapore. And the shapes the airborne filter cannot
/// see by design (`unseenWindowPhotos`).
struct MapLibrary {
    var facts: [AssetFacts] = []
    var trips: [Trip] = []
    var homeSettings = HomeSettings()
    /// Photos taken in flight, as the library was built.
    var windowPhotos: Set<AssetID> = []
    /// The window photos `AirborneFilter` cannot see by design (its doc comment lists them;
    /// `markUnseen` picks them): both window photos of a flight with only two, and the first or
    /// last window photo of a flight with one every 2.5 hours, each where its leg to the airport
    /// is slow.
    var unseenWindowPhotos: Set<AssetID> = []
    /// Photos at airports (gate, layover, arrival) and on the train to the airport: the ground
    /// around flights, which must never count as in flight.
    var travelPhotos: Set<AssetID> = []
    /// What the flights are like.
    var flights = Flights()

    struct Flights {
        var count = 0
        /// 6,000 km and more.
        var longHaul = 0
        /// A window photo every 2.5 hours.
        var sparse = 0
        /// Only one burst of window photos.
        var burstOnly = 0
        /// Only two window photos.
        var two = 0
        /// Layovers (with several photos at the hub).
        var layovers = 0
        /// Journeys to the airport by train.
        var byTrain = 0
    }

    static let hamburg = MapFixture.at(53.5511, 9.9937)
    static let movedOn = MapFixture.date("2019-01-01")
    static let hamburgAirport = MapFixture.at(53.6304, 9.9882)
    static let munichAirport = MapFixture.at(48.3538, 11.7861)
    static let frankfurtAirport = MapFixture.at(50.0379, 8.5622)

    struct Hub {
        var name: String
        var country: String
        var zone: String
        var airport: GeoCoordinate
    }

    static let dubai = Hub(name: "Dubai", country: "AE", zone: "Asia/Dubai", airport: MapFixture.at(25.2532, 55.3657))
    static let singapore = Hub(name: "Singapur", country: "SG", zone: "Asia/Singapore", airport: MapFixture.at(1.3644, 103.9915))

    struct Destination {
        var name: String
        var country: String
        var zone: String
        var center: GeoCoordinate
        /// Where flights land, if it is flown to.
        var airport: GeoCoordinate? = nil
        /// A layover on the way there and back.
        var via: Hub? = nil
        /// Flights there leave from Frankfurt, reached by train.
        var fromFrankfurt = false
    }

    static let nearby: [Destination] = [
        Destination(name: "Bayerischer Wald", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(48.95, 13.40)),
        Destination(name: "München", country: "DE", zone: "Europe/Berlin", center: MapFixture.Places.munich),
        Destination(name: "Nürnberg", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(49.4521, 11.0767)),
        Destination(name: "Salzburg", country: "AT", zone: "Europe/Vienna", center: MapFixture.at(47.8095, 13.0550)),
        Destination(name: "Prag", country: "CZ", zone: "Europe/Prague", center: MapFixture.at(50.0755, 14.4378)),
        Destination(name: "Passau", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(48.5667, 13.4319)),
        Destination(name: "Bodensee", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(47.6600, 9.4500)),
        Destination(name: "Wien", country: "AT", zone: "Europe/Vienna", center: MapFixture.at(48.2082, 16.3738)),
    ]

    static let abroad: [Destination] = [
        Destination(name: "Island", country: "IS", zone: "Atlantic/Reykjavik", center: MapFixture.at(64.10, -20.50), airport: MapFixture.at(63.9850, -22.6056)),
        Destination(name: "Lissabon", country: "PT", zone: "Europe/Lisbon", center: MapFixture.Places.lisbon, airport: MapFixture.at(38.7742, -9.1342)),
        Destination(name: "Rom", country: "IT", zone: "Europe/Rome", center: MapFixture.Places.rome, airport: MapFixture.at(41.8003, 12.2389)),
        Destination(name: "Toskana", country: "IT", zone: "Europe/Rome", center: MapFixture.Places.florence, airport: MapFixture.at(43.8100, 11.2051)),
        Destination(name: "Kreta", country: "GR", zone: "Europe/Athens", center: MapFixture.at(35.24, 24.81), airport: MapFixture.at(35.3397, 25.1803)),
        Destination(name: "Mallorca", country: "ES", zone: "Europe/Madrid", center: MapFixture.at(39.6953, 3.0176), airport: MapFixture.at(39.5517, 2.7388)),
        Destination(name: "Dalmatien", country: "HR", zone: "Europe/Zagreb", center: MapFixture.at(43.5081, 16.4402), airport: MapFixture.at(43.5389, 16.2980)),
        Destination(name: "Provence", country: "FR", zone: "Europe/Paris", center: MapFixture.at(43.9493, 4.8055), airport: MapFixture.at(43.4393, 5.2214)),
        Destination(name: "Lofoten", country: "NO", zone: "Europe/Oslo", center: MapFixture.at(68.2, 13.9), airport: MapFixture.at(67.2692, 14.3653)),
        Destination(name: "Schottland", country: "GB", zone: "Europe/London", center: MapFixture.at(57.12, -4.71), airport: MapFixture.at(57.5425, -4.0475)),
        Destination(name: "New York", country: "US", zone: "America/New_York", center: MapFixture.at(40.7128, -74.0060), airport: MapFixture.at(40.6413, -73.7781)),
        Destination(name: "Kalifornien", country: "US", zone: "America/Los_Angeles", center: MapFixture.at(36.7783, -119.4179), airport: MapFixture.at(33.9416, -118.4085)),
        Destination(name: "Tokio", country: "JP", zone: "Asia/Tokyo", center: MapFixture.Places.tokyo, airport: MapFixture.at(35.7720, 140.3929),
                    fromFrankfurt: true),
        Destination(name: "Bangkok", country: "TH", zone: "Asia/Bangkok", center: MapFixture.at(13.7563, 100.5018), airport: MapFixture.at(13.6900, 100.7501),
                    via: dubai),
        Destination(name: "Kapstadt", country: "ZA", zone: "Africa/Johannesburg", center: MapFixture.at(-33.9249, 18.4241), airport: MapFixture.at(-33.9715, 18.6021)),
        Destination(name: "Neuseeland", country: "NZ", zone: "Pacific/Auckland", center: MapFixture.Places.auckland, airport: MapFixture.at(-37.0082, 174.7850),
                    via: singapore),
        Destination(name: "Fidschi", country: "FJ", zone: "Pacific/Fiji", center: MapFixture.Places.suva, airport: MapFixture.at(-17.7554, 177.4433), via: singapore),
        Destination(name: "Marrakesch", country: "MA", zone: "Africa/Casablanca", center: MapFixture.at(31.6295, -7.9811), airport: MapFixture.at(31.6069, -8.0363)),
        Destination(name: "Kopenhagen", country: "DK", zone: "Europe/Copenhagen", center: MapFixture.at(55.6761, 12.5683), airport: MapFixture.at(55.6180, 12.6508)),
        Destination(name: "Amsterdam", country: "NL", zone: "Europe/Amsterdam", center: MapFixture.at(52.3676, 4.9041), airport: MapFixture.at(52.3105, 4.7683)),
    ]

    /// About `count` photos (the last day may round it a little; with very few photos per day
    /// the ten years may end first).
    init(count: Int = 50_000, seed: UInt64 = 7) {
        var random = MapRandom(seed: seed)
        var counter = 0
        func nextID() -> String { counter += 1; return String(format: "p%06d", counter) }
        let start = MapFixture.date("2016-01-01"), end = MapFixture.date("2026-10-31")
        homeSettings = HomeSettings(former: [FormerHome(place: HomePlace(center: Self.hamburg, components: PlaceComponents(isoCountryCode: "DE")),
                                                        until: Self.movedOn)])

        // Trips first: their days are kept free of everyday photos.
        let tripPhotos = count * 2 / 5
        var tripBudget = tripPhotos
        var tripDays: [ClosedRange<Date>] = []
        var tripIndex = 0
        while tripBudget > 0 {
            tripIndex += 1
            let kind = random.int(0..<100)
            let (destination, days, perDay, roadTrip): (Destination, Int, Int, Bool) =
                kind < 55 ? (Self.nearby[random.int(0..<Self.nearby.count)], random.int(1..<4), random.int(8..<25), false)
                : kind < 92 ? (Self.abroad[random.int(0..<Self.abroad.count)], random.int(4..<15), random.int(15..<35), false)
                : (Self.abroad[random.int(0..<Self.abroad.count)], random.int(15..<31), random.int(20..<35), true)
            // Room for the journey there and back (two days on top, and a third for the longest).
            let span = end.timeIntervalSince(start) - Double(days + 5) * 86_400
            let first = Date(timeInterval: (span * random.unit() / 86_400).rounded(.down) * 86_400, since: start)
            let id = AlbumistID("trip-\(tripIndex)")
            let home = first < Self.movedOn ? Self.hamburg : MapFixture.Places.regensburg
            let homeAirport = first < Self.movedOn ? Self.hamburgAirport : Self.munichAirport

            // Flown: most trips abroad 450 km and more away (a plane's climb and descent need some
            // 400 km), always beyond 3,000 km.
            var journeyOut: [Leg] = [], journeyBack: [Leg] = []
            if kind >= 55, let airport = destination.airport {
                let origin = destination.fromFrankfurt ? Self.frankfurtAirport : homeAirport
                let meters = GeoMath.distance(origin, airport)
                if meters >= 450_000 && (meters >= 3_000_000 || random.int(0..<4) != 0) {
                    let hops = destination.via.map { [($0.airport, $0)] } ?? []
                    journeyOut = Self.plan(from: origin, to: airport, via: hops.first, random: &random)
                    journeyBack = Self.plan(from: airport, to: homeAirport, via: hops.first, random: &random)
                }
            }
            let flown = !journeyOut.isEmpty
            let train = flown && destination.fromFrankfurt
            // Day 0 the journey there (from 04:00 UTC, by train first where it leaves from
            // Frankfurt); the days at the destination start the first day whose 09:00 UTC is an
            // hour after the arrival photos; then the journey back.
            let departure = first.addingTimeInterval(Double(5 + random.int(0..<4)) * 3_600 + (train ? 4 * 3_600 : 0))
            let arrivalOut = Self.arrival(of: journeyOut, leaving: departure)
            var firstDay = flown ? 1 : 0
            while flown && first.addingTimeInterval(Double(firstDay) * 86_400 + 9 * 3_600) < arrivalOut.addingTimeInterval(3_600) { firstDay += 1 }
            let backDay = firstDay + days
            let departureBack = first.addingTimeInterval(Double(backDay) * 86_400 + Double(6 + random.int(0..<4)) * 3_600)
            let arrivalBack = Self.arrival(of: journeyBack, leaving: departureBack)
            let lastDay = flown ? Int((arrivalBack.timeIntervalSince(first) / 86_400).rounded(.down)) : days
            let range = first...first.addingTimeInterval(Double(lastDay) * 86_400)
            if tripDays.contains(where: { $0.overlaps(range) }) { continue }
            tripDays.append(range)

            var members: [AssetFacts] = []
            var position = destination.center
            if flown {
                if train {
                    flights.byTrain += 1
                    members += self.train(from: home, to: Self.frankfurtAirport, arriving: departure.addingTimeInterval(-50 * 60), trip: id,
                                          random: &random, nextID: nextID)
                }
                members += fly(journeyOut, leaving: departure, origin: train ? Hub(name: "Frankfurt", country: "DE", zone: "Europe/Berlin",
                                                                                     airport: Self.frankfurtAirport) : Self.homeHub(homeAirport),
                               destination: destination, trip: id, random: &random, nextID: nextID)
            }
            for day in 0..<days {
                if roadTrip {
                    position = MapFixture.at(position.latitude + (random.unit() - 0.5) * 1.2, position.longitude + (random.unit() - 0.5) * 1.6)
                }
                let places = random.int(1..<4)
                for p in 0..<places {
                    let spot = MapFixture.at(position.latitude + (random.unit() - 0.5) * 0.6, position.longitude + (random.unit() - 0.5) * 0.8)
                    let town = "\(destination.name) \(tripIndex)-\(day)-\(p)"
                    let dayStart = first.addingTimeInterval(Double(firstDay + day) * 86_400 + Double(9 + p * 4) * 3_600)
                    for k in 0..<(perDay / places) {
                        let located = random.int(0..<20) != 0
                        var fact = MapFixture.photo(nextID(), at: dayStart.addingTimeInterval(Double(k) * 300),
                                                    located ? Fixture.jitter(spot, seed: k, meters: 400) : nil,
                                                    country: destination.country, town: town, pointOfInterest: k % 3 == 0 ? "Sight \(p)" : nil,
                                                    timeZone: destination.zone, trip: id, favorite: random.int(0..<50) == 0,
                                                    analysed: random.int(0..<10) != 0)
                        if !located { fact.place = nil; fact.placeSource = nil; fact.tripID = nil }
                        members.append(fact)
                    }
                }
            }
            if flown {
                let hub = Hub(name: destination.name, country: destination.country, zone: destination.zone, airport: journeyBack[0].from)
                members += fly(journeyBack, leaving: departureBack, origin: hub, destination: Self.homeDestination(homeAirport),
                               trip: id, random: &random, nextID: nextID)
            }
            tripBudget -= members.count
            facts += members
            trips.append(MapFixture.trip(id, members.filter { $0.tripID == id }))
        }

        // Everyday photos at home on the other days, as many as fill up `count`.
        var free: [Date] = []
        var day = start
        while day < end {
            if !tripDays.contains(where: { $0.contains(day) }) { free.append(day) }
            day = day.addingTimeInterval(86_400)
        }
        // Rounded up: the days drawn below average a little more, so the free days fill `count`.
        let perDay = max(2, Int((Double(count - facts.count) / Double(max(1, free.count))).rounded(.up)))
        for day in free where facts.count < count {
            let home = day < Self.movedOn ? Self.hamburg : MapFixture.Places.regensburg
            for k in 0..<random.int(perDay / 2..<(perDay * 3 / 2 + 2)) {
                let isScreenshot = random.int(0..<25) == 0
                var fact = MapFixture.photo(nextID(), at: day.addingTimeInterval(Double(8 * 3_600 + k * 2_400)),
                                            isScreenshot ? nil : Fixture.jitter(home, seed: k + Int(day.timeIntervalSince1970) % 997, meters: 6_000),
                                            country: "DE", town: day < Self.movedOn ? "Hamburg" : "Regensburg", timeZone: "Europe/Berlin",
                                            atHome: !isScreenshot)
                if isScreenshot { fact.asset.subtypes = [.screenshot]; fact.place = nil; fact.placeSource = nil }
                facts.append(fact)
            }
        }
    }
}

/// A plane's way from take-off to landing, for photos out of its window: on the great circle,
/// climbing for `rampSeconds` from `liftOffSpeed` to its cruise speed, cruising, and descending
/// the last `rampSeconds` back to `liftOffSpeed`. So it covers some 70 km in its first ten
/// minutes in the air, as an airliner does (250 knots below 10,000 feet).
struct Flight {
    static let rampSeconds: TimeInterval = 20 * 60
    static let liftOffSpeed = 300.0 / 3.6
    var from: GeoCoordinate
    var to: GeoCoordinate
    var takeoff: Date
    /// Metres per second over the ground at cruise.
    var cruise: Double
    /// The great-circle distance, and the time from take-off to landing.
    let meters: Double
    let seconds: TimeInterval

    init(from: GeoCoordinate, to: GeoCoordinate, takeoff: Date, cruiseKmh: Double = 850) {
        self.from = from
        self.to = to
        self.takeoff = takeoff
        cruise = cruiseKmh / 3.6
        meters = GeoMath.distance(from, to)
        let ramps = 2 * Self.rampSeconds * (Self.liftOffSpeed + cruise) / 2
        precondition(meters >= ramps, "too short for a climb and a descent")
        seconds = 2 * Self.rampSeconds + (meters - ramps) / cruise
    }

    var minutes: Double { seconds / 60 }
    var landing: Date { takeoff.addingTimeInterval(seconds) }

    /// Metres flown `t` seconds after take-off.
    func flown(after t: TimeInterval) -> Double {
        func ramp(_ x: Double) -> Double { Self.liftOffSpeed * x + (cruise - Self.liftOffSpeed) * x * x / (2 * Self.rampSeconds) }
        if t <= Self.rampSeconds { return ramp(max(0, t)) }
        if t >= seconds - Self.rampSeconds { return meters - ramp(max(0, seconds - t)) }
        return ramp(Self.rampSeconds) + cruise * (t - Self.rampSeconds)
    }

    func position(minutes: Double) -> GeoCoordinate { MapLibrary.along(from, to, flown(after: minutes * 60) / meters) }
    func date(minutes: Double) -> Date { takeoff.addingTimeInterval(minutes * 60) }
}
