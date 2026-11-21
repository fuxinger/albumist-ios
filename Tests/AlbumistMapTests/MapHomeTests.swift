import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Home on the map (concept §8): only ever the centre of a 10 km cell, and per trip the home of
/// the trip's time, the user's word first.
@Suite("Map home")
struct MapHomeTests {
    typealias Places = MapFixture.Places

    /// The former home of the move ("Bis 2019: Hamburg"); not among the shared places.
    static let hamburg = MapFixture.at(53.5511, 9.9937)
    /// Border towns 6 km apart: a home whose photos at home fall into two countries.
    static let freilassing = MapFixture.at(47.8370, 12.9770)
    static let salzburg = MapFixture.at(47.8095, 13.0550)
    /// On the equator, north of Quito ("Mitad del Mundo").
    static let equator = MapFixture.at(0, -78.4557)

    static func date(_ string: String) -> Date { MapFixture.date(string) }
    static func at(_ latitude: Double, _ longitude: Double) -> GeoCoordinate { MapFixture.at(latitude, longitude) }

    /// A trip of six photos at `place` on `day`, from `hour` on (not at home).
    static func trip(_ id: String, at place: GeoCoordinate, day: String, hour: Int = 10, country: String) -> (trip: Trip, facts: [AssetFacts]) {
        let tripID = AlbumistID(id)
        let facts = MapFixture.burst(id, count: 6, at: place, day: day, hour: hour, country: country, trip: tripID)
        return (MapFixture.trip(tripID, facts), facts)
    }

    /// One photo at home, exactly at `place`.
    static func atHome(_ id: String, _ date: Date, _ place: GeoCoordinate, country: String? = "DE") -> AssetFacts {
        MapFixture.photo(id, at: date, place, country: country, atHome: true)
    }

    /// A home the user chose, with its country when given.
    static func home(_ place: GeoCoordinate, country: String?, town: String? = nil) -> HomePlace {
        HomePlace(center: place, components: country.map { PlaceComponents(isoCountryCode: $0, country: $0, locality: town) })
    }

    /// "Bis 2019: Hamburg".
    static let formerHamburg = FormerHome(id: AlbumistID("hamburg"), place: home(hamburg, country: "DE", town: "Hamburg"), until: date("2019-01-01"))

