import Foundation

/// DS-08 (design wave 3): one quiet moment when the first full analysis of this installation
/// reaches 100 % while the user is there. On the ring card, where the progress was: "100 %" in
/// the wide figures above "Analyse fertig", and the analysis bar the user watched closing its six
/// parts into one bar; then it folds away and the card is the usual "Analyse fertig". Its one
/// haptic is the success tap that "Analyse fertig" has always had; nothing flies.
///
/// "Reaches 100 %" means the user sees it happen: the first run in the app that finishes the
/// analysis after a wait long enough to celebrate (`AnalysisCardState.celebratesFinish`: the
/// "Analyse fertig" card it rides on; the legs of a run that may bring it and ran in several runs
/// count together, `FirstAnalysisLegs`, verification reviews X9 and Y, Y2 and Y4), with Albumist
/// on screen as it ends (not in the background: Control Center or a call banner in front only
/// make the card wait). Finished in the background, or completed for
/// the first time overnight (`completedAway`), or left before the card showed it, the user comes
/// back to "Analyse fertig" and the notification as before, and the moment is gone for good: a
/// 100 % that happened without them is not replayed hours later.
///
/// A first analysis too quick for "Analyse fertig" (a small part of the library, a few photos
/// shared) leaves it owed for `owedAfterQuickFinish`, seven days from that first completion
/// (`firstCompleted`), and only a run that analyses the library as a whole can bring it then:
/// the first full analysis once another part of the library is taken in, or "Analyse neu
/// aufbauen" (no analysis completed since `AnalysisMarker.reset`), and, after a first analysis
/// of only the photos shared with Albumist ("Ausgewählte Fotos", `sharedOnly`), the first run to
/// end once every photo is allowed, which analyses the rest of the library: it uses up that
/// chance, celebrated or not (its legs count together, `FirstAnalysisLegs`, so a short last leg
/// does not lose it). Never a check for new photos or a catch-up of new imports, however long it
/// runs. After those seven days it is spent (second review, K7; the lead's decisions on
/// verification reviews V6, X9 and Y, Y2 and Y4).
///
/// Exactly once per installation: whether it is still owed is kept in `UserDefaults`
/// (`FirstAnalysisMomentStore`), written as `spent` the moment it becomes due, so once it was due
/// neither a relaunch, a later full analysis ("Analyse neu aufbauen", another part of the
/// library), an undo nor a restored device backup brings it back. Not in the database: that is
/// set aside on a rebuild and not part of a device backup, and the moment must outlive both.
public struct FirstAnalysisMoment: Sendable, Equatable {
    /// What is kept across launches.
    public enum Kept: String, Sendable, CaseIterable {
        /// Not shown yet: no analysis finished on this installation, or only one too quick for
        /// "Analyse fertig" (`firstCompleted`). The first celebrated one on screen brings it.
        case owed
        /// It played, or its chance passed: never again on this installation.
        case spent
    }

    /// What a run of the app analyses, as the moment asks it when the run starts (`mayBeBrought`:
    /// whether its legs count together) and when it ends (`runEnded`).
    public struct Run: Sendable, Equatable {
        /// It analyses the library as a whole: no analysis completed since `AnalysisMarker.reset`
        /// (the first analysis, one of another part of the library, "Analyse neu aufbauen"), not a
        /// check for new photos or a catch-up of new imports.
        public var wholeLibrary: Bool
        /// Every photo is allowed (not only "Ausgewählte Fotos"): after a quick first analysis of
        /// only the shared photos (`sharedOnly`), the first such run analyses the rest of the
        /// library, the library as a whole too.
        public var fullAccess: Bool

        public init(wholeLibrary: Bool, fullAccess: Bool) {
            self.wholeLibrary = wholeLibrary
            self.fullAccess = fullAccess
        }
    }

