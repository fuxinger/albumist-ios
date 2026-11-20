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
