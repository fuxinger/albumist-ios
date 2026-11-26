import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// How the photos at home tell where home was: the 120 days before a trip (or after it), the
/// day point of them, today's house; the exact home never leaves; any order of the input, a trip
/// given twice, only the dates left to the detection, a busy library.
extension MapHomeTests {
    /// No photos at home before a trip (the library starts with it): those of the 120 days after
    /// its end tell. Photos before it come first, however few; photos later than that tell nothing.
    @Test func photosAfterTheTripTellWhenNoneCameBefore() throws {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2019-06-10", country: "PT")
        let summer = MapFixture.everyday("rgb", from: "2019-07-01", to: "2019-09-30", at: Places.regensburg, country: "DE", everyNthDay: 3)
        let home = try #require(MapHome.homes(for: [lisbon.trip], facts: lisbon.facts + summer, settings: HomeSettings(), detected: nil)[lisbon.trip.id])
        #expect(GeoMath.distance(home.coordinate, Places.regensburg) < 10_000)
        #expect(home.countryCode == "DE")
        let spring = [Self.atHome("hh", Self.date("2019-05-01 12:00"), Self.hamburg)]
        #expect(MapHome.homes(for: [lisbon.trip], facts: lisbon.facts + summer + spring, settings: HomeSettings(), detected: nil)[lisbon.trip.id]
            == RoundedHome(coordinate: MapHome.rounded(Self.hamburg), countryCode: "DE"))
        let winter = MapFixture.everyday("rgb", from: "2019-12-01", to: "2019-12-31", at: Places.regensburg, country: "DE")
        #expect(MapHome.homes(for: [lisbon.trip], facts: lisbon.facts + winter, settings: HomeSettings(), detected: nil).isEmpty)
    }

    /// The lookback's edges, to the second: a photo exactly 120 days before the start counts, one
    /// a second earlier not; after the trip, exactly 120 days after its end still counts.
    @Test func theLookbackHasExactEdges() {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2019-06-10", country: "PT")
        func home(_ date: Date) -> RoundedHome? {
            MapHome.homes(for: [lisbon.trip], facts: lisbon.facts + [Self.atHome("home", date, Self.hamburg)], settings: HomeSettings(),
                          detected: nil)[lisbon.trip.id]
        }
        let hamburg = RoundedHome(coordinate: MapHome.rounded(Self.hamburg), countryCode: "DE")
        #expect(home(lisbon.trip.start.addingTimeInterval(-MapHome.lookback)) == hamburg)
        #expect(home(lisbon.trip.start.addingTimeInterval(-MapHome.lookback - 1)) == nil)
        #expect(home(lisbon.trip.end.addingTimeInterval(MapHome.lookback)) == hamburg)
        #expect(home(lisbon.trip.end.addingTimeInterval(MapHome.lookback + 1)) == nil)
        #expect(MapHome.lookback == 120 * 86_400)
        #expect(MapHome.lookback == TimeInterval(TripDetector.Configuration().homeWindowDays) * 86_400)
        #expect(MapHome.gridMeters == 10_000)
    }

    /// The point of the photos at home is `GeoMath.dayPoint` of them in time order: the place of
    /// most of them, sampled over the whole window. A move within the window (10 photos in
    /// Regensburg, then 30 in Munich): Munich, which the first 15 photos alone would not say.
    @Test func theHomeIsTheDayPointOfThePhotosAtHome() throws {
        let regensburg = MapFixture.burst("rgb", count: 10, at: Places.regensburg, day: "2020-05-01", jitterMeters: 300, country: "DE", atHome: true)
        let munich = MapFixture.burst("muc", count: 30, at: Places.munich, day: "2020-05-02", jitterMeters: 300, country: "DE", atHome: true)
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let atHome = regensburg + munich
        let home = try #require(MapHome.homes(for: [rome.trip], facts: Self.shuffled(atHome + rome.facts, seed: 3), settings: HomeSettings(),
                                              detected: nil)[rome.trip.id])
        let point = try #require(GeoMath.dayPoint(atHome.compactMap(\.asset.location)))
        #expect(home.coordinate == MapHome.rounded(point))
        #expect(GeoMath.distance(home.coordinate, Places.munich) < 10_000)
        #expect(GeoMath.distance(try #require(GeoMath.dayPoint(Array(atHome.prefix(15)).compactMap(\.asset.location))), Places.regensburg) < 1_000)
    }

    /// The window's sample is exactly the one `GeoMath.dayPoint` takes, without copying the window.
    @Test func theSampleIsTheDayPointsOwn() {
        for count in Array(0...200) + [1_000, 54_321] {
            #expect(MapHome.daySample(7..<(7 + count)) == GeoMath.daySampleIndices(count: count).map { $0 + 7 })
        }
    }

    /// Today's house: a chosen home; else the detected one (its country from the photos at home
    /// near it); else the photos at home of the 120 days up to the newest of them not after
    /// `now`; else none.
    @Test func theCurrentHome() throws {
        let now = Self.date("2021-01-01")
        let detected = DetectedHome(center: Places.regensburg, since: Self.date("2019-01-01"), photoDays: 365)
        #expect(MapHome.current(facts: Self.moveFacts, settings: HomeSettings(), detected: detected, now: now)
            == RoundedHome(coordinate: MapHome.rounded(Places.regensburg), countryCode: "DE"))
        let newest = try #require(MapHome.current(facts: Self.moveFacts, settings: HomeSettings(), detected: nil, now: now))
        #expect(GeoMath.distance(newest.coordinate, Places.regensburg) < 10_000)
        #expect(newest.countryCode == "DE")
        let earlier = try #require(MapHome.current(facts: Self.moveFacts, settings: HomeSettings(), detected: nil, now: Self.date("2018-06-01")))
        #expect(GeoMath.distance(earlier.coordinate, Self.hamburg) < 10_000)
        let chosen = HomeSettings().choosing(Self.home(Places.munich, country: "DE"), from: Self.date("2020-06-01"), date: now)
        #expect(MapHome.current(facts: Self.moveFacts, settings: chosen, detected: detected, now: now)
            == RoundedHome(coordinate: MapHome.rounded(Places.munich), countryCode: "DE"))
        #expect(MapHome.current(facts: [], settings: HomeSettings(), detected: nil, now: now) == nil)
    }

    /// The exact home never appears in any output: every coordinate out is the centre of a grid
    /// cell, and none is a home, a detected home or a photo location that went in.
    @Test func theExactHomeNeverLeaves() throws {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let iceland = Self.trip("iceland", at: Places.reykjavik, day: "2019-06-10", country: "IS")
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let now = Self.date("2021-01-01")
        let settings = HomeSettings(former: [Self.formerHamburg]).choosing(Self.home(Places.munich, country: "DE"), from: Self.date("2020-01-01"), date: now)
        let facts = Self.moveFacts + lisbon.facts + iceland.facts + rome.facts
        let detected = DetectedHome(center: Places.regensburg, since: Self.date("2019-01-01"), photoDays: 365)
        let homes = MapHome.homes(for: [lisbon.trip, iceland.trip, rome.trip], facts: facts, settings: settings, detected: detected)
        let current = try #require(MapHome.current(facts: facts, settings: settings, detected: detected, now: now))
        #expect(homes.count == 3)
        let inputs = Set(facts.compactMap(\.asset.location) + [Self.hamburg, Places.munich, Places.regensburg])
        for coordinate in homes.values.map(\.coordinate) + [current.coordinate] {
            #expect(MapHome.rounded(coordinate) == coordinate)
            #expect(!inputs.contains(coordinate))
        }
    }

    /// The same input in any order gives the same homes, also with photos taken at the same
    /// instant in different places.
    @Test func anyOrderOfTheInputGivesTheSameHomes() throws {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let iceland = Self.trip("iceland", at: Places.reykjavik, day: "2019-02-10", country: "IS")
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let instants = (0..<40).map { Self.date("2020-03-01").addingTimeInterval(Double($0) * 86_400) }
        let twins = instants.enumerated().flatMap { i, date in
            [Self.atHome("twin-a-\(i)", date, Self.freilassing, country: "DE"), Self.atHome("twin-b-\(i)", date, Self.salzburg, country: "AT")]
        }
        let trips = [lisbon.trip, iceland.trip, rome.trip]
        let facts = Self.moveFacts + twins + lisbon.facts + iceland.facts + rome.facts
        let settings = HomeSettings(former: [Self.formerHamburg])
        let detected = DetectedHome(center: Places.regensburg, since: Self.date("2019-01-01"), photoDays: 365)
        let now = Self.date("2021-01-01")
        let homes = MapHome.homes(for: trips, facts: facts, settings: settings, detected: detected)
        let current = MapHome.current(facts: facts, settings: settings, detected: nil, now: now)
        #expect(homes.count == 3)
        #expect(current != nil)
        for seed in UInt64(1)...6 {
            let shuffledFacts = Self.shuffled(facts, seed: seed)
            #expect(MapHome.homes(for: Self.shuffled(trips, seed: seed &+ 100), facts: shuffledFacts, settings: settings, detected: detected) == homes)
            #expect(MapHome.current(facts: shuffledFacts, settings: settings, detected: nil, now: now) == current)
        }
    }

    /// A trip id given twice (never by the trip detection) gets the home of its earliest entry,
    /// in any order.
    @Test func aTripGivenTwiceGetsTheHomeOfItsEarliestEntry() throws {
        let early = Self.trip("twice", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let late = Self.trip("twice", at: Places.rome, day: "2020-06-10", country: "IT")
        let facts = Self.moveFacts + early.facts + late.facts
        for trips in [[early.trip, late.trip], [late.trip, early.trip]] {
            let homes = MapHome.homes(for: trips, facts: facts, settings: HomeSettings(), detected: nil)
            #expect(homes.count == 1)
            #expect(GeoMath.distance(try #require(homes[early.trip.id]).coordinate, Self.hamburg) < 10_000)
        }
    }

    /// Only photos on dates the user left to the detection tell a detected home. The settings are
    /// asked once per stretch between the edges of the user's periods, which must give the same
    /// photos as asking for each photo: overlapping former homes, open starts, a chosen home from
    /// a date or for all time, "Kein Zuhause", and photos exactly on an edge and a second before.
    @Test func onlyDatesLeftToTheDetectionCount() {
        var random = MapRandom(seed: 11)
        let origin = Self.date("2010-01-01").timeIntervalSinceReferenceDate
        func someDate() -> Date { Date(timeIntervalSinceReferenceDate: origin + random.unit() * 15 * 365 * 86_400) }
        for round in 0..<40 {
            var settings = HomeSettings()
            for k in 0..<random.int(0..<5) {
                let a = someDate(), b = someDate()
                let openStart = random.int(0..<3) == 0
                settings.former.append(FormerHome(id: AlbumistID("former-\(k)"), place: Self.home(Self.hamburg, country: "DE"),
                                                  from: openStart ? nil : min(a, b), until: max(a, b)))
            }
            switch random.int(0..<4) {
            case 0: break
            case 1: settings = settings.choosing(Self.home(Places.munich, country: "DE"), from: someDate(), date: someDate())
            case 2: settings = settings.choosing(Self.home(Places.munich, country: "DE"), from: nil, date: someDate())
            default: settings = settings.withoutHome(date: someDate())
            }
            let edges = settings.former.compactMap(\.from) + settings.former.map(\.until) + [settings.confirmedFrom].compactMap { $0 }
            let dates = (0..<300).map { _ in someDate() } + edges + edges.map { $0.addingTimeInterval(-1) }
            let facts = dates.enumerated().map { i, date in Self.atHome("p\(round)-\(i)", date, Places.regensburg) }
            let evidence = MapHome.Evidence(MapHome.PhotosAtHome(facts: facts), facts: facts, settings: settings)
            let expected = dates.filter { if case .detected = settings.home(at: $0) { true } else { false } }.sorted()
            #expect(evidence.dates == expected)
        }
    }

    /// A busy library, 50,000 photos at home over ten years with a former home (every photo's
    /// date asked of the settings) and 1,000 trips: the facts are read once, the photos sorted
    /// once and each trip's windows found by binary search. About 0.1 s in a debug build; the
    /// bound catches work that grows faster than the library.
    @Test func aBusyLibraryIsQuick() {
        let start = Self.date("2011-01-01")
        var facts: [AssetFacts] = []
        facts.reserveCapacity(53_000)
        for i in 0..<50_000 {
            let place = i % 3 == 0 ? Places.munich : Places.regensburg
            facts.append(Self.atHome("home-\(i)", start.addingTimeInterval(Double(i) * 6_300), Fixture.jitter(place, seed: i, meters: 2_000)))
        }
        var trips: [Trip] = []
        for t in 0..<1_000 {
            let id = AlbumistID("trip-\(t)")
            let day = start.addingTimeInterval(Double(t) * 315_000 + 3_000)
            let photos = (0..<3).map { MapFixture.photo("trip-\(t)-\($0)", at: day.addingTimeInterval(Double($0) * 600), Places.rome, country: "IT", trip: id) }
            facts.append(contentsOf: photos)
            trips.append(MapFixture.trip(id, photos))
        }
        let settings = HomeSettings(former: [FormerHome(id: AlbumistID("early"), place: Self.home(Self.hamburg, country: "DE"),
                                                        until: Self.date("2013-01-01"))])
        let clock = ThreadCPUClock()
        var fastest = Duration.seconds(60)
        var homes: [AlbumistID: RoundedHome] = [:]
        for _ in 0..<3 {
            let elapsed = clock.measure { homes = MapHome.homes(for: trips, facts: facts, settings: settings, detected: nil) }
            fastest = min(fastest, elapsed)
        }
        #expect(homes.count == 1_000)
        #expect(fastest < .milliseconds(300))
    }
}
