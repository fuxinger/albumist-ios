import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Home from end to end (concept §8, §11): only ever rounded, an arc from the home of each trip's
/// time, no arcs without a home, only photos at home and then a small start, a trip's photos at
/// home never drawn, no home in the stored summary, the diagnostic report or the share images.
extension MapSummaryTests {
    @Test func homeIsOnlyEverRounded() throws {
        let home = try #require(Self.summary.home)
        #expect(home.countryCode == "DE")
        #expect(home.coordinate == MapHome.rounded(World.home))
        #expect(home.coordinate != World.home)
        #expect(GeoMath.distance(home.coordinate, World.home) <= 7_200)
        // Every trip starts at that same rounded point.
        #expect(Self.summary.trips.allSatisfy { $0.home == home })
        #expect(Self.summary.arcs.allSatisfy { $0.from == home.coordinate })
    }

    @Test func oneArcPerDestinationFromTheHomeOfTheTripsTime() throws {
        let arcs = Self.summary.arcs
        #expect(arcs.count == 4)
        #expect(Set(arcs.flatMap(\.tripIDs)) == [World.iceland, World.portugal, World.passauTrip, World.straubingTrip])
        #expect(arcs.count <= MapSummary.maxArcs)
        // After a move the trips before it start at the old home, the house is the new one.
        let moved = World(homeUntil2024: World.hamburg)
        let settings = HomeSettings(former: [FormerHome(place: HomePlace(center: World.hamburg, components: PlaceComponents(isoCountryCode: "DE")),
                                                        until: MapFixture.date("2024-01-01"))])
        let summary = MapSummary.build(moved.input(settings: settings))
        #expect(summary.trip(World.iceland)?.home?.coordinate == MapHome.rounded(World.hamburg))
        #expect(summary.trip(World.portugal)?.home?.coordinate == MapHome.rounded(World.home))
        #expect(summary.home?.coordinate == MapHome.rounded(World.home))
        let iceland = try #require(summary.arcs.first { $0.tripIDs.contains(World.iceland) })
        #expect(iceland.from == MapHome.rounded(World.hamburg))
    }

    /// Concept §11, "Kein Zuhause bekannt": no arcs, only pins; kilometres only on site.
    @Test func withoutAHomeNoArcsAndOnlyKilometresOnSite() throws {
        let summary = MapSummary.build(Self.world.input(settings: HomeSettings(mode: .none)))
        #expect(summary.home == nil)
        #expect(summary.arcs.isEmpty)
        #expect(!summary.pins.isEmpty)
        #expect(summary.trips.allSatisfy { $0.home == nil && $0.stats.metersFromHome == nil })
        #expect(summary.trips.allSatisfy { abs($0.stats.metersTraveled - $0.stats.metersOnSite) < 1 })
        #expect(summary.numbers.record(.farthest) == nil)
    }

    /// Concept §11, "Nur Fotos zu Hause" and "Kleiner Anfang".
    @Test func onlyHomeThenASmallStart() throws {
        let homeOnly = Self.world.facts.filter { $0.tripID == nil }
        let empty = MapSummary.build(MapInput(facts: homeOnly, trips: [], detectedHome: DetectedHome(center: World.home, since: nil, photoDays: 400),
                                              calendar: MapFixture.calendar, now: World.now))
        #expect(empty.trips.isEmpty && empty.arcs.isEmpty && empty.pins.isEmpty && empty.years.isEmpty)
        #expect(empty.focus == nil)
        #expect(empty.numbers.trips == 0)
        // The home country counts, as in the travel atlas.
        #expect(empty.countries.map(\.code) == ["DE"])

        // A small start: the globe comes closer, every destination still in view.
        let focus = try #require(Self.summary.focus)
        #expect(focus.radiusMeters < 5_000_000)
        #expect(Self.summary.trips.allSatisfy { GeoMath.distance(focus.center, $0.geometry.destination) <= focus.radiusMeters + 1 })
        #expect(Self.summary.pins.count <= MapSummary.maxVisiblePins)
    }

