import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyTestSupport

/// Photos taken in flight count for nothing (concept §5): by altitude, or by a fast straight run
/// between their neighbours; zig-zags on the ground (shared libraries, wrong locations) and fast
/// trains stay in.
@Suite("Airborne filter")
struct AirborneFilterTests {
    typealias Places = MapFixture.Places
    static let munichAirport = MapFixture.at(48.3538, 11.7861)
    static let lisbonAirport = MapFixture.at(38.7742, -9.1342)
    static let parisGareDeLyon = MapFixture.at(48.8443, 2.3744)
    static let lyonPartDieu = MapFixture.at(45.7606, 4.8594)
    /// Nadi airport, Fiji, and Faleolo airport, Samoa: the flight crosses the antimeridian.
    static let nadi = MapFixture.at(-17.7554, 177.4433)
    static let faleolo = MapFixture.at(-13.8300, -172.0083)

    static func shot(_ id: String, _ date: Date?, _ coordinate: GeoCoordinate?, subtypes: MediaSubtypes = []) -> AssetSnapshot {
        AssetSnapshot(id: AssetID(id), subtypes: subtypes, creationDate: date, location: coordinate)
    }

    /// The point `fraction` of the way from `a` to `b` on the great circle (right across the
    /// antimeridian).
    static func along(_ a: GeoCoordinate, _ b: GeoCoordinate, _ fraction: Double) -> GeoCoordinate {
        let u = TripGeometryBuilder.UnitVector(a), v = TripGeometryBuilder.UnitVector(b)
        let angle = u.angle(to: v)
        guard angle > 0 else { return a }
        let p = u.scaled(sin((1 - fraction) * angle) / sin(angle)) + v.scaled(sin(fraction * angle) / sin(angle))
        return p.coordinate!
    }

    /// A flight Munich → Lisbon: gate photos at Munich airport, window photos every 15 minutes
    /// (one a burst of three photos four seconds apart), photos at Lisbon airport and in the city.
    /// Takeoff 08:30, landing 11:00: about 1,990 km at 220 m/s.
    static func lisbonFlight() -> (photos: [AssetSnapshot], window: Set<AssetID>) {
        let takeoff = MapFixture.date("2023-06-14 08:30")
        func flying(_ id: String, _ minutes: Double) -> AssetSnapshot {
            shot(id, takeoff.addingTimeInterval(minutes * 60), along(munichAirport, lisbonAirport, minutes / 150))
        }
        let window = [flying("w-0855", 25), flying("w-0910", 40), flying("w-0925", 55), flying("w-0935a", 65), flying("w-0935b", 65 + 4.0 / 60),
                      flying("w-0935c", 65 + 8.0 / 60), flying("w-0950", 80), flying("w-1005", 95), flying("w-1020", 110), flying("w-1035", 125)]
        let ground = [
            shot("home-0630", MapFixture.date("2023-06-14 06:30"), Places.regensburg),
            shot("muc-0740", MapFixture.date("2023-06-14 07:40"), Fixture.jitter(munichAirport, seed: 1, meters: 500)),
            shot("muc-0800", MapFixture.date("2023-06-14 08:00"), Fixture.jitter(munichAirport, seed: 2, meters: 500)),
            shot("muc-0815", MapFixture.date("2023-06-14 08:15"), Fixture.jitter(munichAirport, seed: 3, meters: 500)),
            shot("lis-1110", MapFixture.date("2023-06-14 11:10"), Fixture.jitter(lisbonAirport, seed: 4, meters: 500)),
            shot("lis-1125", MapFixture.date("2023-06-14 11:25"), Fixture.jitter(lisbonAirport, seed: 5, meters: 500)),
            shot("lis-1140", MapFixture.date("2023-06-14 11:40"), Fixture.jitter(lisbonAirport, seed: 6, meters: 500)),
            shot("city-1230", MapFixture.date("2023-06-14 12:30"), Places.lisbon),
            shot("city-1300", MapFixture.date("2023-06-14 13:00"), Fixture.jitter(Places.lisbon, seed: 7, meters: 800)),
            shot("city-1400", MapFixture.date("2023-06-14 14:00"), Fixture.jitter(Places.lisbon, seed: 8, meters: 800)),
        ]
        return (window + ground, Set(window.map(\.id)))
    }

