import Foundation
import Testing
import SortlyCore
@testable import SortlyMap

/// The years of the time travel, the moment "Neues Land" and "Überrasch mich".
@Suite("Map years")
struct MapYearsTests {
    typealias Places = MapFixture.Places

    static func trip(_ id: String, _ start: String, _ end: String, photos: Int, traveled: Double, place: GeoCoordinate = Places.rome) -> MapTrip {
        var trip = HandBuilt.trip(id, start, end, places: [HandBuilt.place(place, id)], photoCount: photos)
        trip.stats = TripStats(metersOnSite: 0, metersTraveled: traveled, metersFromHome: nil)
        return trip
    }

    /// Four trips with gaps between them, from 2019 on.
    static var trips: [MapTrip] {
        [trip("iceland", "2019-06-14", "2019-06-22", photos: 412, traveled: 5_300_000),
         trip("rome", "2021-04-01", "2021-04-05", photos: 120, traveled: 1_600_000),
         trip("lisbon", "2021-10-01", "2021-10-08", photos: 200, traveled: 4_400_000),
         trip("tokyo", "2024-03-10", "2024-03-24", photos: 900, traveled: 18_600_000)]
    }

    /// Germany from everyday photos long before the first trip; Great Britain this year.
    static var countries: [MapCountry] {
        [HandBuilt.country("DE", "2015-03-01"), HandBuilt.country("IS", "2019-06-14", trips: ["iceland"]),
         HandBuilt.country("IT", "2021-04-01", trips: ["rome"]), HandBuilt.country("PT", "2021-10-01", trips: ["lisbon"]),
         HandBuilt.country("JP", "2024-03-10", trips: ["tokyo"]), HandBuilt.country("GB", "2026-05-01")]
    }

    static func years(_ trips: [MapTrip] = trips, _ countries: [MapCountry] = countries, calendar: Calendar = MapFixture.calendar,
                      through year: Int = 2026) -> [MapYear] {
        MapYears.compute(trips: trips, countries: countries, calendar: calendar, through: year)
    }

    // MARK: Years

    @Test func everyYearFromTheFirstTripToNowGapsIncluded() {
        let years = Self.years()
        #expect(years.map(\.year) == Array(2019...2026))
        #expect(years.map { $0.tripIDs.map(\.rawValue) } == [["iceland"], [], ["rome", "lisbon"], [], [], ["tokyo"], [], []])
        #expect(years.map(\.tripsSoFar) == [1, 1, 3, 3, 3, 4, 4, 4])
        #expect(years.map(\.daysAway) == [9, 0, 13, 0, 0, 15, 0, 0])
        #expect(years.map(\.photoCount) == [412, 0, 320, 0, 0, 900, 0, 0])
        #expect(years.map(\.metersTraveled) == [5_300_000, 0, 6_000_000, 0, 0, 18_600_000, 0, 0])
    }

    @Test func countriesSoFarAndTheNewOnesOfEachYear() {
        let years = Self.years()
        // Germany was visited before the first trip: it counts from the first year on, new in none.
        #expect(years.map(\.countriesSoFar) == [2, 2, 4, 4, 4, 5, 5, 6])
        #expect(years.map(\.newCountries) == [["IS"], [], ["IT", "PT"], [], [], ["JP"], [], ["GB"]])
    }

    @Test func noTripsNoYears() {
        #expect(Self.years([]).isEmpty)
        #expect(Self.years([], []).isEmpty)
        // The first trip after the year asked for: nothing to travel through yet.
        #expect(Self.years(through: 2018).isEmpty)
        #expect(Self.years(through: 2019).map(\.year) == [2019])
    }

    /// A trip belongs to the year of its start in the device's calendar: one starting on New
    /// Year's Eve at 23:30 UTC is a trip of the new year in Germany, of the old one in New York
    /// and in UTC, whatever the local day where it started.
    @Test func theDevicesCalendarDecidesATripOnNewYearsEve() {
        var silvester = Self.trip("silvester", "2022-12-31 23:30", "2023-01-03 10:00", photos: 50, traveled: 2_000_000)
        silvester.geometry.timeZoneIdentifier = "Asia/Tokyo"
        silvester.geometry.firstDay = LocalDay(year: 2023, month: 1, day: 1)
        let countries = [HandBuilt.country("PT", "2022-12-31 23:30", trips: ["silvester"])]
        let utc = Self.years([silvester], countries)
        #expect(utc.first?.year == 2022 && utc.first?.tripIDs == [SortlyID("silvester")] && utc.first?.newCountries == ["PT"])
        let newYork = Self.years([silvester], countries, calendar: HandBuilt.calendar("America/New_York"))
        #expect(newYork.first?.year == 2022 && newYork.first?.tripIDs == [SortlyID("silvester")])
        let berlin = Self.years([silvester], countries, calendar: HandBuilt.calendar("Europe/Berlin"))
        #expect(berlin.map(\.year) == Array(2023...2026))
        #expect(berlin.first?.tripIDs == [SortlyID("silvester")] && berlin.first?.newCountries == ["PT"] && berlin.first?.countriesSoFar == 1)
    }

