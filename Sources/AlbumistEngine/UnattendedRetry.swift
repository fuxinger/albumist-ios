import Foundation

/// When a run that ended early by itself goes on (`AnalysisRunEnd.Next.retry`,
/// `AppModel.retryUnattendedRun`), and what the end of a plan does about it
/// (`AppModel.releaseExecution`).
///
/// - Ended by an error, Vision failing (often on a hot iPhone) or the device: tried again after
///   30 s, then after 60 s; then not again until a run is started by a tap, the app comes on
///   screen, or the analysis finishes.
/// - Ended because Photos did not answer (`PhotosNotResponding`): every 60 s, without a cap. A try
///   sends nothing while the call before still hangs (`PhotosDeadline`). The same when a call
///   into Photos never got a thread (`Cause.busy`): nothing was sent.
/// - A plan held the analysis back meanwhile: when its claim ends, the analysis goes on only once
///   the try is due (app-speed 18.11.2026, open point D of the labels fix). Before, the end of
///   the plan started it at once, past the wait: a Vision that had just failed on a hot iPhone
///   was asked again within seconds. A try that came due during the plan and could not start then
///   goes on when the plan ends.
public struct UnattendedRetry: Sendable, Equatable {
    /// The wait after a run that ended because Photos did not answer.
    public static let photosDelay: Duration = .seconds(60)
    /// Tries after other early ends, each waiting 30 s longer than the one before.
    public static let maxTries = 2

    /// Tries made since the count was last reset.
    public private(set) var tries = 0
    /// A try waits until then; `nil`: none is waiting.
    public private(set) var due: ContinuousClock.Instant?

    public init() {}

    /// Why a run ended early by itself, when it is not an ordinary error.
    public enum Cause: Sendable, Equatable {
        /// Photos did not answer (`PhotosNotResponding`).
        case photos
        /// A call into Photos never began: Albumist's own work kept every thread busy, and
        /// nothing was asked of Photos (`PhotosNotResponding.neverBegan`).
        case busy
    }

    /// A run ended early by itself: how long until the next try, or `nil` when none comes.
    /// `.busy` is tried again like `.photos`, every minute without a cap: nothing was sent, a
    /// thread pool kept busy by the analysis is busy again on the next try now and then, and
    /// after two such ends the analysis must not stop for good with nothing said (review of
    /// f7439fb, MF1). Neither uses up the tries of other early ends.
    public mutating func schedule(after cause: Cause?, now: ContinuousClock.Instant) -> Duration? {
        schedule(photos: cause != nil, now: now)
    }

    /// A run ended early by itself: how long until the next try, or `nil` when none comes.
    /// `photos`: it ended because Photos did not answer.
    public mutating func schedule(photos: Bool, now: ContinuousClock.Instant) -> Duration? {
        let delay: Duration
        if photos {
            delay = Self.photosDelay
        } else {
            guard tries < Self.maxTries else {
                due = nil
                return nil
            }
            tries += 1
            delay = .seconds(30 * tries)
        }
        due = now + delay
        return delay
    }

    /// A run started, by the try or otherwise: no try waits any more.
    public mutating func runStarted() {
        due = nil
    }

    /// Started by a tap, the app back on screen, or the analysis finished: the tries count anew.
    public mutating func reset() {
        tries = 0
        due = nil
    }

    /// A plan's claim ended while the analysis is left to go on: whether it starts now. Not
    /// while a try still waits (its own task starts it when it is due).
    public func startsOnRelease(now: ContinuousClock.Instant) -> Bool {
        guard let due else { return true }
        return due <= now
    }
}

extension AnalysisRunEnd {
    /// The analysis stands paused by the user after this end: kept across launches
    /// (`AppModel`), so the overnight refinement, for which iOS often starts the app in the
    /// night without its screen, leaves it paused (app-speed 18.11.2026, open point C of the
    /// labels fix). Before, a refinement started after a Pause went on with the analysis.
    /// Also when Pause was tapped and the run ended unfinished for another reason (`pauseHeld`).
    public var keepsPause: Bool { report?.pausedBecause == .userPaused || pauseHeld }
}