    public private(set) var kept: Kept
    /// A first analysis too quick for "Analyse fertig" completed then: the moment waits
    /// `owedAfterQuickFinish` from then for a run of the whole library. Kept next to `kept`; nil
    /// once spent.
    public private(set) var firstCompleted: Date?
    /// That quick first analysis saw only the photos shared with Albumist ("Ausgewählte Fotos"):
    /// the first run to end once every photo is allowed analyses the library as a whole too. Kept
    /// next to `firstCompleted`; false once such a run ended, celebrated or not, and once spent.
    public private(set) var sharedOnly = false
    /// The first full analysis finished on screen then; the card shows the moment from then until
    /// `window` has passed. In memory only.
    public private(set) var dueSince: Date?
    /// It plays now: from the card's claim until it folds away (`ended`) or its card goes
    /// (`cardWent`).
    public private(set) var playing = false
    /// Due again: its card went while it played, before its hold (`cardWent`). Then the start
    /// page's done line may play it too, once the run that replaced its card ended. In memory only.
    public private(set) var cutShort = false
    /// Since when it plays, whether VoiceOver said it then, and when it became due: a card that
    /// goes too soon leaves it due again (`cardWent`). In memory only.
    private var playingSince: Date?
    private var heard = false
    private var dueBeforeClaim: Date?

    /// How long after the end of the run the card may still bring it: the user looked at another
    /// tab and comes back to "Vorschläge". Later it is no longer "just now".
    public static let window: TimeInterval = 5 * 60

    /// How long after a first analysis too quick for "Analyse fertig" a run of the whole library
    /// may still bring it: seven days. Later the first 100 % is no longer the first days with the
    /// app (verification review V6).
    public static let owedAfterQuickFinish: TimeInterval = 7 * 24 * 60 * 60

    /// At launch, before anything resets where the analysis got to (`AnalysisMarker.reset`):
    /// `kept` as stored, `completedBefore` whether an analysis was completed before
    /// (`AnalysisMarker.completedOnce`), `firstCompleted` and `sharedOnly` as stored. Never stored is the first
    /// launch of a version with the moment: an analysis completed before it was not seen reaching
    /// 100 % here, spent (an update after the analysis, a device backup of such a version). What
    /// was stored stands: owed after a quick first analysis, which completed the analysis without
    /// "Analyse fertig", until its wait is over (`lapse`).
    public init(kept: Kept?, completedBefore: Bool, firstCompleted: Date? = nil, sharedOnly: Bool = false) {
        self.kept = kept ?? (completedBefore ? .spent : .owed)
        self.firstCompleted = self.kept == .owed ? firstCompleted : nil
        self.sharedOnly = self.firstCompleted != nil && sharedOnly
    }

    /// The wait after a quick first analysis is over (`owedAfterQuickFinish` from
    /// `firstCompleted`): spent. Looked at with every end of a run and at launch.
    public mutating func lapse(at now: Date) {
        guard kept == .owed, let firstCompleted, now.timeIntervalSince(firstCompleted) > Self.owedAfterQuickFinish else { return }
        kept = .spent
        self.firstCompleted = nil
        sharedOnly = false
    }

    /// The analysis was completed where no run of the app ended (the overnight refinement, which
    /// iOS runs without the screen). `first`: it had not been completed before
    /// (`AnalysisMarker.completedOnce`, read before this sets it): its first 100 % happened
    /// without the user, spent. After a quick first analysis it changes nothing.
    public mutating func completedAway(first: Bool) {
        guard first else { return }
        kept = .spent
        firstCompleted = nil
        sharedOnly = false
    }

    /// Whether a run that starts now may bring the moment when it ends, so its legs count together
    /// with the legs before it (`FirstAnalysisLegs`; verification reviews X9 and Y, Y2 and Y4):
    /// while it is owed, a run that takes in the library as a whole (`takesInWholeLibrary`). The
    /// first analysis is one; after a quick first analysis, one of another part of the library or
    /// "Analyse neu aufbauen", and after one of only the shared photos the first run with every
    /// photo allowed, which analyses the rest. Never a check for new photos or a catch-up of new
    /// imports. A wait that is over (`lapse`) is looked at first, where the run starts.
    public func mayBeBrought(by run: Run) -> Bool {
        kept == .owed && takesInWholeLibrary(run)
    }

