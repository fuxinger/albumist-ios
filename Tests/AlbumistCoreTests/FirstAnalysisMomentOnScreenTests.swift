import Foundation
import Testing
@testable import AlbumistCore

/// DS-08 on screen: the first full analysis must be seen reaching 100 %. Finished in the
/// background or completed away from the app, it never comes; leaving before or while it plays
/// spends or ends it; it waits a short while for the card that shows it, and a card that goes
/// before its hold leaves it due (verification review V12). Split from `FirstAnalysisMomentTests`,
/// whose helpers it uses.
@Suite("First analysis moment on screen (DS-08)")
struct FirstAnalysisMomentOnScreenTests {
    typealias Moment = FirstAnalysisMomentTests

    /// Finished while Albumist was in the background (the screen locked, another app): the user
    /// comes back minutes or hours later to "Analyse fertig" (and found the notification), not to
    /// a 100 % that happened without them. The chance is gone for good.
    @Test func finishedInTheBackgroundItNeverComes() {
        var moment = Moment.fresh()
        Moment.end(&moment, onScreen: false)
        #expect(moment.kept == .spent)
        #expect(!moment.isDue(at: Moment.at(1)))
        // Back hours later.
        #expect(!moment.shows(at: Moment.at(4 * 3600)))
        let back = moment.claim(at: Moment.at(4 * 3600), onScreen: true)
        #expect(!back)
        // Relaunched instead.
        let relaunched = FirstAnalysisMoment(kept: moment.kept, completedBefore: true)
        #expect(relaunched.kept == .spent)
    }

    /// The analysis was completed for the first time where no run of the app ended (the
    /// overnight refinement, which iOS runs without the screen): its 100 % happened without the
    /// user, spent for good, so a rebuild cannot bring it either. After a quick first analysis
    /// (completed, not celebrated) a refinement is no first completion: the moment still waits for
    /// the first finish that is celebrated.
    @Test func completedAwayForTheFirstTimeItNeverComes() {
        var moment = Moment.fresh()
        moment.completedAway(first: true, fullAccess: true)
        #expect(moment.kept == .spent)
        Moment.end(&moment, after: 60)
        #expect(!moment.isDue(at: Moment.at(61)))
        // After a quick first analysis: still owed, and the long analysis on screen brings it.
        var quick = Moment.fresh()
        Moment.end(&quick, celebrates: false)
        quick.completedAway(first: false, fullAccess: true)
        #expect(quick.kept == .owed)
        Moment.end(&quick, after: 120)
        #expect(quick.isDue(at: Moment.at(121)))
    }

    /// After a quick first analysis of only the shared photos, an overnight refinement that
    /// completes the analysis with every photo allowed analysed the rest of the library without
    /// the user: like the first run in the app with every photo, it uses up that chance, so a later
    /// check for new photos never brings the 100 % (verification review Y, Y4). With only the
    /// shared photos still allowed it changes nothing.
    @Test func completedAwayWithEveryPhotoUsesUpTheSharedChance() {
        var moment = Moment.fresh()
        Moment.end(&moment, celebrates: false, fullAccess: false)
        var limited = moment
        limited.completedAway(first: false, fullAccess: false)
        #expect(limited.kept == .owed && limited.sharedOnly)
        moment.completedAway(first: false, fullAccess: true)
        #expect(moment.kept == .owed && !moment.sharedOnly && moment.firstCompleted == Moment.start)
        Moment.end(&moment, wholeLibrary: false, fullAccess: true, after: 3600)
        #expect(!moment.isDue(at: Moment.at(3601)), "a check brought it after the rest was analysed overnight")
        // A run of the library as a whole within the week still can.
        Moment.end(&moment, after: 7200)
        #expect(moment.isDue(at: Moment.at(7201)))
    }

    /// Due, but Albumist left the screen before the card showed it (the wait for the overview, or
    /// the user left at once): not later.
    @Test func leavingBeforeItShowsSpendsIt() {
        var moment = Moment.fresh()
        Moment.end(&moment)
        moment.leftScreen()
        #expect(!moment.isDue(at: Moment.at(1)))
        let back = moment.claim(at: Moment.at(30), onScreen: true)
        #expect(!back)
        #expect(moment.kept == .spent)
    }

    /// Playing as Albumist leaves: it ends there and does not show on return.
    @Test func leavingWhileItPlaysEndsIt() {
        var moment = Moment.fresh()
        Moment.end(&moment)
        let plays = moment.claim(at: Moment.at(1), onScreen: true)
        #expect(plays)
        moment.leftScreen()
        #expect(!moment.playing && !moment.shows(at: Moment.at(2)))
        let back = moment.claim(at: Moment.at(3), onScreen: true)
        #expect(!back)
    }

