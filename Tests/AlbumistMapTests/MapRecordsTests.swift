import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// The records of "Deine Welt in Zahlen" (only from trips' places, ties broken the same way every
/// time), the longest trip, the day with the most photos, and the numbers held while the analysis
/// runs.
@Suite("Map records")
struct MapRecordsTests {
    typealias Places = MapFixture.Places
    static let zugspitze = MapFixture.at(47.4211, 10.9853)
    static let garmisch = MapFixture.at(47.4917, 11.0955)

    /// Six trips from the sample home: Iceland, Svalbard, Patagonia, the Pacific, New Zealand
    /// and the Alps.
    static var world: [MapTrip] {
        let home = HandBuilt.home()
        return [
            HandBuilt.trip("iceland", "2023-06-14", "2023-06-22", places: [
                HandBuilt.place(Places.reykjavik, "Reykjavík", country: "IS", photos: 40, days: ["2023-06-14", "2023-06-21"]),
                HandBuilt.place(Places.gullfoss, "Gullfoss", country: "IS", photos: 12, days: ["2023-06-15", "2023-06-18"], altitude: 180),
                HandBuilt.place(Places.vik, "Vík", country: "IS", photos: 15, days: ["2023-06-16"]),
            ], home: home),
            HandBuilt.trip("svalbard", "2024-07-01", "2024-07-05", places: [
                HandBuilt.place(Places.longyearbyen, "Longyearbyen", country: "SJ", photos: 20, days: ["2024-07-01"], altitude: 20),
            ], home: home),
            HandBuilt.trip("patagonia", "2019-11-10", "2019-11-30", places: [
                HandBuilt.place(Places.ushuaia, "Ushuaia", country: "AR", photos: 30, days: ["2019-11-12"]),
            ], home: home),
            HandBuilt.trip("pacific", "2022-08-01", "2022-08-20", places: [
                HandBuilt.place(Places.suva, "Suva", country: "FJ", days: ["2022-08-02"]),
                HandBuilt.place(Places.apia, "Apia", country: "WS", days: ["2022-08-08"]),
                HandBuilt.place(Places.honolulu, "Honolulu", country: "US", days: ["2022-08-15"]),
            ], home: home),
            HandBuilt.trip("newzealand", "2025-02-01", "2025-02-21", places: [
                HandBuilt.place(Places.auckland, "Auckland", country: "NZ", days: ["2025-02-02"]),
            ], home: home),
            HandBuilt.trip("alps", "2021-03-01", "2021-03-03", places: [
                HandBuilt.place(Self.garmisch, "Garmisch-Partenkirchen", country: "DE", days: ["2021-03-01"], altitude: 708),
                HandBuilt.place(Self.zugspitze, "Zugspitze", country: "DE", days: ["2021-03-02"], altitude: 2_962),
            ], home: home),
        ]
    }

