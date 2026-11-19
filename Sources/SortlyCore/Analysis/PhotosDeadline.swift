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
    /// The call was never sent: an earlier call of the same kind still had no answer, or the
    /// call never began (`neverBegan`).
    public var notSent: Bool
    /// The call waited for the user: iOS asks before albums are deleted, and that question may
    /// still be on screen (its own words, second review of the PhotoKit limits, 7).
    public var asksUser: Bool
    /// The call never began: Albumist's own work kept every thread busy past the call's limit
    /// and grace, so it was given up before it reached Photos, and it never runs later. Nothing
    /// was asked of Photos and nothing hangs; trying again is safe (second review of 6c45378, P1).
    /// Always with `notSent`. Only a call given up at its limit says this; a caller cancelled
    /// before its call began gets `CancellationError` (that call never runs either).
    public var neverBegan: Bool
    /// Reported by a library call before it sent any change (a read it makes first, such as
    /// the check that the album is still there): whatever happened to that read, nothing of
    /// the call reached Photos as a change (`beforeAnyChange`, review of f7439fb, SF1).
    public var noChangeSent: Bool

    public init(lane: PhotosDeadline.Lane, what: String, notSent: Bool, asksUser: Bool = false, neverBegan: Bool = false,
                noChangeSent: Bool = false) {
        self.lane = lane
        self.what = what
        self.notSent = notSent || neverBegan
        self.asksUser = asksUser
        self.neverBegan = neverBegan
        self.noChangeSent = noChangeSent
    }
}

extension PhotosNotResponding {
    /// The same, reported by a library call before it sent any change (a read it makes
    /// first): the executor leaves the step as it was (`noChangeSent`).
    public var beforeAnyChange: PhotosNotResponding {
        var quiet = self
        quiet.noChangeSent = true
        return quiet
    }

    /// The library call that reported this sent no change, as far as it can say: a change
    /// request never sent, or anything before the call's first change (`beforeAnyChange`).
    public var reachedPhotosWithNoChange: Bool { noChangeSent || (notSent && lane == .write) }

    /// The same, reported by a library call after a change of that call had already been sent
    /// (`PhotoKitLibrary.deleteCollections` reads back and may ask once more): the call as a
    /// whole is a write whose outcome is not known, never "not sent", whatever the later call
    /// was (a read-back that got no thread says nothing about the change before it; review of
    /// 045f297, M2). The question iOS asks may only still be open if this was that change
    /// itself, without an answer.
    public var afterAChangeWasSent: PhotosNotResponding {
        PhotosNotResponding(lane: .write, what: what, notSent: false, asksUser: lane == .write && !notSent && asksUser)
    }
}

/// Bounded waits for calls into Photos that may never return (assetsd or photolibraryd stuck):
/// before, a fetch or a change request without an answer froze the analysis or the plan for
/// good, with the card standing still.
///
/// - Every call gets a limit; a long read gets it as a limit without any sign of progress
///   (`Heartbeat`), so reading 50,000 photos is not cut off while it moves. The limit counts
///   from when the call starts running and is watched on a Dispatch timer, so a busy thread
///   pool neither delays it nor cuts off a call that has not started. A call that still has no
///   thread after its limit plus `notBegunGrace` is given up and never runs later: it was not
///   sent, does not hang, and says so (`PhotosNotResponding.neverBegan`).
/// - After the limit the caller gets `PhotosNotResponding` and goes on. The call itself cannot
///   be taken back from Photos: it goes on in the background and its answer is dropped.
/// - While such a call still hangs, no new call of the same kind is sent (`Lane`). A write fails
///   at once without being sent: it was decided from a library that the hanging write may still
///   change, so it is never sent after waiting for it (second review: a create that landed during
///   the wait was followed by a second album). A read or an image request waits up to its own
///   limit for the old one and then fails without being sent. A stuck Photos does not collect
///   one stuck thread per retry.
/// - Synchronous PhotoKit work runs on queues of its own (`runBlocking`, by the caller's priority),
///   not on Swift's shared pool, so a hanging fetch never holds a thread the analysis needs. It
///   has no task to cancel: a long read checks `Heartbeat.isCancelled` and stops once nobody
///   waits for it.
/// - A look at a call that comes much later than planned means the app was suspended: the call
///   gets its limit again from then (`cameBack` does the same when the app is on screen again),
///   so time the app did not run in never cuts a call off.
/// - A call cancelled by its caller that began and has not returned counts as hanging the same
///   way; one that had not begun never runs.
/// - `slowFor`: how long the oldest waiting call has gone without an answer (or a sign of
///   progress), once that is `slowAfter` or more (a call handed to the pool that still waits
///   for a thread waits for Albumist, not for Photos; one waiting for its lane waits for Photos
///   and counts), for the honest "Fotos antwortet gerade nicht" on screen
///   while Albumist still waits (owner limit: nothing stands still for more than 10 s).
public final class PhotosDeadline: @unchecked Sendable {
    public enum Lane: String, Sendable, Equatable {
        /// Fetches for the analysis's lists, plans and the overview.
        case read
        /// Change requests.
        case write
        /// One photo's fetch or image for the analysis, the grid, the atlas: apart from the
        /// reads, so a photo that hangs never holds up a plan's reads.
        case image
        /// Pictures on screen: the grid's thumbnails and the atlas cover. Apart from the
        /// analysis's photos, so a thumbnail that hangs never stops a run (third review, N6).
        case thumbnail
    }

