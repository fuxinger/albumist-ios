import Foundation
import Observation
import UIKit
import AlbumistCore

/// The one moment when the first full analysis reaches 100 % on screen (DS-08, design wave 3;
/// the rules are `FirstAnalysisMoment`): whether it is still owed on this installation, kept in
/// `UserDefaults` next to where the analysis got to (`AnalysisMarker`), and whether the ring card
/// shows it now (`FirstAnalysisMomentHeader`). Beside it the legs of an analysis that may bring
/// the moment, which count together for "Analyse fertig" and its 100 % (`FirstAnalysisLegs`,
/// verification reviews X9 and Y). One per app, like the model.
///
/// `UserDefaults`, not the database: a rebuilt database ("Analyse neu aufbauen", a start error)
/// is a new one and is not in a device backup, and neither may bring the moment back; the
/// defaults survive both and come back with a restored backup. Nothing to migrate: a missing
/// value is decided once, at launch (`FirstAnalysisMoment.init`).
@MainActor @Observable
final class FirstAnalysisMomentStore {
    static let shared = FirstAnalysisMomentStore()

    private static let key = "analysis.firstFinishMoment"
    /// When a first analysis too quick for "Analyse fertig" completed (`FirstAnalysisMoment.firstCompleted`).
    private static let firstCompletedKey = "analysis.firstFinishMoment.firstCompleted"
    /// That quick first analysis saw only the photos shared with Albumist (`FirstAnalysisMoment.sharedOnly`).
    private static let sharedOnlyKey = "analysis.firstFinishMoment.sharedOnly"
    /// The legs so far of an analysis that may bring the moment (`FirstAnalysisLegs.kept`), kept
    /// with the resume position: how long they ran and whether one showed the bar (verification
    /// reviews X9 and Y).
    private static let legSecondsKey = "analysis.firstFinishMoment.legSeconds"
    private static let legBarKey = "analysis.firstFinishMoment.legBar"

