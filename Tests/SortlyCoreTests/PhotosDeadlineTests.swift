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
            while !open { try? await Task.sleep(for: .milliseconds(5)) }
            return 7
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
}
