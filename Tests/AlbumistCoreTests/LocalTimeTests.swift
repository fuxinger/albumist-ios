import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Review P1-15 (decision of 19.11.2026, "Ortszeit wie in Apple Fotos"): the zone of a place
/// known only offline, from its country (IANA zone.tab and the reference places of
/// tools/country_time_zones_extra.txt).
@Suite("Time zone of a place known offline (P1-15)")
struct CountryTimeZoneTests {
    /// The table names only zones the system knows: an unknown name would put the photos of a
    /// whole country into the home time zone. The one exception is a zone newer than this
    /// system's database (America/Coyhaique, tzdata 2025b, which the Linux toolchain lacks).
    @Test func everyZoneOfTheTableIsKnown() {
        let zones = CountryTimeZones.allZones
        #expect(zones.count > 400)
        let unknown = zones.filter { TimeZone(identifier: $0) == nil }
        #expect(unknown.subtracting(["America/Coyhaique"]).isEmpty, "\(unknown.sorted())")
        #expect(Set(CountryTimeZones.usable.keys) == Set(CountryTimeZones.table.keys))
        #expect(!CountryTimeZones.databaseVersion.isEmpty)
        for (area, country) in CountryTimeZones.areas {
            #expect(CountryTimeZones.table[country] != nil, "\(area)")
            #expect(DisputedAreas.area(id: area) != nil, "\(area) is no disputed area")
        }
    }

    /// In a country with several zones the zone whose place is nearest: zone.tab's principal
    /// places (Denver, Perth) and the added ones near the borders (Seattle lies nearer to Boise
    /// than to Los Angeles, Alice Springs nearer to Eucla than to Darwin).
    @Test(arguments: [
        ("US", "Denver", 39.7392, -104.9903, "America/Denver"),
        ("AU", "Perth", -31.9523, 115.8613, "Australia/Perth"),
        ("US", "New York", 40.7484, -73.9857, "America/New_York"),
        ("US", "Seattle", 47.6062, -122.3321, "America/Los_Angeles"),
        ("US", "Dallas", 32.7767, -96.7970, "America/Chicago"),
        ("US", "Nashville", 36.1627, -86.7816, "America/Chicago"),
        ("US", "Grand Canyon", 36.0544, -112.1401, "America/Phoenix"),
        ("US", "Honolulu", 21.3069, -157.8583, "Pacific/Honolulu"),
        ("CA", "Québec", 46.8139, -71.2080, "America/Toronto"),
        ("CA", "Banff", 51.1784, -115.5708, "America/Edmonton"),
        ("AU", "Alice Springs", -23.6980, 133.8807, "Australia/Darwin"),
        ("AU", "Byron Bay", -28.6474, 153.6020, "Australia/Sydney"),
        ("BR", "Foz do Iguaçu", -25.5163, -54.5854, "America/Sao_Paulo"),
        ("ES", "Tenerife", 28.2916, -16.6291, "Atlantic/Canary"),
        ("PT", "Madeira", 32.6669, -16.9241, "Atlantic/Madeira"),
        // Ceuta's zone is left out: Andalusia keeps Madrid's zone.
        ("ES", "Málaga", 36.7213, -4.4214, "Europe/Madrid"),
        ("ID", "Ubud", -8.5069, 115.2625, "Asia/Makassar"),
        ("MX", "Tulum", 20.2114, -87.4654, "America/Cancun"),
        // The offline map counts Réunion as part of France (Natural Earth).
        ("FR", "Réunion", -21.1151, 55.5364, "Indian/Reunion"),
        ("FR", "Paris", 48.8566, 2.3522, "Europe/Paris"),
        // Second review: the south of the Gold Coast keeps Queensland's clock up to the border
        // (its airport, Coolangatta, Currumbin, Palm Beach); Tweed Heads across it and the towns
        // behind it keep New South Wales'.
        ("AU", "Gold Coast Airport", -28.1644, 153.5047, "Australia/Brisbane"),
        ("AU", "Coolangatta", -28.1680, 153.5360, "Australia/Brisbane"),
        ("AU", "Currumbin", -28.1330, 153.4830, "Australia/Brisbane"),
        ("AU", "Palm Beach", -28.1140, 153.4640, "Australia/Brisbane"),
        ("AU", "Springbrook", -28.2000, 153.3000, "Australia/Brisbane"),
        ("AU", "Tweed Heads", -28.1800, 153.5450, "Australia/Sydney"),
        ("AU", "Kingscliff", -28.2590, 153.5780, "Australia/Sydney"),
        ("AU", "Murwillumbah", -28.3270, 153.3960, "Australia/Sydney"),
        // West Wendover (Nevada) keeps Utah's clock, Norilsk Krasnoyarsk's, Flin Flon Manitoba's.
        ("US", "West Wendover", 40.7391, -114.0733, "America/Denver"),
        ("RU", "Norilsk", 69.3490, 88.2010, "Asia/Krasnoyarsk"),
        ("CA", "Flin Flon", 54.7670, -101.8770, "America/Winnipeg"),
    ])
    func nearestZoneOfTheCountry(country: String, place: String, latitude: Double, longitude: Double, zone: String) {
        #expect(CountryTimeZones.zone(country: country, near: GeoCoordinate(latitude: latitude, longitude: longitude)) == zone, "\(place)")
    }

