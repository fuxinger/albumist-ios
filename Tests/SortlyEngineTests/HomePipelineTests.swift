import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// "Dein Zuhause" through the analysis: the settings are stored next to the other decisions
/// (`user.home`), kept by "Analyse neu aufbauen" and the backup copy, and a change only makes
/// the suggestions again (`resuggest`): no photo is read again, nothing changes in Photos, and
/// what the user already chose stays as it was.
@Suite("Dein Zuhause in the analysis")
struct HomePipelineTests {
    static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let answers = FakeGeocoder.defaultAnswers + [
        (hamburg, PlaceComponents(isoCountryCode: "DE", country: "Germany", administrativeArea: "Hamburg", locality: "Hamburg")),
    ]
    let now = Fixture.date("2026-11-16")

    struct Setup {
        var pipeline: AnalysisPipeline
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var analyzer: FakeContentAnalyzer
        var geocoder: FakeGeocoder
        var settings: OrganizationSettings
        var lib: LibraryBuilder
    }

    func setup(_ build: (inout LibraryBuilder) -> Void, inventory: CollectionInventory = CollectionInventory()) throws -> Setup {
        var lib = LibraryBuilder()
        build(&lib)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.privacy.allowOnlineGeocoding = true
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets, inventory: inventory)
        let analyzer = FakeContentAnalyzer()
        let geocoder = FakeGeocoder(answers: Self.answers)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: PipelineTests.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source,
            now: { Fixture.date("2026-11-16") }
        )
        return Setup(pipeline: pipeline, store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, settings: settings, lib: lib)
    }

    /// A year in Munich with four days at Lake Garda every month.
    static func gardaEveryMonth(_ lib: inout LibraryBuilder) -> [[AssetID]] {
        var stays: [(String, String)] = []
        for month in 1...12 { stays.append((String(format: "2026-%02d-05", month), String(format: "2026-%02d-08", month))) }
        lib.daily(from: "2026-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19, skipping: stays)
        return stays.prefix(10).map { lib.daily(from: $0.0, to: $0.1, at: Fixture.Places.gardaLake, perDay: 5, hour: 10) }
    }

    /// Everyday life in Munich and two Rome trips.
    static func munichAndRome(_ lib: inout LibraryBuilder) {
        lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2, hour: 19,
                  skipping: [("2025-05-11", "2025-05-20"), ("2026-04-01", "2026-04-07")])
        lib.daily(from: "2025-05-12", to: "2025-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        lib.daily(from: "2026-04-02", to: "2026-04-06", at: Fixture.Places.rome, perDay: 6, hour: 10)
    }

    // MARK: Stored

    /// Nothing stored (every version before this one): automatic. Stored, read back the same;
    /// kept by "Analyse neu aufbauen"; part of the decisions copy; the detected home is not.
    @Test func settingsAreStoredKeptByARebuildAndInTheBackup() async throws {
        let s = try setup(Self.munichAndRome)
        #expect(try await s.pipeline.homeSettings() == HomeSettings())
        _ = try await s.pipeline.run()
        let detected = try #require(try await s.pipeline.detectedHome())
        #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 1_000)

        let home = HomeSettings().confirming(HomePlace(center: detected.center, components: nil), date: now)
            .addingFormer(FormerHome(place: HomePlace(center: Self.hamburg, components: nil), until: Fixture.date("2025-01-01")), date: now)
        try await s.pipeline.setHomeSettings(home)
        #expect(try await s.pipeline.homeSettings() == home)

        let backup = try await s.store.safetyBackup()
        #expect(backup.values.contains { $0.key == "user.home" })
        #expect(!backup.values.contains { $0.key == "analysis.detectedHome" })
        let restored = try SortlyStore(url: nil)
        #expect(try await restored.restore(backup, includingLibraryState: false))
        #expect(try await restored.value(HomeSettings.self, forKey: "user.home") == home)

        try await s.store.resetAnalysis()
        #expect(try await s.pipeline.homeSettings() == home)
        #expect(try await s.pipeline.detectedHome() == nil)
        _ = try await s.pipeline.run()
        #expect(try await s.pipeline.detectedHome() != nil)
    }

    /// A value an older build of this feature wrote, with fields missing: read with defaults.
    @Test func olderStoredValueIsRead() async throws {
        let s = try setup(Self.munichAndRome)
        try await s.store.setValue(["mode": "none"], forKey: "user.home")
        #expect(try await s.pipeline.homeSettings().home(at: nil) == HomeAtDate.none)
    }

    // MARK: Only the suggestions

    /// The change is applied without reading Photos again: new photos in the library, or even
    /// photo access taken away, change nothing. No photo is analysed, no place looked up, no
    /// album touched; the suggestions and the at-home photos follow the new home at once.
    @Test func resuggestReadsNoPhotoAndTouchesNoAlbum() async throws {
        let album = CollectionSnapshot(id: CollectionID("album-rom"), title: "Rom")
        let s = try setup(Self.munichAndRome, inventory: CollectionInventory([album]))
        _ = try await s.pipeline.run()
        let before = try #require(try await s.pipeline.latestProposals())
        let analysed = s.analyzer.counts.withLock { $0 }
        let lookups = s.geocoder.calls.count
        let assets = try await s.store.allAssets()
        let storedInventory = try await s.store.loadInventory()
        let homeBefore = try #require(try await s.store.value(Set<AssetID>.self, forKey: "analysis.home"))
        #expect(!homeBefore.isEmpty)
        // An album Albumist made before ("Rom", from the first trip): its record must not change.
        let romeTrip = try #require(before.proposals.first { $0.kind == .trip })
        let managed = ManagedAlbumState(albumID: album.id, sourceID: romeTrip.id, lastKnownTitle: "Rom", lastKnownParentID: nil,
                                        lastKnownMembers: romeTrip.assetIDs, addedBySortly: romeTrip.assetIDs, createdBySortly: true)
        try await s.store.saveManagedAlbums([managed])
        let albumsInPhotos = try await s.reader.currentInventory()

        var later = s.lib
        later.daily(from: "2026-07-01", to: "2026-07-03", at: Fixture.Places.florence, perDay: 6)
        await s.reader.set(assets: later.assets)
        await s.reader.set(access: .denied)

        try await s.pipeline.setHomeSettings(HomeSettings().withoutHome(date: now))
        let notice = try #require(try await s.pipeline.resuggest())

        #expect(s.analyzer.counts.withLock { $0 } == analysed)
        #expect(s.geocoder.calls.count == lookups)
        #expect(try await s.store.allAssets() == assets)
        #expect(try await s.store.loadInventory() == storedInventory)
        // Nothing in Photos and no record of an album changed; no plan was made or run.
        #expect(try await s.reader.currentInventory() == albumsInPhotos)
        #expect(try await s.store.managedAlbums() == [managed])
        #expect(try await s.store.planHistory().isEmpty)
        #expect(try await s.store.unfinishedPlans().isEmpty)
        #expect(try await s.store.value(Set<AssetID>.self, forKey: "analysis.home") == [])
        let after = try #require(try await s.pipeline.latestProposals())
        #expect(after.generatedAt == now)
        // The trips are the same; with no home Munich is a place like any other: "Deutschland"
        // holds its photos now.
        let trips = before.proposals.filter { $0.kind == .trip }.map(\.id)
        #expect(trips.count == 2)
        #expect(after.proposals.filter { $0.kind == .trip }.map(\.id) == trips)
        #expect(after.proposals.contains { $0.title == "Deutschland" })
        #expect(!before.proposals.contains { $0.title == "Deutschland" })
        #expect(notice.added == 1)
        #expect(notice.held == 0)
        #expect(try await s.pipeline.homeChangeNotice() == notice)
    }

    /// No suggestions yet (the first analysis has not got there): nothing to make again, the
    /// next analysis applies the settings.
    @Test func withoutSuggestionsResuggestWaitsForTheAnalysis() async throws {
        let s = try setup(Self.munichAndRome)
        try await s.pipeline.setHomeSettings(HomeSettings().withoutHome(date: now))
        #expect(try await s.pipeline.resuggest() == nil)
        #expect(try await s.pipeline.latestProposals() == nil)
        _ = try await s.pipeline.run()
        #expect(try await s.store.value(Set<AssetID>.self, forKey: "analysis.home") == [])
    }

    /// The parents live at Lake Garda ("Eltern"): ten trips there become one album of the place.
    /// The trip the user had already chosen stays as chosen, here and in the next analysis,
    /// until it is deselected; the overview is told what went and what came.
    @Test func chosenSuggestionIsHeldAndTheOverviewIsTold() async throws {
        let s = try setup { lib in _ = Self.gardaEveryMonth(&lib) }
        _ = try await s.pipeline.run()
        let before = try #require(try await s.pipeline.latestProposals())
        let trips = before.proposals.filter { $0.kind == .trip }
        #expect(trips.count == 10)
        let chosen = trips[0]
        try await s.store.setValue([chosen.id: ProposalDecision.createNew(title: nil, folderPath: nil)], forKey: "user.decisions")

        let parents = try await s.pipeline.recurringPlaceAnswers()
            .addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        try await s.pipeline.setRecurringPlaceAnswers(parents)
        let notice = try #require(try await s.pipeline.resuggest())
        let after = try #require(try await s.pipeline.latestProposals())
        // The chosen trip is still there, exactly as chosen; the nine others are gone.
        #expect(after.proposals.first { $0.id == chosen.id } == chosen)
        #expect(after.proposals.filter { $0.kind == .trip }.map(\.id) == [chosen.id])
        let placeID = RecurringPlaces.proposalID(for: try #require(parents.places.first?.id))
        #expect(after.proposals.contains { $0.id == placeID })
        #expect(after.matches[chosen.id] != nil)
        // Nine trips, and "Italien", which holds the same photos as the place's album now.
        #expect(notice.removed == 10)
        #expect(!after.proposals.contains { $0.title == "Italien" })
        #expect(notice.held == 1)
        #expect(notice.added == 1)
        #expect(notice.removedTitles.count == 3)
        #expect(try await s.pipeline.homeChangeNotice() == notice)

        // The next analysis keeps it too.
        _ = try await s.pipeline.run()
        #expect(try await s.pipeline.latestProposals()?.proposals.first { $0.id == chosen.id } == chosen)
        // Deselected: let go.
        try await s.store.setValue([SortlyID: ProposalDecision](), forKey: "user.decisions")
        _ = try await s.pipeline.run()
        #expect(try await s.pipeline.latestProposals()?.proposals.contains { $0.id == chosen.id } == false)
        #expect(try await s.store.value([AlbumProposal].self, forKey: "user.heldSuggestions") == [])

        // OK on the card.
        try await s.pipeline.dismissHomeChangeNotice()
        #expect(try await s.pipeline.homeChangeNotice() == nil)
    }

    /// Changed and changed back before OK: nothing changed, nothing to say.
    @Test func changingBackLeavesNothingToSay() async throws {
        let s = try setup { lib in _ = Self.gardaEveryMonth(&lib) }
        _ = try await s.pipeline.run()
        let answers = try await s.pipeline.recurringPlaceAnswers()
        let parents = answers.addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        try await s.pipeline.setRecurringPlaceAnswers(parents)
        #expect(try await s.pipeline.resuggest()?.removed == 11)
        try await s.pipeline.setRecurringPlaceAnswers(parents.withdrawing(try #require(parents.places.first?.id), date: now))
        // Nothing to say: no notice, and none stored.
        #expect(try await s.pipeline.resuggest() == nil)
        #expect(try await s.pipeline.homeChangeNotice() == nil)
        #expect(try await s.pipeline.latestProposals()?.proposals.filter { $0.kind == .trip }.count == 10)
    }

    /// "Bis 2019: Hamburg": the weekend in Munich before the move becomes the trip it was.
    @Test func formerHomeBringsBackTheTripBeforeTheMove() async throws {
        var weekend: [AssetID] = []
        let s = try setup { lib in
            lib.daily(from: "2017-01-01", to: "2018-12-31", at: Self.hamburg, perDay: 2, hour: 19, skipping: [("2018-11-09", "2018-11-11")])
            weekend = lib.daily(from: "2018-11-09", to: "2018-11-11", at: Fixture.Places.munichHome, perDay: 4, hour: 11)
            lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        }
        _ = try await s.pipeline.run()
        #expect(try await s.pipeline.latestProposals()?.proposals.contains { $0.kind == .trip } == false)
        let home = HomeSettings().addingFormer(FormerHome(place: HomePlace(center: Self.hamburg, components: nil), until: Fixture.date("2019-01-01")), date: now)
        try await s.pipeline.setHomeSettings(home)
        let notice = try #require(try await s.pipeline.resuggest())
        #expect(notice.added >= 1)
        let trip = try #require(try await s.pipeline.latestProposals()?.proposals.first { $0.kind == .trip })
        #expect(trip.assetIDs == Set(weekend))
        #expect(trip.title.hasPrefix("München"))
    }

    // MARK: The ring

    /// The ring counts the photos at home of the home the user chose; with "Kein Zuhause" none.
    @Test func ringCountsTheHomeTheUserChose() async throws {
        let s = try setup(Self.munichAndRome)
        func homeCount() async throws -> Int {
            let facts = try await s.pipeline.currentFacts()
            let snapshot = try await s.pipeline.latestProposals()
            return LibraryStatus.computeWithReasons(facts: facts, snapshot: snapshot, settings: s.settings,
                                                    contentAnalyzed: Set(facts.map(\.id))).reasons.home
        }
        _ = try await s.pipeline.run()
        let automatic = try await homeCount()
        #expect(automatic > 0)
        let detected = try #require(try await s.pipeline.detectedHome())
        let facts = try await s.pipeline.currentFacts()

        // "Stimmt", the way the settings do it: the detected home with its name from the photos.
        let confirmed = HomePlace(center: detected.center, components: HomeName.components(near: detected.center, facts: facts))
        #expect(HomeName(confirmed.components).town == "München")
        try await s.pipeline.setHomeSettings(HomeSettings().choosing(confirmed, from: nil, date: now))
        _ = try await s.pipeline.resuggest()
        #expect(try await homeCount() == automatic)

        try await s.pipeline.setHomeSettings(HomeSettings().withoutHome(date: now))
        _ = try await s.pipeline.resuggest()
        #expect(try await homeCount() == 0)

        // Rome as home (made up, to see the rule): the Rome photos are the home photos now.
        let rome = facts.filter { $0.asset.usableLocation.map { GeoMath.distance($0, Fixture.Places.rome) < 30_000 } ?? false }
        let romeHome = HomePlace(center: Fixture.Places.rome, components: HomeName.components(near: Fixture.Places.rome, facts: facts))
        try await s.pipeline.setHomeSettings(HomeSettings().choosing(romeHome, from: nil, date: now))
        _ = try await s.pipeline.resuggest()
        #expect(try await homeCount() == rome.count)
    }
}
