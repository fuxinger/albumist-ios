import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore

/// Fourth-pass review evidence (uncommitted): leaving "catching up" early (a slow quick step,
/// measured over 30 s) re-spreads from the floor at the CURRENT position, so the work that was
/// already done before the stop is counted again as new progress.
@Suite("Review evidence 4: back before the stopped step")
struct ReviewFourthPassEvidenceTests {
    /// Paused at 30,000 of 50,000 photos in the image step (stage 4). Nothing changed. On
    /// resume the places step's map pass over 50,000 photos takes about a minute, so after its
    /// first 30 s it is measured as slow: not catching up, `back` at the places step. Once the
    /// run is again at 30,000 of 50,000 in the image step, the card should still read about
    /// the value it was paused at.
    @Test func plainResumeWithASlowQuickStepDoesNotJumpAhead() throws {
        let w = StepWidths.standard
        let floor = w.overall(step: .content, completed: 30_000, total: 50_000)
        var run = ResumedRun(stage: 4, shown: floor, left: 21_000, photos: 50_000)
        // Adapted (review of 11ef3e1, decision): no timing rule any more; before the stopped
        // position the run holds, however slow the places pass is.
        #expect(run.isCatchingUp(running: true, at: 3))
        let widths = run.back(at: 3, step: .places, completed: 10_000, total: 50_000, widths: w) ?? w
        let real = widths.overall(step: .content, completed: 30_000, total: 50_000)
        let shown = run.shown(running: true, catchingUp: false, overall: real, stopped: nil)
        #expect(abs(shown - floor) < 0.02, "paused at \(Int(floor * 100)) %, back at the same photo: \(Int(shown * 100)) %")
    }

    /// The same in the first step (library read over 30 s, `base` mapping).
    @Test func plainResumeWithASlowLibraryReadDoesNotJumpAhead() {
        let w = StepWidths.standard
        let floor = w.overall(step: .content, completed: 30_000, total: 50_000)
        var run = ResumedRun(stage: 4, shown: floor, left: 21_000, photos: 50_000)
        let r = run.back(at: 1, step: .library, completed: 10_000, total: 50_000, widths: w)
        let widths = r ?? w
        let real = widths.overall(step: .content, completed: 30_000, total: 50_000)
        let shown = run.shown(running: true, catchingUp: false, overall: real, stopped: nil)
        #expect(abs(shown - floor) < 0.02, "paused at \(Int(floor * 100)) %, back at the same photo: \(Int(shown * 100)) %")
    }
}
