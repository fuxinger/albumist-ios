import Foundation
import Testing
@testable import AlbumistCore

/// The one answer of a request that answers from another thread (the photo view's PhotoKit
/// requests: its Live Photo, its share check and its share): whatever comes first counts, the
/// request's answer, the caller going away or the time running out; later ones change nothing,
/// and the request is stopped when the answer came another way. A second resume would crash
/// the app, a missing one would leave the page waiting for good (review D, L9).
@Suite("Photo view: one answer per request")
struct OneAnswerTests {
    /// The requests that were stopped.
    final class Stopped: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int32] = []

        func add(_ id: Int32) { lock.withLock { ids.append(id) } }
        var all: [Int32] { lock.withLock { ids } }
    }

    static func answer(_ stopped: Stopped) -> OneAnswer<String, Int32> {
        OneAnswer(fallback: "none") { stopped.add($0) }
    }

    /// The request's first answer is the caller's; a second one is ignored, and a cancel after
    /// the answer stops nothing.
    @Test func theFirstAnswerCounts() async {
        let stopped = Stopped()
        let answer = Self.answer(stopped)
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard answer.begin(continuation) else { return }
            answer.started(7)
            #expect(answer.finish("photo"))
            #expect(!answer.finish("later"))
        }
        #expect(value == "photo")
        answer.cancel()
        #expect(stopped.all.isEmpty)
    }

    /// The caller goes away (a swipe to the next photo): the fallback at once, and the request
    /// stops; its late answer changes nothing.
    @Test func aCancelGivesTheFallbackAndStopsTheRequest() async {
        let stopped = Stopped()
        let answer = Self.answer(stopped)
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard answer.begin(continuation) else { return }
            answer.started(7)
            answer.cancel()
        }
        #expect(value == "none")
        #expect(stopped.all == [7])
        #expect(!answer.finish("late"))
        #expect(stopped.all == [7])
    }

    /// Cancelled before the request could begin: the caller has the fallback and no request is
    /// made; one that starts anyway is stopped at once.
    @Test func aCancelBeforeTheRequest() async {
        let stopped = Stopped()
        let answer = Self.answer(stopped)
        answer.cancel()
        var began = true
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            began = answer.begin(continuation)
        }
        #expect(value == "none")
        #expect(!began)
        answer.started(9)
        #expect(stopped.all == [9])
    }

    /// A request that says its id only after the caller went away is stopped then.
    @Test func aRequestThatStartsLateIsStopped() async {
        let stopped = Stopped()
        let answer = Self.answer(stopped)
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard answer.begin(continuation) else { return }
            answer.cancel()
            answer.started(4)
        }
        #expect(value == "none")
        #expect(stopped.all == [4])
    }

    /// Photos may never answer for a photo it is busy with: the time limit gives the fallback
    /// and stops the request.
    @Test func theTimeLimitGivesTheFallback() async {
        let stopped = Stopped()
        let answer = Self.answer(stopped)
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard answer.begin(continuation) else { return }
            answer.started(3)
            answer.limit(.milliseconds(20))
        }
        #expect(value == "none")
        #expect(stopped.all == [3])
    }

    /// The first bytes of a file are the answer: it is given and the reading stops; the
    /// request's own end afterwards changes nothing.
    @Test func anAnswerCanStopTheRequest() async {
        let stopped = Stopped()
        let answer = Self.answer(stopped)
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard answer.begin(continuation) else { return }
            answer.started(5)
            #expect(answer.finish("on the iPhone", stop: true))
            #expect(!answer.finish("cancelled"))
        }
        #expect(value == "on the iPhone")
        #expect(stopped.all == [5])
    }

    /// An answer before the caller waits (a request that answers at once) is kept for it.
    @Test func anEarlyAnswerIsKept() async {
        let answer = Self.answer(Stopped())
        answer.finish("early")
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            _ = answer.begin(continuation)
        }
        #expect(value == "early")
    }

    /// Answers, cancels and the time limit from many threads at once: the caller is answered
    /// exactly once (a second resume would end the test run).
    @Test func manyAnswersAtOnceAnswerOnce() async {
        for round in 0..<100 {
            let stopped = Stopped()
            let answer = Self.answer(stopped)
            let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                guard answer.begin(continuation) else { return }
                answer.limit(.milliseconds(round % 3))
                DispatchQueue.global().async {
                    DispatchQueue.concurrentPerform(iterations: 8) { index in
                        if index == 3 { answer.started(Int32(round)) }
                        if index % 2 == 0 { answer.finish("answer \(index)") } else { answer.cancel() }
                    }
                }
            }
            #expect(value == "none" || value.hasPrefix("answer "))
            #expect(stopped.all.count <= 1)
        }
    }
}
