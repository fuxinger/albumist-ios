import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The arcs of the globe (concept §4.2): from the home of each trip's time to its destination,
/// one per home and destination, at most `MapSummary.maxArcs`, the strongest and newest kept.
@Suite("Map arcs")
struct MapArcsTests {
    typealias Place = MapHandmade.Places
    let calendar = MapFixture.calendar

    @Test func twoTripsToRomeFromOneHomeShareOneArc() throws {
        // Rome's centre in 2019 and, five years later, a hotel by Ciampino airport 15 km away.
        let first = MapHandmade.trip("rome-2019", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)])
        let second = MapHandmade.trip("rome-2024", "2024-04-10", [MapHandmade.place(Place.ciampino, "Ciampino", "IT", photos: 120)])
        let arcs = MapArcs.build(trips: [second, first])
        let arc = try #require(arcs.first)
        #expect(arcs.count == 1)
        #expect(arc.weight == 2)
        #expect(arc.tripIDs == [AlbumistID("rome-2019"), AlbumistID("rome-2024")])
        #expect(arc.years == [2019, 2024])
        #expect(arc.from == MapHandmade.home.coordinate)
        // The destination of the trip with the most photos.
        #expect(arc.to == Place.ciampino)
    }

    @Test func romeAndFlorenceGetTwoArcs() {
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)])
        let florence = MapHandmade.trip("florence", "2021-09-12", [MapHandmade.place(MapFixture.Places.florence, "Florenz", "IT", photos: 60)])
        let arcs = MapArcs.build(trips: [rome, florence])
        // 230 km apart: two arcs, equally strong, the one with the newer trip first.
        #expect(arcs.map(\.to) == [MapFixture.Places.florence, MapFixture.Places.rome])
        #expect(arcs.allSatisfy { $0.weight == 1 && $0.from == MapHandmade.home.coordinate })
    }

    @Test func aMoveGivesEachHomeItsOwnArc() {
        // Lived in Hamburg until 2019, in the Regensburg area since: Rome from both.
        let before = MapHandmade.trip("rome-2017", "2017-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)],
                                      home: MapHandmade.hamburgHome)
        let after = MapHandmade.trip("rome-2022", "2022-04-10", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 90)])
        let arcs = MapArcs.build(trips: [after, before])
        #expect(arcs.count == 2)
        #expect(Set(arcs.map(\.from)) == [MapHandmade.hamburgHome.coordinate, MapHandmade.home.coordinate])
        #expect(arcs.allSatisfy { $0.weight == 1 && $0.to == MapFixture.Places.rome })
        #expect(Set(arcs.map(\.id)).count == 2)
    }

    @Test func withoutAHomeThereAreNoArcs() {
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)], home: nil)
        let tokyo = MapHandmade.trip("tokyo", "2020-03-02", [MapHandmade.place(MapFixture.Places.tokyo, "Tokio", "JP", photos: 50)], home: nil)
        #expect(MapArcs.build(trips: [rome, tokyo]).isEmpty)
        #expect(MapArcs.build(trips: []).isEmpty)
        // Only the trips whose home is known get one.
        let lisbon = MapHandmade.trip("lisbon", "2022-10-02", [MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 40)])
        #expect(MapArcs.build(trips: [rome, tokyo, lisbon]).map(\.tripIDs) == [[AlbumistID("lisbon")]])
    }

    @Test func atMostMaxArcsTheStrongestAndNewest() throws {
        // 400 destinations; the first 20 visited three times, the next 40 twice.
        let trips = MapHandmade.manyDestinations(400) { $0 < 20 ? 2 : $0 < 60 ? 1 : 0 }
        let arcs = MapArcs.build(trips: trips)
        #expect(arcs.count == MapSummary.maxArcs)
        #expect(arcs.filter { $0.weight == 3 }.count == 20)
        #expect(arcs.filter { $0.weight == 2 }.count == 40)
        // The other 90 are the newest of the destinations visited once, newest first.
        let starts = Dictionary(uniqueKeysWithValues: trips.map { ($0.id.rawValue, $0.geometry.start) })
        func newest(_ arc: MapArc) -> Date { arc.tripIDs.compactMap { starts[$0.rawValue] }.max() ?? .distantPast }
        let once = arcs.filter { $0.weight == 1 }
        let keptSingles = Set(once.flatMap(\.tripIDs).map(\.rawValue))
        let allSingles = trips.filter { trip in !arcs.contains { $0.weight > 1 && $0.tripIDs.contains(trip.id) } }
        let expected = allSingles.sorted { $0.geometry.start > $1.geometry.start }.prefix(90).map(\.id.rawValue)
        #expect(keptSingles == Set(expected))
        // Ordered as kept: weight, then the newest trip, then id.
        for (a, b) in zip(arcs, arcs.dropFirst()) {
            #expect(a.weight > b.weight || (a.weight == b.weight && (newest(a) > newest(b) || (newest(a) == newest(b) && a.id < b.id))))
        }
        let first = try #require(arcs.first)
        #expect(first.weight == 3)
    }

    @Test func aDestinationAcrossTheAntimeridian() throws {
        // Home in Auckland; two stays on Taveuni (Fiji) either side of the 180th meridian, 9 km
        // apart, and Apia (Samoa) at 171.8° W.
        let auckland = RoundedHome(coordinate: MapFixture.at(-36.85, 174.76), countryCode: "NZ")
        let west = MapHandmade.trip("taveuni-west", "2023-07-01", [MapHandmade.place(Place.taveuniWest, "Waiyevo", "FJ", photos: 60)], home: auckland)
        let east = MapHandmade.trip("taveuni-east", "2024-07-01", [MapHandmade.place(Place.taveuniEast, "Taveuni", "FJ", photos: 40)], home: auckland)
        let samoa = MapHandmade.trip("samoa", "2025-01-10", [MapHandmade.place(MapFixture.Places.apia, "Apia", "WS", photos: 30)], home: auckland)
        #expect(GeoMath.distance(Place.taveuniWest, Place.taveuniEast) < 10_000)
        let arcs = MapArcs.build(trips: [samoa, east, west])
        #expect(arcs.count == 2)
        let fiji = try #require(arcs.first { $0.weight == 2 })
        #expect(fiji.to == Place.taveuniWest)
        #expect(fiji.tripIDs == [AlbumistID("taveuni-west"), AlbumistID("taveuni-east")])
        // The arc keeps the real coordinates: the globe draws the short way over the date line.
        let toSamoa = try #require(arcs.first { $0.tripIDs == [AlbumistID("samoa")] })
        #expect(toSamoa.from == auckland.coordinate)
        #expect(toSamoa.to == MapFixture.Places.apia)
    }

    @Test func nearThePolesDistancesAreMeasuredOnTheSphere() {
        // Svalbard: the town and its airport (5 km) are one destination, Barentsburg (37 km) another.
        let town = MapHandmade.trip("longyearbyen", "2021-03-01", [MapHandmade.place(MapFixture.Places.longyearbyen, "Longyearbyen", "SJ", photos: 50)])
        let airport = MapHandmade.trip("airport", "2022-03-01", [MapHandmade.place(Place.svalbardAirport, nil, "SJ", photos: 10)])
        let barentsburg = MapHandmade.trip("barentsburg", "2023-03-01", [MapHandmade.place(Place.barentsburg, "Barentsburg", "SJ", photos: 20)])
        // The South Pole: the station and the ceremonial pole, a quarter of the globe apart in
        // longitude and 300 m apart on the ice.
        let station = MapHandmade.trip("station", "2024-01-05", [MapHandmade.place(Place.southPoleStation, nil, "AQ", photos: 30)])
        let pole = MapHandmade.trip("pole", "2025-01-05", [MapHandmade.place(Place.southPole, nil, "AQ", photos: 5)])
        let arcs = MapArcs.build(trips: [town, airport, barentsburg, station, pole])
        #expect(arcs.count == 3)
        #expect(arcs.contains { $0.tripIDs == [AlbumistID("longyearbyen"), AlbumistID("airport")] && $0.to == MapFixture.Places.longyearbyen })
        #expect(arcs.contains { $0.tripIDs == [AlbumistID("barentsburg")] })
        #expect(arcs.contains { $0.tripIDs == [AlbumistID("station"), AlbumistID("pole")] && $0.to == Place.southPoleStation })
    }

    @Test func idsAreStableAndDoNotShowHome() throws {
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)])
        let lisbon = MapHandmade.trip("lisbon", "2022-10-02", [MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 40)])
        let before = MapArcs.build(trips: [rome, lisbon])
        // An unrelated trip, even one with more photos, changes no id.
        let tokyo = MapHandmade.trip("tokyo", "2023-03-02", [MapHandmade.place(MapFixture.Places.tokyo, "Tokio", "JP", photos: 500)])
        let after = MapArcs.build(trips: [tokyo, rome, lisbon])
        for arc in before {
            #expect(after.first { $0.tripIDs == arc.tripIDs }?.id == arc.id)
        }
        let id = try #require(before.first { $0.tripIDs == [AlbumistID("rome")] }?.id)
        // "arc:<anchor trip>": nothing of home in it, not even hashed (a hash of a rounded home
        // is undone by trying every cell of the grid).
        #expect(id == "arc:rome")
        // Another home moves the arc's start, not its id.
        var moved = rome
        moved.home = MapHandmade.hamburgHome
        let movedArc = try #require(MapArcs.build(trips: [moved]).first)
        #expect(movedArc.id == id && movedArc.from == MapHandmade.hamburgHome.coordinate)
        // Two homes, two arcs to Rome, told apart by their trips.
        var fromHamburg = MapHandmade.trip("rome-from-hamburg", "2016-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 90)])
        fromHamburg.home = MapHandmade.hamburgHome
        #expect(Set(MapArcs.build(trips: [rome, fromHamburg]).map(\.id)) == ["arc:rome", "arc:rome-from-hamburg"])
    }

    /// Concept §8: the house shows only at 300 to 3,000 km view width, and the arcs vanish with it
    /// below 300 km, so neither points to home more closely than the house.
    @Test func houseAndArcsShowOnlyWhereTheyGiveNoHomeAway() {
        #expect(!MapHome.showsHouse(atWidth: 299_999))
        #expect(MapHome.showsHouse(atWidth: 300_000) && MapHome.showsHouse(atWidth: 1_000_000) && MapHome.showsHouse(atWidth: 3_000_000))
        #expect(!MapHome.showsHouse(atWidth: 3_000_001) && !MapHome.showsHouse(atWidth: 20_000_000))
        #expect(!MapHome.showsHouse(atWidth: .nan) && !MapHome.showsHouse(atWidth: .infinity) && !MapHome.showsHouse(atWidth: -1))
        #expect(!MapArcs.areShown(atWidth: 299_999) && !MapArcs.areShown(atWidth: 1_000))
        #expect(MapArcs.areShown(atWidth: 300_000) && MapArcs.areShown(atWidth: 20_000_000))
        #expect(!MapArcs.areShown(atWidth: .nan))
        // The first camera never comes closer than where house and arcs show.
        #expect(MapPins.minimumFocusRadiusMeters * 2 >= MapHome.houseMinimumWidthMeters)
    }

    @Test func sameTripsInAnyOrderGiveTheSameArcs() {
        var trips = MapHandmade.manyDestinations(60) { $0 % 7 == 0 ? 2 : 0 }
        trips.append(MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)]))
        trips.append(MapHandmade.trip("ciampino", "2020-05-02", [MapHandmade.place(Place.ciampino, nil, "IT", photos: 80)]))
        let arcs = MapArcs.build(trips: trips)
        for seed in 1...5 as ClosedRange<UInt64> {
            #expect(MapArcs.build(trips: MapHandmade.shuffled(trips, seed: seed)) == arcs)
        }
    }

    @Test func tripsJoinTheNearestArcAndNeverChain() throws {
        // Rome leads (most photos). Tivoli is 28 km from Rome: an arc of its own. Guidonia lies
        // 23 km from Rome but 7 km from Tivoli: it joins Tivoli's arc, the nearer one. Chained
        // together, the three would be one arc ending 28 km from some of its trips.
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)])
        let tivoli = MapHandmade.trip("tivoli", "2020-05-02", [MapHandmade.place(Place.tivoli, "Tivoli", "IT", photos: 50)])
        let guidonia = MapHandmade.trip("guidonia", "2021-05-02", [MapHandmade.place(Place.guidonia, "Guidonia", "IT", photos: 20)])
        #expect(GeoMath.distance(MapFixture.Places.rome, Place.tivoli) > MapArcs.mergeMeters)
        #expect(GeoMath.distance(MapFixture.Places.rome, Place.guidonia) < MapArcs.mergeMeters)
        let arcs = MapArcs.build(trips: [guidonia, tivoli, rome])
        #expect(arcs.count == 2)
        let toTivoli = try #require(arcs.first { $0.to == Place.tivoli })
        #expect(toTivoli.tripIDs == [AlbumistID("tivoli"), AlbumistID("guidonia")])
        // Every trip went to within `mergeMeters` of where its arc ends.
        let trips = [rome, tivoli, guidonia]
        for arc in arcs {
            for id in arc.tripIDs {
                let trip = try #require(trips.first { $0.id == id })
                #expect(GeoMath.distance(trip.geometry.destination, arc.to) <= MapArcs.mergeMeters)
            }
        }
    }

    @Test func equallyStrongTripsLeadByStartThenID() {
        let later = MapHandmade.trip("b-later", "2021-05-02", [MapHandmade.place(Place.ciampino, nil, "IT", photos: 50)])
        let earlier = MapHandmade.trip("z-earlier", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 50)])
        #expect(MapArcs.build(trips: [later, earlier]).map(\.to) == [MapFixture.Places.rome])
        // Same start too: the smaller id leads.
        let a = MapHandmade.trip("a", "2019-05-02", [MapHandmade.place(Place.ciampino, nil, "IT", photos: 50)])
        let b = MapHandmade.trip("b", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 50)])
        #expect(MapArcs.build(trips: [b, a]).map(\.to) == [Place.ciampino])
    }

    @Test func yearsAreUniqueAndThoseOfTheLocalDays() throws {
        // Started on New Year's Eve at 23:30 UTC in Rome: already 1 January 2023 there.
        let newYear = MapHandmade.trip("new-year", "2022-12-31 23:30", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 50)],
                                       timeZone: "Europe/Rome")
        let spring = MapHandmade.trip("spring", "2023-04-01", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 40)])
        let autumn = MapHandmade.trip("autumn", "2023-10-01", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 30)])
        let arc = try #require(MapArcs.build(trips: [newYear, spring, autumn]).first)
        #expect(arc.years == [2023])
        #expect(arc.tripIDs == [AlbumistID("new-year"), AlbumistID("spring"), AlbumistID("autumn")])
        // On a clock still on New Year's Eve the same start is a trip of 2022.
        let oldYear = MapHandmade.trip("new-year", "2022-12-31 23:30", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 50)])
        #expect(try #require(MapArcs.build(trips: [oldYear, spring, autumn]).first).years == [2022, 2023])
    }

    @Test func thousandsOfDayTripsStayFast() {
        // Concept §9: the whole summary of 50,000 photos in under 300 ms, so about linear work.
        let trips = MapHandmade.dayTrips(5_000).trips
        var arcs: [MapArc] = []
        let took = ContinuousClock().measure { arcs = MapArcs.build(trips: trips) }
        #expect(arcs.count == MapSummary.maxArcs)
        #expect(arcs.allSatisfy { $0.weight >= 1 && $0.tripIDs.count == $0.weight })
        #expect(took < .seconds(2), "5,000 trips took \(took)")
        // Counted rather than timed: each destination is measured against the few arcs in the
        // cubes around it, not against every arc (that would be millions of distances here).
        var clusters = MapArcs.Clusters(radiusMeters: MapArcs.mergeMeters)
        for trip in MapArcs.byLeadership(trips) { _ = clusters.assign(trip.geometry.destination) }
        #expect(clusters.leaders.count > 1_000)
        #expect(clusters.distancesMeasured < 10 * trips.count, "\(clusters.distancesMeasured) distances")
    }

    @Test func clustersFindEveryLeaderWithinTheRadius() {
        // Against measuring every pair: the cubes never miss a leader within the radius, here at
        // the poles, across the antimeridian and with points on cube edges. 1,500 points within a
        // few hundred km of six spots, so that many lie close to each other.
        var random = MapRandom(seed: 11)
        let spots = [MapFixture.at(89.9, 0), MapFixture.at(-89.95, 120), MapFixture.at(-16.8, 179.99), MapFixture.at(0, 0.5),
                     MapFixture.at(48.0, 11.0), MapFixture.at(64.1, -21.9)]
        let points = (0..<1_500).map { i -> GeoCoordinate in
            let spot = spots[i % spots.count]
            let latitude = max(-90, min(90, spot.latitude + 3 * (random.unit() - 0.5)))
            var longitude = spot.longitude + 6 * (random.unit() - 0.5)
            if longitude > 180 { longitude -= 360 }
            if longitude < -180 { longitude += 360 }
            return MapFixture.at(latitude, longitude)
        }
        var clusters = MapArcs.Clusters(radiusMeters: MapArcs.mergeMeters)
        var leaders: [GeoCoordinate] = []
        for point in points {
            let assignment = clusters.assign(point)
            // The nearest leader within the radius, measured against all of them (the older on a tie).
            let nearest = leaders.indices
                .map { (meters: GeoMath.distance(point, leaders[$0]), leader: $0) }
                .filter { $0.meters <= MapArcs.mergeMeters }
                .min { ($0.meters, $0.leader) < ($1.meters, $1.leader) }
            #expect(assignment.isNew == (nearest == nil))
            if let nearest { #expect(assignment.leader == nearest.leader) } else { leaders.append(point) }
        }
        #expect(clusters.leaders == leaders)
        #expect(leaders.count > 100 && leaders.count < 1_400)
    }

    @Test func aTripWithoutAPlaceStillGetsItsArcButNoBrokenCoordinate() {
        // No place with 3 photos of one day: the destination is the medoid of its photos, a real
        // photo location.
        let walk = MapHandmade.trip("walk", "2022-05-01", [], medoid: MapFixture.Places.lisbon)
        var broken = MapHandmade.trip("broken", "2022-06-01", [MapHandmade.place(MapFixture.Places.porto, "Porto", "PT", photos: 10)])
        broken.geometry.destination = GeoCoordinate(latitude: .nan, longitude: 8)
        var nowhere = MapHandmade.trip("nowhere", "2022-07-01", [MapHandmade.place(MapFixture.Places.porto, "Porto", "PT", photos: 10)])
        nowhere.home = RoundedHome(coordinate: GeoCoordinate(latitude: .infinity, longitude: 0), countryCode: "DE")
        let arcs = MapArcs.build(trips: [walk, broken, nowhere])
        #expect(arcs.map(\.tripIDs) == [[AlbumistID("walk")]])
        #expect(arcs.first?.to == MapFixture.Places.lisbon)
    }
}
