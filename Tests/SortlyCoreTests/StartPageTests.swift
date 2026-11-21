import Foundation
import Testing
@testable import SortlyCore

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
        return AlbumProposal(id: SortlyID("trip.\(name)"), kind: .trip, title: name,
                             assetIDs: Set((0..<photos).map { AssetID("\(name).\($0)") }),
                             dateRange: DateInterval(start: end.addingTimeInterval(-3 * day), end: end))
    }

    static func place(_ name: String, photos: Int = 30) -> AlbumProposal {
        AlbumProposal(id: SortlyID("place.\(name)"), kind: .placeCollection(.country), title: name,
                      assetIDs: Set((0..<photos).map { AssetID("\(name).\($0)") }))
    }

    static func proposal(_ name: String, _ kind: ProposalKind, photos: Int = 12) -> AlbumProposal {
        AlbumProposal(id: SortlyID("\(kind.familyKey).\(name)"), kind: kind, title: name,
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
        let decisions: [SortlyID: ProposalDecision] = [
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

    // MARK: "Angelegt" only once the album is there (7B)

    /// "Anlegen" picks the suggestion for its plan while the album is made: still open, so the
    /// card shows its work, not "Angelegt". Made, the run clears the pick before the suggestions
    /// are matched again: the card keeps "Angelegt" meanwhile, never "Anlegen" in between. Once
    /// the page saw it done, "Widerrufen" brings "Anlegen" back in its place.
    @Test func aCardSaysMadeOnlyOnceItsAlbumIsInPhotos() {
        let all = [Self.kyoto, Self.rome, Self.split]
        let plan = SortlyID("plan.kyoto")
        var visit = StartVisit()
        visit.saw(Self.page(all, nothingMade: false, visit: visit))
        visit.create(Self.kyoto.id)
        let running = Self.page(all, nothingMade: false, visit: visit)
        #expect(running.made.isEmpty, "no \"Angelegt\" before the album exists")
        #expect(running.bigCards == [Self.kyoto.id, Self.split.id])
        visit.made(Self.kyoto.id, by: plan)
        let cleared = Self.page(all, nothingMade: false, visit: visit)
        #expect(cleared.made == [Self.kyoto.id])
        #expect(cleared.seenDone.isEmpty)
        #expect(Self.row(.trips, in: cleared)?.openCount == 2, "the made card no longer counts")
        let matched = Self.page(all, open: [Self.rome, Self.split], nothingMade: false, visit: visit)
        #expect(matched.made == [Self.kyoto.id])
        #expect(matched.seenDone == [Self.kyoto.id])
        #expect(matched.bigCards == [Self.kyoto.id, Self.split.id])
        visit.saw(matched)
        #expect(visit.awaitingDone.isEmpty)
        let undone = Self.page(all, nothingMade: false, visit: visit)
        #expect(undone.made.isEmpty)
        #expect(undone.bigCards == [Self.kyoto.id, Self.split.id], "\"Anlegen\" again, in its place")
    }

    /// A run with gaps leaves the album short of photos, so the suggestion stays open: the card
    /// says "Angelegt" for the visit, until the plan that made it is taken back.
    @Test func aCardMadeWithGapsSaysMadeUntilItsPlanIsTakenBack() {
        let all = [Self.kyoto, Self.rome]
        let plan = SortlyID("plan.kyoto")
        var visit = StartVisit()
        visit.create(Self.kyoto.id)
        visit.made(Self.kyoto.id, by: plan)
        #expect(Self.page(all, nothingMade: false, visit: visit).made == [Self.kyoto.id])
        visit.undone([SortlyID("plan.other")])
        #expect(Self.page(all, nothingMade: false, visit: visit).made == [Self.kyoto.id], "another plan was taken back")
        visit.undone([plan])
        #expect(Self.page(all, nothingMade: false, visit: visit).made.isEmpty)
        // Made without a known plan: held until the page sees it done.
        var unknown = StartVisit()
        unknown.made(Self.rome.id, by: nil)
        #expect(unknown.created == [Self.rome.id])
        #expect(Self.page(all, nothingMade: false, visit: unknown).made == [Self.rome.id])
    }

    /// "Anlegen" with the free albums used up opens the purchase sheet; after the purchase the
    /// album is made from there (`continueQuickCreate`) and its banner is all the page hears of
    /// it (review A of design wave 1, finding 10). The banner of a card tapped in this visit
    /// makes it "Angelegt" as the direct way does, also when its run left gaps; a banner for a
    /// suggestion this visit did not create changes nothing.
    @Test func aCardMadeAfterThePurchaseSheetSaysMade() {
        let all = [Self.kyoto, Self.rome]
        let plan = SortlyID("plan.kyoto")
        var visit = StartVisit()
        visit.create(Self.kyoto.id)
        #expect(Self.page(all, nothingMade: false, visit: visit).made.isEmpty, "the purchase sheet is up")
        visit.announced(Self.rome.id, by: SortlyID("plan.rome"))
        #expect(visit.awaitingDone.isEmpty, "made from another screen")
        #expect(!visit.created.contains(Self.rome.id))
        visit.announced(Self.kyoto.id, by: plan)
        #expect(Self.page(all, nothingMade: false, visit: visit).made == [Self.kyoto.id], "made with gaps: still open")
        #expect(Self.page(all, open: [Self.rome], nothingMade: false, visit: visit).made == [Self.kyoto.id])
        // Told twice (the direct way says it too): the same.
        let once = visit
        visit.announced(Self.kyoto.id, by: plan)
        visit.made(Self.kyoto.id, by: plan)
        #expect(visit == once)
        visit.undone([plan])
        #expect(Self.page(all, nothingMade: false, visit: visit).made.isEmpty, "\"Widerrufen\"")
    }

    // MARK: "Dein Startpaket" for the visit

    /// Once shown, "Dein Startpaket" stays for the visit with what is left of it: an album of it
    /// made from its card in a row leaves it, the others stay, and no other suggestion joins
    /// (the model would offer one meanwhile). Made completely, it goes.
    @Test func theStarterSetStaysWithWhatIsLeft() {
        let all = [Self.kyoto, Self.rome, Self.split, Self.italy, Self.japan]
        var visit = StartVisit()
        let first = Self.page(all, starterSet: 3, visit: visit)
        #expect(first.starterSet == [Self.kyoto.id, Self.rome.id, Self.split.id])
        visit.saw(first)
        visit.create(Self.rome.id)
        let one = Self.page(all, open: [Self.kyoto, Self.split, Self.italy, Self.japan], starterSet: 3,
                            nothingMade: false, visit: visit)
        #expect(one.starterSet == [Self.kyoto.id, Self.split.id])
        visit.saw(one)
        let two = Self.page(all, open: [Self.split, Self.italy, Self.japan], starterSet: 3, nothingMade: false, visit: visit)
        #expect(two.starterSet == [Self.split.id])
        // A card of it made and not yet seen done does not stay in it either.
        visit.made(Self.split.id, by: SortlyID("plan.split"))
        #expect(Self.page(all, open: [Self.split, Self.italy, Self.japan], starterSet: 3, nothingMade: false,
                          visit: visit).starterSet == nil)
        #expect(Self.page(all, open: [Self.italy, Self.japan], starterSet: 3, nothingMade: false, visit: visit).starterSet == nil)
        // Picked for its own preview, its albums are open still: the card stays as it was.
        var picked = StartVisit()
        picked.saw(Self.page(all, starterSet: 3, visit: picked))
        #expect(Self.page(all, starterSet: 3, nothingMade: false, visit: picked).starterSet
                == [Self.kyoto.id, Self.rome.id, Self.split.id])
    }

    /// "Dein Startpaket" never offers more albums than are free now (review A of design wave 1,
    /// finding 2): an album made from a card outside the set uses a free one, and "10 Alben
    /// kostenlos anlegen" over 9 free albums opened a preview that asked for the purchase. The
    /// set kept for the visit is cut to what is free, best first; with none left it goes and
    /// "Neue Reisen" is the big part again. A set formed now is cut first and then needs three.
    @Test func theStarterSetOffersNoMoreThanIsFree() {
        let all = [Self.kyoto, Self.rome, Self.split, Self.italy, Self.japan]
        var visit = StartVisit()
        let first = Self.page(all, starterSet: 4, freeLimit: 10, visit: visit)
        #expect(first.starterSet == [Self.kyoto.id, Self.rome.id, Self.split.id, Self.italy.id])
        visit.saw(first)
        #expect(Self.page(all, starterSet: 4, freeLimit: 4, nothingMade: false, visit: visit).starterSet?.count == 4)
        #expect(Self.page(all, starterSet: 4, freeLimit: 3, nothingMade: false, visit: visit).starterSet
                == [Self.kyoto.id, Self.rome.id, Self.split.id])
        #expect(Self.page(all, starterSet: 4, freeLimit: 1, nothingMade: false, visit: visit).starterSet == [Self.kyoto.id])
        let none = Self.page(all, starterSet: 4, freeLimit: 0, nothingMade: false, visit: visit)
        #expect(none.starterSet == nil)
        #expect(Self.names(none) == ["newTrips", "row.trips", "atlas", "row.places", "allSuggestions"])
        // Unlocked meanwhile: what was shown comes back, nothing joins.
        #expect(Self.page(all, starterSet: 5, freeLimit: 10, nothingMade: false, visit: visit).starterSet?.count == 4)
        // Formed now.
        #expect(Self.page(all, starterSet: 5, freeLimit: 3).starterSet == [Self.kyoto.id, Self.rome.id, Self.split.id])
        #expect(Self.page(all, starterSet: 5, freeLimit: 2).starterSet == nil, "fewer than three")
    }

    /// An interrupted plan offers "Rest anlegen" as the page's one filled button: no
    /// "Dein Startpaket" beside it, also not one shown before in the visit.
    @Test func noStarterSetBesideAnInterruptedPlan() {
        let all = [Self.kyoto, Self.rome, Self.split]
        var visit = StartVisit()
        let shown = Self.page(all, starterSet: 3, visit: visit)
        #expect(shown.starterSet != nil)
        visit.saw(shown)
        let beside = Self.page(all, starterSet: 3, interrupted: true)
        #expect(beside.starterSet == nil)
        #expect(Self.names(beside) == ["newTrips", "row.trips", "atlas", "allSuggestions"])
        #expect(Self.page(all, starterSet: 3, interrupted: true, visit: visit).starterSet == nil)
    }

    // MARK: "Alle Vorschläge"

    /// The page ends with "Alle Vorschläge" whenever there are suggestions: every one is reached
    /// from there (an area without an open one, one with a single suggestion, those set aside
    /// with "Nicht jetzt"), with the facts the area list said ("12 davon in deinen Alben",
    /// "Wird neu berechnet").
    @Test func allSuggestionsCloseThePage() {
        let all = [Self.kyoto, Self.rome, Self.italy, Self.lindau]
        let page = Self.page(all, open: [Self.rome], inYourAlbums: 2)
        #expect(page.sections.last == .allSuggestions(.init(total: 4, inYourAlbums: 2, rebuilding: false)))
        let rebuilding = Self.page(all, open: [], rebuilding: true)
        #expect(rebuilding.sections.last == .allSuggestions(.init(total: 4, inYourAlbums: 0, rebuilding: true)))
        #expect(Self.page([Self.italy]).sections.last?.id == "allSuggestions")
        #expect(Self.page(all, analysedOnce: false).sections.last?.id == "allSuggestions")
        #expect(Self.page(all, open: []).sections.last?.id == "allSuggestions")
        #expect(!Self.page([]).sections.contains { $0.id == "allSuggestions" })
    }

    // MARK: A cut-off analysis

    /// An analysis that ended part way ("58 von 246 Fotos analysiert", never "Analyse fertig").
    /// The first one cut off has not gone through: the trips found so far stay big, no "Dein
    /// Startpaket" yet (its best albums come from the whole library), nothing says "Alles
    /// erledigt".
    @Test func aCutOffAnalysisSaysHowFarItGot() {
        #expect(AnalysisDoneLine.make(photos: 246, analyzed: 58, later: 0) == .partly(analyzed: 58, photos: 246))
        #expect(AnalysisDoneLine.make(photos: 246, analyzed: 58, later: 12) == .partly(analyzed: 58, photos: 246))
        #expect(AnalysisDoneLine.make(photos: 246, analyzed: 0, later: 0) == .partly(analyzed: 0, photos: 246))
        let all = [Self.kyoto, Self.rome, Self.split, Self.italy]
        let page = Self.page(all, analysedOnce: false, starterSet: 4)
        #expect(Self.names(page) == ["earlyTrips", "row.trips", "atlas", "row.places", "allSuggestions"])
        #expect(page.starterSet == nil)
        #expect(Self.names(Self.page(all, open: [], analysedOnce: false)) == ["atlas", "allSuggestions"])
    }

    // MARK: "Bescheid sagen, wenn fertig" (3B)

    @Test func theNotificationIsOfferedOnceTheAnalysisTakesAWhile() {
        let now = Self.now
        func notice(goesOn: Bool = true, finishIn: TimeInterval? = 600, first: Bool = false,
                    permission: FinishNotice.Permission = .notAsked, allowedHere: Bool = false) -> FinishNotice? {
            FinishNotice.make(runGoesOn: goesOn, finish: finishIn.map { now.addingTimeInterval($0) }, now: now,
                              firstAnalysis: first, permission: permission, allowedHere: allowedHere)
        }
        #expect(notice() == .offer)
        #expect(notice(finishIn: FinishNotice.minimumWait) == .offer)
        #expect(notice(finishIn: 60) == nil, "almost done: not worth a question")
        #expect(notice(goesOn: false) == nil, "paused, a quick check or the overnight refinement")
        // No estimate yet: the first analysis takes long anyway, a later run maybe not.
        #expect(notice(finishIn: nil, first: true) == .offer)
        #expect(notice(finishIn: nil) == nil)
        // Answered: a "no" is never asked again, a "yes" is confirmed where it was given.
        #expect(notice(permission: .denied) == nil)
        #expect(notice(permission: .allowed) == nil)
        #expect(notice(permission: .allowed, allowedHere: true) == .promised)
        #expect(notice(goesOn: false, permission: .allowed, allowedHere: true) == nil)
    }

    // MARK: The analysis line when it is done (draft B)

    @Test func theDoneLineSaysWhetherSomethingFollows() {
        #expect(AnalysisDoneLine.make(photos: 0, analyzed: 0, later: 0) == .upToDate)
        #expect(AnalysisDoneLine.make(photos: 14_381, analyzed: 14_381, later: 0) == .all(photos: 14_381))
        #expect(AnalysisDoneLine.make(photos: 14_381, analyzed: 14_380, later: 0) == .partly(analyzed: 14_380, photos: 14_381))
        #expect(AnalysisDoneLine.make(photos: 14_381, analyzed: 14_381, later: 998) == .restLater)
        #expect(AnalysisDoneLine.make(photos: 1, analyzed: 1, later: 0) == .all(photos: 1))
        // "Den Rest holt Albumist später nach" under the line, or when Albumist last looked.
        #expect(AnalysisDoneLine.partly(analyzed: 58, photos: 246).restFollows)
        #expect(AnalysisDoneLine.restLater.restFollows)
        #expect(!AnalysisDoneLine.all(photos: 246).restFollows)
        #expect(!AnalysisDoneLine.upToDate.restFollows)
    }
}
