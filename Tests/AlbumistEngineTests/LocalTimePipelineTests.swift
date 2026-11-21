import Foundation
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Review finding P1-15 (core logic, 18.11.2026) and the decision of 19.11.2026 ("Ortszeit wie
/// in Apple Fotos"): the days, months and years of a photo are those of the wall clock where it
/// was taken, not those of the time zone the iPhone happens to be set to while it analyses. A
/// photo taken in New York at 23:00 on 31 January belongs to January, also on an iPhone on
/// German time. Expectations come from the photos' wall clocks, never from what the code answers.
@Suite("Local time of the photo: months, years and days (P1-15)")
struct LocalTimePipelineTests {
    static let map: OfflineWorldMap = PipelineTests.map
    static let newYork = GeoCoordinate(latitude: 40.7484, longitude: -73.9857)
    static let auckland = GeoCoordinate(latitude: -36.8485, longitude: 174.7633)
    static let basel = GeoCoordinate(latitude: 47.5596, longitude: 7.5886)

    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// "2026-01-31 23:00" on the wall clock in `zone`.
    static func local(_ string: String, _ zone: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)!
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = f.date(from: string) else { fatalError("no such local time \(string) in \(zone)") }
        return date
    }

    /// The month album a photo belongs to by its own wall clock ("Januar 2026").
    static func monthTitle(_ date: Date, _ zone: String) -> String {
        let c = calendar(zone).dateComponents([.year, .month], from: date)
        return "\(DateRangeFormatter(language: .german).monthName(c.month!)) \(c.year!)"
    }

    static func settings() -> OrganizationSettings {
        var s = OrganizationSettings()
        s.titleLanguage = .german
        s.enabledAreas.formUnion([.chronology])
        return s
    }

    /// An iPhone set to `deviceZone` (`calendar` is the device's calendar, as `.albumistDefault` in the app).
    static func pipeline(store: AlbumistStore, reader: InMemoryLibraryReader, geocoder: FakeGeocoder?, deviceZone: String,
                         settings: OrganizationSettings = settings()) -> AnalysisPipeline {
        AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: geocoder, map: map,
            conditions: FakeConditions(), settings: settings, calendar: calendar(deviceZone), time: ManualTime().source,
            now: { Fixture.date("2026-11-19 06:00") }, earlyGraceOnStop: .seconds(60)
        )
    }

    /// The month albums of the last suggestions: title → photos.
    static func months(_ pipeline: AnalysisPipeline) async throws -> [String: Set<AssetID>] {
        let proposals = try await pipeline.latestProposals()?.proposals ?? []
        return Dictionary(proposals.filter { $0.kind == .chronology(.month) }.map { ($0.title, $0.assetIDs) }, uniquingKeysWith: { $0.union($1) })
    }

    /// Short form for the output: "Januar 2026: 37".
    static func describe(_ months: [String: Set<AssetID>]) -> String {
        months.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.count)" }.joined(separator: ", ")
    }

    /// The reviewer's case (`aChangedTimeZoneOfTheDeviceKeepsTheTrips`): daily life in Munich and
    /// a stay in Basel over New Year with photos at 05:30, 12:00 and 21:30 GMT, analysed with the
    /// iPhone on GMT, Los Angeles, Auckland and GMT again. The month albums must not move.
    @Test func monthAlbumsDoNotDependOnTheTimeZoneOfTheDevice() async throws {
        var lib = LibraryBuilder()
        let munich = lib.daily(from: "2025-12-01", to: "2026-02-28", at: Fixture.Places.munichHome, perDay: 1,
                               skipping: [("2025-12-28", "2026-01-03")])
        var basel: [AssetID] = []
        for (day, month, year) in [(28, 12, 2025), (29, 12, 2025), (30, 12, 2025), (31, 12, 2025), (1, 1, 2026), (2, 1, 2026), (3, 1, 2026)] {
            for time in ["05:30", "12:00", "21:30"] {
                basel.append(lib.photo(at: Fixture.date(String(format: "%04d-%02d-%02d ", year, month, day) + time), Self.basel))
            }
        }
        // Expected: each photo in the month of its own wall clock (Munich and Basel: CET).
        let dates = Dictionary(uniqueKeysWithValues: lib.assets.map { ($0.id, $0.creationDate!) })
        var expected: [String: Set<AssetID>] = [:]
        for id in munich { expected[Self.monthTitle(dates[id]!, "Europe/Berlin"), default: []].insert(id) }
        for id in basel { expected[Self.monthTitle(dates[id]!, "Europe/Zurich"), default: []].insert(id) }

        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        var lines: [String] = []
        var results: [[String: Set<AssetID>]] = []
        for zone in ["GMT", "America/Los_Angeles", "Pacific/Auckland", "GMT"] {
            let pipeline = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: zone)
            #expect(try await pipeline.run().isComplete)
            let months = try await Self.months(pipeline)
            results.append(months)
            lines.append("\(zone): \(Self.describe(months))")
        }
        print("P1-15-DEVICE-ZONE expected: \(Self.describe(expected)) | " + lines.joined(separator: " | "))
        for (index, months) in results.enumerated() {
            #expect(months == expected, "run \(index + 1): \(lines[index])")
        }
    }

    /// New York, 23:00 on 31 January 2026, analysed on an iPhone on German time (05:00 on
    /// 1 February there). The photo is January's: in the month album, for a rule "Januar", in
    /// the search for "Januar 2026" and for the day "31.1.2026".
    @Test func anEveningPhotoInNewYorkStaysInJanuary() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-12-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-01-27", "2026-02-03")])
        var trip: [AssetID] = []
        for day in ["2026-01-28", "2026-01-29", "2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02"] {
            for time in ["10:00", "15:00", "20:00"] { trip.append(lib.photo(at: Self.local("\(day) \(time)", "America/New_York"), Self.newYork, jitterMeters: 30)) }
        }
        let evening = lib.photo(at: Self.local("2026-01-31 23:00", "America/New_York"), Self.newYork, jitterMeters: 30)
        trip.append(evening)
        let geocoder = FakeGeocoder(answers: [
            (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München",
                                              timeZoneIdentifier: "Europe/Berlin")),
            (Self.newYork, .init(isoCountryCode: "US", country: "Vereinigte Staaten", administrativeArea: "New York", locality: "New York",
                                 timeZoneIdentifier: "America/New_York")),
        ])
        let store = try AlbumistStore(url: nil)
        let pipeline = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: geocoder, deviceZone: "Europe/Berlin")
        #expect(try await pipeline.run().isComplete)

        let dates = Dictionary(uniqueKeysWithValues: lib.assets.map { ($0.id, $0.creationDate!) })
        let januaryInNewYork = Set(trip.filter { Self.monthTitle(dates[$0]!, "America/New_York") == "Januar 2026" })
        #expect(januaryInNewYork.contains(evening))
        let months = try await Self.months(pipeline)
        print("P1-15-NEW-YORK device Europe/Berlin: \(Self.describe(months)); the photo of 31.1. 23:00 New York is in "
              + "\(months.filter { $0.value.contains(evening) }.map(\.key))")
        #expect(months["Januar 2026"]?.isSuperset(of: januaryInNewYork) == true, "\(Self.describe(months))")
        #expect(months["Februar 2026"]?.contains(evening) == false)

        let facts = try await pipeline.currentFacts()
        let photo = try #require(facts.first { $0.id == evening })
        let berlin = Self.calendar("Europe/Berlin")
        let rules = RuleEvaluator(calendar: berlin)
        print("P1-15-NEW-YORK rule month 1: \(rules.evaluate(.month(1), photo)), month 2: \(rules.evaluate(.month(2), photo))")
        #expect(rules.evaluate(.month(1), photo))
        #expect(!rules.evaluate(.month(2), photo))
        #expect(rules.evaluate(.year(2026), photo))

        let index = SearchIndex(facts: facts, calendar: berlin)
        let now = Fixture.date("2026-11-19 06:00")
        let january = Set(index.search("Januar 2026", now: now).ids)
        let day = Set(index.search("31.1.2026", now: now).ids)
        print("P1-15-NEW-YORK search „Januar 2026“ finds it: \(january.contains(evening)), „31.1.2026“ finds it: \(day.contains(evening))")
        #expect(january.contains(evening))
        #expect(day.contains(evening))
    }

    /// "Nur 2026" (a trial run over one year) takes the year of the photo's wall clock: New
    /// Year's Eve in Auckland and in New York belong to the year they were in there, whatever
    /// the iPhone's time zone. Without a geocoder: the zones come from the countries (offline).
    @Test func theTrialYearIsTheYearOnTheLocalClock() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-12-01", to: "2027-01-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 3)
        let aucklandOld = lib.photo(at: Self.local("2025-12-31 22:00", "Pacific/Auckland"), Self.auckland, jitterMeters: 30)
        let aucklandNew = lib.photo(at: Self.local("2026-01-01 00:30", "Pacific/Auckland"), Self.auckland, jitterMeters: 30)
        let newYorkOld = lib.photo(at: Self.local("2026-12-31 22:00", "America/New_York"), Self.newYork, jitterMeters: 30)
        let newYorkNew = lib.photo(at: Self.local("2027-01-01 00:30", "America/New_York"), Self.newYork, jitterMeters: 30)

        let berlin = Self.calendar("Europe/Berlin")
        let store = try AlbumistStore(url: nil)
        let pipeline = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: nil, deviceZone: "Europe/Berlin")
        #expect(try await pipeline.run(scope: .all).isComplete)
        let facts = Dictionary(uniqueKeysWithValues: try await pipeline.currentFacts().map { ($0.id, $0) })
        let scope = OrganizationScope.year(2026)
        let inScope = [aucklandOld, aucklandNew, newYorkOld, newYorkNew].map { scope.includes(facts[$0]!, calendar: berlin) }
        print("P1-15-TRIAL-YEAR device Europe/Berlin, Nur 2026: Auckland 31.12.2025 22:00 \(inScope[0]), Auckland 1.1.2026 00:30 \(inScope[1]), "
              + "New York 31.12.2026 22:00 \(inScope[2]), New York 1.1.2027 00:30 \(inScope[3])")
        #expect(inScope == [false, true, true, false])

        // A trial run over 2026 works on the same photos: its year album holds exactly them.
        let trial = Self.pipeline(store: try AlbumistStore(url: nil), reader: InMemoryLibraryReader(assets: lib.assets), geocoder: nil,
                                  deviceZone: "Europe/Berlin")
        #expect(try await trial.run(scope: scope).isComplete)
        let trialMonths = try await Self.months(trial)
        #expect(trialMonths["Januar 2026"]?.contains(aucklandNew) == true, "\(Self.describe(trialMonths))")
        #expect(trialMonths["Dezember 2026"]?.contains(newYorkOld) == true, "\(Self.describe(trialMonths))")
        #expect(trialMonths["Dezember 2025"] == nil && trialMonths["Januar 2027"] == nil, "\(Self.describe(trialMonths))")
    }

    /// Second review: a trial year's image step looks at the photos of that year on their own
    /// clock, and its count says as many. Home Munich, a week in Sydney in February: Sydney's 2026
    /// begins at 14:00 on New Year's Eve in Munich, so three photos of that evening at home lay in
    /// the time the year covers on some clock. They are of 2025 on theirs: before, they were
    /// looked at and counted ("von 114" for 111 photos of 2026).
    @Test func aTrialYearLooksAtThePhotosOfThatYearOnly() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1)
        var newYearsEve: [AssetID] = []
        for time in ["2025-12-31 18:00", "2025-12-31 21:00", "2025-12-31 23:30"] {
            newYearsEve.append(lib.photo(at: Self.local(time, "Europe/Berlin"), Fixture.Places.munichHome, jitterMeters: 20))
        }
        for day in 10...16 {
            for hour in [9, 13, 18] {
                _ = lib.photo(at: Self.local("2026-02-\(day) \(hour):00", "Australia/Sydney"), Fixture.Places.sydney, jitterMeters: 200)
            }
        }
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        // The first run finds the places; the second knows them from its start.
        var totals: [Int] = []
        var pipeline = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Europe/Berlin")
        for run in 0..<2 {
            if run > 0 { pipeline = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Europe/Berlin") }
            let shown = ImageStepTotal()
            #expect(try await pipeline.run(scope: .year(2026), onProgress: { shown.note($0) }).isComplete)
            totals.append(shown.total ?? -1)
        }
        let berlin = Self.calendar("Europe/Berlin")
        let ofTheYear = Set(try await pipeline.currentFacts().filter { OrganizationScope.year(2026).includes($0, calendar: berlin) }.map(\.id))
        let lookedAt = Set(try await store.results(ContentAnalysis.self, kind: "content").keys)
        print("P1-15-TRIAL-YEAR-COUNT photos of 2026 on their clock: \(ofTheYear.count); image step of the first run \(totals[0]), "
              + "of the second \(totals[1]); photos looked at \(lookedAt.count), New Year's Eve at home among them "
              + "\(newYearsEve.filter(lookedAt.contains).count)")
        #expect(totals == [ofTheYear.count, ofTheYear.count])
        #expect(lookedAt == ofTheYear)
    }

    /// A photo without a location has no place to take the time from: it keeps the time zone the
    /// iPhone had at the first analysis, also when the next analysis runs on Los Angeles time.
    @Test func aPhotoWithoutLocationKeepsTheTimeZoneOfTheFirstAnalysis() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1)
        // 03:00 on 1 February in Munich: 18:00 on 31 January in Los Angeles.
        let unlocated = lib.photo(at: Self.local("2026-02-01 03:00", "Europe/Berlin"), nil)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        var found: [String] = []
        for zone in ["Europe/Berlin", "America/Los_Angeles"] {
            let pipeline = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: zone)
            #expect(try await pipeline.run().isComplete)
            let months = try await Self.months(pipeline)
            found.append("\(zone): " + months.filter { $0.value.contains(unlocated) }.map(\.key).joined())
            #expect(months["Februar 2026"]?.contains(unlocated) == true, "\(zone): \(Self.describe(months))")
        }
        print("P1-15-NO-LOCATION photo of 1.2.2026 03:00 (Munich time), no location: " + found.joined(separator: " | "))
    }

    /// The home time zone the store holds (nil: none yet).
    static func storedHomeZone(_ store: AlbumistStore) async throws -> String? {
        try await store.value(String.self, forKey: AnalysisPipeline.Key.homeTimeZone)
    }

    /// What must not change for a suggestion to stay the same one: ID, kind, title, photos.
    static func identity(_ proposals: [AlbumProposal]) -> [String] {
        proposals.map { "\($0.id) \($0.kind) \($0.title) \($0.assetIDs.sorted())" }.sorted()
    }

    /// The home time zone is the iPhone's at the first analysis, stored by that run and only
    /// then: reading the facts before stores nothing, and the next run, on Los Angeles time, keeps
    /// Berlin for the photo without a location.
    @Test func theHomeTimeZoneIsStoredOnceAndKeptWhenTheIPhoneTravels() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-01-31", at: Fixture.Places.munichHome, perDay: 1)
        let unlocated = lib.photo(at: Self.local("2026-01-15 12:00", "Europe/Berlin"), nil)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)

        let atHome = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: "Europe/Berlin")
        #expect(try await atHome.homeTimeZone().identifier == "Europe/Berlin")
        _ = try await atHome.currentFacts()
        #expect(try await Self.storedHomeZone(store) == nil)
        #expect(try await atHome.run().isComplete)
        #expect(try await Self.storedHomeZone(store) == "Europe/Berlin")

        let travelling = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: "America/Los_Angeles")
        #expect(try await travelling.homeTimeZone().identifier == "Europe/Berlin")
        #expect(try await travelling.run().isComplete)
        #expect(try await Self.storedHomeZone(store) == "Europe/Berlin")
        let facts = try await travelling.currentFacts()
        #expect(facts.first { $0.id == unlocated }?.timeZone?.identifier == "Europe/Berlin")
    }

    /// A database from before the update has no home time zone: its first run stores the
    /// iPhone's, and a library taken in that zone keeps its suggestions (IDs, titles, photos) and
    /// its decisions: a declined month stays declined, nothing comes twice.
    @Test func aDatabaseFromBeforeKeepsItsSuggestionsAndDecisions() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-02-28", at: Fixture.Places.munichHome, perDay: 2)
        for (day, time) in [("2025-11-30", "23:30"), ("2025-12-01", "00:30"), ("2025-12-31", "23:45"), ("2026-01-01", "00:15")] {
            _ = lib.photo(at: Self.local("\(day) \(time)", "Europe/Berlin"), Fixture.Places.munichHome)
        }
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let first = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: "Europe/Berlin")
        #expect(try await first.run().isComplete)
        let before = try #require(try await first.latestProposals())
        let december = try #require(before.proposals.first { $0.kind == .chronology(.month) && $0.title == "Dezember 2025" })
        try await store.addOverride(UserOverride(scope: .source(december.id), decision: .rejectProposal))
        // As a database of the version before: everything but the home time zone.
        try await store.removeValue(forKey: AnalysisPipeline.Key.homeTimeZone)
        #expect(try await Self.storedHomeZone(store) == nil)

        let updated = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: "Europe/Berlin")
        #expect(try await updated.run().isComplete)
        #expect(try await Self.storedHomeZone(store) == "Europe/Berlin")
        let after = try #require(try await updated.latestProposals())
        #expect(Self.identity(after.proposals) == Self.identity(before.proposals.filter { $0.id != december.id }))
        #expect(after.dismissed.map(\.id) == [december.id])
    }

    /// For photos taken in the zone the iPhone is in (Munich, Rome and Basel on an iPhone on
    /// German time) nothing changes: the facts with their zones give the suggestions the same
    /// facts give without zones, read on the iPhone's calendar as before the change.
    @Test func photosTakenInTheZoneOfTheIPhoneKeepTheirSuggestions() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-02-28", at: Fixture.Places.munichHome, perDay: 1,
                      skipping: [("2025-12-27", "2026-01-03"), ("2026-02-12", "2026-02-16")])
        for day in ["2025-12-27", "2025-12-28", "2025-12-29", "2025-12-30", "2025-12-31", "2026-01-01", "2026-01-02", "2026-01-03"] {
            for time in ["09:00", "15:00", "23:30"] { _ = lib.photo(at: Self.local("\(day) \(time)", "Europe/Rome"), Fixture.Places.rome, jitterMeters: 40) }
        }
        for day in ["2026-02-13", "2026-02-14", "2026-02-15"] {
            for time in ["00:30", "12:00", "21:00"] { _ = lib.photo(at: Self.local("\(day) \(time)", "Europe/Zurich"), Self.basel, jitterMeters: 40) }
        }
        let geocoder = FakeGeocoder(answers: [
            (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Deutschland", locality: "München", timeZoneIdentifier: "Europe/Berlin")),
            (Fixture.Places.rome, .init(isoCountryCode: "IT", country: "Italien", locality: "Rom", timeZoneIdentifier: "Europe/Rome")),
            (Self.basel, .init(isoCountryCode: "CH", country: "Schweiz", locality: "Basel", timeZoneIdentifier: "Europe/Zurich")),
        ])
        var settings = Self.settings()
        settings.enabledAreas.formUnion([.trips, .places])
        let store = try AlbumistStore(url: nil)
        let pipeline = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: geocoder,
                                     deviceZone: "Europe/Berlin", settings: settings)
        #expect(try await pipeline.run().isComplete)
        let facts = try await pipeline.currentFacts()
        #expect(Set(facts.compactMap(\.timeZone?.identifier)) == ["Europe/Berlin", "Europe/Rome", "Europe/Zurich"])
        let snapshot = { (facts: [AssetFacts]) in
            AnalysisSnapshot(facts: facts, trips: try await store.value([Trip].self, forKey: AnalysisPipeline.Key.trips) ?? [],
                             frequentPlaces: try await store.value([FrequentPlace].self, forKey: AnalysisPipeline.Key.frequentPlaces) ?? [])
        }
        let engine = ProposalEngine(settings: settings, calendar: Self.calendar("Europe/Berlin"))
        let withZones = engine.proposals(for: try await snapshot(facts))
        let asBefore = engine.proposals(for: try await snapshot(facts.map { var f = $0; f.timeZone = nil; return f }))
        #expect(withZones.contains { $0.kind == .trip } && withZones.contains { $0.kind == .chronology(.month) })
        #expect(Self.identity(withZones) == Self.identity(asBefore))
    }

    /// "Analyse neu aufbauen" keeps the home time zone, and the safety copy carries it into a
    /// new database: a new iPhone set up abroad still reads photos without a place on Berlin time.
    @Test func rebuildAndSafetyCopyKeepTheHomeTimeZone() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-01-20", at: Fixture.Places.munichHome, perDay: 1)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let store = try AlbumistStore(url: nil)
        let pipeline = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: "Europe/Berlin")
        #expect(try await pipeline.run().isComplete)
        try await pipeline.resetAnalysis()
        #expect(try await Self.storedHomeZone(store) == "Europe/Berlin")
        let rebuilt = Self.pipeline(store: store, reader: reader, geocoder: FakeGeocoder(), deviceZone: "Asia/Tokyo")
        #expect(try await rebuilt.run().isComplete)
        #expect(try await Self.storedHomeZone(store) == "Europe/Berlin")

        let backup = try await store.safetyBackup()
        #expect(backup.values.contains { $0.key == AnalysisPipeline.Key.homeTimeZone })
        let fresh = try AlbumistStore(url: nil)
        #expect(try await fresh.restore(backup, includingLibraryState: true))
        let newPhone = Self.pipeline(store: fresh, reader: reader, geocoder: FakeGeocoder(), deviceZone: "America/Los_Angeles")
        #expect(try await newPhone.homeTimeZone().identifier == "Europe/Berlin")
        #expect(try await newPhone.run().isComplete)
        #expect(try await Self.storedHomeZone(fresh) == "Europe/Berlin")
    }

    /// Second review: the home time zone is that of the home once Albumist knows it, not the
    /// iPhone's. A user at home in Munich updates the app on a trip to Los Angeles: the home the
    /// last analysis found gives Berlin time before and after the first run; and a library
    /// analysed for the first time over there gets Berlin time from the home that run finds.
    /// The photo without a location of 03:00 on 1 February in Munich (18:00 on 31 January in
    /// Los Angeles) stays in February.
    @Test func aUserAtHomeInMunichWhoUpdatesInLosAngelesGetsBerlinTime() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1)
        let unlocated = lib.photo(at: Self.local("2026-02-01 03:00", "Europe/Berlin"), nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)

        // The database of the version before: analysed at home, no home time zone stored.
        let store = try AlbumistStore(url: nil)
        #expect(try await Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Europe/Berlin").run().isComplete)
        try await store.removeValue(forKey: AnalysisPipeline.Key.homeTimeZone)
        let updated = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "America/Los_Angeles")
        #expect(try await updated.detectedHome() != nil)
        let beforeTheRun = try await updated.homeTimeZone().identifier
        #expect(try await updated.run().isComplete)

        // A library analysed for the first time in Los Angeles.
        let fresh = try AlbumistStore(url: nil)
        let firstAbroad = Self.pipeline(store: fresh, reader: reader, geocoder: nil, deviceZone: "America/Los_Angeles")
        #expect(try await firstAbroad.run().isComplete)

        var found = ["update, before its first run: \(beforeTheRun)"]
        for (name, pipeline, s) in [("update", updated, store), ("first analysis", firstAbroad, fresh)] {
            let stored = try await Self.storedHomeZone(s)
            let months = try await Self.months(pipeline)
            let zone = try await pipeline.currentFacts().first { $0.id == unlocated }?.timeZone?.identifier
            found.append("\(name): stored \(stored ?? "none"), photo on \(zone ?? "none") in \(months.filter { $0.value.contains(unlocated) }.map(\.key))")
            #expect(stored == "Europe/Berlin", "\(name)")
            #expect(zone == "Europe/Berlin", "\(name)")
            #expect(months["Februar 2026"]?.contains(unlocated) == true, "\(name): \(Self.describe(months))")
        }
        print("P1-15-HOME-ZONE iPhone on Los Angeles time, home in Munich: " + found.joined(separator: " | "))
        #expect(beforeTheRun == "Europe/Berlin")
    }

    /// The home the user chose in "Dein Zuhause" gives the home time zone, also where Albumist
    /// finds no home (two days of photos) and on an iPhone set to another zone. "Kein Zuhause
    /// festlegen" afterwards leaves it as it is: no home is known, so nothing changes it.
    @Test func theHomeTheUserChoseGivesTheHomeTimeZone() async throws {
        var lib = LibraryBuilder()
        for day in ["2026-01-10", "2026-01-11"] { _ = lib.photo(at: Self.local("\(day) 12:00", "America/New_York"), Self.newYork) }
        // 22:00 on 31 January in New York: 04:00 on 1 February in Berlin.
        let unlocated = lib.photo(at: Self.local("2026-01-31 22:00", "America/New_York"), nil)
        let store = try AlbumistStore(url: nil)
        let pipeline = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: nil, deviceZone: "Europe/Berlin")
        let home = HomePlace(center: Self.newYork, components: PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten", locality: "New York"))
        try await pipeline.setHomeSettings(HomeSettings().choosing(home, from: nil, date: Fixture.date("2026-02-01")))
        let beforeTheRun = try await pipeline.homeTimeZone().identifier
        #expect(try await pipeline.run().isComplete)
        let stored = try await Self.storedHomeZone(store)
        let zone = try await pipeline.currentFacts().first { $0.id == unlocated }?.timeZone?.identifier

        try await pipeline.setHomeSettings(HomeSettings().withoutHome(date: Fixture.date("2026-02-02")))
        #expect(try await pipeline.run().isComplete)
        let withoutHome = try await Self.storedHomeZone(store)
        print("P1-15-CHOSEN-HOME home New York, iPhone on Berlin time: before the run \(beforeTheRun), stored \(stored ?? "none"), "
              + "photo without location on \(zone ?? "none"); after „Kein Zuhause“ \(withoutHome ?? "none")")
        #expect(beforeTheRun == "America/New_York")
        #expect(stored == "America/New_York")
        #expect(zone == "America/New_York")
        #expect(withoutHome == "America/New_York")
    }

    /// A move to another zone takes the home time zone along once the analysis finds the new
    /// home (Munich, then New York from mid-February): suggestions keep their IDs, a declined one
    /// stays declined, and the next run changes nothing.
    @Test func aMoveTakesTheHomeTimeZoneAlong() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-06-01", to: "2026-01-31", at: Fixture.Places.munichHome, perDay: 2)
        let beforeTheMove = lib.assets
        _ = lib.daily(from: "2026-02-15", to: "2026-08-31", at: Self.newYork, perDay: 2)
        // 22:00 on 30 June in New York: 04:00 on 1 July in Berlin.
        let unlocated = lib.photo(at: Self.local("2026-06-30 22:00", "America/New_York"), nil)
        let store = try AlbumistStore(url: nil)
        let first = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: beforeTheMove), geocoder: nil, deviceZone: "Europe/Berlin")
        #expect(try await first.run().isComplete)
        let atFirst = try await Self.storedHomeZone(store)
        let before = try #require(try await first.latestProposals())
        let december = try #require(before.proposals.first { $0.kind == .chronology(.month) && $0.title == "Dezember 2025" })
        try await store.addOverride(UserOverride(scope: .source(december.id), decision: .rejectProposal))

        let reader = InMemoryLibraryReader(assets: lib.assets)
        let moved = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Europe/Berlin")
        #expect(try await moved.run().isComplete)
        let afterTheMove = try await Self.storedHomeZone(store)
        let after = try #require(try await moved.latestProposals())
        let months = try await Self.months(moved)
        let again = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Europe/Berlin")
        #expect(try await again.run().isComplete)
        let next = try #require(try await again.latestProposals())
        print("P1-15-MOVE home zone \(atFirst ?? "none") → \(afterTheMove ?? "none") → \(try await Self.storedHomeZone(store) ?? "none"); "
              + "photo of 30.6. 22:00 New York in \(months.filter { $0.value.contains(unlocated) }.map(\.key))")
        #expect(atFirst == "Europe/Berlin")
        #expect(afterTheMove == "America/New_York")
        #expect(try await Self.storedHomeZone(store) == "America/New_York")
        #expect(months["Juni 2026"]?.contains(unlocated) == true, "\(Self.describe(months))")
        // The months before the move keep their suggestions; December stays declined.
        let earlier = Set(Self.identity(before.proposals.filter { $0.kind == .chronology(.month) && $0.id != december.id }))
        #expect(earlier.isSubset(of: Set(Self.identity(after.proposals))))
        #expect(after.dismissed.map(\.id) == [december.id])
        #expect(!after.proposals.contains { $0.title == "Dezember 2025" })
        #expect(Self.identity(next.proposals) == Self.identity(after.proposals))
    }

    /// Two homes, half a day apart: two weeks in Munich and two in Auckland all year, every other
    /// day photos at 10:00 and 14:00 on the clock there. Counted on Berlin's clock Auckland has
    /// the more photo days, on Auckland's Munich: following the home Albumist finds would swap
    /// the home time zone with every run. It stays as it is, and so do the suggestions.
    @Test func twoHomesHalfADayApartDoNotSwapTheHomeTimeZone() async throws {
        var lib = LibraryBuilder()
        let days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX")
        days.timeZone = TimeZone(identifier: "UTC")
        days.dateFormat = "yyyy-MM-dd"
        for n in stride(from: 0, to: 365, by: 2) {
            let day = days.string(from: Fixture.date("2025-03-01").addingTimeInterval(Double(n) * 86_400))
            let inMunich = (n / 14) % 2 == 0
            for time in ["10:00", "14:00"] {
                _ = lib.photo(at: Self.local("\(day) \(time)", inMunich ? "Europe/Berlin" : "Pacific/Auckland"),
                              inMunich ? Fixture.Places.munichHome : Self.auckland, jitterMeters: 300)
            }
        }
        // 23:30 on 31 January in Munich: 11:30 on 1 February in Auckland.
        let unlocated = lib.photo(at: Self.local("2026-01-31 23:30", "Europe/Berlin"), nil)
        func found(on zone: String) -> String {
            let home = TripDetector(calendar: Self.calendar(zone)).analyse(in: lib.assets).detectedHome
            return home.map { GeoMath.distance($0.center, Self.auckland) < 50_000 ? "Auckland" : "Munich" } ?? "none"
        }
        #expect(found(on: "Europe/Berlin") == "Auckland")
        #expect(found(on: "Pacific/Auckland") == "Munich")

        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        var zones: [String] = []
        var months: [String] = []
        var suggestions: [[String]] = []
        for _ in 0..<3 {
            let pipeline = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Europe/Berlin")
            #expect(try await pipeline.run().isComplete)
            zones.append(try await Self.storedHomeZone(store) ?? "none")
            months.append(try await Self.months(pipeline).filter { $0.value.contains(unlocated) }.map(\.key).joined())
            suggestions.append(Self.identity(try await pipeline.latestProposals()?.proposals ?? []))
        }
        print("P1-15-TWO-HOMES home time zone after each run: \(zones.joined(separator: ", ")); "
              + "the photo without a location of 31.1. 23:30 (Munich time) in \(months.joined(separator: ", "))")
        #expect(Set(zones).count == 1, "\(zones)")
        #expect(Set(months).count == 1, "\(months)")
        let unchanged = suggestions[1] == suggestions[2]
        #expect(unchanged)
    }

    /// A stored home time zone this system cannot read (a zone newer than its database, from the
    /// safety copy of a newer iPhone; or a value a later version stored in another shape) is
    /// never replaced for that. Photos without a place are read on the iPhone's clock meanwhile;
    /// the stored value stays for a system that can read it.
    @Test func aHomeTimeZoneTheSystemCannotReadIsKept() async throws {
        var lib = LibraryBuilder()
        // Without a location: no home whose zone could take its place.
        for day in 1...20 { _ = lib.photo(at: Self.local(String(format: "2026-01-%02d 12:00", day), "Europe/Berlin"), nil) }
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let newer = try AlbumistStore(url: nil)
        try await newer.setValue("America/Nuuk_Two", forKey: AnalysisPipeline.Key.homeTimeZone)
        let reshaped = try AlbumistStore(url: nil)
        try await reshaped.setValue(["zone": "Europe/Berlin", "since": "2026-01-01"], forKey: AnalysisPipeline.Key.homeTimeZone)

        var lines: [String] = []
        for (name, store) in [("unknown zone", newer), ("other shape", reshaped)] {
            let pipeline = Self.pipeline(store: store, reader: reader, geocoder: nil, deviceZone: "Asia/Tokyo")
            #expect(try await pipeline.run().isComplete)
            let inMemory = try await pipeline.homeTimeZone().identifier
            let zones = Set(try await pipeline.currentFacts().compactMap(\.timeZone?.identifier))
            lines.append("\(name): in memory \(inMemory), photos on \(zones.sorted())")
            #expect(inMemory == "Asia/Tokyo", "\(name)")
            #expect(zones == ["Asia/Tokyo"], "\(name)")
        }
        let keptZone = try await newer.value(String.self, forKey: AnalysisPipeline.Key.homeTimeZone)
        let keptShape = (try? await reshaped.value([String: String].self, forKey: AnalysisPipeline.Key.homeTimeZone)) ?? nil
        print("P1-15-UNREADABLE " + lines.joined(separator: " | ") + "; stored afterwards: \(keptZone ?? "none"), \(keptShape ?? [:])")
        #expect(keptZone == "America/Nuuk_Two")
        #expect(keptShape == ["zone": "Europe/Berlin", "since": "2026-01-01"])
    }

    /// Second review: the zones of the photos' places are worked out once for each state of the
    /// places, not again in every step of a run and for every read of the facts (over 100,000
    /// photos in as many places that took about three seconds each time).
    @Test func theZonesOfThePlacesAreWorkedOutOncePerStateOfThePlaces() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1)
        for day in ["2026-02-10", "2026-02-11", "2026-02-12"] {
            for time in ["10:00", "15:00", "20:00"] { _ = lib.photo(at: Self.local("\(day) \(time)", "America/New_York"), Self.newYork, jitterMeters: 30) }
        }
        let geocoder = FakeGeocoder(answers: [
            (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Deutschland", locality: "München", timeZoneIdentifier: "Europe/Berlin")),
            (Self.newYork, .init(isoCountryCode: "US", country: "Vereinigte Staaten", locality: "New York", timeZoneIdentifier: "America/New_York")),
        ])
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let pipeline = Self.pipeline(store: store, reader: reader, geocoder: geocoder, deviceZone: "Europe/Berlin")
        let work = ZoneWork()
        await pipeline.setZoneProbe { work.add() }
        #expect(try await pipeline.run().isComplete)
        let firstRun = work.count
        for _ in 0..<3 { _ = try await pipeline.currentFacts() }
        let reads = work.count - firstRun
        #expect(try await pipeline.run().isComplete)
        let secondRun = work.count - firstRun - reads
        // A new photo with its place: the places change once more.
        _ = lib.photo(at: Self.local("2026-04-01 12:00", "Europe/Berlin"), Fixture.Places.munichHome)
        await reader.set(assets: lib.assets)
        #expect(try await pipeline.run().isComplete)
        let thirdRun = work.count - firstRun - reads - secondRun
        print("P1-15-ZONES worked out: first run \(firstRun), three reads of the facts \(reads), "
              + "a second run \(secondRun), a run with a new photo \(thirdRun)")
        #expect(firstRun <= 2)
        #expect(reads == 0)
        #expect(secondRun == 0)
        #expect(thirdRun <= 2)
    }

    /// Second review: a picture without a location saved on a trip to New York (received in a
    /// messenger, or from a camera without GPS) at 23:00 on 31 January belongs to the trip by its
    /// time, and so to January on the trip's clock, also in the month album, though the home is
    /// in Munich and the iPhone on German time (05:00 on 1 February there).
    @Test func aPictureWithoutALocationOnATripIsReadOnTheTripsClock() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-12-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-01-27", "2026-02-03")])
        for day in ["2026-01-28", "2026-01-29", "2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02"] {
            for time in ["10:00", "15:00", "20:00"] { _ = lib.photo(at: Self.local("\(day) \(time)", "America/New_York"), Self.newYork, jitterMeters: 30) }
        }
        let received = lib.photo(at: Self.local("2026-01-31 23:00", "America/New_York"), nil)
        let store = try AlbumistStore(url: nil)
        let pipeline = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: nil, deviceZone: "Europe/Berlin")
        #expect(try await pipeline.run().isComplete)
        let trips = try await store.value([Trip].self, forKey: AnalysisPipeline.Key.trips) ?? []
        let zone = try await pipeline.currentFacts().first { $0.id == received }?.timeZone?.identifier
        let months = try await Self.months(pipeline)
        print("P1-15-TRIP-CLOCK picture without a location of 31.1. 23:00 New York, in the trip: "
              + "\(trips.contains { $0.inferredAssetIDs.contains(received) }), on \(zone ?? "none"), in \(months.filter { $0.value.contains(received) }.map(\.key))")
        #expect(trips.contains { $0.inferredAssetIDs.contains(received) })
        #expect(zone == "America/New_York")
        #expect(months["Januar 2026"]?.contains(received) == true, "\(Self.describe(months))")
    }

    /// The assembler: a photo without a place that a trip holds by its time gets the zone of the
    /// trip's destination, the most common one among the trip's photos (New York before
    /// Chicago). A place of its own still wins (one the user chose), and a photo without a place
    /// outside every trip keeps the home time zone.
    @Test func theAssemblerGivesAPhotoOfATripWithoutAPlaceTheClockOfTheTrip() {
        let date = Self.local("2026-01-31 23:00", "America/New_York")
        func asset(_ id: AssetID, _ offset: TimeInterval, _ location: GeoCoordinate?) -> AssetSnapshot {
            AssetSnapshot(id: id, creationDate: date.addingTimeInterval(offset), location: location)
        }
        let chicago = GeoCoordinate(latitude: 41.8781, longitude: -87.6298)
        let assets = [asset("ny1", -7_200, Self.newYork), asset("ny2", 7_200, Self.newYork), asset("chicago", 10_800, chicago),
                      asset("received", 0, nil), asset("assigned", 600, nil), asset("atHome", -20 * 86_400, nil)]
        let newYork = ResolvedPlace(components: .init(isoCountryCode: "US", timeZoneIdentifier: "America/New_York"), source: .gpsReverseGeocoded)
        let places: [AssetID: ResolvedPlace] = [
            "ny1": newYork, "ny2": newYork,
            "chicago": ResolvedPlace(components: .init(isoCountryCode: "US", timeZoneIdentifier: "America/Chicago"), source: .gpsReverseGeocoded),
            "assigned": ResolvedPlace(components: .init(isoCountryCode: "JP"), source: .userAssigned),
        ]
        let trip = Trip(id: .stable("trip", "ny1"), start: date.addingTimeInterval(-7_200), end: date.addingTimeInterval(10_800),
                        geotaggedAssetIDs: ["ny1", "ny2", "chicago"], inferredAssetIDs: ["received", "assigned"], centroid: Self.newYork,
                        maxDistanceFromHomeMeters: 6_500_000, distinctStops: 1, kind: .shortTrip)
        let facts = FactsAssembler.assemble(assets: assets, places: places, contents: [:], texts: [:], trips: [trip], frequentPlaces: [],
                                            groups: [], inventory: CollectionInventory([]), homeTimeZone: TimeZone(identifier: "Europe/Berlin"))
        let zones = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0.timeZone?.identifier ?? "none") })
        #expect(zones == ["ny1": "America/New_York", "ny2": "America/New_York", "chicago": "America/Chicago",
                          "received": "America/New_York", "assigned": "Asia/Tokyo", "atHome": "Europe/Berlin"])
    }

    /// The assembler gives each photo the clock of its place: the zone the online lookup named
    /// (it wins over the country's), else the zone of its country there (Denver, Perth offline),
    /// else the home time zone (no location, a place guessed from the content). Without a home
    /// time zone it gives none, as before.
    @Test func eachPhotoGetsTheClockOfItsPlace() {
        let date = Self.local("2026-01-31 23:00", "Europe/Berlin")
        func asset(_ id: AssetID, _ location: GeoCoordinate?) -> AssetSnapshot {
            AssetSnapshot(id: id, creationDate: date, location: location)
        }
        let assets = [asset("online", Self.newYork), asset("denver", GeoCoordinate(latitude: 39.7392, longitude: -104.9903)),
                      asset("perth", GeoCoordinate(latitude: -31.9523, longitude: 115.8613)), asset("unlocated", nil),
                      asset("guessed", nil), asset("unresolved", Self.newYork)]
        let places: [AssetID: ResolvedPlace] = [
            "online": ResolvedPlace(components: .init(isoCountryCode: "US", timeZoneIdentifier: "America/Chicago"), source: .gpsReverseGeocoded),
            "denver": ResolvedPlace(components: .init(isoCountryCode: "US"), source: .gpsReverseGeocoded),
            "perth": ResolvedPlace(components: .init(isoCountryCode: "AU"), source: .gpsReverseGeocoded),
            "guessed": ResolvedPlace(components: .init(isoCountryCode: "JP"), source: .contentInferred),
        ]
        func zones(_ home: TimeZone?) -> [AssetID: String] {
            let facts = FactsAssembler.assemble(assets: assets, places: places, contents: [:], texts: [:], trips: [], frequentPlaces: [],
                                                groups: [], inventory: CollectionInventory([]), homeTimeZone: home)
            return Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0.timeZone?.identifier ?? "none") })
        }
        #expect(zones(TimeZone(identifier: "Europe/Berlin")) == [
            "online": "America/Chicago", "denver": "America/Denver", "perth": "Australia/Perth",
            "unlocated": "Europe/Berlin", "guessed": "Europe/Berlin", "unresolved": "Europe/Berlin",
        ])
        #expect(Set(zones(nil).values) == ["none"])
    }
}

/// How often a pipeline worked out the zones of the photos' places (`setZoneProbe`).
final class ZoneWork: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func add() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

/// The number the image step counts to ("von N"), as last said (`AnalysisPipeline.Progress`).
final class ImageStepTotal: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int?
    func note(_ progress: AnalysisPipeline.Progress) {
        guard progress.stage == .content else { return }
        lock.lock(); last = progress.total; lock.unlock()
    }
    var total: Int? { lock.lock(); defer { lock.unlock() }; return last }
}
