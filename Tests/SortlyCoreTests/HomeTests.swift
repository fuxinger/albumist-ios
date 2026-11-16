import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// "Dein Zuhause": the one function that says where home was at a date
/// (`HomeSettings.home(at:)`), and what trips, trip names and place albums make of it.
@Suite("Dein Zuhause: home at a date")
struct HomeAtDateTests {
    static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let cologne = GeoCoordinate(latitude: 50.9375, longitude: 6.9603)
    static let munich = HomePlace(center: Fixture.Places.munichHome, components: .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München"))
    static let hamburgHome = HomePlace(center: hamburg, components: .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Hamburg", locality: "Hamburg"))
    static let cologneHome = HomePlace(center: cologne, components: .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Nordrhein-Westfalen", locality: "Köln"))
    let now = Fixture.date("2026-11-16")

    @Test func nothingSetLeavesEveryDateToTheDetection() {
        let home = HomeSettings()
        #expect(home.isAutomatic)
        #expect(home.home(at: Fixture.date("2010-01-01")) == .detected)
        #expect(home.home(at: Fixture.date("2030-01-01")) == .detected)
        #expect(home.home(at: nil) == .detected)
        #expect(home.chosenPlaces.isEmpty)
    }

    /// A place picked under "Ändern" holds for every date.
    @Test func chosenHomeHoldsForEveryDate() {
        let home = HomeSettings().choosing(Self.munich, from: nil, date: now)
        #expect(!home.isAutomatic)
        #expect(home.home(at: Fixture.date("2010-01-01")) == .chosen(Self.munich))
        #expect(home.home(at: Fixture.date("2030-01-01")) == .chosen(Self.munich))
        #expect(home.home(at: nil) == .chosen(Self.munich))
    }

    /// "Stimmt" holds from the confirmation on: before it, the detection decides as before.
    @Test func confirmedHomeHoldsFromTheConfirmation() {
        let home = HomeSettings().confirming(Self.munich, date: now)
        #expect(!home.isAutomatic)
        #expect(home.usesDetection)
        #expect(home.home(at: Fixture.date("2010-01-01")) == .detected)
        #expect(home.home(at: Fixture.date("2026-11-15")) == .detected)
        #expect(home.home(at: now) == .chosen(Self.munich))
        #expect(home.home(at: Fixture.date("2030-01-01")) == .chosen(Self.munich))
        #expect(home.home(at: nil) == .chosen(Self.munich))
        // Picked under "Ändern" afterwards: for every date again.
        #expect(home.choosing(Self.munich, from: nil, date: now).home(at: Fixture.date("2010-01-01")) == .chosen(Self.munich))
        // Read back the same.
        let data = try! JSONEncoder().encode(home)
        #expect(try! JSONDecoder().decode(HomeSettings.self, from: data) == home)
    }

    @Test func noHomeHoldsForEveryDate() {
        let home = HomeSettings().withoutHome(date: now)
        #expect(home.home(at: Fixture.date("2018-06-01")) == HomeAtDate.none)
        #expect(home.home(at: nil) == HomeAtDate.none)
        #expect(!home.usesDetection)
    }

    /// "Bis 2015: Köln", "Bis 2019: Hamburg", now München: a chain, the end of each is not included.
    @Test func formerHomesFormAChain() {
        let home = HomeSettings()
            .choosing(Self.munich, from: nil, date: now)
            .addingFormer(FormerHome(place: Self.hamburgHome, until: Fixture.date("2019-01-01")), date: now)
            .addingFormer(FormerHome(place: Self.cologneHome, until: Fixture.date("2015-01-01")), date: now)
        #expect(home.former.map(\.place) == [Self.cologneHome, Self.hamburgHome])
        #expect(home.home(at: Fixture.date("2012-05-01")) == .chosen(Self.cologneHome))
        #expect(home.home(at: Fixture.date("2014-12-31 23:59")) == .chosen(Self.cologneHome))
        #expect(home.home(at: Fixture.date("2015-01-01")) == .chosen(Self.hamburgHome))
        #expect(home.home(at: Fixture.date("2018-12-31 23:59")) == .chosen(Self.hamburgHome))
        #expect(home.home(at: Fixture.date("2019-01-01")) == .chosen(Self.munich))
        #expect(home.home(at: Fixture.date("2026-01-01")) == .chosen(Self.munich))
        // Without a date: the current home.
        #expect(home.home(at: nil) == .chosen(Self.munich))
    }

    /// Overlapping periods: the one that ends first is the more specific one and wins.
    @Test func overlapIsDecidedForThePeriodThatEndsFirst() {
        let berlin = HomePlace(center: GeoCoordinate(latitude: 52.52, longitude: 13.405), components: nil)
        let home = HomeSettings()
            .addingFormer(FormerHome(place: Self.hamburgHome, from: Fixture.date("2010-01-01"), until: Fixture.date("2020-01-01")), date: now)
            .addingFormer(FormerHome(place: berlin, from: Fixture.date("2016-01-01"), until: Fixture.date("2018-01-01")), date: now)
        #expect(home.home(at: Fixture.date("2015-06-01")) == .chosen(Self.hamburgHome))
        #expect(home.home(at: Fixture.date("2017-06-01")) == .chosen(berlin))
        #expect(home.home(at: Fixture.date("2019-06-01")) == .chosen(Self.hamburgHome))
        // Before the first and after the last period: the current home is automatic.
        #expect(home.home(at: Fixture.date("2009-06-01")) == .detected)
        #expect(home.home(at: Fixture.date("2021-06-01")) == .detected)
        // Same end: the one that began later is the more specific one.
        let same = HomeSettings()
            .addingFormer(FormerHome(place: Self.hamburgHome, from: Fixture.date("2010-01-01"), until: Fixture.date("2020-01-01")), date: now)
            .addingFormer(FormerHome(place: berlin, from: Fixture.date("2018-01-01"), until: Fixture.date("2020-01-01")), date: now)
        #expect(same.home(at: Fixture.date("2019-01-01")) == .chosen(berlin))
        #expect(same.home(at: Fixture.date("2017-01-01")) == .chosen(Self.hamburgHome))
    }

    /// A former home with "Kein Zuhause" now (moved away, travelling since): the former home
    /// for its time, no home after it.
    @Test func formerHomeAndNoHomeNow() {
        let home = HomeSettings().withoutHome(date: now)
            .addingFormer(FormerHome(place: Self.hamburgHome, until: Fixture.date("2019-01-01")), date: now)
        #expect(home.home(at: Fixture.date("2018-01-01")) == .chosen(Self.hamburgHome))
        #expect(home.home(at: Fixture.date("2020-01-01")) == HomeAtDate.none)
        #expect(home.chosenPlaces == [Self.hamburgHome])
        #expect(!home.usesDetection)
    }

    @Test func backToAutomaticKeepsFormerHomesAndRemovingOneWorks() {
        let former = FormerHome(place: Self.hamburgHome, until: Fixture.date("2019-01-01"))
        var home = HomeSettings().choosing(Self.munich, from: nil, date: now).addingFormer(former, date: now)
        home = home.automatic(date: now)
        #expect(home.home(at: Fixture.date("2020-01-01")) == .detected)
        #expect(home.home(at: Fixture.date("2018-01-01")) == .chosen(Self.hamburgHome))
        #expect(!home.isAutomatic)
        home = home.removingFormer([former.id], date: now)
        #expect(home.isAutomatic)
    }

    @Test func keysOfAHomeAreItsCountryRegionAndTown() {
        #expect(Self.munich.keys == [
            PlaceKey(level: .country, path: "de"), PlaceKey(level: .administrativeArea, path: "de/bayern"),
            PlaceKey(level: .locality, path: "de/bayern/munchen"),
        ])
        // Offline only country and region are known.
        let offline = HomePlace(center: Fixture.Places.munichHome, components: .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern"))
        #expect(offline.keys.count == 2)
        #expect(HomePlace(center: Fixture.Places.munichHome, components: nil).keys.isEmpty)
        // The same place always gets the same id.
        #expect(HomePlace(center: Fixture.Places.munichHome, components: nil).id == Self.munich.id)
    }
}

@Suite("Dein Zuhause: stored settings")
struct HomeSettingsStorageTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    @Test func roundTrip() throws {
        let now = Fixture.date("2026-11-16")
        let home = HomeSettings().choosing(HomeAtDateTests.munich, from: nil, date: now)
            .addingFormer(FormerHome(place: HomeAtDateTests.hamburgHome, from: Fixture.date("2012-01-01"), until: Fixture.date("2019-01-01")), date: now)
        let data = try encoder.encode(home)
        #expect(try decoder.decode(HomeSettings.self, from: data) == home)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"version\":1"))
    }

    /// Nothing stored (every version before this one) or a value with fields missing: automatic.
    @Test func olderAndNewerValuesStayReadable() throws {
        #expect(try decoder.decode(HomeSettings.self, from: Data("{}".utf8)) == HomeSettings())
        #expect(try decoder.decode(HomeSettings.self, from: Data(#"{"mode":"none"}"#.utf8)).home(at: nil) == HomeAtDate.none)
        // A mode a later version added: the detection, which is always safe.
        let later = try decoder.decode(HomeSettings.self, from: Data(#"{"version":2,"mode":"sometimes","former":[],"extra":true}"#.utf8))
        #expect(later.home(at: nil) == .detected)
        // "Confirmed" without a place (damaged) is automatic, not an error.
        #expect(try decoder.decode(HomeSettings.self, from: Data(#"{"mode":"confirmed"}"#.utf8)).isAutomatic)
    }

    /// Answers stored before places had a kind and a name of the user's.
    @Test func olderPlaceAnswersStayReadable() throws {
        let old = #"{"places":[{"id":"a","center":{"latitude":45.6,"longitude":10.7},"oftenHere":true,"name":"Malcesine","answeredAt":0}]}"#
        let answers = try decoder.decode(RecurringPlaceAnswers.self, from: Data(old.utf8))
        #expect(answers.places.first?.kind == nil)
        #expect(answers.places.first?.label == nil)
        #expect(answers.oftenHere.count == 1)
    }

    @Test func personalPlaceKeepsItsIdAndTakesTheUsersName() {
        let date = Fixture.date("2026-11-16")
        let answered = RecurringPlaceAnswers().answering(true, at: Fixture.Places.gardaLake, name: "Malcesine", date: date)
        let named = answered.addingPersonalPlace(at: Fixture.Places.gardaLake, name: nil, kind: .other, label: "  Oma  ", date: date)
        #expect(named.places.count == 1)
        #expect(named.places[0].id == answered.places[0].id)
        #expect(named.places[0].kind == .other)
        #expect(named.places[0].label == "Oma")
        #expect(named.places[0].name == "Malcesine")
        let parents = RecurringPlaceAnswers().addingPersonalPlace(at: Fixture.Places.tegernsee, name: "Tegernsee", kind: .parents, label: "", date: date)
        #expect(parents.oftenHere.first?.kind == .parents)
        #expect(parents.oftenHere.first?.label == nil)
    }
}

@Suite("Dein Zuhause: trips")
struct HomeTripTests {
    let detector = TripDetector(calendar: Fixture.calendar)
    let now = Fixture.date("2026-11-16")

    /// Everyday life in Munich with three Rome trips.
    func munichLibrary() -> (LibraryBuilder, [[AssetID]]) {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        let t1 = lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let t2 = lib.daily(from: "2025-09-03", to: "2025-09-08", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let t3 = lib.daily(from: "2026-06-14", to: "2026-06-21", at: Fixture.Places.rome, perDay: 6, hour: 10)
        return (lib, [t1, t2, t3])
    }

    /// "Stimmt": the same home as detected changes no trip and no home photo.
    @Test func confirmingTheDetectedHomeChangesNothing() throws {
        let (lib, expected) = munichLibrary()
        let automatic = detector.analyse(in: lib.assets)
        let detected = try #require(automatic.detectedHome)
        #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 1_000)
        #expect(detected.since == nil)
        let confirmed = detector.analyse(in: lib.assets, home: HomeSettings().confirming(HomePlace(center: detected.center, components: nil), date: now))
        #expect(confirmed.trips.map { Set($0.geotaggedAssetIDs) } == expected.map(Set.init))
        #expect(confirmed.trips == automatic.trips)
        #expect(confirmed.atHome == automatic.atHome)
        #expect(!automatic.atHome.isEmpty)
    }

    /// "Stimmt" after a move (the detection knows when: `since` is set): the time in the old
    /// town stays everyday life, no trip comes up, no photo changes between home and away.
    @Test func confirmingAfterAMoveChangesNothing() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2017-01-01", to: "2018-12-31", at: HomeAtDateTests.hamburg, perDay: 2, hour: 19)
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        let automatic = detector.analyse(in: lib.assets)
        let detected = try #require(automatic.detectedHome)
        #expect(detected.since != nil)
        #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 1_000)
        let confirmed = detector.analyse(in: lib.assets, home: HomeSettings().confirming(HomePlace(center: detected.center, components: nil), date: now))
        #expect(confirmed.trips == automatic.trips)
        #expect(confirmed.trips.isEmpty)
        #expect(confirmed.atHome == automatic.atHome)
        // Photos after the confirmation are judged by the confirmed home, whatever the detection
        // would say: a long stay in Hamburg later is a trip.
        var later = lib
        let away = later.daily(from: "2026-12-01", to: "2027-03-31", at: HomeAtDateTests.hamburg, perDay: 3, hour: 19)
        let pinned = detector.analyse(in: later.assets, home: HomeSettings().confirming(HomePlace(center: detected.center, components: nil), date: now))
        #expect(pinned.trips.contains { Set(away).isSubset(of: Set($0.geotaggedAssetIDs)) })
        #expect(pinned.atHome.isDisjoint(with: away))
    }

    /// "Kein Zuhause": no photo is at home, the trips stay what they were.
    @Test func noHomeMeansNoPhotoIsAtHomeButTripsStay() {
        let (lib, _) = munichLibrary()
        let automatic = detector.analyse(in: lib.assets)
        let none = detector.analyse(in: lib.assets, home: HomeSettings().withoutHome(date: now))
        #expect(none.atHome.isEmpty)
        #expect(none.trips == automatic.trips)
    }

    /// The user lived in Hamburg until the end of 2018 and moved to Munich. A weekend in Munich
    /// in November 2018, before the move: the detection looks four months around a date and
    /// already sees Munich as home then. "Bis 2019: Hamburg" makes it the trip it was.
    @Test func tripsAreJudgedAgainstTheHomeOfTheirTime() throws {
        var lib = LibraryBuilder()
        let hamburg = HomeAtDateTests.hamburg
        lib.daily(from: "2017-01-01", to: "2018-12-31", at: hamburg, perDay: 2, hour: 19, skipping: [("2018-11-09", "2018-11-11")])
        let weekend = lib.daily(from: "2018-11-09", to: "2018-11-11", at: Fixture.Places.munichHome, perDay: 4, hour: 11)
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        let automatic = detector.analyse(in: lib.assets)
        #expect(!automatic.trips.contains { Set($0.geotaggedAssetIDs) == Set(weekend) })
        let detected = try #require(automatic.detectedHome)
        #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 1_000)
        #expect(detected.since != nil)

        let settings = HomeSettings()
            .choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now)
            .addingFormer(FormerHome(place: HomeAtDateTests.hamburgHome, until: Fixture.date("2019-01-01")), date: now)
        let chosen = detector.analyse(in: lib.assets, home: settings)
        let trip = try #require(chosen.trips.first { Set($0.geotaggedAssetIDs) == Set(weekend) })
        #expect(trip.kind == .weekendTrip)
        #expect(chosen.trips.count == 1)
        // Home photos of each time are at home, the weekend is not.
        #expect(chosen.atHome.isDisjoint(with: weekend))
        #expect(chosen.atHome.count == lib.assets.count - weekend.count)
    }

    /// A place of the user's ("Eltern"): stays there are no trips, and its photos are not home.
    @Test func staysAtAPlaceOfTheUsersAreNoTrips() {
        var lib = LibraryBuilder()
        var stays: [(String, String)] = []
        for month in 1...12 { stays.append((String(format: "2026-%02d-05", month), String(format: "2026-%02d-08", month))) }
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19, skipping: stays)
        let garda = stays.flatMap { lib.daily(from: $0.0, to: $0.1, at: Fixture.Places.gardaLake, perDay: 5, hour: 10) }
        #expect(detector.detect(in: lib.assets).count == 12)
        let parents = RecurringPlaceAnswers().addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        let analysis = detector.analyse(in: lib.assets, places: parents)
        #expect(analysis.trips.isEmpty)
        #expect(Set(analysis.places.first?.assetIDs ?? []) == Set(garda))
        #expect(analysis.atHome.isDisjoint(with: garda))
        // Also with a home the user chose.
        let chosen = detector.analyse(in: lib.assets, places: parents,
                                      home: HomeSettings().choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now))
        #expect(chosen.trips.isEmpty)
        #expect(chosen.atHome.isDisjoint(with: garda))
    }

