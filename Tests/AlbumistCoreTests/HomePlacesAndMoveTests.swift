import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Re-review of "Dein Zuhause" (16.11.): the home places taken from the photos around each
/// chosen home stay linear. Measured in a release build on about 50,000 photos with three homes:
/// 0.03 s (3.0 s before), the search index 0.8 s (4.8 s before). The test counts instead of
/// timing, on a smaller library: a timed test on CI slows the other timed tests running beside it.
@Suite("Re-review: Dein Zuhause timing")
struct ReReviewHomeTimingTests {
    static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let cologne = GeoCoordinate(latitude: 50.9375, longitude: 6.9603)
    static let vienna = GeoCoordinate(latitude: 48.2082, longitude: 16.3738)

    static func library() -> [AssetFacts] {
        let table: [(GeoCoordinate, PlaceComponents)] = [
            (Fixture.Places.munichHome, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", subAdministrativeArea: "Oberbayern", locality: "München")),
            (hamburg, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Hamburg", locality: "Hamburg")),
            (cologne, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Nordrhein-Westfalen", subAdministrativeArea: "Köln", locality: "Köln")),
            (vienna, PlaceComponents(isoCountryCode: "AT", country: "Österreich", administrativeArea: "Wien", locality: "Wien")),
            (Fixture.Places.rome, PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", subAdministrativeArea: "Rom", locality: "Rom")),
            (Fixture.Places.gardaLake, PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Venetien", subAdministrativeArea: "Verona", locality: "Malcesine")),
        ]
        var lib = LibraryBuilder()
        lib.daily(from: "2010-01-01", to: "2014-12-31", at: cologne, perDay: 1, hour: 19)
        lib.daily(from: "2015-01-01", to: "2018-12-31", at: hamburg, perDay: 1, hour: 19)
        lib.daily(from: "2019-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 1, hour: 19)
        for year in 2010...2026 {
            lib.daily(from: "\(year)-05-10", to: "\(year)-05-17", at: Fixture.Places.rome, perDay: 8, hour: 10)
            lib.daily(from: "\(year)-08-01", to: "\(year)-08-10", at: Fixture.Places.gardaLake, perDay: 6, hour: 10)
            lib.daily(from: "\(year)-10-01", to: "\(year)-10-04", at: vienna, perDay: 6, hour: 10)
        }
        return lib.assets.map { a in
            let c = a.usableLocation!
            let nearest = table.min { GeoMath.distance(c, $0.0) < GeoMath.distance(c, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
    }

    /// Three chosen homes: the places' keys are worked out once per distinct place of the
    /// library (six here), not once per photo and home; per home only the distance is measured.
    @Test func homePlacesAreWorkedOutOncePerPlace() throws {
        let facts = Self.library()
        #expect(facts.count > 7_000)
        let now = Fixture.date("2026-11-16")
        let chosen = HomeSettings()
            .choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now)
            .addingFormer(FormerHome(place: HomePlace(center: Self.hamburg, components: nil), until: Fixture.date("2019-01-01")), date: now)
            .addingFormer(FormerHome(place: HomePlace(center: Self.cologne, components: nil), until: Fixture.date("2015-01-01")), date: now)
        let profile = LibraryProfile(facts: facts, trips: [])
        let context = HomeContext(settings: chosen, profile: profile, facts: facts)
        #expect(context.placeKeyLookups == Set(facts.compactMap(\.gpsPlace)).count)
        #expect(context.placeKeyLookups == 6)
        #expect(HomeContext(settings: HomeSettings(), profile: profile, facts: facts).placeKeyLookups == 0)
        let munich = try #require(chosen.confirmed)
        #expect(context.isHome(PlaceKey(level: .locality, path: "de/bayern/oberbayern/munchen"), at: now))
        #expect(context.chosenKeys[munich.id]?.contains(PlaceKey(level: .country, path: "de")) == true)
        #expect(context.chosenKeys[munich.id]?.contains(PlaceKey(level: .country, path: "it")) == false)
        // The same answer as working out every photo's keys for every home.
        let slow = Set(facts.filter { $0.asset.usableLocation.map { GeoMath.distance($0, munich.center) <= 30_000 } ?? false }
            .compactMap(\.gpsPlace).flatMap { place in PlaceKeyTable.levels.compactMap { place.key(at: $0) } })
        #expect(context.chosenKeys[munich.id] == slow)
    }
}

/// Re-review: "Ändern" right after a move. The detection still shows the old town for up to
/// 120 days; the user picks the new one under "Ändern". It holds from the start of the stay
/// there ("Seit wann wohnst du dort?", proposed by `HomeCandidates.stayStart`), so the years in
/// the old town stay as they were.
@Suite("Re-review: Ändern after a move")
struct ReReviewChangeAfterAMoveTests {
    static let berlin = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)

    @Test func pickingTheNewTownUnderAendernKeepsThePastAsItWas() throws {
        var lib = LibraryBuilder()
        let munich = lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let automatic = detector.analyse(in: lib.assets)
        let detected = try #require(automatic.detectedHome)
        // The premise: the detection still shows Munich.
        #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 30_000)
        let now = Fixture.date("2026-11-16")
        let since = try #require(HomeCandidates.stayStart(near: Self.berlin, assets: lib.assets, calendar: Fixture.calendar))
        #expect(since == Fixture.date("2026-09-01"))
        let picked = detector.analyse(in: lib.assets, home: HomeSettings().choosing(HomePlace(center: Self.berlin, components: nil), from: since, date: now))
        let munichOnTrips = Set(picked.trips.flatMap(\.geotaggedAssetIDs)).intersection(munich).count
        #expect(munichOnTrips == 0)
    }

    /// Munich was confirmed earlier ("Stimmt" in 2025); after the move the user picks Berlin
    /// under "Ändern" with the proposed date. The confirmed years in Munich stay everyday life:
    /// before the date the detection decides, as for every confirmation.
    @Test func confirmedEarlierThenPickedTheNewTownKeepsTheConfirmedYears() throws {
        var lib = LibraryBuilder()
        let munich = lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let confirmed = HomeSettings().confirming(HomePlace(center: Fixture.Places.munichHome, components: nil), date: Fixture.date("2025-03-01"))
        let since = try #require(HomeCandidates.stayStart(near: Self.berlin, assets: lib.assets, calendar: Fixture.calendar))
        let picked = confirmed.choosing(HomePlace(center: Self.berlin, components: nil), from: since, date: Fixture.date("2026-11-16"))
        #expect(picked.home(at: Fixture.date("2025-06-01")) == .detected)
        #expect(picked.home(at: Fixture.date("2026-10-01")) == .chosen(HomePlace(center: Self.berlin, components: nil)))
        let analysis = detector.analyse(in: lib.assets, home: picked)
        #expect(Set(analysis.trips.flatMap(\.geotaggedAssetIDs)).isDisjoint(with: munich))
        #expect(analysis.trips.isEmpty)
    }

    /// "Seit wann wohnst du dort?" is proposed from the photos: the first day of the latest stay
    /// near the place. Trips of one or ten days do not end a stay; years elsewhere do.
    @Test func theStayStartsAfterTheLastLongStretchElsewhere() throws {
        var lib = LibraryBuilder()
        let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
        lib.daily(from: "2015-01-01", to: "2018-12-31", at: hamburg, perDay: 1, hour: 19)
        lib.daily(from: "2019-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 1, hour: 19,
                  skipping: [("2024-05-10", "2024-05-16"), ("2025-08-01", "2025-08-10")])
        lib.daily(from: "2024-05-10", to: "2024-05-16", at: Fixture.Places.rome, perDay: 5, hour: 10)
        lib.daily(from: "2025-08-01", to: "2025-08-10", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        #expect(HomeCandidates.stayStart(near: Fixture.Places.munichHome, assets: lib.assets, calendar: Fixture.calendar) == Fixture.date("2019-01-01"))
        #expect(HomeCandidates.stayStart(near: hamburg, assets: lib.assets, calendar: Fixture.calendar) == Fixture.date("2015-01-01"))
        #expect(HomeCandidates.stayStart(near: Fixture.Places.sydney, assets: lib.assets, calendar: Fixture.calendar) == nil)
    }
}

/// The stay starts after the latest stretch of 28 photo days of which more than half are
/// elsewhere (`HomeCandidates.moveStretchDays`, `moveShareElsewhere`, round 4); days without
/// photos are not counted. A later date than the move is harmless: before it the detection
/// decides, so the trips stay as they were.
@Suite("Stay start: visits before a move, holidays, sparse photos")
struct StayStartTests {
    static let berlin = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
    static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let cologne = GeoCoordinate(latitude: 50.9375, longitude: 6.9603)
    static let london = GeoCoordinate(latitude: 51.5072, longitude: -0.1276)
    let now = Fixture.date("2026-11-16")
    let detector = TripDetector(calendar: Fixture.calendar)

    func start(_ lib: LibraryBuilder, _ center: GeoCoordinate) -> Date? {
        HomeCandidates.stayStart(near: center, assets: lib.assets, calendar: Fixture.calendar)
    }

    func picking(_ center: GeoCoordinate, from since: Date?) -> HomeSettings {
        HomeSettings().choosing(HomePlace(center: center, components: nil), from: since, date: now)
    }

    func onTrips(_ analysis: TripAnalysis, _ ids: [AssetID]) -> Int {
        Set(analysis.trips.flatMap(\.geotaggedAssetIDs)).intersection(ids).count
    }

    /// Lived in Munich, visited the partner in Berlin every two or three weeks for 2.5 years,
    /// moved to Berlin on 1.9.2026 and picks it under "Ändern" with the proposed date: the
    /// visits do not pull the date back, and the Munich years stay everyday life.
    @Test(arguments: [14, 21])
    func visitsBeforeTheMoveDoNotPullTheStayStartBack(everyNthDay: Int) throws {
        var lib = LibraryBuilder()
        let munich = lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        lib.daily(from: "2024-01-06", to: "2026-08-29", at: Self.berlin, perDay: 6, everyNthDay: everyNthDay, hour: 11)
        lib.daily(from: "2024-01-07", to: "2026-08-30", at: Self.berlin, perDay: 6, everyNthDay: everyNthDay, hour: 11)
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 2, hour: 19)
        let since = try #require(start(lib, Self.berlin))
        #expect(since == Fixture.date("2026-09-01"))
        #expect(onTrips(detector.analyse(in: lib.assets, home: picking(Self.berlin, from: since)), munich) == 0)
    }

    /// Berlin every Saturday and Sunday since 2024 (two of seven photo days, no Munich photos
    /// on them), moved there on 1.9.2026: the date is the move, no Munich photo becomes a trip.
    @Test func weekendVisitsEveryWeekBeforeTheMoveDoNotPullTheStayStartBack() throws {
        var lib = LibraryBuilder()
        let calendar = Fixture.calendar
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        var weekends: [(String, String)] = []
        var day = Fixture.date("2024-01-06")
        while day < Fixture.date("2026-08-31") {
            weekends.append((format.string(from: day), format.string(from: calendar.date(byAdding: .day, value: 1, to: day)!)))
            day = calendar.date(byAdding: .day, value: 7, to: day)!
        }
        let munich = lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19, skipping: weekends)
        for weekend in weekends { lib.daily(from: weekend.0, to: weekend.1, at: Self.berlin, perDay: 4, hour: 11) }
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 2, hour: 19)
        let since = try #require(start(lib, Self.berlin))
        #expect(since == Fixture.date("2026-09-01"))
        #expect(onTrips(detector.analyse(in: lib.assets, home: picking(Self.berlin, from: since)), munich) == 0)
    }

    /// A trip of two days in the second week after the move does not push the date past it.
    @Test func aShortTripAfterTheMoveKeepsTheDateOfTheMove() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 3, hour: 19, skipping: [("2026-09-08", "2026-09-09")])
        lib.daily(from: "2026-09-08", to: "2026-09-09", at: Fixture.Places.rome, perDay: 10, hour: 10)
        #expect(start(lib, Self.berlin) == Fixture.date("2026-09-01"))
    }

    /// Works in London one week each month (a quarter of the photo days), lives in Munich since
    /// 2019: the stay goes back to 2019.
    @Test func aWeekAbroadEachMonthKeepsTheStay() {
        var lib = LibraryBuilder()
        var weeks: [(String, String)] = []
        for y in 2019...2026 {
            for m in 1...12 where !(y == 2026 && m > 10) {
                weeks.append((String(format: "%04d-%02d-08", y, m), String(format: "%04d-%02d-14", y, m)))
            }
        }
        lib.daily(from: "2019-01-01", to: "2026-11-10", at: Fixture.Places.munichHome, perDay: 2, hour: 19, skipping: weeks)
        for week in weeks { lib.daily(from: week.0, to: week.1, at: Self.london, perDay: 2, hour: 12) }
        #expect(start(lib, Fixture.Places.munichHome) == Fixture.date("2019-01-01"))
    }

    /// A holiday of three or six weeks with photos every day ends the proposed stay: the date is
    /// after it, and the trips are the same as without a choice.
    @Test(arguments: [("2025-07-01", "2025-07-21", "2025-07-22"), ("2025-07-01", "2025-08-15", "2025-08-16")])
    func aLongHolidayEndsTheProposedStayButChangesNoTrip(holiday: (String, String, String)) throws {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2019-01-01", to: "2026-11-10", at: Fixture.Places.munichHome, perDay: 2, hour: 19,
                             skipping: [(holiday.0, holiday.1)])
        lib.daily(from: holiday.0, to: holiday.1, at: Fixture.Places.sydney, perDay: 5, hour: 10)
        let since = try #require(start(lib, Fixture.Places.munichHome))
        #expect(since == Fixture.date(holiday.2))
        let picked = detector.analyse(in: lib.assets, home: picking(Fixture.Places.munichHome, from: since))
        let automatic = detector.analyse(in: lib.assets)
        #expect(onTrips(picked, home) == 0)
        #expect(picked.trips.map(\.allAssetIDs) == automatic.trips.map(\.allAssetIDs))
    }

    /// Photos at home once a week, none for seven weeks in the summer around two trips (15 photo
    /// days elsewhere in a row): the proposed date is after the trips, and nothing changes.
    @Test func sparsePhotosAtHomeWithTripsChangeNoTrip() throws {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2019-01-01", to: "2026-11-10", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 7, hour: 19,
                             skipping: [("2025-06-25", "2025-08-12")])
        lib.daily(from: "2025-07-01", to: "2025-07-12", at: Fixture.Places.rome, perDay: 10, hour: 10)
        lib.daily(from: "2025-08-02", to: "2025-08-04", at: Fixture.Places.gardaLake, perDay: 10, hour: 10)
        let since = try #require(start(lib, Fixture.Places.munichHome))
        #expect(since > Fixture.date("2025-08-04"))
        let picked = detector.analyse(in: lib.assets, home: picking(Fixture.Places.munichHome, from: since))
        let automatic = detector.analyse(in: lib.assets)
        #expect(onTrips(picked, home) == 0)
        #expect(picked.trips.map(\.allAssetIDs) == automatic.trips.map(\.allAssetIDs))
    }

    /// Few photos, mostly on trips (one day at home a month, three trips of ten days a year):
    /// from the proposed date the home photos are on no more trips than with the home for all
    /// time.
    @Test func fewPhotosMostlyOnTripsPutNoHomePhotoOnATrip() {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2019-01-15", to: "2026-11-10", at: Fixture.Places.munichHome, perDay: 3, everyNthDay: 30, hour: 19)
        for y in 2019...2026 {
            lib.daily(from: "\(y)-03-01", to: "\(y)-03-10", at: Fixture.Places.rome, perDay: 10, hour: 10)
            lib.daily(from: "\(y)-06-01", to: "\(y)-06-10", at: Fixture.Places.gardaLake, perDay: 10, hour: 10)
            lib.daily(from: "\(y)-09-01", to: "\(y)-09-10", at: Self.london, perDay: 10, hour: 10)
        }
        let since = start(lib, Fixture.Places.munichHome)
        let picked = detector.analyse(in: lib.assets, home: picking(Fixture.Places.munichHome, from: since))
        let forAllTime = detector.analyse(in: lib.assets, home: picking(Fixture.Places.munichHome, from: nil))
        #expect(onTrips(picked, home) == onTrips(forAllTime, home))
    }

    /// Moved twice (Cologne, Hamburg, Munich since 2025), or back to Munich after years in
    /// Hamburg: the stay starts at the last move.
    @Test func movingTwiceOrBackStartsTheStayAtTheLastMove() {
        var twice = LibraryBuilder()
        twice.daily(from: "2015-01-01", to: "2018-12-31", at: Self.cologne, perDay: 2, hour: 19)
        twice.daily(from: "2019-01-01", to: "2024-12-31", at: Self.hamburg, perDay: 2, hour: 19)
        twice.daily(from: "2025-01-01", to: "2026-11-10", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        #expect(start(twice, Fixture.Places.munichHome) == Fixture.date("2025-01-01"))
        var back = LibraryBuilder()
        back.daily(from: "2015-01-01", to: "2018-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        back.daily(from: "2019-01-01", to: "2024-12-31", at: Self.hamburg, perDay: 2, hour: 19)
        back.daily(from: "2025-01-01", to: "2026-11-10", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        #expect(start(back, Fixture.Places.munichHome) == Fixture.date("2025-01-01"))
    }

    /// Fewer than 28 photo days in all: no stretch can be found, the stay starts on the first
    /// day near the place.
    @Test func withFewerThan28PhotoDaysTheStayStartsOnTheFirstDayThere() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-01-10", at: Self.hamburg, perDay: 1, hour: 19)
        lib.daily(from: "2026-10-01", to: "2026-10-05", at: Fixture.Places.munichHome, perDay: 1, hour: 19)
        #expect(start(lib, Fixture.Places.munichHome) == Fixture.date("2026-10-01"))
    }
}
