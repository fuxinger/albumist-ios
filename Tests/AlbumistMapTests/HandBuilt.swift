import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// Map values made by hand for the tests of the numbers, records and years: `TripGeometry` is
/// built from photos elsewhere (`TripGeometry.build`), these tests need exact places, routes and
/// days instead. Everything in UTC.
enum HandBuilt {
    typealias Places = MapFixture.Places

    /// `"2023-06-14"` as a local day in UTC.
    static func day(_ string: String) -> LocalDay { LocalDay(MapFixture.date(string), timeZone: MapFixture.utc) }

    static func place(_ coordinate: GeoCoordinate, _ name: String?, country: String? = nil, photos: Int = 12, days: [String] = ["2023-06-14"],
                      altitude: Double? = nil) -> TripPlace {
        TripPlace(coordinate: coordinate, name: name, countryKey: country, photoCount: photos, days: days.map(day), coverCandidates: [],
                  altitude: altitude)
    }

    /// The sample home in the Regensburg area, rounded as the map keeps it.
    static func home(_ coordinate: GeoCoordinate = Places.regensburg, country: String? = "DE") -> RoundedHome {
        RoundedHome(coordinate: coordinate, countryCode: country)
    }

    static func dayCount(_ day: String, _ photos: Int, place: Int? = nil) -> TripDay {
        TripDay(day: Self.day(day), photoCount: photos, placeIndex: place)
    }

    /// A trip from `start` to `end` (`"2023-06-14"` or `"2023-06-14 10:30"`) over `places`,
    /// visited in `route` order (indices into `places`; by default each once, in order), with
    /// straight legs between them. Its photos per country come from its places unless given; its
    /// destination is the place with the most photos (else `destination`); its stats are
    /// `TripStats.compute` from `home`.
    static func trip(_ id: String, _ start: String, _ end: String? = nil, places: [TripPlace] = [], route: [Int]? = nil,
                     dayCounts: [TripDay] = [], countryPhotos: [String: Int]? = nil, photoCount: Int? = nil,
                     destination: GeoCoordinate? = nil, home: RoundedHome? = nil) -> MapTrip {
        let startDate = MapFixture.date(start), endDate = MapFixture.date(end ?? start)
        let visits = route ?? Array(places.indices)
        let points = visits.enumerated().map { step, index in
            let arrival = startDate.addingTimeInterval(TimeInterval(step * 3_600))
            return RoutePoint(placeIndex: index, arrival: arrival, departure: arrival.addingTimeInterval(1_800),
                              day: LocalDay(arrival, timeZone: MapFixture.utc))
        }
        let legs = zip(visits, visits.dropFirst()).map { a, b in
            RouteLeg(meters: GeoMath.distance(places[a].coordinate, places[b].coordinate), withoutPhotos: false)
        }
        var perCountry: [String: Int] = [:]
        for place in places { if let key = place.countryKey { perCountry[key, default: 0] += place.photoCount } }
        let photos = countryPhotos ?? perCountry
        let main = photos.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        let destinationIndex = places.indices.max { a, b in
            (places[a].photoCount, b) < (places[b].photoCount, a)
        }
        let geometry = TripGeometry(
            id: AlbumistID(id), start: startDate, end: endDate, timeZoneIdentifier: "UTC",
            firstDay: LocalDay(startDate, timeZone: MapFixture.utc), lastDay: LocalDay(endDate, timeZone: MapFixture.utc),
            photoCount: photoCount ?? places.reduce(0) { $0 + $1.photoCount }, dayCounts: dayCounts, dayPlaces: [], places: places,
            route: points, legs: legs, destinationIndex: destinationIndex,
            destination: destinationIndex.map { places[$0].coordinate } ?? destination ?? Places.munich,
            countryPhotos: photos, mainCountryKey: main, airborneCount: 0)
        return MapTrip(geometry: geometry, title: id, stats: TripStats.compute(geometry, home: home), home: home)
    }

    /// A trip whose numbers are given, for sums.
    static func trip(_ id: String, _ start: String, traveled: Double, onSite: Double) -> MapTrip {
        var trip = trip(id, start)
        trip.stats = TripStats(metersOnSite: onSite, metersTraveled: traveled, metersFromHome: nil)
        return trip
    }

    static func country(_ code: String, _ firstVisit: String, photos: Int = 10, trips: [String] = []) -> MapCountry {
        MapCountry(code: code, firstVisit: MapFixture.date(firstVisit), photoCount: photos, tripIDs: trips.map(AlbumistID.init),
                   isState: WorldStates.isState(code), continent: Continent.forCountryCode(code), region: WorldRegion.of(countryCode: code))
    }

    /// `countries` as `MapCountries.compute` gives them on a device with `calendar`: the year of
    /// each first visit in that calendar.
    static func seen(_ countries: [MapCountry], in calendar: Calendar) -> [MapCountry] {
        countries.map { country in
            var country = country
            country.firstVisitYear = calendar.component(.year, from: country.firstVisit)
            return country
        }
    }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static let now = MapFixture.date("2026-11-20 12:00")

    static func numbers(_ trips: [MapTrip], _ countries: [MapCountry] = [], cities: Int = 0, calendar: Calendar = MapFixture.calendar,
                        now: Date = now, running: Bool = false) -> WorldNumbers {
        WorldNumbers.compute(trips: trips, countries: countries, cities: cities, timeZone: calendar.timeZone, now: now, analysisRunning: running)
    }

    /// `items` in an order given by `seed` (Fisher-Yates).
    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var items = items
        var random = MapRandom(seed: seed)
        for i in stride(from: items.count - 1, to: 0, by: -1) { items.swapAt(i, random.int(0..<(i + 1))) }
        return items
    }
}
