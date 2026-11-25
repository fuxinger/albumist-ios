import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// The prototype's trip to play: nine made-up days round Iceland, built like a real trip.
@Suite("Demo trip")
struct DemoTripTests {
    static let names = [
        "Reykjavík", "Þingvellir", "Geysir", "Gullfoss", "Seljalandsfoss", "Skógafoss", "Vík", "Skaftafell", "Jökulsárlón", "Höfn",
        "Egilsstaðir", "Dettifoss", "Mývatn", "Goðafoss", "Akureyri", "Borgarnes", "Hafnarfjörður",
    ]

    @Test func itIsNineDaysInJune2023() {
        let trip = DemoTrip.iceland()
        let geometry = trip.geometry
        #expect(trip.title == "Island, Ringstraße")
        #expect(trip.id == DemoTrip.id)
        #expect(geometry.days == 9)
        #expect(geometry.firstDay == LocalDay(year: 2023, month: 6, day: 10))
        #expect(geometry.lastDay == LocalDay(year: 2023, month: 6, day: 18))
        #expect(geometry.timeZoneIdentifier == "Atlantic/Reykjavik")
        #expect(geometry.photoCount == 412)
        #expect(geometry.dayCounts.map(\.day) == (0..<9).map { LocalDay(year: 2023, month: 6, day: 10 + $0) })
        #expect(geometry.dayCounts.map(\.photoCount) == [36, 84, 99, 66, 18, 50, 36, 9, 14])
        #expect(geometry.countryPhotos == ["IS": 412])
        #expect(geometry.mainCountryKey == "IS")
        #expect(geometry.airborneCount == 0)
    }

    @Test func itHasSeventeenNamedPlacesVisitedInTurn() {
        let geometry = DemoTrip.iceland().geometry
        #expect(geometry.places.count == 17)
        #expect(geometry.route.count == 17)
        #expect(geometry.route.map { geometry.places[$0.placeIndex].name } == Self.names)
        #expect(Set(geometry.route.map(\.placeIndex)).count == 17)
        #expect(geometry.places.allSatisfy { $0.countryKey == "IS" })
        #expect(geometry.places.allSatisfy { !$0.coverCandidates.isEmpty })
        #expect(geometry.places.map(\.photoCount).reduce(0, +) == 412)
        // The route keeps time order.
        #expect(zip(geometry.route, geometry.route.dropFirst()).allSatisfy { $0.departure <= $1.arrival })
        // Each place is where its burst was: within a few hundred metres of the made-up spot.
        for (point, stop) in zip(geometry.route, DemoTrip.stops) {
            #expect(GeoMath.distance(geometry.places[point.placeIndex].coordinate, stop.coordinate) < 300)
        }
    }

    @Test func theRouteGoesRoundTheIsland() {
        let geometry = DemoTrip.iceland().geometry
        let points = geometry.routeCoordinates
        #expect(points.count == 17)
        // All on Iceland.
        #expect(points.allSatisfy { (63.2...66.6).contains($0.latitude) && (-24.6 ... -13.4).contains($0.longitude) })
        // It ends near where it began: Hafnarfjörður next to Reykjavík.
        let first = points[0], last = points[points.count - 1]
        #expect(GeoMath.distance(first, last) < 20_000)
        // It reaches the south coast, the east and the north.
        #expect(points.map(\.latitude).min() ?? 90 < 63.5)
        #expect(points.map(\.longitude).max() ?? -180 > -15)
        #expect(points.map(\.latitude).max() ?? -90 > 65.7)
        // Once round the middle of the island, anticlockwise (east along the south coast first).
        let middle = GeoCoordinate(latitude: 64.95, longitude: -18.6)
        let shrink = cos(middle.latitude * .pi / 180)
        let angles = (points + [first]).map { atan2($0.latitude - middle.latitude, ($0.longitude - middle.longitude) * shrink) * 180 / .pi }
        var winding = 0.0
        for (a, b) in zip(angles, angles.dropFirst()) {
            var step = b - a
            if step > 180 { step -= 360 }
            if step < -180 { step += 360 }
            // No leg jumps across the middle (Akureyri to Borgarnes turns the most, about 120°).
            #expect(abs(step) < 150)
            winding += step
        }
        #expect(abs(winding - 360) < 1)
    }