    @Test func recordsComeFromTheTripsPlaces() throws {
        let numbers = HandBuilt.numbers(Self.world)
        #expect(numbers.records.map(\.kind) == MapRecord.Kind.allCases)
        let north = try #require(numbers.record(.northernmost))
        #expect(north == MapRecord(kind: .northernmost, tripID: AlbumistID("svalbard"), placeIndex: 0, placeName: "Longyearbyen",
                                   coordinate: Places.longyearbyen, day: HandBuilt.day("2024-07-01"), value: Places.longyearbyen.latitude))
        let south = try #require(numbers.record(.southernmost))
        #expect(south.tripID == AlbumistID("patagonia") && south.placeName == "Ushuaia" && south.value == Places.ushuaia.latitude)
        let high = try #require(numbers.record(.highest))
        #expect(high.tripID == AlbumistID("alps") && high.placeIndex == 1 && high.placeName == "Zugspitze" && high.value == 2_962)
        #expect(high.day == HandBuilt.day("2021-03-02") && high.coordinate == Self.zugspitze)
        // The farthest place from the home of the trip's time, in metres.
        let far = try #require(numbers.record(.farthest))
        let home = HandBuilt.home().coordinate
        let allPlaces = Self.world.flatMap { trip in trip.geometry.places.map { (trip.id, $0) } }
        let farthest = try #require(allPlaces.max { GeoMath.distance(home, $0.1.coordinate) < GeoMath.distance(home, $1.1.coordinate) })
        #expect(far.tripID == farthest.0 && far.placeName == farthest.1.name)
        #expect(far.value == GeoMath.distance(home, farthest.1.coordinate))
        #expect(far.placeName == "Auckland")
        // A record's day is the first day its place has photos on.
        let iceland = HandBuilt.numbers([Self.world[0]])
        #expect(iceland.record(.highest)?.day == HandBuilt.day("2023-06-15"))
        #expect(iceland.record(.westernmost)?.placeName == "Reykjavík")
        #expect(iceland.record(.westernmost)?.day == HandBuilt.day("2023-06-14"))
    }

    /// East and west are plain longitude: Fiji (178° E) is the easternmost, Samoa (172° W), just
    /// across the antimeridian, the westernmost.
    @Test func eastAndWestArePlainLongitudeAcrossTheAntimeridian() throws {
        let numbers = HandBuilt.numbers(Self.world)
        let east = try #require(numbers.record(.easternmost))
        #expect(east.tripID == AlbumistID("pacific") && east.placeIndex == 0 && east.placeName == "Suva" && east.value == Places.suva.longitude)
        let west = try #require(numbers.record(.westernmost))
        #expect(west.tripID == AlbumistID("pacific") && west.placeIndex == 1 && west.placeName == "Apia" && west.value == Places.apia.longitude)
        #expect(west.day == HandBuilt.day("2022-08-08"))
    }

    /// The 3-photo rule is the geometry's: a record only ever comes from `places`, never from a
    /// trip's destination without a place (a medoid of a few photos).
    @Test func aDestinationWithoutAPlaceMakesNoRecord() {
        let home = HandBuilt.home()
        let fewPhotos = HandBuilt.trip("north", "2024-07-01", destination: Places.longyearbyen, home: home)
        #expect(HandBuilt.numbers([fewPhotos]).records.isEmpty)
        let numbers = HandBuilt.numbers([fewPhotos, Self.world[0]])
        #expect(numbers.record(.northernmost)?.placeName == "Gullfoss")
        #expect(numbers.records.allSatisfy { $0.tripID == AlbumistID("iceland") })
    }

    @Test func farthestNeedsAHomeAndHighestAnAltitude() {
        let noHome = Self.world.map { trip -> MapTrip in var trip = trip; trip.home = nil; return trip }
        let numbers = HandBuilt.numbers(noHome)
        #expect(numbers.record(.farthest) == nil)
        #expect(numbers.records.count == 5)
        let flat = HandBuilt.numbers([Self.world[2], Self.world[3]])
        #expect(flat.record(.highest) == nil)
        #expect(flat.records.map(\.kind) == [.farthest, .northernmost, .southernmost, .easternmost, .westernmost])
    }

    @Test func aPlaceWithABrokenCoordinateOrAltitudeIsSkipped() {
        let home = HandBuilt.home()
        var trip = HandBuilt.trip("odd", "2023-01-01", places: [HandBuilt.place(Places.rome, "Rom", altitude: .nan),
                                                                HandBuilt.place(Places.florence, "Florenz", altitude: 50)], home: home)
        trip.geometry.places.append(HandBuilt.place(MapFixture.at(.nan, 10), "Nirgends", altitude: 9_000))
        trip.geometry.places.append(HandBuilt.place(MapFixture.at(0, 0), "Null Island"))
        let numbers = HandBuilt.numbers([trip])
        #expect(numbers.records.allSatisfy { $0.placeName == "Rom" || $0.placeName == "Florenz" })
        #expect(numbers.record(.highest)?.placeName == "Florenz")
        #expect(numbers.record(.southernmost)?.placeName == "Rom")
    }

    @Test func recordTiesGoToTheEarlierTripThenTheIDThenThePlace() {
        let home = HandBuilt.home()
        func svalbard(_ id: String, _ start: String) -> MapTrip {
            HandBuilt.trip(id, start, places: [HandBuilt.place(Places.longyearbyen, "Longyearbyen \(id)", altitude: 20)], home: home)
        }
        let later = svalbard("a-later", "2024-07-01"), earlier = svalbard("z-earlier", "2022-07-01")
        for trips in [[later, earlier], [earlier, later]] {
            let numbers = HandBuilt.numbers(trips)
            #expect(numbers.records.count == 6)
            #expect(numbers.records.allSatisfy { $0.tripID == AlbumistID("z-earlier") })
        }
        let sameStart = [svalbard("b", "2022-07-01"), svalbard("a", "2022-07-01")]
        #expect(HandBuilt.numbers(sameStart).records.allSatisfy { $0.tripID == AlbumistID("a") })
        // Two places of one trip on the same latitude: the lower index is the northernmost.
        let twin = HandBuilt.trip("twin", "2023-01-01", places: [HandBuilt.place(MapFixture.at(60, 5), "West"),
                                                                 HandBuilt.place(MapFixture.at(60, 25), "Ost")], home: home)
        #expect(HandBuilt.numbers([twin]).record(.northernmost)?.placeIndex == 0)
        #expect(HandBuilt.numbers([twin]).record(.southernmost)?.placeIndex == 0)
        #expect(HandBuilt.numbers([twin]).record(.easternmost)?.placeIndex == 1)
    }

    @Test func theLongestTripHasTheMostDaysATieTheMoreRecentStart() {
        let nine = HandBuilt.trip("nine", "2023-06-14", "2023-06-22")
        let fourteenOld = HandBuilt.trip("old", "2019-08-01", "2019-08-14")
        let fourteenNew = HandBuilt.trip("new", "2021-08-01 08:00", "2021-08-14 20:00")
        var numbers = HandBuilt.numbers([fourteenNew, nine, fourteenOld])
        #expect(numbers.longestTripID == AlbumistID("new") && numbers.longestTripDays == 14)
        numbers = HandBuilt.numbers([nine])
        #expect(numbers.longestTripID == AlbumistID("nine") && numbers.longestTripDays == 9)
        // Same days, same start: the smaller id.
        let twins = [HandBuilt.trip("b", "2021-08-01", "2021-08-14"), HandBuilt.trip("a", "2021-08-01", "2021-08-14")]
        #expect(HandBuilt.numbers(twins).longestTripID == AlbumistID("a"))
        #expect(HandBuilt.numbers(twins.reversed()).longestTripID == AlbumistID("a"))
    }

    @Test func theDayWithTheMostPhotos() throws {
        let iceland = HandBuilt.trip("iceland", "2023-06-14", places: [HandBuilt.place(Places.reykjavik, "Reykjavík")],
                                     dayCounts: [HandBuilt.dayCount("2023-06-14", 96, place: 0), HandBuilt.dayCount("2023-06-15", 40, place: 0)])
        let kyoto = HandBuilt.trip("japan", "2024-04-01", dayCounts: [HandBuilt.dayCount("2024-04-03", 96), HandBuilt.dayCount("2024-04-04", 12)])
        var numbers = HandBuilt.numbers([kyoto, iceland])
        // A tie: the earlier day.
        #expect(numbers.mostPhotosInADay == DayRecord(tripID: AlbumistID("iceland"), day: HandBuilt.day("2023-06-14"), photoCount: 96,
                                                       placeName: "Reykjavík"))
        let more = HandBuilt.trip("more", "2025-01-01", dayCounts: [HandBuilt.dayCount("2025-01-01", 97, place: 5)])
        numbers = HandBuilt.numbers([kyoto, iceland, more])
        // The place index names no place: no name.
        #expect(numbers.mostPhotosInADay == DayRecord(tripID: AlbumistID("more"), day: HandBuilt.day("2025-01-01"), photoCount: 97, placeName: nil))
        // The same day on two trips (one ends, the next begins): the smaller trip id.
        let a = HandBuilt.trip("b-trip", "2023-06-14", dayCounts: [HandBuilt.dayCount("2023-06-20", 50)])
        let b = HandBuilt.trip("a-trip", "2023-06-20", dayCounts: [HandBuilt.dayCount("2023-06-20", 50)])
        #expect(HandBuilt.numbers([a, b]).mostPhotosInADay?.tripID == AlbumistID("a-trip"))
        #expect(HandBuilt.numbers([b, a]).mostPhotosInADay?.tripID == AlbumistID("a-trip"))
        // Days without photos are no record.
        #expect(HandBuilt.numbers([HandBuilt.trip("empty", "2023-01-01", dayCounts: [HandBuilt.dayCount("2023-01-01", 0)])]).mostPhotosInADay == nil)
    }

    @Test func theSameTripsInAnyOrderGiveTheSameNumbers() {
        let countries = [HandBuilt.country("IS", "2023-06-14"), HandBuilt.country("AR", "2019-11-10"), HandBuilt.country("FJ", "2022-08-01")]
        let reference = HandBuilt.numbers(Self.world, countries, cities: 9)
        for seed in UInt64(1)...6 {
            #expect(HandBuilt.numbers(HandBuilt.shuffled(Self.world, seed: seed), HandBuilt.shuffled(countries, seed: seed), cities: 9) == reference)
        }
    }

    // MARK: Holding highs

    /// Which record value is the more extreme, written out once more for the checks.
    static func beats(_ value: Double, _ other: Double, kind: MapRecord.Kind) -> Bool {
        switch kind {
        case .farthest, .northernmost, .easternmost, .highest: value > other
        case .southernmost, .westernmost: value < other
        }
    }

    static func record(_ kind: MapRecord.Kind, _ value: Double, trip: String = "t") -> MapRecord {
        MapRecord(kind: kind, tripID: AlbumistID(trip), placeIndex: 0, placeName: "\(kind) \(value)", coordinate: MapFixture.at(10, 10),
                  day: HandBuilt.day("2023-01-01"), value: value)
    }

    static func tallies(_ visited: [Int]) -> [ContinentTally] {
        zip(WorldNumbers.inhabitedContinents, visited).map { ContinentTally(continent: $0, visited: $1, total: WorldStates.count(on: $0)) }
    }

    /// What the map showed before: the analysis had found 14 countries, 48 trips, 88,800 km.
    static var before: WorldNumbers {
        WorldNumbers(countries: 14, states: 12, worldShare: 12.0 / 195, continents: tallies([0, 2, 10, 0, 0, 0]), cities: 80, trips: 48,
                     firstTripYear: 2011, firstCountryYear: 2009, metersTraveled: 88_800_000, metersOnSite: 9_000_000,
                     earth: .aroundTheEarth(times: 2.2),
                     records: [record(.farthest, 18_000_000), record(.northernmost, 78.2), record(.southernmost, -54.8),
                               record(.easternmost, 178.4), record(.westernmost, -171.8), record(.highest, 2_962)],
                     longestTripID: AlbumistID("long"), longestTripDays: 21,
                     mostPhotosInADay: DayRecord(tripID: AlbumistID("kyoto"), day: HandBuilt.day("2024-04-03"), photoCount: 96, placeName: "Kyoto"),
                     favoriteCountry: FavoriteCountry(code: "IT", tripCount: 3, photoCount: 400), year: 2026, newThisYear: ["GB"],
                     isPreliminary: true)
    }

    /// A moment later the running analysis has re-split trips and re-read places: everything is
    /// a little smaller.
    static var smaller: WorldNumbers {
        WorldNumbers(countries: 13, states: 11, worldShare: 11.0 / 195, continents: tallies([0, 1, 10, 0, 0, 0]), cities: 70, trips: 46,
                     firstTripYear: 2012, firstCountryYear: 2010, metersTraveled: 40_000_000, metersOnSite: 8_000_000,
                     earth: .half,
                     records: [record(.northernmost, 64.1), record(.southernmost, -36.8), record(.easternmost, 174.7),
                               record(.westernmost, -157.8), record(.highest, 2_000)],
                     longestTripID: AlbumistID("shorter"), longestTripDays: 14,
                     mostPhotosInADay: DayRecord(tripID: AlbumistID("rome"), day: HandBuilt.day("2022-05-01"), photoCount: 60, placeName: "Rom"),
                     favoriteCountry: FavoriteCountry(code: "ES", tripCount: 2, photoCount: 500), year: 2026, newThisYear: [],
                     isPreliminary: true)
    }

    @Test func whileTheAnalysisRunsNoNumberGoesDown() {
        let held = Self.smaller.holdingHighs(over: Self.before)
        let before = Self.before
        #expect(held.countries == 14 && held.states == 12 && held.worldShare == before.worldShare)
        #expect(held.continents == before.continents)
        #expect(held.cities == 80 && held.trips == 48)
        #expect(held.firstTripYear == 2011 && held.firstCountryYear == 2009)
        #expect(held.metersTraveled == 88_800_000 && held.metersOnSite == 9_000_000)
        #expect(held.earth == .aroundTheEarth(times: 2.2))
        #expect(held.records == before.records)
        #expect(held.longestTripID == AlbumistID("long") && held.longestTripDays == 21)
        #expect(held.mostPhotosInADay == before.mostPhotosInADay)
        #expect(held.favoriteCountry == before.favoriteCountry)
        // Not numbers: the year and what is new in it are today's.
        #expect(held.newThisYear.isEmpty && held.year == 2026)
        #expect(held.isPreliminary)
    }

    @Test func numbersThatGrowAreShownAtOnce() {
        let held = Self.before.holdingHighs(over: Self.smaller)
        #expect(held == Self.before)
        #expect(Self.before.holdingHighs(over: Self.before) == Self.before)
    }

    @Test func eachNumberIsHeldOnItsOwn() {
        var now = Self.smaller
        now.countries = 15
        now.continents = Self.tallies([1, 1, 9, 0, 0, 0])
        now.metersOnSite = 9_500_000
        now.longestTripID = AlbumistID("equal")
        now.longestTripDays = 21
        now.favoriteCountry = FavoriteCountry(code: "ES", tripCount: 3, photoCount: 500)
        let held = now.holdingHighs(over: Self.before)
        #expect(held.countries == 15 && held.states == 12)
        #expect(held.continents.map(\.visited) == [1, 2, 10, 0, 0, 0])
        #expect(held.continents.map(\.total) == [54, 46, 46, 23, 14, 12])
        #expect(held.metersOnSite == 9_500_000 && held.metersTraveled == 88_800_000)
        // On equal values the current one stands.
        #expect(held.longestTripID == AlbumistID("equal") && held.longestTripDays == 21)
        #expect(held.favoriteCountry?.code == "ES")
    }

    @Test func recordsKeepTheMoreExtremeValue() throws {
        var now = Self.smaller
        // Higher than before, and as far north as before (from another trip).
        now.records = [Self.record(.northernmost, 78.2, trip: "again"), Self.record(.highest, 3_100, trip: "higher"),
                       Self.record(.westernmost, -175, trip: "farther-west")]
        let held = now.holdingHighs(over: Self.before)
        #expect(held.records.map(\.kind) == MapRecord.Kind.allCases)
        #expect(held.record(.farthest)?.value == 18_000_000)
        #expect(held.record(.northernmost)?.tripID == AlbumistID("again"))
        #expect(held.record(.southernmost)?.value == -54.8)
        #expect(held.record(.easternmost)?.value == 178.4)
        #expect(held.record(.westernmost)?.tripID == AlbumistID("farther-west"))
        #expect(held.record(.highest)?.tripID == AlbumistID("higher"))
        // Southern and western records keep the smaller value, the others the larger.
        var south = Self.smaller
        south.records = [Self.record(.southernmost, -60, trip: "antarctic"), Self.record(.easternmost, 179, trip: "east")]
        let heldSouth = south.holdingHighs(over: Self.before)
        #expect(heldSouth.record(.southernmost)?.tripID == AlbumistID("antarctic"))
        #expect(heldSouth.record(.easternmost)?.tripID == AlbumistID("east"))
        #expect(try #require(heldSouth.record(.westernmost)).value == -171.8)
    }

    /// After the analysis, deleted photos, a corrected trip or a new home may make numbers
    /// smaller: that is honest, nothing is held.
    @Test func aCompleteAnalysisMayShowSmallerNumbers() {
        var complete = Self.smaller
        complete.isPreliminary = false
        #expect(complete.holdingHighs(over: Self.before) == complete)
        #expect(Self.smaller.holdingHighs(over: nil) == Self.smaller)
        // A complete earlier state is held over while a new analysis runs.
        var finished = Self.before
        finished.isPreliminary = false
        #expect(Self.smaller.holdingHighs(over: finished).countries == 14)
    }

    @Test func aMissingNumberKeepsThePreviousOne() {
        let empty = HandBuilt.numbers([], running: true)
        let held = empty.holdingHighs(over: Self.before)
        #expect(held.records == Self.before.records)
        #expect(held.longestTripID == AlbumistID("long") && held.longestTripDays == 21)
        #expect(held.mostPhotosInADay == Self.before.mostPhotosInADay)
        #expect(held.favoriteCountry == Self.before.favoriteCountry)
        #expect(held.firstTripYear == 2011)
        #expect(held.trips == 48)
        // And nothing appears from nowhere.
        #expect(HandBuilt.numbers([], running: true).holdingHighs(over: HandBuilt.numbers([], running: true)) == empty)
    }

    /// A run of snapshots while the analysis works through the library, each shown held over the
    /// one shown before: no count ever goes down; the complete result at the end is shown as it is.
    @Test func aRunningAnalysisNeverShowsANumberGoingDown() {
        var random = MapRandom(seed: 42)
        let home = HandBuilt.home()
        let places: [(GeoCoordinate, String)] = [(Places.reykjavik, "Reykjavík"), (Places.lisbon, "Lissabon"), (Places.rome, "Rom"),
                                                 (Places.tokyo, "Tokio"), (Places.auckland, "Auckland"), (Places.longyearbyen, "Longyearbyen"),
                                                 (Places.ushuaia, "Ushuaia"), (Places.honolulu, "Honolulu")]
        func snapshot(_ step: Int) -> WorldNumbers {
            // Each step sees a random part of the trips, as an analysis that also re-splits them.
            let trips = (0..<8).compactMap { i -> MapTrip? in
                guard random.int(0..<3) > 0 else { return nil }
                let place = places[(i + random.int(0..<2)) % places.count]
                return HandBuilt.trip("t\(i)", "201\(i)-05-01", "201\(i)-05-\(10 + random.int(0..<15))",
                                      places: [HandBuilt.place(place.0, place.1, altitude: random.unit() * 2_000)],
                                      dayCounts: [HandBuilt.dayCount("201\(i)-05-01", random.int(1..<100), place: 0)],
                                      countryPhotos: ["IT": random.int(0..<6), "ES": random.int(0..<6)], home: home)
            }
            let countries = ["IT", "ES", "PT", "IS", "JP"].prefix(random.int(1..<6)).map { HandBuilt.country($0, "2012-01-01") }
            return HandBuilt.numbers(trips, countries, cities: random.int(0..<50), running: true)
        }
        var shown = snapshot(0)
        for step in 1...40 {
            let next = snapshot(step).holdingHighs(over: shown)
            #expect(next.countries >= shown.countries && next.states >= shown.states && next.worldShare >= shown.worldShare)
            #expect(zip(next.continents, shown.continents).allSatisfy { $0.visited >= $1.visited })
            #expect(next.cities >= shown.cities && next.trips >= shown.trips)
            #expect(next.metersTraveled >= shown.metersTraveled && next.metersOnSite >= shown.metersOnSite)
            #expect((next.longestTripDays ?? 0) >= (shown.longestTripDays ?? 0))
            #expect((next.mostPhotosInADay?.photoCount ?? 0) >= (shown.mostPhotosInADay?.photoCount ?? 0))
            #expect((next.favoriteCountry?.tripCount ?? 0) >= (shown.favoriteCountry?.tripCount ?? 0))
            for kind in MapRecord.Kind.allCases {
                guard let before = shown.record(kind) else { continue }
                let now = next.record(kind)
                #expect(now != nil, "\(kind) disappeared at step \(step)")
                if let now { #expect(now.value == before.value || Self.beats(now.value, before.value, kind: kind)) }
            }
            shown = next
        }
        var complete = snapshot(41)
        complete.isPreliminary = false
        #expect(complete.holdingHighs(over: shown) == complete)
    }
}
