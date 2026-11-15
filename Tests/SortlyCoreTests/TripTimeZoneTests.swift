import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Trips on a device in Germany (coverage map A17): photos are absolute instants, days are
/// counted on the device's calendar (Europe/Berlin, not UTC), a trip abroad in its own time zone.
@Suite("Trips in local time")
struct TripTimeZoneTests {
    static let berlin: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()
    let detector = TripDetector(calendar: TripTimeZoneTests.berlin)

    /// "2026-03-29 03:15" on the wall clock in `zone`.
    static func local(_ string: String, _ zone: String = "Europe/Berlin") -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)!
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = f.date(from: string) else { fatalError("no such local time \(string) in \(zone)") }
        return date
    }

    /// Everyday life in Munich: photos at 19:00 and 21:00 Berlin time from `from` to `to`,
    /// except on `away` days.
    static func everyday(_ lib: inout LibraryBuilder, from: String, to: String, except away: Set<String>) {
        var day = local(from + " 12:00")
        let end = local(to + " 12:00")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = berlin.timeZone
        f.dateFormat = "yyyy-MM-dd"
        while day <= end {
            let name = f.string(from: day)
            if !away.contains(name) {
                _ = lib.photo(at: local(name + " 19:00"), LifePatterns.Places.munich)
                _ = lib.photo(at: local(name + " 21:00"), LifePatterns.Places.munich)
            }
            day = berlin.date(byAdding: .day, value: 1, to: day)!
        }
    }

    /// Photos at the wall-clock times `times` in `zone`.
    static func photos(_ lib: inout LibraryBuilder, at place: GeoCoordinate, _ times: [String], zone: String = "Europe/Berlin") -> [AssetID] {
        times.map { lib.photo(at: local($0, zone), place) }
    }

    func titles(_ lib: LibraryBuilder, trips: [Trip]) -> [String] {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        var tripOf: [AssetID: SortlyID] = [:]
        for trip in trips { for id in trip.geotaggedAssetIDs { tripOf[id] = trip.id } }
        let facts = LifePatterns.facts(for: lib.assets).map { f -> AssetFacts in
            var f = f
            f.tripID = tripOf[f.id]
            return f
        }
        return ProposalEngine(settings: settings, calendar: Self.berlin)
            .proposals(for: AnalysisSnapshot(facts: facts, trips: trips)).filter { $0.kind == .trip }.map(\.title)
    }

    func dayCounts(_ trip: Trip, _ lib: LibraryBuilder, calendar: Calendar = TripTimeZoneTests.berlin) -> [Int] {
        let dates = Dictionary(uniqueKeysWithValues: lib.assets.compactMap { a in a.creationDate.map { (a.id, $0) } })
        return TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: dates, calendar: calendar).map(\.count)
    }

    /// Clocks go forward in the night to Sunday 29 March 2026 (02:00 → 03:00): a weekend at
    /// Lake Garda keeps its three days, the photo half an hour after midnight is Sunday's.
    @Test func weekendAcrossTheSpringClockChange() throws {
        var lib = LibraryBuilder()
        Self.everyday(&lib, from: "2026-03-01", to: "2026-04-30", except: ["2026-03-27", "2026-03-28", "2026-03-29"])
        let away = Self.photos(&lib, at: LifePatterns.Places.garda, [
            "2026-03-27 09:00", "2026-03-27 13:00", "2026-03-27 20:00", "2026-03-27 23:30",
            "2026-03-28 09:00", "2026-03-28 13:00", "2026-03-28 20:00", "2026-03-28 23:30",
            "2026-03-29 00:30", "2026-03-29 03:15", "2026-03-29 09:00", "2026-03-29 13:00", "2026-03-29 20:00",
        ])
        let trips = detector.detect(in: lib.assets)
        let trip = try #require(trips.first)
        #expect(trips.count == 1)
        #expect(Set(trip.geotaggedAssetIDs) == Set(away))
        #expect(trip.start == Self.local("2026-03-27 09:00") && trip.end == Self.local("2026-03-29 20:00"))
        #expect(trip.kind == .weekendTrip)
        #expect(dayCounts(trip, lib) == [4, 4, 5])
        // In UTC the Sunday photo at 00:30 would belong to Saturday.
        #expect(dayCounts(trip, lib, calendar: Fixture.calendar) == [4, 5, 4])
        #expect(titles(lib, trips: trips) == ["Malcesine, März 2026"])
    }

    /// Clocks go back in the night to Sunday 25 October 2026 (03:00 → 02:00): 02:30 happens
    /// twice. Both photos are Sunday's, an hour apart, and the weekend keeps its three days.
    @Test func weekendAcrossTheAutumnClockChange() throws {
        var lib = LibraryBuilder()
        Self.everyday(&lib, from: "2026-10-01", to: "2026-11-30", except: ["2026-10-23", "2026-10-24", "2026-10-25"])
        var away = Self.photos(&lib, at: LifePatterns.Places.garda, [
            "2026-10-23 09:00", "2026-10-23 13:00", "2026-10-23 20:00", "2026-10-24 09:00", "2026-10-24 13:00", "2026-10-24 20:00", "2026-10-24 23:45",
        ])
        let first = lib.photo(at: Fixture.date("2026-10-25 00:30"), LifePatterns.Places.garda)   // 02:30 summer time
        let second = lib.photo(at: Fixture.date("2026-10-25 01:30"), LifePatterns.Places.garda)  // 02:30 winter time
        away += [first, second] + Self.photos(&lib, at: LifePatterns.Places.garda, ["2026-10-25 10:00", "2026-10-25 18:00"])
        let trips = detector.detect(in: lib.assets)
        let trip = try #require(trips.first)
        #expect(trips.count == 1)
        #expect(trip.geotaggedAssetIDs == away)
        #expect(trip.start == Self.local("2026-10-23 09:00") && trip.end == Self.local("2026-10-25 18:00"))
        #expect(trip.kind == .weekendTrip)
        #expect(dayCounts(trip, lib) == [3, 4, 4])
        let wallClock = Self.berlin.dateComponents([.day, .hour, .minute], from: Fixture.date("2026-10-25 00:30"))
        #expect(wallClock == Self.berlin.dateComponents([.day, .hour, .minute], from: Fixture.date("2026-10-25 01:30")))
        #expect(titles(lib, trips: trips) == ["Malcesine, Oktober 2026"])
    }

    /// A concert in Salzburg that ends after midnight is still a day trip.
    @Test func dayTripPastMidnightIsStillADayTrip() throws {
        var lib = LibraryBuilder()
        Self.everyday(&lib, from: "2026-06-01", to: "2026-07-31", except: ["2026-07-11"])
        let away = Self.photos(&lib, at: LifePatterns.Places.salzburg, [
            "2026-07-11 15:00", "2026-07-11 16:00", "2026-07-11 17:00", "2026-07-11 18:00", "2026-07-11 19:00", "2026-07-11 21:00",
            "2026-07-11 22:30", "2026-07-11 23:15",
            "2026-07-12 00:10", "2026-07-12 00:40",
        ])
        let trips = detector.detect(in: lib.assets)
        let trip = try #require(trips.first)
        #expect(trips.count == 1 && Set(trip.geotaggedAssetIDs) == Set(away))
        #expect(trip.kind == .dayTrip)
        #expect(dayCounts(trip, lib) == [8, 2])   // the workshop still shows both calendar days
        #expect(titles(lib, trips: trips) == ["Salzburg, Juli 2026"])
    }

    /// A sunrise hike that starts at 01:30 is a day trip in Germany. On a UTC calendar the
    /// first photo would be Friday's and the hike a two-day trip.
    @Test func dayTripStartingAtNightUsesTheDeviceCalendar() throws {
        var lib = LibraryBuilder()
        Self.everyday(&lib, from: "2026-08-01", to: "2026-08-31", except: ["2026-08-15"])
        _ = Self.photos(&lib, at: LifePatterns.Places.garmisch, [
            "2026-08-15 01:30", "2026-08-15 04:00", "2026-08-15 06:10", "2026-08-15 08:00", "2026-08-15 11:00", "2026-08-15 14:00",
        ])
        let trip = try #require(detector.detect(in: lib.assets).first)
        #expect(trip.kind == .dayTrip)
        #expect(TripDetector(calendar: Fixture.calendar).detect(in: lib.assets).first?.kind == .weekendTrip)
    }

    /// Munich → New York → Tokyo, every photo stamped in local time: one trip from the first
    /// photo in New York to the last one in Tokyo, eight days on the device's calendar.
    @Test func tripAcrossSeveralTimeZones() throws {
        var lib = LibraryBuilder()
        let days = (4...11).map { String(format: "2026-05-%02d", $0) }
        Self.everyday(&lib, from: "2026-04-01", to: "2026-06-30", except: Set(days))
        let newYork = Self.photos(&lib, at: LifePatterns.Places.newYork, ["04", "05", "06"].flatMap { d in
            ["10:00", "14:00", "18:00", "22:00"].map { "2026-05-\(d) \($0)" }
        }, zone: "America/New_York")
        let tokyo = Self.photos(&lib, at: LifePatterns.Places.tokyo, ["08", "09", "10", "11"].flatMap { d in
            ["09:00", "13:00", "17:00", "21:00"].map { "2026-05-\(d) \($0)" }
        }, zone: "Asia/Tokyo")
        let trips = detector.detect(in: lib.assets)
        let trip = try #require(trips.first)
        #expect(trips.count == 1)
        #expect(trip.geotaggedAssetIDs == newYork + tokyo)
        #expect(trip.start == Self.local("2026-05-04 10:00", "America/New_York"))
        #expect(trip.end == Self.local("2026-05-11 21:00", "Asia/Tokyo"))
        #expect(trip.kind == .vacation)
        #expect(dayCounts(trip, lib) == [2, 4, 4, 2, 4, 4, 4, 4])
        // Counted in the destination's time (Tokyo holds most photos) it stays a holiday.
        let zones = Dictionary(uniqueKeysWithValues: newYork.map { ($0, "America/New_York") } + tokyo.map { ($0, "Asia/Tokyo") })
        let local = TripDetector.inDestinationTime(trips, assets: Dictionary(uniqueKeysWithValues: lib.assets.map { ($0.id, $0) }),
                                                   timeZones: zones, calendar: Self.berlin)
        #expect(local.first?.kind == .vacation)
        #expect(titles(lib, trips: trips) == ["Tokio & New York, Mai 2026"])
    }

    /// The family pattern in German local time: same trips, same question as in UTC.
    @Test func recurringVisitsInLocalTime() throws {
        var lib = LibraryBuilder()
        var away: Set<String> = []
        var visits: [[AssetID]] = []
        var start = Self.local("2025-01-10 12:00")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Self.berlin.timeZone
        f.dateFormat = "yyyy-MM-dd"
        for _ in 0..<12 {
            let names = (0..<3).map { f.string(from: Self.berlin.date(byAdding: .day, value: $0, to: start)!) }
            away.formUnion(names)
            visits.append(Self.photos(&lib, at: LifePatterns.Places.hamburg, names.flatMap { d in ["09:30", "13:00", "17:30", "22:45"].map { "\(d) \($0)" } }))
            start = Self.berlin.date(byAdding: .day, value: 28, to: start)!
        }
        Self.everyday(&lib, from: "2025-01-01", to: "2025-12-31", except: away)
        let analysis = detector.analyse(in: lib.assets)
        #expect(Set(analysis.trips.map { Set($0.geotaggedAssetIDs) }) == Set(visits.map(Set.init)))
        let report = RecurringPlaceReport(analysis, trips: analysis.trips, answers: .init())
        let question = try #require(report.candidates.first)
        #expect(question.stayCount == 12)
        let yes = RecurringPlaceAnswers().answering(true, at: question.center, name: "Hamburg", date: Self.local("2026-01-01 12:00"))
        let after = detector.analyse(in: lib.assets, places: yes)
        #expect(after.trips.isEmpty)
        #expect(Set(after.places.first?.assetIDs ?? []) == Set(visits.joined()))
    }
}

