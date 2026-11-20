import Foundation
import Testing
@testable import AlbumistCore

/// The progress iOS sees for an analysis in the background (device test 15.11.: the bar
/// showed "Vorgang fehlgeschlagen" because iOS took a progress that stood still for an
/// unresponsive app).
@Suite("Continued task heartbeat")
struct ContinuedTaskHeartbeatTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func units(_ step: ContinuedTaskHeartbeat.Step) -> Int64? {
        if case .report(let units) = step { return units }
        return nil
    }

    @Test func followsTheRealProgressAndNeverGoesBack() {
        var beat = ContinuedTaskHeartbeat(start: start)
        #expect(units(beat.step(now: start, running: true, fraction: 0.25)) == 2_500)
        // A late, smaller value (the stages hop in one by one) does not move it back.
        #expect(units(beat.step(now: start.addingTimeInterval(1), running: true, fraction: 0.20)) == 2_500)
        #expect(units(beat.step(now: start.addingTimeInterval(2), running: true, fraction: 0.5)) == 5_000)
    }

    @Test func movesEveryTenSecondsWhileTheRealProgressStandsStill() {
        // One slow photo, a place lookup, or a break while the iPhone cools down: iOS must
        // still see movement, at least one whole unit every ten seconds.
        var beat = ContinuedTaskHeartbeat(start: start)
        _ = beat.step(now: start, running: true, fraction: 0.4)
        var last: Int64 = 4_000
        var standing: TimeInterval = 0
        for second in 1...600 {
            let now = start.addingTimeInterval(TimeInterval(second))
            let reported = units(beat.step(now: now, running: true, fraction: 0.4)) ?? -1
            #expect(reported >= last)
            if reported == last { standing += 1 } else { standing = 0 }
            #expect(standing < ContinuedTaskHeartbeat.heartbeat)
            last = reported
        }
        // Ten minutes of waiting moved the bar by 0.6 %, invisible as a jump.
        #expect(last == 4_060)
    }

    @Test func realProgressCatchesUpWithoutAJumpBack() {
        var beat = ContinuedTaskHeartbeat(start: start)
        _ = beat.step(now: start, running: true, fraction: 0.1)
        for second in 1...100 { _ = beat.step(now: start.addingTimeInterval(TimeInterval(second)), running: true, fraction: 0.1) }
        let ahead = beat.reported
        #expect(ahead == 1_010)
        // The run goes on: below the reported value nothing changes, above it the real value counts.
        #expect(units(beat.step(now: start.addingTimeInterval(101), running: true, fraction: 0.1005)) == ahead)
        #expect(units(beat.step(now: start.addingTimeInterval(102), running: true, fraction: 0.3)) == 3_000)
    }

    @Test func neverFullWhileTheRunIsBusy() {
        var beat = ContinuedTaskHeartbeat(start: start)
        #expect(units(beat.step(now: start, running: true, fraction: 1)) == ContinuedTaskHeartbeat.units - 1)
        for second in 1...100 {
            #expect(units(beat.step(now: start.addingTimeInterval(TimeInterval(second * 20)), running: true, fraction: 1)) == ContinuedTaskHeartbeat.units - 1)
        }
    }

    @Test func oddFractionsAreIgnored() {
        var beat = ContinuedTaskHeartbeat(start: start)
        #expect(units(beat.step(now: start, running: true, fraction: .nan)) == 0)
        #expect(units(beat.step(now: start.addingTimeInterval(1), running: true, fraction: -3)) == 0)
        #expect(units(beat.step(now: start.addingTimeInterval(2), running: true, fraction: .infinity)) == 0)
    }

    @Test func endsOnlyAfterTheAnalysisStoppedForFourSeconds() {
        var beat = ContinuedTaskHeartbeat(start: start)
        _ = beat.step(now: start, running: true, fraction: 0.5)
        #expect(units(beat.step(now: start.addingTimeInterval(1), running: false, fraction: 0.5)) == 5_000)
        #expect(units(beat.step(now: start.addingTimeInterval(4), running: false, fraction: 0.5)) == 5_000)
        #expect(beat.step(now: start.addingTimeInterval(5), running: false, fraction: 0.5) == .finish)
    }

    @Test func aRunThatStartsAgainWithinTheGapKeepsTheTask() {
        // The run ends and a catch-up run starts right after: the same bar goes on.
        var beat = ContinuedTaskHeartbeat(start: start)
        _ = beat.step(now: start, running: true, fraction: 0.5)
        _ = beat.step(now: start.addingTimeInterval(1), running: false, fraction: 0)
        _ = beat.step(now: start.addingTimeInterval(3), running: false, fraction: 0)
        #expect(units(beat.step(now: start.addingTimeInterval(4), running: true, fraction: 0.1)) == 5_000)
        // The gap starts again from zero.
        #expect(units(beat.step(now: start.addingTimeInterval(5), running: false, fraction: 0.1)) != nil)
        #expect(units(beat.step(now: start.addingTimeInterval(8), running: false, fraction: 0.1)) != nil)
        #expect(beat.step(now: start.addingTimeInterval(9), running: false, fraction: 0.1) == .finish)
    }
}
