import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyTestSupport

/// "Analyse fertig" (point 4) is never lost to a short run that slips in right after the run that
/// finished (`FinishMoment`): a trip change, "Neu prüfen", a check for photos added meanwhile.
/// Before, the end of the run that finished waited for the overview, saw a newer run
/// (`AnalysisRunEnd.afterWait(isNewest: false)`) and dropped the moment; the newer run was a
/// quick check, which never celebrates (`AnalysisCardState.celebratesFinish`); and every start
/// cleared a finish card nobody had seen yet. The user never saw the moment, and outside the app
/// got no notification.
@Suite("Finish moment: Analyse fertig is not lost to a run right after")
struct FinishMomentTests {
    typealias R = AnalysisRunEndTests

    /// The end of a run in the app as `AppModel` decides it: its `AnalysisRunEnd`, and whether it
    /// celebrates (a long full run) or not (a quick check).
    struct Run {
        var end: AnalysisRunEnd
        var celebrates: Bool

        static let longFinished = Run(end: R.end(R.complete(R.on)),
                                      celebrates: AnalysisCardState.celebratesFinish(isComplete: true, wasQuickCheck: false,
                                                                                     ranFor: .seconds(1_200)))
        static let quickCheckFinished = Run(end: R.end(R.complete(R.on)),
                                            celebrates: AnalysisCardState.celebratesFinish(isComplete: true, wasQuickCheck: true,
                                                                                           ranFor: .seconds(4)))
        /// A check that missed a change of the user's: one more run follows, never "fertig".
        static let quickCheckWithAChangeLeft = Run(end: AnalysisRunEnd(report: R.complete(R.on), settings: R.on, pauseTapped: false,
                                                                       catchUpRequested: false, mayStart: true, changeRequested: true),
                                                   celebrates: false)
        /// Pause tapped on the check: work is left.
        static let quickCheckPaused: Run = {
            var report = R.complete(R.on)
            report.pausedBecause = .userPaused
            return Run(end: R.end(report), celebrates: false)
        }()
    }

    /// The end of `run` in the order `AppModel` does it: decided at once, then the wait for the
    /// overview, then the moment if it is still the newest run.
    static func end(_ run: Run, in moment: inout FinishMoment, isNewest: Bool, appActive: Bool = true) -> FinishMoment.Shown {
        moment.runEnded(finished: run.end.isFinished, celebrates: run.celebrates)
        return moment.afterWait(settled: run.end.afterWait(isNewest: isNewest).finishMoment, appActive: appActive)
    }

    @Test func theRulesTheMomentBuildsOn() {
        #expect(Run.longFinished.end.isFinished && Run.longFinished.celebrates)
        #expect(Run.quickCheckFinished.end.isFinished && !Run.quickCheckFinished.celebrates)
        #expect(!Run.quickCheckWithAChangeLeft.end.isFinished)
        #expect(!Run.quickCheckPaused.end.isFinished)
    }

    /// The bug: a long run finishes, a trip change (or new photos) starts a quick check while its
    /// end still waits for the overview. Its end is no longer the newest and said nothing; the
    /// check is quick and said nothing either.
    @Test func aQuickRunThatSlipsInShowsTheMomentAtItsEnd() {
        var moment = FinishMoment()
        moment.runStarted()
        // The long run's end is decided; meanwhile the follow-up starts.
        moment.runEnded(finished: Run.longFinished.end.isFinished, celebrates: Run.longFinished.celebrates)
        moment.runStarted()
        let first = moment.afterWait(settled: Run.longFinished.end.afterWait(isNewest: false).finishMoment, appActive: true)
        #expect(first == .nothing, "the earlier run said fertig over the newer run's card")
        // The quick check ends finished: the moment owed comes now.
        let second = Self.end(.quickCheckFinished, in: &moment, isNewest: true)
        #expect(second.card, "Analyse fertig was lost to the quick run right after")
        #expect(!second.notification, "the notification came while the app was open")
        // Seen once: the check mark plays once, and the next run does not bring it back.
        let r1 = moment.claim()
        #expect(r1)
        let again2 = moment.claim()
        #expect(!again2)
        moment.runStarted()
        let r2 = Self.end(.quickCheckFinished, in: &moment, isNewest: true)
        #expect(r2 == .nothing)
    }

    /// The same outside the app: the notification comes with the end of the run that slipped in.
    @Test func outsideTheAppTheNotificationIsNotLostEither() {
        var moment = FinishMoment()
        moment.runStarted()
        moment.runEnded(finished: true, celebrates: true)
        moment.runStarted()
        let r3 = moment.afterWait(settled: false, appActive: false)
        #expect(r3 == .nothing)
        let shown = Self.end(.quickCheckFinished, in: &moment, isNewest: true, appActive: false)
        #expect(shown == FinishMoment.Shown(card: true, notification: true), "no Analyse fertig notification at all")
    }

