import Foundation
import Testing
@testable import AlbumistCore

/// What the start page "Vorschläge" shows in every state (design wave 1, drafts E1, E6, E7):
/// the first analysis with its mosaic and "Schon gefunden" (9A), "Dein Startpaket" after it,
/// "Neue Reisen" later, the rows with trips first and "Deine Welt" right under them, "Alle
/// Vorschläge" at the end, nothing open (and why), an empty library, 0, 1 and over 300
/// suggestions, free albums used up, an interrupted plan, a cut-off analysis, which suggestions
/// count as open, and nothing moving under the user's finger after "Anlegen" on a card (7B).
@Suite("Start page")
struct StartPageTests {
    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let areas: [OrganizationArea] = [.places, .trips, .frequentPlaces, .messenger, .screenshots,
                                            .imageCategories, .documents, .chronology, .mediaTypes]

    /// A trip that ended `daysAgo` days before `now`, with `photos` photos.
    static func trip(_ name: String, daysAgo: Double, photos: Int = 20) -> AlbumProposal {
        let end = now.addingTimeInterval(-daysAgo * day)
        return AlbumProposal(id: AlbumistID("trip.\(name)"), kind: .trip, title: name,
                             assetIDs: Set((0..<photos).map { AssetID("\(name).\($0)") }),
                             dateRange: DateInterval(start: end.addingTimeInterval(-3 * day), end: end))
    }

    static func place(_ name: String, photos: Int = 30) -> AlbumProposal {
        AlbumProposal(id: AlbumistID("place.\(name)"), kind: .placeCollection(.country), title: name,
                      assetIDs: Set((0..<photos).map { AssetID("\(name).\($0)") }))
    }

    static func proposal(_ name: String, _ kind: ProposalKind, photos: Int = 12) -> AlbumProposal {
        AlbumProposal(id: AlbumistID("\(kind.familyKey).\(name)"), kind: kind, title: name,
                      assetIDs: Set((0..<photos).map { AssetID("\(name).\($0)") }))
    }

    static let kyoto = trip("Kyoto, Oktober 2024", daysAgo: 30)
    static let rome = trip("Rom, Juni 2022", daysAgo: 400)
    static let split = trip("Split, August 2023", daysAgo: 300)
    static let lisbon = trip("Lissabon, Mai 2021", daysAgo: 800)
    static let italy = place("Italien")
    static let japan = place("Japan", photos: 50)
    static let lindau = proposal("Häufiger Ort in Lindau", .frequentPlace)
    static let contracts = proposal("Verträge", .documentCategory("contracts"))

    /// `starterSet`: how many albums "Dein Startpaket" would hold now; the model offers the
    /// first open ones here. `freeLimit`: how many it may hold now (`StartPage.starterSetLimit`).
    static func page(_ proposals: [AlbumProposal], open: [AlbumProposal]? = nil, analysedOnce: Bool = true,
                     mosaic: Bool = false, starterSet: Int = 0, freeLimit: Int = StartPage.starterSetMaximum,
                     nothingMade: Bool = true, libraryHint: Bool = false,
                     rebuilding: Bool = false, analysing: Bool = false, interrupted: Bool = false,
                     inYourAlbums: Int = 0, areas: [OrganizationArea] = areas,
                     visit: StartVisit = StartVisit()) -> StartPage {
        let open = open ?? proposals
        return StartPage.make(.init(proposals: proposals, open: Set(open.map(\.id)), areas: areas,
                                    analysedOnce: analysedOnce, showsMosaic: mosaic,
                                    starterSet: open.prefix(starterSet).map(\.id), starterSetLimit: freeLimit,
                                    nothingMadeYet: nothingMade,
                                    libraryHint: libraryHint, rebuilding: rebuilding, analysing: analysing,
                                    interruptedPlan: interrupted, inYourAlbums: inYourAlbums, visit: visit))
    }

    /// The sections by name, so an expectation reads like the page: "row.trips", "atlas" …
    static func names(_ page: StartPage) -> [String] { page.sections.map(\.id) }

    static func row(_ area: OrganizationArea, in page: StartPage) -> StartPage.Row? {
        for case .row(let row) in page.sections where row.area == area { return row }
        return nil
    }

    // MARK: The first analysis

