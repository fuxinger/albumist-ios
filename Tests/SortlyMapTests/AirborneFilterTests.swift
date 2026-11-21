import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyTestSupport

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

    /// Finding 1: a gate photo in Frankfurt, five hours later four window photos three seconds
    /// apart over Russia, then Tokyo. Unfiltered they make Russia a country, a place "Wolke" and
    /// the northernmost place.
    @Test func aSeriesOverSiberiaFiveHoursAfterTheGatePhotoIsFound() throws {
        let trip = SortlyID("tokyo")
        let takeoff = MapFixture.date("2024-10-05 12:40")
        let path = Flight(from: Self.frankfurtAirport, to: Self.naritaAirport, takeoff: takeoff, cruiseKmh: 880)
        var facts = [MapFixture.photo("gate", at: Self.minutes(takeoff, -40), Self.frankfurtAirport, country: "DE", town: "Frankfurt am Main",
                                      timeZone: "Europe/Berlin", trip: trip)]
        let window = Self.series(at: 260, count: 4, seconds: 3).enumerated().map { k, minutes in
            MapFixture.photo("cloud-\(k)", at: path.date(minutes: minutes), path.position(minutes: minutes), country: "RU", town: "Wolke",
                             timeZone: "Asia/Yekaterinburg", trip: trip)
        }
        facts += window
        facts.append(MapFixture.photo("narita", at: Self.minutes(path.landing, 30), Self.naritaAirport, country: "JP", town: "Narita",
                                      timeZone: "Asia/Tokyo", trip: trip))
        for day in 6...9 {
            facts += MapFixture.members(MapFixture.burst("tokyo-\(day)", count: 8, at: Places.tokyo, day: "2024-10-0\(day)", hour: 2, country: "JP",
                                                         town: "Tokio", timeZone: "Asia/Tokyo"), of: trip)
        }
        let all = MapFixture.everyday("home", from: "2024-09-01", to: "2024-10-04", at: Places.regensburg, country: "DE") + facts
        #expect(window.allSatisfy { $0.asset.location!.latitude > 55 && $0.asset.location!.longitude > 45 })

        #expect(AirborneFilter.airborne(all.map(\.asset)) == Set(window.map(\.id)))
        let summary = MapSummary.build(MapInput(facts: all, trips: [MapFixture.trip(trip, facts)],
                                                detectedHome: DetectedHome(center: Places.regensburg, since: nil, photoDays: 30),
                                                calendar: MapFixture.calendar, now: MapFixture.date("2024-11-01")))
        #expect(summary.countries.map(\.code).sorted() == ["DE", "JP"])
        #expect(!summary.trips.contains { $0.geometry.places.contains { $0.name == "Wolke" } })
        let north = try #require(summary.numbers.record(.northernmost))
        #expect(north.coordinate.latitude < 40)
        // Without the filter Russia would count (four photos, three are enough).
        #expect(MapCountries.compute(facts: all, airborne: [], tripStarts: [:]).contains { $0.code == "RU" })
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

    /// Rule 3: a short flight whose only window photos are one series, both legs to the airports
    /// slow (gate 40 minutes before take-off, arrival 40 minutes after landing).
    @Test func aSeriesWithoutAFlownLegIsFound() {
        let takeoff = MapFixture.date("2024-06-01 07:00")
        for count in [4, 3] {
            let journey = Self.flight("fco-\(count)", from: Self.munichAirport, to: Self.romeAirport, takeoff: takeoff, cruiseKmh: 800,
                                      arrival: [40]) { _ in Self.series(at: 30, count: count, seconds: 3) }
            let airborne = AirborneFilter.airborne(journey.photos)
            // Four photos make a series; three do not (documented: the altitude will find them).
            #expect(airborne == (count == 4 ? journey.window : []), "\(count)")
        }
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
        let trip = SortlyID("bangkok")
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

    // MARK: Two people, wrong locations, trains, cars and jumping fixes stay on the ground

    /// Photos alternating between two places every `minutes` (an iCloud Shared Library).
    static func alternating(start: String, count: Int, a: GeoCoordinate, b: GeoCoordinate, minutes: Double, series: Int = 1) -> [AssetSnapshot] {
        let t0 = MapFixture.date(start)
        var photos: [AssetSnapshot] = []
        for i in 0..<count {
            for s in 0..<series {
                let at = t0.addingTimeInterval(Double(i) * minutes * 60 + Double(s) * 2)
                photos.append(shot("\(start)-\(minutes)-\(i)-\(s)", at, Fixture.jitter(i % 2 == 0 ? a : b, seed: i * 7 + s, meters: 400)))
            }
        }
        return photos
    }

    @Test func twoPeoplesPhotosInOneLibraryStayOnTheGround() {
        var photos: [AssetSnapshot] = []
        var day = 0
        for km in [30.0, 80, 150, 300] {
            let other = Self.offset(Places.regensburg, km: km, bearing: 200)
            for minutes in [2.0, 5, 10, 20, 30] {
                day += 1
                let start = String(format: "2024-05-%02d 08:00", day)
                photos += Self.alternating(start: start, count: 16, a: Places.regensburg, b: other, minutes: minutes)
                // Series of three to five photos each, and a third person driving from one to the
                // other at 130 km/h with a photo every four minutes.
                photos += Self.alternating(start: String(format: "2024-05-%02d 14:00", day), count: 12, a: Places.regensburg, b: other,
                                           minutes: minutes, series: 3 + day % 3)
                let drive = km / 130 * 60
                photos += stride(from: 0.0, through: drive, by: 4).map { m in
                    Self.shot("drive-\(day)-\(m)", Self.minutes(MapFixture.date(String(format: "2024-05-%02d 14:00", day)), m),
                              Self.along(Places.regensburg, other, m / drive))
                }
            }
        }
        #expect(AirborneFilter.airborne(photos).isEmpty)
    }

    /// Finding 10: Munich, Florence and Rome lie on a line.
    @Test func munichFlorenceAndRomeStayOnTheGround() {
        let t0 = MapFixture.date("2024-06-01 09:00")
        // Three people's photos in the same minutes.
        var same: [AssetSnapshot] = []
        for k in 0..<40 { same.append(Self.shot("m-\(k)", Self.minutes(t0, Double(k) * 3), Fixture.jitter(Places.munich, seed: k, meters: 800))) }
        for k in 0..<30 { same.append(Self.shot("f-\(k)", Self.minutes(t0, Double(k) * 4 + 0.5), Fixture.jitter(Places.florence, seed: k, meters: 800))) }
        for k in 0..<24 { same.append(Self.shot("r-\(k)", Self.minutes(t0, Double(k) * 5 + 0.8), Fixture.jitter(Places.rome, seed: k, meters: 800))) }
        #expect(AirborneFilter.airborne(same).isEmpty)
        // One after another, round and round every 20 to 35 minutes: Florence lies on the way from
        // Munich to Rome, but then the "flight" turns back to Munich.
        for minutes in [20.0, 25, 30, 35] {
            let cities = [Places.munich, Places.florence, Places.rome]
            let round = (0..<18).map { k in
                Self.shot("round-\(minutes)-\(k)", Self.minutes(t0, Double(k) * minutes), Fixture.jitter(cities[k % 3], seed: k, meters: 800))
            }
            #expect(AirborneFilter.airborne(round).isEmpty, "\(minutes)")
        }
        // The same with several photos at Munich and at Rome each time.
        var stays: [AssetSnapshot] = []
        var time = t0
        for k in 0..<18 {
            let count = k % 3 == 1 ? 1 : 3
            for s in 0..<count {
                stays.append(Self.shot("stay-\(k)-\(s)", time.addingTimeInterval(Double(s) * 180), Fixture.jitter([Places.munich, Places.florence, Places.rome][k % 3], seed: s, meters: 800)))
            }
            time = Self.minutes(time, 25 + Double(count - 1) * 3)
        }
        #expect(AirborneFilter.airborne(stays).isEmpty)
    }

    /// The limit of finding 10 (documented): once, and never back, a single photo at Florence
    /// half an hour after Munich and half an hour before Rome is just what a window photo over
    /// Florence on a flight from Munich to Rome looks like.
    @Test func aSinglePhotoOnTheWayFromMunichToRomeOnceLooksLikeAFlight() {
        let t0 = MapFixture.date("2024-06-01 09:00")
        let photos = (0..<3).map { Self.shot("m-\($0)", Self.minutes(t0, Double($0) * 3), Fixture.jitter(Places.munich, seed: $0, meters: 500)) }
            + [Self.shot("f", Self.minutes(t0, 36), Places.florence)]
            + (0..<3).map { Self.shot("r-\($0)", Self.minutes(t0, 66 + Double($0) * 3), Fixture.jitter(Places.rome, seed: $0, meters: 500)) }
        #expect(AirborneFilter.airborne(photos) == ["f"])
        // Two photos at Florence a minute apart are a stay.
        let two = photos + [Self.shot("f-2", Self.minutes(t0, 37), Fixture.jitter(Places.florence, seed: 9, meters: 300))]
        #expect(AirborneFilter.airborne(two).isEmpty)
    }

    @Test func aWrongLocationComesBack() {
        // A day in Munich with a photo every 15 minutes, and wrong locations: Rome, 40 km, 8 km, and
        // two in a row 60 km away.
        func day(_ name: String, wrong: [Int: GeoCoordinate]) -> [AssetSnapshot] {
            (0..<24).map { i in
                Self.shot("\(name)-\(i)", Self.minutes(MapFixture.date("2023-06-18 08:00"), Double(i) * 15),
                          wrong[i] ?? Fixture.jitter(Places.munich, seed: i, meters: 2_000))
            }
        }
        let far = Self.offset(Places.munich, km: 60, bearing: 90)
        for wrong in [[10: Places.rome], [10: Self.offset(Places.munich, km: 40, bearing: 300)], [10: Self.offset(Places.munich, km: 8, bearing: 10)],
                      [10: far, 11: Self.offset(far, km: 1, bearing: 0)]] {
            #expect(AirborneFilter.airborne(day("wrong", wrong: wrong)).isEmpty, "\(wrong)")
        }
        // A wrong location 30 km away a minute after a photo, in a burst: one fast leg, no run.
        var burst = (0..<10).map { i in Self.shot("b-\(i)", MapFixture.date("2023-06-19 12:00").addingTimeInterval(Double(i) * 20),
                                                  Fixture.jitter(Places.munich, seed: i, meters: 300)) }
        burst[5].location = Self.offset(Places.munich, km: 30, bearing: 45)
        #expect(AirborneFilter.airborne(burst).isEmpty)
    }

    /// Photos on a train from Paris to Lyon at `kmh`, one every 1 to 10 minutes and two series of
    /// six photos one and two seconds apart, each within 25 m of the train.
    static func train(_ kmh: Double) -> [AssetSnapshot] {
        let meters = GeoMath.distance(parisGareDeLyon, lyonPartDieu), seconds = meters / (kmh / 3.6)
        let start = MapFixture.date("2023-07-01 08:00")
        var times: [Double] = []
        var t = 0.0, k = 0
        while t <= seconds {
            times.append(t)
            k += 1
            t += Double(1 + k * 7 % 10) * 60
        }
        for s in 0..<6 {
            times.append(600 + Double(s))
            times.append(1_500 + Double(s) * 2)
        }
        return times.enumerated().map { i, t in
            shot("tgv\(Int(kmh))-\(i)", start.addingTimeInterval(t), Fixture.jitter(along(parisGareDeLyon, lyonPartDieu, t / seconds), seed: i, meters: 50))
        }
    }

    @Test func fastTrainsStayOnTheGround() {
        for kmh in [300.0, 320, 350] {
            let photos = Self.train(kmh)
            #expect(photos.count >= 24)
            #expect(AirborneFilter.airborne(photos).isEmpty, "\(kmh)")
        }
    }

    @Test func aCarOnTheAutobahnStaysOnTheGround() {
        // Munich → Nuremberg at 200 km/h, a photo every 1 to 5 minutes and a series of five.
        let meters = GeoMath.distance(Places.munich, Self.nuremberg), seconds = meters / (200 / 3.6)
        let start = MapFixture.date("2023-07-02 10:00")
        let times = Array(stride(from: 0.0, through: seconds, by: 75)) + (0..<5).map { 1_000 + Double($0) }
        let photos = times.enumerated().map { i, t in
            Self.shot("car-\(i)", start.addingTimeInterval(t), Fixture.jitter(Self.along(Places.munich, Self.nuremberg, t / seconds), seed: i, meters: 60))
        }
        #expect(AirborneFilter.airborne(photos).isEmpty)
    }

    @Test func aLocationJumpingKilometresIndoorsStaysOnTheGround() {
        #expect(AirborneFilter.airborne(Self.jumpingIndoors()).isEmpty)

        // A minute of photos near one spot, a jump 3 km on and another 3 km on in a straight line
        // within seconds, a minute of photos near the far end: two legs at a plane's speed, but
        // from and to a stay.
        let a = MapFixture.at(48.2000, 11.6000), c = Self.offset(a, km: 3.1, bearing: 90), e = Self.offset(c, km: 3.1, bearing: 90)
        let t0 = MapFixture.date("2024-02-03 10:00")
        var line = (0..<8).map { Self.shot("a-\($0)", t0.addingTimeInterval(Double($0) * 10), Fixture.jitter(Self.offset(a, km: 1.2, bearing: 270), seed: $0, meters: 300)) }
        line += [Self.shot("a", t0.addingTimeInterval(80), a), Self.shot("c", t0.addingTimeInterval(90), c), Self.shot("e", t0.addingTimeInterval(100), e)]
        line += (0..<8).map { Self.shot("e-\($0)", t0.addingTimeInterval(110 + Double($0) * 10), Fixture.jitter(Self.offset(e, km: 1.2, bearing: 90), seed: $0, meters: 300)) }
        #expect(AirborneFilter.airborne(line).isEmpty)
        // Documented: the same three photos alone, without a photo near either end, are just what
        // three window photos ten seconds apart look like.
        #expect(AirborneFilter.airborne(Array(line[8..<11])) == ["a", "c", "e"])
    }

    /// An evening indoors whose location jumps between three spots 1.5 to 2.5 km apart, then one
    /// whose location lands 1 to 3 km off in any direction, every few seconds.
    static func jumpingIndoors() -> [AssetSnapshot] {
        var random = MapRandom(seed: 11)
        let hall = MapFixture.at(48.1500, 11.5500)
        // Three spots 1.5 to 2.5 km apart, a photo every 2 to 20 seconds for two hours.
        let spots = [hall, Self.offset(hall, km: 2.4, bearing: 0), Self.offset(hall, km: 1.6, bearing: 120)]
        var time = MapFixture.date("2024-02-02 18:00").timeIntervalSinceReferenceDate
        var photos: [AssetSnapshot] = []
        while photos.count < 900 {
            time += 2 + random.unit() * 18
            photos.append(Self.shot("spots-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), Fixture.jitter(spots[random.int(0..<3)], seed: photos.count, meters: 200)))
        }
        // Evenings whose location lands 1 to 3 km off in any direction, a photo every 2 to 30
        // (on the last evening 2 to 60) seconds, with photos before and after at home 15 km away.
        // Without `returnDuration` one photo in some 400 of these looked like a flight.
        for evening in 0..<6 {
            let home = Self.offset(hall, km: 15, bearing: 250)
            time += 20 * 3_600
            photos.append(Self.shot("home-before-\(evening)", Date(timeIntervalSinceReferenceDate: time), home))
            time += 3_600
            for k in 0..<1_000 {
                time += 2 + random.unit() * (evening == 5 ? 58 : 28)
                photos.append(Self.shot("jitter-\(evening)-\(k)", Date(timeIntervalSinceReferenceDate: time),
                                        Self.offset(hall, km: 1 + random.unit() * 2, bearing: random.unit() * 360)))
            }
            time += 3_600
            photos.append(Self.shot("home-after-\(evening)", Date(timeIntervalSinceReferenceDate: time), home))
        }
        return photos
    }

    /// Rule 3 against GPS errors: a fix jumping away and back, a coarse fix closing in on the true
    /// place, a slow drift indoors, and a steady slide with its stated accuracy.
    @Test func gpsErrorsMakeNoSeries() {
        let t0 = MapFixture.date("2024-03-03 12:00"), here = MapFixture.at(48.3000, 11.4000)
        func series(_ name: String, _ steps: [(seconds: Double, km: Double, bearing: Double)], accuracy: Double? = nil) -> [AssetSnapshot] {
            var position = here, time = t0
            var photos = [Self.shot("\(name)-0", time, position, accuracy: accuracy)]
            for (k, step) in steps.enumerated() {
                position = Self.offset(position, km: step.km, bearing: step.bearing)
                time = time.addingTimeInterval(step.seconds)
                photos.append(Self.shot("\(name)-\(k + 1)", time, position, accuracy: accuracy))
            }
            return photos
        }
        // Away 700 m and back, every 2 seconds (1,260 km/h each step).
        let jumping = series("jump", (0..<7).map { (2, 0.7, $0 % 2 == 0 ? 60 : 240) })
        // Closing in: 800, 520, 340, 220 and 140 m, 2 seconds apart, in one direction.
        let closing = series("close", [(2, 0.8, 10), (2, 0.52, 10), (2, 0.34, 10), (2, 0.22, 10), (2, 0.14, 10)])
        // Drifting at 5 m/s.
        let drift = series("drift", (0..<8).map { _ in (3, 0.015, 200) })
        // Sliding 400 m every 2 seconds (720 km/h) in a straight line, each fix stating 250 m.
        let stated = series("stated", (0..<4).map { _ in (2, 0.4, 135) }, accuracy: 250)
        #expect(AirborneFilter.airborne(jumping + closing + drift + stated).isEmpty)
        // Documented: the same slide without a stated accuracy is what a series out of the window
        // at 720 km/h looks like.
        let slide = series("slide", (0..<4).map { _ in (2, 0.4, 135) })
        #expect(AirborneFilter.airborne(slide) == Set(slide.map(\.id)))
    }

    @Test func zigZagsOnTheGroundAreNotFlights() {
        // Munich and Rome alternating (fast legs both ways, but no photo lies between its neighbours).
        #expect(AirborneFilter.airborne(Self.alternating(start: "2023-06-15 09:00", count: 40, a: Places.munich, b: Places.rome, minutes: 10)).isEmpty)
        // The same with both photos of a pair in the same second.
        let pairs = (0..<40).map { i in
            Self.shot("pair-\(i)", MapFixture.date("2023-06-16 09:00").addingTimeInterval(Double(i / 2) * 600),
                      Fixture.jitter(i % 2 == 0 ? Places.munich : Places.rome, seed: i, meters: 400))
        }
        #expect(AirborneFilter.airborne(pairs).isEmpty)
        // Two cities close together (Munich and Augsburg, 55 km) alternating every minute.
        let augsburg = MapFixture.at(48.3705, 10.8978)
        let close = (0..<30).map { i in
            Self.shot("close-\(i)", MapFixture.date("2023-06-17 10:00").addingTimeInterval(Double(i) * 60), i % 2 == 0 ? Places.munich : augsburg)
        }
        #expect(AirborneFilter.airborne(close).isEmpty)
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
        // Linz on the way to Tokyo: a leg of 19 hours counts for a single photo, one of more than
        // 20 hours says nothing.
        for (hours, expected) in [(19.0, ["l-1"] as Set<AssetID>), (20.1, [])] {
            let long = [Self.shot("l-0", t0, Places.munich), Self.shot("l-1", t0.addingTimeInterval(1_200), linz),
                        Self.shot("l-2", t0.addingTimeInterval(1_200 + hours * 3_600), Places.tokyo)]
            #expect(AirborneFilter.airborne(long) == expected, "\(hours)")
        }
    }

    // MARK: The fast search is the rule, photo by photo

    /// What the reference found, rule by rule.
    struct Judged {
        var all = Set<AssetID>()
        var byRule = [Set<AssetID>](repeating: [], count: 4)
    }

    /// The rules as `AirborneFilter` states them, photo by photo: every neighbour by a plain search,
    /// no groups, no bounds, no kept results.
    static func reference(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> Judged {
        let judged = photos.filter { $0.usableLocation != nil && $0.creationDate != nil && !$0.isScreenshotLike }.sorted { a, b in
            (a.creationDate!, a.id.rawValue, a.location!.latitude, a.location!.longitude)
                < (b.creationDate!, b.id.rawValue, b.location!.latitude, b.location!.longitude)
        }
        let n = judged.count
        let t = judged.map { $0.creationDate!.timeIntervalSinceReferenceDate }, c = judged.map { $0.location! }
        let accuracy = judged.map { $0.locationAccuracy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
        let leg = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration, stay = AirborneFilter.stayDuration
        let ground = AirborneFilter.maximumGroundSpeed, plane = AirborneFilter.maximumFlightSpeed
        func meters(_ a: Int, _ b: Int) -> Double { a <= b ? GeoMath.distance(c[a], c[b]) : GeoMath.distance(c[b], c[a]) }
        func fast(_ a: Int, _ b: Int) -> Bool { meters(a, b) > ground * abs(t[b] - t[a]) }
        func flown(_ a: Int, _ b: Int) -> Bool { fast(a, b) && meters(a, b) <= plane * abs(t[b] - t[a]) }
        func onTheWay(_ a: Int, _ m: Int, _ b: Int) -> Bool {
            meters(a, m) + meters(m, b) <= AirborneFilter.detourFactor * meters(a, b) + AirborneFilter.detourAllowanceMeters
        }
        func neighbour(_ i: Int, _ step: Int) -> Int? {
            var j = i + step
            while j >= 0 && j < n && abs(t[j] - t[i]) <= window {
                if meters(j, i) >= leg { return j }
                j += step
            }
            return nil
        }
        func edge(_ i: Int, _ step: Int) -> Int {
            var j = i
            while j + step >= 0 && j + step < n && abs(t[j + step] - t[i]) <= window { j += step }
            return j
        }
        func stays(_ i: Int, _ before: Int?, _ after: Int?, any: Bool) -> Bool {
            let first = before.map { $0 + 1 } ?? edge(i, -1), last = after.map { $0 - 1 } ?? edge(i, 1)
            guard first < last else { return false }
            let span = t[last] - t[first]
            guard any || span >= stay else { return false }
            var progress = Double.infinity
            if let before { progress = min(progress, meters(before, last) - meters(before, first)) }
            if let after { progress = min(progress, meters(first, after) - meters(last, after)) }
            if before == nil && after == nil { progress = meters(first, last) }
            return progress < max(ground * span, accuracy[first] + accuracy[last]) + 1
        }
        func staysAt(_ p: Int, _ step: Int) -> Bool {
            let farthest = neighbour(p, step).map { $0 - step } ?? edge(p, step)
            return abs(t[farthest] - t[p]) >= stay
        }
        func comesBack(_ i: Int) -> Bool {
            for step in [-1, 1] {
                var k = i + step
                while k >= 0 && k < n && abs(t[k] - t[i]) <= AirborneFilter.returnDuration {
                    if abs(t[k] - t[i]) >= stay && meters(i, k) < leg { return true }
                    k += step
                }
            }
            return false
        }

        // Rule 1 and rule 2.
        let high = judged.map { photo in altitudes[photo.id].map { $0 > AirborneFilter.maximumAltitude } ?? false }
        let run = (0..<n).map { i -> Bool in
            guard let b = neighbour(i, -1), let a = neighbour(i, 1), flown(b, i), flown(i, a), onTheWay(b, i, a) else { return false }
            let long = t[i] - t[b] > AirborneFilter.maximumLegDuration || t[a] - t[i] > AirborneFilter.maximumLegDuration
            if stays(i, b, a, any: long) { return false }
            if t[i] - t[b] <= AirborneFilter.runEndLongDuration && staysAt(b, -1) { return false }
            if t[a] - t[i] <= AirborneFilter.runEndLongDuration && staysAt(a, 1) { return false }
            if let p = neighbour(b, -1), fast(p, b), !onTheWay(p, b, i) { return false }
            if let q = neighbour(a, 1), fast(a, q), !onTheWay(i, a, q) { return false }
            return !comesBack(i)
        }
        // Rule 3: every four photos in a row, chained where they share a photo.
        var chains: [(first: Int, last: Int)] = []
        for k in 0..<n where k + 3 < n {
            var ok = true, slowest = Double.infinity, fastest = 0.0, path = 0.0
            for m in k..<(k + 3) {
                let d = meters(m, m + 1), s = t[m + 1] - t[m]
                ok = s > 0 && s <= AirborneFilter.burstStepDuration && d >= max(AirborneFilter.burstStepMeters, accuracy[m] + accuracy[m + 1])
                    && d > AirborneFilter.burstSpeed * s && d <= plane * s
                guard ok else { break }
                slowest = min(slowest, d / s)
                fastest = max(fastest, d / s)
                path += d
            }
            guard ok, fastest <= AirborneFilter.burstSpeedRatio * slowest, path <= AirborneFilter.burstStraightness * meters(k, k + 3) else { continue }
            if let chain = chains.last, k <= chain.last { chains[chains.count - 1].last = k + 3 } else { chains.append((k, k + 3)) }
        }
        var burst = [Bool](repeating: false, count: n), first = [Int](repeating: -1, count: n), last = first
        for chain in chains {
            for p in chain.first...chain.last { (burst[p], first[p], last[p]) = (true, chain.first, chain.last) }
        }
        // A burst's photos that the location comes back to are none.
        let inBurst = (0..<n).map { burst[$0] && !comesBack($0) }
        // Rule 4.
        let confirmed = (0..<n).map { high[$0] || run[$0] || inBurst[$0] }
        let end = (0..<n).map { i -> Bool in
            guard !confirmed[i] else { return false }
            let b = neighbour(i, -1), a = neighbour(i, 1)
            guard !stays(i, b, a, any: true), !comesBack(i) else { return false }
            for (r, other, later) in [(a, b, true), (b, a, false)] {
                guard let r, confirmed[r], flown(i, r) else { continue }
                let seconds = abs(t[r] - t[i])
                guard seconds <= AirborneFilter.runEndLongDuration,
                      seconds <= AirborneFilter.runEndDuration || meters(i, r) > AirborneFilter.runEndLongSpeed * seconds else { continue }
                if let other, !(later ? onTheWay(other, i, r) : onTheWay(r, i, other)) { continue }
                let far = run[r] ? neighbour(r, later ? 1 : -1) : burst[r] ? (later ? last[r] : first[r]) : nil
                if let far, far != r, !(later ? onTheWay(i, r, far) : onTheWay(far, r, i)) { continue }
                return true
            }
            return false
        }
        var result = Judged()
        for (rule, flags) in [high, run, inBurst, end].enumerated() {
            for i in 0..<n where flags[i] {
                result.all.insert(judged[i].id)
                result.byRule[rule].insert(judged[i].id)
            }
        }
        return result
    }

    /// A random life of photos, mixed so that every rule and every bound of the fast search is met:
    /// stays of many photos, walks and drives, flights with window photos and series, series at a
    /// plane's speed on their own, wrong locations, pauses of hours, long-haul hops, a location
    /// jumping kilometres within seconds, equal times, a photo twice, stated accuracies.
    static func wander(seed: UInt64, count: Int) -> [AssetSnapshot] {
        var random = MapRandom(seed: seed)
        var position = Places.munich
        var time = MapFixture.date("2023-01-01").timeIntervalSinceReferenceDate
        var photos: [AssetSnapshot] = []
        func add(_ coordinate: GeoCoordinate? = nil) {
            let accuracy: Double? = random.int(0..<12) == 0 ? 20 + random.unit() * 600 : nil
            photos.append(shot("r\(seed)-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), coordinate ?? position, accuracy: accuracy))
        }
        func move(_ km: Double, bearing: Double? = nil) {
            let moved = offset(position, km: km, bearing: bearing ?? random.unit() * 360)
            position = MapFixture.at(min(80, max(-80, moved.latitude)), moved.longitude)
        }
        while photos.count < count {
            switch random.int(0..<16) {
            case 0, 1:
                let center = position
                for _ in 0..<(2 + random.int(0..<25)) {
                    time += random.unit() < 0.5 ? random.unit() * 10 : random.unit() * 300
                    add(offset(center, km: random.unit() * 0.4, bearing: random.unit() * 360))
                }
            case 2:
                let bearing = random.unit() * 360, kmh = random.unit() < 0.5 ? 5 : 60 + random.unit() * 240
                for _ in 0..<(3 + random.int(0..<10)) {
                    let minutes = 0.5 + random.unit() * 10
                    time += minutes * 60
                    move(kmh * minutes / 60, bearing: bearing + random.unit() * 20 - 10)
                    add()
                }
            case 3, 4:
                add()
                time += (20 + random.unit() * 40) * 60
                let bearing = random.unit() * 360, kmh = 450 + random.unit() * 500
                for _ in 0..<(1 + random.int(0..<10)) {
                    let minutes = 2 + random.unit() * 13
                    time += minutes * 60
                    move(kmh * minutes / 60, bearing: bearing)
                    if random.int(0..<4) == 0 {
                        for _ in 0..<(2 + random.int(0..<4)) {
                            add()
                            let seconds = 1 + random.unit() * 4
                            time += seconds
                            move(kmh * seconds / 3_600, bearing: bearing)
                        }
                    } else {
                        add()
                    }
                }
                time += (15 + random.unit() * 40) * 60
                move(random.unit() * 20)
                add()
            case 5:
                let bearing = random.unit() * 360, kmh = 300 + random.unit() * 1_300
                for _ in 0..<(3 + random.int(0..<4)) {
                    add()
                    let seconds = 1 + random.unit() * 6
                    time += seconds
                    move(kmh * seconds / 3_600, bearing: bearing + random.unit() * 30 - 15)
                }
            case 6:
                time += random.unit() * 600
                add(offset(position, km: 3 + random.unit() * 2_000, bearing: random.unit() * 360))
                time += random.unit() * 600
                add()
            case 7:
                time += (1 + random.unit() * 30) * 3_600
                add()
            case 8:
                time += (3 + random.unit() * 14) * 3_600
                move(2_000 + random.unit() * 9_000)
                add()
            case 9:
                let center = position
                for _ in 0..<(3 + random.int(0..<30)) {
                    time += 2 + random.unit() * 30
                    add(offset(center, km: 1 + random.unit() * 2, bearing: random.unit() * 360))
                }
            case 10:
                add()
                add(offset(position, km: random.unit() * 5, bearing: random.unit() * 360))
                if random.int(0..<2) == 0 { photos.append(photos[photos.count - 1]) }
            default:
                time += random.unit() * 1_200
                move(random.unit() * 6)
                add()
            }
        }
        return Array(photos.prefix(count))
    }

    @Test func theFastSearchGivesThePhotoByPhotoResult() {
        var byRule = [Int](repeating: 0, count: 4)
        for seed in 1...6 as ClosedRange<UInt64> {
            let photos = Self.wander(seed: seed, count: 2_500)
            let altitudes = Dictionary(photos.enumerated().filter { $0.offset % 97 == 0 }.map { ($0.element.id, Double($0.offset % 3) * 4_000) },
                                       uniquingKeysWith: { a, _ in a })
            let expected = Self.reference(photos, altitudes: altitudes)
            let airborne = AirborneFilter.airborne(photos, altitudes: altitudes)
            #expect(airborne == expected.all, "seed \(seed): extra \(airborne.subtracting(expected.all)), missing \(expected.all.subtracting(airborne))")
            for rule in 0..<4 { byRule[rule] += expected.byRule[rule].count }
        }
        // Every rule had photos to judge.
        #expect(byRule.allSatisfy { $0 > 0 }, "\(byRule)")
        // The flights of the realistic library too.
        let library = MapLibrary(count: 6_000, seed: 3).facts.map(\.asset)
        #expect(AirborneFilter.airborne(library) == Self.reference(library).all)
        // A photo every three seconds for half an hour in flight (the search for a location coming
        // back passes them by the way flown), and evenings of a location jumping around indoors.
        let dense = Self.flight("every-3s", from: Self.munichAirport, to: Self.lisbonAirport, takeoff: MapFixture.date("2024-05-05 08:00"),
                                gate: [40], arrival: [30]) { _ in Array(stride(from: 10.0, to: 40.0, by: 0.05)) }
        #expect(AirborneFilter.airborne(dense.photos) == dense.window)
        #expect(Self.reference(dense.photos).all == dense.window)
        let indoors = Self.jumpingIndoors()
        #expect(AirborneFilter.airborne(indoors) == Self.reference(indoors).all)
    }

    // MARK: Speed

    @Test func fiftyThousandPhotosAreJudgedQuickly() {
        let photos = MapLibrary(count: 50_000).facts.map(\.asset)
        let clock = ContinuousClock()
        var result = Set<AssetID>()
        let elapsed = clock.measure { result = AirborneFilter.airborne(photos) }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "AIRBORNE_PERF photos %d: %.1f ms, %d in flight", photos.count, ms, result.count))
        #expect(result.count > 1_000)
        // A debug build on a shared machine is several times slower than the app; the bound only
        // catches a search that reads every photo of a burst for every photo of it.
        #expect(ms < 2_000)
    }

    /// Thousands of day trips, weddings of 3,000 photos in an afternoon, evenings of 2,500 photos
    /// whose location jumps between three spots 1.6 to 2.4 km apart every few seconds, one of them
    /// right after a photo on the far side of the world (a leg of the length of a long-haul flight,
    /// so no photo of the evening can rule out a fast leg by the steps alone), and evenings of
    /// 2,000 photos whose location lands 1 to 3 km off in any direction.
    static func denseLibrary(count: Int) -> [AssetSnapshot] {
        var random = MapRandom(seed: 99)
        var photos: [AssetSnapshot] = []
        let home = Places.regensburg
        var day = MapFixture.date("2016-01-01").timeIntervalSinceReferenceDate
        func add(_ time: Double, _ coordinate: GeoCoordinate) {
            photos.append(shot("dense-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), coordinate))
        }
        var n = 0
        while photos.count < count {
            n += 1
            add(day + 7 * 3_600, Fixture.jitter(home, seed: n, meters: 200))
            if n % 30 == 0 {
                var time = day + 14 * 3_600
                for k in 0..<3_000 {
                    time += 2 + random.unit() * 5
                    add(time, Fixture.jitter(Self.offset(home, km: 12, bearing: 30), seed: k, meters: 300))
                }
            } else if n % 20 == 0 {
                let hall = Self.offset(home, km: 25, bearing: 160)
                var time = day + 18 * 3_600
                for _ in 0..<2_000 {
                    time += 2 + random.unit() * 28
                    add(time, Self.offset(hall, km: 1 + random.unit() * 2, bearing: random.unit() * 360))
                }
            } else if n % 15 == 0 {
                if n % 45 == 0 { add(day + 1 * 3_600, Places.tokyo) }
                let hall = Self.offset(home, km: 20, bearing: 80)
                let spots = [hall, Self.offset(hall, km: 2.4, bearing: 0), Self.offset(hall, km: 1.6, bearing: 120)]
                var time = day + 9 * 3_600
                for k in 0..<2_500 {
                    time += 3 + random.unit() * 12
                    add(time, Fixture.jitter(spots[random.int(0..<3)], seed: k, meters: 300))
                }
            } else {
                let spot = Self.offset(home, km: 30 + random.unit() * 120, bearing: random.unit() * 360)
                for k in 0..<15 { add(day + 10 * 3_600 + Double(k) * 600, Fixture.jitter(spot, seed: k + n, meters: 1_500)) }
            }
            add(day + 21 * 3_600, Fixture.jitter(home, seed: n + 1, meters: 200))
            day += 86_400
        }
        return photos
    }

    @Test func aDenseLibraryIsJudgedQuickly() {
        let photos = Self.denseLibrary(count: 50_000)
        let clock = ContinuousClock()
        var result = Set<AssetID>()
        let elapsed = clock.measure { result = AirborneFilter.airborne(photos) }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "AIRBORNE_PERF dense photos %d: %.1f ms, %d in flight", photos.count, ms, result.count))
        // All on the ground (the photo on the far side of the world is a wrong location: one leg).
        #expect(result.isEmpty)
        // Before the search stopped after a minute of photos near the photo, the evening after the
        // far photo took about ten seconds here.
        #expect(ms < 2_000)
    }
}