    /// On a system whose database lacks a zone of the table, its places get the nearest zone of
    /// the country the system knows (Coyhaique: Chaitén's, Santiago time), not the home time zone.
    @Test func aZoneTheSystemDoesNotKnowHasAStandIn() {
        let coyhaique = GeoCoordinate(latitude: -45.5712, longitude: -72.0685)
        let zone = CountryTimeZones.zone(country: "CL", near: coyhaique)
        #expect(zone == (TimeZone(identifier: "America/Coyhaique") == nil ? "America/Santiago" : "America/Coyhaique"))
    }

    /// Germany and Norway count as one zone (Büsingen and Svalbard keep Berlin's and Oslo's clocks).
    @Test func aCountryWithOneZoneNeedsNoPlace() {
        #expect(CountryTimeZones.zone(country: "DE", near: nil) == "Europe/Berlin")
        #expect(CountryTimeZones.zone(country: "it", near: Fixture.Places.rome) == "Europe/Rome")
        #expect(CountryTimeZones.zone(country: "XK", near: nil) == "Europe/Belgrade")
        #expect(CountryTimeZones.zone(country: "NO", near: nil) == "Europe/Oslo")
        #expect(!CountryTimeZones.dependsOnPlace(country: "DE"))
        #expect(CountryTimeZones.dependsOnPlace(country: "US"))
    }

    /// Without a place a country with several zones tells none, nor does an unknown code: the
    /// photo keeps the home time zone.
    @Test func noZoneWhereNothingTellsOne() {
        #expect(CountryTimeZones.zone(country: "US", near: nil) == nil)
        #expect(CountryTimeZones.zone(country: "ZZ", near: Fixture.Places.munichHome) == nil)
        #expect(CountryTimeZones.zone(disputedArea: "kashmir", near: GeoCoordinate(latitude: 34.08, longitude: 74.80)) == nil)
    }

    /// Disputed areas have no country code (`DisputedAreas`); their clocks are known anyway.
    @Test func disputedAreasHaveTheClockUsedThere() {
        #expect(CountryTimeZones.zone(disputedArea: "taiwan", near: GeoCoordinate(latitude: 25.0330, longitude: 121.5654)) == "Asia/Taipei")
        #expect(CountryTimeZones.zone(disputedArea: "crimea", near: GeoCoordinate(latitude: 44.9521, longitude: 34.1024)) == "Europe/Simferopol")
        #expect(CountryTimeZones.zone(disputedArea: "kosovo", near: nil) == "Europe/Belgrade")
    }