    private(set) var moment: FirstAnalysisMoment
    /// The legs of an analysis that may bring the moment (`FirstAnalysisLegs`): what "Analyse
    /// fertig" is decided on as it finishes. Not observed: the ring card reads only the moment.
    @ObservationIgnored private var legs = FirstAnalysisLegs()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        // A UI test that starts the first 100 % afresh (`UITestSupport.startsFirstFinishOwed`,
        // always false in the shipped app) reads nothing kept and no analysis completed before.
        let fresh = UITestSupport.startsFirstFinishOwed
        let kept = fresh ? nil : UserDefaults.standard.string(forKey: Self.key).flatMap(FirstAnalysisMoment.Kept.init(rawValue:))
        let since = fresh ? nil : UserDefaults.standard.object(forKey: Self.firstCompletedKey) as? Date
        let sharedOnly = !fresh && UserDefaults.standard.bool(forKey: Self.sharedOnlyKey)
        moment = FirstAnalysisMoment(kept: kept, completedBefore: !fresh && AnalysisMarker.completedOnce,
                                     firstCompleted: since, sharedOnly: sharedOnly)
        // The week after a quick first analysis ended while Albumist was closed (verification review V6).
        moment.lapse(at: Date())
        // The legs of an analysis that went on in another launch, while the moment is owed
        // (verification reviews X9 and Y).
        let legSeconds = fresh ? 0 : UserDefaults.standard.double(forKey: Self.legSecondsKey)
        let legBar = !fresh && UserDefaults.standard.bool(forKey: Self.legBarKey)
        legs = FirstAnalysisLegs(kept: FirstAnalysisLegs.Leg(seconds: legSeconds, showedBar: legBar),
                                 owed: moment.kept == .owed)
        keep()
        // Coming to the front looks at nothing: what completed the analysis meanwhile told the
        // store itself (a run's end, the overnight refinement, `completedAway`), and a quick first
        // analysis completed it without spending the moment (second review, K7).
        observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.leftScreen() }
            },
        ]
    }

    /// At launch, first thing in `AppModel.load`: the store is made here (`shared`), while
    /// `AnalysisMarker` still says whether an analysis was completed before (the load resets it
    /// for a restored backup or a new database), which spends the moment of an installation that
    /// completed its analysis before this version kept the moment.
    func launched() {}

    /// The end of a run in the app (`AppModel.firstAnalysisRunEnded`): what it analysed (`run`).
    func runEnded(_ run: FirstAnalysisMoment.Run, finished: Bool, celebrates: Bool, onScreen: Bool) {
        guard finished else { return }
        moment.runEnded(run, finished: finished, celebrates: celebrates, onScreen: onScreen, at: Date())
        keep()
    }

    /// The analysis was completed where no run of the app ended (the overnight refinement):
    /// `first`, it had not been completed before (`AnalysisMarker.completedOnce`, read before the
    /// refinement sets it); `fullAccess`, every photo is allowed. No legs are left to count.
    func completedAway(first: Bool, fullAccess: Bool) {
        guard moment.kept == .owed else { return }
        moment.completedAway(first: first, fullAccess: fullAccess)
        legs.drop()
        keep()
    }

    /// A run in the app starts (`AppModel.firstAnalysisLegStarted`): what it analyses (`run`),
    /// a leg that counts with the legs before it when it may bring the moment
    /// (`FirstAnalysisMoment.mayBeBrought`; a wait that is over first spends it); `goesOn`: from
    /// the resume position. The moment says whether the legs before it go on
    /// (`FirstAnalysisMoment.legsGoOn`): the rest after only the shared photos goes on without the
    /// position too, which a check that missed a change drops (verification review Z, Z3).
    func legStarted(_ run: FirstAnalysisMoment.Run, goesOn: Bool) {
        moment.lapse(at: Date())
        legs.started(mayBringMoment: moment.mayBeBrought(by: run), goesOn: moment.legsGoOn(with: run, fromPosition: goesOn))
        keep()
    }

    /// The run works, `leg` so far (with each report, as the resume position is written).
    func legRuns(_ leg: FirstAnalysisLegs.Leg) {
        guard legs.counting else { return }
        legs.runs(leg)
        keepLegs(exactly: false)
    }

    /// The run ended after `leg`: what "Analyse fertig" is decided on (`FirstAnalysisLegs.ended`).
    func legEnded(_ leg: FirstAnalysisLegs.Leg, finished: Bool) -> FirstAnalysisLegs.Leg {
        let counted = legs.ended(leg, finished: finished)
        keepLegs(exactly: true)
        return counted
    }

    /// The card with "Analyse fertig" is there: true once, while due and on screen; it plays
    /// from now. VoiceOver says it right after (`FirstAnalysisMomentHeader.start`): heard then.
    func claim(onScreen: Bool) -> Bool {
        guard moment.dueSince != nil, !UITestSupport.isRunning || UITestSupport.showsFirstFinishMoment else { return false }
        return moment.claim(at: Date(), onScreen: onScreen, announced: UIAccessibility.isVoiceOverRunning)
    }

    /// It folded away after its hold.
    func ended() {
        guard moment.playing else { return }
        moment.ended()
    }

    /// Its card went (another tab, a new run's card): cut short before its hold, the next card
    /// plays it again (verification review V12, `FirstAnalysisMoment.cardWent`).
    func cardWent() {
        guard moment.playing else { return }
        moment.cardWent(at: Date())
    }

    /// Albumist left the screen: not shown later; one that plays ends.
    private func leftScreen() {
        guard moment.playing || moment.dueSince != nil else { return }
        moment.leftScreen()
    }

    private func keep() {
        if UserDefaults.standard.string(forKey: Self.key) != moment.kept.rawValue {
            UserDefaults.standard.set(moment.kept.rawValue, forKey: Self.key)
        }
        let stored = UserDefaults.standard.object(forKey: Self.firstCompletedKey) as? Date
        if let since = moment.firstCompleted {
            if stored != since { UserDefaults.standard.set(since, forKey: Self.firstCompletedKey) }
        } else if stored != nil {
            UserDefaults.standard.removeObject(forKey: Self.firstCompletedKey)
        }
        if moment.sharedOnly != UserDefaults.standard.bool(forKey: Self.sharedOnlyKey) {
            if moment.sharedOnly {
                UserDefaults.standard.set(true, forKey: Self.sharedOnlyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.sharedOnlyKey)
            }
        }
        keepLegs(exactly: true)
    }

    /// Writes the legs as kept: exactly as a run starts and ends, and while it works once they
    /// moved on by a second or more since the last write. None: nothing is kept.
    private func keepLegs(exactly: Bool) {
        let seconds = legs.kept.seconds, stored = UserDefaults.standard.double(forKey: Self.legSecondsKey)
        if seconds <= 0 {
            if stored != 0 { UserDefaults.standard.removeObject(forKey: Self.legSecondsKey) }
        } else if exactly ? seconds != stored : abs(seconds - stored) >= 1 {
            UserDefaults.standard.set(seconds, forKey: Self.legSecondsKey)
        }
        if legs.kept.showedBar != UserDefaults.standard.bool(forKey: Self.legBarKey) {
            if legs.kept.showedBar {
                UserDefaults.standard.set(true, forKey: Self.legBarKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.legBarKey)
            }
        }
    }
}

