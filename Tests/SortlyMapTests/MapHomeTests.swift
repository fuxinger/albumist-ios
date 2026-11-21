import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyTestSupport

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
        let tripID = SortlyID(id)
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
    static let formerHamburg = FormerHome(id: SortlyID("hamburg"), place: home(hamburg, country: "DE", town: "Hamburg"), until: date("2019-01-01"))

    /// A move: everyday photos at home in Hamburg in 2017 and 2018, in Regensburg in 2019 and 2020.
    static let moveFacts = MapFixture.everyday("hh", from: "2017-01-01", to: "2018-12-31", at: hamburg, country: "DE", perDay: 1, everyNthDay: 2)
        + MapFixture.everyday("rgb", from: "2019-01-01", to: "2020-12-31", at: Places.regensburg, country: "DE", perDay: 1, everyNthDay: 2)

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var random = MapRandom(seed: seed)
        var copy = items
        for i in stride(from: copy.count - 1, to: 0, by: -1) { copy.swapAt(i, random.int(0..<(i + 1))) }
        return copy
    }

    // MARK: Rounding

    /// Two points 1 km apart in one cell give the same point, the cell's centre, in the north, the
    /// south, near the antimeridian and far north.
    @Test func pointsOfOneCellRoundToItsCentre() {
        for place in [Places.regensburg, Self.hamburg, Places.reykjavik, Places.auckland, Places.ushuaia, Places.suva, Places.longyearbyen] {
            let centre = MapHome.rounded(place)
            #expect(centre != place)
            let half = 500 / GeoMath.metersPerDegreeLatitude
            let halfLongitude = half / cos(centre.latitude * .pi / 180)
            let north = Self.at(centre.latitude + half, centre.longitude), south = Self.at(centre.latitude - half, centre.longitude)
            let east = Self.at(centre.latitude, centre.longitude + halfLongitude), west = Self.at(centre.latitude, centre.longitude - halfLongitude)
            #expect(abs(GeoMath.distance(north, south) - 1_000) < 5)
            #expect(abs(GeoMath.distance(east, west) - 1_000) < 5)
            for point in [north, south, east, west] { #expect(MapHome.rounded(point) == centre) }
        }
    }

    /// Every band of the grid, at the corners of its first cell: they round to the cell's centre,
    /// at most half a cell's diagonal away (7.07 km for a flat 10 km square; a little more near
    /// the poles, where a cell's meridians converge), and a whole number of equally wide cells
    /// goes round the Earth, so no sliver of a cell is left at 180°.
    @Test func everyPointLiesWithinHalfACellDiagonalOfItsCentre() {
        let step = MapHome.gridMeters / GeoMath.metersPerDegreeLatitude
        var worst = 0.0, worstUpTo88 = 0.0
        var failures: [Int] = []
        for band in Int((-90 / step).rounded(.down))...Int((90 / step).rounded(.down)) {
            let lower = max(Double(band) * step, -90), upper = min(Double(band + 1) * step, 90)
            let inset = (upper - lower) * 1e-6
            let first = MapHome.rounded(Self.at(lower + inset, -180))
            let width = 2 * (first.longitude + 180)
            let cells = 360 / width
            let last = MapHome.rounded(Self.at(upper - inset, 180 - 1e-9))
            if abs(cells - cells.rounded()) > 1e-6 || abs(last.longitude - (180 - width / 2)) > 1e-9 || last.latitude != first.latitude {
                failures.append(band)
            }
            for latitude in [lower + inset, upper - inset] {
                for longitude in [-180 + width * 1e-6, -180 + width * (1 - 1e-6)] {
                    let point = Self.at(latitude, longitude)
                    if MapHome.rounded(point) != first { failures.append(band) }
                    let distance = GeoMath.distance(point, first)
                    worst = max(worst, distance)
                    if abs(first.latitude) <= 88 { worstUpTo88 = max(worstUpTo88, distance) }
                }
            }
        }
        #expect(failures.isEmpty)
        #expect(worstUpTo88 > 7_000 && worstUpTo88 < 7_130)
        #expect(worst < 7_250)
    }

    /// Rounding twice changes nothing, bit for bit, anywhere on Earth; the result is always a
    /// valid coordinate with its longitude in [-180, 180).
    @Test func roundingTwiceChangesNothing() {
        var random = MapRandom(seed: 42)
        var points = [Self.at(0, -180), Self.at(0, 179.999_999_9), Self.at(-16.8, 180), Self.at(90, 0), Self.at(-90, 45), Self.at(89.99, -179.99),
                      Self.at(-89.99, 179.99), Self.hamburg, Places.regensburg, Places.suva, Places.apia, Places.longyearbyen, Places.ushuaia]
        for _ in 0..<20_000 { points.append(Self.at(random.unit() * 180 - 90, random.unit() * 360 - 180)) }
        var failures: [GeoCoordinate] = []
        for point in points {
            let once = MapHome.rounded(point)
            if MapHome.rounded(once) != once || !(-90...90).contains(once.latitude) || !(once.longitude >= -180 && once.longitude < 180) {
                failures.append(point)
            }
        }
        #expect(failures.isEmpty)
    }

    /// The antimeridian is no seam: the cells on either side of 180° are whole cells (a home in
    /// Fiji is not given away to within metres by a sliver of a cell), their centres lie on the
    /// map (never at 180.04°), and every longitude is wrapped.
    @Test func theAntimeridianIsNoSeam() {
        let latitude = -16.8 // Taveuni, Fiji, which the 180th meridian crosses
        let west = Self.at(latitude, 179.999), east = Self.at(latitude, -179.999)
        let a = MapHome.rounded(west), b = MapHome.rounded(east)
        for (point, centre) in [(west, a), (east, b)] {
            #expect(centre.longitude >= -180 && centre.longitude < 180)
            #expect(GeoMath.distance(point, centre) < 7_100)
        }
        #expect(a.longitude > 179 && b.longitude < -179)
        #expect(abs(GeoMath.distance(a, b) - 10_000) < 50)
        #expect(MapHome.rounded(Self.at(latitude, 180)) == MapHome.rounded(Self.at(latitude, -180)))
        #expect(MapHome.rounded(Self.at(latitude, 180.001)) == b)
        #expect(MapHome.rounded(Self.at(latitude, 540)) == MapHome.rounded(Self.at(latitude, -180)))
        #expect(MapHome.rounded(Self.at(latitude, -190)) == MapHome.rounded(Self.at(latitude, 170)))
        #expect(MapHome.rounded(Self.at(latitude, -539.999)) == b)
    }

    /// At the poles the cells meet: any longitude there rounds to a centre a few kilometres away;
    /// a latitude beyond ±90° counts as the pole.
    @Test func thePolesAndBeyond() {
        for pole in [90.0, -90.0] {
            let centre = MapHome.rounded(Self.at(pole, 0))
            #expect(abs(centre.latitude) <= 90 && abs(centre.latitude) > 89.9)
            #expect(centre.latitude.sign == pole.sign)
            for longitude in stride(from: -180.0, to: 180, by: 7.5) {
                let point = Self.at(pole, longitude)
                let other = MapHome.rounded(point)
                #expect(GeoMath.distance(point, other) < 5_000)
                #expect(MapHome.rounded(other) == other)
            }
            #expect(MapHome.rounded(Self.at(pole * 1.05, 0)) == centre)
        }
        let svalbard = MapHome.rounded(Places.longyearbyen)
        #expect(GeoMath.distance(Places.longyearbyen, svalbard) < 7_100)
    }

    /// The southern hemisphere: its own cells, counted away from the equator, not towards it (a
    /// truncating index would make one cell twice as high on either side of the equator).
    @Test func theSouthernHemisphere() {
        for place in [Places.auckland, Places.ushuaia, Places.suva, Places.apia] {
            let centre = MapHome.rounded(place)
            #expect(centre.latitude < 0)
            #expect(GeoMath.distance(place, centre) < 7_100)
            #expect(MapHome.rounded(centre) == centre)
        }
        let north = MapHome.rounded(Self.at(Self.equator.latitude + 0.01, Self.equator.longitude))
        let south = MapHome.rounded(Self.at(Self.equator.latitude - 0.01, Self.equator.longitude))
        #expect(north.latitude > 0 && south.latitude < 0)
        #expect(abs(north.latitude + south.latitude) < 1e-12)
        #expect(abs(GeoMath.distance(north, south) - 10_000) < 50)
    }

    /// A coordinate that is not a number (never one of the library's) still gives a point on the
    /// map rather than stopping the app.
    @Test func brokenCoordinatesStillGiveAPoint() {
        for point in [Self.at(.nan, 10), Self.at(10, .nan), Self.at(.infinity, -.infinity)] {
            let centre = MapHome.rounded(point)
            #expect(centre.latitude.isFinite && centre.longitude.isFinite)
            #expect(MapHome.rounded(centre) == centre)
        }
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
        let home = try #require(MapHome.homes(for: [iceland.trip], facts: facts, settings: HomeSettings(former: [Self.formerHamburg]), detected: nil)[iceland.trip.id])
        #expect(GeoMath.distance(home.coordinate, Places.regensburg) < 10_000)
        // Left to the detection all along, the months before it are mostly Hamburg's, but the
        // weeks before it (`moveLookback`) tell the move: Regensburg too.
        let automatic = try #require(MapHome.homes(for: [iceland.trip], facts: facts, settings: HomeSettings(), detected: nil)[iceland.trip.id])
        #expect(GeoMath.distance(automatic.coordinate, Places.regensburg) < 10_000)
        // Four days after the move only the user's word tells it, the weeks before being Hamburg's
        // as well: the rule decides.
        let soon = Self.trip("soon", at: Places.reykjavik, day: "2019-01-05", country: "IS")
        let soonFacts = hamburgTime + regensburgTime + soon.facts
        let told = try #require(MapHome.homes(for: [soon.trip], facts: soonFacts, settings: HomeSettings(former: [Self.formerHamburg]), detected: nil)[soon.trip.id])
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
            MapHome.homes(for: [lisbon.trip], facts: lisbon.facts + [Self.atHome("home", date, Self.hamburg)], settings: HomeSettings(), detected: nil)[lisbon.trip.id]
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
        let home = try #require(MapHome.homes(for: [rome.trip], facts: Self.shuffled(atHome + rome.facts, seed: 3), settings: HomeSettings(), detected: nil)[rome.trip.id])
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
                settings.former.append(FormerHome(id: SortlyID("former-\(k)"), place: Self.home(Self.hamburg, country: "DE"), from: openStart ? nil : min(a, b),
                                                  until: max(a, b)))
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
            let id = SortlyID("trip-\(t)")
            let day = start.addingTimeInterval(Double(t) * 315_000 + 3_000)
            let photos = (0..<3).map { MapFixture.photo("trip-\(t)-\($0)", at: day.addingTimeInterval(Double($0) * 600), Places.rome, country: "IT", trip: id) }
            facts.append(contentsOf: photos)
            trips.append(MapFixture.trip(id, photos))
        }
        let settings = HomeSettings(former: [FormerHome(id: SortlyID("early"), place: Self.home(Self.hamburg, country: "DE"), until: Self.date("2013-01-01"))])
        let clock = ContinuousClock()
        var fastest = Duration.seconds(60)
        var homes: [SortlyID: RoundedHome] = [:]
        for _ in 0..<3 {
            let elapsed = clock.measure { homes = MapHome.homes(for: trips, facts: facts, settings: settings, detected: nil) }
            fastest = min(fastest, elapsed)
        }
        #expect(homes.count == 1_000)
        #expect(fastest < .milliseconds(300))
    }
}
