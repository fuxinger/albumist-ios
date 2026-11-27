import Foundation
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore

/// A first analysis that ran in legs (paused, cut off by iOS, closed and gone on later) is one
/// wait for "Analyse fertig" and its 100 % (verification review X9, the lead's decision). Before,
/// each run was decided alone (`AnalysisCardState.celebratesFinish`: 30 s or more with the bar
/// shown): an analysis of an hour whose last leg took 20 s ended without "Analyse fertig", and its
/// first 100 % was lost for good. Now the legs count together (`FirstAnalysisLegs`): their summed
/// time and whether one showed the bar, kept with the resume position, for the first analysis and
/// every other run that may bring the moment while it is owed (verification review Y, Y2 and Y4:
/// `FirstAnalysisLegsWhileOwedTests`). Every other run is decided alone, as before.
@Suite("First analysis in legs (X9)")
struct FirstAnalysisLegsTests {
    typealias Leg = FirstAnalysisLegs.Leg
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// A run of the library as a whole, every photo allowed: the first analysis.
    static let whole = FirstAnalysisMoment.Run(wholeLibrary: true, fullAccess: true)

    /// What `AppModel` decides at the end of a run with what the legs counted.
    static func celebrates(_ counted: Leg, finished: Bool = true) -> Bool {
        AnalysisCardState.celebratesFinish(isComplete: finished, wasQuickCheck: !counted.showedBar,
                                           ranFor: .seconds(counted.seconds))
    }

    /// One run as `AppModel` tells it: started, a report halfway, ended after `seconds`.
    static func run(_ legs: inout FirstAnalysisLegs, _ seconds: Double, showedBar: Bool = true, finished: Bool,
                    firstCompletion: Bool = true, goesOn: Bool = true) -> Leg {
        legs.started(mayBringMoment: firstCompletion, goesOn: goesOn)
        legs.runs(Leg(seconds: seconds / 2, showedBar: showedBar))
        return legs.ended(Leg(seconds: seconds, showedBar: showedBar), finished: finished)
    }

    /// X9's case: 30,000 photos, the user leaves at 99 % and the run ends there; back later, the
    /// rest takes 20 s. The legs count together: "Analyse fertig", and on screen its 100 %. The
    /// last leg alone would not have been celebrated.
    @Test func aFirstAnalysisWhoseLastLegIsShortIsCelebrated() {
        var moment = FirstAnalysisMoment(kept: nil, completedBefore: false)
        #expect(moment.mayBeBrought(by: Self.whole))
        var legs = FirstAnalysisLegs()
        let paused = Self.run(&legs, 3600, finished: false, goesOn: false)
        #expect(!Self.celebrates(paused, finished: false))
        #expect(legs.kept == Leg(seconds: 3600, showedBar: true))
        let last = Self.run(&legs, 20, finished: true)
        #expect(last == Leg(seconds: 3620, showedBar: true))
        #expect(Self.celebrates(last))
        #expect(!Self.celebrates(Leg(seconds: 20, showedBar: true)), "the last leg alone is celebrated")
        moment.runEnded(Self.whole, finished: true, celebrates: Self.celebrates(last), onScreen: true, at: Self.start)
        #expect(moment.isDue(at: Self.start) && moment.kept == .spent)
        // Done once it finished.
        #expect(legs.kept == .none && !legs.counting)
    }

    /// A first analysis in one short run stays as it was: not celebrated, the 100 % waits the
    /// seven days for a run of the whole library (verification review V6).
    @Test func aSingleShortFirstAnalysisStaysUncelebrated() {
        var moment = FirstAnalysisMoment(kept: nil, completedBefore: false)
        var legs = FirstAnalysisLegs()
        let only = Self.run(&legs, 20, finished: true, goesOn: false)
        #expect(only == Leg(seconds: 20, showedBar: true))
        #expect(!Self.celebrates(only))
        moment.runEnded(Self.whole, finished: true, celebrates: Self.celebrates(only), onScreen: true, at: Self.start)
        #expect(!moment.isDue(at: Self.start) && moment.kept == .owed && moment.firstCompleted == Self.start)
        // From now on only a run of the library as a whole may bring it, never a check.
        #expect(!moment.mayBeBrought(by: FirstAnalysisMoment.Run(wholeLibrary: false, fullAccess: true)))
    }

