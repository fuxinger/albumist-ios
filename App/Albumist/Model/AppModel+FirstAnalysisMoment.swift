import Foundation
import Observation
import UIKit
import AlbumistCore

/// The one moment when the first full analysis reaches 100 % on screen (DS-08, design wave 3;
/// the rules are `FirstAnalysisMoment`): whether it is still owed on this installation, kept in
/// `UserDefaults` next to where the analysis got to (`AnalysisMarker`), and whether the ring card
/// shows it now (`FirstAnalysisMomentHeader`). One per app, like the model.
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

    private(set) var moment: FirstAnalysisMoment
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        // A UI test that starts the first 100 % afresh (`UITestSupport.startsFirstFinishOwed`,
        // always false in the shipped app) reads nothing kept and no analysis completed before.
        let fresh = UITestSupport.startsFirstFinishOwed
        let kept = fresh ? nil : UserDefaults.standard.string(forKey: Self.key).flatMap(FirstAnalysisMoment.Kept.init(rawValue:))
        let since = fresh ? nil : UserDefaults.standard.object(forKey: Self.firstCompletedKey) as? Date
        moment = FirstAnalysisMoment(kept: kept, completedBefore: !fresh && AnalysisMarker.completedOnce, firstCompleted: since)
        // The week after a quick first analysis ended while Albumist was closed (verification review V6).
        moment.lapse(at: Date())
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

    /// The end of a run in the app (`AppModel.firstAnalysisRunEnded`).
    func runEnded(finished: Bool, celebrates: Bool, wholeLibrary: Bool, onScreen: Bool) {
        guard finished else { return }
        moment.runEnded(finished: finished, celebrates: celebrates, wholeLibrary: wholeLibrary, onScreen: onScreen, at: Date())
        keep()
    }

    /// The analysis was completed where no run of the app ended (the overnight refinement):
    /// `first`, it had not been completed before (`AnalysisMarker.completedOnce`, read before the
    /// refinement sets it).
    func completedAway(first: Bool) {
        guard first, moment.kept == .owed else { return }
        moment.completedAway(first: first)
        keep()
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
    }
}

extension AppModel {
    /// The end of a run in the app, decided before it waits for the overview (DS-08): whether it
    /// finished the analysis on screen with "Analyse fertig". On screen means not in the
    /// background (second review, K7): Control Center, an alert or a call banner in front leave
    /// the scene inactive, and the card claims the moment once it is active again
    /// (`FirstAnalysisMomentHeader`); gone to the background before, it is not shown later.
    /// Whether it analysed the library as a whole, from the marker before this run's end sets it:
    /// no analysis completed since `AnalysisMarker.reset` (the first one, "Analyse neu aufbauen",
    /// another part of the library), not a check for new photos (verification review V6).
    func firstAnalysisRunEnded(finished: Bool, celebrates: Bool) {
        FirstAnalysisMomentStore.shared.runEnded(finished: finished, celebrates: celebrates,
                                                 wholeLibrary: !AnalysisMarker.completedOnce,
                                                 onScreen: UIApplication.shared.applicationState != .background)
    }
}