    @Test func itsLegsAndLengths() {
        let trip = DemoTrip.iceland()
        let geometry = trip.geometry
        #expect(geometry.legs.count == 16)
        // The long drives without a photo: Vík to Skaftafell, Höfn to Egilsstaðir to Dettifoss,
        // Akureyri to Borgarnes.
        #expect(geometry.legs.indices.filter { geometry.legs[$0].withoutPhotos } == [6, 9, 10, 14])
        // About 1,000 km on the island as the crow flies, about 2,600 km from home.
        #expect((950_000...1_100_000).contains(trip.stats.metersOnSite))
        #expect(trip.stats.metersOnSite == geometry.metersOnSite)
        let fromHome = trip.stats.metersFromHome ?? 0
        #expect((2_500_000...2_800_000).contains(fromHome))
    }

    @Test func itsHomeIsRoundedNearRegensburg() throws {
        let home = try #require(DemoTrip.iceland().home)
        let exact = GeoCoordinate(latitude: 49.0134, longitude: 12.1016)
        #expect(home.countryCode == "DE")
        #expect(home.coordinate == MapHome.rounded(exact))
        #expect(home.coordinate != exact)
        #expect(GeoMath.distance(home.coordinate, exact) < 7_200)
        // The same home as the globe's demo traveller.
        #expect(MapHome.rounded(home.coordinate) == home.coordinate)
    }

    @Test func itsPhotosAreMadeUpBursts() {
        let zone = TimeZone(identifier: DemoTrip.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let facts = DemoTrip.photos(timeZone: zone)
        #expect(facts.count == 412)
        #expect(Set(facts.map(\.id)).count == 412)
        #expect(facts.allSatisfy { $0.id.rawValue.hasPrefix("demo-iceland-") })
        #expect(facts.allSatisfy { $0.place?.isoCountryCode == "IS" && $0.place?.timeZoneIdentifier == "Atlantic/Reykjavik" })
        #expect(facts.allSatisfy { $0.tripID == DemoTrip.id && $0.contentKnown && $0.asset.kind == .image })
        // All in June 2023 in Iceland's local time (UTC all year).
        let days = facts.compactMap(\.asset.creationDate).map { LocalDay($0, timeZone: zone) }
        #expect(days.count == 412)
        #expect(days.allSatisfy { $0.year == 2023 && $0.month == 6 && (10...18).contains($0.day) })
        // Two minutes apart within a burst, and no two photos on one spot.
        var start = 0
        for stop in DemoTrip.stops {
            let burst = facts[start..<(start + stop.photos)]
            let times = burst.compactMap(\.asset.creationDate?.timeIntervalSince1970)
            #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 120 })
            let spots = Set(burst.compactMap { $0.asset.location.map { "\($0.latitude),\($0.longitude)" } })
            #expect(spots.count == stop.photos)
            #expect(burst.allSatisfy { fact in fact.asset.location.map { GeoMath.distance($0, stop.coordinate) <= 170 } ?? false })
            start += stop.photos
        }
        #expect(start == 412)
    }

    @Test func itIsTheSameEveryTime() {
        #expect(DemoTrip.iceland() == DemoTrip.iceland())
    }

    @Test func itPlaysInLessThanAMinute() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        #expect(plan.days.count == 9)
        #expect(plan.duration <= PlaybackPlan.maximumSeconds)
        #expect(plan.days.allSatisfy { (PlaybackPlan.shortestDaySeconds...PlaybackPlan.longestDaySeconds).contains($0.duration) })
        #expect(plan.stops.count == 17)
        #expect(plan.legs.count == 16)
    }
}
