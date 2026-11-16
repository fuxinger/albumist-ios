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
            components: PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern")), date: now))
        let unnamed = titles(HomeSettings().choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), date: now))
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
        let countryUnnamed = countryTitles(HomeSettings().choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), date: now))
        #expect(countryUnnamed == countryAutomatic)
    }
}

@Suite("Review: a naive fix for Stimmt (confirm from `since`)")
struct HomeReviewNaiveFixTests {
    /// What a fix that confirms the home only from the detection's `since` would do: `since`
    /// lies two months before the real move (the 120-day window), so the last weeks in the old
    /// town would still be a trip. Emulated with the old home as a former home up to `since`.
    @Test func confirmingFromSinceAloneLeavesATripAtTheOldHome() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2017-01-01", to: "2018-12-31", at: HomeReviewCoreTests.hamburg, perDay: 2, hour: 19)
        lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let detected = try #require(detector.analyse(in: lib.assets).detectedHome)
        let since = try #require(detected.since)
        let now = Fixture.date("2026-11-16")
        let settings = HomeSettings().confirming(HomePlace(center: detected.center, components: nil), date: now)
            .addingFormer(FormerHome(place: HomePlace(center: HomeReviewCoreTests.hamburg, components: nil), until: since), date: now)
        let trips = detector.analyse(in: lib.assets, home: settings).trips
        #expect(trips.isEmpty)
    }
}