    /// A long call says it is still moving (a read every 250 photos): its limit counts from
    /// the last beat.
    public final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var last: ContinuousClock.Instant
        private var began = false
        private var stopped = false
        /// Its task was handed to the pool (`run`): until it begins, it waits for a thread, that
        /// is for Albumist's own work, not for Photos.
        private var queued = false

        init(_ now: ContinuousClock.Instant) { last = now }

        /// The caller stopped waiting (limit passed, or it was cancelled). Work run on a queue
        /// (`runBlocking`) has no task to be cancelled: a long read checks this instead, so a
        /// read nobody waits for no longer keeps its lane busy for minutes (third review, N1).
        public var isCancelled: Bool { lock.withLock { stopped } }

        /// Stops the call: true if it had begun. Atomic with `begin`: a call stopped before it
        /// began never begins, so it was never sent to Photos.
        func stop() -> Bool { lock.withLock { stopped = true; return began } }

        public func beat() {
            let now = ContinuousClock.now
            lock.withLock { last = now }
        }

        /// The call starts running: its limit counts from here. A call whose task has not got a
        /// thread yet (the analysis keeps them all busy) is not cut off for Photos' sake.
        /// False when the call was given up before it got a thread: it must not run then.
        func begin() -> Bool {
            let now = ContinuousClock.now
            return lock.withLock {
                guard !stopped else { return false }
                last = now
                began = true
                return true
            }
        }

        /// The call's task is handed to the pool.
        func handedOver() { lock.withLock { queued = true } }