    /// A home the user chose wins over the detection: everyday life somewhere else then is away.
    @Test func chosenHomeWinsOverTheDetection() {
        let (lib, _) = munichLibrary()
        let settings = HomeSettings().choosing(HomePlace(center: Fixture.Places.gardaLake, components: nil), from: nil, date: now)
        let analysis = detector.analyse(in: lib.assets, home: settings)
        #expect(analysis.atHome.isEmpty)
        // The detected home is still Albumist's own finding, shown next to the choice.
        #expect(analysis.detectedHome.map { GeoMath.distance($0.center, Fixture.Places.munichHome) < 1_000 } == true)
    }

    @Test func noPhotosNoDetectedHome() {
        #expect(detector.analyse(in: []).detectedHome == nil)
    }
}

@Suite("Dein Zuhause: names and place albums")
struct HomeNamingTests {
    let labels = Labels(.german)
    let now = Fixture.date("2026-11-16")

    func place(_ region: String, _ town: String) -> PlaceComponents {
        PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: region, locality: town)
    }

    /// A weekend at two towns of one region: named after the region, except where that region
    /// is home at the trip's date.
    @Test func tripNamesUseTheHomeOfTheTripsTime() {
        let augsburg = place("Bayern", "Augsburg"), tegernsee = place("Bayern", "Tegernsee")
        let trip = [augsburg, augsburg, tegernsee, tegernsee]
        let settings = HomeSettings()
            .choosing(HomeAtDateTests.munich, from: nil, date: now)
            .addingFormer(FormerHome(place: HomeAtDateTests.hamburgHome, until: Fixture.date("2019-01-01")), date: now)
        let home = HomeContext(settings: settings)
        func name(at date: String) -> String? {
            ProposalEngine.primaryPlaceName(trip, kind: .weekendTrip, labels: labels, isHome: { home.isHome($0, at: Fixture.date(date)) }).0
        }
        // Living in Hamburg: Bavaria is somewhere else.
        #expect(name(at: "2018-06-01") == "Bayern")
        // Living in Munich: "Bayern" says nothing.
        #expect(name(at: "2020-06-01") == "Augsburg & Tegernsee")
        // Nothing set: the everyday places decide, as before.
        let everyday = LibraryProfile(everydayPlaces: [PlaceKey(level: .country, path: "de"), PlaceKey(level: .administrativeArea, path: "de/bayern")])
        #expect(ProposalEngine.primaryPlaceName(trip, kind: .weekendTrip, labels: labels,
                                                isHome: { HomeContext(profile: everyday).isHome($0, at: Fixture.date("2018-06-01")) }).0 == "Augsburg & Tegernsee")
        // "Kein Zuhause": no region is home.
        let none = HomeContext(settings: HomeSettings().withoutHome(date: now), profile: everyday)
        #expect(ProposalEngine.primaryPlaceName(trip, kind: .weekendTrip, labels: labels, isHome: { none.isHome($0, at: Fixture.date("2020-06-01")) }).0 == "Bayern")
    }

    /// The same through the suggestions (`tripProposals`): each trip is judged by the home at
    /// its start. A weekend in Nuremberg and Regensburg while living in Hamburg is "Bayern";
    /// the same weekend after the move to Munich is named after its towns.
    @Test func tripSuggestionsAreNamedWithTheHomeAtTheirStart() throws {
        let nuremberg = GeoCoordinate(latitude: 49.4521, longitude: 11.0767)
        let regensburg = GeoCoordinate(latitude: 49.0134, longitude: 12.1016)
        let table: [(GeoCoordinate, PlaceComponents)] = [
            (HomeAtDateTests.hamburg, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Hamburg", locality: "Hamburg")),
            (Fixture.Places.munichHome, place("Bayern", "München")),
            (nuremberg, place("Bayern", "Nürnberg")),
            (regensburg, place("Bayern", "Regensburg")),
        ]
        var lib = LibraryBuilder()
        lib.daily(from: "2017-01-01", to: "2018-12-31", at: HomeAtDateTests.hamburg, perDay: 2, hour: 19, skipping: [("2018-06-08", "2018-06-10")])
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19, skipping: [("2020-06-12", "2020-06-14")])
        for (start, end) in [("2018-06-08", "2018-06-09"), ("2020-06-12", "2020-06-13")] {
            lib.daily(from: start, to: start, at: nuremberg, perDay: 8, hour: 10)
            lib.daily(from: end, to: end, at: regensburg, perDay: 8, hour: 10)
        }
        let facts = lib.assets.map { a -> AssetFacts in
            guard let c = a.usableLocation else { return AssetFacts(asset: a) }
            let nearest = table.min { GeoMath.distance(c, $0.0) < GeoMath.distance(c, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
        let home = HomeSettings()
            .choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now)
            .addingFormer(FormerHome(place: HomePlace(center: HomeAtDateTests.hamburg, components: nil), until: Fixture.date("2019-01-01")), date: now)
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets, home: home)
        #expect(trips.count == 2)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.enabledAreas = [.trips]
        let titles = ProposalEngine(settings: settings, calendar: Fixture.calendar)
            .proposals(for: AnalysisSnapshot(facts: facts, trips: trips, home: home))
            .filter { $0.kind != .frequentPlace }
            .sorted { ($0.dateRange?.start ?? .distantPast) < ($1.dateRange?.start ?? .distantPast) }
            .map(\.title)
        #expect(titles.count == 2)
        #expect(titles.first?.hasPrefix("Bayern") == true)
        #expect(titles.last?.hasPrefix("Nürnberg & Regensburg") == true)
    }

    /// Living in Konstanz, with some everyday photos across the border in Kreuzlingen: inside
    /// the home radius, so Switzerland is home too while its photos are these everyday ones
    /// (no album "Schweiz" of the way to the supermarket). Trips to Zurich, further away and
    /// more photos than the everyday ones, give it its album again.
    @Test func aCountryAcrossTheBorderInsideTheHomeIsNoAlbum() {
        let konstanz = GeoCoordinate(latitude: 47.6603, longitude: 9.1758)
        let kreuzlingen = GeoCoordinate(latitude: 47.6505, longitude: 9.1750)
        let zurich = GeoCoordinate(latitude: 47.3769, longitude: 8.5417)
        let table: [(GeoCoordinate, PlaceComponents)] = [
            (konstanz, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Baden-Württemberg", locality: "Konstanz")),
            (kreuzlingen, PlaceComponents(isoCountryCode: "CH", country: "Schweiz", administrativeArea: "Thurgau", locality: "Kreuzlingen")),
            (zurich, PlaceComponents(isoCountryCode: "CH", country: "Schweiz", administrativeArea: "Zürich", locality: "Zürich")),
        ]
        func facts(_ lib: LibraryBuilder) -> [AssetFacts] {
            lib.assets.map { a in
                let c = a.usableLocation!
                let nearest = table.min { GeoMath.distance(c, $0.0) < GeoMath.distance(c, $1.0) }!
                return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
            }
        }
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2026-06-30", at: konstanz, perDay: 2, hour: 19)
        lib.daily(from: "2025-01-03", to: "2026-06-30", at: kreuzlingen, perDay: 1, everyNthDay: 9, hour: 11)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.enabledAreas = [.places, .trips]
        let engine = ProposalEngine(settings: settings, calendar: Fixture.calendar)
        let home = HomeSettings().choosing(HomePlace(center: konstanz, components: nil), from: nil, date: now)
        func titles(_ lib: LibraryBuilder) -> Set<String> {
            let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets, home: home)
            return Set(engine.proposals(for: AnalysisSnapshot(facts: facts(lib), trips: trips, home: home)).filter { $0.kind.area == .places }.map(\.title))
        }
        #expect(!titles(lib).contains("Schweiz"))
        var trips = lib
        for month in ["2025-03", "2025-07", "2025-10", "2026-02", "2026-05"] {
            trips.daily(from: "\(month)-10", to: "\(month)-14", at: zurich, perDay: 12, hour: 10)
        }
        #expect(titles(trips).contains("Schweiz"))
    }

    /// A Munich library with towns as albums: "München" is no album while Munich is home
    /// (detected or chosen), and is one with "Kein Zuhause".
    @Test func placeAlbumsOfTheHomeFollowTheSettings() {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        lib.daily(from: "2025-05-12", to: "2025-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.places.includesCities = true
        settings.enabledAreas = [.places, .trips]
        let engine = ProposalEngine(settings: settings, calendar: Fixture.calendar)
        func titles(_ home: HomeSettings) -> Set<String> {
            let analysis = TripDetector(calendar: Fixture.calendar).analyse(in: lib.assets, home: home)
            var facts = FixtureGeocoder.facts(for: lib.assets)
            for i in facts.indices { facts[i].atHome = analysis.atHome.contains(facts[i].id) }
            return Set(engine.proposals(for: AnalysisSnapshot(facts: facts, trips: analysis.trips, home: home)).filter { $0.kind.area == .places }.map(\.title))
        }
        let automatic = titles(HomeSettings())
        #expect(!automatic.contains("München"))
        #expect(!automatic.contains("Deutschland"))
        let chosen = titles(HomeSettings().choosing(HomeAtDateTests.munich, from: nil, date: now))
        #expect(chosen == automatic)
        // "Deutschland" holds the same photos as "München": the town is the album (curation rule 3).
        let none = titles(HomeSettings().withoutHome(date: now))
        #expect(none == automatic.union(["München"]))
    }

    @Test func homeNameComesFromThePhotosNearIt() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-01-20", at: Fixture.Places.munichHome, perDay: 2)
        lib.daily(from: "2026-02-01", to: "2026-02-05", at: Fixture.Places.rome, perDay: 2)
        let facts = FixtureGeocoder.facts(for: lib.assets)
        let components = HomeName.components(near: Fixture.Places.munichHome, facts: facts)
        #expect(HomeName(components) == HomeName(town: "München", region: "Bayern", country: "Deutschland"))
        // Offline: no town known, the region names it.
        let offline = facts.map { f -> AssetFacts in
            var f = f
            f.place = f.place.map { PlaceComponents(isoCountryCode: $0.isoCountryCode, country: $0.country, administrativeArea: $0.administrativeArea) }
            return f
        }
        #expect(HomeName(HomeName.components(near: Fixture.Places.munichHome, facts: offline)) == HomeName(region: "Bayern", country: "Deutschland"))
        #expect(HomeName.components(near: Fixture.Places.sydney, facts: facts) == nil)
    }
}

