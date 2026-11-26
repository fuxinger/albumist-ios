import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// The numbers of "Deine Welt in Zahlen" held while the analysis runs: no count and no record goes
/// down, each number is held on its own, a missing number keeps the one before, and a complete
/// analysis may show smaller numbers.
extension MapRecordsTests {
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
