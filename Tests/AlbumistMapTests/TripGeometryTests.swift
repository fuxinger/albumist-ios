import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Where the photos of one trip were (`TripGeometry.build`): day places, trip places with names,
/// the route and its legs, the destination, countries, photos per day and place altitude.
@Suite("Trip geometry")
struct TripGeometryTests {
    typealias Places = MapFixture.Places
    static let iceland = "Atlantic/Reykjavik"
    static let sintra = MapFixture.at(38.8029, -9.3817)
    static let madrid = MapFixture.at(40.4168, -3.7038)
    static let augsburg = MapFixture.at(48.3705, 10.8978)
    static let stPeters = MapFixture.at(41.9022, 12.4539)
    static let pyramiden = MapFixture.at(78.6553, 16.3256)
    static let barentsburg = MapFixture.at(78.0648, 14.2335)
    /// Taveuni, Fiji: the 180th meridian runs across the island.
    static let taveuni = MapFixture.at(-16.8500, -179.9800)

    static func day(_ string: String) -> LocalDay {
        let parts = string.split(separator: "-").map { Int($0)! }
        return LocalDay(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The trip over `facts` (made its members) and its geometry.
    static func build(_ facts: [AssetFacts], id: String = "trip", airborne: Set<AssetID> = [], altitudes: [AssetID: Double] = [:],
                      timeZone: TimeZone = MapFixture.utc) -> TripGeometry {
        let members = MapFixture.members(facts, of: AlbumistID(id))
        return TripGeometry.build(trip: MapFixture.trip(AlbumistID(id), members), facts: members, airborne: airborne, altitudes: altitudes,
                                  timeZone: timeZone)
    }

    /// `c` moved `east` and `north` metres.
    static func offset(_ c: GeoCoordinate, east: Double = 0, north: Double = 0) -> GeoCoordinate {
        GeoCoordinate(latitude: c.latitude + north / GeoMath.metersPerDegreeLatitude,
                      longitude: c.longitude + east / (GeoMath.metersPerDegreeLatitude * cos(c.latitude * .pi / 180)))
    }

    /// The point `meters` from `c` towards `bearing` (degrees from north), on the sphere.
    static func destination(from c: GeoCoordinate, bearing: Double, meters: Double) -> GeoCoordinate {
        let angle = meters / GeoMath.earthRadiusMeters, theta = bearing * .pi / 180
        let lat1 = c.latitude * .pi / 180, lon1 = c.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angle) + cos(lat1) * sin(angle) * cos(theta))
        var lon2 = (lon1 + atan2(sin(theta) * sin(angle) * cos(lat1), cos(angle) - sin(lat1) * sin(lat2))) * 180 / .pi
        if lon2 > 180 { lon2 -= 360 } else if lon2 < -180 { lon2 += 360 }
        return GeoCoordinate(latitude: lat2 * 180 / .pi, longitude: lon2)
    }

