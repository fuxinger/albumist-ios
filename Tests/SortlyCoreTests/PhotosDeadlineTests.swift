import Foundation
import Testing
@testable import SortlyCore

/// App-speed (18.11.2026): calls into Photos that never answer must not freeze the analysis or
/// a plan for good (`PhotosDeadline`). Short limits here; the app waits seconds.
@Suite("Bounded waits for Photos", .timeLimit(.minutes(15)))
struct PhotosDeadlineTests {
    /// How long a call may wait for a thread before it counts as not answering. The app gives
    /// 60 s (`PhotosDeadline.notBegunGrace`); in the full parallel test run Swift's shared pool
    /// was busy for 78 s once (CI 44380367650 on Linux: every test, even a trivial one, took 78 s),
    /// and three calls whose answer these tests check were given up before their task got a
    /// thread. These tests are about Photos' answer, not about that wait (it has its own tests,
    /// `aCallWithoutAThreadIsGivenUpOnlyAfterItsGrace` and the ones with a `Gate`); a call that
    /// got its thread is still cut off at its limit. Ten minutes, well under the suite's limit,
    /// so a call that never gets a thread fails the test instead of holding it for an hour.
    static let grace: Duration = .seconds(600)

    /// Holds every call of a `PhotosDeadline` before it begins, as a thread pool kept busy by
    /// Albumist's own work does, until opened (`startGate`).
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var held = 0
        private var through = 0
        var open: Bool {
            get { lock.withLock { isOpen } }
            set { lock.withLock { isOpen = newValue } }
        }
        /// Calls whose task reached the gate.
        var waiting: Int { lock.withLock { held } }
        /// Calls whose task went through the gate (they begin, or find they were given up).
        var passed: Int { lock.withLock { through } }
        func wait() async {
            lock.withLock { held += 1 }
            while !open { await Stuck.pause() }
            lock.withLock { through += 1 }
        }
    }

    /// Stands for a Photos call that does not answer and ignores cancellation, until opened.
    final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var calls = 0
        var open: Bool {
            get { lock.withLock { isOpen } }
            set { lock.withLock { isOpen = newValue } }
        }
        var started: Int { lock.withLock { calls } }
        func wait() async -> Int {
            lock.withLock { calls += 1 }
            while !open { await Self.pause() }
            return 7
        }
        /// A real pause also once the call was cancelled (given up): a cancelled sleep throws at
        /// once, and the loop would hold a thread of the shared pool without ever giving it up
        /// (the full test run hung with every thread in such a loop).
        static func pause() async {
            await Task.detached { try? await Task.sleep(for: .milliseconds(5)) }.value
        }
    }

    @Test func answerInTimeIsReturned() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        let value = try await deadline.run("fetch", lane: .read, limit: .seconds(2)) { _ in 42 }
        #expect(value == 42)
        #expect(deadline.hangingCalls(.read) == 0)
    }

    @Test func errorOfTheCallIsPassedOn() async {
        struct Failed: Error, Equatable {}
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        await #expect(throws: Failed.self) {
            try await deadline.run("write", lane: .write, limit: .seconds(2)) { _ -> Int in throw Failed() }
        }
        #expect(deadline.hangingCalls(.write) == 0)
    }

    /// No answer: the caller goes on after the limit. While the call still hangs, no second
    /// call of the same kind is sent; once it returns, the next one runs.
    @Test func hangingWriteKeepsTheNextOneFromBeingSent() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        let stuck = Stuck()
        let clock = ContinuousClock()
        let began = clock.now
        await #expect(throws: PhotosNotResponding(lane: .write, what: "createAlbum", notSent: false)) {
            try await deadline.run("createAlbum", lane: .write, limit: .milliseconds(150)) { _ in await stuck.wait() }
        }
        let waited = clock.now - began
        // No upper bound here: under a full parallel test run this task itself may resume late.
        #expect(waited >= .milliseconds(150))
        #expect(deadline.hangingCalls(.write) == 1)

        let second = Stuck()
        second.open = true
        await #expect(throws: PhotosNotResponding(lane: .write, what: "addAssets", notSent: true)) {
            try await deadline.run("addAssets", lane: .write, limit: .milliseconds(100)) { _ in await second.wait() }
        }
        #expect(second.started == 0)
        // Reads are not held up by a hanging write.
        #expect(try await deadline.run("collection", lane: .read, limit: .seconds(1)) { _ in 1 } == 1)

        // The first call returns at last (its answer is dropped): writes go out again.
        stuck.open = true
        while deadline.hangingCalls(.write) > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await deadline.run("addAssets", lane: .write, limit: .seconds(1)) { _ in await second.wait() } == 7)
        #expect(second.started == 1)
    }

    /// A call waiting for an earlier one gets through when that one returns within its limit.
    @Test func waitingCallGoesOnceTheHangingOneReturns() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        let stuck = Stuck()
        _ = try? await deadline.run("fetch", lane: .read, limit: .milliseconds(50)) { _ in await stuck.wait() }
        #expect(deadline.hangingCalls(.read) == 1)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            stuck.open = true
        }
        #expect(try await deadline.run("fetch", lane: .read, limit: .seconds(60)) { _ in 3 } == 3)
        #expect(deadline.hangingCalls(.read) == 0)
    }

    /// A long read that keeps saying it moves is not cut off; one that stops moving is.
    @Test func heartbeatKeepsALongReadAlive() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        // The read runs about four times its limit, with a beat every 25 ms; it reads without
        // giving up its thread, like the PhotoKit reads do.
        let value = try await deadline.run("fetchAssets", lane: .read, limit: .milliseconds(500)) { beat in
            let clock = ContinuousClock()
            let began = clock.now
            while clock.now - began < .seconds(2) {
                usleep(25_000)
                beat.beat()
            }
            return 500
        }
        #expect(value == 500)
        let stuck = Stuck()
        await #expect(throws: PhotosNotResponding.self) {
            try await deadline.run("fetchAssets", lane: .read, limit: .milliseconds(150)) { beat in
                for _ in 0..<4 {
                    try? await Task.sleep(for: .milliseconds(25))
                    beat.beat()
                }
                return await stuck.wait()
            }
        }
        stuck.open = true
    }

    /// "Fotos antwortet gerade nicht" may show while Albumist still waits; not for a call that
    /// waits for the user's answer to iOS.
    @Test func slowCallIsSaidWhileItWaits() async throws {
        let deadline = PhotosDeadline(slowAfter: .milliseconds(60), notBegunGrace: Self.grace)
        let stuck = Stuck()
        let call = Task { try await deadline.run("fetch", lane: .read, limit: .seconds(30)) { _ in await stuck.wait() } }
        while stuck.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let clock = ContinuousClock()
        let began = clock.now
        while deadline.slowFor() == nil && clock.now - began < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(deadline.slowFor() != nil)
        stuck.open = true
        #expect(try await call.value == 7)
        #expect(deadline.slowFor() == nil)

        let user = Stuck()
        let delete = Task { try await deadline.run("delete", lane: .write, limit: .seconds(30), reportsSlow: false) { _ in await user.wait() } }
        while user.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(deadline.slowFor() == nil)
        user.open = true
        _ = try await delete.value
    }

    /// The caller is cancelled (the run ends): it goes on at once; a call that was sent and
    /// has not returned counts as hanging.
    @Test func cancelledCallerDoesNotWaitAndTheCallStillCounts() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        let stuck = Stuck()
        let call = Task { try await deadline.run("write", lane: .write, limit: .seconds(60)) { _ in await stuck.wait() } }
        while stuck.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(deadline.hangingCalls(.write) == 1)
        stuck.open = true
        while deadline.hangingCalls(.write) > 0 { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A write while an earlier one hangs is refused at once, never sent after a wait: it was
    /// decided from a library the hanging write may still change (second review 1). Reads and
    /// image requests are not held up by it.
    @Test func writeIsNeverSentAfterWaitingForAHangingOne() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        let stuck = Stuck()
        _ = try? await deadline.run("createAlbum", lane: .write, limit: .milliseconds(50)) { _ in await stuck.wait() }
        #expect(deadline.hangingCalls(.write) == 1)
        let second = Stuck()
        second.open = true
        let clock = ContinuousClock()
        let began = clock.now
        await #expect(throws: PhotosNotResponding(lane: .write, what: "createAlbum", notSent: true)) {
            try await deadline.run("createAlbum", lane: .write, limit: .seconds(30)) { _ in await second.wait() }
        }
        #expect(clock.now - began < .seconds(10))
        #expect(second.started == 0)
        #expect(try await deadline.run("photo", lane: .image, limit: .seconds(30)) { _ in 5 } == 5)
        // The deletion's question to the user is said as such.
        await #expect(throws: PhotosNotResponding(lane: .write, what: "delete", notSent: true, asksUser: true)) {
            try await deadline.run("delete", lane: .write, limit: .seconds(30), reportsSlow: false) { _ in 1 }
        }
        stuck.open = true
        while deadline.hangingCalls(.write) > 0 { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A look much later than planned (the app was suspended) gives the call its limit again;
    /// otherwise the limit decides (second review 3).
    @Test func aLateLookMeansTheAppWasSuspended() {
        #expect(PhotosDeadline.look(quiet: .seconds(90), limit: .seconds(60), late: .seconds(85)) == .cameBack)
        #expect(PhotosDeadline.look(quiet: .seconds(61), limit: .seconds(60), late: .milliseconds(10)) == .giveUp)
        #expect(PhotosDeadline.look(quiet: .seconds(10), limit: .seconds(60), late: .zero) == .again(.seconds(1)))
        #expect(PhotosDeadline.look(quiet: .seconds(59.5), limit: .seconds(60), late: .zero) == .again(.milliseconds(500)))
        // A timer that is always late is not a suspension: after three in a row the limit
        // decides (third review, N5).
        #expect(PhotosDeadline.look(quiet: .seconds(90), limit: .seconds(60), late: .seconds(5), cameBack: 2) == .cameBack)
        #expect(PhotosDeadline.look(quiet: .seconds(90), limit: .seconds(60), late: .seconds(5), cameBack: 3) == .giveUp)
    }

    /// A call that has no thread yet is not cut off at its limit, but never kept for good
    /// (second review of the PhotoKit limits, 4).
    @Test func aCallWithoutAThreadIsGivenUpOnlyAfterItsGrace() {
        let start = ContinuousClock.now
        let limit = Duration.seconds(1)
        let grace = PhotosDeadline.notBegunGrace
        let early = PhotosDeadline.quiet(now: start + .seconds(30), lastBeat: start, running: false, grace: grace)
        #expect(PhotosDeadline.look(quiet: early, limit: limit, late: .zero) != .giveUp)
        let late = PhotosDeadline.quiet(now: start + PhotosDeadline.notBegunGrace + limit, lastBeat: start, running: false,
                                        grace: grace)
        #expect(PhotosDeadline.look(quiet: late, limit: limit, late: .zero) == .giveUp)
        let running = PhotosDeadline.quiet(now: start + limit, lastBeat: start, running: true, grace: grace)
        #expect(PhotosDeadline.look(quiet: running, limit: limit, late: .zero) == .giveUp)
        // The app's instance waits the 60 s; a longer grace (the tests) only adds to the wait of
        // a call without a thread, never to that of a running one.
        #expect(PhotosDeadline().grace == PhotosDeadline.notBegunGrace)
        let longer = PhotosDeadline.quiet(now: start + PhotosDeadline.notBegunGrace + limit, lastBeat: start, running: false,
                                          grace: Self.grace)
        #expect(PhotosDeadline.look(quiet: longer, limit: limit, late: .zero) != .giveUp)
        let runningLonger = PhotosDeadline.quiet(now: start + limit, lastBeat: start, running: true, grace: Self.grace)
        #expect(PhotosDeadline.look(quiet: runningLonger, limit: limit, late: .zero) == .giveUp)
    }

    /// A call given up before its task got a thread (its limit plus the grace passed while
    /// Albumist's own work kept every thread busy) was never sent: it never runs later, does not
    /// hang, says so (`notSent`, `neverBegan`), and the next write goes out. Before, it counted
    /// as hanging (the next write was refused) and its change request still ran after the plan
    /// had stopped with "outcome unknown" (second review of 6c45378, P1).
    @Test func aWriteGivenUpBeforeItBeganNeverRuns() async throws {
        let gate = Gate()
        let deadline = PhotosDeadline(notBegunGrace: .milliseconds(100), startGate: { await gate.wait() })
        let stuck = Stuck()
        stuck.open = true
        await #expect(throws: PhotosNotResponding(lane: .write, what: "createAlbum", notSent: true, neverBegan: true)) {
            try await deadline.run("createAlbum", lane: .write, limit: .milliseconds(100)) { _ in await stuck.wait() }
        }
        #expect(deadline.hangingCalls(.write) == 0)
        // Its task gets a thread now: it finds it was given up and does not run.
        gate.open = true
        let clock = ContinuousClock()
        let opened = clock.now
        while gate.passed < 1, clock.now - opened < .seconds(300) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.passed >= 1)
        // The next write is sent (a long limit: it only has to get a thread under a full test run).
        let next = Stuck()
        next.open = true
        #expect(try await deadline.run("addAssets", lane: .write, limit: .seconds(300)) { _ in await next.wait() } == 7)
        #expect(next.started == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(stuck.started == 0)
        #expect(deadline.hangingCalls(.write) == 0)
    }

    /// The same for a caller cancelled while its call had no thread yet: the call never runs
    /// and does not hang.
    @Test func aCancelledCallThatHadNotBegunNeverRuns() async throws {
        let gate = Gate()
        let deadline = PhotosDeadline(notBegunGrace: Self.grace, startGate: { await gate.wait() })
        let stuck = Stuck()
        stuck.open = true
        let call = Task { try await deadline.run("createAlbum", lane: .write, limit: .seconds(300)) { _ in await stuck.wait() } }
        let clock = ContinuousClock()
        let began = clock.now
        while gate.waiting == 0, clock.now - began < .seconds(300) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.waiting == 1)
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(deadline.hangingCalls(.write) == 0)
        gate.open = true
        while gate.passed < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(stuck.started == 0)
        #expect(deadline.hangingCalls(.write) == 0)
    }

    /// Stopping and beginning exclude each other: a call stopped first never begins (it was not
    /// sent); one that began says so when it is stopped (it hangs until it returns).
    @Test func aHeartbeatStoppedBeforeItBeganNeverBegins() {
        let notBegun = PhotosDeadline.Heartbeat(.now)
        #expect(notBegun.stop() == false)
        #expect(notBegun.begin() == false)
        #expect(notBegun.isCancelled)
        #expect(notBegun.quietSince == nil)
        let running = PhotosDeadline.Heartbeat(.now)
        #expect(running.begin())
        #expect(running.stop())
        #expect(running.isCancelled)
    }

    /// "Fotos antwortet gerade nicht" only for a call Photos has been asked: one still waiting
    /// for a thread waits for Albumist's own work (second review of 6c45378, P2). Before, the
    /// note came after 10 s of a busy thread pool.
    @Test func slowForCountsOnlyCallsThatBegan() async throws {
        let gate = Gate()
        let deadline = PhotosDeadline(slowAfter: .milliseconds(60), notBegunGrace: Self.grace, startGate: { await gate.wait() })
        let stuck = Stuck()
        let call = Task { try await deadline.run("fetch", lane: .read, limit: .seconds(300)) { _ in await stuck.wait() } }
        let clock = ContinuousClock()
        let began = clock.now
        while gate.waiting == 0, clock.now - began < .seconds(300) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.waiting == 1)
        // A minute without a thread: still not "Fotos antwortet gerade nicht".
        #expect(deadline.slowFor(now: .now + .seconds(60)) == nil)
        gate.open = true
        while stuck.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // Begun: it counts from when it began.
        #expect(deadline.slowFor(now: .now + .seconds(1)) != nil)
        stuck.open = true
        #expect(try await call.value == 7)
        #expect(deadline.slowFor(now: .now + .seconds(60)) == nil)
    }

    /// Back on screen: every waiting call gets its limit again from then.
    @Test func comingBackGivesWaitingCallsTheirLimitAgain() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        let stuck = Stuck()
        let clock = ContinuousClock()
        let began = clock.now
        let call = Task { try await deadline.run("fetch", lane: .read, limit: .seconds(1)) { _ in await stuck.wait() } }
        while stuck.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(600))
        let cameBack = clock.now
        deadline.cameBack()
        await #expect(throws: PhotosNotResponding.self) { try await call.value }
        // Only meaningful if the call was still waiting when the app came back.
        if cameBack - began < .milliseconds(900) {
            #expect(clock.now - cameBack >= .milliseconds(950))
        }
        stuck.open = true
    }

    /// Synchronous PhotoKit work runs on a queue of its own and is bounded the same way.
    @Test func blockingWorkIsBounded() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        #expect(try await deadline.runBlocking("fetch", lane: .read, limit: .seconds(30)) { _ in 9 } == 9)
        let stuck = Stuck()
        await #expect(throws: PhotosNotResponding.self) {
            try await deadline.runBlocking("fetch", lane: .image, limit: .milliseconds(200)) { _ -> Int in
                while !stuck.open { usleep(5_000) }
                return 1
            }
        }
        stuck.open = true
        while deadline.hangingCalls(.image) > 0 { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Work on the queue has no task to cancel: a long read nobody waits for any more is told
    /// so by its heartbeat, stops, and frees its lane (third review, N1).
    @Test func blockingWorkNobodyWaitsForIsToldToStop() async throws {
        let deadline = PhotosDeadline(notBegunGrace: Self.grace)
        await #expect(throws: PhotosNotResponding.self) {
            try await deadline.runBlocking("fetchAssets", lane: .read, limit: .milliseconds(200)) { beat -> Int in
                while !beat.isCancelled { usleep(5_000) }
                return 1
            }
        }
        let clock = ContinuousClock()
        let gaveUp = clock.now
        while deadline.hangingCalls(.read) > 0, clock.now - gaveUp < .seconds(20) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(deadline.hangingCalls(.read) == 0)
        // Blocking work runs at the caller's priority (N4).
        #expect(PhotosDeadline.queue(for: .background).label != PhotosDeadline.queue(for: .userInitiated).label)
        #expect(PhotosDeadline.queue(for: .medium).label == PhotosDeadline.queue(for: .high).label)
    }
}
