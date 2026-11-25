import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// What the map shows stays true of its trip and its place, from end to end, while the analysis
/// runs, the home moves and a photo comes twice (found in the second re-check of "Deine Welt"): a
/// held record still leads to its place, the longest trip shown is true of its trip, a visit to
/// today's home before moving in puts nothing on it, a trip soon after a move starts at the new
/// home, a photo listed twice in two states of the analysis gives one map, and a country's year
/// follows its place.
extension MapSummaryTests {
    // MARK: True of its trip and place

    /// A record kept while the analysis runs leads to the place it was made at: the trip's places
    /// are numbered anew as photos arrive (Oslo, earlier, comes before the North Cape), so its
    /// old index would open Oslo.
    @Test func aHeldRecordStillPointsToItsPlace() throws {
        let trip = AlbumistID("norway")
        let cape = MapFixture.at(71.1700, 25.7830), capeSouth = MapFixture.at(71.1690, 25.7830), oslo = MapFixture.at(59.9139, 10.7522)
        func input(_ photos: [AssetFacts]) -> MapInput {
            let members = MapFixture.members(photos, of: trip)
            return MapInput(facts: members, trips: [MapFixture.trip(trip, members)], calendar: MapFixture.calendar,
                            now: MapFixture.date("2024-09-01"), analysisRunning: true)
        }
        let first = MapFixture.burst("cape-a", count: 3, at: cape, day: "2024-07-05", jitterMeters: 0, country: "NO", town: "Nordkapp")
        let one = MapSummary.build(input(first))
        let more = MapFixture.burst("oslo", count: 6, at: oslo, day: "2024-07-01", country: "NO", town: "Oslo") + first
            + MapFixture.burst("cape-b", count: 6, at: capeSouth, day: "2024-07-05", hour: 12, jitterMeters: 0, country: "NO", town: "Nordkapp")
        let two = MapSummary.build(input(more), previous: one)
        let held = try #require(one.numbers.record(.northernmost))
        let record = try #require(two.numbers.record(.northernmost))
        let places = try #require(two.trip(trip)).geometry.places
        #expect(record.value == held.value)
        #expect(places[record.placeIndex].name == "Nordkapp")
        #expect(record.placeName == "Nordkapp")
        #expect(record.coordinate == places[record.placeIndex].coordinate)
    }

    /// While the analysis runs, the longest trip shown is one on the map with those days: a kept
    /// "14 Tage" would open the trip the analysis has since cut to 6.
    @Test func theLongestTripShownIsTrueOfItsTrip() throws {
        let norway = AlbumistID("norway"), north = AlbumistID("norway-north")
        let photos = (0..<14).flatMap { day in
            MapFixture.burst("d\(day)", count: 3, at: MapFixture.at(60.0 + Double(day) * 0.5, 10.0), day: String(format: "2024-07-%02d", day + 1),
                             country: "NO", town: "Ort \(day)")
        }
        func input(_ trips: [(AlbumistID, [AssetFacts])]) -> MapInput {
            let members = trips.map { (id: $0.0, facts: MapFixture.members($0.1, of: $0.0)) }
            return MapInput(facts: members.flatMap(\.facts), trips: members.map { MapFixture.trip($0.id, $0.facts) },
                            calendar: MapFixture.calendar, now: MapFixture.date("2024-09-01"), analysisRunning: true)
        }
        let one = MapSummary.build(input([(norway, photos)]))
        #expect(one.numbers.longestTripID == norway && one.numbers.longestTripDays == 14)
        let split = MapSummary.build(input([(norway, Array(photos.prefix(18))), (north, Array(photos.dropFirst(18)))]), previous: one)
        #expect(split.numbers.trips == 2)
        let longest = try #require(split.numbers.longestTripID)
        #expect(longest == north)
        #expect(split.numbers.longestTripDays == split.trip(longest)?.geometry.days)
        #expect(split.numbers.longestTripDays == 8)
        if let day = split.numbers.mostPhotosInADay {
            #expect(split.trip(day.tripID)?.geometry.dayCounts.contains { $0.day == day.day && $0.photoCount == day.photoCount } == true)
        }
    }

