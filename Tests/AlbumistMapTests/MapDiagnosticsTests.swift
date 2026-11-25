import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The map's section of the diagnostic report (concept §8: "Der Diagnosebericht enthält keine
/// Koordinaten"): counts only, nothing about where the user lives or travels.
@Suite("Map diagnostics")
struct MapDiagnosticsTests {
    typealias Places = MapFixture.Places

    /// Not among the shared places: a trip to India, whose code "IN" is also an English word.
    static let newDelhi = MapFixture.at(28.6139, 77.2090)

    /// A place of a trip built by hand: where it lies, its name and its country.
    struct HandmadePlace {
        var coordinate: GeoCoordinate
        var name: String
        var country: String

        init(_ coordinate: GeoCoordinate, _ name: String, _ country: String) {
            self.coordinate = coordinate
            self.name = name
            self.country = country
        }
    }

    /// A trip built by hand: its places, its route through them (their indices), how many of its
    /// photos were taken in flight, and when it started.
    struct HandmadeTrip {
        var id: String
        var title: String
        var places: [HandmadePlace]
        var route: [Int]
        var airborne: Int
        var start: String

        /// The trip as the map keeps it, its places named, with coordinates, distances and an
        /// altitude to the last decimal.
        var mapTrip: MapTrip {
            let begin = MapFixture.date(start)
            let day = LocalDay(begin, timeZone: MapFixture.utc)
            let tripPlaces = places.enumerated().map { i, place in
                TripPlace(coordinate: place.coordinate, name: place.name, countryKey: place.country, photoCount: 12 + i, days: [day],
                          coverCandidates: [AssetID("\(id)-cover-\(i)")], altitude: 123.456)
            }
            let points = route.enumerated().map { k, index in
                RoutePoint(placeIndex: index, arrival: begin.addingTimeInterval(Double(k) * 3_600),
                           departure: begin.addingTimeInterval(Double(k) * 3_600 + 1_800), day: day)
            }
            let legs = zip(route, route.dropFirst()).map {
                RouteLeg(meters: GeoMath.distance(places[$0].coordinate, places[$1].coordinate), withoutPhotos: false)
            }
            let geometry = TripGeometry(id: AlbumistID(id), start: begin, end: begin.addingTimeInterval(3 * 86_400),
                                        timeZoneIdentifier: "Atlantic/Reykjavik",
                                        firstDay: day, lastDay: day, photoCount: 40, dayPlaces: [], places: tripPlaces, route: points, legs: legs,
                                        destinationIndex: 0, destination: places[0].coordinate, countryPhotos: [places[0].country: 40],
                                        mainCountryKey: places[0].country, airborneCount: airborne)
            return MapTrip(geometry: geometry, title: title,
                           stats: TripStats(metersOnSite: 1_234.567_8, metersTraveled: 98_765.432_1, metersFromHome: 2_345_678.912),
                           home: home)
        }
    }

    static let home = RoundedHome(coordinate: MapHome.rounded(Places.regensburg), countryCode: "DE")