    /// E6 "Analyse läuft": the mosaic, then "Schon gefunden" with the newest trips as big cards
    /// (9A), then the other trips in their row and "Deine Welt" under them.
    @Test func theFirstAnalysisShowsTheMosaicAndTheTripsFoundSoFar() {
        let all = [Self.rome, Self.kyoto, Self.split, Self.lisbon, Self.italy]
        let page = Self.page(all, analysedOnce: false, mosaic: true, starterSet: 4)
        #expect(Self.names(page) == ["mosaic", "earlyTrips", "row.trips", "atlas", "row.places", "allSuggestions"])
        #expect(page.bigCards == [Self.kyoto.id, Self.split.id], "newest first, two at most")
        #expect(Self.row(.trips, in: page)?.cards == [Self.rome.id, Self.lisbon.id], "the big cards are not repeated")
        #expect(Self.row(.trips, in: page)?.openCount == 4, "\"Alle 4\" counts every open trip")
        // No "Dein Startpaket" before the analysis went through, also with enough albums.
        #expect(!page.showsStarterSet)
    }

    /// Paused or waiting, the first analysis is still not through: the same page, without the
    /// mosaic when it is not shown.
    @Test func aPausedFirstAnalysisKeepsTheTripsFound() {
        let page = Self.page([Self.kyoto, Self.italy], analysedOnce: false, mosaic: false)
        #expect(Self.names(page) == ["earlyTrips", "atlas", "row.places", "allSuggestions"])
        #expect(page.bigCards == [Self.kyoto.id])
    }

    /// Before the first trip comes, the mosaic shows the user's own photos; no empty section
    /// and no "Alles erledigt" while the analysis has not gone through.
    @Test func beforeTheFirstSuggestionOnlyTheMosaic() {
        #expect(Self.names(Self.page([], analysedOnce: false, mosaic: true)) == ["mosaic", "atlas"])
        #expect(Self.names(Self.page([], analysedOnce: false)) == ["atlas"])
    }

    // MARK: After the first analysis

