import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// The numbers of one trip and of "Deine Welt in Zahlen": counts, distances, the favourite
/// country, speed.
@Suite("Map numbers")
struct MapNumbersTests {
    typealias Places = MapFixture.Places

    /// Reykjavík is the farthest from home, Vík (most photos) the destination.
    static var iceland: [TripPlace] {
        [HandBuilt.place(Places.reykjavik, "Reykjavík", country: "IS", photos: 12, days: ["2023-06-14"]),
         HandBuilt.place(Places.thingvellir, "Þingvellir", country: "IS", photos: 15, days: ["2023-06-15"]),
         HandBuilt.place(Places.vik, "Vík", country: "IS", photos: 40, days: ["2023-06-16"])]
    }

    // MARK: One trip

    @Test func tripNumbersFromTheHomeOfItsTime() throws {
        let home = HandBuilt.home()
        let trip = HandBuilt.trip("iceland", "2023-06-14", "2023-06-22", places: Self.iceland, home: home)
        let d = { (a: GeoCoordinate, b: GeoCoordinate) in GeoMath.distance(a, b) }
        let onSite = d(Places.reykjavik, Places.thingvellir) + d(Places.thingvellir, Places.vik)
        #expect(trip.stats.metersOnSite == onSite)
        #expect(trip.stats.metersOnSite == trip.geometry.metersOnSite)
        #expect(abs(trip.stats.metersTraveled - (onSite + d(home.coordinate, Places.reykjavik) + d(Places.vik, home.coordinate))) < 1e-6)
        let fromHome = try #require(trip.stats.metersFromHome)
        #expect(trip.geometry.destination == Places.vik)
        #expect(fromHome == d(home.coordinate, Places.reykjavik))
        #expect(fromHome == [Places.reykjavik, Places.thingvellir, Places.vik].map { d(home.coordinate, $0) }.max())
        // Regensburg to Reykjavík, Luftlinie: "ca. 2.600 km".
        #expect(MapDistance.aboutKilometers(fromHome) == 2_600)
    }

    @Test func aRouteBackToTheHotelStartsAndEndsThere() {
        let home = HandBuilt.home()
        let trip = HandBuilt.trip("loop", "2023-06-14", places: Self.iceland, route: [0, 1, 0, 2, 0], home: home)
        let toReykjavik = GeoMath.distance(home.coordinate, Places.reykjavik)
        #expect(abs(trip.stats.metersTraveled - (trip.stats.metersOnSite + 2 * toReykjavik)) < 1e-6)
        #expect(trip.stats.metersOnSite == trip.geometry.legs.reduce(0) { $0 + $1.meters })
    }

    @Test func withoutAHomeOnlyOnSiteCounts() {
        let trip = HandBuilt.trip("iceland", "2023-06-14", places: Self.iceland, home: nil)
        #expect(trip.stats.metersTraveled == trip.stats.metersOnSite)
        #expect(trip.stats.metersOnSite > 100_000)
        #expect(trip.stats.metersFromHome == nil)
    }

    @Test func withoutARouteTheTripGoesToItsDestinationAndBack() throws {
        let home = HandBuilt.home()
        // Places but no route: there and back to the destination (the place with the most photos,
        // Florence), though Rome is farther from home.
        let noRoute = HandBuilt.trip("tuscany", "2023-04-01", places: [HandBuilt.place(Places.rome, "Rom", photos: 10),
                                                                        HandBuilt.place(Places.florence, "Florenz", photos: 30)], route: [], home: home)
        #expect(noRoute.stats.metersOnSite == 0)
        #expect(noRoute.stats.metersTraveled == 2 * GeoMath.distance(home.coordinate, Places.florence))
        #expect(noRoute.stats.metersFromHome == GeoMath.distance(home.coordinate, Places.rome))
        // No place at all: the destination (the medoid of the photos).
        let noPlace = HandBuilt.trip("drive", "2023-05-01", destination: Places.florence, home: home)
        #expect(noPlace.geometry.places.isEmpty)
        #expect(noPlace.stats.metersFromHome == GeoMath.distance(home.coordinate, Places.florence))
        #expect(noPlace.stats.metersTraveled == 2 * GeoMath.distance(home.coordinate, Places.florence))
        // One place: there and back.
        let one = HandBuilt.trip("one", "2023-05-01", places: [HandBuilt.place(Places.porto, "Porto")], home: home)
        #expect(abs(one.stats.metersTraveled - 2 * GeoMath.distance(home.coordinate, Places.porto)) < 1e-6)
        // A route point that names no place counts as no route, never reads past the places.
        var broken = HandBuilt.trip("broken", "2023-06-14", places: Self.iceland, home: home).geometry
        broken.route[broken.route.count - 1].placeIndex = 7
        let stats = TripStats.compute(broken, home: home)
        #expect(stats.metersTraveled == broken.metersOnSite + 2 * GeoMath.distance(home.coordinate, broken.destination))
    }

