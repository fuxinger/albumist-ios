import Foundation
import Testing
import SortlyCore
@testable import SortlyMap

/// The map's shared types: local days, the derived trip numbers, stored form.
@Suite("Map model")
struct MapModelTests {
    @Test func localDayFollowsThePlacesTimeZone() throws {
        // 23:30 UTC on 14 June is already 15 June in Tokyo and still 14 June in Reykjavík.
        let date = MapFixture.date("2023-06-14 23:30")
        #expect(LocalDay(date, timeZone: TimeZone(identifier: "Asia/Tokyo")!) == LocalDay(year: 2023, month: 6, day: 15))
        #expect(LocalDay(date, timeZone: TimeZone(identifier: "Atlantic/Reykjavik")!) == LocalDay(year: 2023, month: 6, day: 14))
        let place = PlaceComponents(isoCountryCode: "JP", timeZoneIdentifier: "Asia/Tokyo")
        #expect(LocalDay(date, place: place, fallback: MapFixture.utc) == LocalDay(year: 2023, month: 6, day: 15))
        #expect(LocalDay(date, place: nil, fallback: MapFixture.utc) == LocalDay(year: 2023, month: 6, day: 14))
        #expect(LocalDay(year: 2023, month: 6, day: 14).days(to: LocalDay(year: 2023, month: 6, day: 22)) == 8)
        #expect(LocalDay(year: 2023, month: 12, day: 31).days(to: LocalDay(year: 2024, month: 1, day: 1)) == 1)
        #expect(LocalDay(year: 2023, month: 6, day: 14) < LocalDay(year: 2023, month: 6, day: 15))
        #expect(LocalDay(year: 2024, month: 2, day: 9).description == "2024-02-09")
    }

    /// The day arithmetic gives what the Gregorian calendar gives: in zones with half and
    /// quarter hours, across the date line, through summer time changes, and the day Samoa
    /// skipped (30 December 2011).
    @Test func localDayIsTheGregorianCalendarsDay() throws {
        let zones = ["UTC", "Europe/Berlin", "Atlantic/Reykjavik", "America/St_Johns", "America/Los_Angeles", "Asia/Kathmandu",
                     "Australia/Lord_Howe", "Pacific/Apia", "Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Tokyo"]
        var random = MapRandom(seed: 11)
        let from = MapFixture.date("1901-01-01").timeIntervalSince1970, to = MapFixture.date("2099-12-31").timeIntervalSince1970
        var dates = (0..<400).map { _ in Date(timeIntervalSince1970: from + random.unit() * (to - from)) }
        dates += ["2011-12-29 09:59", "2011-12-29 10:00", "2011-12-30 12:00", "2024-02-29 12:00", "2000-02-29 23:59",
                  "1970-01-01 00:00", "1969-12-31 23:59", "2026-03-29 00:59", "2026-03-29 01:00", "2026-10-25 01:00"].map(MapFixture.date)
        for identifier in zones {
            let zone = try #require(TimeZone(identifier: identifier))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for date in dates {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                #expect(LocalDay(date, timeZone: zone) == LocalDay(year: parts.year!, month: parts.month!, day: parts.day!), "\(identifier) \(date)")
            }
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = MapFixture.utc
        for _ in 0..<300 {
            let a = Date(timeIntervalSince1970: from + random.unit() * (to - from)), b = Date(timeIntervalSince1970: from + random.unit() * (to - from))
            let expected = utc.dateComponents([.day], from: utc.startOfDay(for: a), to: utc.startOfDay(for: b)).day!
            #expect(LocalDay(a, timeZone: MapFixture.utc).days(to: LocalDay(b, timeZone: MapFixture.utc)) == expected)
        }
        // A month or day out of range carries over as the calendar does.
        #expect(LocalDay(year: 2023, month: 12, day: 31).days(to: LocalDay(year: 2023, month: 13, day: 1)) == 1)
        #expect(LocalDay(year: 2023, month: 3, day: 0).days(to: LocalDay(year: 2023, month: 2, day: 28)) == 0)
        #expect(LocalDay(year: 2024, month: 0, day: 31).days(to: LocalDay(year: 2023, month: 12, day: 31)) == 0)
        // Samoa went from 29 to 31 December 2011.
        let apia = try #require(TimeZone(identifier: "Pacific/Apia"))
        #expect(LocalDay(MapFixture.date("2011-12-30 10:00"), timeZone: apia) == LocalDay(year: 2011, month: 12, day: 31))
        // No date a calendar could show.
        #expect(LocalDay(Date(timeIntervalSince1970: .nan), timeZone: apia) == LocalDay(year: 1970, month: 1, day: 1))
        #expect(LocalDay(Date(timeIntervalSince1970: 1e300), timeZone: apia) == LocalDay(year: 1970, month: 1, day: 1))
    }

    @Test func tripGeometryDerivesDaysOnSiteAndRoute() throws {
        let places = [
            TripPlace(coordinate: MapFixture.Places.reykjavik, name: "Reykjavík", countryKey: "IS", photoCount: 40,
                      days: [LocalDay(year: 2023, month: 6, day: 14)], coverCandidates: []),
            TripPlace(coordinate: MapFixture.Places.vik, name: "Vík", countryKey: "IS", photoCount: 12,
                      days: [LocalDay(year: 2023, month: 6, day: 16)], coverCandidates: []),
        ]
        let geometry = TripGeometry(
            id: SortlyID("iceland"), start: MapFixture.date("2023-06-14 10:00"), end: MapFixture.date("2023-06-22 18:00"),
            timeZoneIdentifier: "Atlantic/Reykjavik", firstDay: LocalDay(year: 2023, month: 6, day: 14), lastDay: LocalDay(year: 2023, month: 6, day: 22),
            photoCount: 52, dayPlaces: [],
            places: places,
            route: [RoutePoint(placeIndex: 0, arrival: MapFixture.date("2023-06-14 10:00"), departure: MapFixture.date("2023-06-14 18:00"),
                               day: LocalDay(year: 2023, month: 6, day: 14)),
                    RoutePoint(placeIndex: 1, arrival: MapFixture.date("2023-06-16 10:00"), departure: MapFixture.date("2023-06-16 18:00"),
                               day: LocalDay(year: 2023, month: 6, day: 16))],
            legs: [RouteLeg(meters: 140_000, withoutPhotos: true)], destinationIndex: 0, destination: MapFixture.Places.reykjavik,
            countryPhotos: ["IS": 52], mainCountryKey: "IS", airborneCount: 0)
        #expect(geometry.days == 9)
        #expect(geometry.metersOnSite == 140_000)
        #expect(geometry.routeCoordinates == [MapFixture.Places.reykjavik, MapFixture.Places.vik])
        #expect(geometry.destinationName == "Reykjavík")
    }

    @Test func summaryRoundTripsThroughItsStoredForm() throws {
        let summary = MapSummary(computedAt: MapFixture.date("2026-11-20"), home: RoundedHome(coordinate: MapFixture.at(49.0, 12.1), countryCode: "DE"),
                                 trips: [], countries: [], arcs: [], pins: [],
                                 numbers: WorldNumbers(earth: .aroundTheEarth(times: 2.2), year: 2026), years: [], focus: nil)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(MapSummary.self, from: data)
        #expect(decoded == summary)
        #expect(decoded.formatVersion == MapSummary.formatVersion)
    }
}
