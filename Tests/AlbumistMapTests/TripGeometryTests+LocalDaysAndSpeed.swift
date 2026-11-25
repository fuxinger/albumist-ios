import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Local days and speed: the days of `LocalDay`, trips of five thousand and of fifty thousand photos
/// built quickly, and trip places merged on a grid as by comparing each, thirty thousand of them
/// quickly.
extension TripGeometryTests {
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