    /// Distances are great-circle: a trip from New Zealand to Fiji and Samoa crosses the
    /// antimeridian the short way.
    @Test func distancesCrossTheAntimeridianTheShortWay() throws {
        let home = HandBuilt.home(Places.auckland, country: "NZ")
        let trip = HandBuilt.trip("pacific", "2024-07-01", places: [HandBuilt.place(Places.suva, "Suva", country: "FJ"),
                                                                     HandBuilt.place(Places.apia, "Apia", country: "WS")], home: home)
        #expect(trip.stats.metersOnSite > 1_000_000 && trip.stats.metersOnSite < 1_300_000)
        #expect(trip.stats.metersTraveled > 5_500_000 && trip.stats.metersTraveled < 7_000_000)
        #expect(try #require(trip.stats.metersFromHome) < 3_000_000)
    }

    // MARK: Deine Welt in Zahlen

    @Test func countsStatesContinentsAndTheWorldShare() {
        let countries = [HandBuilt.country("DE", "2009-05-01"), HandBuilt.country("IT", "2011-07-01"), HandBuilt.country("PT", "2015-04-02"),
                         HandBuilt.country("IS", "2019-06-14"), HandBuilt.country("PR", "2020-02-01"), HandBuilt.country("JP", "2022-10-10"),
                         HandBuilt.country("NZ", "2024-01-15")]
        let trips = [HandBuilt.trip("b", "2015-04-02", traveled: 4_000_000, onSite: 300_000),
                     HandBuilt.trip("a", "2011-07-01", traveled: 2_000_000, onSite: 100_000),
                     HandBuilt.trip("c", "2024-01-15", traveled: 36_000_000, onSite: 1_000_000)]
        let numbers = HandBuilt.numbers(trips, countries, cities: 17)
        #expect(numbers.countries == 7)
        #expect(numbers.states == 6)
        #expect(numbers.worldShare == 6.0 / 195)
        #expect(numbers.continents.map(\.continent) == [.africa, .asia, .europe, .northAmerica, .oceania, .southAmerica])
        #expect(numbers.continents.map(\.visited) == [0, 1, 4, 0, 1, 0])
        #expect(numbers.continents.map(\.total) == [54, 46, 46, 23, 14, 12])
        #expect(numbers.cities == 17)
        #expect(numbers.trips == 3)
        #expect(numbers.firstTripYear == 2011)
        #expect(numbers.firstCountryYear == 2009)
        #expect(numbers.metersTraveled == 42_000_000)
        #expect(numbers.metersOnSite == 1_400_000)
        #expect(numbers.earth == .aroundTheEarth(times: 1.0))
        #expect(!numbers.isPreliminary)
        #expect(HandBuilt.numbers(trips, countries, running: true).isPreliminary)
    }

    @Test func theEarthComparisonFollowsUnterwegs() {
        func earth(_ traveled: [Double]) -> EarthComparison {
            HandBuilt.numbers(traveled.enumerated().map { HandBuilt.trip("t\($0.offset)", "2020-01-01", traveled: $0.element, onSite: 0) }).earth
        }
        #expect(earth([]) == .none)
        #expect(earth([5_000_000, 4_000_000]) == .none)
        #expect(earth([5_000_000, 6_000_000]) == .quarter)
        #expect(earth([10_000_000, 10_100_000]) == .half)
        // The drafts' 88,800 km: "2,2-mal um die Erde".
        #expect(earth([40_000_000, 40_000_000, 8_800_000]) == .aroundTheEarth(times: 2.2))
        #expect(earth([200_000_000, 200_000_000]) == .toTheMoon(times: 1.0))
    }

