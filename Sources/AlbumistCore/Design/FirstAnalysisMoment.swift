import Foundation

/// DS-08 (design wave 3): one quiet moment when the first full analysis of this installation
/// reaches 100 % while the user is there. On the ring card, where the progress was: "100 %" in
/// the wide figures above "Analyse fertig", and the analysis bar the user watched closing its six
/// parts into one bar; then it folds away and the card is the usual "Analyse fertig". Its one
/// haptic is the success tap that "Analyse fertig" has always had; nothing flies.
///
/// "Reaches 100 %" means the user sees it happen: the first run in the app that finishes the
/// analysis after a wait long enough to celebrate (`AnalysisCardState.celebratesFinish`: the
/// "Analyse fertig" card it rides on), with Albumist on screen as it ends (not in the background:
/// Control Center or a call banner in front only make the card wait). Finished in the background,
/// or completed for the first time overnight (`completedAway`), or left before the card showed
/// it, the user comes back to "Analyse fertig" and the notification as before, and the moment is
/// gone for good: a 100 % that happened without them is not replayed hours later.
///
/// A first analysis too quick for "Analyse fertig" (a small part of the library, a few photos
/// shared) leaves it owed for `owedAfterQuickFinish`, seven days from that first completion
/// (`firstCompleted`), and only a run that analyses the library as a whole can bring it then:
/// the first full analysis once another part of the library is taken in, or "Analyse neu
/// aufbauen" (no analysis completed since `AnalysisMarker.reset`), and, after a first analysis
/// of only the photos shared with Albumist ("Ausgewählte Fotos", `sharedOnly`), the first run to
/// end once every photo is allowed, which analyses the rest of the library. Never a check for new
/// photos or a catch-up of new imports, however long it runs. After those seven days it is spent
/// (second review, K7; the lead's decision on verification review V6).
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

    public private(set) var kept: Kept
    /// A first analysis too quick for "Analyse fertig" completed then: the moment waits
    /// `owedAfterQuickFinish` from then for a run of the whole library. Kept next to `kept`; nil
    /// once spent.
    public private(set) var firstCompleted: Date?
    /// That quick first analysis saw only the photos shared with Albumist ("Ausgewählte Fotos"):
    /// the first run to end once every photo is allowed analyses the library as a whole too. Kept
    /// next to `firstCompleted`; false once such a run ended, and once spent.
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

    /// The end of a run in the app, decided before it waits for the overview. `finished`: it
    /// finished the analysis (`AnalysisRunEnd.isFinished`); `celebrates`: "Analyse fertig" is owed
    /// for it (`AnalysisCardState.celebratesFinish`); `wholeLibrary`: it analysed the library as a
    /// whole (no analysis completed since `AnalysisMarker.reset`: the first analysis, one of
    /// another part of the library, "Analyse neu aufbauen"), not a check for new photos or a
    /// catch-up; `fullAccess`: every photo is allowed as it ends (not only "Ausgewählte Fotos"),
    /// so after a quick first analysis of only the shared photos (`sharedOnly`) the first such
    /// run analysed the rest of the library, the library as a whole too; `onScreen`: Albumist is
    /// not in the background as it ends (in front of it Control Center or an alert only make the
    /// card wait, `claim`). The first celebrated finish of the whole library decides: due on
    /// screen, spent either way. Any other finish starts the wait after a quick first analysis
    /// (`firstCompleted`), and it changes nothing once that wait is over.
    public mutating func runEnded(finished: Bool, celebrates: Bool, wholeLibrary: Bool, fullAccess: Bool, onScreen: Bool,
                                  at now: Date) {
        guard finished, kept == .owed else { return }
        lapse(at: now)
        guard kept == .owed else { return }
        let whole = wholeLibrary || (sharedOnly && fullAccess)
        // Only the first run to end with every photo allowed takes in the rest of the library.
        if fullAccess { sharedOnly = false }
        guard celebrates, whole else {
            if firstCompleted == nil {
                firstCompleted = now
                sharedOnly = !fullAccess
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
