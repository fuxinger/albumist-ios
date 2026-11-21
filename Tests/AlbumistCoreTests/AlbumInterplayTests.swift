import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

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
        AlbumProposal(id: AlbumistID(id), kind: .trip, title: title, assetIDs: assets)
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
        let p = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
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
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien",
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
        let city = AlbumProposal(id: AlbumistID("city-rom"), kind: .placeCollection(.locality), title: "Rom",
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
        let p = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
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
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien",
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
    // Counted as work, not on the clock: under the parallel test run the 2-second limit failed
    // once at 2.14 s (alone 0.6-0.7 s, review of a26e8bc). What made it slow before would show
    // here as reads: a big album read once per suggestion (400 x 50,000) instead of once per
    // family, or overlaps counted by scanning albums instead of the photo -> album index.
    @Test("A7 Abgleich bei 50.000 Fotos und 300 Alben: Arbeit wächst nur linear")
    func a7_hugeLibrary() throws {
        var albums: [CollectionSnapshot] = [CollectionSnapshot(id: "alle", title: "Alle", assetIDs: set("x", 0..<50_000))]
        for i in 0..<299 { albums.append(CollectionSnapshot(id: CollectionID("a\(i)"), title: "Album \(i)", assetIDs: set("x", (i * 150)..<(i * 150 + 300)))) }
        var proposals: [AlbumProposal] = []
        for i in 0..<400 { proposals.append(trip("p\(i)", set("x", (i * 120)..<(i * 120 + 120)), "Reise \(i)")) }
        proposals.append(AlbumProposal(id: AlbumistID("big"), kind: .imageCategory("x"), title: "Natur", assetIDs: set("x", 0..<20_000)))
        let inventory = CollectionInventory(albums)
        var stats = AlbumMatcher.Stats()
        let start = Date()
        _ = matcher.match(proposals, against: inventory, overrides: OverrideSet(), assignments: [:], reserved: [], trips: [], stats: &stats)
        let seconds = Date().timeIntervalSince(start)
        // One pass: every photo of every suggestion, once per album it is in.
        let membership = inventory.albumMembershipIndex()
        let onePass = proposals.reduce(0) { sum, p in sum + p.assetIDs.reduce(0) { $0 + (membership[$1]?.count ?? 0) } }
        let albumPhotos = albums.reduce(0) { $0 + $1.assetIDs.count }
        let families = Set(proposals.map(\.kind.familyKey)).count
        print("A7 seconds=\(seconds) runs=\(stats.proposalRuns) membershipReads=\(stats.membershipReads) (one pass \(onePass)) albumPhotoReads=\(stats.albumPhotoReads) (all albums \(albumPhotos) x \(families) families)")
        // Each suggestion matched once, plus at most one more round for those that lost an album.
        #expect(stats.proposalRuns <= 2 * proposals.count)
        #expect(stats.membershipReads <= 2 * onePass)
        // Each album read in full at most once per family, never once per suggestion.
        #expect(stats.albumPhotoReads <= albumPhotos * families)
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
                  AlbumProposal(id: AlbumistID("n-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
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
        let country = AlbumProposal(id: AlbumistID("n-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
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
        let p = AlbumProposal(id: AlbumistID("t"), kind: .trip, title: "Gardasee · Aug. 2026", assetIDs: garda)
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
        let p = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
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
        let p = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
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
        let category = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: dogs)
        let r = try #require(matcher.match([category], against: CollectionInventory([dogs19]))[category.id])
        #expect(r.status == .newAlbumRequired)

        let year = AlbumProposal(id: AlbumistID("y19"), kind: .chronology(.year), title: "2019",
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
        let country = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien", assetIDs: it)
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

    /// A5 without the year in the name: the trip and the country both want "Urlaub in Italien".
    /// The trip (the album is most like it) keeps it; the country gets an album of its own and
    /// is offered the album only under "Anpassen".
    @Test func oneAlbumPerRunForOneSuggestion() throws {
        let y19 = set("it19", 0..<150), y23 = set("it23", 0..<150)
        // Not named exactly like the country: since the decision of 16.11. (ENTWURF Q8,
        // "Gleicher Name gewinnt") an album called "Italien" goes to the country
        // (sameNameWinsTheAlbum). Here the content decides.
        let album = CollectionSnapshot(id: "it", title: "Urlaub in Italien", assetIDs: set("it19", 0..<100))
        let trip = AlbumProposal(id: AlbumistID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien",
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
        // Not named exactly like the country: an album called "Italien" goes to the country
        // since the decision of 16.11. (ENTWURF Q8, sameNameWinsTheAlbum).
        let album = CollectionSnapshot(id: "it", title: "Urlaub in Italien", assetIDs: y19)
        let trip = AlbumProposal(id: AlbumistID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: y19.union(y23))
        // Alone, the country would extend it (the name shares "Italien").
        #expect(matcher.match([country], against: CollectionInventory([album]))[country.id]?.status == .extendable)

        let results = matcher.match([trip, country], against: CollectionInventory([album]))
        #expect(results[trip.id]?.status == .alreadyComplete)
        let c = try #require(results[country.id])
        #expect(!isTouching(ProposalDecision.recommended(for: country, match: c), "it"))

        // The same for a suggestion outside the run (dismissed): its complete album is reserved.
        let reserved = matcher.match([country], against: CollectionInventory([album]), reserved: ["it"])
        #expect(!isTouching(ProposalDecision.recommended(for: country, match: try #require(reserved[country.id])), "it"))

        // A suggestion that the album holds completely may still keep it as well.
        let same = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", assetIDs: y19)
        #expect(matcher.match([trip, same], against: CollectionInventory([album]))[trip.id]?.status == .alreadyComplete)
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
        let year = AlbumProposal(id: AlbumistID("y26"), kind: .chronology(.year), title: "2026", assetIDs: set("y", 0..<200))
        let album = CollectionSnapshot(id: "a26", title: "2026", assetIDs: set("y", 0..<20))
        let dogs = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<500))
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
        let year = AlbumProposal(id: AlbumistID("y19"), kind: .chronology(.year), title: "2019",
                                 assetIDs: set("it19", 0..<150).union(set("home19", 0..<250)))
        let italy = CollectionSnapshot(id: "it19", title: "Italien 2019", assetIDs: set("it19", 0..<150))
        let y = try #require(matcher.match([year], against: CollectionInventory([italy]))[year.id])
        #expect(y.status == .possibleMatch)
        #expect(!isTouching(ProposalDecision.recommended(for: year, match: y), "it19"))

        // Hunde and "Bello" (one dog among all).
        let dogs = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<400))
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
        let may = AlbumProposal(id: AlbumistID("m"), kind: .chronology(.month), title: "Mai 2024", assetIDs: set("may", 0..<300))
        let trip = CollectionSnapshot(id: "trip", title: "Italien, Mai 2024", assetIDs: set("may", 0..<100))
        #expect(matcher.match([may], against: CollectionInventory([trip]))[may.id]?.status == .possibleMatch)
    }

    /// 3: the ring with several albums. Album B (62 % trip) alone is a possible match and does
    /// not count; adding a purer album A must not make all of B count.
    @Test func multipleMatchesCountOnlyAlbumsThatAreMostlyTheSuggestion() throws {
        let trip = AlbumProposal(id: AlbumistID("t"), kind: .trip, title: "Island", assetIDs: set("t", 0..<100))
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

        let country = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien",
                                    assetIDs: set("it", 0..<300))
        for title in ["Italien '19", "Urlaub2019 Italien"] {
            let album = CollectionSnapshot(id: "u", title: title, assetIDs: set("it", 0..<100))
            let r = try #require(matcher.match([country], against: CollectionInventory([album]))[country.id])
            #expect(!isTouching(ProposalDecision.recommended(for: country, match: r), "u"), "\(title): \(r.status)")
        }
        let winter = AlbumProposal(id: AlbumistID("w"), kind: .chronology(.season), title: "Winter 2025/26", assetIDs: set("w", 0..<200))
        let album = CollectionSnapshot(id: "w", title: "Winter 2025/2026", assetIDs: set("w", 0..<100))
        #expect(matcher.match([winter], against: CollectionInventory([album]))[winter.id]?.status == .extendable)
    }

    /// 5 (BEFUNDE #3): an album whose photos all lie in one trip is a part of the place, also
    /// without a year in its name and without a trip suggestion in the run.
    @Test func albumOfOneTripIsAPartOfThePlace() throws {
        let t19 = set("it19", 0..<150), t23 = set("it23", 0..<150)
        let country = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: t19.union(t23))
        let album = CollectionSnapshot(id: "u", title: "Urlaub in Italien", assetIDs: set("it19", 0..<100))
        let r = try #require(matcher.match([country], against: CollectionInventory([album]), trips: [t19, t23])[country.id])
        #expect(!isTouching(ProposalDecision.recommended(for: country, match: r), "u"), "\(r.status)")
        #expect(r.alternatives.contains { $0.albumID == "u" })
        // A country seen on that one trip only: the album is the country's.
        let once = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien", assetIDs: t19)
        #expect(matcher.match([once], against: CollectionInventory([album]), trips: [t19])[once.id]?.status == .extendable)
    }

    /// 7: "Empfohlene auswählen" and "Dein Startpaket" take the same safe suggestions.
    @Test func safeToAcceptUnseenLeavesOutPossibleMatches() throws {
        let dogs = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<400))
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

