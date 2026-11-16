import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review 16.11.2026 (Zusammenspiel bestehender Alben mit Vorschlägen).
/// Each test states the behaviour a user expects. A failing test reproduces a finding;
/// the finding id (A1 …) is in the test name and in
/// sortly-review/alben-und-bedienung-2026-11-16/BEFUNDE.md.
@Suite("Review 16.11.: bestehende Alben und Vorschläge")
struct AlbumInterplayReviewTests {
    let matcher = AlbumMatcher()

    func set(_ prefix: String, _ range: Range<Int>) -> Set<AssetID> {
        Set(range.map { AssetID("\(prefix)-\($0)") })
    }

    func trip(_ id: String, _ assets: Set<AssetID>, _ title: String) -> AlbumProposal {
        AlbumProposal(id: SortlyID(id), kind: .trip, title: title, assetIDs: assets)
    }

    func isTouching(_ d: ProposalDecision, _ album: CollectionID) -> Bool {
        switch d {
        case .extendExisting(let id), .keepExisting(let id): id == album
        default: false
        }
    }

    // A1: a big catch-all album ("iPhone-Export", "Familie", "Instagram") holds a whole trip
    // among thousands of other photos. It is not the trip's album.
    @Test("A1 Sammelalbum mit 5.000 Fotos ist nicht das Album einer Reise")
    func a1_catchAllAlbumSwallowsTrip() throws {
        let garda = set("garda", 0..<120)
        let other = set("home", 0..<4880)
        let export = CollectionSnapshot(id: "export", title: "iPhone-Export", assetIDs: garda.union(other))
        let p = trip("t-garda", garda, "Gardasee · Aug. 2026")
        let result = try #require(matcher.match([p], against: CollectionInventory([export]))[p.id])
        let decision = ProposalDecision.recommended(for: p, match: result)
        print("A1 status=\(result.status) decision=\(decision) purity=\(result.best?.metrics.purity ?? -1)")
        #expect(!isTouching(decision, "export"), "Reise wird vom Sammelalbum geschluckt: \(result.status)")
    }

    // A1b: the same for a category: dog photos partly in "Familie".
    @Test("A1b Kategorie Hunde wird nicht ins Album Familie gekippt")
    func a1b_categoryIntoFamilyAlbum() throws {
        let dogs = set("dog", 0..<200)
        let family = CollectionSnapshot(id: "familie", title: "Familie", assetIDs: set("dog", 0..<120).union(set("fam", 0..<880)))
        let p = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
        let result = try #require(matcher.match([p], against: CollectionInventory([family]))[p.id])
        let decision = ProposalDecision.recommended(for: p, match: result)
        print("A1b status=\(result.status) decision=\(decision)")
        #expect(!isTouching(decision, "familie"), "80 Hundefotos würden in „Familie“ gelegt: \(result.status)")
    }