    /// Legs that add up to less than 30 s are a quick first analysis too; from 30 s on, with the
    /// bar shown in one of them, it is celebrated.
    @Test func legsSummingUnderThirtySecondsStayUncelebrated() {
        var short = FirstAnalysisLegs()
        _ = Self.run(&short, 10, finished: false, goesOn: false)
        _ = Self.run(&short, 12, finished: false)
        let under = Self.run(&short, 5, finished: true)
        #expect(under.seconds == 27)
        #expect(!Self.celebrates(under))
        var enough = FirstAnalysisLegs()
        _ = Self.run(&enough, 10, finished: false, goesOn: false)
        _ = Self.run(&enough, 12, finished: false)
        let thirty = Self.run(&enough, 8, finished: true)
        #expect(thirty.seconds == 30)
        #expect(Self.celebrates(thirty))
    }

    /// The bar must have shown in one of the legs (a full analysis on the card, not only the quick
    /// check), as for a run alone.
    @Test func theBarMustHaveShownInOneOfTheLegs() {
        var never = FirstAnalysisLegs()
        _ = Self.run(&never, 40, showedBar: false, finished: false, goesOn: false)
        let none = Self.run(&never, 20, showedBar: false, finished: true)
        #expect(none == Leg(seconds: 60, showedBar: false))
        #expect(!Self.celebrates(none))
        var once = FirstAnalysisLegs()
        _ = Self.run(&once, 40, showedBar: true, finished: false, goesOn: false)
        let shown = Self.run(&once, 5, showedBar: false, finished: true)
        #expect(shown == Leg(seconds: 45, showedBar: true))
        #expect(Self.celebrates(shown))
    }

    /// A leg that iOS ended with the app has no end of its run: what it ran until its last report
    /// is kept (with the resume position), and the next launch goes on with it.
    @Test func aLegCutOffWithoutItsEndStillCounts() {
        var legs = FirstAnalysisLegs()
        legs.started(mayBringMoment: true, goesOn: false)
        legs.runs(Leg(seconds: 25, showedBar: true))
        legs.runs(Leg(seconds: 40, showedBar: true))
        #expect(legs.kept == Leg(seconds: 40, showedBar: true))
        // The app ends here. Next launch: what was kept, and the run goes on from the resume position.
        var relaunched = FirstAnalysisLegs(kept: legs.kept, owed: true)
        let last = Self.run(&relaunched, 5, finished: true)
        #expect(last == Leg(seconds: 45, showedBar: true))
        #expect(Self.celebrates(last))
        // Kept across launches only while the moment is owed.
        #expect(FirstAnalysisLegs(kept: legs.kept, owed: false).kept == .none)
    }

    /// A run of the library as a whole that does not go on from the resume position starts the
    /// analysis anew (the first run, another part of the library, "Analyse neu aufbauen", a new or
    /// restored database: the resume position was dropped): the legs before it are dropped with it.
    /// The rest after only the shared photos goes on without it (`whoseLegsGoOnAsARunStarts`).
    @Test func aNewAnalysisStartsItsLegsAnew() {
        var legs = FirstAnalysisLegs()
        _ = Self.run(&legs, 40, finished: false, goesOn: false)
        #expect(legs.kept.seconds == 40)
        let anew = Self.run(&legs, 10, finished: true, goesOn: false)
        #expect(anew == Leg(seconds: 10, showedBar: true))
        #expect(!Self.celebrates(anew))
        // Also after a relaunch.
        var kept = FirstAnalysisLegs(kept: Leg(seconds: 40, showedBar: true), owed: true)
        let fresh = Self.run(&kept, 10, finished: true, goesOn: false)
        #expect(fresh.seconds == 10)
    }

