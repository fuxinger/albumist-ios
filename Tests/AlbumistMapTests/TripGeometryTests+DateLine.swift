import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Trips across the antimeridian, the date line and near the pole: the route the short way round,
/// a photo's day by the clock where it was taken, places numbered in time order, Svalbard and the
/// North Pole.
extension TripGeometryTests {
    // MARK: Across the antimeridian, the date line and near the pole

    @Test func aTripAcrossTheAntimeridian() throws {
        // Suva (Fiji) and Apia (Samoa): about 1,150 km, not 39,000 km round the other way.
        let fijiSamoa = MapFixture.burst("suva", count: 5, at: Places.suva, day: "2023-09-10", hour: 1, country: "FJ", town: "Suva",
                                         timeZone: "Pacific/Fiji")
            + MapFixture.burst("apia", count: 5, at: Places.apia, day: "2023-09-11", hour: 3, country: "WS", town: "Apia", timeZone: "Pacific/Apia")
        let geometry = Self.build(fijiSamoa)
        #expect(geometry.places.map(\.name) == ["Suva", "Apia"])
        #expect(geometry.legs.count == 1)
        #expect(abs(geometry.legs[0].meters - 1_150_000) < 25_000)
        #expect(geometry.legs[0].withoutPhotos)
        // As many photos in Fiji as in Samoa: the smaller key; the zone too.
        #expect(geometry.countryPhotos == ["FJ": 5, "WS": 5])
        #expect(geometry.mainCountryKey == "FJ")
        #expect(geometry.timeZoneIdentifier == "Pacific/Apia")
        #expect(geometry.destinationIndex == 0)

        // A day on Taveuni with photos on both sides of 180°, 600 m apart: one place.
        let taveuni = (0..<6).map { i in
            MapFixture.photo("taveuni-\(i)", at: MapFixture.date("2023-09-12 22:00").addingTimeInterval(Double(i) * 600),
                             MapFixture.at(-16.85, i % 2 == 0 ? 179.997 : -179.997), country: "FJ", town: "Somosomo", timeZone: "Pacific/Fiji")
        }
        let island = Self.build(taveuni)
        #expect(island.dayPlaces.count == 1 && island.places.count == 1)
        #expect(taveuni.contains { $0.asset.location == island.places[0].coordinate })
    }