    @Test func windowPhotosOfAFlightAreAirborneAndTheAirportsAreNot() {
        let flight = Self.lisbonFlight()
        #expect(AirborneFilter.airborne(flight.photos) == flight.window)
        // The burst's photos lie within 3 km of each other: each reaches past them to the window
        // photos before and after the burst.
        #expect(flight.window.isSuperset(of: ["w-0935a", "w-0935b", "w-0935c"]))
    }

    @Test func photosWithoutLocationOrDateAndScreenshotsAreNotJudged() {
        let flight = Self.lisbonFlight()
        let midFlight = MapFixture.date("2023-06-14 09:40")
        let onTheWay = Self.along(Self.munichAirport, Self.lisbonAirport, 70.0 / 150)
        let extra = [
            Self.shot("no-location", midFlight, nil),
            Self.shot("no-date", nil, onTheWay),
            Self.shot("screenshot", midFlight, onTheWay, subtypes: .screenshot),
            Self.shot("broken-location", midFlight, MapFixture.at(0, 0)),
        ]
        // Not judged, and nobody's neighbour: the flight's result stays as it was.
        #expect(AirborneFilter.airborne(flight.photos + extra) == flight.window)
        // Nor are they flagged by an altitude.
        let altitudes = Dictionary(uniqueKeysWithValues: extra.map { ($0.id, 10_500.0) })
        #expect(AirborneFilter.airborne(extra, altitudes: altitudes).isEmpty)
    }