    // A2: the user's own trip album "Italien 2019" must not become the country album and
    // receive the photos of 2021 and 2023.
    @Test("A2 Land Italien ergänzt nicht das Reisealbum „Italien 2019“")
    func a2_countryExtendsDatedTripAlbum() throws {
        let y19 = set("it19", 0..<150), y21 = set("it21", 0..<100), y23 = set("it23", 0..<150)
        let album = CollectionSnapshot(id: "it2019", title: "Italien 2019", assetIDs: y19)
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y21).union(y23))
        let result = try #require(matcher.match([country], against: CollectionInventory([album]))[country.id])
        let decision = ProposalDecision.recommended(for: country, match: result)
        print("A2 status=\(result.status) decision=\(decision)")
        #expect(!isTouching(decision, "it2019"), "250 Fotos aus 2021/2023 würden in „Italien 2019“ gelegt: \(result.status)")
    }

    // A3: a city suggestion fully inside a country album is not "done" through that album.
    @Test("A3 Stadt Rom wird nicht vom Länderalbum „Italien“ geschluckt")
    func a3_cityInsideCountryAlbum() throws {
        let rome = set("rome", 0..<80)
        let italy = CollectionSnapshot(id: "italien", title: "Italien", assetIDs: rome.union(set("it", 0..<400)))
        let city = AlbumProposal(id: SortlyID("city-rom"), kind: .placeCollection(.locality), title: "Rom",
                                 folderPath: ["Orte", "Italien"], assetIDs: rome)
        let result = try #require(matcher.match([city], against: CollectionInventory([italy]))[city.id])
        let decision = ProposalDecision.recommended(for: city, match: result)
        print("A3 status=\(result.status) decision=\(decision)")
        #expect(!isTouching(decision, "italien"), "Rom gilt als sortiert in „Italien“, kein Rom-Album: \(result.status)")
    }

    // A3b: same for a single trip inside an "Italien" album without other trips there.
    @Test("A3b Einzige Italienreise wird nicht vom Album „Italien“ geschluckt")
    func a3b_tripInsideCountryAlbum() throws {
        let t = set("rome24", 0..<80)
        let italy = CollectionSnapshot(id: "italien", title: "Italien", assetIDs: t.union(set("it", 0..<400)))
        let p = trip("t-rome", t, "Rom · Mai 2024")
        let result = try #require(matcher.match([p], against: CollectionInventory([italy]))[p.id])
        let decision = ProposalDecision.recommended(for: p, match: result)
        print("A3b status=\(result.status) decision=\(decision)")
        #expect(!isTouching(decision, "italien"), "Reise gilt als in „Italien“ sortiert: \(result.status)")
    }

    // A4: a small curated album ("Beste Hundefotos", 10 photos) must not get 390 more.
    @Test("A4 Kleines Auswahl-Album wird nicht mit hunderten Fotos aufgefüllt")
    func a4_curatedSubsetFlooded() throws {
        let dogs = set("dog", 0..<400)
        let best = CollectionSnapshot(id: "best", title: "Beste Hundefotos", assetIDs: set("dog", 0..<10))
        let p = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
        let result = try #require(matcher.match([p], against: CollectionInventory([best]))[p.id])
        let decision = ProposalDecision.recommended(for: p, match: result)
        print("A4 status=\(result.status) decision=\(decision) coverage=\(result.best?.metrics.coverage ?? -1)")
        #expect(!isTouching(decision, "best"), "390 Fotos würden in ein 10-Fotos-Auswahlalbum gelegt: \(result.status)")
    }

    // A5: in ONE run two suggestions must not both extend the same album of the user
    // (country and trip both pick "Italien 2019").
    @Test("A5 Zwei Vorschläge ergänzen im selben Lauf nicht dasselbe Album")
    func a5_twoSuggestionsSameAlbum() throws {
        let y19 = set("it19", 0..<150), y23 = set("it23", 0..<150)
        let album = CollectionSnapshot(id: "it2019", title: "Italien 2019", assetIDs: set("it19", 0..<100))
        let t19 = trip("t19", y19, "Italien · 2019")
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y23))
        let results = matcher.match([t19, country], against: CollectionInventory([album]))
        let users = [t19, country].filter { p in
            results[p.id].map { isTouching(ProposalDecision.recommended(for: p, match: $0), "it2019") } ?? false
        }
        print("A5 users=\(users.map(\.title)) trip=\(String(describing: results[t19.id]?.status)) country=\(String(describing: results[country.id]?.status))")
        #expect(users.count <= 1, "Beide Vorschläge nutzen „Italien 2019“")
    }

    // A6: an album the user created as a shared album is read-only. Albumist must say so
    // and create a new one, never pretend it fits.
    @Test("A6 Geteiltes Album zählt nicht als sortiert")
    func a6_sharedAlbumOnly() throws {
        let t = set("t", 0..<50)
        let shared = CollectionSnapshot(id: "shared", title: "Urlaub", capabilities: [], assetIDs: t)
        let p = trip("t1", t, "Urlaub 2026")
        let result = try #require(matcher.match([p], against: CollectionInventory([shared]))[p.id])
        #expect(result.status == .notEditable)
        if case .createNew = ProposalDecision.recommended(for: p, match: result) {} else { Issue.record("kein neues Album") }
    }

    // A7: speed for huge libraries: 50,000 photos, 300 albums incl. one 50,000 "Alle" album.
    @Test("A7 Abgleich bei 50.000 Fotos und 300 Alben unter 2 Sekunden")
    func a7_hugeLibrary() throws {
        var albums: [CollectionSnapshot] = [CollectionSnapshot(id: "alle", title: "Alle", assetIDs: set("x", 0..<50_000))]
        for i in 0..<299 { albums.append(CollectionSnapshot(id: CollectionID("a\(i)"), title: "Album \(i)", assetIDs: set("x", (i * 150)..<(i * 150 + 300)))) }
        var proposals: [AlbumProposal] = []
        for i in 0..<400 { proposals.append(trip("p\(i)", set("x", (i * 120)..<(i * 120 + 120)), "Reise \(i)")) }
        proposals.append(AlbumProposal(id: SortlyID("big"), kind: .imageCategory("x"), title: "Natur", assetIDs: set("x", 0..<20_000)))
        let start = Date()
        _ = matcher.match(proposals, against: CollectionInventory(albums))
        let seconds = Date().timeIntervalSince(start)
        print("A7 seconds=\(seconds)")
        #expect(seconds < 2)
    }
    // A8: app deleted and installed again, no backup restored. Albumist's albums are still
    // in Photos ("Albumist/Länder/Italien", "Albumist/Reisen/…"); the new analysis has no
    // records. Nothing may be created twice.
    @Test("A8 Nach Neuinstallation: eigene Alben werden wiedererkannt, keine Duplikate")
    func a8_reinstallRecognizesOwnAlbums() throws {
        let t24 = set("it24", 0..<120), t25 = set("it25", 0..<80), y = set("it-other", 0..<50)
        let root = CollectionSnapshot(id: "f-root", title: "Albumist", kind: .folder, childIDs: ["f-l", "f-r"])
        let countries = CollectionSnapshot(id: "f-l", title: "Länder", kind: .folder, parentID: "f-root", childIDs: ["a-it"])
        let trips = CollectionSnapshot(id: "f-r", title: "Reisen", kind: .folder, parentID: "f-root", childIDs: ["a-t24", "a-t25"])
        let itAlbum = CollectionSnapshot(id: "a-it", title: "Italien", parentID: "f-l", assetIDs: t24.union(t25).union(y))
        let t24Album = CollectionSnapshot(id: "a-t24", title: "Italien · Mai 2024", parentID: "f-r", assetIDs: t24)
        let t25Album = CollectionSnapshot(id: "a-t25", title: "Rom · Juni 2025", parentID: "f-r", assetIDs: t25)
        let inventory = CollectionInventory([root, countries, trips, itAlbum, t24Album, t25Album])
        let ps = [trip("n-t24", t24, "Italien · Mai 2024"), trip("n-t25", t25, "Rom · Juni 2025"),
                  AlbumProposal(id: SortlyID("n-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                assetIDs: t24.union(t25).union(y))]
        let results = matcher.match(ps, against: inventory)
        for p in ps {
            let r = try #require(results[p.id])
            print("A8 \(p.title): \(r.status) best=\(r.best?.albumTitle ?? "-")")
            #expect(ProposalDecision.recommended(for: p, match: r).isKeepExisting, "\(p.title): \(r.status)")
        }
        let merges = AlbumOverlapAnalyzer().suggestions(in: inventory)
        print("A8 merge suggestions: \(merges.map(\.albumIDs))")
        #expect(merges.isEmpty, "Albumists eigene Alben werden zum Zusammenführen angeboten")
    }

    // A9: after reinstall, a new trip to Italy comes in. The old trip album named after the
    // country must not be grown by the country (A2 for Albumist's own albums).
    @Test("A9 Nach Neuinstallation: neue Italienreise landet nicht im alten Reisealbum")
    func a9_reinstallNewTripNotIntoOldTripAlbum() throws {
        let t24 = set("it24", 0..<120), t26 = set("it26", 0..<90)
        let t24Album = CollectionSnapshot(id: "a-t24", title: "Italien · Mai 2024", parentID: "f-r", assetIDs: t24)
        let country = AlbumProposal(id: SortlyID("n-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: t24.union(t26))
        let r = try #require(matcher.match([country], against: CollectionInventory([t24Album]))[country.id])
        let d = ProposalDecision.recommended(for: country, match: r)
        print("A9 status=\(r.status) decision=\(d)")
        #expect(!isTouching(d, "a-t24"))
    }
}

/// Regression tests for the fixes of the review 16.11. beyond the review's own tests: what the
/// user sees and what counts as sorted must follow the same rule ("Unklar heißt nicht erledigt").
@Suite("Review 16.11.: Behebung")
struct AlbumInterplayFixTests {
    let matcher = AlbumMatcher()

    func set(_ prefix: String, _ range: Range<Int>) -> Set<AssetID> {
        Set(range.map { AssetID("\(prefix)-\($0)") })
    }

    /// A1: an album that holds the trip among thousands of other photos is not a match at all:
    /// "Neues Album" (so the trip may go into "Dein Startpaket"), the album only offered.
    @Test func catchAllAlbumIsOnlyOffered() throws {
        let garda = set("garda", 0..<120)
        let export = CollectionSnapshot(id: "export", title: "iPhone-Export", assetIDs: garda.union(set("home", 0..<4880)))
        let p = AlbumProposal(id: SortlyID("t"), kind: .trip, title: "Gardasee · Aug. 2026", assetIDs: garda)
        let result = try #require(matcher.match([p], against: CollectionInventory([export]))[p.id])
        #expect(result.status == .newAlbumRequired)
        #expect(result.best == nil)
        #expect(result.alternatives.map(\.albumID) == ["export"])
        #expect(ProposalDecision.recommended(for: p, match: result) == .createNew(title: nil, folderPath: nil))
    }

    /// A4: a possible match says that nothing is added, and no longer "werden ergänzt".
    @Test func possibleMatchPromisesNoChange() throws {
        let dogs = set("dog", 0..<400)
        let best = CollectionSnapshot(id: "best", title: "Beste Hundefotos", assetIDs: set("dog", 0..<10))
        let p = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
        let result = try #require(matcher.match([p], against: CollectionInventory([best]))[p.id])
        #expect(result.status == .possibleMatch)
        #expect(!result.reasons.contains { if case .missingItems = $0 { true } else { false } })
        #expect(result.reasons.contains(.keptUnchangedUntilChosen(album: "Beste Hundefotos")))
        #expect(ProposalDecision.recommended(for: p, match: result) == .createNew(title: nil, folderPath: nil))
        // Still a choice under "Anpassen".
        #expect(result.best?.albumID == "best")
    }

    /// The area overview counts a possible match as a new album, not as "in deinen Alben".
    @Test func possibleMatchIsANewAlbumInTheAreaOverview() throws {
        let dogs = set("dog", 0..<400)
        let best = CollectionSnapshot(id: "best", title: "Beste Hundefotos", assetIDs: set("dog", 0..<10))
        let p = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
        let results = matcher.match([p], against: CollectionInventory([best]))
        let overview = try #require(AreaOverview.make(proposals: [p], matches: results).first)
        #expect(overview.existingMatches == 0)
        #expect(overview.newAlbumsNeeded == 1)
    }

    /// A2 beyond places: no collection grows an album named after one year. The year 2019
    /// (dogs and 300 other photos) does not grow "Hunde 2019" either: the album is about dogs
    /// (second review 16.11.). An album named "2019" is the year's album.
    @Test func noCollectionGrowsAnAlbumOfOneYear() throws {
        let dogs = set("dog", 0..<200)
        let dogs19 = CollectionSnapshot(id: "d19", title: "Hunde 2019", assetIDs: set("dog", 0..<100))
        let category = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
        let r = try #require(matcher.match([category], against: CollectionInventory([dogs19]))[category.id])
        #expect(r.status == .newAlbumRequired)

        let year = AlbumProposal(id: SortlyID("y19"), kind: .chronology(.year), title: "2019",
                                 assetIDs: set("dog", 0..<100).union(set("y19", 0..<300)))
        let y = try #require(matcher.match([year], against: CollectionInventory([dogs19]))[year.id])
        #expect(!isTouching(ProposalDecision.recommended(for: year, match: y), "d19"), "\(y.status)")
        let named = CollectionSnapshot(id: "a19", title: "2019", assetIDs: set("dog", 0..<100))
        #expect(matcher.match([year], against: CollectionInventory([named]))[year.id]?.status == .extendable)
    }

    /// The ring follows the same rule: with several fitting albums, an album named after
    /// another year does not count for a country.
    @Test func tiedAlbumOfOneYearDoesNotCount() throws {
        let it = set("it", 0..<40)
        let country = AlbumProposal(id: SortlyID("it"), kind: .placeCollection(.country), title: "Italien", assetIDs: it)
        let inventory = CollectionInventory([
            CollectionSnapshot(id: "it-1", title: "Italien", assetIDs: set("it", 0..<20)),
            CollectionSnapshot(id: "it-2", title: "Italien", assetIDs: set("it", 20..<40)),
        ])
        let result = try #require(matcher.match([country], against: inventory)[country.id])
        #expect(result.status == .multipleMatches)
        var renamed = result
        renamed.alternatives = renamed.alternatives.map { var c = $0; c.albumTitle = "Italien 2019"; return c }
        #expect(matcher.tiedWithBest(result, kind: country.kind, title: country.title).count == 1)
        #expect(matcher.tiedWithBest(renamed, kind: country.kind, title: country.title).isEmpty)
    }

    /// A5 without the year in the name: the trip and the country both want "Italien". The trip
    /// (the album is most like it) keeps it; the country gets an album of its own and is offered
    /// "Italien" only under "Anpassen".
    @Test func oneAlbumPerRunForOneSuggestion() throws {
        let y19 = set("it19", 0..<150), y23 = set("it23", 0..<150)
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it19", 0..<100))
        let trip = AlbumProposal(id: SortlyID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19)
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y23))
        // Either order of the suggestions gives the same answer.
        for ps in [[trip, country], [country, trip]] {
            let results = matcher.match(ps, against: CollectionInventory([album]))
            #expect(results[trip.id]?.status == .extendable)
            #expect(ProposalDecision.recommended(for: trip, match: results[trip.id]) == .extendExisting("it"))
            let c = try #require(results[country.id])
            #expect(ProposalDecision.recommended(for: country, match: c) == .createNew(title: nil, folderPath: nil))
            #expect(c.alternatives.contains { $0.albumID == "it" })
        }
    }

    /// A10: an album that is already complete for one suggestion ("Album so lassen") belongs to
    /// it; another suggestion of the same run does not extend it.
    @Test func completeAlbumIsNotExtendedByAnotherSuggestion() throws {
        let y19 = set("it19", 0..<150), y23 = set("it23", 0..<150)
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: y19)
        let trip = AlbumProposal(id: SortlyID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19)
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y23))
        // Alone, the country would extend it (the album is named after it).
        #expect(matcher.match([country], against: CollectionInventory([album]))[country.id]?.status == .extendable)

        let results = matcher.match([trip, country], against: CollectionInventory([album]))
        #expect(results[trip.id]?.status == .alreadyComplete)
        let c = try #require(results[country.id])
        #expect(!isTouching(ProposalDecision.recommended(for: country, match: c), "it"))

        // The same for a suggestion outside the run (dismissed): its complete album is reserved.
        let reserved = matcher.match([country], against: CollectionInventory([album]), reserved: ["it"])
        #expect(!isTouching(ProposalDecision.recommended(for: country, match: try #require(reserved[country.id])), "it"))

        // A suggestion that the album holds completely may still keep it as well.
        let same = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien", assetIDs: y19)
        #expect(matcher.match([trip, same], against: CollectionInventory([album]))[same.id]?.status == .alreadyComplete)
    }

    func isTouching(_ d: ProposalDecision, _ album: CollectionID) -> Bool {
        switch d {
        case .extendExisting(let id), .keepExisting(let id): id == album
        default: false
        }
    }
}

