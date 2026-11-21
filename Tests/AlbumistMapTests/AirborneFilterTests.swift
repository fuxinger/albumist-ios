import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Photos taken in flight count for nothing (concept §5): by altitude, by fast straight runs, by
/// series at a plane's speed and as the ends of runs. Photos on the ground never: airports,
/// layovers, two people's photos in one library, wrong locations, trains, cars, a location
/// jumping indoors. Flights are built as people photograph them (`Flight`: a real climb and
/// descent, gate photos half an hour and more before take-off).
@Suite("Airborne filter")
struct AirborneFilterTests {
    typealias Places = MapFixture.Places
    static let munichAirport = MapFixture.at(48.3538, 11.7861)
    static let frankfurtAirport = MapFixture.at(50.0379, 8.5622)
    static let lisbonAirport = MapFixture.at(38.7742, -9.1342)
    static let romeAirport = MapFixture.at(41.8003, 12.2389)
    static let naritaAirport = MapFixture.at(35.7720, 140.3929)
    static let hanedaAirport = MapFixture.at(35.5494, 139.7798)
    static let honoluluAirport = MapFixture.at(21.3187, -157.9225)
    static let aucklandAirport = MapFixture.at(-37.0082, 174.7850)
    static let losAngelesAirport = MapFixture.at(33.9416, -118.4085)
    static let sanFranciscoAirport = MapFixture.at(37.6213, -122.3790)
    static let dubaiAirport = MapFixture.at(25.2532, 55.3657)
    static let bangkokAirport = MapFixture.at(13.6900, 100.7501)
    static let buenosAiresAirport = MapFixture.at(-34.8222, -58.5358)
    static let parisGareDeLyon = MapFixture.at(48.8443, 2.3744)
    static let lyonPartDieu = MapFixture.at(45.7606, 4.8594)
    static let nuremberg = MapFixture.at(49.4521, 11.0767)
    /// Nadi airport, Fiji, and Faleolo airport, Samoa: the flight crosses the antimeridian.
    static let nadi = MapFixture.at(-17.7554, 177.4433)
    static let faleolo = MapFixture.at(-13.8300, -172.0083)