    @Test func aTripOverNewYearCountsWhollyInItsStartYear() {
        let years = Self.years([Self.trip("winter", "2022-12-28", "2023-01-05", photos: 300, traveled: 1_000_000)], [])
        #expect(years.map(\.year) == Array(2022...2026))
        #expect(years.map(\.daysAway) == [9, 0, 0, 0, 0])
        #expect(years.map(\.photoCount) == [300, 0, 0, 0, 0])
        #expect(years.map(\.tripsSoFar) == [1, 1, 1, 1, 1])
    }

    /// A camera clock set years ahead: that trip and country are in no year (the slider ends at
    /// the year asked for).
    @Test func tripsAfterTheYearAreInNoYear() {
        let trips = [Self.trip("now", "2024-05-01", "2024-05-03", photos: 10, traveled: 100_000),
                     Self.trip("future", "2031-05-01", "2031-05-03", photos: 10, traveled: 100_000)]
        let countries = [HandBuilt.country("AT", "2024-05-01"), HandBuilt.country("CH", "2031-05-01")]
        let years = Self.years(trips, countries)
        #expect(years.map(\.year) == [2024, 2025, 2026])
        #expect(years.last?.tripsSoFar == 1 && years.last?.countriesSoFar == 1)
    }

    @Test func yearsDoNotDependOnTheOrderOfTheirInput() {
        let reference = Self.years()
        for seed in UInt64(1)...5 {
            #expect(Self.years(HandBuilt.shuffled(Self.trips, seed: seed), HandBuilt.shuffled(Self.countries, seed: seed)) == reference)
        }
    }

    // MARK: Neues Land

