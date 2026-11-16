import Foundation

/// When Albumist asks for an App Store rating (Fuchs, 16.11.2026): after new albums, never at app start.
///
/// The moment is the "wow": a plan the user applied made new albums, and they saw its result
/// ("Fertig", the counts, "Rückgängig machen") and left it without taking anything back. The
/// app then asks with SwiftUI's `requestReview` (StoreKit) a moment later, so the question
/// never covers the result or its receipt. iOS decides whether the question really appears (at
/// most three times in 365 days) and how it looks: Albumist has no rating screen of its own, and
/// nothing in it depends on an answer.
///
/// It asks only when all of this holds (each rule has its `Refusal`):
/// - no UI test runs, and Albumist's sample photos are not in the library (an App Review device
///   trying them, `SampleLibrary.Record`; in the simulator also the demo library);
/// - the result was seen in this run of the app: never at a start, and never for a plan that
///   finished before the app was closed (`Session` starts empty at every launch);
/// - the plan made at least one new album, and everything it set out to do happened and was
///   confirmed (no failed, skipped, left or unconfirmed step, no photo missing); it is neither
///   an undo nor "Fehlendes erneut versuchen";
/// - the user did not take it back, not even in part; no plan of this run went wrong (failed,
///   stopped half way, results not stored), and no plan that was cut off was found in it;
/// - nothing is busy: no analysis (so never during the first one), no plan, no change in "Dein
///   Zuhause", no plan that was cut off; Albumist is on screen and shows no message;
/// - the user left the result a moment ago and stayed in Albumist: leaving the app while the
///   question waits drops it, and a wait that ran long (the app was in the background) counts
///   as gone (`momentLasts`);
/// - it did not ask for this version of the app yet, nor in the last 120 days (a last question
///   dated more than a day ahead counts as asked today, `State.clockChecked`).
///
/// So it may ask after any plan like this, at most once per version and 120 days apart; for
/// most people the first such plan makes their first albums. The first day is not left out:
/// the first albums are the moment that was chosen, and most people make them on the day they
/// install Albumist. Apple's advice (not at the first launch or during the introduction, only
/// once people know the app) holds anyway: never at a start, never while an analysis runs, only
/// after a task the user finished and looked at.
public enum ReviewPromptPolicy {
    /// At least this many days between two questions.
    public static let daysBetweenQuestions = 120

    /// After the user left the result, the next screen settles first: the question never covers
    /// the result or its receipt.
    public static let delay: Duration = .milliseconds(1500)
    /// The check for new photos that follows every plan is waited for this long at most. A first
    /// analysis that is still running takes longer: then nothing is asked (no analysis may run).
    public static let analysisWait: Duration = .seconds(15)
    /// A moment is gone this long after the user left the result: both waits and 2 s to spare.
    /// Measured on `ContinuousClock`, where time in the background counts: a wait that iOS
    /// suspended never asks the moment the user comes back, maybe hours later.
    public static let momentLasts: Duration = delay + analysisWait + .seconds(2)

    /// Why Albumist does not ask now.
    public enum Refusal: Hashable, Sendable {
        /// A UI test runs: nothing may cover the screen it taps next.
        case uiTest
        /// Albumist's sample photos are in the library (App Review tries them).
        case samplePhotos
        /// The result was not seen in this run of the app (it has just started).
        case resultNotSeen
        /// The plan took changes back.
        case undoPlan
        /// "Fehlendes erneut versuchen": the plan before it did not get everything done.
        case retryPlan
        /// Not everything happened: a step failed, was skipped, left or not confirmed, or
        /// photos were no longer in the library.
        case incomplete
        /// No new album (only albums extended, merged or taken apart).
        case noNewAlbum
        /// The user took the plan back, completely or in part (or started to).
        case undone
        /// A plan of this run failed, stopped half way or could not store its results, or a
        /// plan that was cut off was found.
        case troubleInThisSession
        case planRunning
        case analysisRunning
        case homeChangeRunning
        /// A plan that was cut off waits to be continued, kept or taken back.
        case planInterrupted
        /// Albumist is not on screen.
        case notOnScreen
        /// The user left the result longer than `momentLasts` ago (Albumist was in the
        /// background meanwhile, or the wait ran long).
        case momentPassed
        /// A message is on screen.
        case messageShown
        /// Asked before in this version of the app.
        case askedInThisVersion
        /// Asked less than `daysBetweenQuestions` days ago (or the clock went back since).
        case askedRecently
    }