    @Test func inputOrderDoesNotMatter() {
        let flight = Self.lisbonFlight()
        let zigzag = Self.interleavedCities(start: "2023-06-15 09:00", count: 30, a: Places.munich, b: Places.rome)
        let photos = flight.photos + zigzag
        let expected = AirborneFilter.airborne(photos)
        #expect(expected == flight.window)
        var random = MapRandom(seed: 7)
        for _ in 0..<5 {
            var shuffled = photos
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, random.int(0..<(i + 1))) }
            #expect(AirborneFilter.airborne(shuffled) == expected)
        }
    }

    @Test func fastTrainsStayOnTheGround() {
        // Paris → Lyon (about 390 km) at 300 km/h, a photo every 4 minutes and a burst on the way;
        // and the same at 350 km/h, the fastest trains in service.
        for (speed, prefix) in [(300.0, "tgv300"), (350.0, "tgv350")] {
            let meters = GeoMath.distance(Self.parisGareDeLyon, Self.lyonPartDieu)
            let seconds = meters / (speed / 3.6)
            let start = MapFixture.date("2023-07-01 08:00")
            let times = Array(stride(from: 0.0, through: seconds, by: 240)) + [1_202, 1_204]
            let photos = times.map { t in
                Self.shot("\(prefix)-\(Int(t))", start.addingTimeInterval(t), Self.along(Self.parisGareDeLyon, Self.lyonPartDieu, t / seconds))
            }
            #expect(photos.count > 15)
            #expect(AirborneFilter.airborne(photos).isEmpty, "\(prefix)")
        }
    }

    /// Two people's photos from two cities, alternating every 10 minutes (an iCloud Shared Library).
    static func interleavedCities(start: String, count: Int, a: GeoCoordinate, b: GeoCoordinate, sameSecond: Bool = false) -> [AssetSnapshot] {
        let t0 = MapFixture.date(start)
        return (0..<count).map { i in
            let atA = i % 2 == 0
            let seconds = sameSecond ? Double(i / 2) * 600 : Double(i) * 600
            return shot("\(atA ? "a" : "b")-\(start)-\(i)", t0.addingTimeInterval(seconds), Fixture.jitter(atA ? a : b, seed: i, meters: 400))
        }
    }

    @Test func zigZagsOnTheGroundAreNotFlights() {
        // Munich and Rome interleaved (fast legs both ways, but no photo lies between its neighbours).
        #expect(AirborneFilter.airborne(Self.interleavedCities(start: "2023-06-15 09:00", count: 40, a: Places.munich, b: Places.rome)).isEmpty)
        // The same with both photos of a pair in the same second.
        #expect(AirborneFilter.airborne(Self.interleavedCities(start: "2023-06-16 09:00", count: 40, a: Places.munich, b: Places.rome,
                                                               sameSecond: true)).isEmpty)
        // Two cities close together (Munich and Augsburg, 55 km) alternating every minute.
        let augsburg = MapFixture.at(48.3705, 10.8978)
        let close = (0..<30).map { i in
            Self.shot("close-\(i)", MapFixture.date("2023-06-17 10:00").addingTimeInterval(Double(i) * 60), i % 2 == 0 ? Places.munich : augsburg)
        }
        #expect(AirborneFilter.airborne(close).isEmpty)
        // A day in Munich with one photo whose location says Rome.
        var day = (0..<20).map { i in
            Self.shot("day-\(i)", MapFixture.date("2023-06-18 09:00").addingTimeInterval(Double(i) * 900), Fixture.jitter(Places.munich, seed: i, meters: 2_000))
        }
        day[10].location = Places.rome
        #expect(AirborneFilter.airborne(day).isEmpty)
    }

    @Test func aPhotoOffTheWayIsNoFlight() {
        // Fast legs Munich → Zurich → Vienna: Zurich is no stop on the way from Munich to Vienna.
        let zurich = MapFixture.at(47.3769, 8.5417), vienna = MapFixture.at(48.2082, 16.3738), linz = MapFixture.at(48.3069, 14.2858)
        let t0 = MapFixture.date("2023-06-20 10:00")
        let detour = [Self.shot("d-0", t0, Places.munich), Self.shot("d-1", t0.addingTimeInterval(1_200), zurich),
                      Self.shot("d-2", t0.addingTimeInterval(2_400), vienna)]
        #expect(AirborneFilter.airborne(detour).isEmpty)
        // Linz lies on the way: the same times make it a photo in flight.
        let straight = [Self.shot("s-0", t0, Places.munich), Self.shot("s-1", t0.addingTimeInterval(1_200), linz),
                        Self.shot("s-2", t0.addingTimeInterval(2_400), vienna)]
        #expect(AirborneFilter.airborne(straight) == ["s-1"])
        // Neighbours more than two hours away say nothing about speed.
        let slow = [Self.shot("t-0", t0, Places.munich), Self.shot("t-1", t0.addingTimeInterval(1_200), linz),
                    Self.shot("t-2", t0.addingTimeInterval(1_200 + 2 * 3_600 + 1), vienna)]
        #expect(AirborneFilter.airborne(slow).isEmpty)
    }

    @Test func altitudeAboveSixThousandMetresIsAFlight() {
        // Slow photos on the ground, one with a cruising altitude, one on a mountain.
        let t0 = MapFixture.date("2023-08-01 10:00")
        let zugspitze = MapFixture.at(47.4211, 10.9853)
        let photos = (0..<6).map { i in Self.shot("alt-\(i)", t0.addingTimeInterval(Double(i) * 1_800), Fixture.jitter(zugspitze, seed: i, meters: 300)) }
        let altitudes: [AssetID: Double] = ["alt-0": 10_500, "alt-1": 2_900, "alt-2": 6_000, "alt-3": .nan, "alt-4": -400]
        #expect(AirborneFilter.airborne(photos, altitudes: altitudes) == ["alt-0"])
        #expect(AirborneFilter.airborne(photos).isEmpty)
    }

    @Test func aFlightAcrossTheAntimeridian() {
        // Nadi (Fiji) → Faleolo (Samoa), about 1,200 km in 1 h 50 min, window photos every 10
        // minutes on both sides of 180°.
        let takeoff = MapFixture.date("2023-09-10 22:00")
        #expect(abs(GeoMath.distance(Self.nadi, Self.faleolo) - 1_210_000) < 30_000)
        let window = stride(from: 20.0, through: 90.0, by: 10.0).map { minutes in
            Self.shot("pacific-\(Int(minutes))", takeoff.addingTimeInterval(minutes * 60), Self.along(Self.nadi, Self.faleolo, minutes / 110))
        }
        #expect(window.contains { $0.location!.longitude > 179 } && window.contains { $0.location!.longitude < -179 })
        let ground = [
            Self.shot("nadi-1", takeoff.addingTimeInterval(-20 * 60), Self.nadi),
            Self.shot("nadi-2", takeoff.addingTimeInterval(-5 * 60), Fixture.jitter(Self.nadi, seed: 1, meters: 300)),
            Self.shot("apia-1", takeoff.addingTimeInterval(120 * 60), Self.faleolo),
            Self.shot("apia-2", takeoff.addingTimeInterval(130 * 60), Fixture.jitter(Self.faleolo, seed: 2, meters: 300)),
        ]
        #expect(AirborneFilter.airborne(window + ground) == Set(window.map(\.id)))
    }

    // MARK: The grouped search is the rule, photo by photo

    /// The rule as the brief states it, photo by photo without groups: the reference.
    static func reference(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> Set<AssetID> {
        let judged = photos.filter { $0.usableLocation != nil && $0.creationDate != nil && !$0.isScreenshotLike }.sorted { a, b in
            (a.creationDate!, a.id.rawValue, a.location!.latitude, a.location!.longitude)
                < (b.creationDate!, b.id.rawValue, b.location!.latitude, b.location!.longitude)
        }
        func time(_ i: Int) -> TimeInterval { judged[i].creationDate!.timeIntervalSinceReferenceDate }
        func meters(_ i: Int, _ j: Int) -> Double { GeoMath.distance(judged[i].location!, judged[j].location!) }
        var result = Set<AssetID>()
        for i in judged.indices {
            if let altitude = altitudes[judged[i].id], altitude > AirborneFilter.maximumAltitude { result.insert(judged[i].id) }
            func neighbour(_ step: Int) -> Int? {
                var j = i + step
                while j >= 0 && j < judged.count && abs(time(j) - time(i)) <= AirborneFilter.maximumLegDuration {
                    if meters(i, j) >= AirborneFilter.minimumLegMeters { return j }
                    j += step
                }
                return nil
            }
            guard let before = neighbour(-1), let after = neighbour(1) else { continue }
            let speed = AirborneFilter.maximumGroundSpeed
            guard meters(before, i) > speed * (time(i) - time(before)), meters(i, after) > speed * (time(after) - time(i)) else { continue }
            if meters(before, i) + meters(i, after) <= AirborneFilter.detourFactor * meters(before, after) + AirborneFilter.detourAllowanceMeters {
                result.insert(judged[i].id)
            }
        }
        return result
    }

    /// A random wander: stays, bursts, walks, drives, flights and jumps, with distances around
    /// the leg length and the group radius, equal times and duplicates.
    static func wander(seed: UInt64, count: Int) -> [AssetSnapshot] {
        var random = MapRandom(seed: seed)
        var position = Places.munich
        var time = MapFixture.date("2023-01-01").timeIntervalSinceReferenceDate
        var photos: [AssetSnapshot] = []
        func move(_ meters: Double) {
            let bearing = random.unit() * 2 * .pi
            let dLat = meters * cos(bearing) / GeoMath.metersPerDegreeLatitude
            let dLon = meters * sin(bearing) / (GeoMath.metersPerDegreeLatitude * max(0.05, cos(position.latitude * .pi / 180)))
            var longitude = position.longitude + dLon
            if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
            position = GeoCoordinate(latitude: min(80, max(-80, position.latitude + dLat)), longitude: longitude)
        }
        while photos.count < count {
            switch random.int(0..<10) {
            case 0, 1: move(random.unit() * 900); time += random.unit() * 30
            case 2, 3: move(1_500 + random.unit() * 3_000); time += random.unit() * 120
            case 4: move(random.unit() * 200)
            case 5: move(20_000 + random.unit() * 300_000); time += 300 + random.unit() * 3_000
            case 6: move(random.unit() * 1_500_000); time += random.unit() * 9_000
            case 7: time += random.unit() * 4 * 3_600
            default: move(random.unit() * 5_000); time += random.unit() * 1_200
            }
            photos.append(shot("r\(seed)-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), position))
            if random.int(0..<50) == 0 { photos.append(photos[photos.count - 1]) }
        }
        return photos
    }

    @Test(arguments: [1, 2, 3, 4] as [UInt64]) func groupedSearchGivesThePhotoByPhotoResult(seed: UInt64) {
        let photos = Self.wander(seed: seed, count: 3_000)
        let altitudes = Dictionary(photos.enumerated().filter { $0.offset % 97 == 0 }.map { ($0.element.id, Double($0.offset % 3) * 4_000) },
                                   uniquingKeysWith: { a, _ in a })
        let expected = Self.reference(photos, altitudes: altitudes)
        #expect(AirborneFilter.airborne(photos, altitudes: altitudes) == expected)
        #expect(!expected.isEmpty)
    }

    // MARK: Speed

    /// 50,000 photos over ten years: everyday life with long bursts (a wedding of 1,500 photos in
    /// two hours), walks, drives, and flights to trips.
    static func library(count: Int) -> [AssetSnapshot] {
        var random = MapRandom(seed: 50_000)
        var photos: [AssetSnapshot] = []
        photos.reserveCapacity(count + 2_000)
        var time = MapFixture.date("2016-01-01 08:00").timeIntervalSinceReferenceDate
        let destinations = [Places.lisbon, Places.rome, Places.reykjavik, Places.tokyo, Places.auckland, Places.suva, Places.apia, Places.honolulu,
                            Places.longyearbyen, Places.ushuaia, Places.florence, Places.porto]
        func add(_ coordinate: GeoCoordinate) {
            photos.append(shot("lib-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), coordinate))
        }
        var session = 0
        while photos.count < count {
            session += 1
            if session % 40 == 0 {
                // A trip: a flight there with window photos, days of walking, a flight back.
                let destination = destinations[random.int(0..<destinations.count)]
                for k in 1...12 { time += 600; add(AirborneFilterTests.along(Places.munich, destination, Double(k) / 13)) }
                for _ in 0..<(80 + random.int(0..<200)) { time += 60 + random.unit() * 1_200; add(Fixture.jitter(destination, seed: photos.count, meters: 6_000)) }
                for k in 1...12 { time += 600; add(AirborneFilterTests.along(destination, Places.munich, Double(k) / 13)) }
            } else if session % 97 == 0 {
                for _ in 0..<1_500 { time += 4.8; add(Fixture.jitter(Places.regensburg, seed: photos.count, meters: 300)) }
            } else {
                for _ in 0..<(5 + random.int(0..<60)) { time += 5 + random.unit() * 600; add(Fixture.jitter(Places.regensburg, seed: photos.count, meters: 5_000)) }
            }
            time += 3_600 * (2 + random.unit() * 40)
        }
        return Array(photos.prefix(count))
    }

    @Test func fiftyThousandPhotosAreJudgedQuickly() {
        let photos = Self.library(count: 50_000)
        let clock = ContinuousClock()
        var result = Set<AssetID>()
        let elapsed = clock.measure { result = AirborneFilter.airborne(photos) }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "AIRBORNE_PERF photos 50000: %.1f ms, %d in flight", ms, result.count))
        #expect(!result.isEmpty)
        // A debug build on a shared machine is several times slower than the app; the bound only
        // catches a search that reads every photo of a burst for every photo of it.
        #expect(ms < 2_000)
    }
}
