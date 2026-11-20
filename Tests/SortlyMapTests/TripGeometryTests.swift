import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyTestSupport

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
        let members = MapFixture.members(facts, of: SortlyID(id))
        return TripGeometry.build(trip: MapFixture.trip(SortlyID(id), members), facts: members, airborne: airborne, altitudes: altitudes,
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
        #expect(geometry.id == SortlyID("iceland"))
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
        #expect(expected.photoCount == facts.count)
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

        // No photo on the map at all: the trip's centre.
        let unlocated = (0..<3).map { MapFixture.photo("blind-\($0)", at: start.addingTimeInterval(Double($0) * 60), nil) }
        let trip = Trip(id: SortlyID("blind"), start: start, end: start.addingTimeInterval(120), geotaggedAssetIDs: [],
                        inferredAssetIDs: unlocated.map(\.id), centroid: Places.rome, maxDistanceFromHomeMeters: 0, distinctStops: 0, kind: .vacation)
        let blind = TripGeometry.build(trip: trip, facts: unlocated, airborne: [], timeZone: MapFixture.utc)
        #expect(blind.destination == Places.rome)
        #expect(blind.destinationIndex == nil)
        #expect(blind.photoCount == 3)
        #expect(blind.timeZoneIdentifier == nil)
        #expect(blind.dayCounts == [TripDay(day: Self.day("2023-04-12"), photoCount: 3, placeIndex: nil)])
    }

    @Test func anEmptyTripAndASinglePhoto() throws {
        let start = MapFixture.date("2023-03-01 23:30"), end = MapFixture.date("2023-03-04 10:00")
        let trip = Trip(id: SortlyID("empty"), start: start, end: end, geotaggedAssetIDs: [], inferredAssetIDs: [], centroid: Places.florence,
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
        // Legs across the antimeridian are short.
        #expect(geometry.legs.allSatisfy { $0.meters < 310_000 })
    }

    @Test func simplificationKeepsAnExcursionThereAndBack() {
        // Hotel, a nearby place, hotel, a far waterfall, hotel, a nearby place, hotel: at most 4
        // points keep the waterfall (an excursion has no area, but stands out from the line).
        let hotel = Places.vik
        let coordinates = [hotel, Self.offset(hotel, east: 5_000), Self.offset(hotel, north: 60_000), Self.offset(hotel, east: -6_000)]
        let visits = [0, 1, 0, 2, 0, 3, 0].enumerated().map { TripGeometryBuilder.Visit(place: $1, first: $0, last: $0) }
        let kept = TripGeometryBuilder.simplified(visits, coordinates: coordinates, limit: 4)
        #expect(kept.count <= 4)
        #expect(kept.first?.first == 0 && kept.last?.last == 6)
        #expect(kept.contains { $0.place == 2 })
        for (a, b) in zip(kept, kept.dropFirst()) { #expect(a.place != b.place) }
        // Points on the great circle between their neighbours (here a meridian) never count.
        let line = (0..<6).map { TripGeometryBuilder.Visit(place: $0, first: $0, last: $0) }
        let lineCoordinates = (0..<6).map { Self.offset(hotel, north: Double($0) * 10_000) }
        #expect(TripGeometryBuilder.simplified(line, coordinates: lineCoordinates, limit: 2).map(\.place) == [0, 5])
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
        #expect(geometry.firstDay == Self.day("2023-06-15") && geometry.lastDay == Self.day("2023-06-15"))
        // The photo without a place counts in the trip's zone, not the device's.
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 5, placeIndex: 0)])
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
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 5, placeIndex: 0)])
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
        // Their days still count: they are photos of the trip.
        #expect(geometry.dayCounts.map(\.photoCount) == [5, 6])
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
        // 23:30 UTC is the 16th in Lisbon (summer time), the trip's zone.
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 6, placeIndex: 0),
                                       TripDay(day: Self.day("2023-06-16"), photoCount: 1, placeIndex: nil),
                                       TripDay(day: Self.day("2023-06-17"), photoCount: 1, placeIndex: nil)])
        #expect(geometry.lastDay == Self.day("2023-06-17"))
        #expect(geometry.end == MapFixture.date("2023-06-17 09:00"))
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

        // Only ordinary photos: the six largest; an id given twice is taken once, at its better
        // rank ("o2" again as a favourite).
        let ordinary = (0..<9).map { photo("o\($0)", $0, pixels: (1_000 + $0 * 100, 1_000)) }
            + [photo("o8", 9, pixels: (1_800, 1_000)), photo("o2", 10, favorite: true, pixels: (1_200, 1_000))]
        for seed in [1, 2, 3] as [UInt64] {
            let best = try #require(Self.build(Self.shuffled(ordinary, seed: seed)).places.first)
            #expect(best.coverCandidates == ["o2", "o8", "o7", "o6", "o5", "o4"])
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
        // One above 6,000 m (a plane's, if not filtered): none.
        #expect(altitude([1_600, 1_620, 7_000], at: zermatt) == nil)
        // Fewer than three photos with an altitude: none; one that is no number does not count.
        #expect(altitude([1_600, 1_620, nil, nil, nil], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, .nan], at: zermatt) == nil)
        #expect(altitude([1_600, 1_620, 1_610, .nan], at: zermatt) == 1_610)
        // Below sea level is fine (the Dead Sea shore).
        #expect(altitude([-420, -415, -410], at: MapFixture.at(31.5590, 35.4732)) == -415)
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
        let members = MapFixture.members(facts, of: SortlyID("big"))
        let trip = MapFixture.trip(SortlyID("big"), members)
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
}
