import Foundation

/// DS-08 (design wave 3): one quiet moment when the first full analysis of this installation
/// reaches 100 % while the user is there. On the ring card, where the progress was: "100 %" in
/// the wide figures above "Analyse fertig", and the analysis bar the user watched closing its six
/// parts into one bar; then it folds away and the card is the usual "Analyse fertig". Its one
/// haptic is the success tap that "Analyse fertig" has always had; nothing flies.
///
/// "Reaches 100 %" means the user sees it happen: a run in the app finishes the analysis for the
/// first time (`AnalysisMarker.completedOnce` was false), after a wait long enough to celebrate
/// (`AnalysisCardState.celebratesFinish`: the "Analyse fertig" card it rides on), with Albumist on
/// screen as it ends. Finished in the background (or overnight, or left before the card showed
/// it), the user comes back to "Analyse fertig" and the notification as before, and the moment is
/// gone for good: a 100 % that happened without them is not replayed hours later.
///
/// Exactly once per installation: whether it is still owed is kept in `UserDefaults`
/// (`FirstAnalysisMomentStore`), written as `spent` the moment it becomes due, so neither a
/// relaunch, a later full analysis ("Analyse neu aufbauen", another part of the library), an
/// undo nor a restored device backup brings it back. Not in the database: that is set aside on a
/// rebuild and not part of a device backup, and the moment must outlive both.
public struct FirstAnalysisMoment: Sendable, Equatable {
    /// What is kept across launches.
    public enum Kept: String, Sendable, CaseIterable {
        /// No analysis finished on this installation yet: the first to finish on screen brings it.
        case owed
        /// It played, or its chance passed: never again on this installation.
        case spent
    }

    public private(set) var kept: Kept
    /// The first full analysis finished on screen then; the card shows the moment from then until
    /// `window` has passed. In memory only.
    public private(set) var dueSince: Date?
    /// It plays now: from the card's claim until it folds away (`ended`).
    public private(set) var playing = false

    /// How long after the end of the run the card may still bring it: the user looked at another
    /// tab and comes back to "Vorschläge". Later it is no longer "just now".
    public static let window: TimeInterval = 5 * 60

    /// At launch, before anything resets where the analysis got to (`AnalysisMarker.reset`):
    /// `kept` as stored (nil: never stored, the first launch of a version with the moment),
    /// `completedBefore` whether an analysis was completed before (`AnalysisMarker.completedOnce`).
    /// Completed before means it was not seen reaching 100 % in this version: spent (an update
    /// after the analysis, a device backup of such a version, an analysis finished while
    /// Albumist was closed).
    public init(kept: Kept?, completedBefore: Bool) {
        self.kept = kept == .spent || completedBefore ? .spent : .owed
    }

    /// Albumist is in front again. An analysis completed meanwhile (the overnight refinement, which
    /// iOS runs without the screen) was not seen reaching 100 %: spent.
    public mutating func cameToFront(completed: Bool) {
        if completed { kept = .spent }
    }

    /// The end of a run in the app, decided before it waits for the overview. `finished`: it
    /// finished the analysis (`AnalysisRunEnd.isFinished`); `celebrates`: "Analyse fertig" is owed
    /// for it (`AnalysisCardState.celebratesFinish`); `completedBefore`: an analysis was completed
    /// before this run (`AnalysisMarker.completedOnce`, read before this run's end sets it);
    /// `onScreen`: Albumist is on screen as it ends.
    public mutating func runEnded(finished: Bool, celebrates: Bool, completedBefore: Bool, onScreen: Bool, at now: Date) {
        guard finished else { return }
        if kept == .owed, !completedBefore, celebrates, onScreen { dueSince = now }
        kept = .spent
    }

    /// Albumist left the screen (the background, the screen locked): a moment not shown yet is not
    /// shown later; one that plays ends.
    public mutating func leftScreen() {
        dueSince = nil
        playing = false
    }

    /// Due now: the first full analysis finished on screen, at most `window` ago.
    public func isDue(at now: Date) -> Bool {
        guard let dueSince else { return false }
        let since = now.timeIntervalSince(dueSince)
        return since >= 0 && since <= Self.window
    }

    /// The card shows it: due, or playing.
    public func shows(at now: Date) -> Bool { playing || isDue(at: now) }

    /// The card with "Analyse fertig" is there: true once, while due and on screen; it plays from
    /// now. A lapsed one is dropped.
    public mutating func claim(at now: Date, onScreen: Bool) -> Bool {
        guard !playing, dueSince != nil else { return false }
        guard isDue(at: now) else {
            dueSince = nil
            return false
        }
        guard onScreen else { return false }
        dueSince = nil
        playing = true
        return true
    }

    /// It folded away, or its card went while it played (another tab, a new run): over. A card
    /// that went before it played leaves it due: the next card within `window` brings it.
    public mutating func ended() {
        playing = false
    }

    /// How it plays (`FirstAnalysisMomentHeader`): "100 %" and the full bar come with "Analyse
    /// fertig"; after `joinDelay` the bar's six parts close into one over `join`; it stays until
    /// `hold` from its start and folds away over `fold`. Calm (Reduce Motion): the bar shows
    /// joined, nothing moves, it fades in and out over `fade`. A UI test that asks for it holds it
    /// `heldForUITest`, so its checks every two seconds and its screenshot find it.
    public enum Timing {
        public static let joinDelay = 0.35
        public static let join = 0.7
        public static let hold = 3.2
        public static let fold = 0.45
        public static let fade = 0.3
        public static let heldForUITest = 15.0
    }

    /// One part of the bar as it joins: from `x`, `width` points wide; its ends round by these
    /// fractions of the bar's half height (1 a capsule's end, 0 square).
    public struct Segment: Equatable, Sendable {
        public var x: Double
        public var width: Double
        public var leadingRound: Double
        public var trailingRound: Double
    }

    /// The analysis bar at 100 % as it joins (`joined` 0…1): at 0 the six parts of the analysis
    /// bar side by side with `gap` points between them, each as wide as its step's share of what
    /// the gaps leave (as `SegmentRow` places them); the gaps close and the inner ends square off
    /// together; at 1 one bar over the whole width.
    public static func segments(shares: [Double], width: Double, gap: Double = 3, joined: Double) -> [Segment] {
        let total = shares.reduce(0) { $0 + max(0, $1) }
        guard width > 0, total > 0 else { return [] }
        let t = min(max(joined, 0), 1)
        if t >= 1 { return [Segment(x: 0, width: width, leadingRound: 1, trailingRound: 1)] }
        let open = gap * (1 - t)
        let usable = max(0, width - open * Double(shares.count - 1))
        var x = 0.0
        return shares.enumerated().map { index, share in
            let part = Segment(x: x, width: usable * max(0, share) / total,
                               leadingRound: index == 0 ? 1 : 1 - t,
                               trailingRound: index == shares.count - 1 ? 1 : 1 - t)
            x += part.width + open
            return part
        }
    }
}
