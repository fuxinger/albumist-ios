import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Trip detection")
struct TripTests {
    let detector = TripDetector(calendar: Fixture.calendar)

    /// Everyday life in Munich with three Rome trips in different years (Scenario B).
    func romeLibrary() -> (LibraryBuilder, [[AssetID]]) {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        let t1 = lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let t2 = lib.daily(from: "2025-09-03", to: "2025-09-08", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let t3 = lib.daily(from: "2026-06-14", to: "2026-06-21", at: Fixture.Places.rome, perDay: 6, hour: 10)
        return (lib, [t1, t2, t3])
    }

    @Test func repeatedVisitsBecomeSeparateTrips() {
        let (lib, expected) = romeLibrary()
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 3)
        for (trip, ids) in zip(trips, expected) {
            #expect(Set(trip.geotaggedAssetIDs) == Set(ids))
            #expect(trip.kind == .vacation)
            #expect(trip.maxDistanceFromHomeMeters > 600_000)
        }
        let de = DateRangeFormatter(language: .german, timeZone: Fixture.utc)
        #expect(de.format(start: trips[0].start, end: trips[0].end) == "12.05.–19.05.2024")
    }

    @Test func dayTripAndWeekendClassification() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2)
        // Sunday 2026-07-12 day trip to Tegernsee (~50 km)
        lib.daily(from: "2026-07-12", to: "2026-07-12", at: Fixture.Places.tegernsee, perDay: 8, hour: 9)
        // Weekend Fri–Sun at Lake Garda
        lib.daily(from: "2026-09-04", to: "2026-09-06", at: Fixture.Places.gardaLake, perDay: 8, hour: 9)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.map(\.kind) == [.dayTrip, .weekendTrip])
    }

    @Test func roadTripAcrossSeveralStops() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 8, skipping: [("2026-08-03", "2026-08-15")])
        lib.daily(from: "2026-08-03", to: "2026-08-05", at: Fixture.Places.florence, perDay: 4, hour: 19)
        lib.daily(from: "2026-08-06", to: "2026-08-09", at: Fixture.Places.rome, perDay: 4, hour: 19)
        lib.daily(from: "2026-08-10", to: "2026-08-13", at: Fixture.Places.naples, perDay: 4, hour: 19)
        lib.daily(from: "2026-08-14", to: "2026-08-15", at: Fixture.Places.gardaLake, perDay: 4, hour: 19)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 1)
        #expect(trips.first?.kind == .roadTrip)
        #expect((trips.first?.distinctStops ?? 0) >= 3)
    }

    /// Someone who mostly takes photos on holiday: a handful of photos at home per year and
    /// a few days of photos per trip (the simulator demo library has exactly this shape).
    /// A short burst of photo days somewhere must never make that place "home".
    @Test func sparseHomePhotographerStillGetsEveryTrip() {
        var lib = LibraryBuilder()
        let cal = Fixture.calendar
        func date(_ y: Int, _ m: Int, _ d: Int, plusDays: Int = 0, hour: Int) -> Date {
            cal.date(byAdding: .day, value: plusDays, to: cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!)!
        }
        let trips: [(GeoCoordinate, Int, Int, Int, Int, Int)] = [   // place, year, month, day, days, photos
            (GeoCoordinate(latitude: 48.8566, longitude: 2.3522), 2018, 10, 5, 3, 12),    // Paris
            (GeoCoordinate(latitude: 41.3874, longitude: 2.1686), 2019, 6, 20, 5, 14),    // Barcelona
            (GeoCoordinate(latitude: 40.7128, longitude: -74.0060), 2019, 11, 2, 6, 16),  // New York
            (GeoCoordinate(latitude: 48.2082, longitude: 16.3738), 2020, 2, 21, 2, 10),   // Wien
            (GeoCoordinate(latitude: 62.1008, longitude: 7.2059), 2021, 7, 12, 5, 14),    // Geiranger
            (GeoCoordinate(latitude: 43.5081, longitude: 16.4402), 2021, 8, 20, 7, 14),   // Split
            (GeoCoordinate(latitude: 38.7223, longitude: -9.1393), 2022, 4, 14, 4, 12),   // Lissabon
            (Fixture.Places.florence, 2022, 9, 3, 3, 11),
            (GeoCoordinate(latitude: 55.6761, longitude: 12.5683), 2023, 5, 18, 3, 10),   // Kopenhagen
            (GeoCoordinate(latitude: 64.1466, longitude: -21.9426), 2023, 8, 1, 4, 12),   // Reykjavík
            (GeoCoordinate(latitude: 63.4186, longitude: -19.0060), 2023, 8, 5, 3, 10),   // Vík, same Iceland trip
            (Fixture.Places.rome, 2024, 5, 10, 5, 20),
            (GeoCoordinate(latitude: 35.0116, longitude: 135.7681), 2024, 10, 8, 6, 16),  // Kyoto
        ]
        for i in 0..<45 {
            _ = lib.photo(at: date(2018 + i % 7, 1 + (i * 5) % 12, 1 + (i * 7) % 27, hour: 10 + i % 9), Fixture.Places.munichHome, jitterMeters: 3_000)
        }
        for i in 0..<12 {
            _ = lib.photo(at: date(2020 + i % 5, 1 + (i * 3) % 12, 5 + i, hour: 15), GeoCoordinate(latitude: 48.3520, longitude: 11.7930))
        }
        for (place, y, m, d, days, photos) in trips {
            for i in 0..<photos { _ = lib.photo(at: date(y, m, d, plusDays: i % days, hour: 9 + i % 10), place, jitterMeters: 2_000) }
        }
        let found = detector.detect(in: lib.assets)
        #expect(found.count == 12)
        #expect(found.allSatisfy { $0.maxDistanceFromHomeMeters > 250_000 })
        let tripPhotos: Int = found.reduce(0) { $0 + $1.allAssetIDs.count }
        let expectedPhotos: Int = trips.reduce(0) { $0 + $1.5 }
        #expect(tripPhotos == expectedPhotos)
    }

    /// A brand-new library (two weeks at home, then a weekend away) keeps its home: the
    /// spread rule must not turn the first weeks into a trip.
    @Test func newLibraryKeepsItsHome() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-03-01", to: "2026-03-14", at: Fixture.Places.munichHome, perDay: 3)
        let away = lib.daily(from: "2026-03-15", to: "2026-03-16", at: Fixture.Places.gardaLake, perDay: 5)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 1)
        #expect(Set(trips.first?.geotaggedAssetIDs ?? []) == Set(away))
    }

    /// Daily photos at home plus a three-week holiday at one place: still one trip.
    @Test func longHolidayAtOnePlaceIsATrip() {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: 2, skipping: [("2025-07-01", "2025-07-24")])
        let beach = lib.daily(from: "2025-07-02", to: "2025-07-23", at: Fixture.Places.naples, perDay: 4)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 1)
        #expect(Set(trips.first?.geotaggedAssetIDs ?? []) == Set(beach))
    }

    @Test func movingHouseDoesNotCreateEndlessTrip() {
        var lib = LibraryBuilder()
        // Lived in Rome until mid 2023, then moved to Munich.
        lib.daily(from: "2022-01-01", to: "2023-06-30", at: Fixture.Places.rome, perDay: 2)
        lib.daily(from: "2023-07-01", to: "2024-12-31", at: Fixture.Places.munichHome, perDay: 2)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.isEmpty)
    }

    @Test func nonGeotaggedPhotosAreOnlyInferredAndScreenshotsNever() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, skipping: [("2026-05-12", "2026-05-19")])
        lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 5, hour: 10)
        let camera = lib.photo(at: Fixture.date("2026-05-15 13:00"), nil)
        let screenshot = lib.photo(at: Fixture.date("2026-05-15 13:05"), nil, subtypes: .screenshot)
        let messenger = lib.photo(at: Fixture.date("2026-05-15 13:10"), nil, filename: "IMG-20260515-WA0003.jpg")
        let outside = lib.photo(at: Fixture.date("2026-06-15 13:00"), nil)
        let trips = detector.detect(in: lib.assets, excludeFromInference: { $0.originalFilename?.contains("-WA") == true })
        let trip = trips.first { $0.geotaggedAssetIDs.count == 40 }
        #expect(trip?.inferredAssetIDs == [camera])
        #expect(trip?.geotaggedAssetIDs.contains(screenshot) == false)
        #expect(trip?.allAssetIDs.contains(messenger) == false)
        #expect(trip?.allAssetIDs.contains(outside) == false)
    }

    @Test func userCorrectionsSplitAndMergePersistByTime() {
        let (lib, _) = romeLibrary()
        // Split the first Rome trip in the middle.
        let split = detector.detect(in: lib.assets, corrections: .init(forcedBreaks: [Fixture.date("2024-05-16")]))
        #expect(split.count == 4)

        // Merge: two nearby trips separated by a short home stay.
        var lib2 = LibraryBuilder()
        lib2.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 8, skipping: [("2026-08-01", "2026-08-03"), ("2026-08-06", "2026-08-08")])
        lib2.daily(from: "2026-08-01", to: "2026-08-03", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        lib2.daily(from: "2026-08-06", to: "2026-08-08", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        #expect(detector.detect(in: lib2.assets).count == 2)
        let joined = detector.detect(in: lib2.assets, corrections: .init(forcedJoins: [DateInterval(start: Fixture.date("2026-08-01"), end: Fixture.date("2026-08-09"))]))
        #expect(joined.count == 1)
    }

    @Test func tripIdentityIsStableAcrossRuns() {
        let (lib, _) = romeLibrary()
        #expect(detector.detect(in: lib.assets).map(\.id) == detector.detect(in: lib.assets.reversed()).map(\.id))
    }

    /// A week in one place on Taveuni (Fiji), which the 180th meridian crosses: the evenings
    /// are a few hundred metres on either side of it. It is one stop, as anywhere else, not two
    /// (the cells of 179.99° and −179.99° were at opposite ends of the grid).
    @Test func aStayOnTheDateLineIsOneStop() {
        let east = GeoCoordinate(latitude: -16.80, longitude: 179.997)
        let west = GeoCoordinate(latitude: -16.80, longitude: -179.997)
        #expect(GeoMath.distance(east, west) < 1_000)
        var dates: [Date] = [], coordinates: [GeoCoordinate] = []
        for day in 0..<7 {
            for (hour, place) in [(10, east), (20, west), (21, east)] {
                dates.append(Fixture.date("2026-08-0\(day + 1) \(hour):00"))
                coordinates.append(place)
            }
        }
        let classified = TripDetector.classify(dates: dates, coordinates: coordinates, calendar: Fixture.calendar)
        #expect(classified.stops == 1)
        #expect(classified.kind == .vacation)
        // Three places on the islands a day's drive apart, all on the west side and one across:
        // still three stops.
        let stops = [GeoCoordinate(latitude: -17.75, longitude: 177.45), GeoCoordinate(latitude: -16.45, longitude: 179.35), west]
        let tour = TripDetector.classify(dates: (0..<6).map { Fixture.date("2026-08-0\($0 + 1) 20:00") },
                                         coordinates: (0..<6).map { stops[$0 / 2] }, calendar: Fixture.calendar)
        #expect(tour.stops == 3)
    }

    /// San Francisco and Tokyo on one trip: nothing near the date line. The stops are counted
    /// on the usual grid, exactly as for each city alone: two places in San Francisco a few
    /// metres apart, in one cell of that grid, are one stop, wherever a grid with its seam
    /// elsewhere would cut between them.
    @Test func aTripAcrossThePacificCountsItsStopsOnTheUsualGrid() throws {
        let latitude = 37.7749
        func plain(_ lon: Double) -> GeoCell { GeoCell(GeoCoordinate(latitude: latitude, longitude: lon), sizeMeters: 25_000) }
        func moved(_ lon: Double) -> GeoCell { GeoCell(GeoCoordinate(latitude: latitude, longitude: lon + 360), sizeMeters: 25_000) }
        // Two points less than a metre apart in San Francisco where a grid moved by 360° cuts
        // and the usual one does not.
        var a = try #require(stride(from: -122.6, to: -122.2, by: 0.001).first { plain($0) == plain($0 + 0.001) && moved($0) != moved($0 + 0.001) })
        var b = a + 0.001
        while b - a > 0.000_005 {
            let mid = (a + b) / 2
            if moved(mid) == moved(a) { a = mid } else { b = mid }
        }
        let sf = [GeoCoordinate(latitude: latitude, longitude: a), GeoCoordinate(latitude: latitude, longitude: b)]
        #expect(GeoMath.distance(sf[0], sf[1]) < 1)
        let tokyo = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)
        var dates: [Date] = [], coordinates: [GeoCoordinate] = []
        for day in 0..<6 {
            dates.append(Fixture.date("2026-09-0\(day + 1) 20:00"))
            coordinates.append(day < 3 ? sf[day % 2] : tokyo)
        }
        let classified = TripDetector.classify(dates: dates, coordinates: coordinates, calendar: Fixture.calendar)
        #expect(classified.stops == 2)
    }
}

