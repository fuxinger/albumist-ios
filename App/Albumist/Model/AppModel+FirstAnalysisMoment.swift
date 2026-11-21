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

    private(set) var moment: FirstAnalysisMoment
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let kept = UserDefaults.standard.string(forKey: Self.key).flatMap(FirstAnalysisMoment.Kept.init(rawValue:))
        moment = FirstAnalysisMoment(kept: kept, completedBefore: AnalysisMarker.completedOnce)
        keep()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.leftScreen() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameToFront() }
            },
        ]
    }

    /// At launch, first thing in `AppModel.load`: read while `AnalysisMarker` still says whether
    /// an analysis was completed before (the load resets it for a restored backup or a new
    /// database, and an analysis completed before this version spends the moment).
    func launched() {
        cameToFront()
    }

    /// The end of a run in the app (`AppModel.firstAnalysisRunEnded`).
    func runEnded(finished: Bool, celebrates: Bool, completedBefore: Bool, onScreen: Bool) {
        guard finished else { return }
        moment.runEnded(finished: finished, celebrates: celebrates, completedBefore: completedBefore, onScreen: onScreen, at: Date())
        keep()
    }

    /// The card with "Analyse fertig" is there: true once, while due and on screen; it plays
    /// from now.
    func claim(onScreen: Bool) -> Bool {
        guard moment.dueSince != nil else { return false }
        return moment.claim(at: Date(), onScreen: onScreen)
    }

    /// It folded away, or the card went (another tab, a new run).
    func ended() {
        guard moment.playing || moment.dueSince != nil else { return }
        moment.ended()
    }

    /// Albumist left the screen: not shown later; one that plays ends.
    private func leftScreen() {
        guard moment.playing || moment.dueSince != nil else { return }
        moment.leftScreen()
    }

    /// In front again (or launched): an analysis completed meanwhile (overnight, in the
    /// background) was not seen reaching 100 %.
    private func cameToFront() {
        guard moment.kept == .owed, AnalysisMarker.completedOnce else { return }
        moment.cameToFront(completed: true)
        keep()
    }

    private func keep() {
        if UserDefaults.standard.string(forKey: Self.key) != moment.kept.rawValue {
            UserDefaults.standard.set(moment.kept.rawValue, forKey: Self.key)
        }
    }
}

extension AppModel {
    /// The end of a run in the app, decided before it waits for the overview (DS-08): whether it
    /// finished the first full analysis on screen. `AnalysisMarker.completedOnce` still says how
    /// it was before this run (its end sets it after this).
    func firstAnalysisRunEnded(finished: Bool, celebrates: Bool) {
        FirstAnalysisMomentStore.shared.runEnded(finished: finished, celebrates: celebrates,
                                                 completedBefore: AnalysisMarker.completedOnce, onScreen: isOnScreen)
    }
}
