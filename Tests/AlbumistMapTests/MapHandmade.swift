import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// Values of the shared types built by hand for the arcs, pins and share tests (building trip
/// geometry from photos is another part's job, so these tests do not depend on it). Real places,
/// the sample home in the Regensburg area; UTC unless a test passes a time zone.
enum MapHandmade {
    /// The sample home, rounded (Regensburg area), and an earlier one in Hamburg.
    static let home = RoundedHome(coordinate: MapFixture.at(49.0, 12.1), countryCode: "DE")
    static let hamburgHome = RoundedHome(coordinate: MapFixture.at(53.55, 10.0), countryCode: "DE")

    /// More real places, beside `MapFixture.Places`.
    enum Places {
        /// About 38 km from the sample home.
        static let straubing = MapFixture.at(48.8777, 12.5735)
        /// About 44 km from the sample home.
        static let bogen = MapFixture.at(48.9113, 12.6897)
        /// About 29 km from the sample home.
        static let abensberg = MapFixture.at(48.8146, 11.8460)
        /// About 19 km from the sample home.
        static let kelheim = MapFixture.at(48.9167, 11.8833)
        static let regensburgOldTown = MapFixture.at(49.0195, 12.0975)
        static let walhalla = MapFixture.at(49.0306, 12.2236)
        static let hamburg = MapFixture.at(53.5511, 9.9937)
        /// About 43 km from the earlier home in Hamburg.
        static let lueneburg = MapFixture.at(53.2464, 10.4115)
        static let innsbruck = MapFixture.at(47.2692, 11.4041)
        static let verona = MapFixture.at(45.4384, 10.9916)
        static let ciampino = MapFixture.at(41.7994, 12.5949)
        static let tivoli = MapFixture.at(41.9634, 12.7986)
        static let guidonia = MapFixture.at(41.9944, 12.7225)
        static let split = MapFixture.at(43.5081, 16.4402)
        static let hvar = MapFixture.at(43.1729, 16.4411)
        static let vis = MapFixture.at(43.0614, 16.1856)
        static let komiza = MapFixture.at(43.0442, 16.0927)
        static let nuuk = MapFixture.at(64.1814, -51.6941)
        static let ilulissat = MapFixture.at(69.2198, -51.0986)
        static let vaduz = MapFixture.at(47.1410, 9.5209)
        static let kyoto = MapFixture.at(35.0116, 135.7681)
        /// Taveuni (Fiji), on either side of the 180th meridian.
        static let taveuniWest = MapFixture.at(-16.7906, 179.9833)
        static let taveuniEast = MapFixture.at(-16.8500, -179.9667)
        static let svalbardAirport = MapFixture.at(78.2461, 15.4656)
        static let barentsburg = MapFixture.at(78.0648, 14.2335)
        static let southPoleStation = MapFixture.at(-89.9975, 139.27)
        static let southPole = MapFixture.at(-90.0, 0.0)
    }

    /// The day the places of the tests have their photos on (what day it is does not matter here).
    static let sampleDay = LocalDay(year: 2023, month: 6, day: 14)

    /// A place of a trip with its photos; `covers` are its cover candidates' asset ids.
    static func place(_ coordinate: GeoCoordinate, _ name: String?, _ country: String?, photos: Int, covers: [String] = []) -> TripPlace {
        TripPlace(coordinate: coordinate, name: name, countryKey: country, photoCount: photos, days: [sampleDay],
                  coverCandidates: covers.map { AssetID($0) })
    }

    /// A trip that visits `places` in this order, one a day from `start` (`visits`: other orders,
    /// by index, places visited again included). Its destination is its place with the most photos
    /// (a tie: the lower index), or `medoid` (then without a destination place). Photos: those of
    /// its places and `otherPhotos`; per country as its places have them unless `countryPhotos`.
    static func trip(_ id: String, _ start: String, _ places: [TripPlace], home: RoundedHome? = MapHandmade.home, title: String? = nil,
                     visits: [Int]? = nil, medoid: GeoCoordinate? = nil, otherPhotos: Int = 0, countryPhotos: [String: Int]? = nil,
                     timeZone: String? = nil) -> MapTrip {
        trip(id, at: MapFixture.date(start), places, home: home, title: title, visits: visits, medoid: medoid, otherPhotos: otherPhotos,
             countryPhotos: countryPhotos, timeZone: timeZone)
    }