/// Re-check of claude/pro-albums (16.11.): what was left after the second review.
@Suite("Review 16.11.: Nachprüfung")
struct AlbumInterplayRecheckTests {
    let matcher = AlbumMatcher()

    func set(_ prefix: String, _ range: Range<Int>) -> Set<AssetID> {
        Set(range.map { AssetID("\(prefix)-\($0)") })
    }

    /// 1: "Italien", made after the first of three trips, stays the country's album. The
    /// one-trip rule made it a part, and the country got a second "Italien" with "Gleicher
    /// Name, anderer Inhalt".
    @Test func albumNamedOnlyAfterThePlaceIsNotOneTrip() throws {
        let t19 = set("it19", 0..<100), t21 = set("it21", 0..<100), t23 = set("it23", 0..<100)
        let country = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien",
                                    folderPath: ["Länder"], assetIDs: t19.union(t21).union(t23))
        let album = CollectionSnapshot(id: "u-it", title: "Italien", assetIDs: t19)
        let r = try #require(matcher.match([country], against: CollectionInventory([album]), trips: [t19, t21, t23])[country.id])
        #expect(r.status == .extendable)
        #expect(ProposalDecision.recommended(for: country, match: r) == .extendExisting("u-it"))
        // The same as without the trips.
        #expect(matcher.match([country], against: CollectionInventory([album]))[country.id]?.status == r.status)
        // Another name: still the trip, a part.
        let other = CollectionSnapshot(id: "u-it", title: "Urlaub in Italien", assetIDs: t19)
        #expect(matcher.match([country], against: CollectionInventory([other]), trips: [t19, t21, t23])[country.id]?.status == .newAlbumRequired)
    }
}

