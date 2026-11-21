import Foundation
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore

/// Resumed run, new work (from the third review pass of the progress work): a floor from before a big new workload.
@Suite("Resumed run: floor and new work")
struct ResumedNewWorkTests {
    /// Stopped in the text step (stage 5) at 90 %. An update asks for every image again, so
    /// the run spends hours in the image step (stage 4), which counts as "catching up": the card
    /// says "Macht da weiter … Gleich wieder bei Schritt 5" and holds 90 % the whole time.
    @Test func newWorkBeforeTheStoppedStepIsNotFrozenAtTheFloor() {
        let w = StepWidths.standard
        // Adapted to the decision (review of 83db832, IMPORTANT 2): the marker keeps the work
        // left when the run stopped (2,000 screenshots to read), and the workload says how much
        // there is now.
        var run = ResumedRun(stage: 5, shown: 0.90, left: 2_000, photos: 50_000, updated: true)
        let update = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 50_000, textLeft: 2_000)
        _ = run.workload(update)
        var values: Set<Int> = []
        for done in stride(from: 0, through: 50_000, by: 5_000) {
            let real = w.overall(step: .content, completed: done, total: 50_000)
            let catching = run.isCatchingUp(running: true, at: 4)
            values.insert(Int((run.shown(running: true, catchingUp: catching, overall: real, stopped: nil) * 100).rounded()))
        }
        #expect(values.count > 1, "shown all through the image step: \(values.sorted()) %")
    }

    /// Paused near the end (proposals, 99.6 %), then an update asks for every image again:
    /// "Analyse zu 100 % fertig" while hours of work are left.
    @Test func neverReads100WhileWorkIsLeft() {
        let w = StepWidths.standard
        let run = ResumedRun(stage: 7, shown: 0.996)
        let real = w.overall(step: .content, completed: 1_000, total: 50_000)
        let shown = run.shown(running: true, catchingUp: run.isCatchingUp(running: true, at: 4), overall: real, stopped: nil)
        #expect(Int((shown * 100).rounded()) < 100, "reads \(Int((shown * 100).rounded())) % with 49,000 photos left")
    }
}
