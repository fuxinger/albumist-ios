import Foundation
import Testing

/// The speed tests' clock (main CI 45722816550): waiting for a core must not count, work must.
@Suite("Speed tests' clock")
struct ThreadCPUClockTests {
    /// A thread that waits (as one does on a starved Mac) uses no CPU time.
    @Test func waitingDoesNotCount() {
        let took = ThreadCPUClock().measure { Thread.sleep(forTimeInterval: 0.3) }
        #expect(took < .milliseconds(50), "waiting counted \(took)")
    }

    /// Real work is still measured, so a slow algorithm still fails its bound.
    @Test func workCounts() {
        var sum = 0.0
        let took = ThreadCPUClock().measure {
            var x = 1.0
            for i in 0..<20_000_000 { x = (x * 1.000_000_1 + Double(i & 7)).truncatingRemainder(dividingBy: 1_000_003) }
            sum = x
        }
        #expect(sum > 0)
        #expect(took > .milliseconds(10), "20 million steps took only \(took)")
    }
}