extension AlbumInterplayRecheckTests {
    /// 3: a decision accepted under the old rules (Startpaket "ergänzen" on "Beste Hundefotos",
    /// now only a possible match) goes back to open after the re-match. Certain ones, other
    /// kinds of decisions and the suggestions of a started plan stay.
    @Test func uncertainExtendDecisionsGoBackToOpen() throws {
        let dogs = AlbumProposal(id: AlbumistID("c-dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("d", 0..<400))
        let trip = AlbumProposal(id: AlbumistID("t"), kind: .trip, title: "Island", assetIDs: set("t", 0..<100))
        let cats = AlbumProposal(id: AlbumistID("c-cats"), kind: .imageCategory("cat"), title: "Katzen", assetIDs: set("k", 0..<50))
        let moved = AlbumProposal(id: AlbumistID("c-birds"), kind: .imageCategory("bird"), title: "Vögel", assetIDs: set("v", 0..<400))
        let inventory = CollectionInventory([
            CollectionSnapshot(id: "best", title: "Beste Hundefotos", assetIDs: set("d", 0..<10)),
            CollectionSnapshot(id: "island", title: "Island", assetIDs: set("t", 0..<60)),
            CollectionSnapshot(id: "birds", title: "Lieblinge", assetIDs: set("v", 0..<10)),
        ])
        let all = [dogs, trip, cats, moved]
        let matches = matcher.match(all, against: inventory)
        let decisions: [AlbumistID: ProposalDecision] = [
            dogs.id: .extendExisting("best"),                  // now a possible match: reopened
            trip.id: .extendExisting("island"),                // still certain: stays
            cats.id: .createNew(title: nil, folderPath: nil),  // adds to no album: stays
            moved.id: .moveExisting("birds", folderPath: ["Tiere"], extend: true), // reopened
        ]
        #expect(ProposalDecision.uncertainExtensions(decisions, proposals: all, matches: matches) == [dogs.id, moved.id])
        // A plan that already started keeps its suggestions.
        #expect(ProposalDecision.uncertainExtensions(decisions, proposals: all, matches: matches, protected: [dogs.id]) == [moved.id])
    }
}

extension AlbumInterplayRecheckTests {
    /// Final check 16.11. (2): the one-trip rule reads an album's photos at most once per run,
    /// however many places (country, region, towns, shown and matched again after a conflict)
    /// ask about it. Counted, not timed: before, the work grew with every place and photo.
    @Test func oneTripRuleReadsEachAlbumAtMostOncePerRun() throws {
        let trips = (0..<20).map { set("t\($0)", 0..<50) }
        var albums: [CollectionSnapshot] = []
        for i in 0..<20 {
            albums.append(CollectionSnapshot(id: CollectionID("trip-\(i)"), title: "Ferien \(i)", assetIDs: set("t\(i)", 0..<30)))
            albums.append(CollectionSnapshot(id: CollectionID("mix-\(i)"), title: "Auswahl \(i)",
                                             assetIDs: set("t\(i)", 0..<20).union(set("t\((i + 1) % 20)", 0..<20))))
        }
        var proposals: [AlbumProposal] = []
        for c in 0..<2 {
            let members = (0..<10).reduce(into: Set<AssetID>()) { $0.formUnion(trips[c * 10 + $1]) }
            proposals.append(AlbumProposal(id: AlbumistID("c\(c)"), kind: .placeCollection(.country), title: "Land \(c)", assetIDs: members))
            proposals.append(AlbumProposal(id: AlbumistID("r\(c)"), kind: .placeCollection(.administrativeArea), title: "Region \(c)", assetIDs: members))
        }
        for t in 0..<20 {
            proposals.append(AlbumProposal(id: AlbumistID("s\(t)"), kind: .placeCollection(.locality), title: "Stadt \(t)",
                                           assetIDs: trips[t].union(trips[(t + 1) % 20])))
        }
        var stats = AlbumMatcher.Stats()
        _ = matcher.match(proposals, against: CollectionInventory(albums), overrides: OverrideSet(), assignments: [:],
                          reserved: [], trips: trips, stats: &stats)
        #expect(stats.albumTripScans.count >= 20, "the rule was asked: \(stats.albumTripScans.count) albums")
        #expect(stats.albumTripScans.values.allSatisfy { $0 == 1 }, "\(stats.albumTripScans.filter { $0.value > 1 })")
    }
}

/// Decision Fuchs 16.11. (ENTWURF-BEDIENUNG Q8, "Gleicher Name gewinnt"): an album of the user
/// named exactly like a suggestion belongs to that suggestion, also when a trip of the same run
/// wants it. The country extends "Italien" (shown in the preview, undoable); the trip gets its
/// own album. Albums with a year ("Italien 2019") stay parts.
@Suite("Gleicher Name gewinnt")
struct SameNameWinsTests {
    let matcher = AlbumMatcher()

    func set(_ prefix: String, _ range: Range<Int>) -> Set<AssetID> {
        Set(range.map { AssetID("\(prefix)-\($0)") })
    }

    // One declaration each: with both in one `let a = …, b = …`, Swift 6.2.3 on Linux gave
    // b the value of a (both closures read "it19").
    let y19 = Set((0..<150).map { AssetID("it19-\($0)") })
    let y23 = Set((0..<150).map { AssetID("it23-\($0)") })
    var trip: AlbumProposal { AlbumProposal(id: AlbumistID("t19"), kind: .trip, title: "Italien · Mai 2019", assetIDs: y19) }
    var country: AlbumProposal {
        AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"], assetIDs: y19.union(y23))
    }

    @Test func sameNameWinsTheAlbum() throws {
        // "Italien" holds part of the 2019 trip: both would extend it; before, the trip got it
        // (more similar) and the country a second "Italien".
        let part = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it19", 0..<100))
        // "Italien" holds the whole 2019 trip: before, the trip kept it ("Album so lassen").
        let whole = CollectionSnapshot(id: "it", title: "Italien", assetIDs: y19)
        for album in [part, whole] {
            for ps in [[trip, country], [country, trip]] {
                let results = matcher.match(ps, against: CollectionInventory([album]), trips: [y19, y23])
                let c = try #require(results[country.id])
                #expect(ProposalDecision.recommended(for: country, match: c) == .extendExisting("it"), "\(album.assetIDs.count): \(c.status)")
                let t = try #require(results[trip.id])
                #expect(ProposalDecision.recommended(for: trip, match: t) == .createNew(title: nil, folderPath: nil), "\(t.status)")
                // Still offered to the trip under "Anpassen".
                #expect(t.alternatives.contains { $0.albumID == "it" })
            }
        }
    }

    /// Normalised: case and accents do not matter.
    @Test func sameNameIsNormalised() throws {
        let album = CollectionSnapshot(id: "it", title: "ITALIEN", assetIDs: y19)
        let results = matcher.match([trip, country], against: CollectionInventory([album]))
        #expect(ProposalDecision.recommended(for: country, match: results[country.id]) == .extendExisting("it"))
    }

    /// The same when the trip is outside the run (dismissed, `reserved`).
    @Test func sameNameWinsOverADismissedTrip() throws {
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: y19)
        let r = matcher.match([country], against: CollectionInventory([album]), reserved: ["it"])
        #expect(ProposalDecision.recommended(for: country, match: r[country.id]) == .extendExisting("it"))
    }

    /// P1-02 (review 18.11.2026): the rule held only while the country would extend the album by
    /// itself (at least 25 % of the country in it). After five trips the user's "Italien", made
    /// after the first one, holds 100 of the country's 600 photos: the country got only a
    /// possible match, the 2019 trip took the album, and a second "Italien" was offered.
    @Test func sameNameWinsAlsoWhenTheAlbumHoldsLittleOfTheCountry() throws {
        let years = [2019, 2021, 2022, 2023, 2024]
        let sets = years.map { set("it\($0)", 0..<120) }
        let trips = zip(years, sets).map {
            AlbumProposal(id: AlbumistID("t\($0)"), kind: .trip, title: "Italien · Mai \($0)", folderPath: ["Reisen", "\($0)"], assetIDs: $1)
        }
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: sets.reduce(into: Set<AssetID>()) { $0.formUnion($1) })
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it2019", 0..<100))
        for ps in [trips + [country], [country] + trips, [country]] {
            let results = matcher.match(ps, against: CollectionInventory([album]), trips: sets)
            let c = try #require(results[country.id])
            #expect(ProposalDecision.recommended(for: country, match: c) == .extendExisting("it"), "\(ps.count) suggestions: \(c.status)")
            #expect(c.reasons.contains(.missingItems(count: 500)))
            guard ps.count > 1 else { continue }
            let t = try #require(results[trips[0].id])
            #expect(ProposalDecision.recommended(for: trips[0], match: t) == .createNew(title: nil, folderPath: nil), "\(t.status)")
            #expect(t.alternatives.contains { $0.albumID == "it" })
        }
    }