    /// Whose legs go on as a run starts (`FirstAnalysisMoment.legsGoOn`, the store's `goesOn` for
    /// `started`; verification review Z, Z3), for a run that may bring the moment: from the resume
    /// position, always; without it, a run of the library as a whole starts the analysis anew and
    /// drops them (`started(mayBringMoment: true, goesOn: false)`), while a run of the rest after
    /// only the shared photos goes on with them: its runs are checks, and a check that missed a
    /// change drops its position. A run that cannot bring the moment goes on with none.
    @Test func whoseLegsGoOnAsARunStarts() {
        let rest = FirstAnalysisMoment.Run(wholeLibrary: false, fullAccess: true)
        let fresh = FirstAnalysisMoment(kept: nil, completedBefore: false)
        #expect(fresh.legsGoOn(with: Self.whole, fromPosition: true))
        #expect(!fresh.legsGoOn(with: Self.whole, fromPosition: false), "a new analysis goes on with the legs before it")
        let shared = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Self.start, sharedOnly: true)
        #expect(shared.legsGoOn(with: rest, fromPosition: true))
        #expect(shared.legsGoOn(with: rest, fromPosition: false), "the rest's legs end where a check drops its position")
        #expect(!shared.legsGoOn(with: Self.whole, fromPosition: false), "\"Analyse neu aufbauen\" goes on with the rest's legs")
        #expect(!shared.legsGoOn(with: FirstAnalysisMoment.Run(wholeLibrary: false, fullAccess: false), fromPosition: true))
        let quick = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Self.start)
        #expect(!quick.legsGoOn(with: rest, fromPosition: false) && !quick.legsGoOn(with: rest, fromPosition: true),
                "a check for new photos goes on with legs")
        #expect(!FirstAnalysisMoment(kept: .spent, completedBefore: true).legsGoOn(with: Self.whole, fromPosition: true))
        // As the store starts the legs: after an unfinished leg that counted, the rest's next run
        // without the position goes on with it; the library as a whole without it starts anew.
        var legs = FirstAnalysisLegs()
        _ = Self.run(&legs, 3600, finished: false, goesOn: false)
        legs.started(mayBringMoment: shared.mayBeBrought(by: rest), goesOn: shared.legsGoOn(with: rest, fromPosition: false))
        #expect(legs.ended(Leg(seconds: 6), finished: true) == Leg(seconds: 3606, showedBar: true))
        var anew = FirstAnalysisLegs()
        _ = Self.run(&anew, 3600, finished: false, goesOn: false)
        anew.started(mayBringMoment: shared.mayBeBrought(by: Self.whole), goesOn: shared.legsGoOn(with: Self.whole, fromPosition: false))
        #expect(anew.ended(Leg(seconds: 6), finished: true) == Leg(seconds: 6))
    }

    /// A run that cannot bring the moment is decided alone, as before, also when it runs in legs:
    /// once the moment was spent (celebrated, lapsed, completed overnight for the first time) and,
    /// while it is owed after a quick first analysis, a check for new photos or a catch-up of new
    /// imports. Every run that may bring it counts its legs (verification review Y, Y2 and Y4;
    /// `FirstAnalysisLegsWhileOwedTests`).
    @Test func runsThatCannotBringItAreDecidedAlone() {
        var legs = FirstAnalysisLegs()
        _ = Self.run(&legs, 3600, finished: false, firstCompletion: false, goesOn: false)
        #expect(legs.kept == .none && !legs.counting)
        let alone = Self.run(&legs, 20, finished: true, firstCompletion: false)
        #expect(alone == Leg(seconds: 20, showedBar: true))
        #expect(!Self.celebrates(alone))
        // Which runs may bring it.
        let check = FirstAnalysisMoment.Run(wholeLibrary: false, fullAccess: true)
        let fresh = FirstAnalysisMoment(kept: nil, completedBefore: false)
        #expect(fresh.mayBeBrought(by: Self.whole))
        #expect(!FirstAnalysisMoment(kept: nil, completedBefore: true).mayBeBrought(by: Self.whole))
        #expect(!FirstAnalysisMoment(kept: .spent, completedBefore: false).mayBeBrought(by: Self.whole))
        let quick = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Self.start)
        #expect(quick.mayBeBrought(by: Self.whole), "after a quick first analysis: the library as a whole")
        #expect(!quick.mayBeBrought(by: check), "after a quick first analysis: a check for new photos")
        let shared = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Self.start, sharedOnly: true)
        #expect(shared.mayBeBrought(by: check), "after only the shared photos: the rest with every photo")
        #expect(!shared.mayBeBrought(by: FirstAnalysisMoment.Run(wholeLibrary: false, fullAccess: false)))
        var away = fresh
        away.completedAway(first: true, fullAccess: true)
        #expect(!away.mayBeBrought(by: Self.whole))
        // Completed overnight while legs were kept: nothing left to count.
        var overnight = FirstAnalysisLegs()
        _ = Self.run(&overnight, 40, finished: false, goesOn: false)
        overnight.drop()
        #expect(overnight.kept == .none && !overnight.counting)
    }

    /// A leg's time is never negative, and the legs add up in order.
    @Test func legsAddUp() {
        #expect(Leg(seconds: -3, showedBar: false).seconds == 0)
        #expect(Leg(seconds: 4, showedBar: false).then(Leg(seconds: 6, showedBar: true)) == Leg(seconds: 10, showedBar: true))
        #expect(Leg.none == Leg(seconds: 0, showedBar: false))
    }
}