    /// On another tab when it finished: the card shows it when the user comes back to
    /// "Vorschläge" soon, not after `window` (then it was not "just now").
    @Test func itWaitsAShortWhileForTheCard() {
        var soon = Moment.fresh()
        Moment.end(&soon)
        let plays = soon.claim(at: Moment.at(FirstAnalysisMoment.window - 1), onScreen: true)
        #expect(plays)
        var late = Moment.fresh()
        Moment.end(&late)
        #expect(late.shows(at: Moment.at(FirstAnalysisMoment.window - 1)))
        #expect(!late.shows(at: Moment.at(FirstAnalysisMoment.window + 1)))
        let lapsed = late.claim(at: Moment.at(FirstAnalysisMoment.window + 1), onScreen: true)
        #expect(!lapsed)
        // Lapsed for good, also if the clock is set back.
        #expect(!late.isDue(at: Moment.at(10)))
        #expect(late.kept == .spent)
        // A clock set back before the end of the run does not keep it waiting either.
        var back = Moment.fresh()
        Moment.end(&back, after: 100)
        #expect(!back.isDue(at: Moment.at(50)))
        #expect(FirstAnalysisMoment.window >= 60 && FirstAnalysisMoment.window <= 10 * 60)
    }

    /// The run ended with Control Center, an alert or a call banner in front (not in the
    /// background, so on screen for the end of the run): the card waits for Albumist to be active
    /// and plays then (second review, K7).
    @Test func offScreenTheCardWaits() {
        var moment = Moment.fresh()
        Moment.end(&moment)
        let offScreen = moment.claim(at: Moment.at(1), onScreen: false)
        #expect(!offScreen)
        #expect(moment.isDue(at: Moment.at(2)))
        let onScreen = moment.claim(at: Moment.at(3), onScreen: true)
        #expect(onScreen)
    }

    /// The card went before the moment played (a run started meanwhile, off screen): it stays
    /// due, and the next "Analyse fertig" within the window brings it. Once it played to its end
    /// and folded away, a card that goes changes nothing.
    @Test func aCardThatGoesBeforeItPlaysLeavesItDue() {
        var moment = Moment.fresh()
        Moment.end(&moment)
        moment.cardWent(at: Moment.at(30))
        #expect(moment.isDue(at: Moment.at(60)))
        let plays = moment.claim(at: Moment.at(90), onScreen: true)
        #expect(plays)
        moment.ended()
        moment.cardWent(at: Moment.at(91))
        #expect(!moment.playing && !moment.shows(at: Moment.at(91)))
        let again = moment.claim(at: Moment.at(92), onScreen: true)
        #expect(!again)
    }

    /// Its card went while it played, before its hold (a run that starts within the 3.2 s puts
    /// its own card there, another tab): not lost, the next card within the window plays it from
    /// the start (verification review V12). Once it was on screen for its hold, or VoiceOver said
    /// it, a card that goes ends it: it never shows twice.
    @Test func aCardThatGoesWhileItPlaysBeforeItsHoldLeavesItDue() {
        typealias Timing = FirstAnalysisMoment.Timing
        var cut = Moment.fresh()
        Moment.end(&cut)
        let plays = cut.claim(at: Moment.at(1), onScreen: true)
        #expect(plays)
        #expect(!cut.cutShort)
        cut.cardWent(at: Moment.at(1 + Timing.hold - 0.5))
        #expect(!cut.playing)
        #expect(cut.isDue(at: Moment.at(10)))
        // Cut short: the done line of the start page may play it too, once that run ended.
        #expect(cut.cutShort)
        let again = cut.claim(at: Moment.at(20), onScreen: true)
        #expect(again)
        #expect(!cut.cutShort)
        // This time on screen for its hold: over, whatever card comes.
        cut.cardWent(at: Moment.at(20 + Timing.hold))
        #expect(!cut.shows(at: Moment.at(30)))
        let third = cut.claim(at: Moment.at(31), onScreen: true)
        #expect(!third)
        #expect(cut.kept == .spent)
        // Said by VoiceOver as it came: heard, over when its card goes, however soon.
        var heard = Moment.fresh()
        Moment.end(&heard)
        let said = heard.claim(at: Moment.at(1), onScreen: true, announced: true)
        #expect(said)
        heard.cardWent(at: Moment.at(1.5))
        #expect(!heard.shows(at: Moment.at(2)))
        let replayed = heard.claim(at: Moment.at(3), onScreen: true)
        #expect(!replayed)
        // Cut short at the end of its window: the window counts from the run's end, gone.
        var late = Moment.fresh()
        Moment.end(&late)
        let started = late.claim(at: Moment.at(FirstAnalysisMoment.window - 1), onScreen: true)
        #expect(started)
        late.cardWent(at: Moment.at(FirstAnalysisMoment.window))
        let tooLate = late.claim(at: Moment.at(FirstAnalysisMoment.window + 1), onScreen: true)
        #expect(!tooLate)
        // Cut short by leaving for the background: over, as before.
        var away = Moment.fresh()
        Moment.end(&away)
        let shown = away.claim(at: Moment.at(1), onScreen: true)
        #expect(shown)
        away.leftScreen()
        away.cardWent(at: Moment.at(2))
        #expect(!away.isDue(at: Moment.at(3)) && !away.cutShort)
        // A moment due for the first time is not "cut short": only "Analyse fertig" plays it.
        var due = Moment.fresh()
        Moment.end(&due)
        #expect(due.isDue(at: Moment.at(1)) && !due.cutShort)
    }
}