    /// A summary full of coordinates, names and codes, built by hand: three trips (Iceland with
    /// four places and a route of five points, three photos in flight; Lisbon; New Delhi), three
    /// countries, three arcs from home, pins on every level, four years, still preliminary.
    static let summary: MapSummary = {
        let iceland = HandmadeTrip(id: "trip-iceland", title: "Island-Rundreise",
                                   places: [HandmadePlace(Places.reykjavik, "Reykjavík", "IS"), HandmadePlace(Places.thingvellir, "Þingvellir", "IS"),
                                            HandmadePlace(Places.geysir, "Geysir", "IS"), HandmadePlace(Places.skogafoss, "Skógafoss", "IS")],
                                   route: [0, 1, 2, 3, 0], airborne: 3, start: "2023-06-14 10:00").mapTrip
        let lisbon = HandmadeTrip(id: "trip-lisbon", title: "Lissabon im Mai", places: [HandmadePlace(Places.lisbon, "Lisboa", "PT")],
                                  route: [0], airborne: 0, start: "2024-05-01 09:00").mapTrip
        let delhi = HandmadeTrip(id: "trip-delhi", title: "Neu-Delhi", places: [HandmadePlace(newDelhi, "Delhi", "IN")],
                                 route: [0], airborne: 0, start: "2026-02-10 08:00").mapTrip
        let trips = [iceland, lisbon, delhi]
        let countries = [
            MapCountry(code: "IS", firstVisit: iceland.geometry.start, photoCount: 40, tripIDs: [iceland.id], isState: true, continent: .europe,
                       region: .northernEurope),
            MapCountry(code: "PT", firstVisit: lisbon.geometry.start, photoCount: 40, tripIDs: [lisbon.id], isState: true, continent: .europe,
                       region: .southernEurope),
            MapCountry(code: "IN", firstVisit: delhi.geometry.start, photoCount: 40, tripIDs: [delhi.id], isState: true, continent: .asia,
                       region: .southernAsia),
        ]
        let arcs = trips.map { MapArc(id: "arc:\($0.id.rawValue)", from: home.coordinate, to: $0.geometry.destination, tripIDs: [$0.id], years: [2023]) }
        let pins = [MapPin(id: "region:northernEurope", level: .worldRegion, coordinate: Places.reykjavik, region: .northernEurope, count: 1, years: [2023]),
                    MapPin(id: "region:southernEurope", level: .worldRegion, coordinate: Places.lisbon, region: .southernEurope, count: 1, years: [2024])]
            + countries.map { MapPin(id: "country:\($0.code)", level: .country, coordinate: Places.reykjavik, countryKey: $0.code, count: 1) }
            + trips.map { MapPin(id: "trip:\($0.id.rawValue)", level: .trip, coordinate: $0.geometry.destination, title: $0.title, tripID: $0.id, count: 40) }
            + trips.flatMap { trip in
                trip.geometry.places.enumerated().map { i, place in
                    MapPin(id: "place:\(trip.id.rawValue):\(i)", level: .place, coordinate: place.coordinate, title: place.name, countryKey: place.countryKey,
                           tripID: trip.id, placeIndex: i, count: place.photoCount, cover: place.coverCandidates.first)
                }
            }
        let numbers = WorldNumbers(countries: 3, states: 3, worldShare: 3.0 / 195, continents: [ContinentTally(continent: .europe, visited: 2, total: 46)],
                                   cities: 4, trips: 3, firstTripYear: 2023, firstCountryYear: 2023, metersTraveled: 12_345_678.9, metersOnSite: 345_678.912,
                                   earth: .quarter,
                                   records: [MapRecord(kind: .northernmost, tripID: iceland.id, placeIndex: 0, placeName: "Reykjavík",
                                                       coordinate: Places.reykjavik, day: LocalDay(year: 2023, month: 6, day: 14), value: 64.1466)],
                                   longestTripID: iceland.id, longestTripDays: 9,
                                   mostPhotosInADay: DayRecord(tripID: iceland.id, day: LocalDay(year: 2023, month: 6, day: 15), photoCount: 87,
                                                               placeName: "Geysir"),
                                   favoriteCountry: FavoriteCountry(code: "IS", tripCount: 1, photoCount: 40), year: 2026, newThisYear: ["IN"],
                                   isPreliminary: true)
        let years = [2023, 2024, 2025, 2026].map { year in
            MapYear(year: year, tripIDs: trips.filter { Calendar(identifier: .gregorian).component(.year, from: $0.geometry.start) == year }.map(\.id),
                    newCountries: [], countriesSoFar: 3, tripsSoFar: 3, daysAway: 4, photoCount: 40, metersTraveled: 4_567.891)
        }
        return MapSummary(computedAt: MapFixture.date("2026-11-20 08:30"), home: home, trips: trips, countries: countries, arcs: arcs, pins: pins,
                          numbers: numbers, years: years, focus: MapFocus(center: Places.reykjavik, radiusMeters: 1_234_567.891))
    }()

    /// The counts, and nothing else: no number with decimals (no coordinate, distance, share or
    /// altitude), no name of a place or trip, no country code, nothing about home.
    @Test func theReportHoldsCountsOnly() {
        let lines = MapDiagnostics.lines(for: Self.summary, buildMilliseconds: 87)
        #expect(lines == [
            "map summary format 1, build 87 ms, preliminary true",
            "map trips 3, places 6, countries 3, arcs 3, years 4",
            "map pins world region 2, country 3, trip 3, place 6; longest route 5 points, photos in flight left out 3",
        ])
        let text = lines.joined(separator: "\n")
        #expect(text.range(of: #"\d[.,]\d"#, options: .regularExpression) == nil)
        let names = ["Reykjavík", "Reykjavik", "Þingvellir", "Geysir", "Skógafoss", "Island", "Rundreise", "Lissabon", "Lisboa", "Delhi", "Regensburg"]
        for name in names { #expect(!text.localizedCaseInsensitiveContains(name)) }
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        for code in ["IS", "PT", "IN", "DE"] { #expect(!words.contains(code)) }
        for word in ["home", "zuhause", "house", "haus"] { #expect(!text.lowercased().contains(word)) }
    }

    /// No build time measured, or a negative one (a clock set back), is shown as "?", as the
    /// report writes what it does not know; an empty summary gives zeros.
    @Test func anUnknownBuildTimeIsAQuestionMark() {
        let empty = MapSummary(computedAt: MapFixture.date("2026-11-20"), home: nil, trips: [], countries: [], arcs: [], pins: [],
                               numbers: WorldNumbers(), years: [], focus: nil)
        #expect(MapDiagnostics.lines(for: empty, buildMilliseconds: nil) == [
            "map summary format 1, build ?, preliminary false",
            "map trips 0, places 0, countries 0, arcs 0, years 0",
            "map pins world region 0, country 0, trip 0, place 0; longest route 0 points, photos in flight left out 0",
        ])
        #expect(MapDiagnostics.lines(for: empty, buildMilliseconds: -3).first == "map summary format 1, build ?, preliminary false")
        #expect(MapDiagnostics.lines(for: empty, buildMilliseconds: 0).first == "map summary format 1, build 0 ms, preliminary false")
    }
}