    /// E1: the analysis went through, nothing made: "Dein Startpaket", then "Reisen · Alle 4"
    /// with the trips (the newest one too: the starter set is the big part now).
    @Test func afterTheAnalysisTheStarterSetAndTheRows() {
        let all = [Self.rome, Self.kyoto, Self.split, Self.lisbon, Self.italy, Self.japan, Self.lindau, Self.contracts]
        let page = Self.page(all, starterSet: 6)
        #expect(Self.names(page) == ["starterSet", "row.trips", "atlas", "row.places", "row.frequentPlaces", "row.documents",
                                     "allSuggestions"])
        #expect(page.starterSet?.count == 6)
        #expect(Self.row(.trips, in: page)?.cards == [Self.kyoto.id, Self.split.id, Self.rome.id, Self.lisbon.id])
        #expect(Self.row(.places, in: page)?.cards == [Self.japan.id, Self.italy.id], "biggest first")
        #expect(page.bigCards.isEmpty)
    }

    /// "Dein Startpaket" needs three albums; with fewer the newest trips are the big part.
    @Test func aStarterSetNeedsThreeAlbums() {
        let page = Self.page([Self.kyoto, Self.rome, Self.italy], starterSet: 2)
        #expect(!page.showsStarterSet)
        #expect(Self.names(page) == ["newTrips", "atlas", "row.places", "allSuggestions"])
        #expect(page.bigCards == [Self.kyoto.id, Self.rome.id])
    }

    /// Free albums used up (E6): no starter set (its limit is 0), the cards stay with "Anlegen"
    /// (which opens the purchase sheet), "Neue Reisen" on top.
    @Test func freeAlbumsUsedUpLeaveNoStarterSet() {
        #expect(StartPage.starterSetLimit(unlocked: false, freeAlbumsLeft: 0) == 0)
        #expect(StartPage.starterSetLimit(unlocked: false, freeAlbumsLeft: 2) == 2)
        #expect(StartPage.starterSetLimit(unlocked: false, freeAlbumsLeft: 7) == 7)
        #expect(StartPage.starterSetLimit(unlocked: false, freeAlbumsLeft: 25) == 10)
        #expect(StartPage.starterSetLimit(unlocked: false, freeAlbumsLeft: -1) == 0)
        #expect(StartPage.starterSetLimit(unlocked: true, freeAlbumsLeft: 0) == 10)
        let made = Self.now.addingTimeInterval(-60 * Self.day)
        let page = Self.page([Self.kyoto, Self.rome, Self.split], starterSet: 0, nothingMade: false,
                             visit: StartVisit(lastMade: made))
        #expect(!page.showsStarterSet)
        #expect(Self.names(page) == ["newTrips", "row.trips", "atlas", "allSuggestions"])
        #expect(page.bigCards == [Self.kyoto.id], "only the trip after the last album is new")
    }

    /// Once an album was made, "Neue Reisen" are the trips that ended after it, newest first.
    @Test func newTripsAreTheOnesAfterTheLastAlbum() {
        let lastMade = Self.now.addingTimeInterval(-350 * Self.day)
        let page = Self.page([Self.kyoto, Self.rome, Self.split, Self.lisbon], starterSet: 5, nothingMade: false,
                             visit: StartVisit(lastMade: lastMade))
        #expect(Self.names(page) == ["newTrips", "row.trips", "atlas", "allSuggestions"])
        #expect(page.bigCards == [Self.kyoto.id, Self.split.id])
        #expect(Self.row(.trips, in: page)?.cards == [Self.rome.id, Self.lisbon.id])
        // Nothing new since: no big part, the trips in their row.
        let later = Self.page([Self.rome, Self.lisbon], nothingMade: false, visit: StartVisit(lastMade: lastMade))
        #expect(Self.names(later) == ["row.trips", "atlas", "allSuggestions"])
        // A trip without dates is never "new".
        var undated = Self.trip("Ohne Datum", daysAgo: 1)
        undated.dateRange = nil
        #expect(Self.page([undated], nothingMade: false, visit: StartVisit(lastMade: lastMade)).bigCards.isEmpty)
    }

    // MARK: Nothing moves under the finger (7B)

    /// E6 "Nach dem Anlegen": "Anlegen" on a big card made it; it keeps its place and says
    /// "Angelegt", the row counts one fewer ("Alle 40").
    @Test func aCardMadeHereKeepsItsPlace() {
        let all = [Self.kyoto, Self.rome, Self.split, Self.lisbon]
        var visit = StartVisit(lastMade: nil)
        let before = Self.page(all, nothingMade: false, visit: visit)
        #expect(before.bigCards == [Self.kyoto.id, Self.split.id])
        visit.saw(before)
        visit.create(Self.kyoto.id)
        // Made: no longer open.
        let after = Self.page(all, open: [Self.rome, Self.split, Self.lisbon], nothingMade: false, visit: visit)
        #expect(after.bigCards == [Self.kyoto.id, Self.split.id], "the made card stays where it was")
        #expect(after.made == [Self.kyoto.id])
        #expect(Self.row(.trips, in: after)?.openCount == 3, "the made card no longer counts, the big open one does")
        #expect(Self.row(.trips, in: after)?.cards == [Self.rome.id, Self.lisbon.id])
        // "Widerrufen": open again, the card says "Anlegen" again, still in its place.
        let undone = Self.page(all, nothingMade: false, visit: visit)
        #expect(undone.bigCards == [Self.kyoto.id, Self.split.id])
        #expect(undone.made.isEmpty)
        // The next visit starts afresh: the made trip is gone.
        let next = Self.page(all, open: [Self.rome, Self.split, Self.lisbon], nothingMade: false, visit: StartVisit(lastMade: Self.now))
        #expect(next.bigCards.isEmpty)
        #expect(!next.sections.contains { $0.id == "newTrips" })
    }

    /// A card made in a row stays in the row (it does not jump to the top or vanish).
    @Test func aCardMadeInARowStaysInTheRow() {
        var visit = StartVisit()
        visit.create(Self.italy.id)
        let page = Self.page([Self.italy, Self.japan], open: [Self.japan], visit: visit)
        #expect(Self.row(.places, in: page)?.cards == [Self.japan.id, Self.italy.id])
        #expect(Self.row(.places, in: page)?.openCount == 1)
        #expect(page.made == [Self.italy.id])
    }

    /// "Anlegen" on a row card made the first album while "Dein Startpaket" was shown: it stays
    /// for this visit (the page does not jump), and goes with the next.
    @Test func theStarterSetStaysForTheVisitItWasShownIn() {
        let all = [Self.kyoto, Self.rome, Self.split]
        var visit = StartVisit()
        let first = Self.page(all, starterSet: 3, visit: visit)
        #expect(first.showsStarterSet)
        visit.saw(first)
        visit.create(Self.kyoto.id)
        let after = Self.page(all, open: [Self.rome, Self.split], starterSet: 3, nothingMade: false, visit: visit)
        #expect(after.starterSet == [Self.rome.id, Self.split.id], "with what is left of it")
        #expect(Self.row(.trips, in: after)?.cards == [Self.kyoto.id, Self.split.id, Self.rome.id])
        let next = Self.page(all, open: [Self.rome, Self.split], starterSet: 3, nothingMade: false, visit: StartVisit(lastMade: Self.now))
        #expect(!next.showsStarterSet)
    }

    /// The big cards stay while they exist: a newer trip found during the first analysis goes
    /// into the row instead of pushing a big card away; a big card that went is replaced.
    @Test func theBigCardsStayWhileTheyExist() {
        var visit = StartVisit()
        let first = Self.page([Self.rome, Self.split, Self.lisbon], analysedOnce: false, visit: visit)
        #expect(first.bigCards == [Self.split.id, Self.rome.id])
        visit.saw(first)
        let newer = Self.page([Self.rome, Self.split, Self.lisbon, Self.kyoto], analysedOnce: false, visit: visit)
        #expect(newer.bigCards == [Self.split.id, Self.rome.id])
        #expect(Self.row(.trips, in: newer)?.cards == [Self.kyoto.id, Self.lisbon.id])
        let gone = Self.page([Self.rome, Self.lisbon, Self.kyoto], analysedOnce: false, visit: visit)
        #expect(gone.bigCards == [Self.rome.id, Self.kyoto.id])
    }

    // MARK: Few and many

    /// Nothing open after the analysis: one calm card that says why, no empty rows. Everything
    /// decided: "Alles erledigt". No suggestion at all: "Noch keine Vorschläge" (a run that goes
    /// on may still find some). Made anew ("Nur 2026" → "Alle Jahre", a recount, "Analyse neu
    /// aufbauen"): "Wird neu berechnet". A long run goes on: never "Alles erledigt", more may
    /// come. With the card for an empty library, that card explains it.
    @Test func nothingOpenSaysWhy() {
        let decided = [Self.kyoto, Self.italy]
        #expect(Self.names(Self.page(decided, open: [])) == ["caughtUp", "atlas", "allSuggestions"])
        #expect(Self.page([]).sections == [.noSuggestionsYet(analysing: false), .atlas])
        #expect(Self.page([], analysing: true).sections == [.noSuggestionsYet(analysing: true), .atlas])
        #expect(Self.names(Self.page(decided, open: [], rebuilding: true)) == ["rebuilding", "atlas", "allSuggestions"])
        #expect(Self.names(Self.page([], rebuilding: true)) == ["rebuilding", "atlas"])
        #expect(Self.names(Self.page([], rebuilding: true, analysing: true)) == ["rebuilding", "atlas"])
        #expect(Self.names(Self.page(decided, open: [], analysing: true)) == ["atlas", "allSuggestions"])
        #expect(Self.names(Self.page([], libraryHint: true)) == ["atlas"])
        #expect(Self.names(Self.page([], libraryHint: true, rebuilding: true)) == ["atlas"])
    }

    /// One suggestion: a trip is the big part, a place its own row of one card.
    @Test func oneSuggestion() {
        #expect(Self.names(Self.page([Self.kyoto])) == ["newTrips", "atlas", "allSuggestions"])
        let place = Self.page([Self.italy])
        #expect(Self.names(place) == ["atlas", "row.places", "allSuggestions"])
        #expect(Self.row(.places, in: place)?.showsAll == false, "no \"Alle 1\"")
    }

    /// Over 300 suggestions: rows of ten, "Alle 300" leads to the rest; the page stays short.
    @Test func overThreeHundredSuggestions() {
        let trips = (0..<300).map { Self.trip("Reise \($0)", daysAgo: Double($0 + 1)) }
        let places = (0..<40).map { Self.place("Land \($0)", photos: 10 + $0) }
        let page = Self.page(trips + places, starterSet: 10)
        #expect(Self.names(page) == ["starterSet", "row.trips", "atlas", "row.places", "allSuggestions"])
        #expect(page.sections.last == .allSuggestions(.init(total: 340, inYourAlbums: 0, rebuilding: false)))
        let row = Self.row(.trips, in: page)
        #expect(row?.cards.count == StartPage.rowLimit)
        #expect(row?.openCount == 300)
        #expect(row?.showsAll == true)
        #expect(row?.cards.first == trips[0].id, "newest first")
        #expect(Self.row(.places, in: page)?.cards.first == places[39].id, "biggest first")
    }

    // MARK: Areas

    /// The rows follow the areas that are on: trips first, "Deine Welt" under them, places,
    /// then the others in the app's order; a turned-off area has no row.
    @Test func theRowsFollowTheAreasThatAreOn() {
        let screenshots = Self.proposal("Bestellungen", .screenshotCategory("orders"))
        let years = Self.proposal("2024", .chronology(.year))
        let all = [years, screenshots, Self.contracts, Self.lindau, Self.italy, Self.rome]
        let page = Self.page(all, starterSet: 0, nothingMade: false, visit: StartVisit(lastMade: Self.now))
        #expect(Self.names(page) == ["row.trips", "atlas", "row.places", "row.frequentPlaces", "row.screenshots",
                                     "row.documents", "row.chronology", "allSuggestions"])
        let withoutTrips = Self.page(all, nothingMade: false, areas: Self.areas.filter { $0 != .trips && $0 != .documents },
                                     visit: StartVisit(lastMade: Self.now))
        #expect(Self.names(withoutTrips) == ["atlas", "row.places", "row.frequentPlaces", "row.screenshots", "row.chronology",
                                             "allSuggestions"])
    }

    /// The section ids are unique, so the app can use them as identities.
    @Test func sectionIDsAreUnique() {
        let all = [Self.kyoto, Self.rome, Self.split, Self.italy, Self.lindau, Self.contracts]
        for page in [Self.page(all, analysedOnce: false, mosaic: true), Self.page(all, starterSet: 4), Self.page([])] {
            #expect(Set(Self.names(page)).count == page.sections.count, "\(Self.names(page))")
        }
    }

    // MARK: Which suggestions are open

    /// Open on the start page: no decision, or an accepted one that still changes something in
    /// Photos (a preview's pick, a choice under "Anpassen", a pick of the old basket), and not
    /// complete in Photos. Not open: "Nicht jetzt", kept as it is, complete.
    @Test func aSuggestionIsOpenUntilItIsDoneOrSetAside() {
        let album = CollectionID("album.toskana")
        #expect(StartPage.isOpen(decision: nil, complete: false))
        #expect(StartPage.isOpen(decision: .undecided, complete: false))
        #expect(StartPage.isOpen(decision: .createNew(title: nil, folderPath: nil), complete: false))
        #expect(StartPage.isOpen(decision: .createNew(title: "Bella Italia", folderPath: ["Länder"]), complete: false))
        #expect(StartPage.isOpen(decision: .extendExisting(album), complete: false))
        #expect(StartPage.isOpen(decision: .renameExisting(album, newTitle: "Toskana 2023", extend: true), complete: false))
        #expect(StartPage.isOpen(decision: .moveExisting(album, folderPath: ["Reisen"], extend: false), complete: false))
        #expect(StartPage.isOpen(decision: .merge(target: album, sources: [], title: nil, folderPath: nil), complete: false))
        #expect(!StartPage.isOpen(decision: .reject, complete: false), "\"Nicht jetzt\"")
        #expect(!StartPage.isOpen(decision: .keepExisting(album), complete: false), "kept as it is: nothing to do")
        #expect(!StartPage.isOpen(decision: nil, complete: true), "complete in Photos already")
        #expect(!StartPage.isOpen(decision: .createNew(title: nil, folderPath: nil), complete: true))
        #expect(!StartPage.isOpen(decision: .extendExisting(album), complete: true))
    }

    /// Suggestions chosen and waiting (picked for a preview, adjusted under "Anpassen", picked in
    /// the old basket of Build 40) stay on the page with their cards: never "Alles erledigt"
    /// while they wait, and none of them vanishes from its row.
    @Test func chosenSuggestionsStayOnThePage() {
        let all = [Self.kyoto, Self.italy, Self.lindau, Self.japan]
        let decisions: [AlbumistID: ProposalDecision] = [
            Self.kyoto.id: .createNew(title: nil, folderPath: nil),
            Self.italy.id: .createNew(title: "Bella Italia", folderPath: ["Länder"]),
            Self.japan.id: .extendExisting(CollectionID("album.japan")),
            Self.lindau.id: .reject,
        ]
        let open = all.filter { StartPage.isOpen(decision: decisions[$0.id], complete: false) }
        let page = Self.page(all, open: open, nothingMade: false)
        #expect(Self.names(page) == ["newTrips", "atlas", "row.places", "allSuggestions"])
        #expect(page.bigCards == [Self.kyoto.id])
        #expect(Self.row(.places, in: page)?.cards == [Self.japan.id, Self.italy.id])
        #expect(page.made.isEmpty)
    }
}
