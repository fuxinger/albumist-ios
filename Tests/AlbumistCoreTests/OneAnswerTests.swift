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

    // MARK: Nothing kept (review D2, N2)

    /// What a request answers, as a Live Photo is: an object.
    final class Photo: Sendable {}

    /// The answer goes to the caller and is not kept: a Live Photo the page let go of is freed
    /// at once, not when the request's time limit would have ended (review D2, N2: about fifteen
    /// Live Photos stayed in memory while the user swiped through a burst).
    @Test func theAnswerIsNotKeptOnceTheCallerHasIt() async {
        let answer = OneAnswer<Photo?, Int32>(fallback: nil) { _ in }
        weak var released: Photo?
        var held: Photo? = await withCheckedContinuation { continuation in
            guard answer.begin(continuation) else { return }
            let photo = Photo()
            released = photo
            answer.finish(photo)
        }
        #expect(held != nil)
        #expect(released != nil)
        held = nil
        #expect(released == nil, "the answer keeps the photo")
        withExtendedLifetime(answer) {}
    }

    /// An answer that comes before the caller waits is kept for it, and only until it has it.
    @Test func anEarlyAnswerIsKeptOnlyUntilTheCallerHasIt() async {
        let answer = OneAnswer<Photo?, Int32>(fallback: nil) { _ in }
        weak var released: Photo?
        do {
            let photo = Photo()
            released = photo
            answer.finish(photo)
        }
        #expect(released != nil, "an early answer must wait for its caller")
        var held: Photo? = await withCheckedContinuation { continuation in
            _ = answer.begin(continuation)
        }
        #expect(held != nil)
        held = nil
        #expect(released == nil, "the answer keeps the photo")
        withExtendedLifetime(answer) {}
    }

    /// The time limit ends with the answer: no task sleeps on for a request that is over, and
    /// none holds the answer object until its time is up.
    @Test func theTimeLimitEndsWithTheAnswer() async throws {
        weak var released: OneAnswer<String, Int32>?
        do {
            let answer = Self.answer(Stopped())
            released = answer
            answer.limit(.seconds(60))
            let limit = try #require(answer.limitTask)
            let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                guard answer.begin(continuation) else { return }
                answer.finish("photo")
            }
            #expect(value == "photo")
            #expect(limit.isCancelled, "the time limit sleeps on")
            #expect(answer.limitTask == nil)
            // Ends at once (not after a minute).
            if limit.isCancelled { await limit.value }
        }
        #expect(released == nil, "the time limit keeps the answer alive")
    }

    /// A caller that goes away ends the time limit too; a limit set after the answer starts none.
    @Test func aCancelEndsTheTimeLimit() async throws {
        let answer = Self.answer(Stopped())
        answer.limit(.seconds(60))
        let limit = try #require(answer.limitTask)
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard answer.begin(continuation) else { return }
            answer.cancel()
        }
        #expect(value == "none")
        #expect(limit.isCancelled)
        if limit.isCancelled { await limit.value }
        answer.limit(.seconds(60))
        #expect(answer.limitTask == nil, "a limit after the answer")
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
