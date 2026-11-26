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
}
