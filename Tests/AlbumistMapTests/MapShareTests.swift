import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The data of the four share motifs (concept §4.11): world map, passport, travel year, postcard.
/// What they leave out near home is `SharePrivacyTests`.
@Suite("Map share data")
struct MapShareTests {
    typealias Place = MapHandmade.Places
    let geometry = MapHandmade.countryGeometry

    /// Home in the Regensburg area; Rome twice (its centre, then by Ciampino airport), Florence,
    /// Iceland and Japan.
    static func library() -> MapSummary {
        let trips = [
            MapHandmade.trip("rome-2019", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80, covers: ["rome-1", "rome-2"])]),
            MapHandmade.trip("florence-2021", "2021-09-12", [MapHandmade.place(MapFixture.Places.florence, "Florenz", "IT", photos: 60,
                                                                               covers: ["florence-1"])]),
            MapHandmade.trip("iceland-2023", "2023-06-14", [
                MapHandmade.place(MapFixture.Places.reykjavik, "Reykjavík", "IS", photos: 50, covers: ["reykjavik-1", "reykjavik-2"]),
                MapHandmade.place(MapFixture.Places.vik, "Vík", "IS", photos: 20, covers: ["vik-1"]),
            ]),
            // Left at 20:00 UTC on 31 March: in Tokyo already 1 April.
            MapHandmade.trip("japan-2024", "2024-03-31 20:00", [
                MapHandmade.place(MapFixture.Places.tokyo, "Tokio", "JP", photos: 60, covers: ["tokyo-1", "tokyo-2"]),
                MapHandmade.place(Place.kyoto, "Kyoto", "JP", photos: 30, covers: ["kyoto-1"]),
            ], title: "Japan", timeZone: "Asia/Tokyo"),
            MapHandmade.trip("rome-2024", "2024-04-10", [
                MapHandmade.place(Place.ciampino, "Ciampino", "IT", photos: 120, covers: ["ciampino-1", "ciampino-2"]),
            ]),
        ]
        let countries = [
            MapHandmade.country("JP", "2024-03-31 20:00", trips: ["japan-2024"], region: .easternAsia),
            MapHandmade.country("IT", "2019-05-02", trips: ["rome-2019", "florence-2021", "rome-2024"], region: .southernEurope),
            MapHandmade.country("DE", "2009-03-01", trips: [], region: .westernEurope),
            MapHandmade.country("IS", "2023-06-14", trips: ["iceland-2023"], region: .northernEurope),
        ]
        let continents = [ContinentTally(continent: .africa, visited: 0, total: 54), ContinentTally(continent: .asia, visited: 1, total: 48),
                          ContinentTally(continent: .europe, visited: 3, total: 44), ContinentTally(continent: .northAmerica, visited: 0, total: 23),
                          ContinentTally(continent: .oceania, visited: 0, total: 14), ContinentTally(continent: .southAmerica, visited: 0, total: 12)]
        let numbers = WorldNumbers(countries: 4, states: 4, worldShare: 4.0 / 195, continents: continents, cities: 7, trips: 5, firstTripYear: 2019,
                                   firstCountryYear: 2009, metersTraveled: 88_812_345, metersOnSite: 2_000_000, year: 2026)
        func year(_ year: Int, _ trips: [String], new: [String] = [], days: Int = 0, photos: Int = 0, meters: Double = 0) -> MapYear {
            MapYear(year: year, tripIDs: trips.map { AlbumistID($0) }, newCountries: new, countriesSoFar: 0, tripsSoFar: 0, daysAway: days,
                    photoCount: photos, metersTraveled: meters)
        }
        let years = [year(2019, ["rome-2019"], new: ["IT"], days: 1, photos: 80, meters: 1_600_000), year(2020, []),
                     year(2021, ["florence-2021"], days: 1, photos: 60, meters: 1_100_000),
                     year(2022, []), year(2023, ["iceland-2023"], new: ["IS"], days: 2, photos: 70, meters: 6_100_000),
                     year(2024, ["japan-2024", "rome-2024"], new: ["JP"], days: 4, photos: 210, meters: 21_049_999),
                     year(2025, []), year(2026, [])]
        return MapHandmade.summary(trips: trips, countries: countries, numbers: numbers, years: years)
    }

    @Test func worldTellsTheNumbersOfWhatItShows() {
        let library = Self.library()
        let world = MapShare.world(library, geometry: geometry)
        #expect(world.countries == ["DE", "IT", "IS", "JP"])
        #expect(world.states == 4)
        #expect(world.tripCount == 5)
        #expect(world.sinceYear == 2019)
        // "unterwegs" only against the Earth, never in kilometres (concept §8: no distance from
        // home on a share image).
        let traveled = library.trips.map(\.stats.metersTraveled).reduce(0, +)
        #expect(world.earth == EarthComparison(meters: traveled))
        #expect(world.earth != .none)
        // Europe and Asia; Antarctica would never count (it has no state).
        #expect(world.continents == 2)
        var withAntarctica = library
        withAntarctica.countries.append(MapHandmade.country("AQ", "2025-01-10", trips: [], region: nil, isState: false))
        #expect(MapShare.world(withAntarctica, geometry: geometry).continents == 2)
        #expect(MapShare.world(withAntarctica, geometry: geometry).states == 4)
        #expect(world.worldShare == 4.0 / 195)
    }

    /// While the analysis runs the app holds its numbers ("bisher"), but a share image counts what
    /// it shows: never "3 Länder" over two flags, or "6 Reisen" over five arcs (review finding 7).
    @Test func heldNumbersNeverReachAShareImage() {
        var library = Self.library()
        library.numbers.countries = 9
        library.numbers.states = 9
        library.numbers.trips = 12
        library.numbers.firstTripYear = 2001
        library.numbers.firstCountryYear = 1999
        library.numbers.metersTraveled = 400_000_000
        library.numbers.isPreliminary = true
        let world = MapShare.world(library, geometry: geometry)
        #expect(world.countries.count == 4 && world.states == 4 && world.tripCount == 5 && world.sinceYear == 2019)
        #expect(world.earth == EarthComparison(meters: library.trips.map(\.stats.metersTraveled).reduce(0, +)))
        let passport = MapShare.passport(library)
        #expect(passport.stamps.count == 4 && passport.tripCount == 5)
        // "gesammelt seit" is the first stamp's year (Germany, 2009).
        #expect(passport.sinceYear == 2009)
    }

    @Test func worldArcsStartInTheMiddleOfTheHomeCountryAndMergeLikeTheGlobe() throws {
        let world = MapShare.world(Self.library(), geometry: geometry)
        let middle = try #require(geometry.centers["DE"])
        #expect(world.arcs.allSatisfy { $0.from == middle })
        // Rome and Ciampino are one destination, ending at the trip with the most photos; the
        // strongest first, then the newest.
        #expect(world.arcs.map(\.to) == [Place.ciampino, MapFixture.Places.tokyo, MapFixture.Places.reykjavik, MapFixture.Places.florence])
        #expect(world.arcs.map(\.weight) == [2, 1, 1, 1])
        // The destinations, one point for Rome and Ciampino, the trip with the most photos first.
        #expect(world.destinations == [Place.ciampino, MapFixture.Places.tokyo, MapFixture.Places.reykjavik, MapFixture.Places.florence])
    }

    @Test func aMoveWithinTheCountryKeepsOneOrigin() {
        let before = MapHandmade.trip("rome-2017", "2017-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)],
                                      home: MapHandmade.hamburgHome)
        let after = MapHandmade.trip("rome-2022", "2022-04-10", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 90)])
        let world = MapShare.world(MapHandmade.summary(trips: [before, after]), geometry: geometry)
        #expect(world.arcs == [ShareArc(from: geometry.centers["DE"]!, to: MapFixture.Places.rome, weight: 2)])
        #expect(world.destinations == [MapFixture.Places.rome])
    }

    @Test func withoutAnyHomeThereAreDestinationsButNoArcs() {
        let trips = Self.library().trips.map { trip -> MapTrip in
            var trip = trip
            trip.home = nil
            return trip
        }
        let world = MapShare.world(MapHandmade.summary(home: nil, trips: trips), geometry: geometry)
        #expect(world.arcs.isEmpty)
        #expect(world.destinations.count == 4)
    }

    @Test func worldKeepsAtMostMaxArcs() {
        let trips = MapHandmade.manyDestinations(400) { $0 < 10 ? 1 : 0 }
        let world = MapShare.world(MapHandmade.summary(trips: trips), geometry: geometry)
        #expect(world.arcs.count == MapSummary.maxArcs)
        #expect(world.arcs.prefix(10).allSatisfy { $0.weight == 2 })
        #expect(world.destinations.count == 400)
    }

    @Test func worldAcrossTheAntimeridian() throws {
        let auckland = RoundedHome(coordinate: MapFixture.at(-36.85, 174.76), countryCode: "NZ")
        let west = MapHandmade.trip("taveuni-west", "2023-07-01", [MapHandmade.place(Place.taveuniWest, "Waiyevo", "FJ", photos: 60)], home: auckland)
        let east = MapHandmade.trip("taveuni-east", "2024-07-01", [MapHandmade.place(Place.taveuniEast, "Taveuni", "FJ", photos: 40)], home: auckland)
        let samoa = MapHandmade.trip("samoa", "2025-01-10", [MapHandmade.place(MapFixture.Places.apia, "Apia", "WS", photos: 30)], home: auckland)
        let world = MapShare.world(MapHandmade.summary(home: auckland, trips: [samoa, east, west]), geometry: geometry)
        let middle = try #require(geometry.centers["NZ"])
        #expect(world.arcs == [ShareArc(from: middle, to: Place.taveuniWest, weight: 2), ShareArc(from: middle, to: MapFixture.Places.apia, weight: 1)])
        #expect(world.destinations == [Place.taveuniWest, MapFixture.Places.apia])
    }

    @Test func passportStampsEachCountryWithItsFirstYear() {
        let passport = MapShare.passport(Self.library(), newCountries: ["jp"])
        #expect(passport.stamps == [
            SharePassport.Stamp(countryCode: "DE", year: 2009, isNew: false),
            SharePassport.Stamp(countryCode: "IT", year: 2019, isNew: false),
            SharePassport.Stamp(countryCode: "IS", year: 2023, isNew: false),
            SharePassport.Stamp(countryCode: "JP", year: 2024, isNew: true),
        ])
        #expect(passport.sinceYear == 2009)
        #expect(passport.tripCount == 5)
        #expect(MapShare.passport(Self.library()).stamps.allSatisfy { !$0.isNew })
    }

    /// The stamp's year is the one the time travel and the numbers give the country, worked
    /// out once in the device's calendar (`MapCountry.firstVisitYear`), not again here.
    @Test func passportYearIsTheYearOfTheTimeTravel() {
        // Landed in Tokyo on New Year's morning 2020 (still 2019 in UTC), on a device in Tokyo;
        // Germany first seen at home on New Year's Eve 2008 at 23:30 UTC, on a device in UTC.
        let japan = MapHandmade.trip("japan", "2019-12-31 22:00", [MapHandmade.place(MapFixture.Places.tokyo, "Tokio", "JP", photos: 40)],
                                     timeZone: "Asia/Tokyo")
        var countries = [MapHandmade.country("JP", "2019-12-31 23:30", trips: ["japan"], region: .easternAsia),
                         MapHandmade.country("DE", "2008-12-31 23:30", trips: [], region: .westernEurope)]
        countries[0].firstVisitYear = 2020
        let passport = MapShare.passport(MapHandmade.summary(trips: [japan], countries: countries))
        #expect(passport.stamps.map(\.countryCode) == ["DE", "JP"])
        #expect(passport.stamps.map(\.year) == [2008, 2020])
    }

    @Test func yearMotifTellsTheYearAndItsBestPhotos() throws {
        let year = try #require(MapShare.year(2024, of: Self.library()))
        #expect(year.year == 2024)
        #expect(year.newCountries == ["JP"])
        #expect(year.earth == .half)
        #expect(year.tripCount == 2)
        #expect(year.daysAway == 4)
        #expect(year.photoCount == 210)
        // Each trip's best photo first (the trip with the most photos first), then the others in
        // turn; within a trip one photo of each place before a second of any.
        #expect(year.photos.map(\.asset) == ["ciampino-1", "tokyo-1", "ciampino-2", "kyoto-1", "tokyo-2"])
        #expect(year.photos.map(\.placeName) == ["Ciampino", "Tokio", "Ciampino", "Kyoto", "Tokio"])
    }

    @Test func aYearWithoutATripHasNoMotif() {
        #expect(MapShare.year(2022, of: Self.library()) == nil)
        #expect(MapShare.year(1999, of: Self.library()) == nil)
        #expect(MapShare.year(2019, of: Self.library())?.tripCount == 1)
    }

    @Test func postcardTellsTheTrip() throws {
        let card = try #require(MapShare.postcard(for: AlbumistID("japan-2024"), in: Self.library()))
        #expect(card.title == "Japan")
        #expect(card.countryCode == "JP")
        // The first day where the trip was: 1 April in Tokyo (31 March in UTC).
        #expect(card.year == 2024 && card.month == 4)
        #expect(card.days == 2)
        #expect(card.photoCount == 90)
        #expect(card.placeCount == 2)
        // "vor Ort", Tokyo to Kyoto, about 360 km: "rund 400 km".
        #expect(card.kilometers == 400)
        #expect(card.route == [MapFixture.Places.tokyo, Place.kyoto])
        #expect(card.photos.map(\.asset) == ["tokyo-1", "kyoto-1", "tokyo-2"])
        #expect(MapShare.postcard(for: AlbumistID("nowhere"), in: Self.library()) == nil)
    }

    @Test func postcardPhotosStartAtTheDestinationAndTakeEachPlaceInTurn() throws {
        // Visited Vík first, but Reykjavík has the most photos: its photo leads. A photo listed
        // twice (it never is, but the image must not repeat it) is taken once.
        let trip = MapHandmade.trip("iceland", "2023-06-14", [
            MapHandmade.place(MapFixture.Places.vik, "Vík", "IS", photos: 20, covers: ["vik-1", "vik-2", "shared"]),
            MapHandmade.place(MapFixture.Places.reykjavik, "Reykjavík", "IS", photos: 50, covers: ["reykjavik-1", "shared"]),
            MapHandmade.place(MapFixture.Places.geysir, "Geysir", "IS", photos: 30, covers: ["geysir-1"]),
        ])
        let card = try #require(MapShare.postcard(for: trip.id, in: MapHandmade.summary(trips: [trip])))
        #expect(card.photos.map(\.asset) == ["reykjavik-1", "geysir-1", "vik-1", "shared", "vik-2"])
        #expect(card.photos.map(\.placeName) == ["Reykjavík", "Geysir", "Vík", "Reykjavík", "Vík"])
        #expect(card.route == [MapFixture.Places.vik, MapFixture.Places.reykjavik, MapFixture.Places.geysir])
        // Two places with as many photos: the destination the trip's geometry chose leads,
        // whichever of them it is.
        var tie = MapHandmade.trip("tie", "2023-06-15", [MapHandmade.place(MapFixture.Places.gullfoss, "Gullfoss", "IS", photos: 30, covers: ["gullfoss-1"]),
                                                         MapHandmade.place(MapFixture.Places.geysir, "Geysir", "IS", photos: 30, covers: ["geysir-2"])])
        tie.geometry.destinationIndex = 1
        tie.geometry.destination = MapFixture.Places.geysir
        let tied = try #require(MapShare.postcard(for: tie.id, in: MapHandmade.summary(trips: [tie])))
        #expect(tied.photos.map(\.asset) == ["geysir-2", "gullfoss-1"])
    }

    @Test func aDisputedAreaIsNoCountryOnAnyImage() throws {
        // Decision 18.11.2026: no flag on the postcard of a trip there, and no stamp and no country
        // on the other images, even if the summary, which never lists one, did.
        let srinagar = MapFixture.at(34.0837, 74.7973)
        let kashmir = MapHandmade.trip("kashmir", "2012-07-01", [MapHandmade.place(srinagar, "Srinagar", "disputed-kashmir", photos: 40)])
        let disputed = MapHandmade.country("disputed-kashmir", "2012-07-01", trips: ["kashmir"], region: .southernAsia, isState: false)
        let summary = MapHandmade.summary(trips: [kashmir], countries: [disputed])
        let card = try #require(MapShare.postcard(for: kashmir.id, in: summary))
        #expect(card.countryCode == nil)
        #expect(card.title == "Srinagar")
        // One place: no route to draw.
        #expect(card.route.isEmpty)
        #expect(MapShare.passport(summary).stamps.isEmpty)
        let world = MapShare.world(summary, geometry: geometry)
        #expect(world.countries.isEmpty)
        // The trip itself is on the world map.
        #expect(world.destinations == [srinagar])
    }

    @Test func aRepeatedTripOrCountryIsTakenOnce() throws {
        // The summary never repeats a trip id or a country code. If it did, every motif takes the
        // copy the globe takes, whatever the order: the trip with the most photos, the country's
        // earliest first visit.
        let library = Self.library()
        let staleTrip = MapHandmade.trip("japan-2024", "2024-03-31 20:00", [MapHandmade.place(Place.kyoto, "Kyoto", "JP", photos: 5, covers: ["stale-1"])],
                                         title: "Kyoto", timeZone: "Asia/Tokyo")
        let staleCountry = MapHandmade.country("JP", "2025-08-01", trips: [], region: .easternAsia)
        let orders: [([MapTrip], [MapCountry])] = [([staleTrip] + library.trips, [staleCountry] + library.countries),
                                                   (library.trips + [staleTrip], library.countries + [staleCountry])]
        for (trips, countries) in orders {
            var repeated = library
            repeated.trips = trips
            repeated.countries = countries
            #expect(MapShare.world(repeated, geometry: geometry) == MapShare.world(library, geometry: geometry))
            #expect(MapShare.passport(repeated) == MapShare.passport(library))
            #expect(MapShare.year(2024, of: repeated) == MapShare.year(2024, of: library))
            #expect(MapShare.postcard(for: AlbumistID("japan-2024"), in: repeated) == MapShare.postcard(for: AlbumistID("japan-2024"), in: library))
        }
    }

    @Test func thousandsOfDayTripsStayFast() throws {
        let (trips, countries) = MapHandmade.dayTrips(5_000)
        let years = (2005...2026).map { year in
            let ofYear = trips.filter { MapFixture.calendar.component(.year, from: $0.geometry.start) == year }
            return MapYear(year: year, tripIDs: ofYear.map(\.id), newCountries: [], countriesSoFar: 0, tripsSoFar: 0, daysAway: ofYear.count,
                           photoCount: ofYear.reduce(0) { $0 + $1.geometry.photoCount }, metersTraveled: 1_000_000)
        }
        let summary = MapHandmade.summary(trips: trips, countries: countries, years: years)
        var world: ShareWorld?
        var year: ShareYear?
        let took = ContinuousClock().measure {
            world = MapShare.world(summary, geometry: geometry)
            year = MapShare.year(2015, of: summary)
            _ = MapShare.passport(summary)
            _ = MapShare.postcard(for: AlbumistID("day-2500"), in: summary)
        }
        #expect(try #require(world).arcs.count == MapSummary.maxArcs)
        #expect(try #require(year).photos.count > 1_000)
        #expect(took < .seconds(2), "5,000 trips took \(took)")
    }

    @Test func sameSummaryInAnyOrderGivesTheSameShareData() {
        let library = Self.library()
        for seed in 1...5 as ClosedRange<UInt64> {
            var shuffled = library
            shuffled.trips = MapHandmade.shuffled(library.trips, seed: seed)
            shuffled.countries = MapHandmade.shuffled(library.countries, seed: seed + 10)
            #expect(MapShare.world(shuffled, geometry: geometry) == MapShare.world(library, geometry: geometry))
            #expect(MapShare.passport(shuffled, newCountries: ["JP"]) == MapShare.passport(library, newCountries: ["JP"]))
            #expect(MapShare.year(2024, of: shuffled) == MapShare.year(2024, of: library))
            #expect(MapShare.postcard(for: AlbumistID("japan-2024"), in: shuffled) == MapShare.postcard(for: AlbumistID("japan-2024"), in: library))
        }
    }
}