        /// One look under one lock: the last beat, whether the call began running, and whether
        /// its task was handed to the pool (review of 045f297, S2: two separate reads could see
        /// a beat from before `begin` with "running").
        var state: (last: ContinuousClock.Instant, began: Bool, queued: Bool) { lock.withLock { (last, began, queued) } }
    }

    /// How the watch goes on after one look at a call.
    enum Look: Equatable {
        /// The limit passed without an answer or a beat.
        case giveUp
        /// The look came much later than planned (the app was suspended): the call gets its
        /// limit again from now.
        case cameBack
        /// Looked at again after this long.
        case again(Duration)
    }

    /// A look later than planned by this much means the app was suspended (a Dispatch timer does
    /// not run while it is; `ContinuousClock` does).
    static let suspendedAfter: Duration = .seconds(2)

    /// A call whose task has not got a thread yet waits this much longer than its limit before
    /// it is given up: it is never kept for good, and a busy moment of the thread pool (seconds
    /// in the full test run) does not cut off a call Photos was never asked.
    static let notBegunGrace: Duration = .seconds(60)

    /// One look at a call: `quiet` since its last beat (for a call not running yet, beyond
    /// `notBegunGrace`), `late` how much later than planned this look came.
    static func quiet(now: ContinuousClock.Instant, lastBeat: ContinuousClock.Instant, running: Bool,
                      grace: Duration) -> Duration {
        // Not running yet (its task has no thread): only its wait beyond the grace counts.
        running ? now - lastBeat : max(.zero, now - lastBeat - grace)
    }

    /// Late looks in a row that give the call its limit again; after these the limit decides
    /// (a timer that is always late is not a suspension, third review, N5).
    static let maxCameBack = 3

    /// `cameBack`: late looks in a row that already gave the call its limit again.
    static func look(quiet: Duration, limit: Duration, late: Duration, cameBack: Int = 0) -> Look {
        if late >= suspendedAfter, cameBack < maxCameBack { return .cameBack }
        if quiet >= limit { return .giveUp }
        return .again(min(limit - quiet, check(limit)))
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
    /// `notBegunGrace` for this instance. The tests give it more: in the full parallel test run
    /// Swift's shared pool was busy for 78 s (CI 44380367650 on Linux, even trivial tests took
    /// that long), and calls that never got a thread were given up after 60 s + their limit.
    let grace: Duration
    /// Tests only: awaited by a call's task before it begins, to hold a call that has no thread.
    private let startGate: (@Sendable () async -> Void)?
    /// Tests only: hears what `Heartbeat.begin` returned for each call's task, so a test knows
    /// for certain that a call given up first did not run (instead of waiting a while).
    private let begun: (@Sendable (Bool) -> Void)?

    public convenience init(slowAfter: Duration = .seconds(10)) {
        self.init(slowAfter: slowAfter, notBegunGrace: Self.notBegunGrace)
    }

    init(slowAfter: Duration = .seconds(10), notBegunGrace: Duration, startGate: (@Sendable () async -> Void)? = nil,
         begun: (@Sendable (Bool) -> Void)? = nil) {
        self.slowAfter = slowAfter
        self.grace = notBegunGrace
        self.startGate = startGate
        self.begun = begun
    }

    /// Calls of this kind that went past their limit and still have not returned.
    public func hangingCalls(_ lane: Lane) -> Int { lock.withLock { hanging[lane] ?? 0 } }

    /// The app is on screen again: every call waiting gets its limit again from now. While the
    /// app was suspended, Photos could not answer it.
    public func cameBack() {
        let waiting = lock.withLock { calls.values.map(\.heartbeat) }
        for heartbeat in waiting { heartbeat.beat() }
    }

    /// How long the oldest waiting call has gone without an answer or a beat, when that is
    /// `slowAfter` or more. Calls that wait for the user (`reportsSlow: false`) do not count, nor
    /// do calls whose task was handed to the pool and has no thread yet. A call that waits for
    /// its lane (an earlier one hangs) counts: it waits for Photos.
    public func slowFor(now: ContinuousClock.Instant = .now) -> Duration? {
        let longest = lock.withLock {
            calls.values.filter(\.reportsSlow).compactMap { call -> Duration? in
                let state = call.heartbeat.state
                // Waiting for a thread: for Albumist's own work, not for Photos (second review of
                // 6c45378, P2). Not a call waiting for its lane (review of 045f297, M1).
                if state.queued && !state.began { return nil }
                return now - state.last
            }.max()
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
        // An earlier call of this kind still hangs: never send a second one. A write is not
        // waited for (see above); a read waits for it up to its limit.
        let clear = lane == .write ? hangingCalls(.write) == 0 : await waitForLane(lane, limit: limit)
        guard clear else {
            lock.withLock { calls[id] = nil }
            if Task.isCancelled { throw CancellationError() }
            throw PhotosNotResponding(lane: lane, what: what, notSent: true, asksUser: !reportsSlow)
        }
        heartbeat.beat()
        let answer = Answer<T>()
        // The call runs with the caller's priority (a detached task would drop it).
        let priority = Task.currentPriority
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                answer.set(continuation)
                let gate = startGate
                let begun = begun
                // Not sent at all when the caller was cancelled before this point.
                let started = answer.start {
                    heartbeat.handedOver()
                    return Task.detached(priority: priority) {
                        if let gate { await gate() }
                        // Given up before it got a thread: never sent, never run (second review
                        // of 6c45378, P1). `giveUp` did not count it as hanging.
                        let running = heartbeat.begin()
                        begun?(running)
                        guard running else { return }
                        let result: Result<T, any Error>
                        do { result = .success(try await work(heartbeat)) } catch { result = .failure(error) }
                        self.returned(id, lane: lane, answer: answer, result: result)
                    }
                }
                guard started else {
                    lock.withLock { calls[id] = nil }
                    return
                }
                watch(id, lane: lane, what: what, limit: limit, asksUser: !reportsSlow, heartbeat: heartbeat, answer: answer,
                      planned: nil, cameBack: 0)
            }
        } onCancel: {
            self.giveUp(id, lane: lane, answer: answer, heartbeat: heartbeat, error: CancellationError())
        }
    }

    /// How often the limit is checked: a quarter of it, at most every second.
    private static func check(_ limit: Duration) -> Duration { min(limit / 4, .seconds(1)) }

    /// The limit is watched on a Dispatch timer, not in a task: when the analysis keeps every
    /// thread of Swift's shared pool busy, a sleeping task wakes late and the limit with it.
    private static let timers = DispatchQueue(label: "PhotosDeadline.timers")

    private func watch<T>(_ id: UUID, lane: Lane, what: String, limit: Duration, asksUser: Bool, heartbeat: Heartbeat,
                          answer: Answer<T>, planned: ContinuousClock.Instant?, cameBack: Int) {
        guard !answer.isDone else { return }
        let now = ContinuousClock.now
        let state = heartbeat.state
        let quiet = Self.quiet(now: now, lastBeat: state.last, running: state.began, grace: grace)
        let late = planned.map { max(.zero, now - $0) } ?? .zero
        let wait: Duration
        var inARow = 0
        switch Self.look(quiet: quiet, limit: limit, late: late, cameBack: cameBack) {
        case .giveUp:
            giveUp(id, lane: lane, answer: answer, heartbeat: heartbeat,
                   error: PhotosNotResponding(lane: lane, what: what, notSent: false, asksUser: asksUser))
            return
        case .cameBack:
            heartbeat.beat()
            inARow = cameBack + 1
            wait = Self.check(limit)
        case .again(let next):
            wait = next
        }
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        let next = now + wait
        let inARowNow = inARow
        Self.timers.asyncAfter(deadline: .now() + seconds) {
            self.watch(id, lane: lane, what: what, limit: limit, asksUser: asksUser, heartbeat: heartbeat, answer: answer,
                       planned: next, cameBack: inARowNow)
        }
    }

    /// Like `run`, for synchronous PhotoKit work (fetches): it runs on a queue of its own, so a
    /// fetch that hangs holds one of that queue's threads, never one of Swift's shared pool.
    public func runBlocking<T: Sendable>(_ what: String, lane: Lane, limit: Duration, reportsSlow: Bool = true,
                                         _ work: @escaping @Sendable (Heartbeat) throws -> T) async throws -> T {
        // The queue of the caller's priority: a background read of the analysis does not run
        // at the priority of what the user waits for (third review, N4).
        let queue = Self.queue(for: Task.currentPriority)
        return try await run(what, lane: lane, limit: limit, reportsSlow: reportsSlow) { beat in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async { continuation.resume(with: Result { try work(beat) }) }
            }
        }
    }

    /// What the user waits for (`.medium` and above) and what runs on its own.
    private static let photoKitUser = DispatchQueue(label: "PhotosDeadline.photoKit.user", qos: .userInitiated, attributes: .concurrent)
    private static let photoKitUtility = DispatchQueue(label: "PhotosDeadline.photoKit.utility", qos: .utility, attributes: .concurrent)

    static func queue(for priority: TaskPriority) -> DispatchQueue {
        priority >= .medium ? photoKitUser : photoKitUtility
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
    /// began running counts as hanging until it returns. A call whose task has not begun is
    /// stopped here, atomically with `Heartbeat.begin`: it never runs, so it was never sent
    /// and does not hang, and a `PhotosNotResponding` says so (`notSent`, `neverBegan`). Before,
    /// such a call counted as hanging and still ran later: a change request carried out after
    /// its plan had stopped with "outcome unknown" (second review of 6c45378, P1).
    private func giveUp<T>(_ id: UUID, lane: Lane, answer: Answer<T>, heartbeat: Heartbeat, error: any Error) {
        let outcome = lock.withLock { () -> (first: Bool, began: Bool) in
            guard answer.giveUp() else { return (false, false) }
            calls[id] = nil
            // True only once the call's task began running (a task never started has not).
            let began = heartbeat.stop()
            if began { hanging[lane, default: 0] += 1 }
            return (true, began)
        }
        guard outcome.first else { return }
        answer.cancelWorker()
        var error = error
        if !outcome.began, let late = error as? PhotosNotResponding {
            error = PhotosNotResponding(lane: late.lane, what: late.what, notSent: true, asksUser: late.asksUser,
                                        neverBegan: true)
        }
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

    /// Starts the call's task unless the caller gave up already; atomic with `giveUp`, so a
    /// call given up first never gets a task.
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

    /// The caller stops waiting: true unless the call answered or was given up already. Whether
    /// the call reached Photos is the heartbeat's to say (`Heartbeat.stop`): a started task may
    /// not have begun yet.
    func giveUp() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
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
