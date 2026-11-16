import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Second review of "Dein Zuhause" (16.11.): the scenarios of its findings, kept as tests.
@Suite("Review: Dein Zuhause core")
struct HomeReviewCoreTests {
    let now = Fixture.date("2026-11-16")
    static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)

    /// The user lived in Hamburg 2017–2018 and moved to Munich. The detection knows that
    /// (`since` is set) and finds no trip. "Stimmt" (AppModel.confirmDetectedHome stores the
    /// detected place with no date) should change nothing, like the branch's own test claims.
    @Test func stimmtAfterAMoveChangesNothing() throws {
        var lib = LibraryBuilder()
        let hamburgPhotos = lib.daily(from: "2017-01-01", to: "2018-12-31", at: Self.hamburg, perDay: 2, hour: 19)
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let automatic = detector.analyse(in: lib.assets)
        let detected = try #require(automatic.detectedHome)
        #expect(detected.since != nil)
        #expect(automatic.trips.isEmpty)
        let confirmed = detector.analyse(in: lib.assets, home: HomeSettings().confirming(HomePlace(center: detected.center, components: nil), date: now))
        let onTrips = Set(confirmed.trips.flatMap(\.geotaggedAssetIDs))
        #expect(confirmed.trips.isEmpty)
        #expect(confirmed.atHome == automatic.atHome)
    }

    /// The same library of the branch's test `placeAlbumsOfTheHomeFollowTheSettings`, with the
    /// home chosen while its town was not named yet (offline: region only, or no name at all,
    /// which "Stimmt" stores when no photo near the detected home has a place yet).
    @Test func chosenHomeWithoutItsTownNameKeepsTheHomeOutOfPlaceAlbums() {
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
        // Picked under "Ändern" (for all time): "Stimmt" holds only from now on and would leave
        // these photos to the detection.
        let regionOnly = titles(HomeSettings().choosing(HomePlace(center: Fixture.Places.munichHome,
            components: PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern")), from: nil, date: now))
        let unnamed = titles(HomeSettings().choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now))
        #expect(regionOnly == automatic)
        #expect(unnamed == automatic)

        // Default settings (countries only): the unnamed home makes "Deutschland" an album.
        var countries = OrganizationSettings()
        countries.titleLanguage = .german
        countries.enabledAreas = [.places, .trips]
        let countryEngine = ProposalEngine(settings: countries, calendar: Fixture.calendar)
        func countryTitles(_ home: HomeSettings) -> Set<String> {
            let analysis = TripDetector(calendar: Fixture.calendar).analyse(in: lib.assets, home: home)
            var facts = FixtureGeocoder.facts(for: lib.assets)
            for i in facts.indices { facts[i].atHome = analysis.atHome.contains(facts[i].id) }
            return Set(countryEngine.proposals(for: AnalysisSnapshot(facts: facts, trips: analysis.trips, home: home)).filter { $0.kind.area == .places }.map(\.title))
        }
        let countryAutomatic = countryTitles(HomeSettings())
        let countryUnnamed = countryTitles(HomeSettings().choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now))
        #expect(countryUnnamed == countryAutomatic)
    }
}

@Suite("Review: why a confirmation does not start at the detected `since`")
struct HomeReviewNaiveFixTests {
    /// The detection's `since` lies two months before the real move (its 120-day window).
    /// Holding the new home from `since` would make the last weeks in the old town a trip; the
    /// rules used instead ("Stimmt" from the confirmation, "Ändern" from the start of the stay
    /// near the place, `HomeCandidates.stayStart`) leave none.
    @Test func confirmingFromTheDetectedSinceWouldMakeTheLastWeeksATrip() throws {
        var lib = LibraryBuilder()
        let hamburg = lib.daily(from: "2017-01-01", to: "2018-12-31", at: HomeReviewCoreTests.hamburg, perDay: 2, hour: 19)
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let detected = try #require(detector.analyse(in: lib.assets).detectedHome)
        let since = try #require(detected.since)
        #expect(since < Fixture.date("2019-01-01"))
        let now = Fixture.date("2026-11-16")
        let munich = HomePlace(center: detected.center, components: nil)
        let fromSince = HomeSettings().choosing(munich, from: since, date: now)
        let tripsFromSince = detector.analyse(in: lib.assets, home: fromSince).trips
        #expect(!tripsFromSince.isEmpty)
        #expect(!Set(tripsFromSince.flatMap(\.geotaggedAssetIDs)).isDisjoint(with: hamburg))
        // The rules in use.
        let stay = try #require(HomeCandidates.stayStart(near: detected.center, assets: lib.assets, calendar: Fixture.calendar))
        #expect(stay == Fixture.date("2019-01-01"))
        #expect(detector.analyse(in: lib.assets, home: HomeSettings().choosing(munich, from: stay, date: now)).trips.isEmpty)
        #expect(detector.analyse(in: lib.assets, home: HomeSettings().confirming(munich, date: now)).trips.isEmpty)
    }
}
