import Foundation
import Testing
@testable import SortlyCore

/// App-speed (18.11.2026): calls into Photos that never answer must not freeze the analysis or
/// a plan for good (`PhotosDeadline`). Short limits here; the app waits seconds.
@Suite("Bounded waits for Photos")
struct PhotosDeadlineTests {
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
        let deadline = PhotosDeadline()
        let value = try await deadline.run("fetch", lane: .read, limit: .seconds(2)) { _ in 42 }
        #expect(value == 42)
        #expect(deadline.hangingCalls(.read) == 0)
    }

    @Test func errorOfTheCallIsPassedOn() async {
        struct Failed: Error, Equatable {}
        let deadline = PhotosDeadline()
        await #expect(throws: Failed.self) {
            try await deadline.run("write", lane: .write, limit: .seconds(2)) { _ -> Int in throw Failed() }
        }
        #expect(deadline.hangingCalls(.write) == 0)
    }

    /// No answer: the caller goes on after the limit. While the call still hangs, no second
    /// call of the same kind is sent; once it returns, the next one runs.
    @Test func hangingWriteKeepsTheNextOneFromBeingSent() async throws {
        let deadline = PhotosDeadline()
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
        let deadline = PhotosDeadline()
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
        let deadline = PhotosDeadline()
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
        let deadline = PhotosDeadline(slowAfter: .milliseconds(60))
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
        let deadline = PhotosDeadline()
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
        let deadline = PhotosDeadline()
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
    }

    /// A call that has no thread yet is not cut off at its limit, but never kept for good
    /// (second review of the PhotoKit limits, 4).
    @Test func aCallWithoutAThreadIsGivenUpOnlyAfterItsGrace() {
        let start = ContinuousClock.now
        let limit = Duration.seconds(1)
        let early = PhotosDeadline.quiet(now: start + .seconds(30), lastBeat: start, running: false)
        #expect(PhotosDeadline.look(quiet: early, limit: limit, late: .zero) != .giveUp)
        let late = PhotosDeadline.quiet(now: start + PhotosDeadline.notBegunGrace + limit, lastBeat: start, running: false)
        #expect(PhotosDeadline.look(quiet: late, limit: limit, late: .zero) == .giveUp)
        let running = PhotosDeadline.quiet(now: start + limit, lastBeat: start, running: true)
        #expect(PhotosDeadline.look(quiet: running, limit: limit, late: .zero) == .giveUp)
    }

    /// Back on screen: every waiting call gets its limit again from then.
    @Test func comingBackGivesWaitingCallsTheirLimitAgain() async throws {
        let deadline = PhotosDeadline()
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
        let deadline = PhotosDeadline()
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
}
