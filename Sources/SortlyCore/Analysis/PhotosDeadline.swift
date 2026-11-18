import Foundation

/// Photos (PhotoKit) did not answer in the time Albumist waits for it (app-speed, 18.11.2026).
///
/// What it means depends on the kind of call (`docs/DECISIONS.md`):
/// - a read: nothing was read; the run ends early and goes on a little later, never "fertig";
/// - a write: the outcome is not known. Photos may still carry the change out later, so it is
///   neither done nor undone: the plan stops at that step as if the app had been closed while
///   the request was on its way (the step stays journaled with its intent), and the ways out of
///   an interrupted plan settle it from what the library shows later.
public struct PhotosNotResponding: Error, Sendable, Equatable {
    public var lane: PhotosDeadline.Lane
    /// The call, for the diagnostic report ("createAlbum", "fetchAssets").
    public var what: String
    /// The call was never sent: an earlier call of the same kind still had no answer.
    public var notSent: Bool

    public init(lane: PhotosDeadline.Lane, what: String, notSent: Bool) {
        self.lane = lane
        self.what = what
        self.notSent = notSent
    }
}

/// Bounded waits for calls into Photos that may never return (assetsd or photolibraryd stuck):
/// before, a fetch or a change request without an answer froze the analysis or the plan for
/// good, with the card standing still.
///
/// - Every call gets a limit; a long read gets it as a limit without any sign of progress
///   (`Heartbeat`), so reading 50,000 photos is not cut off while it moves. The limit counts
///   from when the call starts running and is watched on a Dispatch timer, so a busy thread
///   pool neither delays it nor cuts off a call that has not started.
/// - After the limit the caller gets `PhotosNotResponding` and goes on. The call itself cannot
///   be taken back from Photos: it goes on in the background and its answer is dropped.
/// - While such a call still hangs, no new call of the same kind is sent (`Lane`): a new one
///   waits up to its own limit for the old one and then fails without being sent. So there is
///   never a second write while an earlier one may still land (a second album next to a late
///   first one), and a stuck Photos does not collect one stuck thread per retry.
/// - A call cancelled by its caller that has not returned counts as hanging the same way.
/// - `slowFor`: how long the oldest call has gone without an answer (or a sign of progress),
///   once that is `slowAfter` or more, for the honest "Fotos antwortet gerade nicht" on screen
///   while Albumist still waits (owner limit: nothing stands still for more than 10 s).
public final class PhotosDeadline: @unchecked Sendable {
    public enum Lane: String, Sendable, Equatable {
        case read, write
    }

    /// A long call says it is still moving (a read every 250 photos): its limit counts from
    /// the last beat.
    public final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var last: ContinuousClock.Instant
        private var began = false

        init(_ now: ContinuousClock.Instant) { last = now }

        public func beat() {
            let now = ContinuousClock.now
            lock.withLock { last = now }
        }

        /// The call starts running: its limit counts from here. A call whose task has not got a
        /// thread yet (the analysis keeps them all busy) is not cut off for Photos' sake.
        func begin() {
            let now = ContinuousClock.now
            lock.withLock { last = now; began = true }
        }

