import Foundation
@testable import SortlyCore
import SortlyMap
import SortlyTestSupport

/// A synthetic library for the map's end-to-end and speed tests: ten years of everyday photos at
/// home (Hamburg until the end of 2018, then the Regensburg area), and trips of every kind: day
/// trips and weekends nearby, holidays abroad (some flown, with photos out of the plane window),
/// long road trips. Deterministic for a seed.
struct MapLibrary {
    var facts: [AssetFacts] = []
    var trips: [Trip] = []
    var homeSettings = HomeSettings()
    /// Photos taken in flight, as the library was built (the filter must find them).
    var windowPhotos: Set<AssetID> = []

    static let hamburg = MapFixture.at(53.5511, 9.9937)
    static let movedOn = MapFixture.date("2019-01-01")
    static let hamburgAirport = MapFixture.at(53.6304, 9.9882)
    static let munichAirport = MapFixture.at(48.3538, 11.7861)

    struct Destination {
        var name: String
        var country: String
        var zone: String
        var center: GeoCoordinate
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
        Destination(name: "Island", country: "IS", zone: "Atlantic/Reykjavik", center: MapFixture.at(64.10, -20.50)),
        Destination(name: "Lissabon", country: "PT", zone: "Europe/Lisbon", center: MapFixture.Places.lisbon),
        Destination(name: "Rom", country: "IT", zone: "Europe/Rome", center: MapFixture.Places.rome),
        Destination(name: "Toskana", country: "IT", zone: "Europe/Rome", center: MapFixture.Places.florence),
        Destination(name: "Kreta", country: "GR", zone: "Europe/Athens", center: MapFixture.at(35.24, 24.81)),
        Destination(name: "Mallorca", country: "ES", zone: "Europe/Madrid", center: MapFixture.at(39.6953, 3.0176)),
        Destination(name: "Dalmatien", country: "HR", zone: "Europe/Zagreb", center: MapFixture.at(43.5081, 16.4402)),
        Destination(name: "Provence", country: "FR", zone: "Europe/Paris", center: MapFixture.at(43.9493, 4.8055)),
        Destination(name: "Lofoten", country: "NO", zone: "Europe/Oslo", center: MapFixture.at(68.2, 13.9)),
        Destination(name: "Schottland", country: "GB", zone: "Europe/London", center: MapFixture.at(57.12, -4.71)),
        Destination(name: "New York", country: "US", zone: "America/New_York", center: MapFixture.at(40.7128, -74.0060)),
        Destination(name: "Kalifornien", country: "US", zone: "America/Los_Angeles", center: MapFixture.at(36.7783, -119.4179)),
        Destination(name: "Tokio", country: "JP", zone: "Asia/Tokyo", center: MapFixture.Places.tokyo),
        Destination(name: "Bangkok", country: "TH", zone: "Asia/Bangkok", center: MapFixture.at(13.7563, 100.5018)),
        Destination(name: "Kapstadt", country: "ZA", zone: "Africa/Johannesburg", center: MapFixture.at(-33.9249, 18.4241)),
        Destination(name: "Neuseeland", country: "NZ", zone: "Pacific/Auckland", center: MapFixture.Places.auckland),
        Destination(name: "Fidschi", country: "FJ", zone: "Pacific/Fiji", center: MapFixture.Places.suva),
        Destination(name: "Marrakesch", country: "MA", zone: "Africa/Casablanca", center: MapFixture.at(31.6295, -7.9811)),
        Destination(name: "Kopenhagen", country: "DK", zone: "Europe/Copenhagen", center: MapFixture.at(55.6761, 12.5683)),
        Destination(name: "Amsterdam", country: "NL", zone: "Europe/Amsterdam", center: MapFixture.at(52.3676, 4.9041)),
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
            let span = end.timeIntervalSince(start) - Double(days + 2) * 86_400
            let first = Date(timeInterval: (span * random.unit() / 86_400).rounded(.down) * 86_400, since: start)
            let range = first...first.addingTimeInterval(Double(days) * 86_400)
            if tripDays.contains(where: { $0.overlaps(range) }) { continue }
            tripDays.append(range)
            let id = SortlyID("trip-\(tripIndex)")
            var members: [AssetFacts] = []
            var position = destination.center
            if kind >= 55 && random.int(0..<2) == 0 {
                // A flight: a photo at the gate, three out of the window at 800 km/h over the
                // ground, one after landing. Only flights of 1,500 to 3,200 km: there every window
                // photo has a photo before and after it within two hours (AirborneFilter's legs);
                // the window photos of longer flights are found by their altitude.
                let airport = first < Self.movedOn ? Self.hamburgAirport : Self.munichAirport
                let meters = GeoMath.distance(airport, destination.center)
                if (1_500_000...3_200_000).contains(meters) {
                    let gate = first.addingTimeInterval(4 * 3_600), metersPerSecond = 800_000.0 / 3_600, taxi = 1_800.0
                    members.append(MapFixture.photo(nextID(), at: gate, airport, trip: id))
                    for f in [0.35, 0.5, 0.65] {
                        let fact = MapFixture.photo(nextID(), at: gate.addingTimeInterval(taxi + f * meters / metersPerSecond),
                                                    Self.along(airport, destination.center, f), trip: id)
                        windowPhotos.insert(fact.id)
                        members.append(fact)
                    }
                    members.append(MapFixture.photo(nextID(), at: gate.addingTimeInterval(taxi + meters / metersPerSecond + 1_200),
                                                    destination.center, trip: id))
                }
            }
            for day in 0..<days {
                if roadTrip {
                    position = MapFixture.at(position.latitude + (random.unit() - 0.5) * 1.2, position.longitude + (random.unit() - 0.5) * 1.6)
                }
                let places = random.int(1..<4)
                for p in 0..<places {
                    let spot = MapFixture.at(position.latitude + (random.unit() - 0.5) * 0.6, position.longitude + (random.unit() - 0.5) * 0.8)
                    let town = "\(destination.name) \(tripIndex)-\(day)-\(p)"
                    let dayStart = first.addingTimeInterval(Double(day) * 86_400 + Double(9 + p * 4) * 3_600)
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
        let perDay = max(2, (count - facts.count) / max(1, free.count))
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
