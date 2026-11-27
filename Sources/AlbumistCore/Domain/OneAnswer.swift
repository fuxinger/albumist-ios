import Foundation

/// The one answer of a request that answers from another thread, for an async caller: the
/// photo view's PhotoKit requests (its Live Photo, its share check and its share, design wave
/// 2, DS-10), which call back on Photos' own threads. Whatever comes first counts: the request's
/// answer (`finish`), the caller going away (`cancel`, a swipe to the next photo) or the time
/// running out (`limit`); a later one changes nothing, and the request is stopped when the
/// answer came another way. A second resume of the caller would crash the app, a missing one
/// would leave the page waiting for good, hence the lock.
///
/// Generic over the request's id, so the rules are tested here and not only on an iPhone
/// (review D, L9); the app says how each kind of PhotoKit request is stopped (`PhotoKitAnswer`).
///
/// Nothing is kept once it is over (review D2, N2): the answer goes to the caller and is not
/// stored (only one that comes before the caller waits, until the caller has it), and the time
/// limit ends with the answer. Before, every Live Photo loaded stayed in memory until its 15 s
/// limit was up, about fifteen at once while the user swiped through a burst.
public final class OneAnswer<Value: Sendable, Request: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallback: Value
    private let stopRequest: @Sendable (Request) -> Void
    private var continuation: CheckedContinuation<Value, Never>?
    private var request: Request?
    /// The request's answer when it came before the caller waited: handed over in `begin`, then
    /// gone.
    private var early: Value?
    /// Answered, given up or cancelled: nothing more is waited for.
    private var over = false
    /// The time limit while it runs (`limit`); it ends with the answer. Internal for the tests.
    private(set) var limitTask: Task<Void, Never>?

    /// - Parameters:
    ///   - fallback: The answer when the caller goes away or the time runs out.
    ///   - stopRequest: Stops the request (`PHImageManager.cancelImageRequest`, …).
    public init(fallback: Value, stopRequest: @escaping @Sendable (Request) -> Void) {
        self.fallback = fallback
        self.stopRequest = stopRequest
    }

    /// Takes the caller's continuation. False when the answer is in already (the caller was
    /// cancelled, or the time ran out, before the request could begin): then the caller is
    /// answered here and no request is to be made.
    public func begin(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        let (waits, given): (Bool, Value) = lock.withLock {
            if over {
                let given = early ?? fallback
                early = nil
                return (false, given)
            }
            self.continuation = continuation
            return (true, fallback)
        }
        if !waits { continuation.resume(returning: given) }
        return waits
    }

    /// The request that was made; stopped at once when the answer was given up meanwhile.
    public func started(_ request: Request) {
        let late: Bool = lock.withLock {
            self.request = request
            return over
        }
        if late { stopRequest(request) }
    }

    /// The request's answer; one after the first changes nothing. `stop`: the request is
    /// stopped as well, because what came is enough (the first bytes of a file). True when this
    /// was the answer.
    @discardableResult
    public func finish(_ value: Value, stop: Bool = false) -> Bool {
        let (first, ending): (Bool, Ending) = lock.withLock {
            guard !over else { return (false, Ending()) }
            over = true
            let ending = Ending(waiting: continuation, running: stop ? request : nil, limit: limitTask)
            continuation = nil
            limitTask = nil
            // Kept only for a caller that has not begun to wait yet.
            if ending.waiting == nil { early = value }
            return (true, ending)
        }
        ending.end(answering: value, stopRequest: stopRequest)
        return first
    }

    /// The caller went away, or the time ran out: the fallback, and the request stops. After
    /// the answer nothing happens.
    public func cancel() {
        let ending: Ending = lock.withLock {
            guard !over else { return Ending() }
            over = true
            let ending = Ending(waiting: continuation, running: request, limit: limitTask)
            continuation = nil
            limitTask = nil
            return ending
        }
        ending.end(answering: fallback, stopRequest: stopRequest)
    }

    /// Gives up after `duration` (`cancel`): Photos may never answer while it is busy. A second
    /// limit replaces the first; after the answer none is set. The waiting task holds this
    /// object only weakly and ends with the answer.
    public func limit(_ duration: Duration) {
        let replaced: Task<Void, Never>? = lock.withLock {
            guard !over else { return nil }
            let before = limitTask
            limitTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                self?.cancel()
            }
            return before
        }
        replaced?.cancel()
    }

    /// What is left to do once it is over, outside the lock: the time limit ends, the caller
    /// gets its answer, the request stops. Empty when it was over already.
    private struct Ending {
        var waiting: CheckedContinuation<Value, Never>?
        var running: Request?
        var limit: Task<Void, Never>?

        func end(answering value: Value, stopRequest: (Request) -> Void) {
            limit?.cancel()
            waiting?.resume(returning: value)
            if let running { stopRequest(running) }
        }
    }

    deinit {
        limitTask?.cancel()
    }
}
