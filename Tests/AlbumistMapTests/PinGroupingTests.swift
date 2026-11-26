import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// Which pins the globe shows (concept §4.2, §9): the level by the view's width, at most 60 groups
/// of pins close together on screen, and the first camera.
@Suite("Pin grouping")
struct PinGroupingTests {
    typealias Places = MapFixture.Places

    static func at(_ latitude: Double, _ longitude: Double) -> GeoCoordinate { MapFixture.at(latitude, longitude) }

    static func pin(_ id: String, _ coordinate: GeoCoordinate, count: Int = 1, level: MapPinLevel = .trip) -> MapPin {
        MapPin(id: id, level: level, coordinate: coordinate, count: count)
    }

    /// An iPhone's view in portrait, `widthMeters` wide on the ground.
    static func view(_ center: GeoCoordinate, widthMeters: Double) -> MapViewport {
        MapViewport(center: center, widthMeters: widthMeters, widthPoints: 390, heightPoints: 844)
    }

    /// The globe shows the pins of the level its width calls for, never all levels at once: all of
    /// them together grouped into one heap (review finding 13).
    @Test func theGlobeShowsOneLevelAtATime() {
        let pins = MapSummaryTests.summary.pins
        #expect(Set(pins.map(\.level)) == Set(MapPinLevel.allCases))
        for (width, level) in [(20_000_000.0, MapPinLevel.worldRegion), (4_000_000, .country), (1_000_000, .trip), (100_000, .place)] {
            let groups = MapPins.onGlobe(pins, in: Self.view(MapFixture.Places.reykjavik, widthMeters: width))
            #expect(!groups.isEmpty, "\(level)")
            #expect(groups.allSatisfy { $0.pin.level == level }, "\(level)")
            #expect(groups.count <= MapSummary.maxVisiblePins)
        }
    }

    /// Where `coordinate` is on screen, in points from the view's centre (x east, y north).
    static func screen(_ coordinate: GeoCoordinate, in view: MapViewport) -> (x: Double, y: Double) {
        let p = AzimuthalEquidistantProjection(center: view.center).project(coordinate)
        let pointsPerMeter = view.widthPoints / view.widthMeters
        return (p.x * pointsPerMeter, p.y * pointsPerMeter)
    }