    static func shot(_ id: String, _ date: Date?, _ coordinate: GeoCoordinate?, accuracy: Double? = nil,
                     subtypes: MediaSubtypes = []) -> AssetSnapshot {
        AssetSnapshot(id: AssetID(id), subtypes: subtypes, creationDate: date, location: coordinate, locationAccuracy: accuracy)
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

    /// The point `km` kilometres from `c` towards `bearing` (degrees clockwise from north).
    static func offset(_ c: GeoCoordinate, km: Double, bearing: Double) -> GeoCoordinate {
        let d = km * 1_000 / GeoMath.earthRadiusMeters, b = bearing * .pi / 180
        let lat1 = c.latitude * .pi / 180, lon1 = c.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        var longitude = (lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))) * 180 / .pi
        if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        return MapFixture.at(lat2 * 180 / .pi, longitude)
    }

    static func minutes(_ date: Date, _ minutes: Double) -> Date { date.addingTimeInterval(minutes * 60) }

    // MARK: Flights as people photograph them

    /// The photos of one flight, and which of them are taken in the air.
    struct Journey {
        var photos: [AssetSnapshot] = []
        var window: Set<AssetID> = []
        var ground: Set<AssetID> = []
        var path: Flight
        var windowPhotos: [AssetSnapshot] { photos.filter { window.contains($0.id) } }
    }

    /// Gate photos `gate` minutes before take-off (within 300 m of the origin airport), window
    /// photos at the minutes after take-off `window` gives for the flight's minutes, arrival
    /// photos `arrival` minutes after landing.
    static func flight(_ name: String, from: GeoCoordinate, to: GeoCoordinate, takeoff: Date, cruiseKmh: Double = 850,
                       gate: [Double] = [40], arrival: [Double] = [25], window: (Double) -> [Double]) -> Journey {
        let path = Flight(from: from, to: to, takeoff: takeoff, cruiseKmh: cruiseKmh)
        var journey = Journey(path: path)
        for (k, before) in gate.enumerated() {
            let photo = shot("\(name)-gate-\(k)", minutes(takeoff, -before), Fixture.jitter(from, seed: k + 1, meters: 600))
            journey.photos.append(photo)
            journey.ground.insert(photo.id)
        }
        for (k, after) in window(path.minutes).enumerated() {
            let photo = shot("\(name)-w-\(k)", path.date(minutes: after), path.position(minutes: after))
            journey.photos.append(photo)
            journey.window.insert(photo.id)
        }
        for (k, after) in arrival.enumerated() {
            let photo = shot("\(name)-arr-\(k)", minutes(path.landing, after), Fixture.jitter(to, seed: k + 11, meters: 600))
            journey.photos.append(photo)
            journey.ground.insert(photo.id)
        }
        return journey
    }

    /// Every `step` minutes from `first` minutes after take-off to `last` minutes before landing
    /// (`total` minutes after take-off), that one included: no two more than `step` apart.
    static func every(_ step: Double, of total: Double, first: Double = 10, last: Double = 10) -> [Double] {
        Array(stride(from: first, to: total - last, by: step)) + [total - last]
    }

    /// `count` photos `seconds` apart from `minutes` on.
    static func series(at minutes: Double, count: Int, seconds: Double) -> [Double] {
        (0..<count).map { minutes + Double($0) * seconds / 60 }
    }

    /// Munich → Lisbon: a photo at home, gate photos 75, 55 and 40 minutes before take-off, window
    /// photos every 10 minutes from 10 minutes after take-off to 10 before landing and a series of
    /// three four seconds apart, photos at Lisbon airport 20 and 35 minutes after landing and in
    /// the city.
    static func lisbonFlight() -> (photos: [AssetSnapshot], window: Set<AssetID>) {
        let takeoff = MapFixture.date("2023-06-14 08:30")
        let journey = flight("lis", from: munichAirport, to: lisbonAirport, takeoff: takeoff, gate: [75, 55, 40], arrival: [20, 35]) { total in
            every(10, of: total) + series(at: 65, count: 3, seconds: 4)
        }
        let ground = [
            shot("home-0630", MapFixture.date("2023-06-14 06:30"), Places.regensburg),
            shot("city-1300", MapFixture.date("2023-06-14 13:00"), Places.lisbon),
            shot("city-1330", MapFixture.date("2023-06-14 13:30"), Fixture.jitter(Places.lisbon, seed: 7, meters: 800)),
            shot("city-1430", MapFixture.date("2023-06-14 14:30"), Fixture.jitter(Places.lisbon, seed: 8, meters: 800)),
        ]
        return (journey.photos + ground, journey.window)
    }

    @Test func windowPhotosOfAFlightAreAirborneAndTheAirportsAreNot() {
        let flight = Self.lisbonFlight()
        #expect(flight.window.count == 18)
        #expect(AirborneFilter.airborne(flight.photos) == flight.window)
    }

    /// Finding 1: with the gate photo 30 to 45 minutes before take-off and a window photo every 10
    /// minutes, the first and the last window photo of every flight were missed.
    @Test(arguments: ["rome", "lisbon", "tokyo"])
    func theFirstAndLastWindowPhotosAreFound(route: String) {
        let (from, to, gate, cruise): (GeoCoordinate, GeoCoordinate, Double, Double) = switch route {
        case "rome": (Self.munichAirport, Self.romeAirport, 30, 800)
        case "lisbon": (Self.munichAirport, Self.lisbonAirport, 40, 850)
        default: (Self.frankfurtAirport, Self.naritaAirport, 45, 880)
        }
        let takeoff = MapFixture.date("2024-03-02 09:00")
        let journey = Self.flight(route, from: from, to: to, takeoff: takeoff, cruiseKmh: cruise, gate: [gate + 30, gate], arrival: [25, 40]) {
            Self.every(10, of: $0)
        }
        let home = Self.shot("\(route)-home", Self.minutes(takeoff, -gate - 150), Places.regensburg)
        let city = (0..<3).map { k in
            Self.shot("\(route)-city-\(k)", Self.minutes(journey.path.landing, 120 + Double(k) * 20), Fixture.jitter(to, seed: k, meters: 9_000))
        }
        let airborne = AirborneFilter.airborne(journey.photos + [home] + city)
        #expect(journey.window.count >= (route == "tokyo" ? 60 : route == "lisbon" ? 14 : 6))
        #expect(airborne == journey.window, "\(route): missed \(journey.window.subtracting(airborne).count), on the ground \(airborne.subtracting(journey.window))")
    }

    /// Munich → Lisbon at 830 km/h: window photos over France `windowAt` seconds after 09:15 (by
    /// default three, four seconds apart), each at the fix `fix` gives for its seconds (by default
    /// where the plane is then), the trip's first photos (or a gate photo `gateSecondsBefore`
    /// them), the arrival photo 25 minutes after landing, four days in Lisbon; everyday photos at
    /// home until three days before. No altitudes.
    static func lisbonLibrary(gateSecondsBefore: TimeInterval?, windowAt seconds: [Double] = [0, 4, 8],
                              fix: (Double) -> Double = { $0 }) -> MapInput {
        let trip = AlbumistID("lisbon"), overFrance = MapFixture.date("2024-04-02 09:15")
        let speed = 830_000.0 / 3_600, way = GeoMath.distance(munichAirport, lisbonAirport)
        var photos: [AssetFacts] = []
        if let gate = gateSecondsBefore {
            photos.append(MapFixture.photo("gate", at: overFrance.addingTimeInterval(-gate), munichAirport, country: "DE", town: "Freising",
                                           timeZone: "Europe/Berlin"))
        }
        for (k, s) in seconds.enumerated() {
            photos.append(MapFixture.photo("window-\(k)", at: overFrance.addingTimeInterval(s),
                                           along(munichAirport, lisbonAirport, 0.4 + fix(s) * speed / way), country: "FR", town: "Wolken",
                                           timeZone: "Europe/Paris"))
        }
        photos.append(MapFixture.photo("landing", at: overFrance.addingTimeInterval(0.6 * way / speed + 1_500), lisbonAirport, country: "PT",
                                       town: "Lissabon", timeZone: "Europe/Lisbon"))
        for day in 3...6 {
            photos += MapFixture.burst("lis-\(day)", count: 8, at: Places.lisbon, day: "2024-04-0\(day)", country: "PT", town: "Lissabon",
                                       timeZone: "Europe/Lisbon")
        }
        let members = MapFixture.members(photos, of: trip)
        let everyday = MapFixture.everyday("home", from: "2024-01-01", to: "2024-03-30", at: Places.regensburg, country: "DE", everyNthDay: 3)
        return MapInput(facts: everyday + members, trips: [MapFixture.trip(trip, members)],
                        detectedHome: DetectedHome(center: Places.regensburg, since: nil, photoDays: 400), calendar: MapFixture.calendar,
                        now: MapFixture.date("2024-07-01"))
    }

    /// Finding 1: one photo every 2.5 hours on a long-haul flight.
    @Test func aLongHaulFlightWithAPhotoEveryTwoAndAHalfHoursIsFound() {
        // Frankfurt → Buenos Aires, 11,500 km in 13 hours: photos 2.5, 5, 7.5, 10 and 12.5 hours
        // after take-off, the last 48 minutes before landing.
        let eze = Self.flight("eze", from: Self.frankfurtAirport, to: Self.buenosAiresAirport, takeoff: MapFixture.date("2024-02-10 21:00"),
                              cruiseKmh: 880) { Array(stride(from: 150.0, through: $0 - 10, by: 150)) }
        #expect(eze.window.count == 5)
        #expect(AirborneFilter.airborne(eze.photos) == eze.window)
        // Dubai → Los Angeles, 13,400 km: the same, but the last photo 27 minutes before landing.
        // Rule 4 needs the window photo before it within 15 minutes, and its leg to the arrival
        // photo is slow: missed, as documented.
        let lax = Self.flight("dxb-lax", from: Self.dubaiAirport, to: Self.losAngelesAirport, takeoff: MapFixture.date("2024-02-12 03:00"),
                              cruiseKmh: 880) { Array(stride(from: 150.0, through: $0 - 10, by: 150)) }
        let photos = lax.windowPhotos.sorted { $0.creationDate! < $1.creationDate! }
        #expect(photos.count == 6)
        #expect(lax.path.landing.timeIntervalSince(photos.last!.creationDate!) < 30 * 60)
        #expect(AirborneFilter.airborne(lax.photos) == lax.window.subtracting([photos.last!.id]))
    }

    @Test func flightsAcrossTheDateLineAreFound() {
        // Tokyo Haneda → Honolulu and Auckland → Los Angeles, a window photo every 15 minutes.
        for (name, from, to) in [("hnd-hnl", Self.hanedaAirport, Self.honoluluAirport), ("akl-lax", Self.aucklandAirport, Self.losAngelesAirport)] {
            let journey = Self.flight(name, from: from, to: to, takeoff: MapFixture.date("2024-05-20 10:00"), cruiseKmh: 880, gate: [55, 35],
                                      arrival: [25, 45]) { Self.every(15, of: $0) }
            let longitudes = journey.windowPhotos.map { $0.location!.longitude }
            #expect(longitudes.contains { $0 > 170 } && longitudes.contains { $0 < -170 }, "\(name)")
            #expect(AirborneFilter.airborne(journey.photos) == journey.window, "\(name)")
        }
    }

    @Test func aFlightOverThePoleIsFound() {
        // Dubai → San Francisco, 13,000 km over the Arctic: a window photo every 15 minutes.
        let journey = Self.flight("dxb-sfo", from: Self.dubaiAirport, to: Self.sanFranciscoAirport, takeoff: MapFixture.date("2024-07-01 02:00"),
                                  cruiseKmh: 880, gate: [60, 40], arrival: [30]) { Self.every(15, of: $0) }
        #expect(journey.windowPhotos.contains { $0.location!.latitude > 85 })
        #expect(AirborneFilter.airborne(journey.photos) == journey.window)
    }

    @Test func aFlightAcrossTheAntimeridian() {
        // Nadi (Fiji) → Faleolo (Samoa), about 1,200 km: window photos every 10 minutes on both
        // sides of 180°.
        #expect(abs(GeoMath.distance(Self.nadi, Self.faleolo) - 1_210_000) < 30_000)
        let journey = Self.flight("pacific", from: Self.nadi, to: Self.faleolo, takeoff: MapFixture.date("2023-09-10 22:00"), cruiseKmh: 800,
                                  gate: [40, 30], arrival: [20, 30]) { Self.every(10, of: $0) }
        let longitudes = journey.windowPhotos.map { $0.location!.longitude }
        #expect(longitudes.contains { $0 > 179 } && longitudes.contains { $0 < -179 })
        #expect(AirborneFilter.airborne(journey.photos) == journey.window)
    }

    @Test func photosWithoutLocationOrDateAndScreenshotsAreNotJudged() {
        let flight = Self.lisbonFlight()
        let midFlight = MapFixture.date("2023-06-14 09:40")
        let onTheWay = Self.along(Self.munichAirport, Self.lisbonAirport, 0.45)
        let extra = [
            Self.shot("no-location", midFlight, nil),
            Self.shot("no-date", nil, onTheWay),
            Self.shot("screenshot", midFlight, onTheWay, subtypes: .screenshot),
            Self.shot("broken-location", midFlight, MapFixture.at(0, 0)),
            Self.shot("coarse-location", midFlight, onTheWay, accuracy: 6_000),
        ]
        // Not judged, and nobody's neighbour: the flight's result stays as it was.
        #expect(AirborneFilter.airborne(flight.photos + extra) == flight.window)
        // Nor are they flagged by an altitude.
        let altitudes = Dictionary(uniqueKeysWithValues: extra.map { ($0.id, 10_500.0) })
        #expect(AirborneFilter.airborne(extra, altitudes: altitudes).isEmpty)
    }

    @Test func inputOrderDoesNotMatter() {
        let flight = Self.lisbonFlight()
        let zigzag = Self.alternating(start: "2023-06-15 09:00", count: 30, a: Places.munich, b: Places.rome, minutes: 10)
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
}
