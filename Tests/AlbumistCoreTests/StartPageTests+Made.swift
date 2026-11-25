import Foundation
import Testing
@testable import AlbumistCore

/// The start page once albums are made, for the visit, and when the analysis ends (`StartPageTests`).
extension StartPageTests {
    // MARK: "Angelegt" only once the album is there (7B)

    /// "Anlegen" picks the suggestion for its plan while the album is made: still open, so the
    /// card shows its work, not "Angelegt". Made, the run clears the pick before the suggestions
    /// are matched again: the card keeps "Angelegt" meanwhile, never "Anlegen" in between. Once
    /// the page saw it done, "Widerrufen" brings "Anlegen" back in its place.
    @Test func aCardSaysMadeOnlyOnceItsAlbumIsInPhotos() {
        let all = [Self.kyoto, Self.rome, Self.split]
        let plan = AlbumistID("plan.kyoto")
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
        let plan = AlbumistID("plan.kyoto")
        var visit = StartVisit()
        visit.create(Self.kyoto.id)
        visit.made(Self.kyoto.id, by: plan)
        #expect(Self.page(all, nothingMade: false, visit: visit).made == [Self.kyoto.id])
        visit.undone([AlbumistID("plan.other")])
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
        let plan = AlbumistID("plan.kyoto")
        var visit = StartVisit()
        visit.create(Self.kyoto.id)
        #expect(Self.page(all, nothingMade: false, visit: visit).made.isEmpty, "the purchase sheet is up")
        visit.announced(Self.rome.id, by: AlbumistID("plan.rome"))
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
        visit.made(Self.split.id, by: AlbumistID("plan.split"))
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