/// Most people take no photo at home on the evening they come back. Two outings with nothing
/// in between are still two (simulated library of the proposals work, 15.11.).
@Suite("Back home without a photo")
struct UnseenReturnTests {
    let detector = TripDetector(calendar: Fixture.calendar)
    typealias P = LifePatterns.Places

    /// Everyday photos in Munich in 2025 except on the given days.
    func library(_ stays: [LifePatterns.Stay]) -> (LibraryBuilder, [[AssetID]]) {
        var lib = LibraryBuilder()
        let ids = LifePatterns.life(from: "2025-01-01", to: "2025-12-31", stays: stays, into: &lib)
        return (lib, ids)
    }

    func trips(_ lib: LibraryBuilder) -> [Set<AssetID>] {
        detector.detect(in: lib.assets).map { Set($0.geotaggedAssetIDs) }
    }

    /// Parents in Augsburg on Saturday, the Tegernsee on Sunday: two day trips, not a weekend
    /// trip (home lies on the way between them).
    @Test func saturdayAtTheParentsSundayAtTheLake() {
        let (lib, stays) = library([
            .init(start: "2025-06-14", days: 1, place: P.augsburg, perDay: 6, hour: 12),
            .init(start: "2025-06-15", days: 1, place: P.tegernsee, perDay: 10, hour: 10),
        ])
        #expect(trips(lib) == stays.map(Set.init))
    }