@Suite("Frequent places")
struct FrequentPlaceTests {
    @Test func detectsRecurringPlacesWithoutNamingThem() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 3)
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichWork, perDay: 1, everyNthDay: 7)
        lib.daily(from: "2026-03-01", to: "2026-03-02", at: Fixture.Places.rome, perDay: 10)
        let detector = FrequentPlaceDetector(calendar: Fixture.calendar)
        let places = detector.detect(in: lib.assets)
        #expect(places.count == 2)
        #expect(places[0].distinctDays == 181)
        #expect(places[0].userName == nil)
        #expect(places[1].distinctDays == 26)
        #expect(GeoMath.distance(places[1].centroid, Fixture.Places.munichWork) < 100)
    }

    @Test func mergeRadiusTreatsLargePremisesAsOnePlace() {
        var lib = LibraryBuilder()
        let a = Fixture.Places.munichHome
        let b = GeoCoordinate(latitude: a.latitude + 0.004, longitude: a.longitude) // ~450 m apart
        lib.daily(from: "2026-01-01", to: "2026-03-31", at: a, perDay: 2)
        lib.daily(from: "2026-01-01", to: "2026-03-31", at: b, perDay: 2)
        var config = FrequentPlaceDetector.Configuration()
        #expect(FrequentPlaceDetector(configuration: config, calendar: Fixture.calendar).detect(in: lib.assets).count == 2)
        config.mergeRadiusMeters = 600
        #expect(FrequentPlaceDetector(configuration: config, calendar: Fixture.calendar).detect(in: lib.assets).count == 1)
    }
}
