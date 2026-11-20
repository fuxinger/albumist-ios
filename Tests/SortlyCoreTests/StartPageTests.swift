import Foundation
import Testing
@testable import SortlyCore

/// What the start page "Vorschläge" shows in every state (design wave 1, drafts E1, E6, E7):
/// the first analysis with its mosaic and "Schon gefunden" (9A), "Dein Startpaket" after it,
/// "Neue Reisen" later, the rows with trips first and "Deine Welt" right under them, nothing
/// open, an empty library, 0, 1 and over 300 suggestions, free albums used up, and nothing
/// moving under the user's finger after "Anlegen" on a card (7B).
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

    static func page(_ proposals: [AlbumProposal], open: [AlbumProposal]? = nil, analysedOnce: Bool = true,
                     mosaic: Bool = false, starterSet: Int = 0, nothingMade: Bool = true, libraryHint: Bool = false,
                     areas: [OrganizationArea] = areas, visit: StartVisit = StartVisit()) -> StartPage {
        StartPage.make(.init(proposals: proposals, open: Set((open ?? proposals).map(\.id)), areas: areas,
                             analysedOnce: analysedOnce, showsMosaic: mosaic, starterSetSize: starterSet,
                             nothingMadeYet: nothingMade, libraryHint: libraryHint, visit: visit))
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
        #expect(Self.names(page) == ["mosaic", "earlyTrips", "row.trips", "atlas", "row.places"])
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
        #expect(Self.names(page) == ["earlyTrips", "atlas", "row.places"])
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
        #expect(Self.names(page) == ["starterSet", "row.trips", "atlas", "row.places", "row.frequentPlaces", "row.documents"])
        #expect(Self.row(.trips, in: page)?.cards == [Self.kyoto.id, Self.split.id, Self.rome.id, Self.lisbon.id])
        #expect(Self.row(.places, in: page)?.cards == [Self.japan.id, Self.italy.id], "biggest first")
        #expect(page.bigCards.isEmpty)
    }

    /// "Dein Startpaket" needs three albums; with fewer the newest trips are the big part.
    @Test func aStarterSetNeedsThreeAlbums() {
        let page = Self.page([Self.kyoto, Self.rome, Self.italy], starterSet: 2)
        #expect(!page.showsStarterSet)
        #expect(Self.names(page) == ["newTrips", "atlas", "row.places"])
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
        #expect(Self.names(page) == ["newTrips", "row.trips", "atlas"])
        #expect(page.bigCards == [Self.kyoto.id], "only the trip after the last album is new")
    }

    /// Once an album was made, "Neue Reisen" are the trips that ended after it, newest first.
    @Test func newTripsAreTheOnesAfterTheLastAlbum() {
        let lastMade = Self.now.addingTimeInterval(-350 * Self.day)
        let page = Self.page([Self.kyoto, Self.rome, Self.split, Self.lisbon], starterSet: 5, nothingMade: false,
                             visit: StartVisit(lastMade: lastMade))
        #expect(Self.names(page) == ["newTrips", "row.trips", "atlas"])
        #expect(page.bigCards == [Self.kyoto.id, Self.split.id])
        #expect(Self.row(.trips, in: page)?.cards == [Self.rome.id, Self.lisbon.id])
        // Nothing new since: no big part, the trips in their row.
        let later = Self.page([Self.rome, Self.lisbon], nothingMade: false, visit: StartVisit(lastMade: lastMade))
        #expect(Self.names(later) == ["row.trips", "atlas"])
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
        #expect(after.showsStarterSet)
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

    /// No suggestion after the analysis: one calm card, no empty rows; with the card for an
    /// empty library that card explains it.
    @Test func noSuggestionSaysAllDone() {
        #expect(Self.names(Self.page([])) == ["caughtUp", "atlas"])
        #expect(Self.names(Self.page([], libraryHint: true)) == ["atlas"])
        // Everything decided: the same.
        #expect(Self.names(Self.page([Self.kyoto, Self.italy], open: [])) == ["caughtUp", "atlas"])
    }

    /// One suggestion: a trip is the big part, a place its own row of one card.
    @Test func oneSuggestion() {
        #expect(Self.names(Self.page([Self.kyoto])) == ["newTrips", "atlas"])
        let place = Self.page([Self.italy])
        #expect(Self.names(place) == ["atlas", "row.places"])
        #expect(Self.row(.places, in: place)?.showsAll == false, "no \"Alle 1\"")
    }

    /// Over 300 suggestions: rows of ten, "Alle 300" leads to the rest; the page stays short.
    @Test func overThreeHundredSuggestions() {
        let trips = (0..<300).map { Self.trip("Reise \($0)", daysAgo: Double($0 + 1)) }
        let places = (0..<40).map { Self.place("Land \($0)", photos: 10 + $0) }
        let page = Self.page(trips + places, starterSet: 10)
        #expect(Self.names(page) == ["starterSet", "row.trips", "atlas", "row.places"])
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
                                     "row.documents", "row.chronology"])
        let withoutTrips = Self.page(all, nothingMade: false, areas: Self.areas.filter { $0 != .trips && $0 != .documents },
                                     visit: StartVisit(lastMade: Self.now))
        #expect(Self.names(withoutTrips) == ["atlas", "row.places", "row.frequentPlaces", "row.screenshots", "row.chronology"])
    }

    /// The section ids are unique, so the app can use them as identities.
    @Test func sectionIDsAreUnique() {
        let all = [Self.kyoto, Self.rome, Self.split, Self.italy, Self.lindau, Self.contracts]
        for page in [Self.page(all, analysedOnce: false, mosaic: true), Self.page(all, starterSet: 4), Self.page([])] {
            #expect(Set(Self.names(page)).count == page.sections.count, "\(Self.names(page))")
        }
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
        #expect(AnalysisDoneLine.make(photos: 14_381, analyzed: 14_380, later: 0) == .restLater)
        #expect(AnalysisDoneLine.make(photos: 14_381, analyzed: 14_381, later: 998) == .restLater)
        #expect(AnalysisDoneLine.make(photos: 1, analyzed: 1, later: 0) == .all(photos: 1))
    }
}