    /// The last question, kept in the user defaults (iOS keeps its own count apart).
    public struct State: Hashable, Sendable, Codable {
        /// The version of the app that asked ("1.0.0").
        public var lastAskedVersion: String?
        public var lastAskedAt: Date?

        public init(lastAskedVersion: String? = nil, lastAskedAt: Date? = nil) {
            self.lastAskedVersion = lastAskedVersion
            self.lastAskedAt = lastAskedAt
        }

        /// After asking now. Written down when the app asks: iOS does not say whether the
        /// question appeared.
        public static func asked(version: String, at date: Date) -> State {
            State(lastAskedVersion: version, lastAskedAt: date)
        }

        /// A last question dated more than a day after `now` counts as asked now: the clock was
        /// set back, or it was wrong when Albumist asked. The 120 days then run from today, not
        /// from a date that may lie years ahead (the app stores the result). Up to a day ahead
        /// stays as it is (time zones, a clock the network set right) and counts as recent.
        public func clockChecked(now: Date) -> State {
            guard let last = lastAskedAt, last.timeIntervalSince(now) > 24 * 60 * 60 else { return self }
            var state = self
            state.lastAskedAt = now
            return state
        }

        /// The stored value. Fields a later version adds come from the defaults
        /// (`StoredDefaults`); nothing stored or unreadable bytes count as never asked (iOS
        /// still allows at most three questions a year).
        public init(stored data: Data?) {
            let decoded = data.flatMap {
                try? StoredDefaults.decode(State.self, from: $0, defaults: State(), encoder: JSONEncoder(), decoder: JSONDecoder())
            }
            self = decoded ?? State()
        }

        /// The bytes to store.
        public var stored: Data? { try? JSONEncoder().encode(self) }
    }

    /// What the app is doing at the moment of asking.
    public struct Situation: Hashable, Sendable {
        /// Also a plan that has its claim but has not started yet.
        public var planRunning: Bool
        /// Also "Analyse neu aufbauen" while it clears the tables.
        public var analysisRunning: Bool
        public var homeChangeRunning: Bool
        public var planInterrupted: Bool
        /// The app's scene is active.
        public var onScreen: Bool
        public var messageShown: Bool
        /// Albumist's sample photos (or the simulator's demo library) are in the library.
        public var samplePhotos: Bool
        public var uiTest: Bool
        /// How long ago the user left the result (`Session.takeWaiting`), on `ContinuousClock`:
        /// time in the background counts.
        public var sinceLeft: Duration

        public init(planRunning: Bool = false, analysisRunning: Bool = false, homeChangeRunning: Bool = false,
                    planInterrupted: Bool = false, onScreen: Bool = true, messageShown: Bool = false,
                    samplePhotos: Bool = false, uiTest: Bool = false, sinceLeft: Duration = .zero) {
            self.planRunning = planRunning
            self.analysisRunning = analysisRunning
            self.homeChangeRunning = homeChangeRunning
            self.planInterrupted = planInterrupted
            self.onScreen = onScreen
            self.messageShown = messageShown
            self.samplePhotos = samplePhotos
            self.uiTest = uiTest
            self.sinceLeft = sinceLeft
        }
    }

    /// One run of the app, from its launch: the results the user saw and left, the plans they
    /// took back, and whether a plan went wrong. Empty at every launch, so nothing from before
    /// the start (a plan that finished before the app was closed, the history) can ask.
    public struct Session: Hashable, Sendable {
        /// The plan whose result was seen last, until it is settled (asked about or not).
        public private(set) var waiting: ChangePlan?
        /// When the user left the result of the waiting plan (and its receipt): the moment to
        /// ask, a little later. `ContinuousClock`: time in the background counts.
        public private(set) var left: ContinuousClock.Instant?
        /// Results and receipts on screen now. A receipt opened from the result covers it: the
        /// question waits until the user has left both.
        public private(set) var screens = 0
        public private(set) var seenResults: Set<SortlyID> = []
        public private(set) var undonePlans: Set<SortlyID> = []
        public private(set) var hadTrouble = false