    /// Photos of a trip taken at home (packing the evening before) never put anything on the
    /// map: the exact home would be a place, a pin and the start of the route (review finding 2).
    @Test func aTripsPhotosAtHomeAreNeverDrawn() throws {
        var packing = Self.world
        let packed = MapFixture.members(MapFixture.burst("packing", count: 4, at: World.home, day: "2024-04-01", hour: 18, jitterMeters: 10,
                                                         country: "DE", town: "Regensburg", atHome: true), of: World.portugal)
        packing.facts += packed
        let index = try #require(packing.trips.firstIndex { $0.id == World.portugal })
        packing.trips[index] = MapFixture.trip(World.portugal, packing.facts.filter { $0.tripID == World.portugal })
        let summary = MapSummary.build(packing.input())
        let trip = try #require(summary.trip(World.portugal))
        let nearHome = { (coordinate: GeoCoordinate) in GeoMath.distance(coordinate, World.home) < 30_000 }
        #expect(!trip.geometry.places.contains { nearHome($0.coordinate) })
        #expect(!trip.geometry.dayPlaces.contains { nearHome($0.coordinate) })
        #expect(!nearHome(trip.geometry.destination))
        #expect(!summary.pins.contains { nearHome($0.coordinate) })
        #expect(trip.geometry.countryPhotos["DE"] == nil)
        // They are still photos of the trip, as its album shows them.
        #expect(trip.geometry.photoCount == (Self.summary.trip(World.portugal)?.geometry.photoCount ?? 0) + 4)
        // A trip of nothing but photos at home has nothing to draw.
        var onlyHome = Self.world
        let home = MapFixture.members(MapFixture.burst("garden", count: 6, at: World.home, day: "2025-05-10", jitterMeters: 10, country: "DE",
                                                       town: "Regensburg", atHome: true), of: AlbumistID("garden"))
        onlyHome.facts += home
        onlyHome.trips.append(MapFixture.trip(AlbumistID("garden"), home))
        #expect(MapSummary.build(onlyHome.input()).trip(AlbumistID("garden")) == nil)
    }

    /// Concept §8: the stored summary knows home only rounded, the diagnostic report no
    /// coordinate at all.
    @Test func storedSummaryAndDiagnosticsGiveNoHomeAway() throws {
        let data = try JSONEncoder().encode(Self.summary)
        let json = try #require(String(data: data, encoding: .utf8))
        for exact in ["49.0134", "12.1016", "49.013", "12.101"] { #expect(!json.contains(exact), "\(exact)") }
        #expect(try JSONDecoder().decode(MapSummary.self, from: data) == Self.summary)

        let lines = MapDiagnostics.lines(for: Self.summary, buildMilliseconds: 42).joined(separator: "\n")
        let home = try #require(Self.summary.home).coordinate
        var coordinates = [home, World.home, World.passau, World.straubing]
        coordinates += Self.summary.trips.flatMap { $0.geometry.places.map(\.coordinate) }
        for c in coordinates {
            for text in [String(format: "%.1f", c.latitude), String(format: "%.1f", c.longitude)] where text.count > 3 {
                #expect(!lines.contains(text), "\(text)")
            }
        }
        for word in ["Regensburg", "Reykjavík", "Straubing", "IS", "PT", "DE"] { #expect(!lines.contains(word), "\(word)") }
    }

    /// Concept §8: the share images get no home, nothing from within 50 km of it, arcs only from
    /// the middle of the home country.
    @Test func shareImagesNeverShowHome() throws {
        let summary = Self.summary
        let geometry = CountryGeometry(squareKilometers: ["DE": 357_000, "IS": 103_000, "PT": 92_000],
                                       centers: ["DE": MapFixture.at(51.0, 10.4), "IS": MapFixture.at(64.9, -18.6), "PT": MapFixture.at(39.6, -8.0)])
        let world = MapShare.world(summary, geometry: geometry)
        #expect(world.arcs.allSatisfy { $0.from == MapFixture.at(51.0, 10.4) })
        #expect(!world.arcs.isEmpty)
        let passport = MapShare.passport(summary)
        #expect(passport.stamps.map(\.countryCode).sorted() == ["DE", "IS", "PT"])
        let year = try #require(MapShare.year(2024, of: summary))
        let postcards = summary.trips.compactMap { MapShare.postcard(for: $0.id, in: summary) }
        // Every trip but Straubing, under 50 km from home: its postcard would name a place near
        // home, and none of its photos may be shown.
        #expect(postcards.count == summary.trips.count - 1)
        #expect(MapShare.postcard(for: World.straubingTrip, in: summary) == nil)

        var points = world.arcs.flatMap { [$0.from, $0.to] } + world.destinations
        points += postcards.flatMap(\.route)
        for point in points { #expect(GeoMath.distance(point, World.home) >= MapShare.nearHomeMeters, "\(point)") }
        #expect(!points.isEmpty)
        let nearHome = Set(Self.world.facts.filter { $0.tripID == World.straubingTrip || $0.atHome }.map(\.id))
        let photos = year.photos + postcards.flatMap(\.photos)
        #expect(photos.allSatisfy { !nearHome.contains($0.asset) })
        // Nothing in the share data spells the rounded home either.
        let home = try #require(summary.home).coordinate
        let encoder = JSONEncoder()
        let parts = try [encoder.encode(world), encoder.encode(passport), encoder.encode(year)] + postcards.map { try encoder.encode($0) }
        let text = try parts.map { try #require(String(bytes: $0, encoding: .utf8)) }.joined(separator: "\n")
        #expect(!text.contains(String(format: "%.4f", home.latitude)) && !text.contains(String(format: "%.4f", home.longitude)))
    }
}