    static func trip(_ id: String, at first: Date, _ places: [TripPlace], home: RoundedHome? = MapHandmade.home, title: String? = nil,
                     visits: [Int]? = nil, medoid: GeoCoordinate? = nil, otherPhotos: Int = 0, countryPhotos: [String: Int]? = nil,
                     timeZone: String? = nil) -> MapTrip {
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? MapFixture.utc
        // One calendar for the trip: `LocalDay(_:timeZone:)` makes one per call, too slow for the
        // thousands of trips of `dayTrips`.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func localDay(_ date: Date) -> LocalDay {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return LocalDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        }
        let order = visits ?? Array(places.indices)
        let route = order.enumerated().map { step, index in
            let arrival = first.addingTimeInterval(TimeInterval(step) * 86_400)
            return RoutePoint(placeIndex: index, arrival: arrival, departure: arrival.addingTimeInterval(6 * 3_600), day: localDay(arrival))
        }
        let coordinates = order.map { places[$0].coordinate }
        let legs = zip(coordinates, coordinates.dropFirst()).map { RouteLeg(meters: GeoMath.distance($0, $1), withoutPhotos: false) }
        let end = route.last?.departure ?? first.addingTimeInterval(6 * 3_600)
        let destinationIndex = medoid == nil ? places.indices.max { (places[$0].photoCount, $1) < (places[$1].photoCount, $0) } : nil
        var perCountry: [String: Int] = [:]
        for place in places { if let key = place.countryKey { perCountry[key, default: 0] += place.photoCount } }
        let countries = countryPhotos ?? perCountry
        let main = countries.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        let geometry = TripGeometry(
            id: AlbumistID(id), start: first, end: end, timeZoneIdentifier: timeZone, firstDay: localDay(first),
            lastDay: localDay(end), photoCount: places.reduce(otherPhotos) { $0 + $1.photoCount }, dayPlaces: [], places: places,
            route: route, legs: legs, destinationIndex: destinationIndex,
            destination: destinationIndex.map { places[$0].coordinate } ?? medoid ?? MapFixture.at(.nan, .nan),
            countryPhotos: countries, mainCountryKey: main, airborneCount: 0)
        let onSite = legs.reduce(0) { $0 + $1.meters }
        let away = home.map { home in coordinates.map { GeoMath.distance(home.coordinate, $0) } } ?? []
        let stats = TripStats(metersOnSite: onSite, metersTraveled: onSite + (away.first ?? 0) + (away.last ?? 0), metersFromHome: away.max())
        return MapTrip(geometry: geometry, title: title ?? geometry.destinationName ?? main ?? id, stats: stats, home: home)
    }

    static func country(_ code: String, _ firstVisit: String, trips: [String], region: WorldRegion?, isState: Bool = true, photos: Int = 20) -> MapCountry {
        MapCountry(code: code, firstVisit: MapFixture.date(firstVisit), photoCount: photos, tripIDs: trips.map { AlbumistID($0) }, isState: isState,
                   continent: Continent.forCountryCode(code), region: region)
    }

    static func summary(home: RoundedHome? = MapHandmade.home, trips: [MapTrip], countries: [MapCountry] = [],
                        numbers: WorldNumbers = WorldNumbers(year: 2026), years: [MapYear] = []) -> MapSummary {
        MapSummary(computedAt: MapFixture.date("2026-11-20"), home: home, trips: trips, countries: countries, arcs: [], pins: [], numbers: numbers,
                   years: years, focus: nil)
    }