    /// A visit to today's home before moving in (a viewing of the flat in 2023, a trip then)
    /// puts nothing on the map nearer to it than the house's rounding: no pin and no place on
    /// today's exact home. Its photos still count for the country.
    @Test func aVisitToTodaysHomeBeforeMovingInPutsNothingOnIt() throws {
        var world = World(homeUntil2024: World.hamburg)
        let viewing = AlbumistID("viewing")
        let members = MapFixture.members(MapFixture.burst("flat", count: 6, at: World.home, day: "2023-10-14", jitterMeters: 30,
                                                          country: "DE", town: "Regensburg"), of: viewing)
        world.facts += members
        world.trips.append(MapFixture.trip(viewing, members))
        let summary = MapSummary.build(world.input())
        #expect(summary.trip(viewing) == nil)
        let points = summary.pins.map(\.coordinate) + summary.trips.flatMap { $0.geometry.places.map(\.coordinate) }
        #expect(!points.isEmpty)
        for point in points { #expect(GeoMath.distance(point, World.home) > MapHome.maximumRoundingMeters, "\(point)") }
        #expect(summary.countries.contains { $0.code == "DE" })
    }

    /// A trip a month after a move starts at the new home: the photos at home of the weeks before
    /// it were there, though the old home still has most of the months before it. Days after a
    /// move only the detection's date of it tells.
    @Test func aTripSoonAfterAMoveStartsAtTheNewHome() throws {
        var world = World(homeUntil2024: World.hamburg)
        let rome = AlbumistID("rome"), early = AlbumistID("rome-early")
        for (id, day) in [(rome, "2024-02-03"), (early, "2024-01-10")] {
            let members = MapFixture.members(MapFixture.burst(id.rawValue, count: 8, at: MapFixture.Places.rome, day: day, country: "IT",
                                                              town: "Rom"), of: id)
            world.facts += members
            world.trips.append(MapFixture.trip(id, members))
        }
        let summary = MapSummary.build(world.input())
        let home = try #require(summary.trip(rome)?.home)
        #expect(GeoMath.distance(home.coordinate, World.home) <= MapHome.maximumRoundingMeters)
        let beforeKnown = try #require(summary.trip(early)?.home)
        #expect(GeoMath.distance(beforeKnown.coordinate, World.hamburg) <= MapHome.maximumRoundingMeters)
        let moved = DetectedHome(center: World.home, since: MapFixture.date("2024-01-01"), photoDays: 400)
        let dated = MapSummary.build(world.input(detected: moved))
        for id in [rome, early] {
            let home = try #require(dated.trip(id)?.home)
            #expect(GeoMath.distance(home.coordinate, World.home) <= MapHome.maximumRoundingMeters, "\(id)")
        }
        // Iceland, in 2023, from the old home either way.
        let iceland = try #require(dated.trip(World.iceland)?.home)
        #expect(GeoMath.distance(iceland.coordinate, World.hamburg) <= MapHome.maximumRoundingMeters)
    }

    /// One photo listed twice in two states of the analysis gives one map in any order: the
    /// analysed copy wins over its twin not analysed yet, and a copy the analysis took for a
    /// document wins over an ordinary one, so it is never a cover.
    @Test func aPhotoListedTwiceInTwoAnalysisStatesGivesOneMapInAnyOrder() throws {
        let trip = AlbumistID("lisbon")
        let others = MapFixture.members(MapFixture.burst("lis", count: 4, at: MapFixture.Places.lisbon, day: "2024-04-03", country: "PT",
                                                         town: "Lissabon"), of: trip)
        func copy(analysed: Bool, document: Bool = false) -> AssetFacts {
            var fact = MapFixture.photo("fav", at: MapFixture.date("2024-04-03 12:00"), MapFixture.Places.lisbon, country: "PT", town: "Lissabon",
                                        trip: trip, favorite: true, analysed: analysed)
            fact.looksLikeDocument = document
            return fact
        }
        func covers(_ copies: [AssetFacts]) -> [AssetID]? {
            let input = MapInput(facts: others + copies, trips: [MapFixture.trip(trip, others + [copies[0]])], calendar: MapFixture.calendar,
                                 now: MapFixture.date("2024-07-01"))
            return MapSummary.build(input).trip(trip)?.geometry.places.first?.coverCandidates
        }
        let analysed = copy(analysed: true), unread = copy(analysed: false), card = copy(analysed: true, document: true)
        #expect(covers([analysed, unread]) == covers([unread, analysed]))
        #expect(covers([unread, analysed])?.first == "fav")
        #expect(covers([card, analysed]) == covers([analysed, card]))
        #expect(covers([analysed, card])?.contains("fav") == false)
    }

    /// Without a clock of its own, a photo is dated on its place's zone for its country as for
    /// its trip: New Year's Eve in New York stays 2025 with the iPhone in Berlin.
    @Test func aCountrysYearFollowsItsPlaceLikeItsTripsYear() throws {
        let trip = AlbumistID("nyc")
        let photos = MapFixture.members((0..<5).map {
            MapFixture.photo("nyc-\($0)", at: MapFixture.date("2026-01-01 02:00").addingTimeInterval(Double($0) * 300), MapFixture.at(40.7580, -73.9855),
                             country: "US", town: "New York", timeZone: "America/New_York")
        }, of: trip)
        var calendar = MapFixture.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let summary = MapSummary.build(MapInput(facts: photos, trips: [MapFixture.trip(trip, photos)], calendar: calendar,
                                                now: MapFixture.date("2026-03-01")))
        #expect(summary.trip(trip)?.geometry.firstDay.year == 2025)
        #expect(try #require(summary.countries.first { $0.code == "US" }).firstVisitYear == 2025)
    }
}
