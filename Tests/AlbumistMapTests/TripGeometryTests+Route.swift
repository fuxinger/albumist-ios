import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// The route and its legs: more than two hundred visits are simplified, keeping an excursion there
/// and back; legs without photos; the kilometres on site count every leg before the route is cut,
/// and a leg of the cut route inherits what most of its metres were.
extension TripGeometryTests {
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
}
