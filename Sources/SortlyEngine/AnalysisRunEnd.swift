import Foundation
import SortlyCore

/// What follows the end of a run, for runs in the app and the overnight refinement alike
/// (`AppModel`; second review of the labels fix, 17.11.).
///
/// A run reads each setting it works with once, at its own point
/// (`AnalysisPipeline.Report.settingsUsed`). At its end that is compared with the settings as
/// they are then:
/// - It missed a change (labels, texts, finer places, online lookups, hidden photos): one more
///   run starts right away (`followUp`), and this end is not the end of the analysis: no
///   "Analyse fertig", no 100 %, no notification, the marker stays. Before, the run ended with
///   "Analyse fertig" and the next one came about 20 s later, in the background only once the
///   app was opened again. A change the run took in (made before it read that setting) needs
///   nothing more.
/// - Pause was tapped but the run finished anyway (its last steps do not stop), with work left
///   (a change it missed, or changes in Photos during it): it reads as paused by the user, with
///   "Fortsetzen". A Pause tap never ends in "fertig" while work is left, and nothing starts by
///   itself (before, the change was lost).
/// - Changes in Photos during the run (`AppModel.catchUpAfterRun`): one more pass after the
///   usual gap (`LibraryChangeWatcher`); a follow-up run takes them in too. Every run's end takes
///   the request, the overnight refinement's too (before, only runs in the app did, and a request
///   made during a refinement waited for some later run).
/// - Paused by the user: nothing follows; "Fortsetzen" reads the library and the settings anew.
/// - Ended early by itself (an error, heat, the app's time, the photo access): it goes on a
///   little later (`retry`); the overnight refinement leaves that to its next window.
public struct AnalysisRunEnd: Sendable, Equatable {
    public enum Next: Sendable, Equatable {
        /// Nothing starts: the analysis is done, waits for "Fortsetzen", or a run that is due
        /// anyway takes the work (after a plan being written, a rebuild, the photo access).
        case nothing
        /// One more run, right away.
        case followUp
        /// One more pass after the usual gap (`LibraryChangeWatcher.scheduleCatchUp`).
        case catchUp
        /// The run goes on a little later (`AppModel.retryUnattendedRun`).
        case retry
    }

    /// The report as the app keeps it: paused by the user when Pause was tapped and work is left.
    public var report: AnalysisPipeline.Report?
    public var next: Next
    /// The analysis is finished with this run. The finish card, haptic and notification, the
    /// Lock Screen's "Analyse fertig", the 100 % and the end of the marker are for this case only.
    public var isFinished: Bool
    /// Pause was tapped, and the run ended unfinished for another reason before the Pause
    /// stopped it (an error, the heat, Photos not answering): the Pause stays all the same, and
    /// nothing goes on by itself (review of the Pause fix, a).
    public var pauseHeld = false

    /// `report`: the run's report, `nil` when it threw or was stopped on purpose. `settings`: as
    /// they are now. `pauseTapped`: Pause was tapped during the run (it may have come too late
    /// to stop it). `catchUpRequested`: Photos changed during the run. `mayStart`: a run may
    /// start now (past the introduction, photos readable, no plan claimed or being written, no
    /// rebuild). `background`: the overnight refinement.
    public init(report: AnalysisPipeline.Report?, settings: OrganizationSettings, pauseTapped: Bool,
                catchUpRequested: Bool, mayStart: Bool, background: Bool = false) {
        self.report = report
        let later: Next = pauseTapped ? .nothing : (catchUpRequested ? .catchUp : (background ? .nothing : .retry))
        pauseHeld = pauseTapped
        guard let report else {
            next = later
            isFinished = false
            return
        }
        pauseHeld = false
        if report.pausedBecause == .userPaused {
            next = .nothing
            isFinished = false
            return
        }
        if report.pausedBecause != nil {
            next = later
            isFinished = false
            pauseHeld = pauseTapped
            return
        }
        let settingsLeft = report.settingsUsed.needsRun(for: settings)
        if pauseTapped && (settingsLeft || catchUpRequested) {
            self.report?.pausedBecause = .userPaused
            next = .nothing
            isFinished = false
            return
        }
        if settingsLeft {
            next = mayStart ? .followUp : (catchUpRequested ? .catchUp : .nothing)
            isFinished = false
            return
        }
        next = catchUpRequested ? .catchUp : .nothing
        isFinished = true
    }

    /// The run ended neither done nor paused by the user: the analysis goes on by itself
    /// (`AppModel.AnalysisState.needsResume`), also when the settings left work that starts right
    /// away or once what holds it ends. The Lock Screen then says "Analyse wartet auf dich",
    /// never "Analyse fertig".
    public var needsResume: Bool { !isFinished && !keepsPause }