    /// P1-02: "Italien" holds 150 of the country's 300 photos and 50 from the way there through
    /// Austria (75 % of the album is Italy, below the 80 % for extending by content). It is the
    /// country's album all the same: extended (only Italy photos are added, nothing taken out),
    /// not a second "Italien". Because it holds other photos too, it is not chosen without the
    /// user looking at it ("Empfohlene auswählen").
    @Test func sameNameWinsAlsoWhenTheAlbumHoldsOtherPhotosToo() throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it", 0..<150).union(set("at", 0..<50)))
        let c = try #require(matcher.match([country], against: CollectionInventory([album]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: c) == .extendExisting("it"), "\(c.status)")
        #expect(c.reasons.contains(.missingItems(count: 150)))
        #expect(!ProposalDecision.isSafeToAcceptUnseen(country, match: c))
        // The same album with only Italy photos may be chosen unseen, as before.
        let pure = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it", 0..<150))
        let p = try #require(matcher.match([country], against: CollectionInventory([pure]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: p) == .extendExisting("it"))
        #expect(ProposalDecision.isSafeToAcceptUnseen(country, match: p))
    }

    /// P1-02, as decided (ENTWURF-BEDIENUNG point 8, Fuchs 16.11.): "Dein Album 'Italien' gehört
    /// dem Vorschlag 'Italien'", with no share of its content asked for: two albums "Italien"
    /// confuse more than one extended album. The user's only album of that name is extended
    /// whatever else it holds, also with no photo of the country in it yet; never a second one.
    @Test func theOnlyAlbumOfTheNameIsExtendedWhateverItHolds() throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        for album in [
            CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it", 0..<40).union(set("food", 0..<200))),
            CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it", 0..<2).union(set("food", 0..<20))),
            CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("food", 0..<20)),
            CollectionSnapshot(id: "it", title: "Italien", assetIDs: []),
        ] {
            let c = try #require(matcher.match([country], against: CollectionInventory([album]))[country.id])
            #expect(ProposalDecision.recommended(for: country, match: c) == .extendExisting("it"), "\(album.assetIDs.count): \(c.status)")
            #expect(c.reasons.contains(.missingItems(count: 300 - album.assetIDs.intersection(italy).count)))
            // Its other photos stay where they are, and with them in it, the user looks first.
            #expect(!ProposalDecision.isSafeToAcceptUnseen(country, match: c) || album.assetIDs.isSubset(of: italy))
        }
        // The user said it does not fit: then it is not its album.
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("food", 0..<20))
        let rejected = OverrideSet([UserOverride(scope: .albumForSource("it", country.id), decision: .notMatchingAlbum)])
        let r = try #require(matcher.match([country], against: CollectionInventory([album]), overrides: rejected)[country.id])
        #expect(ProposalDecision.recommended(for: country, match: r) == .createNew(title: nil, folderPath: nil))
    }

    /// P1-02: photos without a location in the user's "Italien" (from the camera roll, a
    /// messenger) can never be in a place suggestion, so they never count against it: 150 Italy
    /// photos and 160 without a location is an album that is all Italy, chosen unseen like one.
    @Test func photosWithoutALocationDoNotCountAgainstAPlace() throws {
        let italy = set("it", 0..<300)
        let unlocated = set("noloc", 0..<160)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        let album = CollectionSnapshot(id: "it", title: "Italien", assetIDs: set("it", 0..<150).union(unlocated))
        let c = try #require(matcher.match([country], against: CollectionInventory([album]), unlocated: unlocated)[country.id])
        #expect(ProposalDecision.recommended(for: country, match: c) == .extendExisting("it"))
        #expect(c.best?.metrics.purity == 1)
        #expect(ProposalDecision.isSafeToAcceptUnseen(country, match: c))
        // Only for the album of the name (third review 19.11., S6): under another name the
        // content decides with every photo, and 160 of 310 are not Italy.
        let named = CollectionSnapshot(id: "u", title: "Urlaub in Italien", assetIDs: album.assetIDs)
        let u = try #require(matcher.match([country], against: CollectionInventory([named]), unlocated: unlocated)[country.id])
        #expect(ProposalDecision.recommended(for: country, match: u).extendedAlbum == nil, "\(u.status)")
        // Not for a theme: a photo without a location can be a dog photo.
        let dogs = AlbumProposal(id: AlbumistID("dogs"), kind: .imageCategory("dog"), title: "Hunde", assetIDs: set("dog", 0..<100))
        let h = CollectionSnapshot(id: "h", title: "Meine Tiere", assetIDs: set("dog", 0..<60).union(unlocated))
        let d = try #require(matcher.match([dogs], against: CollectionInventory([h]), unlocated: unlocated)[dogs.id])
        #expect(d.best.map { $0.metrics.purity < 0.5 } ?? true)
    }

    /// Third review 19.11. (S6): photos without a location are left out only for the album
    /// named exactly like the place. An album that holds the whole country among many photos
    /// without a location ("Alle Fotos", "iPhone-Export", "Sommer 2019") stays what it was by
    /// its content: never the country's album, never "so lassen", and the country's photos do
    /// not count as sorted through it (review 16.11., A1 and A3).
    @Test(arguments: [("Sommer 2019", 1_000), ("Alle Fotos", 5_000), ("iPhone-Export", 300)])
    func photosWithoutALocationCountForOtherAlbums(title: String, unlocatedCount: Int) throws {
        let italy = set("it", 0..<300)
        let unlocated = set("noloc", 0..<unlocatedCount)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        let album = CollectionSnapshot(id: "x", title: title, assetIDs: italy.union(unlocated))
        let plain = try #require(matcher.match([country], against: CollectionInventory([album]))[country.id])
        let with = try #require(matcher.match([country], against: CollectionInventory([album]), unlocated: unlocated)[country.id])
        #expect(with.status != .alreadyComplete && with.status != .extendable, "\(title): \(with.status)")
        #expect(ProposalDecision.recommended(for: country, match: with).existingAlbum == nil)
        #expect(!matcher.sortingAlbums(with, kind: country.kind, title: country.title).contains("x"))
        #expect(with.status == plain.status && with.best?.albumID == plain.best?.albumID)
    }

    /// Third review 19.11. (M3): another album of the user already holds the whole country
    /// ("Italia" with all 300 photos, or "Urlaub Italien"). It stays the country's album, as
    /// complete, and keeps the photos counted as sorted; the album named "Italien" (a few of the
    /// photos and others, one trip, or empty) gets nothing. Before, the name won and the ring
    /// fell back by 298 photos at launch without the user doing anything.
    @Test func anAlbumHoldingTheWholeSuggestionWinsOverTheName() throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        let full = CollectionSnapshot(id: "full", title: "Italia", assetIDs: italy)
        let strays: [Set<AssetID>] = [set("it", 0..<2).union(set("food", 0..<20)), set("food", 0..<20), [], set("it", 0..<100)]
        for stray in strays {
            let named = CollectionSnapshot(id: "named", title: "Italien", assetIDs: stray)
            let m = try #require(matcher.match([country], against: CollectionInventory([full, named]))[country.id])
            #expect(m.status == .alreadyComplete && m.best?.albumID == "full", "\(stray.count): \(m.status) \(String(describing: m.best?.albumID))")
            #expect(ProposalDecision.recommended(for: country, match: m) == .keepExisting("full"))
            #expect(matcher.sortingAlbums(m, kind: country.kind, title: country.title).contains("full"))
        }
        // Both hold everything: the album of the name stays it, complete.
        let both = CollectionSnapshot(id: "named", title: "Italien", assetIDs: italy.union(set("food", 0..<20)))
        let b = try #require(matcher.match([country], against: CollectionInventory([full, both]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: b) == .keepExisting("named"), "\(b.status)")
        // "Urlaub Italien" holds every trip, "Italien" the first one (matched with the trips).
        let trips = [set("it", 0..<100), set("it", 100..<200), set("it", 200..<300)]
        let holiday = CollectionSnapshot(id: "holiday", title: "Urlaub Italien", assetIDs: italy)
        let first = CollectionSnapshot(id: "named", title: "Italien", assetIDs: trips[0])
        let m = try #require(matcher.match([country], against: CollectionInventory([holiday, first]), trips: trips)[country.id])
        #expect(m.status == .alreadyComplete && m.best?.albumID == "holiday", "\(m.status) \(String(describing: m.best?.albumID))")
        #expect(ProposalDecision.recommended(for: country, match: m) == .keepExisting("holiday"))
        // Without such an album the name still wins.
        let alone = try #require(matcher.match([country], against: CollectionInventory([first]), trips: trips)[country.id])
        #expect(ProposalDecision.recommended(for: country, match: alone) == .extendExisting("named"))
    }

    /// The country's photos the ring counts as sorted: those in an album that sorts them.
    func sortedCount(_ proposal: AlbumProposal, _ albums: [CollectionSnapshot]) throws -> Int {
        let inventory = CollectionInventory(albums)
        let m = try #require(matcher.match([proposal], against: inventory)[proposal.id])
        let sorting = matcher.sortingAlbums(m, kind: proposal.kind, title: proposal.title)
        return proposal.assetIDs.filter { id in sorting.contains { inventory[$0]?.assetIDs.contains(id) == true } }.count
    }

    /// Final check 19.11. (N1): the user's "Urlaub in Italien" holds most of the country and is
    /// its album by content; "Italien" holds a few photos. The name rule makes "Italien" the
    /// album to extend (decision Fuchs 16.11.), but the photos in "Urlaub in Italien" stay
    /// sorted: before the rule, 200, 250 and 290 counted, after it only 50, 10 and 100, and the
    /// ring fell back at launch without any step of the user.
    @Test(arguments: [(200, 50), (250, 10), (290, 100)])
    func theAlbumThatFitsByContentKeepsCountingWhenTheNameWins(holiday: Int, named: Int) throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        let urlaub = CollectionSnapshot(id: "urlaub", title: "Urlaub in Italien", assetIDs: set("it", 0..<holiday))
        let italien = CollectionSnapshot(id: "named", title: "Italien", assetIDs: set("it", (300 - named)..<300))
        let m = try #require(matcher.match([country], against: CollectionInventory([urlaub, italien]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: m) == .extendExisting("named"))
        #expect(try sortedCount(country, [urlaub, italien]) >= holiday)
        #expect(matcher.sortingAlbums(m, kind: country.kind, title: country.title).contains("urlaub"))
    }

    /// N1 as a rule over many sizes: adding the album named like the suggestion (the name rule
    /// then decides) never lowers the number of the suggestion's photos counted as sorted.
    @Test func theNameRuleNeverLowersTheSortedCount() throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        var checked = 0
        for holiday in [0, 30, 80, 150, 200, 250, 290, 300] {
            for other in [0, 20, 60] {
                let urlaub = CollectionSnapshot(id: "urlaub", title: "Urlaub in Italien", assetIDs: set("it", 0..<holiday).union(set("other", 0..<other)))
                let before = try sortedCount(country, [urlaub])
                for named in [0, 10, 50, 100, 200, 300] {
                    for food in [0, 40] {
                        let italien = CollectionSnapshot(id: "named", title: "Italien",
                                                         assetIDs: set("it", (300 - named)..<300).union(set("food", 0..<food)))
                        let after = try sortedCount(country, [urlaub, italien])
                        #expect(after >= before, "Urlaub \(holiday)+\(other), Italien \(named)+\(food): \(after) < \(before)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 288)
    }

    /// Sorted counts of the country "Italien" (300 photos) before the name rule, measured with
    /// integ/next (matching version 4): album "U" ("Urlaub in Italien") or "S" ("Sommer") with
    /// the first h photos of Italy and `other` other photos, and "Italien" with the last n and
    /// `food` other photos. Entries: kind,h,other,n,food,sorted.
    static let versionFourSortedCounts = """
        U,65,0,0,0,0 U,65,0,0,40,0 U,65,0,5,0,65 U,65,0,5,40,0 U,65,0,10,0,10 U,65,0,10,40,0 U,65,0,100,0,100
        U,65,0,100,40,0 U,65,0,300,0,300 U,65,0,300,40,300 U,65,60,0,0,0 U,65,60,0,40,0 U,65,60,5,0,0
        U,65,60,5,40,0 U,65,60,10,0,0 U,65,60,10,40,0 U,65,60,100,0,100 U,65,60,100,40,0 U,65,60,300,0,300
        U,65,60,300,40,300 U,70,0,0,0,0 U,70,0,0,40,0 U,70,0,5,0,70 U,70,0,5,40,0 U,70,0,10,0,70 U,70,0,10,40,0
        U,70,0,100,0,100 U,70,0,100,40,0 U,70,0,300,0,300 U,70,0,300,40,300 U,70,60,0,0,0 U,70,60,0,40,0
        U,70,60,5,0,0 U,70,60,5,40,0 U,70,60,10,0,0 U,70,60,10,40,0 U,70,60,100,0,100 U,70,60,100,40,0
        U,70,60,300,0,300 U,70,60,300,40,300 U,150,0,0,0,150 U,150,0,0,40,150 U,150,0,5,0,150 U,150,0,5,40,150
        U,150,0,10,0,150 U,150,0,10,40,150 U,150,0,100,0,100 U,150,0,100,40,150 U,150,0,300,0,300
        U,150,0,300,40,300 U,150,60,0,0,0 U,150,60,0,40,0 U,150,60,5,0,0 U,150,60,5,40,0 U,150,60,10,0,0
        U,150,60,10,40,0 U,150,60,100,0,100 U,150,60,100,40,0 U,150,60,300,0,300 U,150,60,300,40,300
        U,250,0,0,0,250 U,250,0,0,40,250 U,250,0,5,0,250 U,250,0,5,40,250 U,250,0,10,0,250 U,250,0,10,40,250
        U,250,0,100,0,250 U,250,0,100,40,250 U,250,0,300,0,300 U,250,0,300,40,300 U,250,60,0,0,250
        U,250,60,0,40,250 U,250,60,5,0,250 U,250,60,5,40,250 U,250,60,10,0,250 U,250,60,10,40,250
        U,250,60,100,0,250 U,250,60,100,40,250 U,250,60,300,0,300 U,250,60,300,40,300 U,300,0,0,0,300
        U,300,0,0,40,300 U,300,0,5,0,300 U,300,0,5,40,300 U,300,0,10,0,300 U,300,0,10,40,300 U,300,0,100,0,300
        U,300,0,100,40,300 U,300,0,300,0,300 U,300,0,300,40,300 U,300,60,0,0,300 U,300,60,0,40,300 U,300,60,5,0,300
        U,300,60,5,40,300 U,300,60,10,0,300 U,300,60,10,40,300 U,300,60,100,0,300 U,300,60,100,40,300
        U,300,60,300,0,300 U,300,60,300,40,300 S,65,0,0,0,0 S,65,0,0,40,0 S,65,0,5,0,0 S,65,0,5,40,0 S,65,0,10,0,0
        S,65,0,10,40,0 S,65,0,100,0,100 S,65,0,100,40,0 S,65,0,300,0,300 S,65,0,300,40,300 S,65,60,0,0,0
        S,65,60,0,40,0 S,65,60,5,0,0 S,65,60,5,40,0 S,65,60,10,0,0 S,65,60,10,40,0 S,65,60,100,0,100
        S,65,60,100,40,0 S,65,60,300,0,300 S,65,60,300,40,300 S,70,0,0,0,0 S,70,0,0,40,0 S,70,0,5,0,0 S,70,0,5,40,0
        S,70,0,10,0,0 S,70,0,10,40,0 S,70,0,100,0,100 S,70,0,100,40,0 S,70,0,300,0,300 S,70,0,300,40,300
        S,70,60,0,0,0 S,70,60,0,40,0 S,70,60,5,0,0 S,70,60,5,40,0 S,70,60,10,0,0 S,70,60,10,40,0 S,70,60,100,0,100
        S,70,60,100,40,0 S,70,60,300,0,300 S,70,60,300,40,300 S,150,0,0,0,0 S,150,0,0,40,0 S,150,0,5,0,0
        S,150,0,5,40,0 S,150,0,10,0,0 S,150,0,10,40,0 S,150,0,100,0,100 S,150,0,100,40,0 S,150,0,300,0,300
        S,150,0,300,40,300 S,150,60,0,0,0 S,150,60,0,40,0 S,150,60,5,0,0 S,150,60,5,40,0 S,150,60,10,0,0
        S,150,60,10,40,0 S,150,60,100,0,100 S,150,60,100,40,0 S,150,60,300,0,300 S,150,60,300,40,300 S,250,0,0,0,0
        S,250,0,0,40,0 S,250,0,5,0,0 S,250,0,5,40,0 S,250,0,10,0,0 S,250,0,10,40,0 S,250,0,100,0,100
        S,250,0,100,40,0 S,250,0,300,0,300 S,250,0,300,40,300 S,250,60,0,0,0 S,250,60,0,40,0 S,250,60,5,0,0
        S,250,60,5,40,0 S,250,60,10,0,0 S,250,60,10,40,0 S,250,60,100,0,100 S,250,60,100,40,0 S,250,60,300,0,300
        S,250,60,300,40,300 S,300,0,0,0,300 S,300,0,0,40,300 S,300,0,5,0,300 S,300,0,5,40,300 S,300,0,10,0,300
        S,300,0,10,40,300 S,300,0,100,0,300 S,300,0,100,40,300 S,300,0,300,0,300 S,300,0,300,40,300
        S,300,60,0,0,300 S,300,60,0,40,300 S,300,60,5,0,300 S,300,60,5,40,300 S,300,60,10,0,300 S,300,60,10,40,300
        S,300,60,100,0,300 S,300,60,100,40,300 S,300,60,300,0,300 S,300,60,300,40,300
        """

    /// Final check 19.11. (N1, the last gap): measured against version 4 itself, the name rule
    /// never lowers the sorted count. "Urlaub in Italien" with 70 of 300 photos and "Italien"
    /// with 5 were several matching albums with "Urlaub" first, which counted (70); after the
    /// rule only 5 counted, because "Urlaub" holds less than 25 % of the country.
    @Test func theNameRuleNeverCountsFewerThanVersionFour() throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"],
                                    assetIDs: italy, reliability: .certain)
        let rows = Self.versionFourSortedCounts.split(whereSeparator: \.isWhitespace).map { $0.split(separator: ",") }
        #expect(rows.count == 200)
        for row in rows {
            let n = row.dropFirst().compactMap { Int($0) }
            try #require(n.count == 5)
            let first = CollectionSnapshot(id: "u", title: row[0] == "U" ? "Urlaub in Italien" : "Sommer",
                                           assetIDs: set("it", 0..<n[0]).union(set("other", 0..<n[1])))
            let named = CollectionSnapshot(id: "n", title: "Italien", assetIDs: set("it", (300 - n[2])..<300).union(set("food", 0..<n[3])))
            let now = try sortedCount(country, [first, named])
            #expect(now >= n[4], "\(row.joined(separator: ",")): \(now) sorted, version 4 counted \(n[4])")
        }
    }

    /// P1-02: with two albums of that name the content picks between them; a third "Italien" is
    /// never made. When they fit exactly as well, the user picks (nothing is decided for them).
    @Test func withTwoAlbumsOfTheNameTheContentPicksOne() throws {
        let italy = set("it", 0..<300)
        let country = AlbumProposal(id: AlbumistID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"], assetIDs: italy)
        let first = CollectionSnapshot(id: "it1", title: "Italien", assetIDs: set("it", 0..<60))
        let second = CollectionSnapshot(id: "it2", title: "Italien", assetIDs: set("it", 100..<130))
        let two = try #require(matcher.match([country], against: CollectionInventory([first, second]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: two) == .extendExisting("it1"), "\(two.status)")
        // One mostly other photos: still the content picks the one with more of the country.
        let food = CollectionSnapshot(id: "it2", title: "Italien", assetIDs: set("it", 100..<102).union(set("food", 0..<300)))
        let mixed = try #require(matcher.match([country], against: CollectionInventory([first, food]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: mixed) == .extendExisting("it1"), "\(mixed.status)")
        // Neither holds any of it: the user picks.
        let a = CollectionSnapshot(id: "a", title: "Italien", assetIDs: set("food", 0..<10))
        let b = CollectionSnapshot(id: "b", title: "Italien", assetIDs: set("wine", 0..<10))
        let none = try #require(matcher.match([country], against: CollectionInventory([a, b]))[country.id])
        #expect(ProposalDecision.recommended(for: country, match: none) == .undecided, "\(none.status)")
        let offered = Set(none.alternatives.map(\.albumID) + [none.best?.albumID].compactMap { $0 })
        #expect(offered.isSuperset(of: ["a", "b"]))
    }

    /// A year in the name stays a part: the trip keeps "Italien 2019", the country does not
    /// grow it. Another name: the content decides, as before.
    @Test func yearOrOtherNameDoNotWin() throws {
        let dated = CollectionSnapshot(id: "it", title: "Italien 2019", assetIDs: y19)
        let r = matcher.match([trip, country], against: CollectionInventory([dated]))
        #expect(r[trip.id]?.status == .alreadyComplete)
        #expect(ProposalDecision.recommended(for: country, match: r[country.id]) == .createNew(title: nil, folderPath: nil))

        let other = CollectionSnapshot(id: "it", title: "Urlaub in Italien", assetIDs: y19)
        let o = matcher.match([trip, country], against: CollectionInventory([other]))
        #expect(o[trip.id]?.status == .alreadyComplete)
        #expect(ProposalDecision.recommended(for: country, match: o[country.id]) == .createNew(title: nil, folderPath: nil))
    }
}