    @Test func newCountriesSinceTheLastLook() {
        let events = MapYears.newCountries(since: ["DE", "IS"], countries: Self.countries)
        #expect(events == [NewCountryEvent(code: "IT", ordinal: 3, firstVisit: MapFixture.date("2021-04-01"), tripID: SortlyID("rome")),
                           NewCountryEvent(code: "PT", ordinal: 4, firstVisit: MapFixture.date("2021-10-01"), tripID: SortlyID("lisbon")),
                           NewCountryEvent(code: "JP", ordinal: 5, firstVisit: MapFixture.date("2024-03-10"), tripID: SortlyID("tokyo")),
                           NewCountryEvent(code: "GB", ordinal: 6, firstVisit: MapFixture.date("2026-05-01"), tripID: nil)])
        #expect(MapYears.newCountries(since: ["de", "is"], countries: HandBuilt.shuffled(Self.countries, seed: 9)) == events)
        // A country found now with an old first visit is new too, with its place in the order.
        let late = MapYears.newCountries(since: ["DE", "IS", "PT", "JP", "GB"], countries: Self.countries)
        #expect(late.map(\.code) == ["IT"] && late.first?.ordinal == 3)
        #expect(MapYears.newCountries(since: Set(Self.countries.map(\.code)), countries: Self.countries).isEmpty)
        // A country no longer there (photos deleted) is no event.
        #expect(MapYears.newCountries(since: ["DE", "IS", "IT", "PT", "JP", "GB", "FR"], countries: Self.countries).isEmpty)
    }

    @Test func theFirstOpeningShowsNoNewCountry() {
        #expect(MapYears.newCountries(since: nil, countries: Self.countries).isEmpty)
        // Opened before any country was found: each one is new, numbered from the first.
        let all = MapYears.newCountries(since: [], countries: Self.countries)
        #expect(all.map(\.code) == ["DE", "IS", "IT", "PT", "JP", "GB"])
        #expect(all.map(\.ordinal) == [1, 2, 3, 4, 5, 6])
        #expect(MapYears.newCountries(since: [], countries: []).isEmpty)
    }

    // MARK: Überrasch mich

    static let now = HandBuilt.now
    static func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    static func surpriseTrips(_ count: Int) -> [MapTrip] {
        (0..<count).map { Self.trip(String(format: "trip-%02d", $0), "20\(10 + $0 % 15)-0\(1 + $0 % 9)-01", "20\(10 + $0 % 15)-0\(1 + $0 % 9)-05",
                                    photos: 10, traveled: 0) }
    }

    static func picks(_ trips: [MapTrip], _ viewed: [SortlyID: Date], seeds: Range<UInt64> = 0..<300) -> Set<String> {
        Set(seeds.compactMap { MapYears.surpriseTrip(trips: trips, lastViewed: viewed, now: now, seed: $0)?.rawValue })
    }

    @Test func surpriseIsDeterministic() {
        let trips = Self.surpriseTrips(12)
        let viewed = [trips[0].id: Self.ago(days: 400), trips[3].id: Self.ago(days: 30)]
        for seed in UInt64(0)..<50 {
            let pick = MapYears.surpriseTrip(trips: trips, lastViewed: viewed, now: Self.now, seed: seed)
            #expect(pick != nil)
            #expect(MapYears.surpriseTrip(trips: trips, lastViewed: viewed, now: Self.now, seed: seed) == pick)
            #expect(MapYears.surpriseTrip(trips: HandBuilt.shuffled(trips, seed: seed), lastViewed: viewed, now: Self.now, seed: seed) == pick)
        }
        // SplitMix64 itself: the same numbers on every platform.
        #expect(MapYears.splitMix64(0) == 0xE220_A839_7B1D_CDAF)
        #expect(MapYears.splitMix64(1) == 0x910A_2DEC_8902_5CC1)
    }

    @Test func surpriseNeverPicksARecentlyViewedTripWhileOlderOnesExist() {
        let trips = Self.surpriseTrips(5)
        let ids = trips.map(\.id)
        // Looked at two years, a year and a month ago, two days and an hour ago: the last two are
        // recent, the pool is the first three.
        let viewed = [ids[0]: Self.ago(days: 730), ids[1]: Self.ago(days: 365), ids[2]: Self.ago(days: 30), ids[3]: Self.ago(days: 2),
                      ids[4]: Self.ago(days: 1.0 / 24)]
        #expect(Self.picks(trips, viewed) == Set(ids[0...2].map(\.rawValue)))
        // Never looked at comes first; a trip looked at two hours ago never comes while another is older.
        let three = Array(trips[0...2])
        let some = [ids[1]: Self.ago(days: 2.0 / 24), ids[2]: Self.ago(days: 365)]
        #expect(Self.picks(three, some) == [ids[0].rawValue, ids[2].rawValue])
        // A look "in the future" (the clock was set back) is recent too.
        let future = [ids[1]: Self.now.addingTimeInterval(86_400), ids[2]: Self.ago(days: 365)]
        #expect(!Self.picks(three, future).contains(ids[1].rawValue))
    }

    @Test func neverLookedAtComesBeforeLookedAtLongAgo() {
        let trips = Self.surpriseTrips(10)
        var viewed: [SortlyID: Date] = [:]
        for trip in trips[4...] { viewed[trip.id] = Self.ago(days: 3_000) }
        // The pool: max(3, 20 % of 10) = 3 of the four never looked at, the oldest trips first.
        let neverViewed = trips[0..<4].sorted { $0.geometry.start < $1.geometry.start }
        #expect(Self.picks(trips, viewed) == Set(neverViewed[0..<3].map(\.id.rawValue)))
    }

    @Test func whenEveryTripWasJustLookedAtTheOneLookedAtLongestAgoComes() {
        let trips = Self.surpriseTrips(3)
        let viewed = [trips[0].id: Self.ago(days: 1), trips[1].id: Self.ago(days: 3), trips[2].id: Self.ago(days: 0.001)]
        #expect(Self.picks(trips, viewed) == [trips[1].id.rawValue])
    }

    @Test func thePoolIsTwentyPercentOfTheTrips() {
        let trips = Self.surpriseTrips(30)
        let oldest = trips.sorted { ($0.geometry.start, $0.id.rawValue) < ($1.geometry.start, $1.id.rawValue) }
        let picks = Self.picks(trips, [:], seeds: 0..<600)
        #expect(picks == Set(oldest[0..<6].map(\.id.rawValue)))
        // 11 trips: 20 % is 2.2, rounded up 3.
        #expect(Self.picks(Self.surpriseTrips(11), [:]).count == 3)
        #expect(Self.picks(Self.surpriseTrips(16), [:]).count == 4)
    }

    @Test func surpriseNeedsATripWithAPlace() {
        #expect(MapYears.surpriseTrip(trips: [], lastViewed: [:], now: Self.now, seed: 1) == nil)
        let bare = HandBuilt.trip("bare", "2015-01-01", destination: Places.tokyo)
        #expect(MapYears.surpriseTrip(trips: [bare], lastViewed: [:], now: Self.now, seed: 1) == nil)
        // A trip without a place is never picked, however long it was not looked at.
        let trips = [bare] + Self.surpriseTrips(1)
        #expect(Self.picks(trips, [trips[1].id: Self.ago(days: 1)]) == [trips[1].id.rawValue])
    }
}