    /// Photos taken in turn at `places`, one person at each (an iCloud Shared Library): from
    /// `start` (UTC), `rounds` rounds of `period`, in each three photos 20 s apart at every place,
    /// each place's turn `offset` after the one before (by default the round spread evenly).
    static func inTurn(_ places: [(GeoCoordinate, String)], rounds: Int, period: TimeInterval, offset: TimeInterval? = nil,
                       start: String = "2023-06-15 12:00") -> [AssetFacts] {
        let offset = offset ?? period / Double(places.count)
        var photos: [AssetFacts] = []
        for round in 0..<rounds {
            let t = MapFixture.date(start).addingTimeInterval(Double(round) * period)
            for (c, place) in places.enumerated() {
                for k in 0..<3 {
                    photos.append(MapFixture.photo("\(place.1)-\(round)-\(k)", at: t.addingTimeInterval(offset * Double(c) + Double(k) * 20),
                                                   Fixture.jitter(place.0, seed: k, meters: 50), country: "IS", town: place.1))
                }
            }
        }
        return photos
    }

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var random = MapRandom(seed: seed)
        var result = items
        for i in stride(from: result.count - 1, to: 0, by: -1) { result.swapAt(i, random.int(0..<(i + 1))) }
        return result
    }

    // MARK: Iceland, the ring road

    /// Nine days: Reykjavík, Þingvellir (back to Reykjavík for the night), Geysir and Gullfoss,
    /// Seljalandsfoss, Skógafoss, three nights in Vík (Reynisfjara on the way), two photos at
    /// Seljalandsfoss on the way back, Reykjavík.
    static func ringRoad() -> [AssetFacts] {
        func at(_ prefix: String, _ count: Int, _ place: GeoCoordinate, _ day: String, hour: Int, town: String? = nil,
                poi: String? = nil) -> [AssetFacts] {
            MapFixture.burst(prefix, count: count, at: place, day: day, hour: hour, country: "IS", town: town, pointOfInterest: poi, timeZone: iceland)
        }
        return at("rvk1", 10, Places.reykjavik, "2023-06-14", hour: 12, town: "Reykjavík")
            + at("thing", 8, Places.thingvellir, "2023-06-15", hour: 10, poi: "Þingvellir")
            + at("rvk2", 4, Places.reykjavik, "2023-06-15", hour: 19, town: "Reykjavík")
            + at("geysir", 6, Places.geysir, "2023-06-16", hour: 10, poi: "Geysir")
            + at("gull", 6, Places.gullfoss, "2023-06-16", hour: 13, poi: "Gullfoss")
            + at("selja", 7, Places.seljalandsfoss, "2023-06-17", hour: 11, poi: "Seljalandsfoss")
            + at("skoga", 9, Places.skogafoss, "2023-06-18", hour: 10, town: "Skógar", poi: "Skógafoss")
            + at("vik1", 5, Places.vik, "2023-06-18", hour: 19, town: "Vík")
            + at("vik2", 6, Places.vik, "2023-06-19", hour: 9, town: "Vík")
            + at("reynis", 3, Places.vik, "2023-06-19", hour: 14, town: "Vík", poi: "Reynisfjara")
            + at("vik3", 3, Places.vik, "2023-06-20", hour: 9, town: "Vík")
            + at("selja2", 2, Places.seljalandsfoss, "2023-06-21", hour: 12, poi: "Seljalandsfoss")
            + at("rvk3", 8, Places.reykjavik, "2023-06-22", hour: 11, town: "Reykjavík")
    }

    @Test func icelandRingRoad() throws {
        let facts = Self.ringRoad()
        let geometry = Self.build(facts, id: "iceland")
        #expect(geometry.id == AlbumistID("iceland"))
        #expect(geometry.photoCount == 77)
        #expect(geometry.start == MapFixture.date("2023-06-14 12:00"))
        #expect(geometry.end == MapFixture.date("2023-06-22 12:10"))
        #expect(geometry.timeZoneIdentifier == Self.iceland)
        #expect(geometry.firstDay == Self.day("2023-06-14"))
        #expect(geometry.lastDay == Self.day("2023-06-22"))
        #expect(geometry.days == 9)

        // A point of interest names a place when it names at least half of its photos
        // (Skógafoss, though in the town of Skógar); Reynisfjara names 3 of Vík's 17: the town.
        #expect(geometry.places.map(\.name) == ["Reykjavík", "Þingvellir", "Geysir", "Gullfoss", "Seljalandsfoss", "Skógafoss", "Vík"])
        #expect(geometry.places.map(\.photoCount) == [22, 8, 6, 6, 7, 9, 17])
        #expect(geometry.places.allSatisfy { $0.countryKey == "IS" && $0.altitude == nil })
        // The hotel towns of several days are one place each.
        #expect(geometry.places[0].days == [Self.day("2023-06-14"), Self.day("2023-06-15"), Self.day("2023-06-22")])
        #expect(geometry.places[6].days == [Self.day("2023-06-18"), Self.day("2023-06-19"), Self.day("2023-06-20")])
        // Every point is a real photo location of the place.
        for (p, place) in geometry.places.enumerated() {
            let ids = Set(geometry.places[p].coverCandidates)
            #expect(ids.count == min(6, place.photoCount))
            #expect(facts.contains { $0.asset.location == place.coordinate })
        }
        #expect(geometry.places[0].coverCandidates == ["rvk1-0", "rvk1-1", "rvk1-2", "rvk1-3", "rvk1-4", "rvk1-5"])

        #expect(geometry.dayPlaces.map(\.placeIndex) == [0, 1, 0, 2, 3, 4, 5, 6, 6, 6, 0])
        #expect(geometry.dayPlaces.map(\.photoCount) == [10, 8, 4, 6, 6, 7, 9, 5, 9, 3, 8])
        #expect(geometry.dayPlaces[8].firstPhoto == MapFixture.date("2023-06-19 09:00"))
        #expect(geometry.dayPlaces[8].lastPhoto == MapFixture.date("2023-06-19 14:20"))
        #expect(geometry.dayPlaces.allSatisfy { dayPlace in facts.contains { $0.asset.location == dayPlace.coordinate } })

        // The route: back to Reykjavík for the night, three nights in Vík one visit.
        #expect(geometry.route.map(\.placeIndex) == [0, 1, 0, 2, 3, 4, 5, 6, 0])
        #expect(geometry.route.map(\.day) == ["2023-06-14", "2023-06-15", "2023-06-15", "2023-06-16", "2023-06-16", "2023-06-17", "2023-06-18",
                                              "2023-06-18", "2023-06-22"].map(Self.day))
        #expect(geometry.route[7].arrival == MapFixture.date("2023-06-18 19:00"))
        #expect(geometry.route[7].departure == MapFixture.date("2023-06-20 09:20"))
        #expect(geometry.legs.count == 8)
        for (i, leg) in geometry.legs.enumerated() {
            #expect(leg.meters == GeoMath.distance(geometry.routeCoordinates[i], geometry.routeCoordinates[i + 1]))
        }
        // Only Vík → Reykjavík is longer than 100 km with more than 3 hours without a photo.
        #expect(geometry.legs.map(\.withoutPhotos) == [false, false, false, false, false, false, false, true])
        #expect(geometry.legs[7].meters > 150_000 && geometry.legs[7].meters < 180_000)

        #expect(geometry.destinationIndex == 0)
        #expect(geometry.destination == geometry.places[0].coordinate)
        #expect(geometry.destinationName == "Reykjavík")
        // The two photos at Seljalandsfoss on the way back make no place but count for the
        // country and their day.
        #expect(geometry.countryPhotos == ["IS": 77])
        #expect(geometry.mainCountryKey == "IS")
        #expect(geometry.airborneCount == 0)
        #expect(geometry.dayCounts.map(\.day) == (14...22).map { Self.day("2023-06-\($0)") })
        #expect(geometry.dayCounts.map(\.photoCount) == [10, 12, 12, 7, 14, 9, 3, 2, 8])
        // Geysir and Gullfoss both hold 6 photos of the 16th: the lower index.
        #expect(geometry.dayCounts.map(\.placeIndex) == [0, 1, 2, 4, 5, 6, 6, nil, 0])
    }

    @Test func shuffledInputGivesTheSameGeometry() {
        // The ring road with photos lacking a location or a date, a screenshot, equal times
        // and one photo given twice.
        var facts = Self.ringRoad()
        facts.append(MapFixture.photo("no-location", at: MapFixture.date("2023-06-16 12:00"), nil))
        facts.append(MapFixture.photo("no-date", at: MapFixture.date("2023-06-16 12:00"), Places.geysir, country: "IS"))
        facts[facts.count - 1].asset.creationDate = nil
        var screenshot = MapFixture.photo("screenshot", at: MapFixture.date("2023-06-17 11:05"), Places.seljalandsfoss, country: "IS")
        screenshot.asset.subtypes = .screenshot
        facts.append(screenshot)
        for i in 0..<4 {
            facts.append(MapFixture.photo("same-second-\(i)", at: MapFixture.date("2023-06-19 12:00"),
                                          Fixture.jitter(Places.vik, seed: 50 + i, meters: 3_000), country: "IS", town: "Vík", timeZone: Self.iceland))
        }
        facts.append(facts[3])
        let expected = Self.build(facts)
        // The photo given twice counts once.
        #expect(expected.photoCount == facts.count - 1)
        for seed in 1...6 as ClosedRange<UInt64> {
            #expect(Self.build(Self.shuffled(facts, seed: seed)) == expected)
        }
    }

    // MARK: Places of a day

    @Test func aCityDaySpreadOverFourKilometresIsOnePlace() throws {
        // A walk from St. Peter's 4 km east, a photo every 400 m: the running centre follows the
        // walk, so the city stays one place.
        let start = MapFixture.date("2023-05-02 08:00")
        let walk = (0...10).map { i in
            MapFixture.photo("walk-\(i)", at: start.addingTimeInterval(Double(i) * 900), Self.offset(Self.stPeters, east: Double(i) * 400),
                             country: "IT", town: "Roma", timeZone: "Europe/Rome")
        }
        let geometry = Self.build(walk)
        #expect(geometry.dayPlaces.count == 1)
        #expect(geometry.dayPlaces.first?.photoCount == 11)
        #expect(geometry.places.count == 1)
        #expect(geometry.places.first?.name == "Roma")
        #expect(geometry.route.count == 1)
        #expect(geometry.legs.isEmpty)
        #expect(geometry.metersOnSite == 0)
        #expect(geometry.destinationIndex == 0)
        // The same walk on to 8 km leaves the first place's radius: two places.
        let longWalk = (0...20).map { i in
            MapFixture.photo("long-\(i)", at: start.addingTimeInterval(Double(i) * 900), Self.offset(Self.stPeters, east: Double(i) * 400),
                             country: "IT", town: "Roma")
        }
        let long = Self.build(longWalk)
        #expect(long.places.count == 2)
        #expect(long.route.map(\.placeIndex) == [0, 1])
        #expect(long.legs.count == 1 && long.legs[0].meters > 3_000 && !long.legs[0].withoutPhotos)
    }

    @Test func thereAndBackInOneDayIsThreeRoutePoints() throws {
        // Lisbon in the morning, Sintra at noon, Lisbon in the evening.
        let facts = MapFixture.burst("lis-am", count: 4, at: Places.lisbon, day: "2023-04-10", hour: 9, country: "PT", town: "Lisboa")
            + MapFixture.burst("sintra", count: 5, at: Self.sintra, day: "2023-04-10", hour: 13, country: "PT", town: "Sintra")
            + MapFixture.burst("lis-pm", count: 4, at: Places.lisbon, day: "2023-04-10", hour: 19, country: "PT", town: "Lisboa")
        let geometry = Self.build(facts)
        // The morning and the evening in Lisbon are one place of the day.
        #expect(geometry.dayPlaces.map(\.photoCount) == [8, 5])
        #expect(geometry.places.map(\.name) == ["Lisboa", "Sintra"])
        #expect(geometry.route.map(\.placeIndex) == [0, 1, 0])
        #expect(geometry.route.map(\.arrival) == ["2023-04-10 09:00", "2023-04-10 13:00", "2023-04-10 19:00"].map(MapFixture.date))
        #expect(geometry.route.map(\.departure) == ["2023-04-10 09:30", "2023-04-10 13:40", "2023-04-10 19:30"].map(MapFixture.date))
        #expect(geometry.legs.count == 2)
        #expect(geometry.legs.allSatisfy { $0.meters > 20_000 && $0.meters < 26_000 && !$0.withoutPhotos })
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-04-10"), photoCount: 13, placeIndex: 0)])
    }

    @Test func noPlaceMeansTheMedoidAndNoDestinationIndex() throws {
        // A drive north from Lisbon, one photo every 20 km: no three photos of a day together.
        let start = MapFixture.date("2023-04-12 08:00")
        let drive = (0..<12).map { i in
            MapFixture.photo("drive-\(i)", at: start.addingTimeInterval(Double(i) * 900), Self.offset(Places.lisbon, north: Double(i) * 20_000),
                             country: "PT")
        }
        let geometry = Self.build(drive)
        #expect(geometry.dayPlaces.isEmpty && geometry.places.isEmpty && geometry.route.isEmpty && geometry.legs.isEmpty)
        #expect(geometry.destinationIndex == nil)
        #expect(geometry.destinationName == nil)
        #expect(geometry.destination == GeoMath.dayPoint(drive.map { $0.asset.location! }))
        #expect(drive.contains { $0.asset.location == geometry.destination })
        #expect(geometry.countryPhotos == ["PT": 12])
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-04-12"), photoCount: 12, placeIndex: nil)])

        // No photo on the map at all: the trip's centre, and no day with photos on the map.
        let unlocated = (0..<3).map { MapFixture.photo("blind-\($0)", at: start.addingTimeInterval(Double($0) * 60), nil) }
        let trip = Trip(id: AlbumistID("blind"), start: start, end: start.addingTimeInterval(120), geotaggedAssetIDs: [],
                        inferredAssetIDs: unlocated.map(\.id), centroid: Places.rome, maxDistanceFromHomeMeters: 0, distinctStops: 0, kind: .vacation)
        let blind = TripGeometry.build(trip: trip, facts: unlocated, airborne: [], timeZone: MapFixture.utc)
        #expect(blind.destination == Places.rome)
        #expect(blind.destinationIndex == nil)
        #expect(blind.photoCount == 3)
        #expect(blind.timeZoneIdentifier == nil)
        #expect(blind.dayCounts.isEmpty)
        #expect(blind.firstDay == Self.day("2023-04-12") && blind.lastDay == Self.day("2023-04-12"))
    }

    @Test func anEmptyTripAndASinglePhoto() throws {
        let start = MapFixture.date("2023-03-01 23:30"), end = MapFixture.date("2023-03-04 10:00")
        let trip = Trip(id: AlbumistID("empty"), start: start, end: end, geotaggedAssetIDs: [], inferredAssetIDs: [], centroid: Places.florence,
                        maxDistanceFromHomeMeters: 0, distinctStops: 0, kind: .vacation)
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let empty = TripGeometry.build(trip: trip, facts: [], airborne: [], timeZone: berlin)
        #expect(empty.photoCount == 0)
        #expect(empty.start == start && empty.end == end)
        // 23:30 UTC is already the 2nd in Berlin: the device's zone without a place.
        #expect(empty.firstDay == Self.day("2023-03-02") && empty.lastDay == Self.day("2023-03-04"))
        #expect(empty.dayCounts.isEmpty && empty.dayPlaces.isEmpty && empty.places.isEmpty && empty.route.isEmpty && empty.legs.isEmpty)
        #expect(empty.destinationIndex == nil && empty.destination == Places.florence)
        #expect(empty.countryPhotos.isEmpty && empty.mainCountryKey == nil && empty.airborneCount == 0 && empty.timeZoneIdentifier == nil)

        let single = Self.build([MapFixture.photo("one", at: start, Places.porto, country: "PT", timeZone: "Europe/Lisbon")])
        #expect(single.places.isEmpty && single.route.isEmpty)
        #expect(single.destination == Places.porto)
        #expect(single.countryPhotos == ["PT": 1] && single.mainCountryKey == "PT")
        #expect(single.timeZoneIdentifier == "Europe/Lisbon")
        #expect(single.dayCounts == [TripDay(day: Self.day("2023-03-01"), photoCount: 1, placeIndex: nil)])
    }
}
