import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// Privacy by construction (concept §8, "Für alle drei gibt es Tests"): the share data has no
/// field for home, and nothing in it comes from within 50 km of home: no point, no arc end, no
/// route point, no photo, no place name. Arcs start in the middle of the home country, and not
/// at all from a small or unknown one.
@Suite("Map share privacy")
struct SharePrivacyTests {
    typealias Place = MapHandmade.Places
    let geometry = MapHandmade.countryGeometry

    /// Home in the Regensburg area (49.0, 12.1). A weekend in Straubing and Bogen (37 and 44 km
    /// away), a road trip from Abensberg (28 km) to Munich, Innsbruck and Verona and back to
    /// Abensberg, Rome, Iceland; a 2015 trip from the earlier home in Hamburg to Regensburg, where
    /// the user lives now, and a 2016 weekend from there in Lüneburg (43 km from Hamburg); a 2010
    /// trip to Kelheim (18 km) before any home was known; a 2021 stay in Munich with a day out to
    /// Abensberg; a 2024 visit to Hamburg.
    static func library() -> MapSummary {
        let trips = [
            MapHandmade.trip("weekend", "2023-04-15", [
                MapHandmade.place(Place.straubing, "Straubing", "DE", photos: 30, covers: ["straubing-1", "straubing-2"]),
                MapHandmade.place(Place.bogen, "Bogen", "DE", photos: 12, covers: ["bogen-1"]),
            ]),
            MapHandmade.trip("road-trip", "2023-07-01", [
                MapHandmade.place(Place.abensberg, "Abensberg", "DE", photos: 20, covers: ["abensberg-1"]),
                MapHandmade.place(MapFixture.Places.munich, "München", "DE", photos: 40, covers: ["munich-1"]),
                MapHandmade.place(Place.innsbruck, "Innsbruck", "AT", photos: 35, covers: ["innsbruck-1"]),
                MapHandmade.place(Place.verona, "Verona", "IT", photos: 50, covers: ["verona-1", "verona-2"]),
            ], visits: [0, 1, 2, 3, 0]),
            MapHandmade.trip("rome", "2022-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80, covers: ["rome-1", "rome-2"]),
                                                    MapHandmade.place(Place.ciampino, "Ciampino", "IT", photos: 20, covers: ["ciampino-1"])]),
            MapHandmade.trip("iceland", "2023-06-14", [MapHandmade.place(MapFixture.Places.reykjavik, "Reykjavík", "IS", photos: 50, covers: ["reykjavik-1"]),
                                                       MapHandmade.place(MapFixture.Places.vik, "Vík", "IS", photos: 20, covers: ["vik-1"])]),
            MapHandmade.trip("from-hamburg", "2015-06-01", [
                MapHandmade.place(Place.regensburgOldTown, "Regensburg", "DE", photos: 25, covers: ["regensburg-1"]),
                MapHandmade.place(Place.walhalla, "Walhalla", "DE", photos: 10, covers: ["walhalla-1"]),
            ], home: MapHandmade.hamburgHome),
            MapHandmade.trip("lueneburg", "2016-05-01", [MapHandmade.place(Place.lueneburg, "Lüneburg", "DE", photos: 20, covers: ["lueneburg-1"])],
                             home: MapHandmade.hamburgHome),
            MapHandmade.trip("kelheim", "2010-08-01", [MapHandmade.place(Place.kelheim, "Kelheim", "DE", photos: 15, covers: ["kelheim-1"])], home: nil),
            MapHandmade.trip("munich", "2021-03-01", [MapHandmade.place(MapFixture.Places.munich, "München", "DE", photos: 40, covers: ["munich-2"]),
                                                      MapHandmade.place(Place.abensberg, "Abensberg", "DE", photos: 10, covers: ["abensberg-2"])],
                             visits: [0, 1, 0]),
            MapHandmade.trip("hamburg", "2024-02-01", [MapHandmade.place(Place.hamburg, "Hamburg", "DE", photos: 30, covers: ["hamburg-1"])]),
        ]
        let countries = [
            MapHandmade.country("DE", "2009-03-01", trips: ["kelheim", "from-hamburg", "lueneburg", "munich", "weekend", "road-trip", "hamburg"],
                                region: .westernEurope),
            MapHandmade.country("IT", "2022-05-02", trips: ["rome", "road-trip"], region: .southernEurope),
            MapHandmade.country("IS", "2023-06-14", trips: ["iceland"], region: .northernEurope),
            MapHandmade.country("AT", "2023-07-03", trips: ["road-trip"], region: .westernEurope),
        ]
        let numbers = WorldNumbers(countries: 4, states: 4, worldShare: 4.0 / 195, continents: [ContinentTally(continent: .europe, visited: 4, total: 44)],
                                   trips: 9, firstTripYear: 2010, firstCountryYear: 2009, metersTraveled: 12_345_678, year: 2026)
        let years = [2010, 2015, 2016, 2021, 2022, 2023, 2024].map { year in
            MapYear(year: year, tripIDs: trips.filter { MapFixture.calendar.component(.year, from: $0.geometry.start) == year }.map(\.id),
                    newCountries: [], countriesSoFar: 0, tripsSoFar: 0, daysAway: 3, photoCount: 100, metersTraveled: 2_000_000)
        }
        return MapHandmade.summary(trips: trips, countries: countries, numbers: numbers, years: years)
    }

    /// Every share value of `summary`, populated: the world, the passport, every year, every trip's
    /// postcard.
    static func shareValues(of summary: MapSummary, geometry: CountryGeometry = MapHandmade.countryGeometry) -> [Any] {
        var values: [Any] = [MapShare.world(summary, geometry: geometry), MapShare.passport(summary, newCountries: ["IS"])]
        values += summary.years.compactMap { MapShare.year($0.year, of: summary) }
        values += summary.trips.compactMap { MapShare.postcard(for: $0.id, in: summary) }
        return values
    }

    @Test func shareDataHasNoPlaceForHome() throws {
        let summary = Self.library()
        let values = Self.shareValues(of: summary)
        // Populated, so the walk below sees every nested type.
        let world = try #require(values.first as? ShareWorld)
        #expect(!world.arcs.isEmpty && !world.destinations.isEmpty && !world.countries.isEmpty)
        #expect(values.contains { ($0 as? SharePassport)?.stamps.isEmpty == false })
        #expect(values.contains { ($0 as? ShareYear)?.photos.isEmpty == false })
        #expect(values.contains { ($0 as? SharePostcard).map { !$0.route.isEmpty && !$0.photos.isEmpty } == true })
        var labels: [String] = []
        var types: [String] = []
        for value in values {
            Self.walk(value) { label, child in
                if let label { labels.append(label) }
                types.append(String(describing: type(of: child)))
            }
        }
        #expect(labels.count > 100)
        #expect(!labels.contains { $0.lowercased().contains("home") || $0.lowercased().contains("zuhause") })
        #expect(!types.contains { $0.contains("RoundedHome") || $0.lowercased().contains("home") })
        // The walk finds a home where there is one: in the summary, which the app alone sees.
        var summaryHomes = 0
        var summaryLabels: [String] = []
        Self.walk(summary) { label, child in
            if Self.exactly(child, as: RoundedHome.self) != nil { summaryHomes += 1 }
            if let label { summaryLabels.append(label) }
        }
        #expect(summaryHomes == 1 + summary.trips.filter { $0.home != nil }.count)
        #expect(summaryLabels.contains("home"))
    }

    @Test func nothingFromWithin50KilometresOfHome() throws {
        let summary = Self.library()
        let home = MapHandmade.home.coordinate
        #expect(MapShare.nearHomeMeters == 50_000)
        let coordinates = Self.coordinates(in: Self.shareValues(of: summary))
        #expect(coordinates.count > 10)
        for coordinate in coordinates {
            // 50 km from the real home, wherever in its 10 km cell it lies.
            #expect(GeoMath.distance(coordinate, home) >= MapShare.nearHomeMeters + MapHome.maximumRoundingMeters, "\(coordinate) is near home")
        }
        // Every arc starts exactly in the middle of the home country.
        let world = MapShare.world(summary, geometry: geometry)
        let middle = try #require(geometry.centers["DE"])
        #expect(!world.arcs.isEmpty && world.arcs.allSatisfy { $0.from == middle })
        // The weekend 37 and 44 km away gets no postcard: its name would name a place near home,
        // and none of its photos may be shown. The road trip's route starts at Munich, without
        // Abensberg at either end.
        #expect(MapShare.postcard(for: AlbumistID("weekend"), in: summary) == nil)
        let road = try #require(MapShare.postcard(for: AlbumistID("road-trip"), in: summary))
        #expect(road.route == [MapFixture.Places.munich, Place.innsbruck, Place.verona])
        // The trip from the earlier home to where the user lives now shows nothing of it: neither
        // on its postcard nor as a destination or arc of the world map.
        #expect(MapShare.postcard(for: AlbumistID("from-hamburg"), in: summary) == nil)
        #expect(!world.destinations.contains(Place.regensburgOldTown))
        // Away from the home of the trip's time too: the weekend in Lüneburg, 43 km from Hamburg
        // where the user lived then, is far from today's home and still not shown.
        #expect(MapShare.postcard(for: AlbumistID("lueneburg"), in: summary) == nil)
        #expect(!world.destinations.contains(Place.lueneburg) && !world.arcs.contains { $0.to == Place.lueneburg })
        for trip in summary.trips {
            guard let home = trip.home, let card = MapShare.postcard(for: trip.id, in: summary) else { continue }
            #expect(card.route.allSatisfy { GeoMath.distance($0, home.coordinate) >= MapShare.nearHomeMeters })
        }
        // Munich, a day out to Abensberg and back: without Abensberg, Munich is left on both sides
        // of it, one place, so no route (never a line from a place to itself).
        let munich = try #require(MapShare.postcard(for: AlbumistID("munich"), in: summary))
        #expect(munich.route.isEmpty)
        #expect(munich.photos.map(\.asset) == ["munich-2"])
    }

    @Test func aSmallOrUnknownHomeCountryGetsNoArcs() throws {
        // Lived in Luxembourg, the middle of which is almost anyone's home there; then moved to
        // the Regensburg area.
        let luxembourg = RoundedHome(coordinate: MapFixture.Places.luxembourg, countryCode: "LU")
        let fromLuxembourg = [
            MapHandmade.trip("rome", "2018-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)], home: luxembourg),
            MapHandmade.trip("iceland", "2019-06-14", [MapHandmade.place(MapFixture.Places.reykjavik, "Reykjavík", "IS", photos: 50)], home: luxembourg),
        ]
        let small = MapShare.world(MapHandmade.summary(home: luxembourg, trips: fromLuxembourg), geometry: geometry)
        #expect(small.arcs.isEmpty)
        #expect(small.destinations == [MapFixture.Places.rome, MapFixture.Places.reykjavik])
        // After the move only the trips from Germany get arcs.
        let lisbon = MapHandmade.trip("lisbon", "2022-10-02", [MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 40)])
        let moved = MapShare.world(MapHandmade.summary(trips: fromLuxembourg + [lisbon]), geometry: geometry)
        let germany = try #require(geometry.centers["DE"])
        #expect(moved.arcs == [ShareArc(from: germany, to: MapFixture.Places.lisbon, weight: 1)])
        // An unknown home country, or one the world map does not know: no arcs either.
        for country in [nil, "XX"] as [String?] {
            let home = RoundedHome(coordinate: MapHandmade.home.coordinate, countryCode: country)
            let trips = fromLuxembourg.map { trip -> MapTrip in
                var trip = trip
                trip.home = home
                return trip
            }
            #expect(MapShare.world(MapHandmade.summary(home: home, trips: trips), geometry: geometry).arcs.isEmpty)
        }
    }

    @Test func noPhotoAndNoPlaceNameFromNearHome() {
        let summary = Self.library()
        let values = Self.shareValues(of: summary)
        let photos = Self.photos(in: values)
        let near: Set<AssetID> = ["straubing-1", "straubing-2", "bogen-1", "abensberg-1", "abensberg-2", "regensburg-1", "walhalla-1",
                                  "kelheim-1", "lueneburg-1"]
        let nearNames: Set<String> = ["Straubing", "Bogen", "Abensberg", "Regensburg", "Walhalla", "Kelheim", "Lüneburg"]
        #expect(!photos.isEmpty)
        #expect(!photos.contains { near.contains($0.asset) })
        #expect(!photos.contains { $0.placeName.map(nearNames.contains) ?? false })
        // What may be shown is there: the road trip's photos from Munich on.
        let road = MapShare.postcard(for: AlbumistID("road-trip"), in: summary)
        #expect(road?.photos.map(\.asset) == ["verona-1", "munich-1", "innsbruck-1", "verona-2"])
        let year = MapShare.year(2023, of: summary)
        #expect(year?.photos.map(\.asset) == ["verona-1", "reykjavik-1", "munich-1", "vik-1", "innsbruck-1", "verona-2"])
    }

    @Test func theRoundedHomeIsNowhereInTheShareData() {
        let summary = Self.library()
        let homes = [MapHandmade.home.coordinate, MapHandmade.hamburgHome.coordinate]
        let coordinates = Self.coordinates(in: Self.shareValues(of: summary))
        #expect(!coordinates.isEmpty)
        #expect(!coordinates.contains { homes.contains($0) })
        // Not even when a trip's own place lies at the rounded home: it is left out, not moved.
        var atHome = summary
        atHome.trips.append(MapHandmade.trip("garden", "2025-05-01", [MapHandmade.place(MapHandmade.home.coordinate, "Garten", "DE", photos: 40,
                                                                                         covers: ["garden-1"])], home: nil))
        let more = Self.shareValues(of: atHome)
        #expect(!Self.coordinates(in: more).contains { homes.contains($0) })
        #expect(!Self.photos(in: more).contains { $0.asset == "garden-1" })
    }

    /// Every home the summary knows keeps its distance on every image, from every trip (a trip
    /// from Hamburg to near the earlier home in Munich), and the 50 km hold from the real home
    /// wherever in its 10 km cell it lies (review finding 12).
    @Test func everyHomeKeepsItsDistanceFromTheRealHome() throws {
        let munichHome = RoundedHome(coordinate: MapHome.rounded(MapFixture.Places.munich), countryCode: "DE")
        var rome = MapHandmade.trip("rome-2015", "2015-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 40, covers: ["rome-1"])])
        rome.home = munichHome
        // Freising: 33 km from Munich, the home of 2015, far from Hamburg and from today's home.
        let freisingPlace = MapFixture.at(48.4029, 11.7488)
        var freising = MapHandmade.trip("freising-2018", "2018-07-01", [MapHandmade.place(freisingPlace, "Freising", "DE", photos: 30,
                                                                                          covers: ["freising-1"])])
        freising.home = MapHandmade.hamburgHome
        // 53 km north of today's rounded home: maybe only 46 km from the real one. 70 km: far enough.
        let today = MapHandmade.home.coordinate
        let close = MapFixture.at(today.latitude + 53_000 / GeoMath.metersPerDegreeLatitude, today.longitude)
        let farther = MapFixture.at(today.latitude + 70_000 / GeoMath.metersPerDegreeLatitude, today.longitude)
        let near = MapHandmade.trip("north-53", "2020-03-01", [MapHandmade.place(close, "Nah", "DE", photos: 30, covers: ["near-1"])])
        let far = MapHandmade.trip("north-70", "2020-04-01", [MapHandmade.place(farther, "Weiter", "DE", photos: 30, covers: ["far-1"])])
        let summary = MapHandmade.summary(trips: [rome, freising, near, far],
                                          countries: [MapHandmade.country("DE", "2015-01-01", trips: ["freising-2018", "north-53", "north-70"],
                                                                          region: .westernEurope),
                                                      MapHandmade.country("IT", "2015-05-02", trips: ["rome-2015"], region: .southernEurope)])
        #expect(MapShare.postcard(for: AlbumistID("freising-2018"), in: summary) == nil)
        #expect(MapShare.postcard(for: AlbumistID("north-53"), in: summary) == nil)
        #expect(MapShare.postcard(for: AlbumistID("north-70"), in: summary)?.photos.map(\.asset) == ["far-1"])
        #expect(MapShare.postcard(for: AlbumistID("rome-2015"), in: summary)?.photos.map(\.asset) == ["rome-1"])
        let world = MapShare.world(summary, geometry: geometry)
        #expect(!world.destinations.contains(freisingPlace) && !world.destinations.contains(close))
        #expect(world.destinations.contains(farther) && world.destinations.contains(MapFixture.Places.rome))
        let values = Self.shareValues(of: summary)
        #expect(!Self.photos(in: values).contains { $0.asset == "freising-1" || $0.asset == "near-1" })
        for coordinate in Self.coordinates(in: values) {
            for home in [today, munichHome.coordinate, MapHandmade.hamburgHome.coordinate] {
                #expect(GeoMath.distance(coordinate, home) >= MapShare.nearHomeMeters + MapHome.maximumRoundingMeters)
            }
        }
    }

    @Test func aHomeThatIsNoNumberKeepsEverythingOff() throws {
        // The summary never has one, but nothing can be measured as far enough from it: without
        // data, privacy wins.
        let broken = RoundedHome(coordinate: GeoCoordinate(latitude: .nan, longitude: 12.1), countryCode: "DE")
        // As today's home: nothing of any trip.
        var today = Self.library()
        today.home = broken
        let values = Self.shareValues(of: today)
        #expect(Self.coordinates(in: values).isEmpty)
        #expect(Self.photos(in: values).isEmpty)
        // As the home of one trip's time: every home counts for every trip, so nothing at all.
        var once = Self.library()
        let index = try #require(once.trips.firstIndex { $0.id == AlbumistID("rome") })
        once.trips[index].home = broken
        #expect(MapShare.postcard(for: AlbumistID("rome"), in: once) == nil)
        let onceValues = Self.shareValues(of: once)
        #expect(Self.coordinates(in: onceValues).isEmpty)
        #expect(Self.photos(in: onceValues).isEmpty)
    }

    // MARK: - Reflection

    /// Calls `visit` for `value` and every value stored inside it, depth first, with the label it
    /// is stored under (`nil` for an element of a collection). An optional is visited itself (so
    /// an empty one still shows its label and type) and then its value, if it has one.
    static func walk(_ value: Any, label: String? = nil, _ visit: (String?, Any) -> Void) {
        visit(label, value)
        for child in Mirror(reflecting: value).children {
            walk(child.value, label: child.label, visit)
        }
    }

    /// `value` when it is a `T` itself; `nil` for an optional holding one, which `as?` would
    /// unwrap, so nothing the walk visits is counted twice.
    static func exactly<T>(_ value: Any, as type: T.Type) -> T? {
        Swift.type(of: value) == type ? value as? T : nil
    }

    static func coordinates(in values: [Any]) -> [GeoCoordinate] {
        var found: [GeoCoordinate] = []
        for value in values {
            walk(value) { _, child in if let coordinate = exactly(child, as: GeoCoordinate.self) { found.append(coordinate) } }
        }
        return found
    }

    static func photos(in values: [Any]) -> [SharePhoto] {
        var found: [SharePhoto] = []
        for value in values {
            walk(value) { _, child in if let photo = exactly(child, as: SharePhoto.self) { found.append(photo) } }
        }
        return found
    }
}
