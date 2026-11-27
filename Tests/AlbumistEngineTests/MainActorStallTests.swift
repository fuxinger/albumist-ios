import Foundation
import Testing
@testable import AlbumistEngine

/// `MainThreadWork.ownStall` takes off only the machine's load, and the ticker of
/// `MainThreadWork.mainActorStall` sees work that holds the main actor. Not a load test (its own
/// file, so `--filter LoadTests` does not pick it): it runs in every core test run, beside other
/// tests on the main actor, so it asserts nothing about the baseline (core tests hard (macOS) in
/// UI run 45936196002: beside the load test the baseline took up the whole 300 ms).
struct MainActorStallTests {
    @Test func theMachinesLoadIsTakenOffNeverMore() {
        #expect(MainThreadWork.ownStall(.milliseconds(60), baseline: .milliseconds(25)) == .milliseconds(35))
        #expect(MainThreadWork.ownStall(.milliseconds(10), baseline: .milliseconds(25)) == .zero)
        #expect(MainThreadWork.ownStall(.milliseconds(300), baseline: .zero) == .milliseconds(300))
    }

    /// Work that holds the main actor for 100 ms shows as a gap of the ticker at least that long.
    /// Short, so other tests on the main actor beside it wait only that long.
    @MainActor
    @Test func workOnTheMainActorIsSeen() async {
        let (stall, _) = await MainThreadWork.mainActorStall {
            // The detached work puts 100 ms on the main actor and runs on past it.
            Task { @MainActor in MainActorStallTests.hold(0.1) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        #expect(stall >= .milliseconds(90), "the ticker saw only \(stall)")
    }

    /// Blocks the calling thread (`Thread.sleep` is unavailable in an async context such as the
    /// main actor's task, Linux core tests 45935589057).
    static func hold(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