    /// The finish card was shown while the app was in the background (notification sent), and a
    /// check for the photos taken meanwhile starts before the user comes back: the card comes back
    /// at that check's end, the notification not a second time.
    @Test func aCardNobodySawComesBackAfterTheNextRun() {
        var moment = FinishMoment()
        moment.runStarted()
        let r4 = Self.end(.longFinished, in: &moment, isNewest: true, appActive: false)
        #expect(r4 == .init(card: true, notification: true))
        moment.runStarted()
        let again = Self.end(.quickCheckFinished, in: &moment, isNewest: true, appActive: false)
        #expect(again.card, "the finish card nobody saw went with the next run")
        #expect(!again.notification, "Analyse fertig was notified twice")
        // On screen now: played once.
        let r5 = moment.claim()
        #expect(r5)
        let again2 = moment.claim()
        #expect(!again2)
    }

    /// Never "fertig" while work is left: the run that slipped in ends with a change left or
    /// paused, and the moment waits for the run that really finishes the analysis.
    @Test func neverFertigWhileWorkIsLeft() {
        for unfinished in [Run.quickCheckWithAChangeLeft, .quickCheckPaused] {
            var moment = FinishMoment()
            moment.runStarted()
            moment.runEnded(finished: true, celebrates: true)
            moment.runStarted()
            let r6 = moment.afterWait(settled: false, appActive: true)
            #expect(r6 == .nothing)
            let r7 = Self.end(unfinished, in: &moment, isNewest: true)
            #expect(r7 == .nothing, "fertig with work left")
            moment.runStarted()
            let r8 = Self.end(.quickCheckFinished, in: &moment, isNewest: true)
            #expect(r8.card, "the moment never came")
        }
    }

    /// The order of the two ends does not matter: the quick run can end before the long run's
    /// end has finished waiting for the overview (a large library).
    @Test func theQuickRunMayEndFirst() {
        var moment = FinishMoment()
        moment.runStarted()
        moment.runEnded(finished: true, celebrates: true)
        moment.runStarted()
        let r9 = Self.end(.quickCheckFinished, in: &moment, isNewest: true)
        #expect(r9.card)
        let r10 = moment.afterWait(settled: false, appActive: true)
        #expect(r10 == .nothing, "fertig said twice")
    }

    /// Nothing is owed by runs that did not celebrate: a quick check alone, a run that did not
    /// finish, a run whose end is not the newest.
    @Test func onlyAFinishedLongRunOwesTheMoment() {
        var moment = FinishMoment()
        moment.runStarted()
        let r11 = Self.end(.quickCheckFinished, in: &moment, isNewest: true)
        #expect(r11 == .nothing)
        moment.runStarted()
        moment.runEnded(finished: false, celebrates: true)
        let r12 = moment.afterWait(settled: false, appActive: true)
        #expect(r12 == .nothing)
        moment.runStarted()
        let r13 = Self.end(.quickCheckFinished, in: &moment, isNewest: true)
        #expect(r13 == .nothing)
        // The usual case is unchanged: a long run that finishes shows the moment at its end.
        var usual = FinishMoment()
        usual.runStarted()
        let r14 = Self.end(.longFinished, in: &usual, isNewest: true)
        #expect(r14 == .init(card: true, notification: false))
        let r15 = usual.claim()
        #expect(r15)
    }

    /// The App decides by these rules (it does not build on Linux, so its code is read without
    /// comments and strings, `AppSource.code`): the end of a run says what it owes before it waits
    /// for the overview, the moment comes from `afterWait` with the end's settled value, a start
    /// keeps a moment nobody saw, and the card's check mark is claimed from the same state.
    @Test func theAppKeepsTheMomentByTheseRules() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        func code(_ declaration: String) throws -> String {
            AppSource.code(try #require(AppSource.body(of: declaration, in: model), "AppModel.swift: no \(declaration)"))
        }
        let start = try code("func startAnalysisNow(")
        let owes = start.range(of: "finishMoment.runEnded(finished: end.isFinished, celebrates: celebrate)")
        let waits = start.range(of: "await refreshDerived()")
        #expect(owes != nil, "the end of a run does not say that it owes the moment")
        if let owes, let waits { #expect(owes.lowerBound < waits.lowerBound, "the moment is decided only after the wait: a run that slips in drops it") }
        let shows = start.contains("finishMoment.afterWait(settled: settled.finishMoment,")
        #expect(shows, "the moment does not come from FinishMoment.afterWait")
        let startKeeps = start.contains("finishMoment.runStarted()")
        #expect(startKeeps, "a start does not tell FinishMoment")
        let oldFlag = AppSource.code(model).contains("finishMomentPlayed")
        #expect(!oldFlag, "the old flag still clears a moment nobody saw")
        let claim = try code("func claimFinishMoment(")
        let claims = claim.contains("finishMoment.claim()")
        #expect(claims, "the card's check mark does not settle the moment")
    }
}