    /// A day in Innsbruck two days after coming back from Sardinia (a day without photos in
    /// between) is its own day trip.
    @Test func dayTripAfterAHolidayWithADayWithoutPhotos() {
        let (lib, stays) = library([
            .init(start: "2025-08-05", days: 10, place: P.cagliari, perDay: 12, hour: 9),
            .init(start: "2025-08-15", days: 1, place: P.innsbruck, perDay: 0),     // no photos at all that day
            .init(start: "2025-08-16", days: 1, place: P.innsbruck, perDay: 15, hour: 9),
        ])
        #expect(trips(lib) == [Set(stays[0]), Set(stays[2])])
    }

    /// Vienna over New Year, then the parents in Augsburg two days later.
    @Test func visitAfterACityTrip() {
        let (lib, stays) = library([
            .init(start: "2025-03-01", days: 5, place: P.vienna, perDay: 12, hour: 9),
            .init(start: "2025-03-06", days: 1, place: P.augsburg, perDay: 0),
            .init(start: "2025-03-07", days: 1, place: P.augsburg, perDay: 6, hour: 12),
        ])
        #expect(trips(lib) == [Set(stays[0]), Set(stays[2])])
    }

    /// Garmisch on Saturday, Innsbruck on Sunday: home is not on the way, one weekend trip.
    @Test func weekendWithTwoStopsStaysOneTrip() {
        let (lib, stays) = library([
            .init(start: "2025-06-14", days: 1, place: P.garmisch, perDay: 8, hour: 10),
            .init(start: "2025-06-15", days: 1, place: P.innsbruck, perDay: 8, hour: 10),
        ])
        #expect(trips(lib) == [Set(stays.joined())])
    }

    /// A day without photos in the middle of a holiday far away splits nothing, at another
    /// town of the island or at the same ski resort.
    @Test func dayWithoutPhotosDuringAHolidayAway() {
        let (lib, stays) = library([
            .init(start: "2025-08-05", days: 5, place: P.cagliari, perDay: 12, hour: 9),
            .init(start: "2025-08-10", days: 1, place: P.cagliari, perDay: 0),
            .init(start: "2025-08-11", days: 4, place: P.alghero, perDay: 12, hour: 9),
            .init(start: "2025-02-08", days: 3, place: P.soelden, perDay: 10, hour: 9),
            .init(start: "2025-02-11", days: 1, place: P.soelden, perDay: 0),
            .init(start: "2025-02-12", days: 3, place: P.soelden, perDay: 10, hour: 9),
        ])
        let sardinia: Set<AssetID> = Set(stays[0]).union(stays[2])
        let ski: Set<AssetID> = Set(stays[3]).union(stays[5])
        #expect(Set(trips(lib)) == [sardinia, ski])
    }
}
