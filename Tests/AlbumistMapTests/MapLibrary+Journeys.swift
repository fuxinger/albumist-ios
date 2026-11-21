import Foundation
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// How the library's trips get there and back: the flights of a journey, with photos at the gate,
/// out of the window, at a layover and after landing, and the train to the airport in Frankfurt.
extension MapLibrary {
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
    mutating func fly(_ journey: [Leg], leaving departure: Date, origin: Hub, destination: Destination, trip: AlbumistID) -> [AssetFacts] {
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
            let flying = window(path, leg.shape, trip: trip)
            flights.add(leg, along: path)
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
    mutating func window(_ path: Flight, _ shape: Shape, trip: AlbumistID) -> [AssetFacts] {
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
    mutating func train(from: GeoCoordinate, to: GeoCoordinate, arriving: Date, trip: AlbumistID) -> [AssetFacts] {
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

    /// A point on the unit sphere, as `along` works with it.
    struct Vector {
        var x: Double
        var y: Double
        var z: Double
    }

    /// The point a fraction `f` of the way from `a` to `b` on the great circle (a plane's track).
    static func along(_ a: GeoCoordinate, _ b: GeoCoordinate, _ f: Double) -> GeoCoordinate {
        func vector(_ c: GeoCoordinate) -> Vector {
            let latitude = c.latitude * .pi / 180, longitude = c.longitude * .pi / 180
            return Vector(x: cos(latitude) * cos(longitude), y: cos(latitude) * sin(longitude), z: sin(latitude))
        }
        let p = vector(a), q = vector(b)
        let angle = acos(min(1, max(-1, p.x * q.x + p.y * q.y + p.z * q.z)))
        guard angle > 1e-12 else { return a }
        let wa = sin((1 - f) * angle) / sin(angle), wb = sin(f * angle) / sin(angle)
        let x = wa * p.x + wb * q.x, y = wa * p.y + wb * q.y, z = wa * p.z + wb * q.z
        return MapFixture.at(atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi, atan2(y, x) * 180 / .pi)
    }
}
