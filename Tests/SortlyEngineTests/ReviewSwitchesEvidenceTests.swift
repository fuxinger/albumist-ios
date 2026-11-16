import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore

/// Review evidence (uncommitted): the "never lower" percentage of a resumed run.
@Suite("Review evidence: resumed percentage")
struct ReviewSwitchesEvidenceTests {
    typealias Instant = ContinuousClock.Instant
    static let t0 = ContinuousClock.now
    static func at(_ seconds: Double) -> Instant { t0.advanced(by: .seconds(seconds)) }

    /// Mirrors AppModel.receive/tick for a resumed run (resumeFrom != nil) on screen with the
    /// glide on: every report whose real value is below the drawn bar re-spreads the widths so
    /// that the real value equals the bar (AppModel.swift:887-892, `held: max(held, analysisBar)`).
    /// Photos finish irregularly (4 lanes, 0.5 to 3.5 s each, about 2 a second on average, as
    /// in the stress log). The bar should go on from 64 % at the speed of the real work, as
    /// the one-time rescale at the start does (`oneShot`).
    @Test(arguments: [0, 25]) func resumedBarDoesNotRunAheadOfTheWork(stallEvery: Int) throws {
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double(rng >> 11) / Double(1 << 53)
        }
        let total = 50_246
        let held = 0.64
        var widths = StepWidths.standard
        let oneShot = try #require(widths.continuing(held: held, step: .content, completed: 0, total: total))
        var resumed = ResumedRun(stage: 4, shown: held)
        var glide = BarGlide()
        glide.reset(keeping: held)
        var bar = glide.value(at: Self.at(0), gliding: false)
        // Four lanes, each finishing a photo after 0.5...3.5 s.
        var lanes = (0..<4).map { _ in 0.5 + 3 * random() }
        var completed = 0
        var reported = -1
        let rate = stallEvery > 0 ? 1.0 / (2.0 / 4 + 15.0 / 4 / Double(stallEvery)) : 2.0 // measured average
        var t = 0.0
        while completed < 10_000 {
            t += 0.25
            for i in lanes.indices where lanes[i] <= t {
                completed += 1
                // Now and then a photo waits 15 s (a preview still loading), as the stress
                // log's "stood still 10-15 s" lines show.
                let stall = stallEvery > 0 && completed % stallEvery == 0 ? 15.0 : 0
                lanes[i] += 0.5 + 3 * random() + stall
            }
            if completed != reported {
                reported = completed
                // receive() since the fix: `ResumedRun.back`, once, from the marker's value
                // (the earlier run stopped at 4,000 of 10,000 photos; 40,246 came in since).
                if let c = resumed.back(at: 4, step: .content, completed: completed, total: total, widths: widths) {
                    widths = c
                }
                let real = widths.overall(step: .content, completed: completed, total: total)
                glide.update(real: real, at: Self.at(t), step: .content, widths: widths, itemsPerSecond: rate, total: total)
            }
            bar = glide.value(at: Self.at(t), gliding: true)
        }
        let honest = oneShot.overall(step: .content, completed: completed, total: total)
        let gainedHonest = honest - held
        let gainedShown = bar - held
        // 10,000 of 50,246 photos: the honest gain is about 7 points. Allow 10 % more.
        #expect(gainedShown <= gainedHonest * 1.10,
                "bar \(bar) vs honest \(honest): moved \(gainedShown / gainedHonest)x as fast as the work")
        // The segments of the bar are meant to stay fixed for the analysis after the one rescale.
        #expect(widths == oneShot, "widths re-spread on later reports")
    }
}