    /// A move: everyday photos at home in Hamburg in 2017 and 2018, in Regensburg in 2019 and 2020.
    static let moveFacts = MapFixture.everyday("hh", from: "2017-01-01", to: "2018-12-31", at: hamburg, country: "DE", perDay: 1, everyNthDay: 2)
        + MapFixture.everyday("rgb", from: "2019-01-01", to: "2020-12-31", at: Places.regensburg, country: "DE", perDay: 1, everyNthDay: 2)

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var random = MapRandom(seed: seed)
        var copy = items
        for i in stride(from: copy.count - 1, to: 0, by: -1) { copy.swapAt(i, random.int(0..<(i + 1))) }
        return copy
    }

    // MARK: The home of each trip

    /// A move, left to the detection: a trip before it starts from Hamburg, one after it from
    /// Regensburg; today's house is in Regensburg.
    @Test func aMoveGivesTripsBeforeAndAfterItTheirOwnHome() throws {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let facts = Self.moveFacts + lisbon.facts + rome.facts
        let detected = DetectedHome(center: Places.regensburg, since: Self.date("2019-01-01"), photoDays: 365)
        let homes = MapHome.homes(for: [lisbon.trip, rome.trip], facts: facts, settings: HomeSettings(), detected: detected)
        let before = try #require(homes[lisbon.trip.id])
        let after = try #require(homes[rome.trip.id])
        #expect(GeoMath.distance(before.coordinate, Self.hamburg) < 10_000)
        #expect(GeoMath.distance(after.coordinate, Places.regensburg) < 10_000)
        #expect(before.countryCode == "DE" && after.countryCode == "DE")
        let current = MapHome.current(facts: facts, settings: HomeSettings(), detected: detected, now: Self.date("2021-01-01"))
        #expect(current == RoundedHome(coordinate: MapHome.rounded(Places.regensburg), countryCode: "DE"))
    }

    /// "Bis 2019: Hamburg", a former home the user entered, wins over photos at home that say
    /// Regensburg; after it, the photos decide.
    @Test func aChosenFormerHomeWinsOverThePhotos() throws {
        let settings = HomeSettings(former: [Self.formerHamburg])
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let everyday = MapFixture.everyday("rgb", from: "2017-01-01", to: "2020-12-31", at: Places.regensburg, country: "DE", perDay: 1, everyNthDay: 3)
        let homes = MapHome.homes(for: [lisbon.trip, rome.trip], facts: everyday + lisbon.facts + rome.facts, settings: settings, detected: nil)
        #expect(homes[lisbon.trip.id] == RoundedHome(coordinate: MapHome.rounded(Self.hamburg), countryCode: "DE"))
        let after = try #require(homes[rome.trip.id])
        #expect(GeoMath.distance(after.coordinate, Places.regensburg) < 10_000)
    }

    /// The photos at home of a time the user gave a home of its own do not tell where the
    /// detected home was after it: a trip six weeks after the move starts in Regensburg, though
    /// most photos at home of the 120 days before it were taken in Hamburg.
    @Test func photosOfAChosenTimeDoNotLeakIntoTheDetectedOne() throws {
        let hamburgTime = MapFixture.everyday("hh", from: "2018-06-01", to: "2018-12-31", at: Self.hamburg, country: "DE")
        let regensburgTime = MapFixture.everyday("rgb", from: "2019-01-01", to: "2019-02-09", at: Places.regensburg, country: "DE", everyNthDay: 7)
        let iceland = Self.trip("iceland", at: Places.reykjavik, day: "2019-02-10", country: "IS")
        let facts = hamburgTime + regensburgTime + iceland.facts
        let home = try #require(MapHome.homes(for: [iceland.trip], facts: facts, settings: HomeSettings(former: [Self.formerHamburg]),
                                              detected: nil)[iceland.trip.id])
        #expect(GeoMath.distance(home.coordinate, Places.regensburg) < 10_000)
        // Left to the detection all along, the months before it are mostly Hamburg's, but the
        // weeks before it (`moveLookback`) tell the move: Regensburg too.
        let automatic = try #require(MapHome.homes(for: [iceland.trip], facts: facts, settings: HomeSettings(), detected: nil)[iceland.trip.id])
        #expect(GeoMath.distance(automatic.coordinate, Places.regensburg) < 10_000)
        // Four days after the move only the user's word tells it, the weeks before being Hamburg's
        // as well: the rule decides.
        let soon = Self.trip("soon", at: Places.reykjavik, day: "2019-01-05", country: "IS")
        let soonFacts = hamburgTime + regensburgTime + soon.facts
        let told = try #require(MapHome.homes(for: [soon.trip], facts: soonFacts, settings: HomeSettings(former: [Self.formerHamburg]),
                                              detected: nil)[soon.trip.id])
        #expect(GeoMath.distance(told.coordinate, Places.regensburg) < 10_000)
        let guessed = try #require(MapHome.homes(for: [soon.trip], facts: soonFacts, settings: HomeSettings(), detected: nil)[soon.trip.id])
        #expect(GeoMath.distance(guessed.coordinate, Self.hamburg) < 10_000)
    }

    /// "Kein Zuhause": no home for any trip and no house; a former home the user entered still
    /// holds for its time.
    @Test func noHomeMeansNoHomesAndNoHouse() {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let facts = Self.moveFacts + lisbon.facts + rome.facts
        let detected = DetectedHome(center: Places.regensburg, since: nil, photoDays: 700)
        let now = Self.date("2021-01-01")
        let none = HomeSettings().withoutHome(date: now)
        #expect(MapHome.homes(for: [lisbon.trip, rome.trip], facts: facts, settings: none, detected: detected).isEmpty)
        #expect(MapHome.current(facts: facts, settings: none, detected: detected, now: now) == nil)
        let noneSince2019 = none.addingFormer(Self.formerHamburg, date: now)
        #expect(MapHome.homes(for: [lisbon.trip, rome.trip], facts: facts, settings: noneSince2019, detected: detected)
            == [lisbon.trip.id: RoundedHome(coordinate: MapHome.rounded(Self.hamburg), countryCode: "DE")])
        #expect(MapHome.current(facts: facts, settings: noneSince2019, detected: detected, now: now) == nil)
    }

    /// No photos at home (a library of trips only): the home Albumist detected counts for the
    /// trips from its `since` on (a trip starting at that very moment included), and for every
    /// trip when `since` is unknown. Its country comes from photos at home near it, of any time.
    @Test func withoutPhotosAtHomeTheDetectedHomeCountsIfItHeldThen() {
        let lisbon = Self.trip("lisbon", at: Places.lisbon, day: "2018-06-10", country: "PT")
        let newYear = Self.trip("new-year", at: Places.reykjavik, day: "2019-01-01", hour: 0, country: "IS")
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let trips = [lisbon.trip, newYear.trip, rome.trip]
        let facts = lisbon.facts + newYear.facts + rome.facts
        let detected = DetectedHome(center: Places.regensburg, since: Self.date("2019-01-01"), photoDays: 300)
        let regensburg = RoundedHome(coordinate: MapHome.rounded(Places.regensburg), countryCode: nil)
        #expect(newYear.trip.start == detected.since)
        #expect(MapHome.homes(for: trips, facts: facts, settings: HomeSettings(), detected: detected)
            == [newYear.trip.id: regensburg, rome.trip.id: regensburg])
        let always = DetectedHome(center: Places.regensburg, since: nil, photoDays: 300)
        #expect(MapHome.homes(for: trips, facts: facts, settings: HomeSettings(), detected: always)
            == [lisbon.trip.id: regensburg, newYear.trip.id: regensburg, rome.trip.id: regensburg])
        let longBefore = MapFixture.everyday("old", from: "2010-01-01", to: "2010-03-31", at: Places.regensburg, country: "DE", everyNthDay: 5)
        #expect(MapHome.homes(for: [rome.trip], facts: rome.facts + longBefore, settings: HomeSettings(), detected: detected)
            == [rome.trip.id: RoundedHome(coordinate: MapHome.rounded(Places.regensburg), countryCode: "DE")])
    }

    /// Nothing known: no photo at home with a date and a usable location, no detected home, or
    /// only homes the library could not have, gives no entry and no house.
    @Test func nothingKnownGivesNoEntry() {
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        var undated = Self.atHome("undated", Self.date("2020-05-01"), Places.regensburg)
        undated.asset.creationDate = nil
        var unplaced = Self.atHome("unplaced", Self.date("2020-05-02"), Places.regensburg)
        unplaced.asset.location = nil
        let nullIsland = Self.atHome("null-island", Self.date("2020-05-03"), Self.at(0, 0))
        var vague = Self.atHome("vague", Self.date("2020-05-04"), Places.regensburg)
        vague.asset.locationAccuracy = 20_000
        let notAtHome = MapFixture.photo("everyday", at: Self.date("2020-05-05"), Places.regensburg, country: "DE")
        let facts = rome.facts + [undated, unplaced, nullIsland, vague, notAtHome]
        let now = Self.date("2021-01-01")
        #expect(MapHome.homes(for: [rome.trip], facts: facts, settings: HomeSettings(), detected: nil).isEmpty)
        #expect(MapHome.current(facts: facts, settings: HomeSettings(), detected: nil, now: now) == nil)
        let broken = DetectedHome(center: Self.at(0, 0), since: nil, photoDays: 1)
        #expect(MapHome.homes(for: [rome.trip], facts: facts, settings: HomeSettings(), detected: broken).isEmpty)
        #expect(MapHome.current(facts: facts, settings: HomeSettings(), detected: broken, now: now) == nil)
        let nowhere = HomeSettings().choosing(Self.home(Self.at(0, 0), country: "DE"), from: nil, date: now)
        #expect(MapHome.homes(for: [rome.trip], facts: facts, settings: nowhere, detected: nil).isEmpty)
        #expect(MapHome.current(facts: facts, settings: nowhere, detected: nil, now: now) == nil)
        #expect(MapHome.homes(for: [], facts: Self.moveFacts, settings: HomeSettings(), detected: nil).isEmpty)
    }

    /// The home's country: a chosen home's from the place the user chose (else from the photos
    /// at home within the trip detection's home radius); a detected home's the most common one of
    /// the photos at home it was found from, a tie to the smaller code; places from GPS only;
    /// codes in upper case.
    @Test func theHomeCountry() throws {
        let rome = Self.trip("rome", at: Places.rome, day: "2020-06-10", country: "IT")
        let now = Self.date("2021-01-01")
        let named = HomeSettings().choosing(Self.home(Places.regensburg, country: "de"), from: nil, date: now)
        #expect(MapHome.homes(for: [rome.trip], facts: rome.facts, settings: named, detected: nil)[rome.trip.id]?.countryCode == "DE")

        let nearby = (1...4).map { Self.atHome("rgb-\($0)", Self.date("2015-05-0\($0)"), Places.regensburg, country: "DE") }
        let farAway = (1...9).map { Self.atHome("sbg-\($0)", Self.date("2015-06-0\($0)"), Self.salzburg, country: "AT") }
        let unnamed = HomeSettings().choosing(Self.home(Places.regensburg, country: nil), from: nil, date: now)
        #expect(MapHome.current(facts: nearby + farAway, settings: unnamed, detected: nil, now: now)
            == RoundedHome(coordinate: MapHome.rounded(Places.regensburg), countryCode: "DE"))
        let withoutCountry = try #require(MapHome.current(facts: farAway, settings: unnamed, detected: nil, now: now))
        #expect(withoutCountry.countryCode == nil)

        func detected(_ atHome: [AssetFacts]) throws -> RoundedHome {
            try #require(MapHome.homes(for: [rome.trip], facts: rome.facts + atHome, settings: HomeSettings(), detected: nil)[rome.trip.id])
        }
        let freilassing = (1...4).map { Self.atHome("fl-\($0)", Self.date("2020-05-0\($0)"), Self.freilassing, country: "DE") }
        let salzburg = (1...4).map { Self.atHome("sbg-\($0)", Self.date("2020-05-1\($0)"), Self.salzburg, country: "at") }
        #expect(try detected(freilassing + salzburg).countryCode == "AT")
        #expect(try detected(freilassing + salzburg.dropLast()).countryCode == "DE")
        let guessed = salzburg.map { var f = $0; f.placeSource = .contentInferred; return f }
        #expect(try detected([freilassing[0]] + guessed).countryCode == "DE")
        let unknown = freilassing.map { var f = $0; f.place = nil; f.placeSource = nil; return f }
        #expect(try detected(unknown).countryCode == nil)
    }
}
