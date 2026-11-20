import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// The numbers of the overview's first card agree with each other and with the analysis card
/// below it (review P3-03 of 18.11.2026; the ring and the library's lists already agree,
/// P1-05/P1-06). Counted the way `AppModel.refreshDerived` counts, after a real analysis, and
/// shown the way `OverviewView` shows it (`SortedCountCard`).
///
/// Found on the screens of the review: "82 von 176 sortiert", "57 Fotos von zu Hause" and "Alle
/// 246 Fotos analysiert" on one screen, 13 photos without a place said nowhere; "0 von 0
/// sortiert, 0 %" while the analysis ran again after the decisions came back from the backup.
@Suite("Overview numbers agree")
struct OverviewNumbersTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    static let basel = GeoCoordinate(latitude: 47.5596, longitude: 7.5886)
    static let salzburg = GeoCoordinate(latitude: 47.8095, longitude: 13.0550)
    static let today = Fixture.date("2026-11-18 06:00")

    struct World {
        var store: SortlyStore
        var pipeline: AnalysisPipeline
        var settings: OrganizationSettings
        /// Munich, every day of 2026 until June, and twenty days of September 2025.
        var home: [AssetID]
        var homeEarlier: [AssetID]
        /// A week in Rome, all of it in the user's album "Rom": sorted.
        var rome: [AssetID]
        /// Six days in Basel, no album yet: open.
        var basel: [AssetID]
        /// One afternoon in Salzburg: too few photos for an album of their own.
        var salzburg: [AssetID]
        /// Pictures saved from a messenger and screenshots: no place.
        var noPlace: [AssetID]

        /// What `AppModel.refreshDerived` derives. `suggestions: false`: as before the first
        /// suggestions of a run exist (a new database: first start, or after the decisions came
        /// back from the backup).
        func derived(scope: OrganizationScope = .all, suggestions: Bool = true) async throws -> DerivedLibraryStatus {
            DerivedLibraryStatus.derive(
                facts: try await pipeline.currentFacts(), snapshot: suggestions ? try await pipeline.latestProposals() : nil,
                settings: settings, overrides: OverrideSet(try await store.overrides()),
                contents: try await store.results(ContentAnalysis.self, kind: "content"),
                managed: [], inventory: try await store.loadInventory(), scope: scope, calendar: Fixture.calendar)
        }

        func ignore(_ ids: [AssetID]) async throws {
            for id in ids { try await store.addOverride(UserOverride(scope: .asset(id), decision: .ignoreAsset)) }
        }

        func exclude(_ ids: [AssetID]) async throws {
            for id in ids { try await store.addOverride(UserOverride(scope: .asset(id), decision: .excludeFromAnalysis)) }
        }
    }

    static func germanSettings() -> OrganizationSettings {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        return settings
    }

    func world(settings: OrganizationSettings = germanSettings(), scope: OrganizationScope = .all) async throws -> World {
        var lib = LibraryBuilder()
        let homeEarlier = lib.daily(from: "2025-09-01", to: "2025-09-20", at: Fixture.Places.munichHome, perDay: 1)
        let home = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                             skipping: [("2026-05-12", "2026-05-19"), ("2026-03-10", "2026-03-15")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let basel = lib.daily(from: "2026-03-10", to: "2026-03-15", at: Self.basel, perDay: 3, hour: 11)
        let salzburg = lib.daily(from: "2026-04-18", to: "2026-04-18", at: Self.salzburg, perDay: 6, hour: 14)
        var noPlace: [AssetID] = []
        for day in 1...8 { noPlace.append(lib.photo(at: Fixture.date(String(format: "2026-02-%02d 09:00", day)), nil)) }
        for day in 1...5 {
            noPlace.append(lib.photo(at: Fixture.date(String(format: "2026-06-%02d 18:00", day)), nil, subtypes: .screenshot))
        }
        let store = try SortlyStore(url: nil)
        let albums = [CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(rome))]
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets, inventory: CollectionInventory(albums)),
            analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(),
            settings: settings, calendar: Fixture.calendar, time: ManualTime().source, now: { Self.today }
        )
        #expect(try await pipeline.run(scope: scope).isComplete)
        return World(store: store, pipeline: pipeline, settings: settings, home: home, homeEarlier: homeEarlier, rome: rome,
                     basel: basel, salzburg: salzburg, noPlace: noPlace)
    }

    /// The card as the overview shows it once the analysis went through.
    static func card(_ d: DerivedLibraryStatus, _ settings: OrganizationSettings, running: Bool = false) -> SortedCountCard {
        SortedCountCard.make(.init(progress: d.progress, leftOut: d.leftOut, settings: settings, hasSuggestions: true,
                                   analysisRunning: running, analysedOnce: true))
    }

    static func line(_ d: DerivedLibraryStatus) -> String {
        let p = d.progress
        return "\(p.fully) von \(p.total) sortiert, nicht mitgezählt \(p.outsideMainAreas) (zu Hause \(d.leftOut.home), "
            + "kein Album \(d.leftOut.noAlbum)), ignoriert \(p.ignored), Fotos \(d.photos)"
    }

    // MARK: - Every photo of "Alle N Fotos analysiert" is in the ring or named once

    /// "82 von 176 sortiert" and "Außerdem nicht mitgezählt: 57 Fotos von zu Hause" next to "Alle
    /// 246 Fotos analysiert": the 13 photos without a place were said nowhere. Now the ring's
    /// total and the groups it leaves out add up to the analysis card's number, also for
    /// "Nur 2026" and with ignored photos.
    @Test(arguments: [OrganizationScope.all, .year(2026)])
    func theRingAndWhatItLeavesOutAddUpToThePhotosAnalysed(scope: OrganizationScope) async throws {
        let w = try await world()
        try await w.ignore(Array(w.basel.prefix(3)))
        let d = try await w.derived(scope: scope)
        guard case .ring(let ring) = Self.card(d, w.settings) else {
            Issue.record("no ring: \(Self.card(d, w.settings)); \(Self.line(d))")
            return
        }
        // `photos` is the number of "Alle 246 Fotos analysiert" / "240 von 246 Fotos analysiert".
        #expect(ring.total + ring.notCounted.sum == d.photos,
                "\(ring.total) counted + \(ring.notCounted.sum) left out != \(d.photos) photos; \(Self.line(d))")
        #expect(ring.fully == w.rome.count)
        #expect(ring.notCounted.noMainArea == w.noPlace.count, "\(ring.notCounted)")
        #expect(ring.notCounted.noMainAreaIsNoPlace, "with \"Länder und Orte\" counted they are photos without a place")
        #expect(ring.notCounted.noAlbum == w.salzburg.count, "\(ring.notCounted)")
        #expect(ring.notCounted.ignored == 3)
        #expect(ring.notCounted.home == w.home.count + (scope == .all ? w.homeEarlier.count : 0), "\(ring.notCounted)")
    }

    /// With "Reisen" as the only main area, a photo from home has a place but fits no main
    /// area: the group is not called "ohne Ort" then, and the numbers still add up.
    @Test func withoutCountriesAsAMainAreaTheRestIsNotCalledWithoutAPlace() async throws {
        var settings = Self.germanSettings()
        settings.primaryAreas = [.trips]
        let w = try await world(settings: settings)
        let d = try await w.derived()
        guard case .ring(let ring) = Self.card(d, settings) else {
            Issue.record("no ring: \(Self.card(d, settings)); \(Self.line(d))")
            return
        }
        #expect(ring.total + ring.notCounted.sum == d.photos, "\(ring.notCounted); \(Self.line(d))")
        #expect(ring.notCounted.noMainArea >= w.home.count + w.noPlace.count, "\(ring.notCounted)")
        #expect(!ring.notCounted.noMainAreaIsNoPlace, "photos from home have a place")
    }

    /// Photos excluded from the analysis are a group of their own (no switch in the app today,
    /// but the numbers must add up then too). A photo both ignored and excluded is in it once:
    /// excluded comes first (`OrganizationStatusResolver.areaStatus`), never in both groups.
    @Test func excludedPhotosAreOneGroupAlsoWhenIgnoredToo() async throws {
        let w = try await world()
        let both = w.rome[0]
        try await w.ignore([both] + Array(w.basel.prefix(2)))
        try await w.exclude([both, w.basel[5], w.home[0], w.noPlace[0]])
        let d = try await w.derived()
        guard case .ring(let ring) = Self.card(d, w.settings) else {
            Issue.record("no ring: \(Self.card(d, w.settings)); \(Self.line(d))")
            return
        }
        #expect(ring.total + ring.notCounted.sum == d.photos, "\(ring.total) counted, \(ring.notCounted); \(Self.line(d))")
        #expect(ring.notCounted.excluded == 4, "\(ring.notCounted)")
        #expect(ring.notCounted.ignored == 2, "the photo ignored and excluded counts once, as excluded: \(ring.notCounted)")
        #expect(ring.fully == w.rome.count - 1)
        #expect(ring.total == w.rome.count - 1 + w.basel.count - 3, "\(Self.line(d))")
        #expect(ring.notCounted.home == w.home.count + w.homeEarlier.count - 1, "\(ring.notCounted)")
        #expect(ring.notCounted.noMainArea == w.noPlace.count - 1, "\(ring.notCounted)")
        #expect(ring.notCounted.groups.contains(.excluded(4)), "\(ring.notCounted.groups)")
    }

    /// The overview names the groups in this order: "57 Fotos von zu Hause, 13 Fotos ohne Ort, 3
    /// ignorierte Fotos, 1 ausgeschlossenes Foto und 6 Fotos, für die sich kein eigenes Album
    /// lohnt." The one group said with a relative clause is last, where the period closes it;
    /// before "und" the clause stayed open ("…, 6 Fotos, für die sich kein eigenes Album lohnt und
    /// 13 Fotos ohne Ort.", second review of P3-03). Empty groups are not named.
    @Test func theGroupSaidWithAClauseComesLast() {
        for mask in 1..<32 {
            let n = { (bit: Int, value: Int) in mask & (1 << bit) != 0 ? value : 0 }
            let notCounted = SortedCountCard.NotCounted(home: n(0, 57), noAlbum: n(1, 6), noMainArea: n(2, 13), ignored: n(3, 3),
                                                        excluded: n(4, 1))
            let groups = notCounted.groups
            #expect(groups.map(\.count).reduce(0, +) == notCounted.sum, "\(groups)")
            #expect(!groups.contains { $0.count == 0 }, "\(groups)")
            if notCounted.noAlbum > 0 {
                #expect(groups.last == .noAlbum(6), "mask \(mask): \(groups)")
            }
            let order = groups.map { group -> Int in
                switch group {
                case .home: 0
                case .noMainArea: 1
                case .ignored: 2
                case .excluded: 3
                case .noAlbum: 4
                }
            }
            #expect(order == order.sorted(), "mask \(mask): \(groups)")
        }
    }

    // MARK: - Never "0 von 0 sortiert"

    /// After the decisions came back from the backup (`RestoredFromBackupCard`, UI test 4,
    /// screenshot 40-restored-card) the database is new and the analysis runs again: the ring said
    /// "0 von 0 sortiert, 0 %", and once the library was read "0 von N": without suggestions no
    /// photo can count as sorted yet (an own album counts through the suggestion it fits). The
    /// same on the first start and after "Analyse neu aufbauen" with nothing counted before.
    @Test func whileTheAnalysisRunsAgainThereIsNoCountYetNotZeroOfZero() async throws {
        let settings = Self.germanSettings()
        let restored = SortedCountCard.make(.init(progress: .init(), settings: settings, hasSuggestions: false,
                                                  analysisRunning: true, analysedOnce: false))
        #expect(restored == .counting, "\(restored)")
        // The library is read, the first suggestions are not made yet: "0 von N" is no count.
        let w = try await world()
        let read = try await w.derived(suggestions: false)
        #expect(read.progress.total > 0 && read.progress.fully == 0, "\(Self.line(read))")
        for (running, paused) in [(true, false), (false, true), (false, false)] {
            let card = SortedCountCard.make(.init(progress: read.progress, leftOut: read.leftOut, settings: settings,
                                                  hasSuggestions: false, analysisRunning: running, analysisPaused: paused,
                                                  analysedOnce: false))
            // The spinner only while the analysis runs (`notCountedYetWhileTheAnalysisDoesNotRun`).
            #expect(card == (running ? .counting : .notCountedYet), "running \(running), paused \(paused): \(card)")
        }
        // The first suggestions (the early set of trips and places, minutes into a first run):
        // the count is shown while the run goes on.
        let first = try await w.derived()
        let shown = SortedCountCard.make(.init(progress: first.progress, leftOut: first.leftOut, settings: settings,
                                               hasSuggestions: true, analysisRunning: true, analysedOnce: false))
        guard case .ring(let ring) = shown else {
            Issue.record("no ring once the suggestions exist: \(shown)")
            return
        }
        #expect(ring.fully == w.rome.count)
        // "Analyse neu aufbauen" with a count on screen holds it, as before.
        let held = RecountState(fully: 32, total: 50)
        let rebuilding = SortedCountCard.make(.init(progress: .init(), recount: held, settings: settings, hasSuggestions: false,
                                                    analysisRunning: true, analysedOnce: false))
        #expect(rebuilding == .recounting(held))
    }

    /// Every photo the ring would count is ignored (question for Fuchs, 18.11.: "0 von 0
    /// sortiert, 0 %" or a text?): nothing is left to sort, and the card says so with what it
    /// leaves out. A check for new photos does not turn it into "Wird gezählt".
    @Test func everyCountedPhotoIgnoredIsNothingToSortNotZeroOfZero() async throws {
        let w = try await world()
        try await w.ignore(w.rome + w.basel)
        let d = try await w.derived()
        #expect(d.progress.total == 0, "\(Self.line(d))")
        let card = Self.card(d, w.settings)
        guard case .nothingToSort(let notCounted) = card else {
            Issue.record("\(card); \(Self.line(d))")
            return
        }
        #expect(notCounted.ignored == w.rome.count + w.basel.count)
        #expect(notCounted.sum == d.photos, "\(notCounted); \(Self.line(d))")
        #expect(Self.card(d, w.settings, running: true) == card)
    }

    /// Before the first suggestions, the first card turns a spinner ("Wird gezählt") only while
    /// the analysis works. Paused by the user (also after a new launch), waiting for the device or
    /// for Photos, pausing, ended early or on an error: "Noch nicht gezählt", without a spinner.
    /// Before, "Wird gezählt" turned for as long as a pause lasted, right above the paused
    /// analysis card (second review of P3-03).
    @Test func notCountedYetWhileTheAnalysisDoesNotRun() async throws {
        let w = try await world()
        let read = try await w.derived(suggestions: false)
        for (what, running, paused, analysisCard) in Self.working + Self.standing {
            let shown = SortedCountCard.make(.init(
                progress: read.progress, leftOut: read.leftOut, settings: w.settings, hasSuggestions: false,
                analysisRunning: running, analysisPaused: paused, analysedOnce: false, analysisCard: analysisCard))
            let works = Self.working.contains { $0.what == what }
            #expect(shown == (works ? .counting : .notCountedYet), "\(what): \(shown)")
        }
    }

    /// The same for a count held while it is made anew ("Analyse neu aufbauen", photos waiting
    /// for their labels): "Wird neu gezählt" turns only while the analysis works. The hold ends
    /// only with new suggestions or a run that went through (`RecountState.next`), so a Pause
    /// kept the spinner turning beside "Zuletzt 82 von 176 sortiert" for as long as it lasted.
    /// Now the held count stands still: "Zuletzt 82 von 176 sortiert. Wird weitergezählt,
    /// sobald die Analyse weiterläuft." (third look at P3-03).
    @Test func aHeldCountStandsStillWhileTheAnalysisDoesNotWork() {
        for held in [RecountState(fully: 82, total: 176), RecountState(fully: 82, total: 176, labels: true)] {
            for (what, running, paused, analysisCard) in Self.working + Self.standing {
                for once in [false, true] {
                    let shown = SortedCountCard.make(.init(
                        progress: .init(), recount: held, settings: Self.germanSettings(), hasSuggestions: false,
                        analysisRunning: running, analysisPaused: paused, analysedOnce: once, analysisCard: analysisCard))
                    let works = Self.working.contains { $0.what == what }
                    #expect(shown == (works ? .recounting(held) : .recountWaiting(held)),
                            "\(what), labels \(held.isForLabels), analysed once \(once): \(shown)")
                }
            }
        }
    }

    /// The analysis works: it runs, and its card says so (or is not drawn yet).
    static let working: [(what: String, running: Bool, paused: Bool, card: AnalysisCardState?)] = [
        ("running", true, false, .running(nil, slower: nil, appleWait: false, catchingUp: nil)),
        ("running slower, after a pause", true, true, .running(nil, slower: .warm, appleWait: false, catchingUp: nil)),
        ("running, card not drawn yet", true, false, nil),
    ]

    /// The analysis does not work: paused by the user (also after a new launch), pausing, waiting
    /// for the device or for Photos, ended early or on an error.
    static let standing: [(what: String, running: Bool, paused: Bool, card: AnalysisCardState?)] = [
        ("paused by the user", false, true, .paused(nil)),
        ("paused, after a new launch", false, false, .paused(nil)),
        ("pausing", true, false, .pausing(nil, longer: false)),
        ("waiting for the device to cool", true, false, .waiting(.cooling, nil)),
        ("waiting to charge", true, false, .waiting(.charging, nil)),
        ("Photos does not answer, still running", true, false, .waiting(.photos, nil)),
        ("Photos did not answer, next try later", false, true, .waiting(.photos, nil)),
        ("Albumist was busy, next try later", false, true, .waiting(.busy, nil)),
        ("ended early, goes on at the next start", false, true, nil),
        ("ended on an error", false, false, nil),
    ]

    /// The states of the analysis the overview can meet: whether it runs, the "paused" fact of
    /// `EmptyLibraryState` (the last report paused, or a run that goes on by itself; a run that
    /// goes on after a Pause still has the paused report), whether it went through once, and
    /// what its card shows (`AnalysisCardState.resolve`: waiting for the device, pausing and the
    /// running card only while it runs; paused, busy and finished only after it ended).
    static let situations: [(running: Bool, paused: Bool, once: Bool, card: AnalysisCardState?)] = {
        let running = AnalysisCardState.running(nil, slower: nil, appleWait: false, catchingUp: nil)
        var all: [(running: Bool, paused: Bool, once: Bool, card: AnalysisCardState?)] = []
        for once in [false, true] {
            for paused in [false, true] {
                var whileRunning: [AnalysisCardState?] = [nil, running, .pausing(nil, longer: false), .waiting(.cooling, nil),
                                                          .waiting(.charging, nil), .waiting(.photos, nil)]
                if once { whileRunning.append(.quickCheck(showsPause: false)) }
                for card in whileRunning { all.append((true, paused, once, card)) }
                for card: AnalysisCardState? in [nil, .paused(nil), .waiting(.photos, nil), .waiting(.busy, nil)] {
                    all.append((false, paused, once, card))
                }
            }
        }
        all.append((false, false, true, .finished(photos: 300, proposals: 3)))
        return all
    }()

    /// In every state the overview can meet: never "0 von 0 sortiert" (the card for an empty
    /// library explains it, `EmptyLibraryState`, or the first card has no ring); once the
    /// analysis went through never "Wird gezählt" or "Noch nicht gezählt" (no spinner that turns
    /// for good); the spinner only while the analysis works, and "Noch nicht gezählt" only while
    /// it does not. Suggestions exist exactly when the analysis made some (`AppModel.proposals`).
    @Test func theOverviewNeverSaysZeroOfZero() {
        var problems: [String] = []
        var seen: Set<String> = []
        for photos in [0, 4, 300] {
            for total in Set([0, photos / 2, photos]).sorted() {
                for proposals in [0, 3] {
                    for s in Self.situations {
                        for held in [nil, RecountState(fully: 3, total: 9)] {
                            var progress = OrganizationStatusResolver.Progress()
                            progress.total = total
                            progress.unorganized = total
                            progress.outsideMainAreas = photos - total
                            let empty = EmptyLibraryState.evaluate(.init(
                                photos: photos, photosWithPlace: photos, proposals: proposals, analysisRunning: s.running,
                                analysisPaused: s.paused, analysedOnce: s.once, recounting: held != nil))
                            guard empty == nil else { continue }
                            let input = SortedCountCard.Input(
                                progress: progress, recount: held, settings: Self.germanSettings(), hasSuggestions: proposals > 0,
                                analysisRunning: s.running, analysisPaused: s.paused, analysedOnce: s.once, analysisCard: s.card)
                            let card = SortedCountCard.make(input)
                            let state = "photos \(photos), total \(total), proposals \(proposals), running \(s.running), "
                                + "paused \(s.paused), analysed once \(s.once), card \(String(describing: s.card)): \(card)"
                            seen.insert(String(describing: card).prefix { $0 != "(" }.description)
                            if case .ring(let ring) = card, ring.total == 0 { problems.append("0 von 0 · " + state) }
                            let wentThrough = !s.running && !s.paused && s.once
                            if wentThrough && (card == .counting || card == .notCountedYet) {
                                problems.append("no count after the analysis went through · " + state)
                            }
                            if Self.spins(card) && !input.analysisWorks { problems.append("spinner while not working · " + state) }
                            if Self.standsStill(card) && input.analysisWorks { problems.append("no spinner while working · " + state) }
                        }
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) states, e.g. \(problems.prefix(3))")
        // The grid reaches every card the overview can show here (no main area is another test).
        #expect(seen.isSuperset(of: ["counting", "notCountedYet", "recounting", "recountWaiting", "nothingToSort", "ring"]),
                "\(seen.sorted())")
    }

    /// The cards with a spinner ("Wird gezählt", "Wird neu gezählt").
    static func spins(_ card: SortedCountCard) -> Bool {
        switch card {
        case .counting, .recounting: true
        case .notCountedYet, .recountWaiting, .noMainAreaChosen, .nothingToSort, .ring: false
        }
    }

    /// The cards that say a count waits for the analysis, without a spinner.
    static func standsStill(_ card: SortedCountCard) -> Bool {
        switch card {
        case .notCountedYet, .recountWaiting: true
        case .counting, .recounting, .noMainAreaChosen, .nothingToSort, .ring: false
        }
    }

    // MARK: - The main areas the sentence names are the ones that count

    /// The start lets the user turn "Länder und Orte" and "Reisen" off, but they stay the main
    /// areas: the ring counted every photo as open for good ("0 von 300 sortiert"), and "Gezählt
    /// werden nur Fotos, die zu deinen Hauptbereichen passen" named the two areas that were off.
    /// With no main area turned on, the card says so instead of a ring that can never move.
    @Test func withNoMainAreaOnTheCardHasNoRing() async throws {
        var settings = Self.germanSettings()
        settings.enabledAreas = [.screenshots, .imageCategories]
        #expect(settings.primaryAreas == [.places, .trips])
        let w = try await world(settings: settings)
        let d = try await w.derived()
        #expect(d.progress.fully == 0 && d.progress.total == d.photos, "\(Self.line(d))")
        #expect(SortedCountCard.countedAreas(settings).isEmpty)
        #expect(Self.card(d, settings) == .noMainAreaChosen)
        // None chosen in the settings ("Zählt als sortiert" all off).
        var noneChosen = Self.germanSettings()
        noneChosen.primaryAreas = []
        #expect(SortedCountCard.countedAreas(noneChosen).isEmpty)
        #expect(Self.card(d, noneChosen) == .noMainAreaChosen)
    }

    @Test func theSentenceNamesOnlyTheMainAreasThatAreOn() {
        var settings = OrganizationSettings()
        #expect(SortedCountCard.countedAreas(settings) == [.places, .trips])
        settings.enabledAreas.remove(.trips)
        #expect(SortedCountCard.countedAreas(settings) == [.places])
    }

    // MARK: - The overview shows what is decided here

    /// The overview draws the card `SortedCountCard.make` decides, with the same three facts
    /// about the analysis as the card for an empty library (`EmptyLibraryCard.state(for:)`):
    /// `theOverviewNeverSaysZeroOfZero` holds only while both read them alike. Its numbers come
    /// from the card's values, no longer from `model.progress` and `model.leftOut` worked out in
    /// the view (that is how the photos without a place went unsaid). The card for limited
    /// access names the photos Albumist sees, not the ring's: with "Nur 2026" those were only
    /// the photos of 2026 ("sieht nur die 12 Fotos" of 40 shared). The App does not build on
    /// Linux, so its code is read (`AppSource`).
    @Test func theOverviewShowsTheCardDecidedHere() throws {
        let overview = try AppSource.read("App/Sortly/Views/OverviewView.swift")
        let emptyCard = try AppSource.read("App/Sortly/Views/EmptyLibraryCard.swift")
        let made = AppSource.calls(of: "SortedCountCard.make(", in: overview)
        let evaluated = AppSource.calls(of: "EmptyLibraryState.evaluate(", in: emptyCard)
        #expect(made.count == 1, "\(made)")
        #expect(evaluated.count == 1, "\(evaluated)")
        let card = Self.labelled(made.first ?? ""), empty = Self.labelled(evaluated.first ?? "")
        for label in ["analysisRunning", "analysisPaused", "analysedOnce"] {
            #expect(card[label] != nil && card[label] == empty[label],
                    "\(label): \(card[label] ?? "missing") here, \(empty[label] ?? "missing") for the empty library")
        }
        // The spinner follows the analysis card below (`Input.analysisWorks`).
        #expect(card["analysisCard"] == "model.analysisCard", "\(card["analysisCard"] ?? "missing")")
        let status = AppSource.code(AppSource.body(of: "private var statusCard", in: overview) ?? "")
        #expect(status.contains("switch sortedCount"), "the first card does not show `SortedCountCard`")
        for own in ["model.progress", "model.leftOut"] {
            #expect(!status.contains(own), "the first card reads \(own) itself")
        }
        // "Noch nicht gezählt" and the held count waiting have no spinner: the analysis does not
        // work then.
        for still in [".notCountedYet", ".recountWaiting"] {
            let body = Self.caseBody(still, in: status)
            #expect(!body.isEmpty && !body.contains("ProgressView"), "\(still): \(body)")
        }
        for turning in [".counting", ".recounting"] {
            #expect(Self.caseBody(turning, in: status).contains("ProgressView"), "\(turning)")
        }
        // The groups in the core's order, and only the last one said with a clause (a comma
        // inside the group): "…, 3 ignorierte Fotos und 6 Fotos, für die sich kein eigenes
        // Album lohnt." (`theGroupSaidWithAClauseComesLast`).
        let list = AppSource.body(of: "private func notCountedText", in: overview) ?? ""
        #expect(AppSource.code(list).contains("notCounted.groups"), "the overview orders the groups itself")
        let groups = Self.localized(in: list).filter { !$0.hasPrefix("Außerdem nicht mitgezählt") && !$0.hasPrefix("Nicht mitgezählt") }
        #expect(groups.count >= 6, "\(groups)")
        let withAClause = groups.filter { $0.contains(",") }
        #expect(withAClause.count == 1 && withAClause.allSatisfy { $0.contains("kein eigenes Album lohnt") }, "\(groups)")
        let limited = AppSource.code(AppSource.body(of: ["struct LimitedAccessCard", "var body: some View"], in: overview) ?? "")
        #expect(limited.contains("model.facts.count"), "limited access does not name the photos Albumist sees")
        #expect(!limited.contains("progress.allPhotos"), "limited access names the ring's photos")
    }

    /// The code of one case of a `switch` in `code`: from `case <pattern>` to the next `case .`
    /// at the same place in the text (the cases of `statusCard` hold no other switch).
    static func caseBody(_ pattern: String, in code: String) -> String {
        guard let start = code.range(of: "case " + pattern) else { return "" }
        let rest = code[start.upperBound...]
        let end = rest.range(of: "case .")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The texts of `String(localized: "…")` in `source`, as written (interpolations included).
    static func localized(in source: String) -> [String] {
        var found: [String] = []
        var rest = Substring(source)
        while let start = rest.range(of: "String(localized: \"") {
            var text = ""
            var index = start.upperBound
            while index < rest.endIndex, rest[index] != "\"" {
                if rest[index] == "\\", rest.index(after: index) < rest.endIndex, rest[rest.index(after: index)] == "\"" {
                    text.append("\"")
                    index = rest.index(index, offsetBy: 2)
                    continue
                }
                text.append(rest[index])
                index = rest.index(after: index)
            }
            found.append(text)
            rest = rest[index...]
        }
        return found
    }

    /// The labelled arguments of a call (`label: value`, also inside `.init(…)`), the value with
    /// its spaces and line breaks made single spaces.
    static func labelled(_ arguments: String) -> [String: String] {
        var inner = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix(".init("), inner.hasSuffix(")") { inner = String(inner.dropFirst(6).dropLast()) }
        var parts: [String] = [], current = "", depth = 0
        for character in inner {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        var result: [String: String] = [:]
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let label = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            result[label] = part[part.index(after: colon)...].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return result
    }
}
