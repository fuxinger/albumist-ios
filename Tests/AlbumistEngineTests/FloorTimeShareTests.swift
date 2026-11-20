import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistTestSupport

/// Review of c772325 (evidence of the sixth pass, adopted): a run that goes on from the floor
/// moves visibly or starts a phase of its own, never starts again under the title already
/// shown, and repeated cut-offs while re-reading do not each add their time share. Adapted
/// only where decisions 1-3 of that review changed what is expected (marked "Adapted").
@Suite("A resumed run: time share from the floor")
struct FloorTimeShareTests {
    /// 1. Paused at the end of the text step (only the suggestions left: the floor is at or
    /// next to the 99 % cap). 450 new photos come in: not "much more" (< 500), so no phase,
    /// no new number. The whole image analysis of the new photos runs with the number at
    /// 99 % (or 98 %) and the bar without visible movement: there is no room left above the
    /// floor. Simulator invariant 8 (number or bar move every 10 s) is checked by `finish`.
    @Test func newPhotosAfterAStopAtTheEndStartTheirOwnPhase() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("r6 pause at the end of text", pause: .when(stage: .text, atLeast: 1.0))
        #expect(first.report?.pausedBecause == .userPaused)
        await sim.addPhotos(450)
        let rest = await sim.run("r6 goes on")
        sim.expectComplete(rest)
        // Adapted (decision 1): the number could not move visibly from 98 % to 99 % through the
        // new work, so the run starts a phase of its own, under its own title.
        #expect(sim.phases.map(\.cause) == [.newPhotos])
        let values = sim.shownValues.filter { $0.run == "r6 goes on" }
        // Time with the number at 98 % or more while at least 30 s of work were left.
        let high = values.filter { $0.value >= 0.975 && rest.end - $0.t >= .seconds(30) }
        let span = (high.last?.t ?? .zero) - (high.first?.t ?? .zero)
        print("R6 floor \(sim.shownValues.last { $0.run == "r6 pause at the end of text" }?.value ?? -1), at >= 98 % for \(Int(span.seconds)) s with >= 30 s left, run \(Int((rest.end - rest.start).seconds)) s")
        #expect(span <= .seconds(10), "number at 98-99 % for \(Int(span.seconds)) s while the new photos were analysed")
        sim.finish()
    }

    /// 2. Same at the device's numbers, without the simulator: stopped near the end (floor 0.985,
    /// 30 s left by the estimate then), 450 new photos (not much more). Every 0.25 s tick as in
    /// AppModel.tick. The number must change at least every 10 s while work runs.
    @Test func highFloorWithNewWorkMovesInAPhaseOfItsOwn() {
        var run = ResumedRun(stage: 5, completed: 1_990, shown: 0.985, left: 10, photos: 50_000, seconds: 30)
        let wl = AnalysisWorkload(photos: 50_450, located: 30_000, screenshots: 2_000, contentLeft: 450, textLeft: 10)
        // Library read and trips (20 s, before the workload), then the image step (450 x 0.13 s)
        // and the texts (10 x 0.65 s).
        let catchUp = 20.0, work = 450 * 0.13 + 10 * 0.65
        // Adapted (decision 1): with the time left by the estimate when the workload is known
        // (the image step and the texts), the number could only move from 98.5 % to 99 %: a
        // phase of its own starts, and the card shows the phase's own value (its widths, the
        // step and count of the simulated run) instead of a fixed 70 %.
        let started = run.workload(wl, remaining: work)
        #expect(started)
        #expect(run.newWork == .newPhotos)
        let widths = StepWidths(workload: wl)
        func overall(at t: Double) -> Double {
            if t < catchUp { return widths.overall(step: t < catchUp / 2 ? .library : .trips, completed: Int(t), total: Int(catchUp)) }
            let done = t - catchUp
            if done < 450 * 0.13 { return widths.overall(step: .content, completed: Int(done / 0.13), total: 450) }
            return widths.overall(step: .text, completed: min(10, Int((done - 450 * 0.13) / 0.65)), total: 10)
        }
        var t = 0.0, lastPercent = -1, lastChange = 0.0, longest = 0.0
        while t < catchUp + work {
            t += 0.25
            let remaining: Double? = t < catchUp ? nil : (catchUp + work - t)
            run.spend(active: t, remaining: remaining)
            let p = AnalysisPercent.percent(run.shown(running: true, catchingUp: false, overall: overall(at: t), stopped: nil), isComplete: false)
            if p != lastPercent { longest = max(longest, t - lastChange); lastChange = t; lastPercent = p }
        }
        longest = max(longest, t - lastChange)
        #expect(longest <= 10, "number stood at \(lastPercent) % for \(Int(longest)) s of \(Int(catchUp + work)) s of work")
    }

    /// 3. A phase "Neue Fotos werden analysiert" is paused; more photos come in; the run that
    /// goes on starts a phase again: under the title it already showed, the number starts
    /// again (decision C: only together with a new title). Simulator invariant 3 via `finish`.
    @Test func morePhotosGoOnUnderTheTitleAlreadyShown() async throws {
        let sim = try Sim(scale: 0.2)
        _ = await sim.run("r6 pause in text", pause: .when(stage: .text, atLeast: 0.5))
        await sim.addPhotos(800)
        let phase = await sim.run("r6 phase paused", pause: .when(stage: .content, atLeast: 0.9))
        #expect(phase.report?.pausedBecause == .userPaused)
        #expect(sim.phases.count == 1)
        await sim.addPhotos(1_500)
        let rest = await sim.run("r6 more photos")
        sim.expectComplete(rest)
        // Adapted (decision 2): the run already shows "Neue Fotos werden analysiert" and its
        // number can still move visibly through the new work: no second phase, it goes on
        // from its value under that title.
        #expect(sim.phases.count == 1)
        let before = sim.shownValues.last { $0.run == "r6 phase paused" }?.value ?? 0
        let after = sim.shownValues.first { $0.run == "r6 more photos" && $0.value < before - 0.01 }
        #expect(after == nil, "\"Neue Fotos werden analysiert\" \(Int(before * 100)) % then \(Int((after?.value ?? 0) * 100)) % under the same title")
        sim.finish()
    }

    /// Decision 2: a phase "Neue Fotos werden analysiert" paused at the end of its texts, at
    /// 98-99 %; 450 more photos come in. Its number cannot move visibly through them, so a
    /// phase starts again, under another title ("Weitere neue Fotos werden analysiert"), and
    /// the simulator's card holds every invariant (3: the number starts again only with a new
    /// title; 8: something moves every 10 s).
    @Test func morePhotosAtTheEndOfAPhaseStartOneUnderAnotherTitle() async throws {
        let sim = try Sim(scale: 0.2)
        _ = await sim.run("r6c pause in text", pause: .when(stage: .text, atLeast: 0.5))
        await sim.addPhotos(800)
        let phase = await sim.run("r6c phase paused at its end", pause: .when(stage: .text, atLeast: 1.0))
        #expect(phase.report?.pausedBecause == .userPaused)
        await sim.addPhotos(450)
        let rest = await sim.run("r6c more photos")
        sim.expectComplete(rest)
        print("R6c phase paused at \(sim.shownValues.last { $0.run == "r6c phase paused at its end" }?.value ?? -1), still \(Int(sim.longestStill("r6c more photos").seconds)) s")
        #expect(sim.phases.map(\.cause) == [.newPhotos, .moreNewPhotos])
        #expect(sim.longestStill("r6c more photos") <= .seconds(10))
        sim.finish()
    }

    /// 4. Doubt (1) of the author, carried over restarts: a run cut off while it re-reads the
    /// library (before the workload, the marker's time left stays the one of the stop) writes
    /// the moved value as the next floor. Ten such cut-offs of 40 s each, no work done past
    /// the stop: the number rose from 37 % to over 50 %.
    @Test func cutOffsWhileReReadingAddOneRunsTimeShare() {
        var floor = 0.37
        let secondsThen = 1_000.0
        // Adapted (decision 3): the marker also carries how long the runs before re-read
        // (`caughtUp`), as AppModel.receive writes it while the value is held.
        var caughtUp: Double?
        var floors: [Double] = []
        for _ in 0..<10 {
            var run = ResumedRun(stage: 4, completed: 18_000, shown: floor, left: 21_000, photos: 50_000, seconds: secondsThen,
                                 caughtUp: caughtUp)
            var t = 0.0
            while t < 40 { t += 0.25; run.spend(active: t, remaining: nil) }
            // AppModel.receive: the marker keeps the stopped position with the value shown now
            // and the carried time left.
            floor = run.shown(running: true, catchingUp: true, overall: 0.05, stopped: nil)
            caughtUp = run.caughtUp
            floors.append(floor)
        }
        // Adapted (decision 3, the bound): one run's time share (37 % -> 39.4 % in 40 s), then
        // the visible pace for the nine runs that re-read what the first one already did:
        // 9 x 40 s x 0.025 % per s = 9 %, so at most 48.4 %. Each cut-off still moves the
        // number visibly (never stands still) and never lower (no fall on the next start).
        let first = 0.37 + (AnalysisPercent.cap - 0.37) * (1 - exp(-40 / secondsThen))
        let bound = first + 9 * 40 * ResumedRun.visiblePace
        #expect(floor <= bound + 1e-6, "after ten cut-offs while re-reading, with nothing done past the stop: \(Int(floor * 100)) %")
        #expect(floor < 0.485)
        for (a, b) in zip([0.37] + floors, floors) {
            #expect(b - a >= 0.002 * 4 - 1e-6, "a cut-off run of 40 s moved \(b - a)")
        }
    }

    /// 5. The adopted test 2 (ResumedRunNeverStandsStillTests) measures the value "exactly at
    /// the floor" (1e-9): a value creeping by 0.0001 passes. Measured here on what the card
    /// shows (whole percent), and with the simulator's own invariants (`finish`).
    @Test func fewNewPhotosMoveTheNumberOnWholePercent() async throws {
        let sim = try Sim(scale: 0.2)
        _ = await sim.run("r6b pause in text", pause: .when(stage: .text, atLeast: 0.5))
        await sim.addPhotos(450)
        let rest = await sim.run("r6b goes on")
        sim.expectComplete(rest)
        var longest: Duration = .zero, from: Duration?, last: Int?
        for v in sim.shownValues where v.run == "r6b goes on" {
            let p = AnalysisPercent.percent(v.value, isComplete: false)
            if p == last { longest = max(longest, v.t - from!) } else { from = v.t; last = p }
        }
        print("R6b longest at one percent: \(Int(longest.seconds)) s")
        #expect(longest <= .seconds(10), "number stood at one percent for \(Int(longest.seconds)) s")
        sim.finish()
    }
}
