import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore

/// Second-pass review evidence (uncommitted): `ResumedRun.back` drops the floor whenever the
/// stopped step's total did not grow, also when the library was not rebuilt.
@Suite("Review evidence 2: resumed floor")
struct ReviewSecondPassEvidenceTests {
    /// Paused at 30,000 of 50,000 photos in the image step; the user then deletes 5,000 photos
    /// that were already analysed (a clean-up). Back at step 4: 25,000 of 45,000. Same work
    /// left (20,000), nothing stale, but the total shrank, so the floor is dropped and the
    /// card falls from 56 % to 53 % (glide reset, so the drawn bar falls too).
    @Test func deletedPhotosDoNotTakeTheValueBack() {
        let w = StepWidths.standard
        let floor = w.overall(step: .content, completed: 30_000, total: 50_000)
        var run = ResumedRun(stage: 4, shown: floor)
        // Adapted (review of 0305d20): `back` no longer re-spreads the widths.
        run.back(at: 4, completed: 25_000, total: 45_000)
        let real = continued0(w).overall(step: .content, completed: 25_000, total: 45_000)
        let shown = run.shown(running: true, catchingUp: false, overall: real, stopped: nil)
        #expect(shown >= floor - 1e-9, "shown \(shown) after \(floor)")
    }

    /// Paused at 30,000 of 50,000; an app update raises the image analysis version, so all
    /// 50,000 are to be looked at again (same total). More work, not a stale value; the floor is
    /// dropped and the card falls from 56 % to 20 %.
    @Test func moreWorkWithTheSameTotalDoesNotTakeTheValueBack() {
        let w = StepWidths.standard
        let floor = w.overall(step: .content, completed: 30_000, total: 50_000)
        var run = ResumedRun(stage: 4, shown: floor)
        // Adapted (review of 0305d20): `back` no longer re-spreads the widths.
        run.back(at: 4, completed: 0, total: 50_000)
        let real = w.overall(step: .content, completed: 0, total: 50_000)
        let shown = run.shown(running: true, catchingUp: false, overall: real, stopped: nil)
        #expect(shown >= floor - 1e-9, "shown \(shown) after \(floor)")
    }

    private func continued0(_ w: StepWidths) -> StepWidths { w }
}