    /// Sizes and middles of the countries the tests use, roughly as the offline world map has them.
    static let countryGeometry = CountryGeometry(
        squareKilometers: ["DE": 357_588, "AT": 83_879, "IT": 301_340, "IS": 103_000, "NZ": 268_021, "LU": 2_586],
        centers: ["DE": MapFixture.at(51.1657, 10.4515), "AT": MapFixture.at(47.5162, 14.5501), "IT": MapFixture.at(42.8, 12.6),
                  "IS": MapFixture.at(64.9631, -19.0208), "NZ": MapFixture.at(-41.5, 172.8), "LU": MapFixture.at(49.8153, 6.1296)])

    /// One trip to each of `count` (at most 400) destinations at least 500 km apart (a grid over
    /// the Earth, far from the sample home), ten days apart from 2000 on, each with 10 photos at
    /// one place; `repeats(i)` later trips go to the i-th destination again.
    static func manyDestinations(_ count: Int, home: RoundedHome? = MapHandmade.home, repeats: (Int) -> Int = { _ in 0 }) -> [MapTrip] {
        var trips: [MapTrip] = []
        var later = count
        func start(_ n: Int) -> String {
            let date = MapFixture.date("2000-01-01").addingTimeInterval(TimeInterval(n) * 10 * 86_400)
            return LocalDay(date, timeZone: MapFixture.utc).description
        }
        for i in 0..<count {
            // Latitudes -52 to 43, so no point is (0, 0), which a photo never has ("Null Island").
            let destination = MapFixture.at(-52 + 5 * Double(i / 20), -170 + 17 * Double(i % 20))
            let place = Self.place(destination, "Ort \(i)", "XX", photos: 10)
            trips.append(trip("trip-\(i)", start(i), [place], home: home))
            for r in 0..<repeats(i) {
                trips.append(trip("trip-\(i)-again-\(r)", start(later), [place], home: home))
                later += 1
            }
        }
        return trips
    }

    /// A large library ("Tausende Tagesausflüge", concept §11): `count` trips from the sample home
    /// to anywhere in Europe, one or two days apart from 2005 on, each with `places` places within
    /// about 20 km of each other and a full set of cover candidates. Twelve countries by longitude
    /// (not their real borders: only the sizes matter here).
    static func dayTrips(_ count: Int, places perTrip: Int = 4) -> (trips: [MapTrip], countries: [MapCountry]) {
        var random = MapRandom(seed: 2026)
        let codes = ["PT", "ES", "FR", "BE", "DE", "CH", "AT", "IT", "CZ", "PL", "HU", "RO"]
        let regions: [WorldRegion] = [.southernEurope, .westernEurope, .easternEurope]
        var tripsOf: [[String]] = Array(repeating: [], count: codes.count)
        let first = MapFixture.date("2005-01-01")
        let trips = (0..<count).map { i in
            let latitude = 36 + 24 * random.unit()
            let longitude = -10 + 40 * random.unit()
            let country = min(codes.count - 1, Int((longitude + 10) / 40 * Double(codes.count)))
            tripsOf[country].append("day-\(i)")
            let places = (0..<perTrip).map { p in
                place(MapFixture.at(latitude + 0.18 * (random.unit() - 0.5), longitude + 0.25 * (random.unit() - 0.5)), "Ort \(i)-\(p)", codes[country],
                      photos: 3 + random.int(0..<60), covers: (0..<TripGeometry.coverCandidateLimit).map { "day-\(i)-\(p)-\($0)" })
            }
            return trip("day-\(i)", at: first.addingTimeInterval(TimeInterval(i) * 1.5 * 86_400), places)
        }
        let countries = codes.indices.map { c in
            country(codes[c], "2005-01-01", trips: tripsOf[c], region: regions[c % regions.count], photos: 1_000)
        }
        return (trips, countries)
    }

    /// `items` in an order given by `seed` (Fisher-Yates over `MapRandom`).
    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var random = MapRandom(seed: seed)
        var result = items
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            result.swapAt(i, random.int(0..<(i + 1)))
        }
        return result
    }
}