/// Second review of claude/pro-albums (16.11.): one regression test per finding.
@Suite("Review 16.11.: Zweitprüfung")
struct AlbumInterplaySecondReviewTests {
    let matcher = AlbumMatcher()

    func set(_ prefix: String, _ range: Range<Int>) -> Set<AssetID> {
        Set(range.map { AssetID("\(prefix)-\($0)") })
    }

    func isTouching(_ d: ProposalDecision, _ album: CollectionID) -> Bool {
        switch d {
        case .extendExisting(let id), .keepExisting(let id): id == album
        default: false
        }
    }

    /// 1: Albumist made "2026" in January (20 photos). By December the year has 200: the album
    /// stays its album and is extended, never a second "2026".
    @Test func assignedAlbumStaysExtendableWhenTheSuggestionGrows() throws {
        let year = AlbumProposal(id: SortlyID("y26"), kind: .chronology(.year), title: "2026", assetIDs: set("y", 0..<200))
        let album = CollectionSnapshot(id: "a26", title: "2026", assetIDs: set("y", 0..<20))
        let dogs = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<500))
        let dogAlbum = CollectionSnapshot(id: "a-dogs", title: "Hunde", assetIDs: set("d", 0..<30))
        let results = matcher.match([year, dogs], against: CollectionInventory([album, dogAlbum]),
                                    assignments: [year.id: "a26", dogs.id: "a-dogs"])
        #expect(results[year.id]?.status == .extendable)
        #expect(ProposalDecision.recommended(for: year, match: results[year.id]) == .extendExisting("a26"))
        #expect(ProposalDecision.recommended(for: dogs, match: results[dogs.id]) == .extendExisting("a-dogs"))
    }

    /// 2: a collection fills a subset album of the user only when the name says it is this
    /// collection or the album holds most of it.
    @Test func collectionsDoNotFillSubsetAlbumsWithoutACertainMatch() throws {
        // The year 2019 (150 Italy, 250 other photos) and "Italien 2019".
        let year = AlbumProposal(id: SortlyID("y19"), kind: .chronology(.year), title: "2019",
                                 assetIDs: set("it19", 0..<150).union(set("home19", 0..<250)))
        let italy = CollectionSnapshot(id: "it19", title: "Italien 2019", assetIDs: set("it19", 0..<150))
        let y = try #require(matcher.match([year], against: CollectionInventory([italy]))[year.id])
        #expect(y.status == .possibleMatch)
        #expect(!isTouching(ProposalDecision.recommended(for: year, match: y), "it19"))

        // Hunde and "Bello" (one dog among all).
        let dogs = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<400))
        let bello = CollectionSnapshot(id: "bello", title: "Bello", assetIDs: set("d", 0..<120))
        let d = try #require(matcher.match([dogs], against: CollectionInventory([bello]))[dogs.id])
        #expect(d.status == .possibleMatch)
        // Most of all dog photos: then it is the dog album.
        let most = CollectionSnapshot(id: "bello", title: "Bello", assetIDs: set("d", 0..<350))
        #expect(matcher.match([dogs], against: CollectionInventory([most]))[dogs.id]?.status == .extendable)
        // Named after it: extended.
        let named = CollectionSnapshot(id: "hunde", title: "Unsere Hunde", assetIDs: set("d", 0..<120))
        #expect(matcher.match([dogs], against: CollectionInventory([named]))[dogs.id]?.status == .extendable)

        // The month Mai 2024 and "Italien, Mai 2024".
        let may = AlbumProposal(id: SortlyID("m"), kind: .chronology(.month), title: "Mai 2024", assetIDs: set("may", 0..<300))
        let trip = CollectionSnapshot(id: "trip", title: "Italien, Mai 2024", assetIDs: set("may", 0..<100))
        #expect(matcher.match([may], against: CollectionInventory([trip]))[may.id]?.status == .possibleMatch)
    }

    /// 3: the ring with several albums. Album B (62 % trip) alone is a possible match and does
    /// not count; adding a purer album A must not make all of B count.
    @Test func multipleMatchesCountOnlyAlbumsThatAreMostlyTheSuggestion() throws {
        let trip = AlbumProposal(id: SortlyID("t"), kind: .trip, title: "Island", assetIDs: set("t", 0..<100))
        let b = CollectionSnapshot(id: "b", title: "Sommer", assetIDs: set("t", 0..<90).union(set("x", 0..<55)))
        let a = CollectionSnapshot(id: "a", title: "Auswahl", assetIDs: set("t", 0..<40))
        let alone = try #require(matcher.match([trip], against: CollectionInventory([b]))[trip.id])
        #expect(alone.status == .possibleMatch)
        let both = try #require(matcher.match([trip], against: CollectionInventory([a, b]))[trip.id])
        #expect(both.status == .multipleMatches)
        #expect(both.best?.albumID == "b")
        #expect(!matcher.sortingAlbums(both, kind: trip.kind, title: trip.title).contains("b"))
        // The area overview and "davon in deinen Alben" follow the same rule.
        let overview = try #require(AreaOverview.make(proposals: [trip], matches: [trip.id: both]).first)
        #expect(overview.existingMatches == 0)
    }

    /// 5: years in short forms are years; a season over the new year names both.
    @Test func yearsInShortForms() throws {
        #expect(AlbumMatcher.years(in: "Italien '19") == [2019])
        #expect(AlbumMatcher.years(in: "Urlaub2019") == [2019])
        #expect(AlbumMatcher.years(in: "Winter 2025/26") == [2025, 2026])
        #expect(AlbumMatcher.years(in: "Winter 2025/2026") == [2025, 2026])
        #expect(AlbumMatcher.years(in: "Gardasee · 03.08.–14.08.2026") == [2026])
        #expect(AlbumMatcher.years(in: "Album 12345").isEmpty)

        let country = AlbumProposal(id: SortlyID("it"), kind: .placeCollection(.country), title: "Italien",
                                    assetIDs: set("it", 0..<300))
        for title in ["Italien '19", "Urlaub2019 Italien"] {
            let album = CollectionSnapshot(id: "u", title: title, assetIDs: set("it", 0..<100))
            let r = try #require(matcher.match([country], against: CollectionInventory([album]))[country.id])
            #expect(!isTouching(ProposalDecision.recommended(for: country, match: r), "u"), "\(title): \(r.status)")
        }
        let winter = AlbumProposal(id: SortlyID("w"), kind: .chronology(.season), title: "Winter 2025/26", assetIDs: set("w", 0..<200))
        let album = CollectionSnapshot(id: "w", title: "Winter 2025/2026", assetIDs: set("w", 0..<100))
        #expect(matcher.match([winter], against: CollectionInventory([album]))[winter.id]?.status == .extendable)
    }

    /// 5 (BEFUNDE #3): an album whose photos all lie in one trip is a part of the place, also
    /// without a year in its name and without a trip suggestion in the run.
    @Test func albumOfOneTripIsAPartOfThePlace() throws {
        let t19 = set("it19", 0..<150), t23 = set("it23", 0..<150)
        let country = AlbumProposal(id: SortlyID("it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: t19.union(t23))
        let album = CollectionSnapshot(id: "u", title: "Urlaub in Italien", assetIDs: set("it19", 0..<100))
        let r = try #require(matcher.match([country], against: CollectionInventory([album]), trips: [t19, t23])[country.id])
        #expect(!isTouching(ProposalDecision.recommended(for: country, match: r), "u"), "\(r.status)")
        #expect(r.alternatives.contains { $0.albumID == "u" })
        // A country seen on that one trip only: the album is the country's.
        let once = AlbumProposal(id: SortlyID("it"), kind: .placeCollection(.country), title: "Italien", assetIDs: t19)
        #expect(matcher.match([once], against: CollectionInventory([album]), trips: [t19])[once.id]?.status == .extendable)
    }

    /// 7: "Empfohlene auswählen" and "Dein Startpaket" take the same safe suggestions.
    @Test func safeToAcceptUnseenLeavesOutPossibleMatches() throws {
        let dogs = AlbumProposal(id: SortlyID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<400))
        let best = CollectionSnapshot(id: "best", title: "Beste Hundefotos", assetIDs: set("d", 0..<10))
        let possible = matcher.match([dogs], against: CollectionInventory([best]))[dogs.id]
        #expect(possible?.status == .possibleMatch)
        #expect(!ProposalDecision.isSafeToAcceptUnseen(dogs, match: possible))
        #expect(ProposalDecision.isSafeToAcceptUnseen(dogs, match: matcher.match([dogs], against: CollectionInventory())[dogs.id]))
        var sensitive = dogs
        sensitive.isSensitive = true
        #expect(!ProposalDecision.isSafeToAcceptUnseen(sensitive, match: nil))
    }
}