extension AppModel {
    /// The end of a run in the app, decided before it waits for the overview (DS-08): whether it
    /// finished the analysis on screen with "Analyse fertig". On screen means not in the
    /// background (second review, K7): Control Center, an alert or a call banner in front leave
    /// the scene inactive, and the card claims the moment once it is active again
    /// (`FirstAnalysisMomentHeader`); gone to the background before, it is not shown later.
    /// What it analysed is `firstAnalysisRun`.
    func firstAnalysisRunEnded(finished: Bool, celebrates: Bool) {
        FirstAnalysisMomentStore.shared.runEnded(firstAnalysisRun, finished: finished, celebrates: celebrates,
                                                 onScreen: UIApplication.shared.applicationState != .background)
    }

    /// A run in the app starts, with its clock (`beginCard`, after the resume position was read):
    /// a leg that counts with the legs before it when the run may bring the moment
    /// (`FirstAnalysisLegs`, verification review X9) and goes on from the resume position
    /// (`analysis.resumeFrom`, read from `AnalysisMarker.unfinished`), or analyses the rest after
    /// only the shared photos: the follow-up of such a check that missed a change starts without
    /// the position (`startAnalysisNow` drops it for a check) and goes on with the legs (Z3).
    func firstAnalysisLegStarted() {
        FirstAnalysisMomentStore.shared.legStarted(firstAnalysisRun, goesOn: analysis.resumeFrom != nil)
    }

    /// The analysis was completed where no run of the app ended (the overnight refinement,
    /// `refinePass`), told before the marker says so: whether it had been completed before, and
    /// whether every photo is allowed (after only the shared photos, it analysed the rest).
    func firstAnalysisCompletedAway() {
        FirstAnalysisMomentStore.shared.completedAway(first: !AnalysisMarker.completedOnce, fullAccess: access == .full)
    }

    /// What the moment asks of a run as it starts and as it ends (`FirstAnalysisMoment.Run`).
    /// Whether it analyses the library as a whole, from the marker before this run's end sets it:
    /// no analysis completed since `AnalysisMarker.reset` (the first one, "Analyse neu aufbauen",
    /// another part of the library), not a check for new photos (verification review V6); and
    /// whether every photo is allowed: after a quick first analysis of only the shared photos,
    /// the first such run analyses the rest of the library (K7's case).
    private var firstAnalysisRun: FirstAnalysisMoment.Run {
        FirstAnalysisMoment.Run(wholeLibrary: !AnalysisMarker.completedOnce, fullAccess: access == .full)
    }

    /// The run works, `since` its start; `showedBar`: the card showed it as a full analysis. Told
    /// with each report the tick takes, right after `receive` wrote the resume position, so a leg
    /// that iOS ends with the app still counts at the next launch.
    func firstAnalysisLegRuns(since start: ContinuousClock.Instant, showedBar: Bool) {
        FirstAnalysisMomentStore.shared.legRuns(Self.leg(since: start, showedBar: showedBar))
    }

    /// The end of a run, before "Analyse fertig" is decided (`AnalysisCardState.celebratesFinish`):
    /// what it is decided on, the run alone, or, for a run that may bring the moment, its legs
    /// together, so one whose last leg was short is celebrated with its 100 %.
    func firstAnalysisLeg(ended finished: Bool, since start: ContinuousClock.Instant, showedBar: Bool) -> FirstAnalysisLegs.Leg {
        FirstAnalysisMomentStore.shared.legEnded(Self.leg(since: start, showedBar: showedBar), finished: finished)
    }

    /// The time since `start`, in seconds, and whether the card showed the bar.
    private static func leg(since start: ContinuousClock.Instant, showedBar: Bool) -> FirstAnalysisLegs.Leg {
        let ran = (ContinuousClock.now - start).components
        return FirstAnalysisLegs.Leg(seconds: Double(ran.seconds) + Double(ran.attoseconds) / 1e18, showedBar: showedBar)
    }
}
