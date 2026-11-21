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

    // MARK: Route

    @Test func moreThanTwoHundredVisitsAreSimplified() throws {
        // 160 days from a hotel on Taveuni, right on the antimeridian, each to another place and
        // back: 321 visits. One day goes 150 km out, the others 10 to 60 km.
        var facts: [AssetFacts] = []
        for d in 0..<160 {
            let day = MapFixture.date("2023-01-01").addingTimeInterval(Double(d) * 86_400)
            let meters = d == 77 ? 150_000 : 10_000 + Double(d % 50) * 1_000
            let excursion = Self.destination(from: Self.taveuni, bearing: Double(d) * 137.5, meters: meters)
            for (part, hour, place) in [("am", 8, Self.taveuni), ("ex", 12, excursion), ("pm", 19, Self.taveuni)] {
                for k in 0..<3 {
                    facts.append(MapFixture.photo("d\(d)-\(part)-\(k)", at: day.addingTimeInterval(Double(hour * 3_600 + k * 300)),
                                                  Fixture.jitter(place, seed: d * 10 + k, meters: 100), country: "FJ", timeZone: "Pacific/Fiji"))
                }
            }
        }
        let geometry = Self.build(facts)
        #expect(geometry.places.count > 150)
        #expect(geometry.route.count <= TripGeometry.maxRoutePoints)
        #expect(geometry.route.count > 100)
        // First and last kept, no place twice in a row, in time order.
        #expect(geometry.route.first?.placeIndex == 0 && geometry.route.first?.arrival == MapFixture.date("2023-01-01 08:00"))
        #expect(geometry.route.last?.placeIndex == 0 && geometry.route.last?.departure == MapFixture.date("2023-06-09 19:10"))
        for (a, b) in zip(geometry.route, geometry.route.dropFirst()) {
            #expect(a.placeIndex != b.placeIndex)
            #expect(a.arrival <= a.departure && a.departure < b.arrival)
        }
        #expect(geometry.legs.count == geometry.route.count - 1)
        // The farthest excursion stands out most: it stays.
        let reach = geometry.places.map { GeoMath.distance($0.coordinate, Self.taveuni) }
        let far = try #require(reach.indices.max { reach[$0] < reach[$1] })
        #expect(reach[far] > 140_000)
        #expect(geometry.route.contains { $0.placeIndex == far })
        // Lines across the antimeridian are short: none goes round the Earth.
        let points = geometry.routeCoordinates
        #expect(zip(points, points.dropFirst()).allSatisfy { GeoMath.distance($0, $1) < 310_000 })
        // "vor Ort" is every excursion there and back, the ones the cut left out too.
        let hotel = geometry.places[0].coordinate
        let everyLeg = geometry.dayPlaces.filter { $0.placeIndex != 0 }.reduce(0.0) {
            $0 + 2 * GeoMath.distance(hotel, geometry.places[$1.placeIndex].coordinate)
        }
        #expect(abs(geometry.metersOnSite - everyLeg) < 1)
    }

    @Test func simplificationKeepsAnExcursionThereAndBack() {
        // Hotel, a nearby place, hotel, a far waterfall, hotel, a nearby place, hotel: at most 4
        // points keep the waterfall (an excursion has no area, but stands out from the line).
        let hotel = Places.vik
        let coordinates = [hotel, Self.offset(hotel, east: 5_000), Self.offset(hotel, north: 60_000), Self.offset(hotel, east: -6_000)]
        let visits = [0, 1, 0, 2, 0, 3, 0].enumerated().map { TripGeometryBuilder.Visit(place: $1, first: $0, last: $0) }
        let cut = TripGeometryBuilder.simplified(visits, coordinates: coordinates, limit: 4)
        let kept = cut.visits
        #expect(kept.count <= 4)
        #expect(kept.first?.first == 0 && kept.last?.last == 6)
        #expect(kept.contains { $0.place == 2 })
        for (a, b) in zip(kept, kept.dropFirst()) { #expect(a.place != b.place) }
        // Each kept point starts at a visit of its place (`cutLegs` sums the legs from there on).
        #expect(cut.starts.count == kept.count && cut.starts.first == 0)
        #expect(zip(kept, cut.starts).allSatisfy { visits[$1] == TripGeometryBuilder.Visit(place: $0.place, first: $0.first, last: $0.first) })
        // Points on the great circle between their neighbours (here a meridian) never count.
        let line = (0..<6).map { TripGeometryBuilder.Visit(place: $0, first: $0, last: $0) }
        let lineCoordinates = (0..<6).map { Self.offset(hotel, north: Double($0) * 10_000) }
        #expect(TripGeometryBuilder.simplified(line, coordinates: lineCoordinates, limit: 2).visits.map(\.place) == [0, 5])
        let significance = TripGeometryBuilder.significance(lineCoordinates.map(TripGeometryBuilder.UnitVector.init), depthLimit: 10)
        #expect(significance == [0, 0, 0, 0, 0, 0])
    }

    @Test func legsWithoutPhotos() throws {
        let day = MapFixture.date("2023-09-05")
        func photos(_ prefix: String, at place: GeoCoordinate, from hour: Double) -> [AssetFacts] {
            (0..<4).map { i in
                MapFixture.photo("\(prefix)-\(i)", at: day.addingTimeInterval(hour * 3_600 + Double(i) * 600), Fixture.jitter(place, seed: i, meters: 80),
                                 country: "PT")
            }
        }
        // One place from 09:00 to 09:30, the other from 15:30 to 16:00, single photos on the way
        // (no place, but evidence of the way) at `hours`.
        func trip(_ prefix: String, from a: GeoCoordinate, to b: GeoCoordinate, singlesAt hours: [Double]) -> TripGeometry {
            var facts = photos("\(prefix)-a", at: a, from: 9) + photos("\(prefix)-b", at: b, from: 15.5)
            for hour in hours {
                facts.append(MapFixture.photo("\(prefix)-on-\(hour)", at: day.addingTimeInterval(hour * 3_600), Self.along(a, b, (hour - 9.5) / 6),
                                              country: "PT"))
            }
            return Self.build(facts)
        }
        // Lisbon, then Madrid (about 500 km) six hours later, nothing in between.
        let gap = trip("gap", from: Places.lisbon, to: Self.madrid, singlesAt: [])
        #expect(gap.route.count == 2)
        #expect(abs(gap.legs[0].meters - 503_000) < 10_000)
        #expect(gap.legs[0].withoutPhotos)
        // A single photo every hour on the way: a solid line.
        let solid = trip("solid", from: Places.lisbon, to: Self.madrid, singlesAt: [10.5, 11.5, 12.5, 13.5, 14.5])
        #expect(solid.route.count == 2 && !solid.legs[0].withoutPhotos)
        // Exactly 3 hours without a photo is not longer than 3 hours; 3 hours and a minute is.
        let three = trip("three", from: Places.lisbon, to: Self.madrid, singlesAt: [12.5])
        #expect(three.route.count == 2 && !three.legs[0].withoutPhotos)
        let longer = trip("longer", from: Places.lisbon, to: Self.madrid, singlesAt: [12.5 + 1.0 / 60])
        #expect(longer.route.count == 2 && longer.legs[0].withoutPhotos)
        // 60 km and 6 hours: too short for "ohne Fotos".
        let near = trip("near", from: Places.munich, to: Self.augsburg, singlesAt: [])
        #expect(near.legs.count == 1 && near.legs[0].meters < 100_000 && !near.legs[0].withoutPhotos)
    }

    /// Two people's photos in one library (an iCloud Shared Library): one in Rome, one in Florence,
    /// taken in turn. From one to the other in minutes is faster than anything travels
    /// (`AirborneFilter.maximumFlightSpeed`): no zig-zag, one leg (review: 40 route points and
    /// 8,994 km "vor Ort" against 230 km). Real travel, by train or by plane, stays as it is.
    @Test func photosTakenAtTheSameTimeInTwoPlacesAreNoZigZag() throws {
        let palermo = MapFixture.at(38.1157, 13.3615)
        func photo(_ id: String, _ date: String, minutes: Double = 0, at place: GeoCoordinate, seed: Int) -> AssetFacts {
            let town = place == Places.rome ? "Roma" : place == Places.florence ? "Firenze" : "Palermo"
            return MapFixture.photo(id, at: MapFixture.date(date).addingTimeInterval(minutes * 60), Fixture.jitter(place, seed: seed, meters: 200),
                                    country: "IT", town: town, timeZone: "Europe/Rome")
        }
        /// `count` photos one every `minutes`, Rome and Florence in turn, Rome first.
        func inTurn(_ prefix: String, _ count: Int, every minutes: Double) -> [AssetFacts] {
            (0..<count).map { i in
                photo("\(prefix)-\(i)", "2023-05-02 08:00", minutes: Double(i) * minutes, at: i % 2 == 0 ? Places.rome : Places.florence, seed: i)
            }
        }
        let direct = GeoMath.distance(Places.rome, Places.florence)
        #expect(direct > 225_000 && direct < 235_000)

        // 20 photos each, every 5 minutes in turn.
        let shared = Self.build(inTurn("shared", 40, every: 5))
        #expect(shared.places.map(\.name) == ["Roma", "Firenze"])
        #expect(shared.places.map(\.photoCount) == [20, 20])
        #expect(shared.route.map(\.placeIndex) == [0, 1])
        #expect(shared.route[0].arrival <= shared.route[0].departure && shared.route[0].departure < shared.route[1].arrival)
        #expect(shared.legs.count == 1 && !shared.legs[0].withoutPhotos)
        #expect(abs(shared.metersOnSite - direct) < 2_000)
        for seed in 1...3 as ClosedRange<UInt64> {
            #expect(Self.build(Self.shuffled(inTurn("shared", 40, every: 5), seed: seed)) == shared)
        }
        // Whichever photo comes last: 21 in Rome give the same one leg.
        let odd = Self.build(inTurn("odd", 41, every: 5))
        #expect(odd.route.map(\.placeIndex) == [0, 1])
        #expect(abs(odd.metersOnSite - direct) < 2_000)

        // A day trip Rome → Florence → Rome, hours between: three route points.
        let dayTrip = Self.build((0..<4).map { photo("am-\($0)", "2023-05-03 07:00", minutes: Double($0) * 10, at: Places.rome, seed: $0) }
            + (0..<5).map { photo("flo-\($0)", "2023-05-03 11:00", minutes: Double($0) * 10, at: Places.florence, seed: $0) }
            + (0..<4).map { photo("pm-\($0)", "2023-05-03 18:00", minutes: Double($0) * 10, at: Places.rome, seed: $0 + 10) })
        #expect(dayTrip.route.map(\.placeIndex) == [0, 1, 0])
        #expect(abs(dayTrip.metersOnSite - 2 * direct) < 4_000)

        // A flight Rome → Palermo, an hour from the last photo in Rome to the first in Palermo:
        // faster than any train, but a plane flies it.
        let flight = Self.build((0..<3).map { photo("fco-\($0)", "2023-05-04 08:00", minutes: Double($0) * 10, at: Places.rome, seed: $0) }
            + (0..<3).map { photo("pmo-\($0)", "2023-05-04 09:20", minutes: Double($0) * 10, at: palermo, seed: $0) })
        #expect(flight.route.map(\.placeIndex) == [0, 1])
        let flown = GeoMath.distance(Places.rome, palermo)
        #expect(flown / 3_600 > AirborneFilter.maximumGroundSpeed)
        #expect(abs(flight.metersOnSite - flown) < 2_000)

        // Rome and Florence in turn every 2 hours: possible by train, so the route stays as it is.
        var turns: [AssetFacts] = []
        for k in 0..<6 {
            for i in 0..<3 {
                turns.append(photo("train-\(k)-\(i)", "2023-05-05 08:00", minutes: Double(k * 120 + i * 10),
                                   at: k % 2 == 0 ? Places.rome : Places.florence, seed: k * 3 + i))
            }
        }
        let byTrain = Self.build(turns)
        #expect(byTrain.route.map(\.placeIndex) == [0, 1, 0, 1, 0, 1])
        #expect(abs(byTrain.metersOnSite - 5 * direct) < 10_000)
    }

    /// Two people's photos in one library 41 km apart, an afternoon in Reykjavík and at Þingvellir:
    /// three photos at one, ten minutes later three at the other, in turn (review: 18 route points
    /// and 699 km "vor Ort", which "unterwegs" counts too). A plane could fly it, but nobody goes 41 km
    /// door to door in nine minutes on the ground, and each visit turns straight back: one leg.
    ///
    /// Whenever the second camera takes its photos (third review: it passed only while they came 7
    /// to 12 minutes after the first's; at the same minutes it was 18 route points and 699 km
    /// again): from Reykjavík there and back to it takes the round of 20 minutes, 82 km at some
    /// 260 km/h, however the round splits into the way there and the way back.
    @Test func twoCamerasFortyKilometresApartAreNoZigZag() {
        /// Three photos in Reykjavík every 20 minutes from 12:00, and three at Þingvellir `offset` after each.
        func cameras(offset: TimeInterval) -> [AssetFacts] {
            var photos: [AssetFacts] = []
            for round in 0..<9 {
                let t = MapFixture.date("2023-06-15 12:00").addingTimeInterval(Double(round) * 1_200)
                for k in 0..<3 {
                    photos.append(MapFixture.photo("a-\(round)-\(k)", at: t.addingTimeInterval(Double(k) * 20),
                                                   Fixture.jitter(Places.reykjavik, seed: k, meters: 50), country: "IS", town: "Reykjavík"))
                    photos.append(MapFixture.photo("b-\(round)-\(k)", at: t.addingTimeInterval(offset + Double(k) * 20),
                                                   Fixture.jitter(Places.thingvellir, seed: k, meters: 50), country: "IS", town: "Þingvellir"))
                }
            }
            return photos
        }
        let photos = cameras(offset: 600)
        let geometry = Self.build(photos, id: "iceland")
        #expect(geometry.route.count <= 3)
        #expect(geometry.metersOnSite < 100_000)
        // Each place once, at its first visit.
        #expect(geometry.places.map(\.name) == ["Reykjavík", "Þingvellir"])
        #expect(geometry.route.map(\.placeIndex) == [0, 1])
        #expect(geometry.route.map(\.arrival) == ["2023-06-15 12:00", "2023-06-15 12:10"].map(MapFixture.date))
        #expect(geometry.legs.count == 1 && !geometry.legs[0].withoutPhotos)
        #expect(abs(geometry.metersOnSite - GeoMath.distance(Places.reykjavik, Places.thingvellir)) < 500)
        for seed in 1...3 as ClosedRange<UInt64> {
            #expect(Self.build(Self.shuffled(photos, seed: seed), id: "iceland") == geometry)
        }
        for minutes in 0..<20 {
            let other = Self.build(cameras(offset: Double(minutes) * 60), id: "iceland")
            #expect(other.route.map(\.placeIndex) == [0, 1], "Þingvellir \(minutes) min after Reykjavík: \(other.route.count) route points")
            #expect(abs(other.metersOnSite - GeoMath.distance(Places.reykjavik, Places.thingvellir)) < 500,
                    "Þingvellir \(minutes) min after Reykjavík: \(Int(other.metersOnSite / 1_000)) km vor Ort")
        }
    }

    /// Three people's photos in one library in three places, each in turn every quarter of an hour
    /// for three hours: Reykjavík, Þingvellir (41 km) and a place 45 km south-east of Reykjavík
    /// (third review: 36 route points and 1,704 km "vor Ort"). Going round them takes the quarter
    /// of an hour, 160 km at some 650 km/h, with half a minute at each: no way anyone goes twice
    /// in a row. Each place once. Once round as fast, as by helicopter with two landings, is a way
    /// people go and stays as it is.
    ///
    /// Documented limit, measured: two people closer together or taking photos less often go
    /// there and back slower than `TripGeometryBuilder.turnBackSpeed`, at 130 to 170 km/h (41 km
    /// apart every 30 minutes, 20 km every 20, 10 km every 10, 5 km every 5), as a car on a
    /// motorway can, and still zig-zag: 16, 24, 48 and 96 route points in four hours, 459 to
    /// 614 km "vor Ort". The camera of each photo, stored by the analysis, would part their photos
    /// at any speed; it is not stored yet.
    @Test func threeCamerasInThreePlacesInTurnAreNoZigZag() {
        let south = Self.destination(from: Places.reykjavik, bearing: 160, meters: 45_000)
        let places = [(Places.reykjavik, "Reykjavík"), (Places.thingvellir, "Þingvellir"), (south, "Süden")]
        let round = GeoMath.distance(Places.reykjavik, Places.thingvellir) + GeoMath.distance(Places.thingvellir, south)
        // A turn every five minutes, two minutes after the one before, and all at the same
        // minutes (each in the order of the photos' names then: Reykjavík, Süden, Þingvellir).
        for (offset, way) in [(300.0, round), (120, round),
                              (0, GeoMath.distance(Places.reykjavik, south) + GeoMath.distance(south, Places.thingvellir))] {
            let geometry = Self.build(Self.inTurn(places, rounds: 12, period: 900, offset: offset), id: "iceland")
            #expect(geometry.route.map(\.placeIndex) == [0, 1, 2], "every \(Int(offset)) s: \(geometry.route.count) route points")
            #expect(abs(geometry.metersOnSite - way) < 1_000, "every \(Int(offset)) s: \(Int(geometry.metersOnSite / 1_000)) km vor Ort")
        }
        // Once round, ten minutes from one landing to the next (as fast, at 350 km/h): as it is.
        let back = (0..<3).map { k in
            MapFixture.photo("back-\(k)", at: MapFixture.date("2023-06-15 12:30").addingTimeInterval(Double(k) * 20),
                             Fixture.jitter(Places.reykjavik, seed: k, meters: 50), country: "IS", town: "Reykjavík")
        }
        let once = Self.build(Self.inTurn(places, rounds: 1, period: 1_800, offset: 600) + back, id: "iceland")
        #expect(once.route.map(\.placeIndex) == [0, 1, 2, 0])
        #expect(abs(once.metersOnSite - round - GeoMath.distance(south, Places.reykjavik)) < 1_000)
    }

    /// After an afternoon of photos in turn in Reykjavík and at Þingvellir (a run of visits joined
    /// by legs nobody went), the evening in Reykjavík and the next day in Vík. The leg on leaves
    /// the run from where its last photos were taken (review: when the one in Reykjavík took three
    /// more photos at 15:00, the evening's visit began inside the run and was left out as "its
    /// place once", and the route went on to Vík from Þingvellir, where nobody was any more;
    /// which camera took the afternoon's last photo decided it).
    @Test func afterAnAfternoonApartTheRouteGoesOnFromWhereTheLastPhotosWere() {
        let (reykjavik, thingvellir) = (Places.reykjavik, Places.thingvellir)
        func stop(_ prefix: String, at place: GeoCoordinate, town: String, from start: String, minutes: [Double]) -> [AssetFacts] {
            minutes.enumerated().map { k, m in
                MapFixture.photo("\(prefix)-\(k)", at: MapFixture.date(start).addingTimeInterval(m * 60), Fixture.jitter(place, seed: k, meters: 50),
                                 country: "IS", town: town)
            }
        }
        // 12:00 to 14:50: three photos in Reykjavík, ten minutes later three at Þingvellir, in turn.
        let afternoon = Self.inTurn([(reykjavik, "Reykjavík"), (thingvellir, "Þingvellir")], rounds: 9, period: 1_200)
        let more = stop("more", at: reykjavik, town: "Reykjavík", from: "2023-06-15 15:00", minutes: [0, 0.33, 0.67])
        let evening = stop("evening", at: reykjavik, town: "Reykjavík", from: "2023-06-15 18:00", minutes: [0, 30, 60, 180])
        let vik = stop("vik", at: Places.vik, town: "Vík", from: "2023-06-16 12:00", minutes: [0, 10, 20])
        let there = GeoMath.distance(reykjavik, thingvellir)
        for (name, photos) in [("the last photo at Þingvellir", afternoon + evening + vik), ("three more in Reykjavík", afternoon + more + evening + vik)] {
            let geometry = Self.build(photos, id: "iceland")
            #expect(geometry.route.map { geometry.places[$0.placeIndex].name ?? "?" } == ["Reykjavík", "Þingvellir", "Reykjavík", "Vík"], "\(name)")
            let km = (2 * there + GeoMath.distance(reykjavik, Places.vik)) / 1_000
            #expect(abs(geometry.metersOnSite / 1_000 - km) < 2, "\(name): \(Int(geometry.metersOnSite / 1_000)) km vor Ort, not \(Int(km))")
        }
    }

    /// The route turns back from a visit right away when it comes from a place and goes back to it,
    /// both legs faster than `TripGeometryBuilder.turnBackSpeed` (200 km/h as the crow flies, photo
    /// to photo), after at most `turnBackStay` (an hour) there. Once is a way people go; twice in a
    /// row is not: those legs join a run, as photos taken at the same time do.
    @Test func turningBackRightAwayTwiceInARowIsNoZigZag() {
        let a = Places.reykjavik, b = Places.thingvellir, c = Places.geysir, d = Places.vik
        /// Visits at `places` in turn from 08:00: three photos right at the place, the first and the
        /// last `stay` apart (`stays` by visit), then `leg` to the next.
        func inTurn(_ prefix: String, _ places: [GeoCoordinate], leg: TimeInterval, stay: TimeInterval = 40,
                    stays: [Int: TimeInterval] = [:]) -> [Int] {
            var facts: [AssetFacts] = []
            var start = MapFixture.date("2023-06-15 08:00")
            for (v, place) in places.enumerated() {
                let span = stays[v] ?? stay
                for k in 0..<3 {
                    facts.append(MapFixture.photo("\(prefix)-\(v)-\(k)", at: start.addingTimeInterval(span * Double(k) / 2), place, country: "IS"))
                }
                start = start.addingTimeInterval(span + leg)
            }
            return Self.build(facts).route.map(\.placeIndex)
        }
        let alternating = [a, b, a, b, a, b]
        // 41 km at exactly the speed take 12 minutes 21 seconds: from one to the other 2 % faster is
        // one leg, 2 % slower is as it is.
        let atTheSpeed = GeoMath.distance(a, b) / TripGeometryBuilder.turnBackSpeed
        #expect(abs(atTheSpeed - 741) < 1)
        #expect(inTurn("faster", alternating, leg: atTheSpeed * 0.98) == [0, 1])
        #expect(inTurn("slower", alternating, leg: atTheSpeed * 1.02) == [0, 1, 0, 1, 0, 1])
        // Ten minutes from one to the other: an hour at every place (first to last photo) is turning
        // back right away, an hour and a minute is not.
        #expect(inTurn("hour", alternating, leg: 600, stay: TripGeometryBuilder.turnBackStay) == [0, 1])
        #expect(inTurn("longer", alternating, leg: 600, stay: TripGeometryBuilder.turnBackStay + 60) == [0, 1, 0, 1, 0, 1])
        // Once is a way people go: a scenic flight, a high-speed train out and straight back.
        #expect(inTurn("once", [a, b, a], leg: 600) == [0, 1, 0])
        // Twice in a row: at two visits next to each other, ...
        #expect(inTurn("twice", [a, b, a, b], leg: 600) == [0, 1])
        // ... or with one between them, however long (one camera taking photos all day at one place,
        // the other now and then at another) ...
        #expect(inTurn("all-day", [a, b, a, b, a], leg: 600, stays: [0: 10_800, 2: 10_800, 4: 10_800]) == [0, 1])
        // ... or going on to another place (the other camera moving on): each place once.
        #expect(inTurn("moving-on", [a, b, a, c, a], leg: 600) == [0, 1, 2])
        // Two turns with two visits between them are not in a row: as it is.
        #expect(inTurn("apart", [a, b, a, c, d, c], leg: 600) == [0, 1, 0, 2, 3, 2])
        // Every leg of ten minutes here is faster than `turnBackSpeed`, none faster than a plane.
        for (p, q) in [(a, b), (a, c), (c, d)] {
            let speed = GeoMath.distance(p, q) / 600
            #expect(speed > TripGeometryBuilder.turnBackSpeed && speed < AirborneFilter.maximumFlightSpeed)
        }
    }

    /// Real ways there and back stay as they are: legs slower than `TripGeometryBuilder.turnBackSpeed`
    /// however often they turn back (a car, a ferry), faster ones turning back once at a time or
    /// after time spent at the far end (a high-speed train, a scenic flight, island hops by plane).
    @Test func realWaysThereAndBackStayAsTheyAre() {
        /// `count` photos at `place` from `start` (UTC), one every `minutes`.
        func stop(_ prefix: String, _ place: GeoCoordinate, _ start: String, count: Int = 3, minutes: Double = 10) -> [AssetFacts] {
            (0..<count).map { i in
                MapFixture.photo("\(prefix)-\(i)", at: MapFixture.date(start).addingTimeInterval(Double(i) * minutes * 60),
                                 Fixture.jitter(place, seed: i, meters: 80))
            }
        }
        /// From each stop to the next at another place: the speed from its last photo to the next one's first.
        func speeds(_ stops: [[AssetFacts]]) -> [Double] {
            zip(stops, stops.dropFirst()).compactMap { from, to in
                let a = from[from.count - 1].asset, b = to[0].asset
                let meters = GeoMath.distance(a.location!, b.location!)
                return meters > TripGeometry.placeRadiusMeters ? meters / b.creationDate!.timeIntervalSince(a.creationDate!) : nil
            }
        }
        func route(_ stops: [[AssetFacts]]) -> [Int] { Self.build(stops.flatMap { $0 }).route.map(\.placeIndex) }
        let fast = TripGeometryBuilder.turnBackSpeed

        // By car from the hotel in Vík to Skógafoss, back for something forgotten, to the waterfall
        // again and back: 28 km in 25 minutes, ten minutes at either end.
        let (vik, skogafoss) = (Places.vik, Places.skogafoss)
        let car = [stop("vik1", vik, "2023-06-17 09:00", minutes: 5), stop("skoga1", skogafoss, "2023-06-17 09:35", minutes: 5),
                   stop("vik2", vik, "2023-06-17 10:10", minutes: 5), stop("skoga2", skogafoss, "2023-06-17 10:45", minutes: 5),
                   stop("vik3", vik, "2023-06-17 11:20", minutes: 5)]
        #expect(speeds(car).count == 4 && speeds(car).allSatisfy { $0 < fast })
        #expect(route(car) == [0, 1, 0, 1, 0])
        // The ferry from Landeyjahöfn to Heimaey and back, twice: 12 km in 35 minutes.
        let landeyjahofn = MapFixture.at(63.5310, -20.1170), heimaey = MapFixture.at(63.4430, -20.2700)
        let ferry = [stop("land1", landeyjahofn, "2023-06-18 08:00"), stop("heim1", heimaey, "2023-06-18 08:55"),
                     stop("land2", landeyjahofn, "2023-06-18 09:50"), stop("heim2", heimaey, "2023-06-18 10:45"),
                     stop("land3", landeyjahofn, "2023-06-18 11:40")]
        #expect(speeds(ferry).count == 4 && speeds(ferry).allSatisfy { $0 < fast })
        #expect(route(ferry) == [0, 1, 0, 1, 0])

        // By high-speed train from Beijing to Tianjin, 108 km in half an hour platform to platform,
        // faster than `turnBackSpeed`: a day out with five hours there, ...
        let beijing = MapFixture.at(39.8652, 116.3786), tianjin = MapFixture.at(39.1365, 117.2098)
        let dayOut = [stop("bj-am", beijing, "2023-06-20 07:40"), stop("tj", tianjin, "2023-06-20 08:30", count: 6, minutes: 60),
                      stop("bj-pm", beijing, "2023-06-20 14:00")]
        #expect(speeds(dayOut).count == 2 && speeds(dayOut).allSatisfy { $0 > fast })
        #expect(route(dayOut) == [0, 1, 0])
        // ... out and straight back, twenty minutes at the station (turning back once), ...
        let straightBack = [stop("bj-out", beijing, "2023-06-21 07:40"), stop("tj-station", tianjin, "2023-06-21 08:30"),
                            stop("bj-back", beijing, "2023-06-21 09:20")]
        #expect(speeds(straightBack).count == 2 && speeds(straightBack).allSatisfy { $0 > fast })
        #expect(route(straightBack) == [0, 1, 0])
        // ... and three days in Beijing from a hotel in Tianjin, there and back every day.
        var commute: [[AssetFacts]] = []
        for day in 22...24 {
            commute += [stop("tj-am-\(day)", tianjin, "2023-06-\(day) 06:30"), stop("bj-\(day)", beijing, "2023-06-\(day) 07:20", count: 11, minutes: 60)]
            if day < 24 { commute.append(stop("tj-pm-\(day)", tianjin, "2023-06-\(day) 17:50")) }
        }
        #expect(speeds(commute).count == 5 && speeds(commute).allSatisfy { $0 > fast })
        #expect(route(commute) == [0, 1, 0, 1, 0, 1])

        // A scenic flight from Reykjavík (the last photo while taxiing) to Langjökull, 102 km in 26
        // minutes, ten minutes circling over the glacier and back (photos the airborne filter keeps:
        // a slow plane, circling): it turns back once.
        let langjokull = MapFixture.at(64.70, -20.25)
        let scenic = [stop("field-out", Places.reykjavik, "2023-06-19 09:57", minutes: 15), stop("glacier", langjokull, "2023-06-19 10:53", minutes: 5),
                      stop("field-back", Places.reykjavik, "2023-06-19 11:29")]
        #expect(speeds(scenic).count == 2 && speeds(scenic).allSatisfy { $0 > fast })
        #expect(route(scenic) == [0, 1, 0])

        // Island hops by plane from a hotel in Honolulu, 151 km to Maui and 173 km to Kauai in 40 and
        // 45 minutes gate to gate: a day on each, ...
        let honolulu = Places.honolulu, maui = MapFixture.at(20.8893, -156.4729), kauai = MapFixture.at(21.9811, -159.3711)
        let islands = [stop("hnl1", honolulu, "2023-07-01 07:40"), stop("maui", maui, "2023-07-01 08:40", count: 7, minutes: 60),
                       stop("hnl2", honolulu, "2023-07-01 15:20"), stop("hnl3", honolulu, "2023-07-02 07:35"),
                       stop("kauai", kauai, "2023-07-02 08:40", count: 7, minutes: 60), stop("hnl4", honolulu, "2023-07-02 15:25")]
        #expect(speeds(islands).count == 4 && speeds(islands).allSatisfy { $0 > fast })
        #expect(route(islands) == [0, 1, 0, 2, 0])
        // ... and from Maui to Kauai with forty minutes at Honolulu's airport between the flights.
        let hop = [stop("ogg", maui, "2023-07-05 07:40"), stop("hnl", honolulu, "2023-07-05 08:40", count: 5),
                   stop("lih", kauai, "2023-07-05 10:05")]
        #expect(speeds(hop).count == 2 && speeds(hop).allSatisfy { $0 > fast })
        #expect(route(hop) == [0, 1, 2])
    }

    /// "km vor Ort" are the legs between all route points, counted before the route is cut to
    /// `TripGeometry.maxRoutePoints` (review: a 360-place road trip showed 7,983 km against 8,872 km
    /// between all its day places). A leg of the cut route carries the legs it stands for.
    @Test func kilometresOnSiteCountEveryLegBeforeTheRouteIsCut() throws {
        // A year on the road: each day 25 km on to a new place, winding east (never more than 80°
        // off), and every 30th day 300 km in one go.
        var random = MapRandom(seed: 360)
        var position = Places.lisbon
        var facts: [AssetFacts] = []
        for d in 0..<360 {
            if d > 0 {
                let meters = d % 30 == 0 ? 300_000.0 : 25_000
                position = Self.destination(from: position, bearing: 90 + (random.unit() - 0.5) * 160, meters: meters)
            }
            let day = MapFixture.date("2023-01-01").addingTimeInterval(Double(d) * 86_400 + 10 * 3_600)
            for k in 0..<3 {
                facts.append(MapFixture.photo("road-\(d)-\(k)", at: day.addingTimeInterval(Double(k) * 600),
                                              Fixture.jitter(position, seed: d * 3 + k, meters: 100)))
            }
        }
        let geometry = Self.build(facts)
        #expect(geometry.places.count == 360)
        #expect(geometry.route.count <= TripGeometry.maxRoutePoints && geometry.route.count > 100)
        #expect(geometry.legs.count == geometry.route.count - 1)
        let places = geometry.places.map(\.coordinate)
        let everyLeg = zip(places, places.dropFirst()).reduce(0.0) { $0 + GeoMath.distance($1.0, $1.1) }
        #expect(everyLeg > 8_000_000)
        #expect(abs(geometry.metersOnSite - everyLeg) < 1)
        // The straight lines of the cut route are shorter (here by 193 km): what they leave out is
        // in their legs.
        let points = geometry.routeCoordinates
        let lines = zip(points, points.dropFirst()).reduce(0.0) { $0 + GeoMath.distance($1.0, $1.1) }
        #expect(lines < everyLeg - 150_000)
        #expect(zip(geometry.legs, zip(points, points.dropFirst())).allSatisfy { $0.meters >= GeoMath.distance($1.0, $1.1) - 1 })
    }

    /// A leg of the cut route stands for the legs from its first point up to the next point's
    /// first visit (those of an excursion the cut left out too): their metres added up, and
    /// "ohne Fotos" when most of those metres were.
    @Test func aLegOfTheCutRouteInheritsWhatMostOfItsMetresWere() {
        let legs = [RouteLeg(meters: 150_000, withoutPhotos: true), RouteLeg(meters: 20_000, withoutPhotos: false),
                    RouteLeg(meters: 30_000, withoutPhotos: false), RouteLeg(meters: 120_000, withoutPhotos: true),
                    RouteLeg(meters: 130_000, withoutPhotos: false)]
        // Six visits cut to points starting at the visits 0, 2 and 3, the last one up to visit 5:
        // 150 of the first leg's 170 km without photos, 120 of the second's 280 km.
        #expect(TripGeometryBuilder.cutLegs(legs, startingAt: [0, 2, 3])
                == [RouteLeg(meters: 170_000, withoutPhotos: true), RouteLeg(meters: 280_000, withoutPhotos: false)])
        // Two points: one leg for all of them, 270 of its 450 km without photos.
        #expect(TripGeometryBuilder.cutLegs(legs, startingAt: [0, 4]) == [RouteLeg(meters: 450_000, withoutPhotos: true)])
        // Exactly half is not most.
        let half = [RouteLeg(meters: 100_000, withoutPhotos: true), RouteLeg(meters: 100_000, withoutPhotos: false)]
        #expect(TripGeometryBuilder.cutLegs(half, startingAt: [0, 2]) == [RouteLeg(meters: 200_000, withoutPhotos: false)])
        // Nothing cut: the legs as they are.
        #expect(TripGeometryBuilder.cutLegs(legs, startingAt: [0, 1, 2, 3, 4, 5]) == legs)
    }

    /// The point `fraction` of the way from `a` to `b` on the great circle.
    static func along(_ a: GeoCoordinate, _ b: GeoCoordinate, _ fraction: Double) -> GeoCoordinate {
        AirborneFilterTests.along(a, b, fraction)
    }

    // MARK: Across the antimeridian, the date line and near the pole

    @Test func aTripAcrossTheAntimeridian() throws {
        // Suva (Fiji) and Apia (Samoa): about 1,150 km, not 39,000 km round the other way.
        let fijiSamoa = MapFixture.burst("suva", count: 5, at: Places.suva, day: "2023-09-10", hour: 1, country: "FJ", town: "Suva",
                                         timeZone: "Pacific/Fiji")
            + MapFixture.burst("apia", count: 5, at: Places.apia, day: "2023-09-11", hour: 3, country: "WS", town: "Apia", timeZone: "Pacific/Apia")
        let geometry = Self.build(fijiSamoa)
        #expect(geometry.places.map(\.name) == ["Suva", "Apia"])
        #expect(geometry.legs.count == 1)
        #expect(abs(geometry.legs[0].meters - 1_150_000) < 25_000)
        #expect(geometry.legs[0].withoutPhotos)
        // As many photos in Fiji as in Samoa: the smaller key; the zone too.
        #expect(geometry.countryPhotos == ["FJ": 5, "WS": 5])
        #expect(geometry.mainCountryKey == "FJ")
        #expect(geometry.timeZoneIdentifier == "Pacific/Apia")
        #expect(geometry.destinationIndex == 0)

        // A day on Taveuni with photos on both sides of 180°, 600 m apart: one place.
        let taveuni = (0..<6).map { i in
            MapFixture.photo("taveuni-\(i)", at: MapFixture.date("2023-09-12 22:00").addingTimeInterval(Double(i) * 600),
                             MapFixture.at(-16.85, i % 2 == 0 ? 179.997 : -179.997), country: "FJ", town: "Somosomo", timeZone: "Pacific/Fiji")
        }
        let island = Self.build(taveuni)
        #expect(island.dayPlaces.count == 1 && island.places.count == 1)
        #expect(taveuni.contains { $0.asset.location == island.places[0].coordinate })
    }

    @Test func aPhotoAtHalfPastElevenUTCInTokyoCountsOnTheNextDay() throws {
        // 23:00 to 23:30 UTC on the 14th is 08:00 to 08:30 on the 15th in Tokyo; the device is on UTC.
        let tokyo = MapFixture.burst("tokyo", count: 4, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo",
                                     timeZone: "Asia/Tokyo")
        let unlocated = MapFixture.photo("no-place", at: MapFixture.date("2023-06-14 23:30"), nil)
        let geometry = Self.build(tokyo + [unlocated], timeZone: MapFixture.utc)
        #expect(geometry.timeZoneIdentifier == "Asia/Tokyo")
        // The photo without a place counts in the trip's zone, not the device's: the trip has one
        // day. Photos per day are those on the map.
        #expect(geometry.firstDay == Self.day("2023-06-15") && geometry.lastDay == Self.day("2023-06-15"))
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.dayPlaces.map(\.day) == [Self.day("2023-06-15")])
        #expect(geometry.route.map(\.day) == [Self.day("2023-06-15")])
    }

    /// A photo's day is the day on the clock where it was taken, as the app's albums count it
    /// (`AssetFacts.timeZone`, review P1-15): it wins over its place's zone and the trip's.
    @Test func theClockWhereAPhotoWasTakenDecidesItsDay() throws {
        // Offline places name no zone; the analysis gave each photo Tokyo's clock from its country.
        let tokyo = MapFixture.burst("tokyo", count: 4, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo")
            .map { fact -> AssetFacts in var fact = fact; fact.timeZone = TimeZone(identifier: "Asia/Tokyo"); return fact }
        var unlocated = MapFixture.photo("no-place", at: MapFixture.date("2023-06-14 23:30"), nil)
        unlocated.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let geometry = Self.build(tokyo + [unlocated], timeZone: MapFixture.utc)
        #expect(geometry.timeZoneIdentifier == "Asia/Tokyo")
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.firstDay == Self.day("2023-06-15") && geometry.lastDay == Self.day("2023-06-15"))
        #expect(geometry.dayPlaces.map(\.day) == [Self.day("2023-06-15")])
        // The clock wins over a place's zone that says otherwise.
        let mixed = MapFixture.burst("utc", count: 3, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo",
                                     timeZone: "UTC")
            .map { fact -> AssetFacts in var fact = fact; fact.timeZone = TimeZone(identifier: "Asia/Tokyo"); return fact }
        #expect(Self.build(mixed, timeZone: MapFixture.utc).firstDay == Self.day("2023-06-15"))
    }

    @Test func placesAreNumberedInTimeOrderAcrossTheDateLine() throws {
        // Tokyo on the morning of the 15th (local), then Honolulu on the evening of the 14th
        // (local): later in time, earlier by the calendar.
        let tokyo = MapFixture.burst("tokyo", count: 4, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo",
                                     timeZone: "Asia/Tokyo")
        let honolulu = MapFixture.burst("honolulu", count: 4, at: Places.honolulu, day: "2023-06-15", hour: 6, country: "US", town: "Honolulu",
                                        timeZone: "Pacific/Honolulu")
        let geometry = Self.build(honolulu + tokyo)
        #expect(geometry.places.map(\.name) == ["Tokyo", "Honolulu"])
        #expect(geometry.dayPlaces.map(\.day) == [Self.day("2023-06-15"), Self.day("2023-06-14")])
        #expect(geometry.route.map(\.placeIndex) == [0, 1])
        #expect(geometry.route.map(\.day) == [Self.day("2023-06-15"), Self.day("2023-06-14")])
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-14"), photoCount: 4, placeIndex: 1),
                                       TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.firstDay == Self.day("2023-06-14") && geometry.lastDay == Self.day("2023-06-15"))
        // As many photos at both: the earlier first day wins, though Honolulu came second.
        #expect(geometry.destinationIndex == 1)
        #expect(geometry.legs.count == 1 && geometry.legs[0].withoutPhotos && geometry.legs[0].meters > 6_000_000)
        #expect(geometry.timeZoneIdentifier == "Asia/Tokyo")
    }

    @Test func svalbardAndTheNorthPole() throws {
        // Longyearbyen (78° N) with a walk 2.5 km across town, Pyramiden by boat, Barentsburg, and
        // a day at the North Pole whose photos lie on all sides of it.
        let zone = "Arctic/Longyearbyen"
        let walk = (0..<6).map { i in
            MapFixture.photo("lyr-\(i)", at: MapFixture.date("2023-07-10 10:00").addingTimeInterval(Double(i) * 1_200),
                             Self.offset(Places.longyearbyen, east: Double(i) * 500), country: "SJ", town: "Longyearbyen", timeZone: zone)
        }
        let pole = [0.0, 90, 180, -90].enumerated().map { i, longitude in
            MapFixture.photo("pole-\(i)", at: MapFixture.date("2023-07-14 12:00").addingTimeInterval(Double(i) * 300), MapFixture.at(89.99, longitude),
                             timeZone: zone)
        }
        let facts = walk
            + MapFixture.burst("pyr", count: 5, at: Self.pyramiden, day: "2023-07-11", hour: 11, country: "SJ", town: "Pyramiden", timeZone: zone)
            + MapFixture.burst("lyr-eve", count: 3, at: Places.longyearbyen, day: "2023-07-11", hour: 20, country: "SJ", town: "Longyearbyen", timeZone: zone)
            + MapFixture.burst("bar", count: 4, at: Self.barentsburg, day: "2023-07-12", hour: 11, country: "SJ", town: "Barentsburg", timeZone: zone)
            + MapFixture.burst("lyr-end", count: 5, at: Places.longyearbyen, day: "2023-07-13", hour: 9, country: "SJ", town: "Longyearbyen", timeZone: zone)
            + pole
        let geometry = Self.build(facts)
        #expect(geometry.places.map(\.name) == ["Longyearbyen", "Pyramiden", "Barentsburg", nil])
        #expect(geometry.places.map(\.photoCount) == [14, 5, 4, 4])
        #expect(geometry.route.map(\.placeIndex) == [0, 1, 0, 2, 0, 3])
        let kilometres = geometry.legs.map { Int(($0.meters / 1_000).rounded()) }
        #expect(kilometres[0] >= 48 && kilometres[0] <= 54 && kilometres[1] == kilometres[0])
        #expect(kilometres[2] >= 34 && kilometres[2] <= 40 && kilometres[3] == kilometres[2])
        #expect(kilometres[4] >= 1_300 && kilometres[4] <= 1_320)
        #expect(geometry.legs.map(\.withoutPhotos) == [false, false, false, false, true])
        #expect(geometry.destinationIndex == 0)
        #expect(geometry.countryPhotos == ["SJ": 23])
        #expect(geometry.places[3].countryKey == nil)
        #expect(pole.contains { $0.asset.location == geometry.places[3].coordinate })
    }

    // MARK: Countries, photos left out, photos per day

    @Test func photosInFlightAreLeftOutAndCounted() throws {
        // Lisbon days, and on the way there three window photos over France seconds apart and
        // two over Spain: without the filter they would make a place and two countries.
        let lisbon = MapFixture.burst("lis", count: 6, at: Places.lisbon, day: "2023-06-15", hour: 10, country: "PT", town: "Lisboa")
        let overFrance = MapFixture.at(45.0, 1.0)
        let window = (0..<3).map { i in
            MapFixture.photo("fr-\(i)", at: MapFixture.date("2023-06-14 15:00").addingTimeInterval(Double(i) * 4),
                             Self.offset(overFrance, east: Double(i) * 900), country: "FR", town: "Brive")
        } + (0..<2).map { i in
            MapFixture.photo("es-\(i)", at: MapFixture.date("2023-06-14 15:40").addingTimeInterval(Double(i) * 600),
                             Self.offset(MapFixture.at(41.5, -4.0), east: Double(i) * -120_000), country: "ES")
        }
        let airborne = Set(window.map(\.id))
        let geometry = Self.build(lisbon + window, airborne: airborne)
        #expect(geometry.places.map(\.name) == ["Lisboa"])
        #expect(geometry.countryPhotos == ["PT": 6])
        #expect(geometry.airborneCount == 5)
        #expect(geometry.photoCount == 11)
        // They are photos of the trip and their day is one of its days, but no photos of a day on
        // the map ("Meiste Fotos an einem Tag").
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 6, placeIndex: 0)])
        #expect(geometry.firstDay == Self.day("2023-06-14") && geometry.days == 2)
        let unfiltered = Self.build(lisbon + window)
        #expect(unfiltered.places.map(\.name) == ["Brive", "Lisboa"])
        #expect(unfiltered.countryPhotos == ["PT": 6, "FR": 3, "ES": 2])
        #expect(unfiltered.airborneCount == 0)
    }

    @Test func photosWithoutLocationOrDateCountOnlyInTheAlbum() throws {
        let lisbon = MapFixture.burst("lis", count: 4, at: Places.lisbon, day: "2023-06-15", hour: 10, country: "PT", town: "Lisboa",
                                      timeZone: "Europe/Lisbon")
        var undated = MapFixture.photo("undated", at: MapFixture.date("2023-06-15 11:00"), Places.lisbon, country: "PT", town: "Lisboa")
        undated.asset.creationDate = nil
        var screenshot = MapFixture.photo("screenshot", at: MapFixture.date("2023-06-15 12:00"), Places.lisbon, country: "PT")
        screenshot.asset.subtypes = .screenshot
        var vague = MapFixture.photo("vague", at: MapFixture.date("2023-06-15 12:30"), Places.lisbon, country: "PT")
        vague.asset.locationAccuracy = 8_000
        let others = [
            MapFixture.photo("unlocated-1", at: MapFixture.date("2023-06-15 23:30"), nil),
            MapFixture.photo("unlocated-2", at: MapFixture.date("2023-06-17 09:00"), nil),
            undated, screenshot, vague,
        ]
        let geometry = Self.build(lisbon + others)
        #expect(geometry.photoCount == 9)
        #expect(geometry.countryPhotos == ["PT": 4])
        #expect(geometry.places.map(\.photoCount) == [4])
        // Photos per day are those on the map; the trip's days are those of all its dated photos.
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.lastDay == Self.day("2023-06-17"))
        #expect(geometry.end == MapFixture.date("2023-06-17 09:00"))
        // 23:30 UTC is the 16th in Lisbon (summer time), the trip's zone: a trip ending then has
        // two days.
        let late = Self.build(lisbon + [others[0]])
        #expect(late.lastDay == Self.day("2023-06-16") && late.days == 2)
    }

    /// "Meiste Fotos an einem Tag" (concept §5; review: it counted screenshots, photos in flight
    /// and photos without a place): a day counts the trip's photos on the map, nothing else. The
    /// album (`photoCount`) and the trip's days (`firstDay` to `lastDay`) still hold them all.
    @Test func photosPerDayAreThePhotosOnTheMap() throws {
        let lisbon = MapFixture.burst("lis", count: 6, at: Places.lisbon, day: "2023-06-15", hour: 10, country: "PT", town: "Lisboa",
                                      timeZone: "Europe/Lisbon")
        var screenshot = MapFixture.photo("shot", at: MapFixture.date("2023-06-15 12:00"), Places.lisbon, country: "PT", timeZone: "Europe/Lisbon")
        screenshot.asset.subtypes = .screenshot
        let window = (0..<3).map { i in
            MapFixture.photo("window-\(i)", at: MapFixture.date("2023-06-14 15:00").addingTimeInterval(Double(i) * 600),
                             MapFixture.at(44.0 - Double(i), -2.0 - Double(i)), country: "ES")
        }
        let packing = (0..<3).map { i in
            MapFixture.photo("packing-\(i)", at: MapFixture.date("2023-06-13 18:00").addingTimeInterval(Double(i) * 600), Places.regensburg,
                             country: "DE", timeZone: "Europe/Berlin", atHome: true)
        }
        let unlocated = MapFixture.photo("unlocated", at: MapFixture.date("2023-06-16 09:00"), nil)
        let geometry = Self.build(lisbon + [screenshot] + window + packing + [unlocated], airborne: Set(window.map(\.id)))
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 6, placeIndex: 0)])
        #expect(geometry.photoCount == 14)
        #expect(geometry.firstDay == Self.day("2023-06-13") && geometry.lastDay == Self.day("2023-06-16") && geometry.days == 4)
    }

    // MARK: Photos at home, a photo listed twice

    /// Concept §8: everyday photos at home never appear on the map. A photo marked at home is never
    /// drawn, even when it carries the trip's id (review: four packing photos at the exact home made
    /// a place, a pin and the first route point there; the trip detection should not put them in a
    /// trip, but the map does not rely on it): no day place, place, route point, destination, cover
    /// or country. The album still shows it.
    @Test func photosAtHomeAreNeverDrawn() throws {
        let home = Places.regensburg, station = MapFixture.at(49.0118, 12.0997)
        // The evening before: four favourite photos of the packing at the exact home, and three at
        // the station 230 m away, which are not at home.
        let packing = (0..<4).map { i in
            MapFixture.photo("pack-\(i)", at: MapFixture.date("2023-04-09 17:00").addingTimeInterval(Double(i) * 300), home, country: "DE",
                             town: "Regensburg", timeZone: "Europe/Berlin", atHome: true, favorite: true)
        }
        let train = MapFixture.burst("station", count: 3, at: station, day: "2023-04-09", hour: 18, jitterMeters: 30, country: "DE",
                                     town: "Regensburg", timeZone: "Europe/Berlin")
        let lisbon = MapFixture.burst("lis", count: 5, at: Places.lisbon, day: "2023-04-10", country: "PT", town: "Lisboa", timeZone: "Europe/Lisbon")
            + MapFixture.burst("lis2", count: 5, at: Places.lisbon, day: "2023-04-11", country: "PT", town: "Lisboa", timeZone: "Europe/Lisbon")
        let geometry = Self.build(packing + train + lisbon)
        #expect(geometry.photoCount == 17)
        #expect(geometry.places.map(\.name) == ["Regensburg", "Lisboa"])
        #expect(geometry.places.map(\.photoCount) == [3, 10])
        #expect(geometry.places[0].coverCandidates == ["station-0", "station-1", "station-2"])
        #expect(train.contains { $0.asset.location == geometry.places[0].coordinate })
        #expect(geometry.dayPlaces.map(\.photoCount) == [3, 5, 5])
        #expect(geometry.route.map(\.placeIndex) == [0, 1])
        #expect(geometry.destinationIndex == 1 && geometry.destination == geometry.places[1].coordinate)
        #expect(geometry.countryPhotos == ["DE": 3, "PT": 10])
        #expect(geometry.dayCounts.map(\.photoCount) == [3, 5, 5])
        let points = geometry.places.map(\.coordinate) + geometry.dayPlaces.map(\.coordinate) + geometry.routeCoordinates + [geometry.destination]
        #expect(points.allSatisfy { GeoMath.distance($0, home) > 150 })
        // The album shows them: the trip starts with them.
        #expect(geometry.start == MapFixture.date("2023-04-09 17:00") && geometry.firstDay == Self.day("2023-04-09"))

        // Without a place, the destination is where the photos on the map gather, never home.
        let fewer = Self.build(packing + lisbon.prefix(2))
        #expect(fewer.places.isEmpty && fewer.route.isEmpty)
        #expect(lisbon.prefix(2).contains { $0.asset.location == fewer.destination })
        // Only photos at home: nothing on the map, and the trip's centre (here home) is not taken
        // either: the destination is no place on Earth.
        let onlyHome = Self.build(packing)
        #expect(onlyHome.photoCount == 4 && onlyHome.dayPlaces.isEmpty && onlyHome.places.isEmpty && onlyHome.route.isEmpty)
        #expect(onlyHome.dayCounts.isEmpty && onlyHome.countryPhotos.isEmpty && onlyHome.mainCountryKey == nil)
        #expect(!onlyHome.destination.isPlausible)
    }

    /// A library listing one photo twice or three times counts it once (concept §5: a single wrong
    /// photo makes no place, no record and no country; review: one Longyearbyen photo three times
    /// made a place and "Nördlichster Ort"). Two facts of one photo that differ (two states of the
    /// analysis) give one, the same in any order; one at home wins.
    @Test func onePhotoListedThreeTimesCountsOnce() throws {
        let oslo = MapFixture.at(59.9139, 10.7522), bergen = MapFixture.at(60.3913, 5.3221)
        let city = MapFixture.burst("osl", count: 5, at: oslo, day: "2023-07-09", country: "NO", town: "Oslo", timeZone: "Europe/Oslo")
        let lyr = MapFixture.photo("lyr", at: MapFixture.date("2023-07-10 12:00"), Places.longyearbyen, country: "SJ", town: "Longyearbyen",
                                   timeZone: "Arctic/Longyearbyen")
        let window = MapFixture.photo("window", at: MapFixture.date("2023-07-10 09:00"), MapFixture.at(70, 15), country: "NO")
        let geometry = Self.build(city + [lyr, lyr, lyr, window, window], airborne: [window.id])
        #expect(geometry.photoCount == 7)
        #expect(geometry.airborneCount == 1)
        #expect(geometry.places.map(\.name) == ["Oslo"])
        #expect(geometry.countryPhotos == ["NO": 5, "SJ": 1])
        #expect(geometry.dayCounts.map(\.photoCount) == [5, 1])

        let here = MapFixture.photo("twin", at: MapFixture.date("2023-07-09 12:00"), oslo, country: "NO", town: "Oslo", timeZone: "Europe/Oslo")
        var there = MapFixture.photo("twin", at: MapFixture.date("2023-07-09 12:00"), bergen, country: "NO", town: "Bergen", timeZone: "Europe/Oslo")
        there.asset.isFavorite = true
        var atHome = here
        atHome.atHome = true
        for pair in [[here, there], [here, atHome], [there, atHome]] {
            let one = Self.build(city + pair), other = Self.build(pair.reversed() + city)
            #expect(one == other)
            #expect(one.photoCount == 6)
            #expect(one.countryPhotos.values.reduce(0, +) <= 6)
        }
        // The copy at home wins: the photo is not on the map.
        #expect(Self.build(city + [atHome, there]).countryPhotos == ["NO": 5])
    }

    @Test func countriesAndDisputedAreas() throws {
        let taipei = MapFixture.at(25.0330, 121.5654)
        var facts = MapFixture.burst("tpe", count: 5, at: taipei, day: "2023-10-01", hour: 2, town: "Taipei", timeZone: "Asia/Taipei")
        for i in facts.indices {
            facts[i].place = PlaceComponents(country: "Taiwan", locality: "Taipei", timeZoneIdentifier: "Asia/Taipei", disputedArea: "taiwan")
            facts[i].placeSource = .gpsReverseGeocoded
        }
        facts += MapFixture.burst("tyo", count: 3, at: Places.tokyo, day: "2023-10-03", hour: 2, country: "JP", town: "Tokyo", timeZone: "Asia/Tokyo")
        // Content-inferred places are no GPS places: no country, no name.
        var guessed = MapFixture.burst("guess", count: 3, at: MapFixture.at(35.0116, 135.7681), day: "2023-10-04", hour: 2, country: "JP",
                                       town: "Kyoto")
        for i in guessed.indices { guessed[i].placeSource = .contentInferred }
        let geometry = Self.build(facts + guessed)
        #expect(geometry.countryPhotos == ["disputed-taiwan": 5, "JP": 3])
        #expect(geometry.mainCountryKey == "disputed-taiwan")
        #expect(geometry.places.map(\.countryKey) == ["disputed-taiwan", "JP", nil])
        #expect(geometry.places.map(\.name) == ["Taipei", "Tokyo", nil])
        #expect(geometry.timeZoneIdentifier == "Asia/Taipei")
    }

    // MARK: Names, photos and altitude of a place

    @Test func placeNames() throws {
        func name(_ components: [PlaceComponents?]) -> String? {
            let facts = components.enumerated().map { i, place in
                var fact = MapFixture.photo("n-\(i)", at: MapFixture.date("2023-08-01 10:00").addingTimeInterval(Double(i) * 60),
                                            Fixture.jitter(Places.florence, seed: i, meters: 200))
                fact.place = place
                fact.placeSource = place == nil ? nil : .gpsReverseGeocoded
                return fact
            }
            return Self.build(facts).places.first?.name
        }
        let uffizi = PlaceComponents(isoCountryCode: "IT", country: "Italia", administrativeArea: "Toscana", subAdministrativeArea: "Firenze",
                                     locality: "Firenze", areaOfInterest: "Uffizi")
        let town = PlaceComponents(isoCountryCode: "IT", country: "Italia", administrativeArea: "Toscana", subAdministrativeArea: "Firenze",
                                   locality: "Firenze")
        // A point of interest naming half the photos names the place; fewer, the town.
        #expect(name([uffizi, uffizi, town, town]) == "Uffizi")
        #expect(name([uffizi, town, town, town]) == "Firenze")
        // Photos not geocoded yet count against the point of interest.
        #expect(name([uffizi, uffizi, nil, nil, nil]) == "Firenze")
        // Without a town the district, then the region, then the country.
        #expect(name([PlaceComponents(country: "Italia", administrativeArea: "Toscana", subAdministrativeArea: "Chianti")] + Array(repeating: nil, count: 3))
                == "Chianti")
        #expect(name(Array(repeating: PlaceComponents(country: "Italia", administrativeArea: "Toscana"), count: 3)) == "Toscana")
        #expect(name(Array(repeating: PlaceComponents(isoCountryCode: "IT", country: "Italia"), count: 3)) == "Italia")
        // Ties alphabetically; empty names are no names.
        let fiesole = PlaceComponents(isoCountryCode: "IT", locality: "Fiesole"), empty = PlaceComponents(isoCountryCode: "IT", locality: "")
        #expect(name([town, fiesole, town, fiesole, empty, empty, empty]) == "Fiesole")
        #expect(name([nil, nil, nil]) == nil)
    }

    @Test func coverCandidatesAreAnalysedPhotosFavouritesFirstThenTheLargest() throws {
        let start = MapFixture.date("2023-08-02 10:00")
        func photo(_ id: String, _ i: Int, favorite: Bool = false, pixels: (Int, Int) = (4032, 3024), kind: MediaKind = .image,
                   analysed: Bool = true, document: Bool = false) -> AssetFacts {
            var fact = MapFixture.photo(id, at: start.addingTimeInterval(Double(i) * 60), Fixture.jitter(Places.porto, seed: i, meters: 200),
                                        country: "PT", town: "Porto", favorite: favorite, analysed: analysed, kind: kind)
            fact.asset.pixelWidth = pixels.0
            fact.asset.pixelHeight = pixels.1
            fact.looksLikeDocument = document
            return fact
        }
        let facts = [
            photo("a-small", 0, pixels: (1000, 1000)), photo("b-large", 1, pixels: (8000, 6000)), photo("c-fav-small", 2, favorite: true, pixels: (800, 600)),
            photo("d-fav-large", 3, favorite: true), photo("e-video", 4, favorite: true, kind: .video), photo("f-unknown", 5, favorite: true, analysed: false),
            photo("g-document", 6, favorite: true, document: true), photo("h-same", 7), photo("i-same", 8), photo("j-same", 9),
        ]
        let place = try #require(Self.build(Self.shuffled(facts, seed: 9)).places.first)
        #expect(place.photoCount == 10)
        #expect(place.coverCandidates == ["d-fav-large", "c-fav-small", "b-large", "h-same", "i-same", "j-same"])

        // Only ordinary photos: the six largest. An id given twice is one photo, with the facts
        // `isKept(_:over:)` prefers whatever their order: "o2" again, later and as a favourite, is
        // the same photo in another state, and the facts kept (the earlier, no favourite) decide.
        let ordinary = (0..<9).map { photo("o\($0)", $0, pixels: (1_000 + $0 * 100, 1_000)) }
        let again = [photo("o8", 9, pixels: (1_800, 1_000)), photo("o2", 10, favorite: true, pixels: (1_200, 1_000))]
        #expect(!TripGeometryBuilder.isKept(again[1], over: ordinary[2]) && TripGeometryBuilder.isKept(ordinary[2], over: again[1]))
        for seed in [1, 2, 3] as [UInt64] {
            let best = try #require(Self.build(Self.shuffled(ordinary + again, seed: seed)).places.first)
            #expect(best.photoCount == 9)
            #expect(best.coverCandidates == ["o8", "o7", "o6", "o5", "o4", "o3"])
        }
    }

    @Test func coverPickerGivesWhatSortingGives() {
        // One pass keeping the best six gives the first six ids of all of them sorted, an id that
        // comes again (with another rank) taken once.
        var random = MapRandom(seed: 6)
        for _ in 0..<300 {
            let covers = (0..<random.int(0..<30)).compactMap { i -> TripGeometryBuilder.Cover? in
                var fact = MapFixture.photo("p\(random.int(0..<12))", at: MapFixture.date("2023-08-02 10:00"), Places.porto,
                                            favorite: random.int(0..<3) == 0)
                fact.asset.pixelWidth = 100 * random.int(1..<4)
                return TripGeometryBuilder.Cover(fact, at: i)
            }
            var picker = TripGeometryBuilder.CoverPicker(limit: TripGeometry.coverCandidateLimit)
            for cover in covers { picker.add(cover) }
            var expected: [AssetID] = []
            for cover in covers.sorted(by: { $0.ranks(before: $1) })
            where expected.count < TripGeometry.coverCandidateLimit && !expected.contains(cover.id) {
                expected.append(cover.id)
            }
            #expect(picker.ids == expected)
        }
    }

    @Test func placeAltitude() throws {
        func altitude(_ values: [Double?], at place: GeoCoordinate) -> Double? {
            let facts = values.enumerated().map { i, _ in
                MapFixture.photo("alt-\(i)", at: MapFixture.date("2023-08-03 09:00").addingTimeInterval(Double(i) * 600),
                                 Fixture.jitter(place, seed: i, meters: 300), country: "CH")
            }
            var altitudes: [AssetID: Double] = [:]
            for (i, value) in values.enumerated() { altitudes[facts[i].id] = value }
            return Self.build(facts, altitudes: altitudes).places.first?.altitude
        }
        let zermatt = MapFixture.at(46.0207, 7.7491)
        // Three agreeing: their mean.
        #expect(altitude([1_600, 1_620, 1_640], at: zermatt) == 1_620)
        // 150 m apart still agree, 400 m do not.
        #expect(altitude([1_600, 1_675, 1_750], at: zermatt) == 1_675)
        #expect(altitude([1_400, 1_600, 1_800], at: zermatt) == nil)
        // Only scattered altitudes, no three within 150 m: none.
        #expect(altitude([1_000, 1_200, 1_400, 1_600, 1_800, 2_000], at: zermatt) == nil)
        // One above 6,000 m (a plane's, if not filtered) does not count; the others do.
        #expect(altitude([1_600, 1_620, 7_000], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, 1_640, 7_000], at: zermatt) == 1_620)
        // A cable car from the valley to the top within the place's 3 km: the highest group.
        #expect(altitude([1_610, 1_600, 3_100, 1_620, 3_050, 3_000, 2_400], at: zermatt) == 3_050)
        // Fewer than three photos with an altitude: none; one that is no number does not count.
        #expect(altitude([1_600, 1_620, nil, nil, nil], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, .nan], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, 1_610, .nan], at: zermatt) == 1_610)
        // Below sea level is fine (the Dead Sea shore).
        #expect(altitude([-420, -415, -410], at: MapFixture.at(31.5590, 35.4732)) == -415)
    }

    /// "Höchstes Foto" (concept §5): the mean of the highest group of at least three photos of a
    /// place whose altitudes lie within `TripGeometry.altitudeSpreadMeters` of each other (review:
    /// summit photos from 2,600 to 2,962 m got no altitude, and the record went to a lake at 600 m).
    @Test func aSummitKeepsItsAltitude() throws {
        // The Eibsee one day; the next, the Zugspitze: the glacier at 2,600 m, the way up, the
        // summit at 2,962 m, all within 1.5 km.
        let lake = MapFixture.at(47.4571, 10.9813), summit = MapFixture.at(47.4211, 10.9853)
        let lakeAltitudes = [600.0, 602, 598, 601]
        let summitAltitudes = [2_600.0, 2_650, 2_700, 2_780, 2_870, 2_930, 2_945, 2_955, 2_962]
        let photos = lakeAltitudes.indices.map { i in
            MapFixture.photo("lake-\(i)", at: MapFixture.date("2023-08-04 10:00").addingTimeInterval(Double(i) * 600),
                             Fixture.jitter(lake, seed: i, meters: 300), country: "DE", town: "Eibsee", timeZone: "Europe/Berlin")
        } + summitAltitudes.indices.map { i in
            let below = Double(summitAltitudes.count - 1 - i)
            return MapFixture.photo("top-\(i)", at: MapFixture.date("2023-08-05 09:00").addingTimeInterval(Double(i) * 600),
                                    Self.offset(summit, east: -below * 150, north: -below * 100), country: "DE", town: "Zugspitze",
                                    timeZone: "Europe/Berlin")
        }
        var altitudes: [AssetID: Double] = [:]
        for (i, value) in lakeAltitudes.enumerated() { altitudes[AssetID("lake-\(i)")] = value }
        for (i, value) in summitAltitudes.enumerated() { altitudes[AssetID("top-\(i)")] = value }
        let geometry = Self.build(photos, altitudes: altitudes)
        #expect(geometry.places.map(\.name) == ["Eibsee", "Zugspitze"])
        #expect(geometry.places[0].altitude == 600.25)
        // The summit's group: everything within 150 m below its highest photo, 2,870 to 2,962 m.
        let top = try #require(geometry.places[1].altitude)
        #expect(abs(top - (2_870 + 2_930 + 2_945 + 2_955 + 2_962) / 5) < 1e-9)
        #expect(geometry.places.max { ($0.altitude ?? -.infinity) < ($1.altitude ?? -.infinity) }?.name == "Zugspitze")
    }

    // MARK: Local days and speed

    @Test func localDaysAreTheDaysOfLocalDay() {
        // The offsets kept from one transition to the next and the day arithmetic agree with
        // `LocalDay` everywhere: zones with half and quarter hours, summer time both ways and at
        // midnight (Santiago), the date line (Apia skipped 30 December 2011), from 1900 to 2200
        // and outside it, around every transition from 1990 to 2040; in time order, backwards and
        // shuffled.
        let identifiers = ["UTC", "Europe/Berlin", "Europe/Lisbon", "America/New_York", "America/St_Johns", "America/Santiago", "Asia/Kolkata",
                           "Asia/Kathmandu", "Australia/Lord_Howe", "Pacific/Chatham", "Pacific/Apia", "Pacific/Kiritimati", "Pacific/Honolulu",
                           "Atlantic/Reykjavik", "Arctic/Longyearbyen", "Antarctica/Troll"]
        let zones = identifiers.compactMap(TimeZone.init(identifier:))
        #expect(zones.count == identifiers.count)
        var random = MapRandom(seed: 19)
        var common: [Date] = [MapFixture.date("2011-12-29 10:30"), MapFixture.date("2011-12-30 10:30"), MapFixture.date("2023-03-26 00:59"),
                              MapFixture.date("2023-03-26 01:00"), MapFixture.date("2023-10-29 00:59"), MapFixture.date("2023-10-29 01:00"),
                              Date(timeIntervalSince1970: -2_208_988_800), Date(timeIntervalSince1970: 7_258_118_399.5),
                              MapFixture.date("1850-06-01 12:00"), MapFixture.date("2500-06-01 12:00"), Date(timeIntervalSince1970: -0.25)]
        for _ in 0..<300 { common.append(Date(timeIntervalSince1970: -2_208_988_800 + random.unit() * 9_467_107_200)) }
        var mismatches: [String] = []
        var transitions = 0
        for (number, zone) in zones.enumerated() {
            var dates = common
            var next = zone.nextDaylightSavingTimeTransition(after: MapFixture.date("1990-01-01 00:00"))
            while let transition = next, transition < MapFixture.date("2040-01-01 00:00") {
                dates += [-1, -0.5, 0, 0.5, 1].map { transition.addingTimeInterval($0) }
                transitions += 1
                next = zone.nextDaylightSavingTimeTransition(after: transition)
            }
            let expected = dates.map { LocalDay($0, timeZone: zone) }
            let inTime = dates.indices.sorted { dates[$0] < dates[$1] }
            for order in [inTime, inTime.reversed(), Self.shuffled(inTime, seed: UInt64(number))] {
                // Numbered as in a trip, after a zone Foundation does not know.
                var finder = TripGeometryBuilder.LocalDayFinder(zones: [nil, zone], fallback: zone)
                for i in order where finder.day(dates[i], zone: 1) != expected[i] { mismatches.append("\(zone.identifier) \(dates[i])") }
            }
        }
        #expect(transitions > 500)
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")

        // A place's zone by its number as `build` gives them; an identifier Foundation does not
        // know and none count as the trip's zone, as in `LocalDay(_:place:fallback:)`.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var numbers = TripGeometryBuilder.ZoneNumbers()
        let places = ["Atlantic/Reykjavik", "Asia/Tokyo", "Not/AZone", "Atlantic/Reykjavik", nil].map {
            PlaceComponents(isoCountryCode: "XX", timeZoneIdentifier: $0)
        }
        let placeZones = places.map { $0.timeZoneIdentifier.map { numbers.number($0) } ?? -1 }
        #expect(placeZones == [0, 1, 2, 0, -1])
        var finder = TripGeometryBuilder.LocalDayFinder(zones: numbers.identifiers.map { TimeZone(identifier: $0) }, fallback: tokyo)
        let date = MapFixture.date("2023-06-14 23:30")
        for (place, zone) in zip(places, placeZones) {
            #expect(finder.day(date, zone: zone) == LocalDay(date, place: place, fallback: tokyo))
        }
        #expect(finder.day(date, zone: -1) == Self.day("2023-06-15"))
        #expect(finder.day(date, zone: 0) == Self.day("2023-06-14"))
    }

    @Test func aTripOfFiveThousandPhotosBuildsQuickly() {
        // Twenty days 20 km apart, five places a day 7 km apart with fifty photos each.
        var facts: [AssetFacts] = []
        var random = MapRandom(seed: 5_000)
        for d in 0..<20 {
            let base = Self.destination(from: Places.florence, bearing: 90, meters: Double(d) * 20_000)
            for p in 0..<5 {
                let place = Self.destination(from: base, bearing: Double(p) * 72, meters: 6_000)
                for k in 0..<50 {
                    let date = MapFixture.date("2023-05-01 07:00").addingTimeInterval(Double(d) * 86_400 + Double(p) * 9_000 + Double(k) * 150)
                    facts.append(MapFixture.photo("big-\(d)-\(p)-\(k)", at: date, Fixture.jitter(place, seed: random.int(0..<100_000), meters: 600),
                                                  country: "IT", town: "Town \(d)-\(p)", timeZone: "Europe/Rome"))
                }
            }
        }
        #expect(facts.count == 5_000)
        let members = MapFixture.members(facts, of: AlbumistID("big"))
        let trip = MapFixture.trip(AlbumistID("big"), members)
        let clock = ContinuousClock()
        var geometry: TripGeometry?
        let elapsed = clock.measure {
            geometry = TripGeometry.build(trip: trip, facts: members, airborne: [], timeZone: MapFixture.utc)
        }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "TRIP_GEOMETRY_PERF photos 5000: %.1f ms, %d places, %d route points", ms, geometry?.places.count ?? 0,
                     geometry?.route.count ?? 0))
        #expect(geometry?.places.count == 100)
        #expect(geometry?.route.count == 100)
        // A debug build on a shared machine is several times slower than the app; the bound only
        // catches work growing with the square of the photos.
        #expect(ms < 1_000)
    }

    /// Five years of a library whose home is not known, made into one trip: 50,000 photos, a day
    /// at two to four of 24 places around home, and 30 holidays of ten days at 12 places each.
    static func fiveYearsInOneTrip() -> [AssetFacts] {
        var random = MapRandom(seed: 50_000)
        /// Places 6 km apart on a grid around `centre`: never one place.
        func grid(_ centre: GeoCoordinate, _ count: Int) -> [GeoCoordinate] {
            (0..<count).map { k in Self.offset(centre, east: Double(k % 5 - 2) * 6_000, north: Double(k / 5 - 2) * 6_000) }
        }
        let around = grid(Places.regensburg, 25).enumerated().filter { $0.offset != 12 }.map(\.element)
        let holidays = (0..<30).map { h in
            grid(MapFixture.at(-40 + Double(h) * 3.1, -150 + Double(h) * 11.3), 12)
        }
        var facts: [AssetFacts] = []
        for d in 0..<1_826 where facts.count < 50_000 {
            let holiday = d % 60 < 10 ? holidays[(d / 60) % holidays.count] : nil
            let spots = holiday ?? around
            let day = MapFixture.date("2019-01-01").addingTimeInterval(Double(d) * 86_400)
            let stops = 2 + random.int(0..<3)
            for s in 0..<stops {
                let spot = spots[random.int(0..<spots.count)]
                for k in 0..<(28 / stops) where facts.count < 50_000 {
                    let date = day.addingTimeInterval(Double(8 + s * 4) * 3_600 + Double(k) * 300)
                    facts.append(MapFixture.photo("life-\(d)-\(s)-\(k)", at: date, Fixture.jitter(spot, seed: random.int(0..<100_000), meters: 600),
                                                  country: holiday == nil ? "DE" : "XX", town: "Spot \(spot.latitude)",
                                                  timeZone: holiday == nil ? "Europe/Berlin" : "UTC"))
                }
            }
        }
        return facts
    }

    /// One trip holding 50,000 photos at a few hundred places costs about what the trips of a
    /// whole 50,000-photo library cost per photo (`MapSummaryLoadTests`); review: thousands of
    /// day places were each compared with every place before them.
    @Test func aTripOfFiftyThousandPhotosBuildsQuickly() {
        let members = MapFixture.members(Self.fiveYearsInOneTrip(), of: AlbumistID("life"))
        #expect(members.count == 50_000)
        let trip = MapFixture.trip(AlbumistID("life"), members)
        let clock = ContinuousClock()
        var geometry: TripGeometry?
        // Warm once (first-use costs of Foundation), then the best of three.
        _ = TripGeometry.build(trip: trip, facts: members, airborne: [], timeZone: MapFixture.utc)
        var best = Duration.seconds(1_000)
        for _ in 0..<3 {
            best = min(best, clock.measure { geometry = TripGeometry.build(trip: trip, facts: members, airborne: [], timeZone: MapFixture.utc) })
        }
        let ms = Double(best.components.seconds) * 1_000 + Double(best.components.attoseconds) / 1e15
        print(String(format: "TRIP_GEOMETRY_PERF photos 50000, one trip: %.1f ms, %d day places, %d places, %d route points", ms,
                     geometry?.dayPlaces.count ?? 0, geometry?.places.count ?? 0, geometry?.route.count ?? 0))
        #expect(geometry?.photoCount == 50_000)
        #expect((300...384).contains(geometry?.places.count ?? 0))
        #expect(geometry?.route.count ?? 0 <= TripGeometry.maxRoutePoints)
        // Debug build on a shared machine: the bound catches work growing with the square of the
        // places, the printed figure is the one that matters.
        #expect(ms < 3_000)
    }

    /// Day places merge into trip places on a grid (`mergedPlaces`): the same places as comparing
    /// each with every place before it, at the antimeridian and the poles too.
    @Test func placesMergedOnAGridAreThoseOfComparingEach() {
        /// Each day place joins the nearest place founded within the radius, ties to the lower
        /// index, else founds one: compared with every place before it.
        func comparingEach(_ groups: [TripGeometryBuilder.DayGroup]) -> (placeOfGroup: [Int], count: Int) {
            var founders: [TripGeometryBuilder.UnitVector] = []
            var placeOfGroup: [Int] = []
            for group in groups {
                let point = TripGeometryBuilder.UnitVector(group.coordinate)
                var nearest = -1, nearestChord = Double.infinity
                for p in founders.indices {
                    let chord = point.chordSquared(to: founders[p])
                    if chord <= TripGeometryBuilder.placeChordSquared && chord < nearestChord { (nearest, nearestChord) = (p, chord) }
                }
                if nearest < 0 {
                    founders.append(point)
                    nearest = founders.count - 1
                }
                placeOfGroup.append(nearest)
            }
            return (placeOfGroup, founders.count)
        }
        let centres = [Places.rome, MapFixture.at(-16.85, 179.995), MapFixture.at(-16.85, -179.995), MapFixture.at(89.995, 30),
                       MapFixture.at(-89.99, -120), MapFixture.at(0.02, -0.03), MapFixture.at(64.15, -21.94)]
        var random = MapRandom(seed: 3_000)
        for round in 0..<40 {
            let groups = (0..<(50 + round * 10)).map { i in
                let centre = centres[random.int(0..<centres.count)]
                let point = Self.destination(from: centre, bearing: random.unit() * 360, meters: random.unit() * 12_000)
                return TripGeometryBuilder.DayGroup(day: LocalDay(year: 2023, month: 1, day: 1 + i % 28), members: [i], coordinate: point)
            }
            let grid = TripGeometryBuilder.mergedPlaces(groups), each = comparingEach(groups)
            #expect(grid.placeOfGroup == each.placeOfGroup && grid.count == each.count)
        }
        // Just inside the radius across the antimeridian and across the pole: one place each.
        func groups(_ points: [GeoCoordinate]) -> [TripGeometryBuilder.DayGroup] {
            points.enumerated().map {
                TripGeometryBuilder.DayGroup(day: LocalDay(year: 2023, month: 1, day: 1), members: [$0.offset], coordinate: $0.element)
            }
        }
        let fiji = MapFixture.at(-16.85, 179.999)
        let across = groups([fiji, Self.destination(from: fiji, bearing: 90, meters: 2_990), MapFixture.at(89.99, 0), MapFixture.at(89.99, 180),
                             Places.vik, Self.destination(from: Places.vik, bearing: 45, meters: 2_990)])
        #expect(TripGeometryBuilder.mergedPlaces(across).placeOfGroup == [0, 0, 1, 1, 2, 2])
        // At the radius itself, in every direction: as comparing each says.
        for bearing in stride(from: 0.0, to: 360, by: 15) {
            for centre in [fiji, Places.vik, MapFixture.at(89.98, 0), MapFixture.at(0.03, 0.03)] {
                let pair = groups([centre, Self.destination(from: centre, bearing: bearing, meters: TripGeometry.placeRadiusMeters)])
                #expect(TripGeometryBuilder.mergedPlaces(pair).placeOfGroup == comparingEach(pair).placeOfGroup)
            }
        }
    }

    /// Tens of thousands of trip places merge in linear time (review: each day place was compared
    /// with every place before it, 450 million comparisons for these).
    @Test func thirtyThousandPlacesMergeQuickly() {
        var random = MapRandom(seed: 30_000)
        let groups = (0..<30_000).map { i in
            TripGeometryBuilder.DayGroup(day: LocalDay(year: 2023, month: 1, day: 1), members: [i],
                                         coordinate: MapFixture.at(asin(2 * random.unit() - 1) * 180 / .pi, random.unit() * 360 - 180))
        }
        let clock = ContinuousClock()
        var merged: (placeOfGroup: [Int], count: Int)?
        let elapsed = clock.measure { merged = TripGeometryBuilder.mergedPlaces(groups) }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "TRIP_GEOMETRY_PERF merge of 30000 day places: %.1f ms, %d places", ms, merged?.count ?? 0))
        // Random points on the Earth lie some 130 km apart: almost every one is a place of its own.
        #expect((merged?.count ?? 0) > 29_900)
        // Debug build on a shared machine: some 150 ms here, against 6,600 ms comparing each.
        #expect(ms < 2_000)
    }
}
