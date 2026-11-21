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

    // MARK: Journeys

    /// How the window photos of one flight are taken.
    enum Shape {
        /// Every 5 to 15 minutes from about 10 minutes after take-off to about 10 minutes before
        /// landing, some of them bursts; with `sleep`, none in the middle 40 % of the flight.
        case regular(sleep: Bool)
        /// One every 2.5 hours.
        case sparse
        /// Only a burst of `photos` photos seconds apart in the middle of the flight: rule 3 finds
        /// four or more on their own, and three as they head on from the gate photo towards the
        /// arrival photo (on a long-haul flight rule 2 may find them too).
        case burst(photos: Int)
        /// Only two, about 10 minutes after take-off and before landing (unseen by design).
        case two
        /// None (asleep).
        case none
    }

    /// One flight of a journey: from, to, its shape, and the time on the ground before it (from the
    /// first gate or layover photo to take-off).
    struct Leg {
        var from: GeoCoordinate
        var to: GeoCoordinate
        var shape: Shape
        var groundBefore: TimeInterval
        /// The layover after it, if any.
        var hub: Hub?
        var path: Flight { Flight(from: from, to: to, takeoff: Date(timeIntervalSinceReferenceDate: 0), cruiseKmh: cruiseKmh) }
        var cruiseKmh: Double
    }

    /// The flights from `from` to `to`, with a layover at `via`: their shapes picked by distance.
    static func plan(from: GeoCoordinate, to: GeoCoordinate, via: (GeoCoordinate, Hub)?, random: inout MapRandom) -> [Leg] {
        func leg(_ a: GeoCoordinate, _ b: GeoCoordinate, hub: Hub?) -> Leg {
            let meters = GeoMath.distance(a, b)
            let cruise = meters > 4_000_000 ? 880.0 : 800.0
            let draw = random.int(0..<100)
            let shape: Shape
            if meters > 5_000_000 {
                shape = draw < 45 ? .regular(sleep: random.int(0..<2) == 0) : draw < 70 ? .sparse : draw < 85 ? .burst(photos: 4) : .none
            } else {
                shape = draw < 70 ? .regular(sleep: false) : draw < 82 ? .two : draw < 92 ? .burst(photos: 4 + random.int(0..<2)) : .burst(photos: 3)
            }
            // The first gate photo 50 to 90 minutes before take-off, the last 30 to 45.
            return Leg(from: a, to: b, shape: shape, groundBefore: Double(50 + random.int(0..<41)) * 60, hub: hub, cruiseKmh: cruise)
        }
        guard let (stop, hub) = via else { return [leg(from, to, hub: nil)] }
        return [leg(from, stop, hub: hub), leg(stop, to, hub: nil)]
    }

    /// When the last arrival photo of a journey leaving (first gate photo) at `departure` is taken.
    static func arrival(of journey: [Leg], leaving departure: Date) -> Date {
        var time = departure
        for leg in journey {
            time = time.addingTimeInterval(leg.groundBefore + leg.path.seconds)
            // Layover: the second flight's ground time counts from the first layover photo.
            time = time.addingTimeInterval(leg.hub == nil ? 40 * 60 : 25 * 60)
        }
        return time
    }

    static func homeHub(_ airport: GeoCoordinate) -> Hub {
        airport == hamburgAirport ? Hub(name: "Hamburg Flughafen", country: "DE", zone: "Europe/Berlin", airport: airport)
            : Hub(name: "Freising", country: "DE", zone: "Europe/Berlin", airport: airport)
    }

    static func homeDestination(_ airport: GeoCoordinate) -> Destination {
        let hub = homeHub(airport)
        return Destination(name: hub.name, country: hub.country, zone: hub.zone, center: airport, airport: airport)
    }

    /// The photos of a journey leaving (first gate photo) at `departure`: gate photos at `origin`,
    /// each flight's window photos, layover photos, arrival photos at the destination airport.
    mutating func fly(_ journey: [Leg], leaving departure: Date, origin: Hub, destination: Destination, trip: AlbumistID,
                      random: inout MapRandom, nextID: () -> String) -> [AssetFacts] {
        var photos: [AssetFacts] = []
        var ground = origin
        var time = departure
        for (index, leg) in journey.enumerated() {
            // At the gate (or the layover): the first photo at `time`, the last 30 to 45 minutes
            // before take-off. At a layover the photos began after landing (below).
            let takeoff = time.addingTimeInterval(leg.groundBefore)
            if index == 0 {
                let gates = 1 + random.int(0..<3)
                for g in 0..<gates {
                    let at = g == gates - 1 ? takeoff.addingTimeInterval(-Double(30 + random.int(0..<16)) * 60)
                        : time.addingTimeInterval(Double(g) * 10 * 60)
                    photos.append(travel(nextID(), at: at, Fixture.jitter(ground.airport, seed: counterSeed(at), meters: 800), ground, trip: trip))
                }
            }
            let before = photos[photos.count - 1]
            let path = Flight(from: leg.from, to: leg.to, takeoff: takeoff, cruiseKmh: leg.cruiseKmh)
            let flying = window(path, leg.shape, trip: trip, random: &random, nextID: nextID)
            flights.count += 1
            if path.meters >= 6_000_000 { flights.longHaul += 1 }
            if leg.hub != nil { flights.layovers += 1 }
            switch leg.shape {
            case .sparse: flights.sparse += 1
            case .burst: flights.burstOnly += 1
            case .two: flights.two += 1
            case .regular, .none: break
            }
            photos += flying
            let landed = path.landing
            let after = photos.count
            if let hub = leg.hub {
                // Layover: 3 or 4 photos from 20 minutes after landing over 30 to 60 minutes; the next
                // flight leaves 30 to 45 minutes after the last of them.
                let count = 3 + random.int(0..<2)
                let spread = Double(30 + random.int(0..<31)) * 60
                for k in 0..<count {
                    let at = landed.addingTimeInterval(20 * 60 + spread * Double(k) / Double(count - 1))
                    photos.append(travel(nextID(), at: at, Fixture.jitter(hub.airport, seed: counterSeed(at), meters: 1_500), hub, trip: trip))
                }
                ground = hub
                time = landed.addingTimeInterval(20 * 60 + spread + Double(30 + random.int(0..<16)) * 60 - journey[index + 1].groundBefore)
            } else {
                // Arrival: 1 or 2 photos 20 to 40 minutes after landing.
                let first = landed.addingTimeInterval(Double(20 + random.int(0..<21)) * 60)
                for k in 0..<(1 + random.int(0..<2)) {
                    let at = first.addingTimeInterval(Double(k) * 15 * 60)
                    let hub = Hub(name: "\(destination.name) Flughafen", country: destination.country, zone: destination.zone,
                                  airport: destination.airport ?? destination.center)
                    photos.append(travel(nextID(), at: at, Fixture.jitter(hub.airport, seed: counterSeed(at), meters: 800), hub, trip: trip))
                }
            }
            markUnseen(flying, leg.shape, after: before, before: photos[after])
        }
        return photos
    }

    /// Of one flight's window photos, those `AirborneFilter` cannot see by design (its doc comment
    /// lists them), given the airport photos right before and after them: both photos of a flight
    /// with two (near the airports, so their legs to the airports are slow); the first or last
    /// window photo of a flight with one every 2.5 hours, when its leg to the airport is slow (too
    /// far from the next window photo for rule 4).
    mutating func markUnseen(_ flying: [AssetFacts], _ shape: Shape, after ground: AssetFacts, before next: AssetFacts) {
        guard let first = flying.first, let last = flying.last else { return }
        let slowBefore = !Self.flown(ground, first), slowAfter = !Self.flown(last, next)
        switch shape {
        case .two:
            precondition(slowBefore && slowAfter, "two window photos near the airports")
            unseenWindowPhotos.formUnion(flying.map(\.id))
        case .sparse:
            if slowBefore { unseenWindowPhotos.insert(first.id) }
            if slowAfter { unseenWindowPhotos.insert(last.id) }
        default:
            break
        }
    }

    /// Faster than ground transport and not faster than a plane, from `a` to `b`.
    static func flown(_ a: AssetFacts, _ b: AssetFacts) -> Bool {
        let meters = GeoMath.distance(a.asset.location!, b.asset.location!)
        let seconds = b.asset.creationDate!.timeIntervalSince(a.asset.creationDate!)
        return meters > AirborneFilter.maximumGroundSpeed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
    }

    func counterSeed(_ date: Date) -> Int { Int(date.timeIntervalSinceReferenceDate) % 9_973 }

    mutating func travel(_ id: String, at date: Date, _ coordinate: GeoCoordinate, _ hub: Hub, trip: AlbumistID) -> AssetFacts {
        let fact = MapFixture.photo(id, at: date, coordinate, country: hub.country, town: hub.name, timeZone: hub.zone, trip: trip)
        travelPhotos.insert(fact.id)
        return fact
    }

    /// The window photos of one flight.
    mutating func window(_ path: Flight, _ shape: Shape, trip: AlbumistID, random: inout MapRandom, nextID: () -> String) -> [AssetFacts] {
        var photos: [AssetFacts] = []
        func shoot(_ minutes: Double, burst: Int = 1, stepSeconds: Double = 3) {
            for b in 0..<burst {
                let at = minutes + Double(b) * stepSeconds / 60
                let fact = MapFixture.photo(nextID(), at: path.date(minutes: at), path.position(minutes: at), trip: trip)
                windowPhotos.insert(fact.id)
                photos.append(fact)
            }
        }
        let total = path.minutes
        switch shape {
        case .regular(let sleep):
            let first = 8 + 4 * random.unit(), last = total - 8 - 4 * random.unit()
            var slots = [first]
            while last - slots[slots.count - 1] > 15 {
                slots.append(slots[slots.count - 1] + min(5 + 10 * random.unit(), last - slots[slots.count - 1] - 5))
            }
            slots.append(last)
            if sleep { slots.removeAll { $0 > total * 0.3 && $0 < total * 0.7 } }
            for minutes in slots {
                let burst = random.int(0..<7) == 0 ? 3 + random.int(0..<3) : 1
                shoot(minutes, burst: burst, stepSeconds: Double(2 + random.int(0..<4)))
            }
        case .sparse:
            var minutes = 150.0
            while minutes <= total - 10 { shoot(minutes); minutes += 150 }
        case .burst(let count):
            shoot(total * (0.4 + 0.2 * random.unit()), burst: count, stepSeconds: Double(2 + random.int(0..<3)))
        case .two:
            shoot(8 + 4 * random.unit())
            shoot(total - 8 - 4 * random.unit())
        case .none:
            break
        }
        return photos
    }

    /// Photos on a train at up to 280 km/h from `from` to `to`, arriving at `arriving`: one every
    /// 5 to 30 minutes and a burst on the way. On the ground.
    mutating func train(from: GeoCoordinate, to: GeoCoordinate, arriving: Date, trip: AlbumistID, random: inout MapRandom,
                        nextID: () -> String) -> [AssetFacts] {
        let meters = GeoMath.distance(from, to), speed = 280_000.0 / 3_600
        let seconds = meters / speed, leaving = arriving.addingTimeInterval(-seconds)
        var photos: [AssetFacts] = []
        var t = 0.0
        let burstAt = seconds * random.unit()
        var burstDone = false
        while t <= seconds {
            let count = !burstDone && t >= burstAt ? 4 : 1
            if count > 1 { burstDone = true }
            for b in 0..<count {
                let at = min(seconds, t + Double(b) * 3)
                let fact = MapFixture.photo(nextID(), at: leaving.addingTimeInterval(at),
                                            Fixture.jitter(Self.along(from, to, at / seconds), seed: counterSeed(leaving) + b, meters: 60),
                                            country: "DE", timeZone: "Europe/Berlin", trip: trip)
                travelPhotos.insert(fact.id)
                photos.append(fact)
            }
            t += Double(5 + random.int(0..<26)) * 60
        }
        return photos
    }

    /// The point a fraction `f` of the way from `a` to `b` on the great circle (a plane's track).
    static func along(_ a: GeoCoordinate, _ b: GeoCoordinate, _ f: Double) -> GeoCoordinate {
        func vector(_ c: GeoCoordinate) -> (x: Double, y: Double, z: Double) {
            let latitude = c.latitude * .pi / 180, longitude = c.longitude * .pi / 180
            return (cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
        }
        let p = vector(a), q = vector(b)
        let angle = acos(min(1, max(-1, p.x * q.x + p.y * q.y + p.z * q.z)))
        guard angle > 1e-12 else { return a }
        let wa = sin((1 - f) * angle) / sin(angle), wb = sin(f * angle) / sin(angle)
        let x = wa * p.x + wb * q.x, y = wa * p.y + wb * q.y, z = wa * p.z + wb * q.z
        return MapFixture.at(atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi, atan2(y, x) * 180 / .pi)
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