    @Test func theYearAndItsNewCountries() {
        let countries = [HandBuilt.country("DE", "2009-05-01"), HandBuilt.country("NO", "2026-07-01"), HandBuilt.country("IS", "2026-03-01"),
                         HandBuilt.country("GB", "2026-05-10"), HandBuilt.country("FR", "2025-12-31 23:30")]
        let utc = HandBuilt.numbers([], countries)
        #expect(utc.year == 2026)
        #expect(utc.newThisYear == ["IS", "GB", "NO"])
        // A first visit on New Year's Eve 23:30 UTC, photographed in Germany, is one of 2026 on
        // the photo's clock (`MapCountry.firstVisitYear`), and "this year" is 2026 there too.
        let berlinCalendar = HandBuilt.calendar("Europe/Berlin")
        let berlin = HandBuilt.numbers([], HandBuilt.seen(countries, in: berlinCalendar), calendar: berlinCalendar)
        #expect(berlin.newThisYear == ["FR", "IS", "GB", "NO"])
        #expect(HandBuilt.numbers([], countries, now: MapFixture.date("2025-12-31 12:00")).newThisYear == ["FR"])
    }

    @Test func anEmptyWorldHasZerosAndNoRecords() {
        let numbers = HandBuilt.numbers([], [], running: false)
        #expect(numbers.countries == 0 && numbers.states == 0 && numbers.worldShare == 0 && numbers.cities == 0 && numbers.trips == 0)
        #expect(numbers.continents.count == 6 && numbers.continents.allSatisfy { $0.visited == 0 && $0.total > 0 })
        #expect(numbers.firstTripYear == nil && numbers.firstCountryYear == nil)
        #expect(numbers.metersTraveled == 0 && numbers.metersOnSite == 0 && numbers.earth == .none)
        #expect(numbers.records.isEmpty)
        #expect(numbers.longestTripID == nil && numbers.longestTripDays == nil)
        #expect(numbers.mostPhotosInADay == nil && numbers.favoriteCountry == nil)
        #expect(numbers.year == 2026 && numbers.newThisYear.isEmpty)
        // Trips without places: counted, but no record.
        let bare = HandBuilt.numbers([HandBuilt.trip("bare", "2024-01-01", destination: Places.tokyo, home: HandBuilt.home())])
        #expect(bare.trips == 1 && bare.records.isEmpty)
    }

    /// Kilometres are added up in the trips' time order, so their order does not change a digit.
    @Test func sumsDoNotDependOnTheOrderOfTheTrips() {
        var random = MapRandom(seed: 7)
        let trips = (0..<300).map { i in
            HandBuilt.trip("t\(i)", "2020-01-01", traveled: random.unit() * 1e7 + 0.1, onSite: random.unit() * 1e5 + 0.3)
        }
        let reference = HandBuilt.numbers(trips)
        for seed in UInt64(1)...4 {
            let shuffled = HandBuilt.numbers(HandBuilt.shuffled(trips, seed: seed))
            #expect(shuffled.metersTraveled == reference.metersTraveled)
            #expect(shuffled.metersOnSite == reference.metersOnSite)
            #expect(shuffled == reference)
        }
    }

    // MARK: Favourite country

    static func abroad(_ id: String, _ start: String, _ photos: [String: Int], home: RoundedHome? = HandBuilt.home()) -> MapTrip {
        HandBuilt.trip(id, start, countryPhotos: photos, home: home)
    }

    @Test func theFavouriteIsTheCountryWithTheMostTripsAbroad() throws {
        var trips = [Self.abroad("it1", "2019-05-01", ["IT": 40, "DE": 5]), Self.abroad("it2", "2020-05-01", ["IT": 12]),
                     Self.abroad("it3", "2021-05-01", ["IT": 3, "AT": 30]), Self.abroad("es1", "2022-05-01", ["ES": 80]),
                     Self.abroad("es2", "2023-05-01", ["ES": 90])]
        trips += (1...5).map { Self.abroad("de\($0)", "201\($0)-08-01", ["DE": 50]) }
        let favorite = try #require(HandBuilt.numbers(trips).favoriteCountry)
        // Germany has the most trips, but it is home; Spain has more photos, Italy more trips.
        #expect(favorite == FavoriteCountry(code: "IT", tripCount: 3, photoCount: 55))
    }