    /// Photos a few metres apart are measured from the same rounded place: never two zones.
    @Test func photosAFewMetresApartGetTheSameZone() {
        for i in 0..<50 {
            let a = Fixture.jitter(GeoCoordinate(latitude: 41.0, longitude: -87.3), seed: i, meters: 20)
            let b = Fixture.jitter(GeoCoordinate(latitude: 41.0, longitude: -87.3), seed: i + 100, meters: 20)
            if CountryTimeZones.rounded(a) == CountryTimeZones.rounded(b) {
                #expect(CountryTimeZones.zone(country: "US", near: a) == CountryTimeZones.zone(country: "US", near: b))
            }
        }
    }
}

@Suite("Local time of a photo (P1-15)")
struct LocalTimeTests {
    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// "2026-03-29 03:15" on the wall clock in `zone`.
    static func local(_ string: String, _ zone: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)!
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = f.date(from: string) else { fatalError("no such local time \(string) in \(zone)") }
        return date
    }

    static func photo(_ id: String, _ date: Date, zone: String?) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: date), timeZone: zone.flatMap(TimeZone.init(identifier:)))
    }

    /// The place's own zone (online lookup) first, then the country's, nothing without a place.
    @Test func theOnlineZoneWinsOverTheCountry() {
        let chicago = PlaceComponents(isoCountryCode: "US", timeZoneIdentifier: "America/Chicago")
        let newYork = GeoCoordinate(latitude: 40.7484, longitude: -73.9857)
        #expect(LocalTime.zone(of: chicago, at: newYork)?.identifier == "America/Chicago")
        let offline = PlaceComponents(isoCountryCode: "US")
        #expect(LocalTime.zone(of: offline, at: newYork)?.identifier == "America/New_York")
        let unknown = PlaceComponents(isoCountryCode: "US", timeZoneIdentifier: "Mars/Olympus_Mons")
        #expect(LocalTime.zone(of: unknown, at: newYork)?.identifier == "America/New_York")
        #expect(LocalTime.zone(of: nil, at: newYork) == nil)
        #expect(LocalTime.zone(of: PlaceComponents(country: "Atlantik"), at: newYork) == nil)
        var finder = TimeZoneFinder()
        #expect(finder.zone(of: offline, at: newYork)?.identifier == "America/New_York")
        #expect(finder.zone(of: offline, at: GeoCoordinate(latitude: 39.7392, longitude: -104.9903))?.identifier == "America/Denver")
        #expect(finder.zone(of: offline, at: nil) == nil)
        #expect(finder.zone(of: chicago, at: newYork)?.identifier == "America/Chicago")
    }

    /// A wall clock read in UTC has the fields the zone's own calendar gives, also on the days the
    /// clocks change (expectations from Foundation's calendar in that zone).
    @Test(arguments: ["Europe/Berlin", "America/New_York", "Pacific/Auckland", "Asia/Kolkata", "Australia/Lord_Howe"])
    func wallClockHasTheFieldsOfTheZone(zone: String) {
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .weekday, .weekOfYear, .yearForWeekOfYear]
        let inZone = Self.calendar(zone)
        let wall = LocalTime.wallCalendar(inZone)
        var date = Fixture.date("2025-12-20 00:00")
        while date < Fixture.date("2026-12-31 00:00") {
            let expected = inZone.dateComponents(fields, from: date)
            let read = wall.dateComponents(fields, from: LocalTime.wallClock(date, in: TimeZone(identifier: zone)!))
            #expect(read == expected, "\(date) in \(zone)")
            date = date.addingTimeInterval(3 * 3_600 + 17 * 60)
        }
    }

    /// 23:00 in New York and 23:00 in Munich on 31 January are the same day; half past midnight in
    /// Munich is the next one.
    @Test func theSameDayAnywhereHasTheSameNumber() {
        let ny = LocalTime.day(LocalTime.wallClock(Self.local("2026-01-31 23:00", "America/New_York"), in: TimeZone(identifier: "America/New_York")!))
        let munich = LocalTime.day(LocalTime.wallClock(Self.local("2026-01-31 23:00", "Europe/Berlin"), in: TimeZone(identifier: "Europe/Berlin")!))
        let night = LocalTime.day(LocalTime.wallClock(Self.local("2026-02-01 00:30", "Europe/Berlin"), in: TimeZone(identifier: "Europe/Berlin")!))
        #expect(ny == munich)
        #expect(night == munich + 1)
    }

    /// Days and months on the photos' clocks across the clock changes of 2026, in Munich (29 March,
    /// 25 October) and New York (8 March, 1 November), on a grouper set to Los Angeles or Auckland:
    /// every photo in the day its own clock showed, also in the hour that comes twice.
    @Test(arguments: ["America/Los_Angeles", "Pacific/Auckland", "Europe/Berlin"])
    func daysAcrossTheClockChanges(device: String) throws {
        let cases: [(String, String, String)] = [
            // spring forward
            ("2026-03-28 23:30", "Europe/Berlin", "28.03.2026"), ("2026-03-29 00:30", "Europe/Berlin", "29.03.2026"),
            ("2026-03-29 01:59", "Europe/Berlin", "29.03.2026"), ("2026-03-29 03:00", "Europe/Berlin", "29.03.2026"),
            ("2026-03-29 23:59", "Europe/Berlin", "29.03.2026"), ("2026-03-30 00:00", "Europe/Berlin", "30.03.2026"),
            ("2026-03-07 23:30", "America/New_York", "07.03.2026"), ("2026-03-08 00:30", "America/New_York", "08.03.2026"),
            ("2026-03-08 03:30", "America/New_York", "08.03.2026"), ("2026-03-08 23:30", "America/New_York", "08.03.2026"),
            // fall back
            ("2026-10-24 23:30", "Europe/Berlin", "24.10.2026"), ("2026-10-25 00:30", "Europe/Berlin", "25.10.2026"),
            ("2026-10-25 23:30", "Europe/Berlin", "25.10.2026"), ("2026-10-26 00:30", "Europe/Berlin", "26.10.2026"),
            ("2026-10-31 23:30", "America/New_York", "31.10.2026"), ("2026-11-01 00:30", "America/New_York", "01.11.2026"),
            ("2026-11-01 23:30", "America/New_York", "01.11.2026"), ("2026-11-02 00:30", "America/New_York", "02.11.2026"),
        ]
        var facts = cases.enumerated().map { i, c in Self.photo("p\(i)", Self.local(c.0, c.1), zone: c.1) }
        // The hour that comes twice in Munich: 02:30 summer time (00:30 UTC) and 02:30 winter
        // time (01:30 UTC).
        let first = Fixture.date("2026-10-25 00:30"), second = Fixture.date("2026-10-25 01:30")
        #expect(Self.calendar("Europe/Berlin").component(.hour, from: first) == 2)
        #expect(Self.calendar("Europe/Berlin").component(.hour, from: second) == 2)
        facts.append(Self.photo("twice-1", first, zone: "Europe/Berlin"))
        facts.append(Self.photo("twice-2", second, zone: "Europe/Berlin"))
        let expected = cases.map(\.2) + ["25.10.2026", "25.10.2026"]

        let grouper = ChronologyGrouper(calendar: Self.calendar(device))
        let (buckets, undated) = grouper.group(facts, levels: [.day])
        #expect(undated.isEmpty)
        let formatter = DateRangeFormatter(language: .german)
        var dayOf: [AssetID: String] = [:]
        for (path, ids) in buckets { for id in ids { dayOf[id] = formatter.label(for: try #require(path.last)) } }
        for (fact, day) in zip(facts, expected) {
            #expect(dayOf[fact.id] == day, "\(fact.id) on a grouper in \(device)")
        }
        // Months: the photo of 31 October at 23:30 in New York is October's.
        let (months, _) = grouper.group(facts, levels: [.month])
        let october = try #require(months[[ChronologyKey(.month, [2026, 10])]])
        #expect(october.contains(facts[14].id))
        #expect(!october.contains(facts[15].id))
    }

    /// Facts made without zones (before the assembler sets them, or in older tests) are read in the
    /// calendar's zone, as before.
    @Test func factsWithoutAZoneAreReadInTheCalendarsZone() {
        let date = Self.local("2026-02-01 03:00", "Europe/Berlin")
        let fact = Self.photo("a", date, zone: nil)
        let la = ChronologyGrouper(calendar: Self.calendar("America/Los_Angeles"))
        let berlin = ChronologyGrouper(calendar: Self.calendar("Europe/Berlin"))
        #expect(la.group([fact], levels: [.month]).buckets.keys.first == [ChronologyKey(.month, [2026, 1])])
        #expect(berlin.group([fact], levels: [.month]).buckets.keys.first == [ChronologyKey(.month, [2026, 2])])
        #expect(la.group([fact.asset], levels: [.month]).buckets.keys.first == [ChronologyKey(.month, [2026, 1])])
    }

    /// A place's days are those of the clock there: a flat in New York photographed at 17:00 and
    /// 19:00 on six days (23:00 and 01:00 the next day in Berlin) has six days, not twelve.
    @Test func aFrequentPlaceCountsTheDaysOfItsClock() {
        let newYork = GeoCoordinate(latitude: 40.7484, longitude: -73.9857)
        var assets: [AssetSnapshot] = []
        for day in [1, 4, 7, 10, 13, 16] {
            for time in ["17:00", "19:00"] {
                assets.append(AssetSnapshot(id: AssetID("\(day) \(time)"), creationDate: Self.local(String(format: "2026-01-%02d ", day) + time, "America/New_York"),
                                            location: Fixture.jitter(newYork, seed: assets.count, meters: 20)))
            }
        }
        let detector = FrequentPlaceDetector(calendar: Self.calendar("Europe/Berlin"))
        let zones = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, TimeZone(identifier: "America/New_York")!) })
        #expect(detector.detect(in: assets, zones: zones).map(\.distinctDays) == [6])
        #expect(detector.detect(in: assets).map(\.distinctDays) == [12])
    }

    /// "Dein Zuhause" offers towns by their photo days on the clocks there: two evenings in New
    /// York at 17:00 and 19:00 are two days, not the three they touch on German time.
    @Test func homeCandidatesCountTheDaysOfTheirClock() {
        let place = PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten", administrativeArea: "New York", locality: "New York")
        var facts: [AssetFacts] = []
        for day in ["2026-01-10", "2026-01-11"] {
            for time in ["17:00", "19:00"] {
                let asset = AssetSnapshot(id: AssetID("\(day) \(time)"), creationDate: Self.local("\(day) \(time)", "America/New_York"),
                                          location: GeoCoordinate(latitude: 40.7484, longitude: -73.9857))
                facts.append(AssetFacts(asset: asset, place: place, placeSource: .gpsReverseGeocoded, timeZone: TimeZone(identifier: "America/New_York")))
            }
        }
        let berlin = Self.calendar("Europe/Berlin")
        #expect(HomeCandidates.make(facts: facts, calendar: berlin).map(\.photoDays) == [2])
        #expect(HomeCandidates.make(facts: facts.map { var f = $0; f.timeZone = nil; return f }, calendar: berlin).map(\.photoDays) == [3])
    }

    /// Rules "Januar" and "2026" take the month and year of the photo's clock.
    @Test func rulesTakeTheMonthOfThePhotosClock() {
        let evening = Self.photo("ny", Self.local("2026-12-31 23:00", "America/New_York"), zone: "America/New_York")
        let rules = RuleEvaluator(calendar: Self.calendar("Europe/Berlin"))
        #expect(rules.evaluate(.month(12), evening))
        #expect(rules.evaluate(.year(2026), evening))
        #expect(!rules.evaluate(.month(1), evening))
        #expect(!rules.evaluate(.year(2027), evening))
        let unknown = Self.photo("x", Self.local("2026-12-31 23:00", "America/New_York"), zone: nil)
        #expect(rules.evaluate(.year(2027), unknown))
    }

    /// Second review: the analysis chooses the clock it detects the trips on by the home alone
    /// (`TripDetector.detectedHome`), so the trips are detected once. That home is the one the
    /// whole analysis finds on the same clock: two homes half a day apart (two weeks in Munich,
    /// two in Auckland, photos at 10:00 and 14:00 on the clock there) give Auckland on Berlin's
    /// clock and Munich on Auckland's; with photos taken out and a place the user is often at too.
    @Test func theHomeAloneIsTheHomeOfTheWholeAnalysis() throws {
        let auckland = GeoCoordinate(latitude: -36.8485, longitude: 174.7633)
        let days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX")
        days.timeZone = TimeZone(identifier: "UTC")
        days.dateFormat = "yyyy-MM-dd"
        var lib = LibraryBuilder()
        for n in stride(from: 0, to: 365, by: 2) {
            let day = days.string(from: Fixture.date("2025-03-01").addingTimeInterval(Double(n) * 86_400))
            let inMunich = (n / 14) % 2 == 0
            for time in ["10:00", "14:00"] {
                _ = lib.photo(at: Self.local("\(day) \(time)", inMunich ? "Europe/Berlin" : "Pacific/Auckland"),
                              inMunich ? Fixture.Places.munichHome : auckland, jitterMeters: 300)
            }
        }
        let takenOut = TripCorrections(excludedAssets: Set(lib.assets.prefix(30).map(\.id)))
        let oftenThere = RecurringPlaceAnswers().answering(true, at: Fixture.Places.tegernsee, name: "Tegernsee", date: Fixture.date("2025-06-01"))
        var found: [String: String] = [:]
        for zone in ["Europe/Berlin", "Pacific/Auckland"] {
            let detector = TripDetector(calendar: Self.calendar(zone))
            for (corrections, places) in [(TripCorrections(), RecurringPlaceAnswers()), (takenOut, oftenThere)] {
                let home = detector.detectedHome(in: lib.assets, corrections: corrections, places: places)
                #expect(home == detector.analyse(in: lib.assets, corrections: corrections, places: places).detectedHome, "\(zone)")
            }
            let home = try #require(detector.detectedHome(in: lib.assets))
            found[zone] = GeoMath.distance(home.center, auckland) < 50_000 ? "Auckland" : "Munich"
        }
        #expect(found == ["Europe/Berlin": "Auckland", "Pacific/Auckland": "Munich"])
        #expect(TripDetector(calendar: Self.calendar("Europe/Berlin")).detectedHome(in: []) == nil)
        // It names the trips step's count first, at 0, as the analysis does.
        let detector = TripDetector(calendar: Self.calendar("Europe/Berlin"))
        var said: [[Int]] = []
        _ = detector.detectedHome(in: lib.assets, progress: { said.append([$0, $1]) })
        var first: [Int]?
        _ = detector.analyse(in: lib.assets, progress: { if first == nil { first = [$0, $1] } })
        #expect(said == [first ?? []] && said == [[0, lib.assets.count]])
    }

    /// The search finds a photo by the day and month of its clock, on an iPhone in Auckland:
    /// New Year's Eve in Munich at 23:30 is 11:30 on New Year's Day there.
    @Test func searchUsesThePhotosClock() {
        let eve = Self.photo("eve", Self.local("2025-12-31 23:30", "Europe/Berlin"), zone: "Europe/Berlin")
        let morning = Self.photo("morning", Self.local("2026-01-01 09:00", "Europe/Berlin"), zone: "Europe/Berlin")
        let index = SearchIndex(facts: [eve, morning], calendar: Self.calendar("Pacific/Auckland"))
        let now = Self.local("2026-11-19 12:00", "Pacific/Auckland")
        #expect(index.search("31.12.2025", now: now).ids == [eve.id])
        #expect(index.search("Dezember 2025", now: now).ids == [eve.id])
        #expect(index.search("2026", now: now).ids == [morning.id])
        #expect(index.search("1.1.2026", now: now).ids == [morning.id])
        #expect(Set(index.search("Silvester", now: now).ids).contains(eve.id))
    }
}
