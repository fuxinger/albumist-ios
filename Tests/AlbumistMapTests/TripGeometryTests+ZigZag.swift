import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Photos that would draw the route as a zig-zag, and ways that are none: photos taken at the same
/// time in two places, two or three cameras apart in turn, the route going on after an afternoon
/// apart, turning back right away twice in a row; real ways there and back stay as they are.
extension TripGeometryTests {
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

    /// `count` photos at `place` from `start` (UTC), one every `minutes`.
    private func stop(_ prefix: String, _ place: GeoCoordinate, _ start: String, count: Int = 3, minutes: Double = 10) -> [AssetFacts] {
        (0..<count).map { i in
            MapFixture.photo("\(prefix)-\(i)", at: MapFixture.date(start).addingTimeInterval(Double(i) * minutes * 60),
                             Fixture.jitter(place, seed: i, meters: 80))
        }
    }

    /// From each stop to the next at another place: the speed from its last photo to the next one's first.
    private func speeds(_ stops: [[AssetFacts]]) -> [Double] {
        zip(stops, stops.dropFirst()).compactMap { from, to in
            let a = from[from.count - 1].asset, b = to[0].asset
            let meters = GeoMath.distance(a.location!, b.location!)
            return meters > TripGeometry.placeRadiusMeters ? meters / b.creationDate!.timeIntervalSince(a.creationDate!) : nil
        }
    }

    /// The route through these stops, as the indices of its places.
    private func route(_ stops: [[AssetFacts]]) -> [Int] { Self.build(stops.flatMap { $0 }).route.map(\.placeIndex) }

    /// Real ways there and back stay as they are: legs slower than `TripGeometryBuilder.turnBackSpeed`
    /// however often they turn back (a car, a ferry), faster ones turning back once at a time or
    /// after time spent at the far end (a high-speed train, a scenic flight, island hops by plane).
    @Test func realWaysThereAndBackStayAsTheyAre() {
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
}
