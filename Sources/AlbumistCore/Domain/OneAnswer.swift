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
public final class OneAnswer<Value: Sendable, Request: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallback: Value
    private let stopRequest: @Sendable (Request) -> Void
    private var continuation: CheckedContinuation<Value, Never>?
    private var request: Request?
    /// The request's answer once it came: a caller that begins late gets it.
    private var answer: Value?
    /// Answered, given up or cancelled: nothing more is waited for.
    private var over = false

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
            if over { return (false, answer ?? fallback) }
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
        let (first, waiting, running): (Bool, CheckedContinuation<Value, Never>?, Request?) = lock.withLock {
            guard !over else { return (false, nil, nil) }
            over = true
            answer = value
            defer { continuation = nil }
            return (true, continuation, stop ? request : nil)
        }
        waiting?.resume(returning: value)
        if let running { stopRequest(running) }
        return first
    }

    /// The caller went away, or the time ran out: the fallback, and the request stops. After
    /// the answer nothing happens.
    public func cancel() {
        let (waiting, running): (CheckedContinuation<Value, Never>?, Request?) = lock.withLock {
            guard !over else { return (nil, nil) }
            over = true
            defer { continuation = nil }
            return (continuation, request)
        }
        waiting?.resume(returning: fallback)
        if let running { stopRequest(running) }
    }

    /// Gives up after `duration` (`cancel`): Photos may never answer while it is busy.
    public func limit(_ duration: Duration) {
        Task { [self] in
            try? await Task.sleep(for: duration)
            cancel()
        }
    }
}