    /// The run takes in the library as a whole: it analyses it as a whole (`Run.wholeLibrary`),
    /// or, after a quick first analysis of only the shared photos, it is the first with every
    /// photo allowed, which analyses the rest.
    private func takesInWholeLibrary(_ run: Run) -> Bool {
        run.wholeLibrary || (sharedOnly && run.fullAccess)
    }

    /// The end of a run in the app, decided before it waits for the overview. `run`: what it
    /// analysed, the library as a whole or not (`Run.wholeLibrary`), with every photo allowed as
    /// it ends or not (`Run.fullAccess`): after a quick first analysis of only the shared photos
    /// (`sharedOnly`) the first run with every photo analysed the rest of the library, the library
    /// as a whole too, and uses up that chance, celebrated or not (verification review Y, Y4).
    /// `finished`: it finished the analysis (`AnalysisRunEnd.isFinished`); `celebrates`: "Analyse
    /// fertig" is owed for it (`AnalysisCardState.celebratesFinish`, on its legs counted together,
    /// `FirstAnalysisLegs`); `onScreen`: Albumist is not in the background as it ends (in front of
    /// it Control Center or an alert only make the card wait, `claim`). The first celebrated
    /// finish of the whole library decides: due on screen, spent either way. Any other finish
    /// starts the wait after a quick first analysis (`firstCompleted`), and it changes nothing
    /// once that wait is over.
    public mutating func runEnded(_ run: Run, finished: Bool, celebrates: Bool, onScreen: Bool, at now: Date) {
        guard finished, kept == .owed else { return }
        lapse(at: now)
        guard kept == .owed else { return }
        let whole = takesInWholeLibrary(run)
        // Only the first run to end with every photo allowed takes in the rest of the library.
        if run.fullAccess { sharedOnly = false }
        guard celebrates, whole else {
            if firstCompleted == nil {
                firstCompleted = now
                sharedOnly = !run.fullAccess
            }
            return
        }
        if onScreen { dueSince = now }
        kept = .spent
        firstCompleted = nil
        sharedOnly = false
    }

