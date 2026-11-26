import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Which photos count where: photos in flight are left out and counted, photos without location
/// or date count only in the album, a day counts the photos on the map, photos at home are never
/// drawn, a photo listed three times counts once; and countries and disputed areas.
extension TripGeometryTests {
    // MARK: Countries, photos left out, photos per day

    @Test func photosInFlightAreLeftOutAndCounted() throws {
        // Lisbon days, and on the way there three window photos over France seconds apart and
        // two over Spain: without the filter they would make a place and two countries.
        let lisbon = MapFixture.burst("lis", count: 6, at: Places.lisbon, day: "2023-06-15", hour: 10, country: "PT", town: "Lisboa")
        let overFrance = MapFixture.at(45.0, 1.0)
        let window = (0..<3).map { i in
            MapFixture.photo("fr-\(i)", at: MapFixture.date("2023-06-14 15:00").addingTimeInterval(Double(i) * 4),
                             Self.offset(overFrance, east: Double(i) * 900), country: "FR", town: "Brive")
        } + (0..<2).map { i in
            MapFixture.photo("es-\(i)", at: MapFixture.date("2023-06-14 15:40").addingTimeInterval(Double(i) * 600),
                             Self.offset(MapFixture.at(41.5, -4.0), east: Double(i) * -120_000), country: "ES")
        }
        let airborne = Set(window.map(\.id))
        let geometry = Self.build(lisbon + window, airborne: airborne)
        #expect(geometry.places.map(\.name) == ["Lisboa"])
        #expect(geometry.countryPhotos == ["PT": 6])
        #expect(geometry.airborneCount == 5)
        #expect(geometry.photoCount == 11)
        // They are photos of the trip and their day is one of its days, but no photos of a day on
        // the map ("Meiste Fotos an einem Tag").
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 6, placeIndex: 0)])
        #expect(geometry.firstDay == Self.day("2023-06-14") && geometry.days == 2)
        let unfiltered = Self.build(lisbon + window)
        #expect(unfiltered.places.map(\.name) == ["Brive", "Lisboa"])
        #expect(unfiltered.countryPhotos == ["PT": 6, "FR": 3, "ES": 2])
        #expect(unfiltered.airborneCount == 0)
    }

    @Test func photosWithoutLocationOrDateCountOnlyInTheAlbum() throws {
        let lisbon = MapFixture.burst("lis", count: 4, at: Places.lisbon, day: "2023-06-15", hour: 10, country: "PT", town: "Lisboa",
                                      timeZone: "Europe/Lisbon")
        var undated = MapFixture.photo("undated", at: MapFixture.date("2023-06-15 11:00"), Places.lisbon, country: "PT", town: "Lisboa")
        undated.asset.creationDate = nil
        var screenshot = MapFixture.photo("screenshot", at: MapFixture.date("2023-06-15 12:00"), Places.lisbon, country: "PT")
        screenshot.asset.subtypes = .screenshot
        var vague = MapFixture.photo("vague", at: MapFixture.date("2023-06-15 12:30"), Places.lisbon, country: "PT")
        vague.asset.locationAccuracy = 8_000
        let others = [
            MapFixture.photo("unlocated-1", at: MapFixture.date("2023-06-15 23:30"), nil),
            MapFixture.photo("unlocated-2", at: MapFixture.date("2023-06-17 09:00"), nil),
            undated, screenshot, vague,
        ]
        let geometry = Self.build(lisbon + others)
        #expect(geometry.photoCount == 9)
        #expect(geometry.countryPhotos == ["PT": 4])
        #expect(geometry.places.map(\.photoCount) == [4])
        // Photos per day are those on the map; the trip's days are those of all its dated photos.
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 4, placeIndex: 0)])
        #expect(geometry.lastDay == Self.day("2023-06-17"))
        #expect(geometry.end == MapFixture.date("2023-06-17 09:00"))
        // 23:30 UTC is the 16th in Lisbon (summer time), the trip's zone: a trip ending then has
        // two days.
        let late = Self.build(lisbon + [others[0]])
        #expect(late.lastDay == Self.day("2023-06-16") && late.days == 2)
    }

    /// "Meiste Fotos an einem Tag" (concept §5; review: it counted screenshots, photos in flight
    /// and photos without a place): a day counts the trip's photos on the map, nothing else. The
    /// album (`photoCount`) and the trip's days (`firstDay` to `lastDay`) still hold them all.
    @Test func photosPerDayAreThePhotosOnTheMap() throws {
        let lisbon = MapFixture.burst("lis", count: 6, at: Places.lisbon, day: "2023-06-15", hour: 10, country: "PT", town: "Lisboa",
                                      timeZone: "Europe/Lisbon")
        var screenshot = MapFixture.photo("shot", at: MapFixture.date("2023-06-15 12:00"), Places.lisbon, country: "PT", timeZone: "Europe/Lisbon")
        screenshot.asset.subtypes = .screenshot
        let window = (0..<3).map { i in
            MapFixture.photo("window-\(i)", at: MapFixture.date("2023-06-14 15:00").addingTimeInterval(Double(i) * 600),
                             MapFixture.at(44.0 - Double(i), -2.0 - Double(i)), country: "ES")
        }
        let packing = (0..<3).map { i in
            MapFixture.photo("packing-\(i)", at: MapFixture.date("2023-06-13 18:00").addingTimeInterval(Double(i) * 600), Places.regensburg,
                             country: "DE", timeZone: "Europe/Berlin", atHome: true)
        }
        let unlocated = MapFixture.photo("unlocated", at: MapFixture.date("2023-06-16 09:00"), nil)
        let geometry = Self.build(lisbon + [screenshot] + window + packing + [unlocated], airborne: Set(window.map(\.id)))
        #expect(geometry.dayCounts == [TripDay(day: Self.day("2023-06-15"), photoCount: 6, placeIndex: 0)])
        #expect(geometry.photoCount == 14)
        #expect(geometry.firstDay == Self.day("2023-06-13") && geometry.lastDay == Self.day("2023-06-16") && geometry.days == 4)
    }

    // MARK: Photos at home, a photo listed twice

    /// Concept §8: everyday photos at home never appear on the map. A photo marked at home is never
    /// drawn, even when it carries the trip's id (review: four packing photos at the exact home made
    /// a place, a pin and the first route point there; the trip detection should not put them in a
    /// trip, but the map does not rely on it): no day place, place, route point, destination, cover
    /// or country. The album still shows it.
    @Test func photosAtHomeAreNeverDrawn() throws {
        let home = Places.regensburg, station = MapFixture.at(49.0118, 12.0997)
        // The evening before: four favourite photos of the packing at the exact home, and three at
        // the station 230 m away, which are not at home.
        let packing = (0..<4).map { i in
            MapFixture.photo("pack-\(i)", at: MapFixture.date("2023-04-09 17:00").addingTimeInterval(Double(i) * 300), home, country: "DE",
                             town: "Regensburg", timeZone: "Europe/Berlin", atHome: true, favorite: true)
        }
        let train = MapFixture.burst("station", count: 3, at: station, day: "2023-04-09", hour: 18, jitterMeters: 30, country: "DE",
                                     town: "Regensburg", timeZone: "Europe/Berlin")
        let lisbon = MapFixture.burst("lis", count: 5, at: Places.lisbon, day: "2023-04-10", country: "PT", town: "Lisboa", timeZone: "Europe/Lisbon")
            + MapFixture.burst("lis2", count: 5, at: Places.lisbon, day: "2023-04-11", country: "PT", town: "Lisboa", timeZone: "Europe/Lisbon")
        let geometry = Self.build(packing + train + lisbon)
        #expect(geometry.photoCount == 17)
        #expect(geometry.places.map(\.name) == ["Regensburg", "Lisboa"])
        #expect(geometry.places.map(\.photoCount) == [3, 10])
        #expect(geometry.places[0].coverCandidates == ["station-0", "station-1", "station-2"])
        #expect(train.contains { $0.asset.location == geometry.places[0].coordinate })
        #expect(geometry.dayPlaces.map(\.photoCount) == [3, 5, 5])
        #expect(geometry.route.map(\.placeIndex) == [0, 1])
        #expect(geometry.destinationIndex == 1 && geometry.destination == geometry.places[1].coordinate)
        #expect(geometry.countryPhotos == ["DE": 3, "PT": 10])
        #expect(geometry.dayCounts.map(\.photoCount) == [3, 5, 5])
        let points = geometry.places.map(\.coordinate) + geometry.dayPlaces.map(\.coordinate) + geometry.routeCoordinates + [geometry.destination]
        #expect(points.allSatisfy { GeoMath.distance($0, home) > 150 })
        // The album shows them: the trip starts with them.
        #expect(geometry.start == MapFixture.date("2023-04-09 17:00") && geometry.firstDay == Self.day("2023-04-09"))

        // Without a place, the destination is where the photos on the map gather, never home.
        let fewer = Self.build(packing + lisbon.prefix(2))
        #expect(fewer.places.isEmpty && fewer.route.isEmpty)
        #expect(lisbon.prefix(2).contains { $0.asset.location == fewer.destination })
        // Only photos at home: nothing on the map, and the trip's centre (here home) is not taken
        // either: the destination is no place on Earth.
        let onlyHome = Self.build(packing)
        #expect(onlyHome.photoCount == 4 && onlyHome.dayPlaces.isEmpty && onlyHome.places.isEmpty && onlyHome.route.isEmpty)
        #expect(onlyHome.dayCounts.isEmpty && onlyHome.countryPhotos.isEmpty && onlyHome.mainCountryKey == nil)
        #expect(!onlyHome.destination.isPlausible)
    }

    /// A library listing one photo twice or three times counts it once (concept §5: a single wrong
    /// photo makes no place, no record and no country; review: one Longyearbyen photo three times
    /// made a place and "Nördlichster Ort"). Two facts of one photo that differ (two states of the
    /// analysis) give one, the same in any order; one at home wins.
    @Test func onePhotoListedThreeTimesCountsOnce() throws {
        let oslo = MapFixture.at(59.9139, 10.7522), bergen = MapFixture.at(60.3913, 5.3221)
        let city = MapFixture.burst("osl", count: 5, at: oslo, day: "2023-07-09", country: "NO", town: "Oslo", timeZone: "Europe/Oslo")
        let lyr = MapFixture.photo("lyr", at: MapFixture.date("2023-07-10 12:00"), Places.longyearbyen, country: "SJ", town: "Longyearbyen",
                                   timeZone: "Arctic/Longyearbyen")
        let window = MapFixture.photo("window", at: MapFixture.date("2023-07-10 09:00"), MapFixture.at(70, 15), country: "NO")
        let geometry = Self.build(city + [lyr, lyr, lyr, window, window], airborne: [window.id])
        #expect(geometry.photoCount == 7)
        #expect(geometry.airborneCount == 1)
        #expect(geometry.places.map(\.name) == ["Oslo"])
        #expect(geometry.countryPhotos == ["NO": 5, "SJ": 1])
        #expect(geometry.dayCounts.map(\.photoCount) == [5, 1])

        let here = MapFixture.photo("twin", at: MapFixture.date("2023-07-09 12:00"), oslo, country: "NO", town: "Oslo", timeZone: "Europe/Oslo")
        var there = MapFixture.photo("twin", at: MapFixture.date("2023-07-09 12:00"), bergen, country: "NO", town: "Bergen", timeZone: "Europe/Oslo")
        there.asset.isFavorite = true
        var atHome = here
        atHome.atHome = true
        for pair in [[here, there], [here, atHome], [there, atHome]] {
            let one = Self.build(city + pair), other = Self.build(pair.reversed() + city)
            #expect(one == other)
            #expect(one.photoCount == 6)
            #expect(one.countryPhotos.values.reduce(0, +) <= 6)
        }
        // The copy at home wins: the photo is not on the map.
        #expect(Self.build(city + [atHome, there]).countryPhotos == ["NO": 5])
    }

    @Test func countriesAndDisputedAreas() throws {
        let taipei = MapFixture.at(25.0330, 121.5654)
        var facts = MapFixture.burst("tpe", count: 5, at: taipei, day: "2023-10-01", hour: 2, town: "Taipei", timeZone: "Asia/Taipei")
        for i in facts.indices {
            facts[i].place = PlaceComponents(country: "Taiwan", locality: "Taipei", timeZoneIdentifier: "Asia/Taipei", disputedArea: "taiwan")
            facts[i].placeSource = .gpsReverseGeocoded
        }
        facts += MapFixture.burst("tyo", count: 3, at: Places.tokyo, day: "2023-10-03", hour: 2, country: "JP", town: "Tokyo", timeZone: "Asia/Tokyo")
        // Content-inferred places are no GPS places: no country, no name.
        var guessed = MapFixture.burst("guess", count: 3, at: MapFixture.at(35.0116, 135.7681), day: "2023-10-04", hour: 2, country: "JP",
                                       town: "Kyoto")
        for i in guessed.indices { guessed[i].placeSource = .contentInferred }
        let geometry = Self.build(facts + guessed)
        #expect(geometry.countryPhotos == ["disputed-taiwan": 5, "JP": 3])
        #expect(geometry.mainCountryKey == "disputed-taiwan")
        #expect(geometry.places.map(\.countryKey) == ["disputed-taiwan", "JP", nil])
        #expect(geometry.places.map(\.name) == ["Taipei", "Tokyo", nil])
        #expect(geometry.timeZoneIdentifier == "Asia/Taipei")
    }
}