@Suite("Dein Zuhause: places to choose from")
struct HomeCandidateTests {
    @Test func townsOfTheLibraryMostDaysFirstAndSearchable() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1)
        lib.daily(from: "2026-05-01", to: "2026-05-06", at: Fixture.Places.rome, perDay: 4)
        lib.daily(from: "2026-06-01", to: "2026-06-01", at: Fixture.Places.florence, perDay: 9)
        let candidates = HomeCandidates.make(facts: FixtureGeocoder.facts(for: lib.assets), calendar: Fixture.calendar)
        // Florence: one day only, not offered.
        #expect(candidates.map(\.name.town) == ["München", "Rom"])
        #expect(GeoMath.distance(candidates[0].center, Fixture.Places.munichHome) < 200)
        #expect(candidates[0].photoDays == 90)
        #expect(candidates[0].homePlace.keys.contains(PlaceKey(level: .locality, path: "de/bayern/munchen")))
        #expect(HomeCandidates.filter(candidates, query: "munch").map(\.name.town) == ["München"])
        #expect(HomeCandidates.filter(candidates, query: "Italien").map(\.name.town) == ["Rom"])
        #expect(HomeCandidates.filter(candidates, query: " ").count == 2)
        #expect(HomeCandidates.filter(candidates, query: "Paris").isEmpty)
    }

    /// Without online place names (offline map only): the regions are the places.
    @Test func offlineTheRegionsAreOffered() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-01-10", at: Fixture.Places.munichHome, perDay: 1)
        let facts = lib.assets.map { AssetFacts(asset: $0, place: .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern"), placeSource: .gpsReverseGeocoded) }
        let candidates = HomeCandidates.make(facts: facts, calendar: Fixture.calendar)
        #expect(candidates.count == 1)
        #expect(candidates[0].name == HomeName(region: "Bayern", country: "Deutschland"))
        #expect(candidates[0].components.locality == nil)
    }

    /// Offline, "Bayern" holds the everyday photos in Munich and many days in Nuremberg and
    /// Würzburg: the region's place is where the photos are densest (Munich), not the median of
    /// all of them (near Nuremberg, 150 km away), so choosing it makes Munich home.
    @Test func aRegionIsPlacedWhereItsPhotosAreDensest() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-04-10", at: Fixture.Places.munichHome, perDay: 1)
        lib.daily(from: "2026-05-01", to: "2026-07-19", at: GeoCoordinate(latitude: 49.4521, longitude: 11.0767), perDay: 1)
        lib.daily(from: "2026-08-01", to: "2026-10-19", at: GeoCoordinate(latitude: 49.7913, longitude: 9.9534), perDay: 1)
        let facts = lib.assets.map { AssetFacts(asset: $0, place: .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern"), placeSource: .gpsReverseGeocoded) }
        let candidates = HomeCandidates.make(facts: facts, calendar: Fixture.calendar)
        #expect(candidates.count == 1)
        #expect(candidates[0].photoCount == lib.assets.count)
        #expect(GeoMath.distance(candidates[0].center, Fixture.Places.munichHome) < 1_000)
    }
}

@Suite("Dein Zuhause: search")
struct HomeSearchTests {
    /// "Ausland" is measured against the home of each photo's date, like trips and suggestions:
    /// Vienna until 2019, then Munich. A weekend in Munich in 2018 and one in Vienna in 2020 are
    /// abroad; the everyday photos of both homes are not.
    @Test func abroadFollowsTheHomeOfEachDate() {
        let vienna = GeoCoordinate(latitude: 48.2082, longitude: 16.3738)
        let table: [(GeoCoordinate, PlaceComponents)] = [
            (vienna, PlaceComponents(isoCountryCode: "AT", country: "Österreich", administrativeArea: "Wien", locality: "Wien")),
            (Fixture.Places.munichHome, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")),
            (Fixture.Places.rome, PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom")),
        ]
        var lib = LibraryBuilder()
        lib.daily(from: "2017-01-01", to: "2018-12-31", at: vienna, perDay: 1, hour: 19, skipping: [("2018-05-10", "2018-05-20"), ("2018-09-07", "2018-09-09")])
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 1, hour: 19, skipping: [("2020-05-10", "2020-05-20"), ("2020-09-11", "2020-09-13")])
        var away = lib.daily(from: "2018-05-12", to: "2018-05-18", at: Fixture.Places.rome, perDay: 6, hour: 10)
        away += lib.daily(from: "2020-05-12", to: "2020-05-18", at: Fixture.Places.rome, perDay: 6, hour: 10)
        away += lib.daily(from: "2018-09-07", to: "2018-09-09", at: Fixture.Places.munichHome, perDay: 6, hour: 11)
        away += lib.daily(from: "2020-09-11", to: "2020-09-13", at: vienna, perDay: 6, hour: 11)
        let facts = lib.assets.map { a -> AssetFacts in
            guard let c = a.usableLocation else { return AssetFacts(asset: a) }
            let nearest = table.min { GeoMath.distance(c, $0.0) < GeoMath.distance(c, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
        let now = Fixture.date("2026-11-16")
        let home = HomeSettings()
            .choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now)
            .addingFormer(FormerHome(place: HomePlace(center: vienna, components: nil), until: Fixture.date("2019-01-01")), date: now)
        let abroad = SearchIndex(facts: facts, home: home, calendar: Fixture.calendar).search("Ausland", now: now).ids
        #expect(Set(abroad) == Set(away))
        // Nothing set: the everyday countries, as for the suggestions (both hold a quarter of
        // the photos here); only Rome is abroad.
        let detected = SearchIndex(facts: facts, calendar: Fixture.calendar).search("Ausland", now: now).ids
        #expect(Set(detected) == Set(facts.filter { $0.gpsPlace?.isoCountryCode == "IT" }.map(\.id)))
        // "Kein Zuhause": the country with the most photos, as before this setting.
        let none = SearchIndex(facts: facts, home: HomeSettings().withoutHome(date: now), calendar: Fixture.calendar).search("Ausland", now: now).ids
        #expect(Set(none) == Set(facts.filter { $0.gpsPlace?.isoCountryCode != "DE" }.map(\.id)))
    }
}