        public init() {}

        /// The result of `plan` was on screen for a moment (not only flashed by).
        public mutating func resultSeen(_ plan: ChangePlan) {
            seenResults.insert(plan.id)
            waiting = plan
        }

        /// A result or receipt came on screen: a moment that waited is over (the next one comes
        /// when the user leaves them).
        public mutating func screenAppeared() {
            screens += 1
            left = nil
        }

        /// A result or receipt left the screen at `now`. True when the user has now left the
        /// result of a plan that waits: the moment to ask (a little later, see the app).
        public mutating func screenDisappeared(at now: ContinuousClock.Instant) -> Bool {
            screens = max(0, screens - 1)
            guard screens == 0, waiting != nil else { return false }
            left = now
            return true
        }

        /// Albumist left the screen (another app, the Home Screen, a call, Control Center).
        /// A moment that waited is gone, and its plan with it: the question would come when
        /// the user is back, maybe hours later. A result still on screen keeps its plan (the
        /// user may be looking at the new albums in Photos): leaving it later is the moment.
        public mutating func sceneLeft() {
            guard left != nil else { return }
            left = nil
            waiting = nil
        }

        /// The user asked to take `plan` back (whether or not it all went).
        public mutating func undoStarted(_ plan: SortlyID) {
            undonePlans.insert(plan)
            if waiting?.id == plan { waiting = nil }
        }

        /// A plan ran in this session: applied, taken back, continued or tried again. `result`
        /// is nil when it stopped with an error; `resultsStored`: what follows a run (albums,
        /// decisions, free albums) was stored.
        public mutating func planEnded(_ result: ChangePlan?, resultsStored: Bool) {
            let clean = result.map { $0.status == .completed && PlanReceipt(plan: $0, inventory: CollectionInventory()).isComplete } ?? false
            if !clean || !resultsStored { hadTrouble = true }
        }

        /// A plan that was cut off (the app ended while it ran, or it stopped half way) is open.
        public mutating func interruptedPlanFound() {
            hadTrouble = true
        }

        /// The plan to ask about now and when the user left its result, once. Nil when none
        /// waits, or while a result or receipt is on screen again (then it waits until the user
        /// leaves them).
        public mutating func takeWaiting() -> (plan: ChangePlan, left: ContinuousClock.Instant)? {
            guard screens == 0, let plan = waiting, let left else { return nil }
            waiting = nil
            self.left = nil
            return (plan, left)
        }
    }

    /// Why not to ask now about `plan` (the result the user just left); nil: ask.
    public static func refusal(after plan: ChangePlan, session: Session, situation: Situation,
                               state: State, version: String, now: Date) -> Refusal? {
        if situation.uiTest { return .uiTest }
        if situation.samplePhotos { return .samplePhotos }
        guard session.seenResults.contains(plan.id) else { return .resultNotSeen }
        if plan.reverts != nil { return .undoPlan }
        if plan.retries != nil { return .retryPlan }
        let receipt = PlanReceipt(plan: plan, inventory: CollectionInventory())
        guard plan.status == .completed, receipt.isComplete else { return .incomplete }
        guard receipt.albumsCreated > 0 else { return .noNewAlbum }
        if session.undonePlans.contains(plan.id) { return .undone }
        if session.hadTrouble { return .troubleInThisSession }
        if situation.planRunning { return .planRunning }
        if situation.analysisRunning { return .analysisRunning }
        if situation.homeChangeRunning { return .homeChangeRunning }
        if situation.planInterrupted { return .planInterrupted }
        if !situation.onScreen { return .notOnScreen }
        if situation.sinceLeft > momentLasts { return .momentPassed }
        if situation.messageShown { return .messageShown }
        if state.lastAskedVersion == version { return .askedInThisVersion }
        if let last = state.lastAskedAt, now.timeIntervalSince(last) < Double(daysBetweenQuestions) * 24 * 60 * 60 {
            return .askedRecently
        }
        return nil
    }
}