    @Test func aPhotoAtHalfPastElevenUTCInTokyoCountsOnTheNextDay() throws {
        // 23:00 to 23:30 UTC on the 14th is 08:00 to 08:30 on the 15th in Tokyo; the device is on UTC.
        let tokyo = MapFixture.burst("tokyo", count: 4, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo",
                                     timeZone: "Asia/Tokyo")
        let unlocated = MapFixture.photo("no-place", at: MapFixture.date("2023-06-14 23:30"), nil)
        let geometry = Self.build(tokyo + [unlocated], timeZone: MapFixture.utc)
        #expect(geometry.timeZoneIdentifier == "Asia/Tokyo")
        // The photo without a place counts in the trip's zone, not the device's: the trip has one
        // day. Photos per day are those on the map.
        #expect(geometry.firstDay == Self.day("2023-06-15") && geometry.lastDay == Self.day("2023-06-15"))
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.dayPlaces.map(\.day) == [Self.day("2023-06-15")])
        #expect(geometry.route.map(\.day) == [Self.day("2023-06-15")])
    }

    /// A photo's day is the day on the clock where it was taken, as the app's albums count it
    /// (`AssetFacts.timeZone`, review P1-15): it wins over its place's zone and the trip's.
    @Test func theClockWhereAPhotoWasTakenDecidesItsDay() throws {
        // Offline places name no zone; the analysis gave each photo Tokyo's clock from its country.
        let tokyo = MapFixture.burst("tokyo", count: 4, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo")
            .map { fact -> AssetFacts in var fact = fact; fact.timeZone = TimeZone(identifier: "Asia/Tokyo"); return fact }
        var unlocated = MapFixture.photo("no-place", at: MapFixture.date("2023-06-14 23:30"), nil)
        unlocated.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let geometry = Self.build(tokyo + [unlocated], timeZone: MapFixture.utc)
        #expect(geometry.timeZoneIdentifier == "Asia/Tokyo")
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.firstDay == Self.day("2023-06-15") && geometry.lastDay == Self.day("2023-06-15"))
        #expect(geometry.dayPlaces.map(\.day) == [Self.day("2023-06-15")])
        // The clock wins over a place's zone that says otherwise.
        let mixed = MapFixture.burst("utc", count: 3, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo",
                                     timeZone: "UTC")
            .map { fact -> AssetFacts in var fact = fact; fact.timeZone = TimeZone(identifier: "Asia/Tokyo"); return fact }
        #expect(Self.build(mixed, timeZone: MapFixture.utc).firstDay == Self.day("2023-06-15"))
    }

    @Test func placesAreNumberedInTimeOrderAcrossTheDateLine() throws {
        // Tokyo on the morning of the 15th (local), then Honolulu on the evening of the 14th
        // (local): later in time, earlier by the calendar.
        let tokyo = MapFixture.burst("tokyo", count: 4, at: Places.tokyo, day: "2023-06-14", hour: 23, country: "JP", town: "Tokyo",
                                     timeZone: "Asia/Tokyo")
        let honolulu = MapFixture.burst("honolulu", count: 4, at: Places.honolulu, day: "2023-06-15", hour: 6, country: "US", town: "Honolulu",
                                        timeZone: "Pacific/Honolulu")
        let geometry = Self.build(honolulu + tokyo)
        #expect(geometry.places.map(\.name) == ["Tokyo", "Honolulu"])
        #expect(geometry.dayPlaces.map(\.day) == [Self.day("2023-06-15"), Self.day("2023-06-14")])
        #expect(geometry.route.map(\.placeIndex) == [0, 1])
        #expect(geometry.route.map(\.day) == [Self.day("2023-06-15"), Self.day("2023-06-14")])
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-14"), photoCount: 4, placeIndex: 1),
                                       TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.firstDay == Self.day("2023-06-14") && geometry.lastDay == Self.day("2023-06-15"))
        // As many photos at both: the earlier first day wins, though Honolulu came second.
        #expect(geometry.destinationIndex == 1)
        #expect(geometry.legs.count == 1 && geometry.legs[0].withoutPhotos && geometry.legs[0].meters > 6_000_000)
        #expect(geometry.timeZoneIdentifier == "Asia/Tokyo")
    }

    @Test func svalbardAndTheNorthPole() throws {
        // Longyearbyen (78° N) with a walk 2.5 km across town, Pyramiden by boat, Barentsburg, and
        // a day at the North Pole whose photos lie on all sides of it.
        let zone = "Arctic/Longyearbyen"
        let walk = (0..<6).map { i in
            MapFixture.photo("lyr-\(i)", at: MapFixture.date("2023-07-10 10:00").addingTimeInterval(Double(i) * 1_200),
                             Self.offset(Places.longyearbyen, east: Double(i) * 500), country: "SJ", town: "Longyearbyen", timeZone: zone)
        }
        let pole = [0.0, 90, 180, -90].enumerated().map { i, longitude in
            MapFixture.photo("pole-\(i)", at: MapFixture.date("2023-07-14 12:00").addingTimeInterval(Double(i) * 300), MapFixture.at(89.99, longitude),
                             timeZone: zone)
        }
        let facts = walk
            + MapFixture.burst("pyr", count: 5, at: Self.pyramiden, day: "2023-07-11", hour: 11, country: "SJ", town: "Pyramiden", timeZone: zone)
            + MapFixture.burst("lyr-eve", count: 3, at: Places.longyearbyen, day: "2023-07-11", hour: 20, country: "SJ", town: "Longyearbyen", timeZone: zone)
            + MapFixture.burst("bar", count: 4, at: Self.barentsburg, day: "2023-07-12", hour: 11, country: "SJ", town: "Barentsburg", timeZone: zone)
            + MapFixture.burst("lyr-end", count: 5, at: Places.longyearbyen, day: "2023-07-13", hour: 9, country: "SJ", town: "Longyearbyen", timeZone: zone)
            + pole
        let geometry = Self.build(facts)
        #expect(geometry.places.map(\.name) == ["Longyearbyen", "Pyramiden", "Barentsburg", nil])
        #expect(geometry.places.map(\.photoCount) == [14, 5, 4, 4])
        #expect(geometry.route.map(\.placeIndex) == [0, 1, 0, 2, 0, 3])
        let kilometres = geometry.legs.map { Int(($0.meters / 1_000).rounded()) }
        #expect(kilometres[0] >= 48 && kilometres[0] <= 54 && kilometres[1] == kilometres[0])
        #expect(kilometres[2] >= 34 && kilometres[2] <= 40 && kilometres[3] == kilometres[2])
        #expect(kilometres[4] >= 1_300 && kilometres[4] <= 1_320)
        #expect(geometry.legs.map(\.withoutPhotos) == [false, false, false, false, true])
        #expect(geometry.destinationIndex == 0)
        #expect(geometry.countryPhotos == ["SJ": 23])
        #expect(geometry.places[3].countryKey == nil)
        #expect(pole.contains { $0.asset.location == geometry.places[3].coordinate })
    }
}