    @Test func aTripCountsForACountryWithThreePhotosThere() throws {
        let trips = [Self.abroad("a", "2020-01-01", ["AT": 2]), Self.abroad("b", "2020-02-01", ["AT": 2]), Self.abroad("c", "2020-03-01", ["AT": 2]),
                     Self.abroad("d", "2020-04-01", ["CH": 3])]
        #expect(try #require(HandBuilt.numbers(trips).favoriteCountry) == FavoriteCountry(code: "CH", tripCount: 1, photoCount: 3))
        #expect(TripGeometry.minimumPhotosPerPlace == 3)
    }

    /// Abroad follows the home of each trip's time: after moving from Germany to Austria a trip to
    /// Germany is abroad and a trip in Austria no longer is; before the move it was the other way
    /// round, although Austria is the more common home by then.
    @Test func afterAMoveTheOldHomeCountryIsAbroad() throws {
        let germany = HandBuilt.home(), austria = HandBuilt.home(GeoCoordinate(latitude: 48.2082, longitude: 16.3738), country: "AT")
        let afterMove = (1...3).map { Self.abroad("de\($0)", "202\($0)-05-01", ["DE": 10], home: austria) }
            + (4...6).map { Self.abroad("at\($0)", "202\($0)-08-01", ["AT": 30], home: austria) }
        let twoBefore = (1...2).map { Self.abroad("vienna\($0)", "201\($0)-05-01", ["AT": 20], home: germany) }
        #expect(try #require(HandBuilt.numbers(twoBefore + afterMove).favoriteCountry)
            == FavoriteCountry(code: "DE", tripCount: 3, photoCount: 30))
        let fourBefore = (1...4).map { Self.abroad("vienna\($0)", "201\($0)-05-01", ["AT": 20], home: germany) }
        #expect(try #require(HandBuilt.numbers(fourBefore + afterMove).favoriteCountry)
            == FavoriteCountry(code: "AT", tripCount: 4, photoCount: 80))
    }

    @Test func aTripWithoutAKnownHomeCountryTakesTheMostCommonOne() throws {
        let home = HandBuilt.home()
        let trips = [Self.abroad("h1", "2018-05-01", ["IT": 10], home: home), Self.abroad("h2", "2018-06-01", ["DE": 30], home: home),
                     Self.abroad("h3", "2018-07-01", ["DE": 30], home: home),
                     Self.abroad("n1", "2019-05-01", ["DE": 50], home: nil),
                     Self.abroad("n2", "2019-06-01", ["DE": 50, "FR": 5], home: HandBuilt.home(country: nil))]
        // Germany would win with two trips if the trips without a home country counted it as abroad.
        #expect(try #require(HandBuilt.numbers(trips).favoriteCountry) == FavoriteCountry(code: "IT", tripCount: 1, photoCount: 10))
        // A tie for the most common home country goes to the smaller code: Austria here, so the
        // trip without one counts Germany as abroad.
        let tied = [Self.abroad("de", "2018-05-01", ["FR": 3], home: HandBuilt.home()),
                    Self.abroad("at", "2018-06-01", ["IT": 3], home: HandBuilt.home(country: "AT")),
                    Self.abroad("unknown", "2018-07-01", ["DE": 10, "AT": 10], home: nil)]
        #expect(try #require(HandBuilt.numbers(tied).favoriteCountry) == FavoriteCountry(code: "DE", tripCount: 1, photoCount: 10))
    }

    @Test func withoutAnyHomeThereIsNoFavourite() {
        let trips = [Self.abroad("a", "2020-01-01", ["IT": 30], home: nil), Self.abroad("b", "2021-01-01", ["IT": 30], home: nil),
                     Self.abroad("c", "2022-01-01", ["ES": 30], home: HandBuilt.home(country: nil))]
        #expect(HandBuilt.numbers(trips).favoriteCountry == nil)
    }

    @Test func favouriteTiesGoToMorePhotosThenTheCode() throws {
        let photos = [Self.abroad("it1", "2020-01-01", ["IT": 10]), Self.abroad("it2", "2020-02-01", ["IT": 10]),
                      Self.abroad("es1", "2020-03-01", ["ES": 10]), Self.abroad("es2", "2020-04-01", ["ES": 11])]
        #expect(try #require(HandBuilt.numbers(photos).favoriteCountry).code == "ES")
        let code = [Self.abroad("pt1", "2020-01-01", ["PT": 10]), Self.abroad("pt2", "2020-02-01", ["PT": 10]),
                    Self.abroad("es1", "2020-03-01", ["ES": 10]), Self.abroad("es2", "2020-04-01", ["ES": 10])]
        #expect(try #require(HandBuilt.numbers(code).favoriteCountry) == FavoriteCountry(code: "ES", tripCount: 2, photoCount: 20))
        #expect(HandBuilt.numbers(HandBuilt.shuffled(code, seed: 3)).favoriteCountry?.code == "ES")
    }

    @Test func aDisputedAreaIsNeverTheFavourite() throws {
        var trips = (1...5).map { Self.abroad("crimea\($0)", "201\($0)-07-01", ["disputed-crimea": 50]) }
        #expect(HandBuilt.numbers(trips).favoriteCountry == nil)
        trips.append(Self.abroad("kyiv", "2019-07-01", ["UA": 3, "disputed-crimea": 40]))
        #expect(try #require(HandBuilt.numbers(trips).favoriteCountry) == FavoriteCountry(code: "UA", tripCount: 1, photoCount: 3))
    }

    // MARK: Speed

    /// 2,000 trips of 20 places each: every number, the held numbers and the years in a few
    /// milliseconds in the app (linear in the places; the bound here is for a debug build on a
    /// shared machine and only catches work that grows faster).
    @Test func twoThousandTripsOfTwentyPlacesAreFast() {
        var random = MapRandom(seed: 2_000)
        let home = HandBuilt.home()
        let codes = ["IT", "ES", "FR", "PT", "GR", "HR", "IS", "NO", "JP", "US", "AU", "NZ", "TH", "MX", "BR"]
        var trips: [MapTrip] = []
        var firstVisits: [String: Date] = [:]
        for t in 0..<2_000 {
            let code = codes[random.int(0..<codes.count)]
            let center = GeoCoordinate(latitude: random.unit() * 140 - 70, longitude: random.unit() * 360 - 180)
            let start = MapFixture.date("2006-01-01").addingTimeInterval(TimeInterval(t) * 86_400 * 3 + random.unit() * 86_400)
            let places = (0..<20).map { p in
                TripPlace(coordinate: GeoCoordinate(latitude: center.latitude + random.unit(), longitude: center.longitude + random.unit()),
                          name: "Ort \(t)-\(p)", countryKey: code, photoCount: 3 + random.int(0..<40),
                          days: [LocalDay(start.addingTimeInterval(TimeInterval(p) * 3_600 * 8), timeZone: MapFixture.utc)], coverCandidates: [],
                          altitude: p % 3 == 0 ? random.unit() * 3_000 : nil)
            }
            var trip = HandBuilt.trip("trip-\(t)", "2006-01-01", places: places, home: random.int(0..<10) == 0 ? nil : home)
            trip.geometry.start = start
            trip.geometry.dayCounts = (0..<7).map { d in
                TripDay(day: LocalDay(start.addingTimeInterval(TimeInterval(d) * 86_400), timeZone: MapFixture.utc), photoCount: random.int(1..<200),
                        placeIndex: d)
            }
            trips.append(trip)
            firstVisits[code] = min(firstVisits[code] ?? start, start)
        }
        let countries = firstVisits.map { code, date in
            MapCountry(code: code, firstVisit: date, photoCount: 100, tripIDs: [], isState: true, continent: Continent.forCountryCode(code),
                       region: WorldRegion.of(countryCode: code))
        }
        let clock = ThreadCPUClock()
        var numbers = WorldNumbers()
        var years: [MapYear] = []
        var stats: [TripStats] = []
        let elapsed = clock.measure {
            stats = trips.map { TripStats.compute($0.geometry, home: $0.home) }
            numbers = WorldNumbers.compute(trips: trips, countries: countries, cities: 500, timeZone: MapFixture.calendar.timeZone, now: HandBuilt.now,
                                           analysisRunning: true)
            numbers = numbers.holdingHighs(over: numbers)
            years = MapYears.compute(trips: trips, countries: countries, through: 2026)
        }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "MAP_NUMBERS_PERF trips 2000 places 40000: %.1f ms", ms))
        #expect(stats.count == 2_000)
        #expect(numbers.trips == 2_000 && numbers.records.count == 6)
        #expect(years.first?.year == 2006 && years.last?.tripsSoFar == 2_000)
        #expect(ms < 250)
    }
}