    /// The overnight refinement's `needsResume` after this end, from the one before it:
    /// - finished: nothing to go on with;
    /// - paused by the user (Pause tapped while the app was open): the Pause stays, "Fortsetzen"
    ///   goes on (third review of the labels fix, finding 1: before, a refinement paused that way
    ///   left the value as it was, and an unfinished analysis went on by itself);
    /// - a change of the settings it missed: not done; one more pass in the same window
    ///   (`AppModel.refine`), or the app goes on with it when opened;
    /// - cut off by iOS or stopped by the device: as it was; the next window goes on.
    public func needsResume(afterRefinement before: Bool) -> Bool {
        if isFinished || keepsPause { return false }
        return report?.isComplete == true ? true : before
    }

    /// What is left once the end of the run has waited for the overview to refresh (`AppModel`):
    /// the finish moment, and a pass or a retry later (a follow-up started before the wait).
    /// Nothing when another run started meanwhile (`isNewest` false: the follow-up, a change of
    /// the settings, "Neu prüfen"): that run shows its own state and reads the library and the
    /// settings anew (review finding 4: the earlier run wrote "Analyse fertig" over its card).
    public func afterWait(isNewest: Bool) -> (finishMoment: Bool, next: Next) {
        guard isNewest else { return (false, .nothing) }
        return (isFinished, next == .followUp ? .nothing : next)
    }
}

/// Why a run is asked for, and what a Pause of the user does to it (`AppModel.startAnalysis`).
///
/// A Pause stands until the user goes on (`AnalysisMarker.pausedByUser`, also across launches):
/// - Nothing that happens by itself starts a run then (`automatic`); "Fortsetzen" reads the
///   library and the settings anew. A change in the settings has its own rule and waits for
///   "Fortsetzen" too (`AnalysisPipeline.runAfterSettingsChange`).
/// - A tap that asks for the analysis starts it and ends the Pause (`tap`).
/// - A change of the user's that needs a run to apply it starts that run at once and ends the
///   Pause, like a tap (`userChange`; owner decision 18.11.2026, "Analyse läuft dann weiter").
///   Before, the change was stored, the run waited for "Fortsetzen", and the trip workshop or the
///   settings kept the old trips with no word why.
///
/// No cause starts a run under a standing Pause: what starts while paused ends it.
public enum AnalysisStartCause: Sendable, Equatable, CaseIterable {
    /// Nothing the user did just now: the start at launch, a follow-up, a retry, the end of a
    /// plan, changes in Photos.
    case automatic
    /// A tap that asks for the analysis: "Fortsetzen", "Analyse neu aufbauen", another part of
    /// the library, a change in the settings that needs a run (only without a Pause).
    case tap
    /// A change of the user's that needs a run to apply it: a split, a merge, "Aufheben" in the
    /// trip workshop, "Reisen wieder automatisch erkennen" in the settings, an answer in "Dein
    /// Zuhause" that changes the trips.
    case userChange

    /// A run with this cause starts while the Pause stands.
    public var startsWhilePaused: Bool { self != .automatic }
    /// Its run ends the Pause.
    public var endsPause: Bool { self != .automatic }
    /// Started by the user: background time for a long run, the retries count from nothing again.
    public var isUserInitiated: Bool { self != .automatic }

    /// Whether the run starts now.
    public func startsRun(pausedByUser: Bool) -> Bool { !pausedByUser || startsWhilePaused }

    /// Whether the Pause still stands once this run has started.
    public func pausedAfterStart(pausedByUser: Bool) -> Bool { pausedByUser && !endsPause }

    /// Two requests that become one run (asked for while a change in "Dein Zuhause" is applied):
    /// the one the user asked for wins, so a queued trip change still ends the Pause.
    public func joined(with other: Self?) -> Self {
        guard let other else { return self }
        return other.rank > rank ? other : self
    }

    private var rank: Int {
        switch self {
        case .automatic: 0
        case .tap: 1
        case .userChange: 2
        }
    }
}

extension AnalysisWorkload {
    /// The work left is mostly image labels for photos analysed before ("Themen" or
    /// "Dokumente" turned on since): a check run names it "Fotos werden für die neuen Bereiche
    /// angesehen" instead of the image step's own title (review finding 7: right after "Alle
    /// 5.683 Fotos analysiert" the check said "Bildinhalte werden erkannt · 0 von 5.683").
    public var isMostlyLabels: Bool { labelsLeft > 0 && labelsLeft >= contentLeft + textLeft - labelsLeft }
}

extension ResumedRun.NewWork {
    /// As kept in the marker (`AnalysisMarker.Point.newWork`). Builds before `newAreas` know
    /// only the other four labels and drop a marker they cannot read whole (review finding 9):
    /// `newAreas` is kept as `newPhotos`, the same kind of phase, with a flag those builds
    /// ignore (`markerFlag`).
    public var markerValue: Self { self == .newAreas ? .newPhotos : self }
    /// The marker's flag for `newAreas` (`nil` for every other label).
    public var markerFlag: Bool? { self == .newAreas ? true : nil }
    /// The label read back from the marker's two fields.
    public static func fromMarker(_ value: Self?, flag: Bool?) -> Self? { flag == true ? .newAreas : value }
}
