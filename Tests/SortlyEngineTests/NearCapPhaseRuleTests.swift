import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore

/// Review of ee36188 (evidence of the seventh pass, adopted, large libraries the simulator's
/// small ones missed): the pace rule starts a phase only near the cap and only for new work;
/// update after update alternates its titles. Adapted only where decision 3 of that review
/// changed what is expected (marked "Adapted").
@Suite("A resumed run: the pace rule only near the cap")
struct NearCapPhaseRuleTests {
    /// The time left as AppModel.tick computes it when the workload arrives: the estimator is
    /// at the end of the trips step, the workload just set (`estimatedRemaining`).
    static func remainingAtWorkload(_ wl: AnalysisWorkload) -> Double {
        var estimator = ProgressEstimator()
        let start = ContinuousClock.now
        estimator.record(step: .library, completed: wl.photos, total: wl.photos, at: start)
        estimator.record(step: .trips, completed: 0, total: wl.located, at: start.advanced(by: .seconds(20)))
        estimator.record(step: .trips, completed: wl.located, total: wl.located, at: start.advanced(by: .seconds(24)))
        estimator.setWorkload(wl)
        let d = estimator.estimatedRemaining!.components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    /// 1. A 50,000-photo library paused in the image step at 37 % with 20,000 photos and
    /// 2,000 screenshots left. ONE new photo comes in. The rule "new work whatever its size,
    /// when (99 % - value) / time left < 0.25 % per 10 s" holds for every long analysis (0.62
    /// over about 5,000 s is 0.12 % per 10 s), so the run starts a phase "Neue Fotos werden
    /// analysiert" and the number falls from 37 % to the phase's own start, for one photo.
    /// Without the new photo the same run goes on from 37 %.
    @Test func oneNewPhotoDoesNotRestartALongAnalysis() {
        let then = 20_000 + 2_000
        let wl = AnalysisWorkload(photos: 50_001, located: 30_000, screenshots: 2_000, contentLeft: 20_001, textLeft: 2_000)
        let remaining = Self.remainingAtWorkload(wl)
        var run = ResumedRun(stage: 4, completed: 30_000, shown: 0.37, left: then, photos: 50_000, seconds: 4_500)
        run.spend(active: 24, remaining: nil)
        let started = run.workload(wl, remaining: remaining)
        let widths = StepWidths(workload: wl)
        let shownAfter = run.shown(running: true, catchingUp: false, overall: widths.overall(step: .trips, completed: 30_000, total: 30_000), stopped: nil)
        #expect(!started, "one new photo: phase \(String(describing: run.newWork)) started, time left \(Int(remaining)) s, number 37 % -> \(Int(shownAfter * 100)) %")
        // Decision 1 (clarified A): it goes on from 37 % by its time share, at least at the
        // honest pace of the work (room over time left), never frozen.
        var t = 24.0
        while t < 624 { t += 0.25; run.spend(active: t, remaining: remaining - (t - 24)) }
        let moved = run.shown(running: true, catchingUp: false, overall: 0.05, stopped: nil)
        #expect(moved - 0.37 >= 0.62 * 600 / remaining * 0.95, "in 600 s from 37 % to \(moved)")
        // The same without the new photo: no phase.
        var same = ResumedRun(stage: 4, completed: 30_000, shown: 0.37, left: then, photos: 50_000, seconds: 4_500)
        let wl0 = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 20_000, textLeft: 2_000)
        let sameStarted = same.workload(wl0, remaining: Self.remainingAtWorkload(wl0))
        #expect(!sameStarted)
    }

    /// 2. The same with an update that changed the analysis version but asks for no photo
    /// again (work left unchanged): "Analyse nach Update" starts and the number falls from 37 %.
    @Test func anUpdateWithoutNewWorkStartsNoPhase() {
        let wl = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 20_000, textLeft: 2_000)
        var run = ResumedRun(stage: 4, completed: 30_000, shown: 0.37, left: 22_000, photos: 50_000, seconds: 4_500, updated: true)
        let started = run.workload(wl, remaining: Self.remainingAtWorkload(wl))
        #expect(!started, "no extra work after the update, yet \(String(describing: run.newWork)) restarted the number")
    }

    /// 3. "Analyse nach Update" paused at 95 %; a second update asks for every photo again
    /// (50,000). There is no other title, so no phase starts: the number has 4 % for hours of
    /// work and stands still (whole percent) far longer than 10 s.
    @Test func updateAfterUpdateNearTheCapStartsUnderAnotherTitle() {
        var run = ResumedRun(stage: 5, completed: 1_000, shown: 0.95, left: 1_000, photos: 50_000, seconds: 500,
                             updated: true, newWork: .afterUpdate)
        let wl = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 50_000, textLeft: 2_000)
        let remaining = Self.remainingAtWorkload(wl)
        let started = run.workload(wl, remaining: remaining)
        // Adapted (decision 3): a second title, "Analyse nach erneutem Update", so a phase of
        // its own starts; the card shows the phase's own honest value (its widths through the
        // image step), not a fixed 10 %.
        #expect(started)
        #expect(run.newWork == .afterUpdateAgain)
        let widths = StepWidths(workload: wl)
        let perPhoto = remaining / Double(wl.contentLeft + wl.textLeft)
        var t = 0.0, last = -1, lastChange = 0.0, longest = 0.0
        while t < 600 {
            t += 0.25
            run.spend(active: t, remaining: remaining - t)
            let overall = widths.overall(step: .content, completed: Int(t / perPhoto), total: wl.contentLeft)
            let p = AnalysisPercent.percent(run.shown(running: true, catchingUp: false, overall: overall, stopped: nil), isComplete: false)
            if p != last { longest = max(longest, t - lastChange); lastChange = t; last = p }
        }
        longest = max(longest, t - lastChange)
        // Adapted (decision 1, clarified A): on a run of hours a whole percent may take longer
        // than 10 s, but no longer than the honest pace of the work gives it (the image step's
        // share of the bar over its time), with a little slack for rounding.
        let honest = 0.01 / (widths.width(of: .content) / (Double(wl.contentLeft) * perPhoto))
        #expect(longest <= max(10, honest * 1.1), "after a second update the number stood at \(last) % for \(Int(longest)) s (honest \(Int(honest)) s per percent, time left \(Int(remaining)) s)")
    }
}