        var lastBeat: ContinuousClock.Instant { lock.withLock { last } }
        /// The last beat, once the call has started running.
        var quietSince: ContinuousClock.Instant? { lock.withLock { began ? last : nil } }
    }

    private struct Call {
        var lane: Lane
        var heartbeat: Heartbeat
        var reportsSlow: Bool
    }

    private let lock = NSLock()
    private var calls: [UUID: Call] = [:]
    /// Calls past their limit (or cancelled by their caller) that have not returned yet.
    private var hanging: [Lane: Int] = [:]
    public let slowAfter: Duration

    public init(slowAfter: Duration = .seconds(10)) {
        self.slowAfter = slowAfter
    }

    /// Calls of this kind that went past their limit and still have not returned.
    public func hangingCalls(_ lane: Lane) -> Int { lock.withLock { hanging[lane] ?? 0 } }

    /// How long the oldest waiting call has gone without an answer or a beat, when that is
    /// `slowAfter` or more. Calls that wait for the user (`reportsSlow: false`) do not count.
    public func slowFor(now: ContinuousClock.Instant = .now) -> Duration? {
        let longest = lock.withLock {
            calls.values.filter(\.reportsSlow).map { now - $0.heartbeat.lastBeat }.max()
        }
        guard let longest, longest >= slowAfter else { return nil }
        return longest
    }

    /// Runs `work` and returns its answer, or throws `PhotosNotResponding` once `limit` passed
    /// without an answer (counted from the last `Heartbeat.beat()`). `reportsSlow: false` for a
    /// call that waits for the user (the question iOS asks before albums are deleted).
    public func run<T: Sendable>(_ what: String, lane: Lane, limit: Duration, reportsSlow: Bool = true,
                                 _ work: @escaping @Sendable (Heartbeat) async throws -> T) async throws -> T {
        let id = UUID()
        let heartbeat = Heartbeat(.now)
        lock.withLock { calls[id] = Call(lane: lane, heartbeat: heartbeat, reportsSlow: reportsSlow) }
        // An earlier call of this kind still hangs: wait for it, but never send a second one.
        let clear = await waitForLane(lane, limit: limit)
        guard clear else {
            lock.withLock { calls[id] = nil }
            if Task.isCancelled { throw CancellationError() }
            throw PhotosNotResponding(lane: lane, what: what, notSent: true)
        }
        heartbeat.beat()
        let answer = Answer<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                answer.set(continuation)
                // Not sent at all when the caller was cancelled before this point.
                let started = answer.start {
                    Task.detached {
                        let result: Result<T, any Error>
                        heartbeat.begin()
                        do { result = .success(try await work(heartbeat)) } catch { result = .failure(error) }
                        self.returned(id, lane: lane, answer: answer, result: result)
                    }
                }
                guard started else {
                    lock.withLock { calls[id] = nil }
                    return
                }
                watch(id, lane: lane, what: what, limit: limit, heartbeat: heartbeat, answer: answer)
            }
        } onCancel: {
            self.giveUp(id, lane: lane, answer: answer, error: CancellationError())
        }
    }

    /// How often the limit is checked: a quarter of it, at most every second.
    private static func check(_ limit: Duration) -> Duration { min(limit / 4, .seconds(1)) }

    /// The limit is watched on a Dispatch timer, not in a task: when the analysis keeps every
    /// thread of Swift's shared pool busy, a sleeping task wakes late and the limit with it.
    private static let timers = DispatchQueue(label: "PhotosDeadline.timers")

    private func watch<T>(_ id: UUID, lane: Lane, what: String, limit: Duration, heartbeat: Heartbeat, answer: Answer<T>) {
        guard !answer.isDone else { return }
        // Not running yet: looked at again later.
        let quiet = heartbeat.quietSince.map { ContinuousClock.now - $0 } ?? .zero
        if quiet >= limit {
            giveUp(id, lane: lane, answer: answer, error: PhotosNotResponding(lane: lane, what: what, notSent: false))
            return
        }
        let wait = min(limit - quiet, Self.check(limit))
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        Self.timers.asyncAfter(deadline: .now() + seconds) {
            self.watch(id, lane: lane, what: what, limit: limit, heartbeat: heartbeat, answer: answer)
        }
    }

    /// Waits until no call of this kind hangs, up to `limit`. False if one still does (or the
    /// caller was cancelled meanwhile).
    private func waitForLane(_ lane: Lane, limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while hangingCalls(lane) > 0 {
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: min(.milliseconds(100), Self.check(limit)))
        }
        return true
    }

    /// The call returned: its answer goes to the caller if it still waits; a call given up
    /// before no longer hangs.
    private func returned<T>(_ id: UUID, lane: Lane, answer: Answer<T>, result: Result<T, any Error>) {
        let deliver = lock.withLock { () -> Bool in
            calls[id] = nil
            if answer.complete() { return true }
            hanging[lane, default: 1] -= 1
            return false
        }
        if deliver { answer.deliver(result) }
    }

    /// The caller stops waiting (limit passed, or cancelled): it gets `error`, and a call that
    /// was sent counts as hanging until it returns.
    private func giveUp<T>(_ id: UUID, lane: Lane, answer: Answer<T>, error: any Error) {
        let first = lock.withLock { () -> Bool in
            let (first, sent) = answer.giveUp()
            guard first else { return false }
            calls[id] = nil
            if sent { hanging[lane, default: 0] += 1 }
            return true
        }
        guard first else { return }
        answer.cancelWorker()
        answer.deliver(.failure(error))
    }
}

/// The caller's continuation, resumed exactly once: by the answer (`complete`) or by giving up
/// (`giveUp`), whichever comes first; only that one delivers.
private final class Answer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var early: Result<T, any Error>?
    private var worker: Task<Void, Never>?
    private var finished = false

    var isDone: Bool { lock.withLock { finished } }

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = lock.withLock {
            if let early { self.early = nil; return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    /// Starts the call unless the caller gave up already; atomic with `giveUp`, so a call is
    /// either never sent or counted as sent.
    func start(_ make: () -> Task<Void, Never>) -> Bool {
        lock.withLock {
            guard !finished else { return false }
            worker = make()
            return true
        }
    }

    /// The call answered: true if the caller still waits for it (it is delivered then).
    func complete() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    /// The caller stops waiting: `first` unless the call answered or was given up already;
    /// `sent` when the call was started.
    func giveUp() -> (first: Bool, sent: Bool) {
        lock.withLock {
            guard !finished else { return (false, worker != nil) }
            finished = true
            return (true, worker != nil)
        }
    }

    func cancelWorker() {
        let task = lock.withLock { worker }
        task?.cancel()
    }

    func deliver(_ result: Result<T, any Error>) {
        let pending: CheckedContinuation<T, any Error>? = lock.withLock {
            guard let continuation else {
                // Given up before the continuation was stored: kept for `set`.
                early = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        pending?.resume(with: result)
    }
}