    /// Albumist left the screen (the background, the screen locked): a moment not shown yet is not
    /// shown later; one that plays ends.
    public mutating func leftScreen() {
        ended()
        dueSince = nil
        cutShort = false
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
    /// now. A lapsed one is dropped. `announced`: VoiceOver says it as it starts (it is heard
    /// then, `cardWent`).
    public mutating func claim(at now: Date, onScreen: Bool, announced: Bool = false) -> Bool {
        guard !playing, dueSince != nil else { return false }
        guard isDue(at: now) else {
            dueSince = nil
            return false
        }
        guard onScreen else { return false }
        dueBeforeClaim = dueSince
        dueSince = nil
        cutShort = false
        playing = true
        playingSince = now
        heard = announced
        return true
    }

    /// It folded away after its hold: over.
    public mutating func ended() {
        playing = false
        playingSince = nil
        heard = false
        dueBeforeClaim = nil
    }

    /// Its card went (another tab; a run that starts puts its own card there). While it played and
    /// before its `Timing.hold`, not said by VoiceOver: due again (`cutShort`), and the next card
    /// within `window` of the run's end plays it from the start: "Analyse fertig", or the done
    /// line once the run that replaced it ended (verification review V12). Once it was on screen
    /// for its hold, or VoiceOver said it, over: it never shows twice. A card that went before it
    /// played leaves it due.
    public mutating func cardWent(at now: Date) {
        guard playing else { return }
        let cutShort = !heard && (playingSince.map { now.timeIntervalSince($0) < Timing.hold } ?? false)
        let due = dueBeforeClaim
        ended()
        guard cutShort else { return }
        dueSince = due
        self.cutShort = true
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

/// The legs of an analysis that may bring the first 100 % (verification reviews X9 and Y, the
/// lead's decisions): an analysis that was paused, cut off by iOS or closed and went on later is
/// one wait for "Analyse fertig" and its 100 %. Each run was decided alone before
/// (`AnalysisCardState.celebratesFinish`: 30 s or more with the bar shown), so an analysis of an
/// hour whose last leg took 20 s ended without "Analyse fertig", and its first 100 % was lost.
///
/// - For every run that may bring the moment while it is owed (`FirstAnalysisMoment.mayBeBrought`:
///   the first analysis; after a quick first analysis, one of the library as a whole; after one of
///   only the shared photos, the first with every photo allowed), the legs count together: their
///   summed time and whether one showed the bar. Every other run is decided alone, as before.
/// - Kept with the resume position (`AnalysisMarker.unfinished`): written while a run works, as
///   that is, so a leg that iOS ended with the app (no end of its run) still counts. A run that goes
///   on from the resume position goes on with the legs; one that starts the analysis anew (the
///   first run, another part of the library, "Analyse neu aufbauen", a new or restored database,
///   which drop the resume position) drops them too.
/// - Done once such a run finished, celebrated or not, or the analysis was completed where no run
///   of the app ended (`drop`: the overnight refinement).
public struct FirstAnalysisLegs: Sendable, Equatable {
    /// How long a run or legs ran, in seconds, and whether the card showed one of them as a full
    /// analysis (the bar, not the quick check): what "Analyse fertig" is decided on.
    public struct Leg: Sendable, Equatable {
        public var seconds: Double
        public var showedBar: Bool

        public init(seconds: Double = 0, showedBar: Bool = false) {
            self.seconds = max(0, seconds)
            self.showedBar = showedBar
        }

        /// Nothing ran.
        public static let none = Leg()

        /// This and `next` one after the other.
        public func then(_ next: Leg) -> Leg {
            Leg(seconds: seconds + next.seconds, showedBar: showedBar || next.showedBar)
        }
    }

    /// The legs so far, the run now included: what is kept across launches.
    public private(set) var kept: Leg
    /// The run now may bring the moment (`started`): its legs count together.
    public private(set) var counting = false
    /// The legs before the run now. In memory only.
    private var before: Leg

    /// At launch: the legs kept, while the moment is owed (`FirstAnalysisMoment.kept`, its wait
    /// looked at first); none otherwise.
    public init(kept: Leg = .none, owed: Bool = false) {
        self.kept = owed ? kept : .none
        before = self.kept
    }

    /// A run in the app starts. `mayBringMoment`: it may bring the first 100 % when it ends
    /// (`FirstAnalysisMoment.mayBeBrought`), so its legs count together. `goesOn`: it goes on from
    /// the resume position, so the legs before it count on; otherwise it starts the analysis anew
    /// and they are dropped.
    public mutating func started(mayBringMoment: Bool, goesOn: Bool) {
        counting = mayBringMoment
        before = mayBringMoment && goesOn ? kept : .none
        kept = before
    }

    /// The run works: `leg` since it started. Kept with the resume position.
    public mutating func runs(_ leg: Leg) {
        guard counting else { return }
        kept = before.then(leg)
    }

    /// The run ended after `leg`; `finished`: it finished the analysis. What "Analyse fertig" is
    /// decided on: a leg of the first analysis together with the legs before it, any other run
    /// alone. A finished one ends the legs; an unfinished one leaves them for the next leg.
    public mutating func ended(_ leg: Leg, finished: Bool) -> Leg {
        guard counting else { return leg }
        let counted = before.then(leg)
        counting = false
        kept = finished ? .none : counted
        before = kept
        return counted
    }

    /// The analysis was completed where no run of the app ended (the overnight refinement): no
    /// legs are left to count.
    public mutating func drop() {
        kept = .none
        before = .none
        counting = false
    }
}
