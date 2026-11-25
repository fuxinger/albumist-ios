import Foundation
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore

/// A first analysis that ran in legs (paused, cut off by iOS, closed and gone on later) is one
/// wait for "Analyse fertig" and its 100 % (verification review X9, the lead's decision). Before,
/// each run was decided alone (`AnalysisCardState.celebratesFinish`: 30 s or more with the bar
/// shown): an analysis of an hour whose last leg took 20 s ended without "Analyse fertig", and its
/// first 100 % was lost for good. Now, for the first completion on this installation only, the
/// legs count together (`FirstAnalysisLegs`): their summed time and whether one showed the bar,
/// kept with the resume position. Every later run is decided alone, as before.
@Suite("First analysis in legs (X9)")
struct FirstAnalysisLegsTests {
    typealias Leg = FirstAnalysisLegs.Leg
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// What `AppModel` decides at the end of a run with what the legs counted.
    static func celebrates(_ counted: Leg, finished: Bool = true) -> Bool {
        AnalysisCardState.celebratesFinish(isComplete: finished, wasQuickCheck: !counted.showedBar,
                                           ranFor: .seconds(counted.seconds))
    }

    /// One run as `AppModel` tells it: started, a report halfway, ended after `seconds`.
    static func run(_ legs: inout FirstAnalysisLegs, _ seconds: Double, showedBar: Bool = true, finished: Bool,
                    firstCompletion: Bool = true, goesOn: Bool = true) -> Leg {
        legs.started(firstCompletion: firstCompletion, goesOn: goesOn)
        legs.runs(Leg(seconds: seconds / 2, showedBar: showedBar))
        return legs.ended(Leg(seconds: seconds, showedBar: showedBar), finished: finished)
    }

    /// X9's case: 30,000 photos, the user leaves at 99 % and the run ends there; back later, the
    /// rest takes 20 s. The legs count together: "Analyse fertig", and on screen its 100 %. The
    /// last leg alone would not have been celebrated.
    @Test func aFirstAnalysisWhoseLastLegIsShortIsCelebrated() {
        var moment = FirstAnalysisMoment(kept: nil, completedBefore: false)
        #expect(moment.firstCompletionAhead)
        var legs = FirstAnalysisLegs()
        let paused = Self.run(&legs, 3600, finished: false, goesOn: false)
        #expect(!Self.celebrates(paused, finished: false))
        #expect(legs.kept == Leg(seconds: 3600, showedBar: true))
        let last = Self.run(&legs, 20, finished: true)
        #expect(last == Leg(seconds: 3620, showedBar: true))
        #expect(Self.celebrates(last))
        #expect(!Self.celebrates(Leg(seconds: 20, showedBar: true)), "the last leg alone is celebrated")
        moment.runEnded(finished: true, celebrates: Self.celebrates(last), wholeLibrary: true, fullAccess: true,
                        onScreen: true, at: Self.start)
        #expect(moment.isDue(at: Self.start) && moment.kept == .spent)
        // Done with the first completion.
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
        moment.runEnded(finished: true, celebrates: Self.celebrates(only), wholeLibrary: true, fullAccess: true,
                        onScreen: true, at: Self.start)
        #expect(!moment.isDue(at: Self.start) && moment.kept == .owed && moment.firstCompleted == Self.start)
        #expect(!moment.firstCompletionAhead)
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
        legs.started(firstCompletion: true, goesOn: false)
        legs.runs(Leg(seconds: 25, showedBar: true))
        legs.runs(Leg(seconds: 40, showedBar: true))
        #expect(legs.kept == Leg(seconds: 40, showedBar: true))
        // The app ends here. Next launch: what was kept, and the run goes on from the resume position.
        var relaunched = FirstAnalysisLegs(kept: legs.kept, firstCompletionAhead: true)
        let last = Self.run(&relaunched, 5, finished: true)
        #expect(last == Leg(seconds: 45, showedBar: true))
        #expect(Self.celebrates(last))
        // Kept across launches only while the first completion is ahead.
        #expect(FirstAnalysisLegs(kept: legs.kept, firstCompletionAhead: false).kept == .none)
    }

    /// A run that does not go on from the resume position starts the analysis anew (the first run,
    /// another part of the library, "Analyse neu aufbauen", a new or restored database: the
    /// resume position was dropped): the legs before it are dropped with it.
    @Test func aNewAnalysisStartsItsLegsAnew() {
        var legs = FirstAnalysisLegs()
        _ = Self.run(&legs, 40, finished: false, goesOn: false)
        #expect(legs.kept.seconds == 40)
        let anew = Self.run(&legs, 10, finished: true, goesOn: false)
        #expect(anew == Leg(seconds: 10, showedBar: true))
        #expect(!Self.celebrates(anew))
        // Also after a relaunch.
        var kept = FirstAnalysisLegs(kept: Leg(seconds: 40, showedBar: true), firstCompletionAhead: true)
        let fresh = Self.run(&kept, 10, finished: true, goesOn: false)
        #expect(fresh.seconds == 10)
    }

    /// Once the analysis was completed on this installation (celebrated or quick, or overnight),
    /// every run is decided alone, as before: a check for new photos, a catch-up, "Analyse neu
    /// aufbauen" or another part of the library, also when they run in legs.
    @Test func laterRunsAreDecidedAlone() {
        var legs = FirstAnalysisLegs()
        _ = Self.run(&legs, 3600, finished: false, firstCompletion: false, goesOn: false)
        #expect(legs.kept == .none && !legs.counting)
        let check = Self.run(&legs, 20, finished: true, firstCompletion: false)
        #expect(check == Leg(seconds: 20, showedBar: true))
        #expect(!Self.celebrates(check))
        // Which installations have the first completion ahead.
        #expect(FirstAnalysisMoment(kept: nil, completedBefore: false).firstCompletionAhead)
        #expect(!FirstAnalysisMoment(kept: nil, completedBefore: true).firstCompletionAhead)
        #expect(!FirstAnalysisMoment(kept: .spent, completedBefore: false).firstCompletionAhead)
        #expect(!FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Self.start).firstCompletionAhead)
        var away = FirstAnalysisMoment(kept: nil, completedBefore: false)
        away.completedAway(first: true)
        #expect(!away.firstCompletionAhead)
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
