import Foundation

/// The progress Albumist reports to iOS for an analysis that goes on after the user leaves the
/// app (continued processing: bar on the Lock Screen and in the Dynamic Island).
///
/// iOS treats a task whose progress stops moving as unresponsive: it ends the task and shows
/// "Vorgang fehlgeschlagen" (device test 15.11.; Apple's guidance is to report progress, also
/// artificially, instead of letting the task expire). So the bar follows the real progress,
/// and while one slow photo, a place lookup or a break for heat or battery takes long, it
/// still moves by one unit every `heartbeat` seconds. It only moves forward, and it is full
/// only when the task is finished.
public struct ContinuedTaskHeartbeat: Sendable, Equatable {
    /// Units of the whole bar. Fine enough that the heartbeat is invisible (one unit is
    /// 0.01 %), and iOS counts only whole units as movement.
    public static let units: Int64 = 10_000
    /// The longest time the reported progress stands still while the analysis runs.
    public static let heartbeat: TimeInterval = 10
    /// The analysis has not been running for this long: the task ends (finished, paused by
    /// the user, or a short gap a new run does not fill).
    public static let idleLimit: TimeInterval = 4

    public enum Step: Equatable, Sendable {
        /// Report this many completed units.
        case report(Int64)
        /// The analysis is no longer running: complete the task as done.
        case finish
    }

    public private(set) var reported: Int64 = 0
    private var lastMove: Date
    private var idleSince: Date?

    public init(start: Date) {
        lastMove = start
    }

    /// Called about once a second with the analysis as it is now. `fraction`: overall
    /// progress of the run, 0...1.
    public mutating func step(now: Date, running: Bool, fraction: Double) -> Step {
        guard running else {
            let since = idleSince ?? now
            idleSince = since
            return now.timeIntervalSince(since) >= Self.idleLimit ? .finish : .report(reported)
        }
        idleSince = nil
        // Never full while the run is busy: a full bar reads as done.
        let cap = Self.units - 1
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let real = min(cap, Int64((clamped * Double(Self.units)).rounded(.down)))
        if real > reported {
            reported = real
            lastMove = now
        } else if now.timeIntervalSince(lastMove) >= Self.heartbeat, reported < cap {
            reported += 1
            lastMove = now
        }
        return .report(reported)
    }
}
