import Foundation
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// How `init` draws the library: trips first (each one planned, then its photos on the way and at
/// the destination), then everyday photos at home on the days no trip has.
extension MapLibrary {
    /// What a trip does at its destination: where it goes, for how many days, how many photos a
    /// day, and whether it moves on every day (a road trip).
    struct Stay {
        var destination: Destination
        var days: Int
        var perDay: Int
        var roadTrip: Bool

        init(_ destination: Destination, _ days: Int, _ perDay: Int, _ roadTrip: Bool) {
            self.destination = destination
            self.days = days
            self.perDay = perDay
            self.roadTrip = roadTrip
        }
    }

    /// A trip as drawn, before its photos: its number and id, its stay, its first day and where home
    /// was then, and its journeys there and back (none when it is not flown).
    struct TripPlan {
        var index: Int
        var id: AlbumistID
        var stay: Stay
        var first: Date
        var home: GeoCoordinate
        var homeAirport: GeoCoordinate
        var journeyOut: [Leg]
        var journeyBack: [Leg]
        /// The first gate photo of the journey there, and of the journey back.
        var departure: Date
        var departureBack: Date
        /// The first day at the destination, counted from `first`.
        var firstDay: Int
        /// From the first day to the last, the journeys included.
        var range: ClosedRange<Date>
        var flown: Bool { !journeyOut.isEmpty }
        var train: Bool { flown && stay.destination.fromFrankfurt }
    }

    /// Trips of about `tripPhotos` photos in all, none on the days of another: returns their days.
    mutating func addTrips(photos tripPhotos: Int) -> [ClosedRange<Date>] {
        var tripBudget = tripPhotos
        var tripDays: [ClosedRange<Date>] = []
        var tripIndex = 0
        while tripBudget > 0 {
            tripIndex += 1
            let plan = planTrip(tripIndex)
            if tripDays.contains(where: { $0.overlaps(plan.range) }) { continue }
            tripDays.append(plan.range)
            let members = photos(of: plan)
            tripBudget -= members.count
            facts += members
            trips.append(MapFixture.trip(plan.id, members.filter { $0.tripID == plan.id }))
        }
        return tripDays
    }

    /// Draws the trip numbered `tripIndex`: its stay, its first day, and its flights there and back
    /// if it is flown.
    mutating func planTrip(_ tripIndex: Int) -> TripPlan {
        let kind = random.int(0..<100)
        let stay = kind < 55 ? Stay(Self.nearby[random.int(0..<Self.nearby.count)], random.int(1..<4), random.int(8..<25), false)
            : kind < 92 ? Stay(Self.abroad[random.int(0..<Self.abroad.count)], random.int(4..<15), random.int(15..<35), false)
            : Stay(Self.abroad[random.int(0..<Self.abroad.count)], random.int(15..<31), random.int(20..<35), true)
        let destination = stay.destination, days = stay.days
        // Room for the journey there and back (two days on top, and a third for the longest).
        let span = Self.end.timeIntervalSince(Self.start) - Double(days + 5) * 86_400
        let first = Date(timeInterval: (span * random.unit() / 86_400).rounded(.down) * 86_400, since: Self.start)
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
        return TripPlan(index: tripIndex, id: id, stay: stay, first: first, home: home, homeAirport: homeAirport, journeyOut: journeyOut,
                        journeyBack: journeyBack, departure: departure, departureBack: departureBack, firstDay: firstDay, range: range)
    }

    /// The photos of a trip as planned: on the train to Frankfurt and the flights there if it is
    /// flown, at its destination, and on the flights back.
    mutating func photos(of plan: TripPlan) -> [AssetFacts] {
        let destination = plan.stay.destination
        var members: [AssetFacts] = []
        if plan.flown {
            if plan.train {
                flights.byTrain += 1
                members += train(from: plan.home, to: Self.frankfurtAirport, arriving: plan.departure.addingTimeInterval(-50 * 60), trip: plan.id)
            }
            let origin = plan.train ? Hub(name: "Frankfurt", country: "DE", zone: "Europe/Berlin", airport: Self.frankfurtAirport)
                : Self.homeHub(plan.homeAirport)
            members += fly(plan.journeyOut, leaving: plan.departure, origin: origin, destination: destination, trip: plan.id)
        }
        members += photosAtDestination(of: plan)
        if plan.flown {
            let hub = Hub(name: destination.name, country: destination.country, zone: destination.zone, airport: plan.journeyBack[0].from)
            members += fly(plan.journeyBack, leaving: plan.departureBack, origin: hub, destination: Self.homeDestination(plan.homeAirport),
                           trip: plan.id)
        }
        return members
    }

    /// The photos at a trip's destination: about `perDay` a day at one to three places (a road trip
    /// moves on every day); one in twenty without a location, and so in no trip.
    mutating func photosAtDestination(of plan: TripPlan) -> [AssetFacts] {
        let stay = plan.stay, destination = plan.stay.destination
        var members: [AssetFacts] = []
        var position = destination.center
        for day in 0..<stay.days {
            if stay.roadTrip {
                position = MapFixture.at(position.latitude + (random.unit() - 0.5) * 1.2, position.longitude + (random.unit() - 0.5) * 1.6)
            }
            let places = random.int(1..<4)
            for p in 0..<places {
                let spot = MapFixture.at(position.latitude + (random.unit() - 0.5) * 0.6, position.longitude + (random.unit() - 0.5) * 0.8)
                let town = "\(destination.name) \(plan.index)-\(day)-\(p)"
                let dayStart = plan.first.addingTimeInterval(Double(plan.firstDay + day) * 86_400 + Double(9 + p * 4) * 3_600)
                for k in 0..<(stay.perDay / places) {
                    let located = random.int(0..<20) != 0
                    var fact = MapFixture.photo(nextID(), at: dayStart.addingTimeInterval(Double(k) * 300),
                                                located ? Fixture.jitter(spot, seed: k, meters: 400) : nil,
                                                country: destination.country, town: town, pointOfInterest: k % 3 == 0 ? "Sight \(p)" : nil,
                                                timeZone: destination.zone, trip: plan.id, favorite: random.int(0..<50) == 0,
                                                analysed: random.int(0..<10) != 0)
                    if !located { fact.place = nil; fact.placeSource = nil; fact.tripID = nil }
                    members.append(fact)
                }
            }
        }
        return members
    }

    /// Everyday photos at home on the days no trip has, until the library holds `count` photos;
    /// one in twenty-five is a screenshot without a location.
    mutating func addEverydayPhotos(count: Int, besides tripDays: [ClosedRange<Date>]) {
        var free: [Date] = []
        var day = Self.start
        while day < Self.end {
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