    /// `kilometers` east of `coordinate` (west for a negative number), on its parallel.
    static func east(of coordinate: GeoCoordinate, kilometers: Double) -> GeoCoordinate {
        at(coordinate.latitude, coordinate.longitude + kilometers * 1_000 / (GeoMath.metersPerDegreeLatitude * cos(coordinate.latitude * .pi / 180)))
    }

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var random = MapRandom(seed: seed)
        var copy = items
        for i in stride(from: copy.count - 1, to: 0, by: -1) { copy.swapAt(i, random.int(0..<(i + 1))) }
        return copy
    }

    // MARK: Levels

    /// The farther away the view, the coarser the pins, switching exactly at the thresholds; a
    /// width that is not a number gets the coarsest level.
    @Test func levelsChangeAtTheirThresholds() {
        #expect(MapPins.regionWidthMeters == 7_000_000)
        #expect(MapPins.countryWidthMeters == 2_500_000)
        #expect(MapPins.tripWidthMeters == 250_000)
        #expect(MapPins.level(forWidth: 40_000_000) == .worldRegion)
        #expect(MapPins.level(forWidth: MapPins.regionWidthMeters) == .worldRegion)
        #expect(MapPins.level(forWidth: MapPins.regionWidthMeters.nextDown) == .country)
        #expect(MapPins.level(forWidth: MapPins.countryWidthMeters) == .country)
        #expect(MapPins.level(forWidth: MapPins.countryWidthMeters.nextDown) == .trip)
        #expect(MapPins.level(forWidth: MapPins.tripWidthMeters) == .trip)
        #expect(MapPins.level(forWidth: MapPins.tripWidthMeters.nextDown) == .place)
        #expect(MapPins.level(forWidth: 500) == .place)
        #expect(MapPins.level(forWidth: 0) == .place)
        #expect(MapPins.level(forWidth: .infinity) == .worldRegion)
        #expect(MapPins.level(forWidth: .nan) == .worldRegion)
    }

    // MARK: Grouping

    /// 3,000 day trips around Bavaria in a 300 km view: at most 60 groups (concept §9), whose
    /// members are every visible pin exactly once; each group shows the pin with the highest
    /// count among its members; shown pins at least the spacing apart; pins far outside the view
    /// (Lisbon, Rome, Tokyo) in no group.
    @Test func thousandsOfDayTripsAroundBavariaStayWithinTheLimit() {
        var random = MapRandom(seed: 2_026)
        var pins = (0..<3_000).map { i in
            Self.pin(String(format: "trip:%04d", i), Self.at(47.3 + random.unit() * 3.2, 9.0 + random.unit() * 4.8), count: 1 + random.int(0..<400))
        }
        pins += [Self.pin("trip:lisbon", Places.lisbon, count: 900), Self.pin("trip:rome", Places.rome, count: 900), Self.pin("trip:tokyo", Places.tokyo, count: 900)]
        let view = Self.view(Self.at(48.9, 11.4), widthMeters: 300_000)
        let groups = MapPins.visible(pins, in: view)
        #expect(groups.count <= MapSummary.maxVisiblePins && groups.count >= 10)
        let members = groups.flatMap(\.memberIDs)
        #expect(Set(members).count == members.count)
        // Visible: on screen, give or take half the spacing (22 points) at the edges.
        let visible = pins.filter { pin in
            let p = Self.screen(pin.coordinate, in: view)
            return abs(p.x) <= 195 + 22 && abs(p.y) <= 422 + 22
        }
        #expect(visible.count > 2_000 && visible.count < 3_000)
        #expect(Set(members) == Set(visible.map(\.id)))
        let counts = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0.count) })
        for group in groups {
            #expect(group.memberIDs.first == group.pin.id)
            #expect(group.memberIDs.allSatisfy { (counts[$0] ?? .max) <= group.pin.count })
        }
        let shown = groups.map { Self.screen($0.pin.coordinate, in: view) }
        var closest = Double.infinity
        for i in shown.indices {
            for j in shown.indices where j > i { closest = min(closest, hypot(shown[i].x - shown[j].x, shown[i].y - shown[j].y)) }
        }
        #expect(closest > 44)
    }

    /// Pins on the far side of the globe are not drawn, however wide the view: from Regensburg,
    /// Tokyo (83° away) shows, Honolulu (109°) and Auckland (163°) do not; turned to Honolulu,
    /// the other way round.
    @Test func pinsOnTheFarSideAreDropped() {
        let pins = [Self.pin("regensburg", Places.regensburg, count: 5), Self.pin("tokyo", Places.tokyo, count: 4),
                    Self.pin("honolulu", Places.honolulu, count: 3), Self.pin("auckland", Places.auckland, count: 2)]
        let europe = MapPins.visible(pins, in: Self.view(Places.regensburg, widthMeters: 40_000_000), spacingPoints: 1)
        #expect(europe.map(\.pin.id) == ["regensburg", "tokyo"])
        let pacific = MapPins.visible(pins, in: Self.view(Places.honolulu, widthMeters: 40_000_000), spacingPoints: 1)
        #expect(pacific.map(\.pin.id) == ["tokyo", "honolulu", "auckland"])
    }

    /// A view centred on 180° (given as 180° or -180°) shows Fiji west of the antimeridian and
    /// Samoa east of it, 1,150 km apart: one group from far away, two closer in.
    @Test func aViewOnTheAntimeridianGroupsFijiAndSamoa() {
        let fiji = Self.pin("trip:fiji", Places.suva, count: 12), samoa = Self.pin("trip:samoa", Places.apia, count: 7)
        for longitude in [180.0, -180.0] {
            let center = Self.at(-16, longitude)
            let far = MapPins.visible([samoa, fiji], in: Self.view(center, widthMeters: 20_000_000))
            #expect(far == [MapPinGroup(pin: fiji, memberIDs: ["trip:fiji", "trip:samoa"])])
            let closer = Self.view(center, widthMeters: 3_000_000)
            #expect(MapPins.visible([samoa, fiji], in: closer).map(\.memberIDs) == [["trip:fiji"], ["trip:samoa"]])
            let west = Self.screen(Places.suva, in: closer), east = Self.screen(Places.apia, in: closer)
            #expect(west.x < 0 && east.x > 0)
            #expect(hypot(east.x - west.x, east.y - west.y) > 140 && hypot(east.x - west.x, east.y - west.y) < 160)
        }
    }

    /// Ties are broken the same way in any order of the pins: equal counts go by the smaller id; a
    /// pin exactly as near to two shown pins joins the group made first; a repeated id counts once.
    /// Around the Greenwich meridian, so that pins 0.4375° west and east of it lie exactly
    /// mirrored on screen (about 30 points either side) and the middle one is exactly as near
    /// to both.
    @Test func tiesAreBrokenTheSameWayInAnyOrder() {
        let greenwich = Self.at(51.4779, 0)
        let view = Self.view(greenwich, widthMeters: 390_000) // 1 point is 1 km
        let west = Self.at(greenwich.latitude, -0.4375), east = Self.at(greenwich.latitude, 0.4375)
        let a = Self.pin("a", west, count: 10), b = Self.pin("b", east, count: 10), c = Self.pin("c", greenwich, count: 1)
        let (left, right) = (Self.screen(west, in: view), Self.screen(east, in: view))
        #expect(left.x == -right.x && left.y == right.y && right.x > 22 && right.x < 44)
        #expect(MapPins.visible([c, b, a], in: view).map(\.memberIDs) == [["a", "c"], ["b"]])
        let stronger = Self.pin("b", east, count: 11)
        #expect(MapPins.visible([a, c, stronger], in: view).map(\.memberIDs) == [["b", "c"], ["a"]])
        let stack = ["d", "b", "e", "a", "c"].map { Self.pin("stack:\($0)", greenwich, count: 3) }
        #expect(MapPins.visible(stack, in: view).map(\.memberIDs) == [["stack:a", "stack:b", "stack:c", "stack:d", "stack:e"]])
        let twice = MapPins.visible([Self.pin("x", west, count: 2), Self.pin("x", east, count: 5)], in: view)
        #expect(twice.count == 1 && twice.first?.pin.count == 5 && twice.first?.memberIDs == ["x"])

        var random = MapRandom(seed: 5)
        let crowd = (0..<400).map { i in Self.pin("crowd:\(i % 97)-\(i)", Self.at(51 + random.unit(), -1 + random.unit() * 2), count: 1 + i % 4) }
            + [a, b, c] + stack
        let reference = MapPins.visible(crowd, in: view)
        #expect(reference.count > 1)
        for seed in UInt64(1)...8 { #expect(MapPins.visible(Self.shuffled(crowd, seed: seed), in: view) == reference) }
    }

    /// The limit holds whatever it is: the spacing grows by half until it does, at the latest
    /// when all visible pins are one group. A spacing that is not a number counts as the default
    /// 44 points, one below a point as one point.
    @Test func theLimitHolds() {
        var random = MapRandom(seed: 77)
        let view = Self.view(Places.regensburg, widthMeters: 1_000_000)
        let pins = (0..<800).map { Self.pin("p\($0)", Self.at(44 + random.unit() * 10, 2 + random.unit() * 20), count: 1 + random.int(0..<50)) }
        let visible = Set(MapPins.visible(pins, in: view, limit: 10_000).flatMap(\.memberIDs))
        #expect(visible.count > 300 && visible.count < 800)
        for limit in [1, 2, 5, 10, 60, 1_000] {
            let groups = MapPins.visible(pins, in: view, limit: limit)
            #expect(!groups.isEmpty && groups.count <= limit)
            #expect(Set(groups.flatMap(\.memberIDs)) == visible)
        }
        #expect(MapPins.visible(pins, in: view, spacingPoints: .nan) == MapPins.visible(pins, in: view))
        #expect(MapPins.visible(pins, in: view, spacingPoints: -5) == MapPins.visible(pins, in: view, spacingPoints: 1))
        let spot = [Self.pin("s1", Places.munich), Self.pin("s2", Places.munich)]
        #expect(MapPins.visible(spot, in: view, spacingPoints: 0).map(\.memberIDs) == [["s1", "s2"]])
        #expect(MapPins.visible(spot, in: view, spacingPoints: .infinity).map(\.memberIDs) == [["s1", "s2"]])
    }

    /// A broken camera state or no room for pins shows nothing rather than stopping the app; pins
    /// without a valid coordinate are not drawn.
    @Test func brokenViewsShowNothing() {
        let pins = [Self.pin("a", Places.regensburg, count: 2), Self.pin("broken", Self.at(.nan, 12), count: 9), Self.pin("beyond", Self.at(91, 0), count: 9),
                    Self.pin("endless", Self.at(49, .infinity), count: 9)]
        let good = Self.view(Places.regensburg, widthMeters: 100_000)
        #expect(MapPins.visible(pins, in: good).map(\.memberIDs) == [["a"]])
        let broken = [MapViewport(center: Places.regensburg, widthMeters: 0, widthPoints: 390, heightPoints: 844),
                      MapViewport(center: Self.at(.nan, 0), widthMeters: 100_000, widthPoints: 390, heightPoints: 844),
                      MapViewport(center: Places.regensburg, widthMeters: .infinity, widthPoints: 390, heightPoints: 844),
                      MapViewport(center: Places.regensburg, widthMeters: .leastNonzeroMagnitude, widthPoints: 390, heightPoints: 844),
                      MapViewport(center: Places.regensburg, widthMeters: 100_000, widthPoints: 0, heightPoints: 844),
                      MapViewport(center: Places.regensburg, widthMeters: 100_000, widthPoints: 390, heightPoints: -1)]
        for view in broken { #expect(MapPins.visible(pins, in: view).isEmpty) }
        #expect(MapPins.visible(pins, in: good, limit: 0).isEmpty)
        #expect(MapPins.visible([], in: good).isEmpty)
        // A metre filling 10^30 points: screen positions far beyond any integer, still grouped.
        let absurd = MapViewport(center: Places.regensburg, widthMeters: 1, widthPoints: 1e30, heightPoints: 1e30)
        let beside = Self.pin("beside", Self.east(of: Places.regensburg, kilometers: 0.0003))
        #expect(MapPins.visible(pins + [beside], in: absurd).map(\.memberIDs) == [["a"], ["beside"]])
        #expect(MapPins.visible(pins + [beside], in: absurd, limit: 1).map(\.memberIDs) == [["a", "beside"]])
    }

    /// The projection behind it keeps every point's true distance from the view's centre and its
    /// direction, across the antimeridian and round a pole, and goes back to the same point.
    @Test func theProjectionKeepsDistanceAndDirection() {
        let europe = AzimuthalEquidistantProjection(center: Places.regensburg)
        let munich = europe.project(Places.munich)
        #expect(abs(hypot(munich.x, munich.y) - GeoMath.distance(Places.regensburg, Places.munich)) < 0.01)
        #expect(munich.x < 0 && munich.y < 0 && abs(munich.y) > abs(munich.x))
        #expect(europe.project(Places.tokyo).angle < .pi / 2 && europe.project(Places.honolulu).angle > .pi / 2)
        let pacific = AzimuthalEquidistantProjection(center: Self.at(-16, 180))
        #expect(pacific.project(Places.suva).x < 0 && pacific.project(Places.apia).x > 0)
        let northPole = AzimuthalEquidistantProjection(center: Self.at(90, 0))
        let svalbard = northPole.project(Places.longyearbyen)
        #expect(abs(hypot(svalbard.x, svalbard.y) - GeoMath.distance(Self.at(90, 0), Places.longyearbyen)) < 0.01)
        let southPole = AzimuthalEquidistantProjection(center: Self.at(-90, 0))
        for projection in [europe, pacific, northPole, southPole] {
            for place in [Places.munich, Places.tokyo, Places.auckland, Places.apia, Places.suva, Places.ushuaia, Places.longyearbyen] {
                let p = projection.project(place)
                #expect(GeoMath.distance(projection.unproject(x: p.x, y: p.y), place) < 0.01)
            }
        }
    }

    /// 20,000 place pins filling the view: sorted once, and in each grouping pass (three here,
    /// the spacing growing until at most 60 groups are left) a pin looks only at the groups in
    /// the squares around it. About 0.1 s in a debug build; the bound catches work that grows
    /// faster than the pins.
    @Test func manyPinsAreGroupedQuickly() {
        var random = MapRandom(seed: 1)
        let pins = (0..<20_000).map {
            Self.pin("place:\($0)", Self.at(46 + random.unit() * 6, 9.3 + random.unit() * 4.4), count: 1 + random.int(0..<100), level: .place)
        }
        let view = Self.view(Self.at(49, 11.5), widthMeters: 300_000)
        let clock = ThreadCPUClock()
        var groups: [MapPinGroup] = []
        var fastest = Duration.seconds(60)
        for _ in 0..<3 { fastest = min(fastest, clock.measure { groups = MapPins.visible(pins, in: view) }) }
        #expect(!groups.isEmpty && groups.count <= MapSummary.maxVisiblePins)
        #expect(MapPins.visible(pins, in: view, limit: 10_000).count > MapSummary.maxVisiblePins)
        let members = groups.flatMap(\.memberIDs)
        #expect(members.count > 15_000 && Set(members).count == members.count)
        #expect(fastest < .milliseconds(500))
    }

    // MARK: The first camera

    /// The first camera holds every trip: the focus of Lisbon, Rome and Reykjavík is a cap around
    /// their middle (`GeoMath.centroid`, in Brittany) reaching the farthest of them (Reykjavík).
    @Test func theFocusHoldsEveryDestination() throws {
        let places = [Places.lisbon, Places.rome, Places.reykjavik]
        let focus = try #require(MapPins.focus(on: places))
        #expect(GeoMath.distance(focus.center, try #require(GeoMath.centroid(places))) < 1)
        for place in places { #expect(GeoMath.distance(focus.center, place) <= focus.radiusMeters) }
        #expect(focus.radiusMeters == GeoMath.distance(focus.center, Places.reykjavik))
        #expect(abs(focus.radiusMeters - 2_001_000) < 1_000)
    }

    /// Across the antimeridian: the focus of Fiji and Samoa lies between them in the Pacific (not
    /// on the other side of the Earth, where the plain mean of their longitudes would put it).
    @Test func aFocusAcrossTheAntimeridian() throws {
        let focus = try #require(MapPins.focus(on: [Places.suva, Places.apia]))
        #expect(abs(focus.center.longitude) > 170 && focus.center.latitude < -10)
        #expect(abs(focus.radiusMeters - 575_000) < 1_000)
        for place in [Places.suva, Places.apia] { #expect(GeoMath.distance(focus.center, place) <= focus.radiusMeters) }
    }

    /// One trip, or trips close together, is never a street: the cap's radius is at least 300 km,
    /// a view of about 600 km. No trip, no focus; coordinates the library cannot have are left out.
    @Test func aSmallFocusIsNeverAStreet() throws {
        let one = try #require(MapPins.focus(on: [Places.regensburg]))
        #expect(GeoMath.distance(one.center, Places.regensburg) < 1)
        #expect(one.radiusMeters == 300_000)
        #expect(MapPins.focus(on: [Places.regensburg, Places.munich])?.radiusMeters == 300_000)
        #expect(MapPins.focus(on: []) == nil)
        #expect(MapPins.focus(on: [Self.at(0, 0), Self.at(.nan, 10), Self.at(95, 10), Self.at(10, 190)]) == nil)
        #expect(MapPins.focus(on: [Self.at(0, 0), Places.regensburg, Self.at(10, .infinity)]) == one)
    }

    /// The same destinations in any order give the same focus, bit for bit.
    @Test func anyOrderGivesTheSameFocus() throws {
        var random = MapRandom(seed: 9)
        let points = (0..<60).map { _ in Self.at(35 + random.unit() * 30, -10 + random.unit() * 40) }
        let reference = try #require(MapPins.focus(on: points))
        for seed in UInt64(1)...10 { #expect(MapPins.focus(on: Self.shuffled(points, seed: seed)) == reference) }
    }

    /// Destinations spread evenly round the Earth have no middle: the cap is centred on the first
    /// of them (by latitude, then longitude) and still holds them all.
    @Test func destinationsWithoutAMiddle() throws {
        let focus = try #require(MapPins.focus(on: [Self.at(10, 20), Self.at(-10, -160)]))
        #expect(focus.center == Self.at(-10, -160))
        #expect(abs(focus.radiusMeters - .pi * GeoMath.earthRadiusMeters) < 1)
    }
}
