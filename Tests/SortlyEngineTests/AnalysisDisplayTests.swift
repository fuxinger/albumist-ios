import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore

/// The rules of the analysis card (progress display v3, cases P1–P18 in docs/TEST_PLAN.md).
@Suite("Analysis card: steps, widths, finish time, gliding bar, states")
struct AnalysisDisplayTests {
    typealias Instant = ContinuousClock.Instant
    static let t0 = ContinuousClock.now
    static func at(_ seconds: Double) -> Instant { t0.advanced(by: .seconds(seconds)) }
    static let wall0 = Date(timeIntervalSinceReferenceDate: 815_000_000) // a fixed evening
    static func wall(_ seconds: Double) -> Date { wall0.addingTimeInterval(seconds) }

    /// The owner's library (5,683 photos, 1,600 with a location, 1,040 screenshots), first run.
    static let owner = AnalysisWorkload(photos: 5_683, located: 1_600, screenshots: 1_040, contentLeft: 5_683, textLeft: 1_040)

    /// Feeds `step` at `perSecond` items/s from `from` to `to` seconds, a report every 0.5 s;
    /// returns the last time fed.
    @discardableResult
    static func feed(_ e: inout ProgressEstimator, _ step: AnalysisStep, total: Int, startAt start: Int = 0,
                     perSecond: Double, from: Double, to: Double, every: Double = 0.5) -> Int {
        var t = from
        var completed = start
        while t <= to + 1e-9 {
            completed = min(total, start + Int(perSecond * (t - from)))
            e.record(step: step, completed: completed, total: total, at: at(t))
            t += every
        }
        return completed
    }

    // MARK: Steps and widths

    @Test func sevenStagesMakeSixSteps() {
        #expect(AnalysisStep.count == 6)
        #expect(AnalysisStep(.groups) == .proposals)
        #expect(AnalysisStep(.proposals) == .proposals)
        #expect(AnalysisPipeline.Stage.allCases.map { AnalysisStep($0).number } == [1, 2, 3, 4, 5, 6, 6])
    }

    @Test func standardWidthsWithoutAmounts() {
        let w = StepWidths.standard
        #expect(w.shares == [0.05, 0.03, 0.12, 0.60, 0.12, 0.08])
        #expect(abs(w.start(of: .content) - 0.20) < 1e-9)
        #expect(abs(w.end(of: .proposals) - 1) < 1e-9)
        // Anything stored that does not fit gives the standard.
        #expect(StepWidths(shares: [1, 2]) == .standard)
        #expect(StepWidths(shares: [0, 1, 1, 1, 1, 1]) == .standard)
    }

    /// The widths follow the library's amounts (S6): a library with many screenshots has a wide
    /// text step; every step keeps at least 2 %; the shares add up to 1.
    @Test func widthsFromTheLibrary() {
        let w = StepWidths(workload: Self.owner)
        #expect(abs(w.shares.reduce(0, +) - 1) < 1e-9)
        #expect(w.shares.allSatisfy { $0 >= StepWidths.minimumShare - 1e-9 })
        #expect(w.width(of: .content) > w.width(of: .places))
        #expect(w.width(of: .text) > 0.3, "\(w.shares)")
        let noScreenshots = StepWidths(workload: AnalysisWorkload(photos: 5_000, located: 0, screenshots: 0, contentLeft: 5_000, textLeft: 0))
        #expect(abs(noScreenshots.width(of: .text) - StepWidths.minimumShare) < 1e-9)
        #expect(noScreenshots.width(of: .content) > 0.8)
    }

    /// P8: an empty library still gives six visible segments.
    @Test func emptyLibraryWidths() {
        let w = StepWidths(workload: AnalysisWorkload(photos: 0, located: 0, screenshots: 0, contentLeft: 0, textLeft: 0))
        #expect(abs(w.shares.reduce(0, +) - 1) < 1e-9)
        #expect(w.shares.allSatisfy { $0 >= StepWidths.minimumShare - 1e-9 })
    }

    /// P3: widths are stored with the marker and come back the same after a restart.
    @Test func widthsSurviveAsStored() throws {
        let w = StepWidths(workload: Self.owner)
        let data = try JSONEncoder().encode(w)
        #expect(try JSONDecoder().decode(StepWidths.self, from: data) == w)
    }

    /// One bar for the whole run: never back from one step to the next, full only at the end.
    @Test func overallNeverGoesBackAcrossSteps() {
        let w = StepWidths(workload: Self.owner)
        var last = 0.0
        for step in AnalysisStep.allCases {
            for completed in stride(from: 0, through: 100, by: 10) {
                let v = w.overall(step: step, completed: completed, total: 100)
                #expect(v + 1e-12 >= last)
                last = v
            }
        }
        #expect(abs(last - 1) < 1e-9)
        #expect(w.overall(step: .proposals, completed: 0, total: 0) < 1)
        let fills = w.fills(for: w.overall(step: .content, completed: 50, total: 100))
        #expect(fills[0] == 1 && fills[2] == 1 && abs(fills[3] - 0.5) < 1e-9 && fills[4] == 0)
    }

    // MARK: Finish time (P14)

    @Test func noTimeBeforeThirtySecondsAndTwentyItems() {
        var e = ProgressEstimator()
        e.setWorkload(Self.owner)
        Self.feed(&e, .content, total: 5_683, perSecond: 10, from: 0, to: 29)
        #expect(e.finish(at: Self.at(29), wall: Self.wall(29)) == nil)
        Self.feed(&e, .content, total: 5_683, startAt: 290, perSecond: 10, from: 29.5, to: 31)
        #expect(e.finish(at: Self.at(31), wall: Self.wall(31)) != nil)
        // Slow items: 30 s but only 15 items are not enough.
        var slow = ProgressEstimator()
        slow.setWorkload(Self.owner)
        Self.feed(&slow, .text, total: 1_040, perSecond: 0.4, from: 0, to: 40)
        #expect(slow.finish(at: Self.at(40), wall: Self.wall(40)) == nil)
    }

    /// The whole analysis: the image step at its measured speed plus the text and suggestion
    /// steps at their usual time scaled by this device (here twice as slow as usual).
    @Test func finishCoversTheWholeAnalysis() throws {
        var e = ProgressEstimator()
        e.setWorkload(Self.owner)
        // 5 photos/s instead of the usual 10: the device factor is 2.
        Self.feed(&e, .content, total: 5_683, perSecond: 5, from: 0, to: 60)
        #expect(abs(e.deviceFactor - 2) < 0.1, "\(e.deviceFactor)")
        let remaining = try #require(e.remaining).components.seconds
        let content = Double(5_683 - 300) / 5
        let text = 1_040 * 0.5 * 2
        let proposals = 3 + 5_683 * 0.002
        #expect(abs(Double(remaining) - (content + text + proposals)) < 30, "\(remaining)")
        #expect(try #require(e.stepRemaining).components.seconds == Int64(content.rounded(.down)))
    }

    /// P5, S4: a wait in the middle shows no time, is not counted, and the time settles again.
    @Test func waitingHasNoFinishTimeAndSettlesAgain() {
        var e = ProgressEstimator()
        e.setWorkload(Self.owner)
        let done = Self.feed(&e, .content, total: 5_683, perSecond: 10, from: 0, to: 60)
        guard case .at(let before)? = e.finish(at: Self.at(60), wall: Self.wall(60)) else {
            Issue.record("no time after 60 s")
            return
        }
        e.idle() // waits until the iPhone cools down
        #expect(e.finish(at: Self.at(300), wall: Self.wall(300)) == nil)
        // Goes on 5 min later: needs 30 s and 20 photos again.
        Self.feed(&e, .content, total: 5_683, startAt: done, perSecond: 10, from: 360, to: 380)
        #expect(e.finish(at: Self.at(380), wall: Self.wall(380)) == nil)
        Self.feed(&e, .content, total: 5_683, startAt: done + 200, perSecond: 10, from: 380.5, to: 395)
        guard case .at(let after)? = e.finish(at: Self.at(395), wall: Self.wall(395)) else {
            Issue.record("no time after settling again")
            return
        }
        // The 5 min wait moved the end by about 5 min, not by hours (the wait was not counted
        // as time without photos).
        #expect(abs(after.timeIntervalSince(before) - 300) < 6 * 60, "\(after.timeIntervalSince(before))")
    }

    /// P2: 10 minutes suspended in the background (no reports, no idle call) count as nothing.
    @Test func tenMinutesInTheBackgroundDoNotCount() {
        var e = ProgressEstimator()
        e.setWorkload(Self.owner)
        let done = Self.feed(&e, .content, total: 5_683, perSecond: 10, from: 0, to: 60)
        let rate = e.rate
        // Back after 600 s with 10 more photos: the gap is not active time.
        e.record(step: .content, completed: done + 10, total: 5_683, at: Self.at(660))
        #expect(e.rate == nil, "settles again")
        #expect(e.finish(at: Self.at(660), wall: Self.wall(660)) == nil)
        Self.feed(&e, .content, total: 5_683, startAt: done + 10, perSecond: 10, from: 660.5, to: 700)
        #expect(abs((e.rate ?? 0) - (rate ?? -1)) < 0.5, "\(String(describing: e.rate)) vs \(String(describing: rate))")
    }

    /// P5: the device warms up and gets slower: the time moves later, but only by 2 min or more,
    /// and at most every 15 s.
    @Test func speedChangeMovesTheTimeOnlyPastTheHysteresis() {
        var e = ProgressEstimator()
        e.setWorkload(AnalysisWorkload(photos: 2_000, located: 0, screenshots: 0, contentLeft: 2_000, textLeft: 0))
        var completed = Self.feed(&e, .content, total: 2_000, perSecond: 10, from: 0, to: 40)
        guard case .at(let first)? = e.finish(at: Self.at(40), wall: Self.wall(40)) else {
            Issue.record("no time")
            return
        }
        // A little slower: 9.5/s changes the end by less than 2 min, the time stays.
        completed = Self.feed(&e, .content, total: 2_000, startAt: completed, perSecond: 9.5, from: 40.5, to: 60)
        #expect(e.finish(at: Self.at(60), wall: Self.wall(60)) == .at(first))
        // Gentle (half speed) for a while: the end moves by minutes, so the time moves.
        completed = Self.feed(&e, .content, total: 2_000, startAt: completed, perSecond: 5, from: 60.5, to: 140)
        guard case .at(let later)? = e.finish(at: Self.at(140), wall: Self.wall(140)) else {
            Issue.record("no time")
            return
        }
        #expect(later.timeIntervalSince(first) >= 120)
        // Within 15 s of the last check nothing is recomputed.
        _ = Self.feed(&e, .content, total: 2_000, startAt: completed, perSecond: 1, from: 140.5, to: 150)
        #expect(e.finish(at: Self.at(150), wall: Self.wall(150)) == .at(later))
    }

    /// Waits for Apple's geocoder are not measured: the speed after them is the speed of the
    /// lookups, and a time shown before stays during the wait.
    @Test func appleWaitIsNotMeasured() {
        var e = ProgressEstimator()
        // Images and texts done already: the places step's own speed is enough for a time.
        e.setWorkload(AnalysisWorkload(photos: 5_683, located: 1_600, screenshots: 1_040, contentLeft: 0, textLeft: 0))
        let done = Self.feed(&e, .places, total: 1_600, perSecond: 5, from: 0, to: 40)
        let shown = e.finish(at: Self.at(40), wall: Self.wall(40))
        #expect(shown != nil)
        let rate = e.rate
        // 30 s of waiting for Apple, reported every 2 s with the same count.
        for t in stride(from: 42.0, through: 72, by: 2) {
            e.record(step: .places, completed: done, total: 1_600, at: Self.at(t), appleWait: true)
        }
        #expect(e.rate == nil)
        #expect(e.finish(at: Self.at(72), wall: Self.wall(72)) == shown)
        Self.feed(&e, .places, total: 1_600, startAt: done, perSecond: 5, from: 72.5, to: 110)
        #expect(abs((e.rate ?? 0) - (rate ?? -1)) < 0.5, "the wait did not lower the speed: \(String(describing: e.rate))")
    }

    /// Review I4: no finish time before this device's speed is known (an image or text step
    /// measured). The places step's speed says nothing about it; the usual times are a guess.
    @Test func noFinishTimeBeforeTheDeviceIsMeasured() {
        var e = ProgressEstimator()
        e.setWorkload(Self.owner)
        Self.feed(&e, .places, total: 1_600, perSecond: 5, from: 0, to: 60)
        #expect(e.rate != nil)
        #expect(e.stepRemaining != nil, "the step's own time is known (Details)")
        #expect(e.finish(at: Self.at(60), wall: Self.wall(60)) == nil)
        #expect(!e.deviceKnown)
        // Once the image step is measured, there is one.
        Self.feed(&e, .content, total: 5_683, perSecond: 10, from: 61, to: 100)
        #expect(e.deviceKnown)
        #expect(e.finish(at: Self.at(100), wall: Self.wall(100)) != nil)
        // Nothing left that depends on the device: the step's own speed is enough.
        var rest = ProgressEstimator()
        rest.setWorkload(AnalysisWorkload(photos: 5_683, located: 1_600, screenshots: 0, contentLeft: 0, textLeft: 0))
        Self.feed(&rest, .places, total: 1_600, perSecond: 5, from: 0, to: 60)
        #expect(rest.finish(at: Self.at(60), wall: Self.wall(60)) != nil)
    }

    /// Review minor: once the time shown has passed while the run goes on, it is not kept for
    /// the refresh or the hysteresis; without a new one, "Gleich fertig" lasts a minute at most.
    @Test func gleichFertigDoesNotLinger() {
        var e = ProgressEstimator()
        e.setWorkload(AnalysisWorkload(photos: 600, located: 0, screenshots: 0, contentLeft: 600, textLeft: 0))
        // 10/s: 400 done at 40 s, the time shown is about 64 s. Then 2/s: the real end is
        // about 144 s, so the time shown passes while the run goes on, and the new ones are
        // within the 2 min hysteresis of it. A time is shown all the way, not a "Gleich
        // fertig" kept from the passed one (which would end after a minute, with none).
        Self.feed(&e, .content, total: 600, perSecond: 10, from: 0, to: 40)
        #expect(e.finish(at: Self.at(40), wall: Self.wall(40)) != nil)
        var t = 40.5
        while t < 139 {
            e.record(step: .content, completed: 400 + Int((t - 40) * 2), total: 600, at: Self.at(t))
            #expect(e.finish(at: Self.at(t), wall: Self.wall(t)) != nil, "no time at \(t) s")
            t += 0.5
        }
        // A step without a count after the time passed: "Gleich fertig" for a minute, then none.
        var s = ProgressEstimator()
        s.setWorkload(AnalysisWorkload(photos: 600, located: 0, screenshots: 0, contentLeft: 600, textLeft: 0))
        Self.feed(&s, .content, total: 600, perSecond: 10, from: 0, to: 59)
        #expect(s.finish(at: Self.at(59), wall: Self.wall(59)) != nil)
        s.record(step: .proposals, completed: 0, total: 0, at: Self.at(60))
        for t in stride(from: 60.5, through: 300, by: 0.5) {
            s.record(step: .proposals, completed: 0, total: 0, at: Self.at(t))
        }
        #expect(s.finish(at: Self.at(300), wall: Self.wall(300)) == nil)
    }

    @Test func roundingAndSoon() {
        let rules = ProgressEstimator.Rules()
        let wall = Date(timeIntervalSinceReferenceDate: 3_600 * 1_000) // whole hour
        // More than 30 min: to 5 minutes.
        #expect(ProgressEstimator.display(wall.addingTimeInterval(47 * 60 + 40), wall: wall, rules: rules)
                == .at(wall.addingTimeInterval(50 * 60)))
        #expect(ProgressEstimator.display(wall.addingTimeInterval(41 * 60), wall: wall, rules: rules)
                == .at(wall.addingTimeInterval(40 * 60)))
        // Up to 30 min: to the minute.
        #expect(ProgressEstimator.display(wall.addingTimeInterval(12 * 60 + 20), wall: wall, rules: rules)
                == .at(wall.addingTimeInterval(12 * 60)))
        // Under a minute: "Gleich fertig", also once the time is past.
        #expect(ProgressEstimator.display(wall.addingTimeInterval(50), wall: wall, rules: rules) == .soon)
        #expect(ProgressEstimator.display(wall.addingTimeInterval(-30), wall: wall, rules: rules) == .soon)
    }

    @Test func dayOfFinish() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 22, minute: 55))!
        let at2340 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 23, minute: 40))!
        let at0710 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7, minute: 10))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9))!
        let nextWeek = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9))!
        #expect(FinishEstimate.day(of: at2340, now: evening, calendar: calendar) == .today)
        #expect(FinishEstimate.day(of: at0710, now: evening, calendar: calendar) == .tomorrow)
        #expect(FinishEstimate.day(of: tuesday, now: evening, calendar: calendar) == .weekday)
        #expect(FinishEstimate.day(of: nextWeek, now: evening, calendar: calendar) == .date)
    }

    /// Steps without a count (trips, suggestions) keep the time shown before.
    @Test func stepsWithoutACountKeepTheTime() {
        var e = ProgressEstimator()
        e.setWorkload(AnalysisWorkload(photos: 600, located: 0, screenshots: 0, contentLeft: 600, textLeft: 0))
        Self.feed(&e, .content, total: 600, perSecond: 10, from: 0, to: 59)
        let shown = e.finish(at: Self.at(59), wall: Self.wall(59))
        #expect(shown != nil)
        e.record(step: .proposals, completed: 0, total: 0, at: Self.at(60))
        #expect(e.finish(at: Self.at(61), wall: Self.wall(61)) == shown)
    }

    /// P9: 50,000 photos over 5,000 s with a report every 0.25 s: the samples stay within the
    /// window (no growing memory), and the time is right within 2 min all the way.
    @Test func fiftyThousandPhotosStayBoundedAndAccurate() {
        let total = 50_000
        var e = ProgressEstimator()
        e.setWorkload(AnalysisWorkload(photos: total, located: 0, screenshots: 0, contentLeft: total, textLeft: 0))
        var t = 0.0
        var worst = 0.0
        while t < 5_000 {
            e.record(step: .content, completed: Int(t * 10), total: total, at: Self.at(t))
            if case .at(let end)? = e.finish(at: Self.at(t), wall: Self.wall(t)) {
                let real = Self.wall(5_000 + 3 + Double(total) * 0.002)
                worst = max(worst, abs(end.timeIntervalSince(real)))
            }
            t += 0.25
        }
        #expect((e.running?.samples.count ?? 0) <= 250)
        #expect(worst <= 5 * 60, "worst \(worst) s") // rounded to 5 min while more than 30 min left
    }

    // MARK: Gliding bar (P4, P15)

    @Test func glideNeverBackNeverAheadMoreThanOnePercent() {
        let w = StepWidths.standard
        var g = BarGlide()
        let total = 1_000
        // 10 photos/s; a real report only every 3 s.
        var shown = 0.0
        var t = 0.0
        while t < 60 {
            let completed = Int(t * 10)
            let real = w.overall(step: .content, completed: completed, total: total)
            if Int(t * 100) % 300 == 0 {
                g.update(real: real, at: Self.at(t), step: .content, widths: w, itemsPerSecond: 10, total: total)
            }
            let v = g.value(at: Self.at(t), gliding: true)
            #expect(v + 1e-12 >= shown, "went back at \(t)")
            #expect(v <= g.real + BarGlide.maxLead * w.width(of: .content) + 1e-12, "ahead at \(t)")
            shown = v
            t += 1.0 / 15
        }
        // The real progress was faster than the cap: the bar moved between reports.
        #expect(shown > w.start(of: .content))
        // A slower real value later does not pull it back.
        g.update(real: w.overall(step: .content, completed: 1, total: total), at: Self.at(61), step: .content, widths: w, itemsPerSecond: 10, total: total)
        #expect(g.value(at: Self.at(61), gliding: true) >= shown)
    }

    @Test func glideStopsWhenNotGliding() {
        let w = StepWidths.standard
        var g = BarGlide()
        g.update(real: 0.3, at: Self.at(0), step: .content, widths: w, itemsPerSecond: 100, total: 1_000)
        #expect(g.value(at: Self.at(5), gliding: false) == 0.3)
        // Never past the end of the step either.
        g.update(real: w.end(of: .content) - 0.001, at: Self.at(6), step: .content, widths: w, itemsPerSecond: 100, total: 1_000)
        #expect(g.value(at: Self.at(100), gliding: true) <= w.end(of: .content) + 1e-12)
        // Without a measured speed it shows the real value.
        var still = BarGlide()
        still.update(real: 0.4, at: Self.at(0), step: .text, widths: w, itemsPerSecond: nil, total: 100)
        #expect(still.value(at: Self.at(10), gliding: true) == 0.4)
    }

    /// Review minor: a run that goes on with the same analysis starts from the bar drawn
    /// last, not from the real value below it (the glided lead was lost: a step back).
    @Test func glideGoesOnFromTheBarDrawnLast() {
        let w = StepWidths.standard
        var g = BarGlide()
        g.update(real: 0.30, at: Self.at(0), step: .content, widths: w, itemsPerSecond: 100, total: 10_000)
        let drawn = g.value(at: Self.at(10), gliding: true)
        #expect(drawn > 0.30)
        var next = BarGlide()
        next.reset(keeping: drawn)
        next.update(real: 0.30, at: Self.at(20), step: .content, widths: w, itemsPerSecond: nil, total: 10_000)
        #expect(next.value(at: Self.at(20), gliding: false) == drawn)
        // A plain reset (new widths, a new analysis) starts at the real value.
        next.reset()
        next.update(real: 0.04, at: Self.at(21), step: .places, widths: w, itemsPerSecond: nil, total: 100)
        #expect(next.value(at: Self.at(21), gliding: true) == 0.04)
    }

    /// Stress run 43833158673: an analysis stopped at 64 % (step 4) went on after 50,000 photos
    /// had come in. Back at step 4 the real value was 38 % ("0 von 50.246"): the card fell from
    /// 64 % to 38 %, and the bar stood still until the real value passed 64 %. With the widths
    /// that continue it, the value starts at 64 % and moves with every photo up to 100 %.
    @Test func resumedAnalysisNeverGoesBackAndMovesOn() throws {
        let w = StepWidths.standard
        let held = 0.64
        let total = 50_246
        #expect(w.overall(step: .content, completed: 0, total: total) < held)
        let c = try #require(w.continuing(held: held, step: .content, completed: 0, total: total))
        #expect(abs(c.shares.reduce(0, +) - 1) < 1e-9)
        #expect(c.shares.allSatisfy { $0 > 0 })
        // Starts where the earlier run stood: not back, not ahead.
        #expect(abs(c.overall(step: .content, completed: 0, total: total) - held) < 1e-9)
        // Every photo moves it; never down; 100 % at the end.
        var last = held - 1e-9
        for done in stride(from: 0, through: total, by: 997) {
            let v = c.overall(step: .content, completed: done, total: total)
            #expect(v >= last, "back at \(done)")
            last = v
        }
        let tenth = c.overall(step: .content, completed: total / 10, total: total)
        #expect(tenth > held + 0.005, "the bar stands still")
        #expect(abs(c.overall(step: .proposals, completed: 1, total: 1) - 1) < 1e-9)
        // The later steps keep their proportions to each other.
        #expect(abs(c.width(of: .text) / c.width(of: .proposals) - w.width(of: .text) / w.width(of: .proposals)) < 1e-9)
        // Nothing to change when the real value is not below what was shown.
        #expect(c.continuing(held: held, step: .content, completed: 0, total: total) == nil)
        #expect(w.continuing(held: 0.15, step: .content, completed: 0, total: total) == nil)
        #expect(w.continuing(held: 1, step: .content, completed: 0, total: total) == nil)
    }

    /// The same in the middle of a step, and twice in a row (paused again, more photos again):
    /// each time the value goes on from where it stood.
    @Test func resumedTwiceStillNeverGoesBack() throws {
        var w = StepWidths(workload: Self.owner)
        var shown = w.overall(step: .content, completed: 4_000, total: 5_683)
        // 10,000 photos more, run goes on at 4,000 of 15,683.
        w = try #require(w.continuing(held: shown, step: .content, completed: 4_000, total: 15_683))
        #expect(abs(w.overall(step: .content, completed: 4_000, total: 15_683) - shown) < 1e-9)
        shown = w.overall(step: .content, completed: 6_000, total: 15_683)
        // Paused at 6,000; 30,000 more photos came in.
        w = try #require(w.continuing(held: shown, step: .content, completed: 6_000, total: 45_683))
        #expect(abs(w.overall(step: .content, completed: 6_000, total: 45_683) - shown) < 1e-9)
        #expect(w.overall(step: .content, completed: 6_500, total: 45_683) > shown)
        #expect(w.shares.allSatisfy { $0 > 0 })
    }

    /// Review of d612bc0 (1): a run that goes on at 64 % is paused while it reads the library.
    /// The paused card said "3 %" (where the read stood) or "0 %" (nothing reported yet)
    /// while the bar stayed at 64 %. It keeps the value it went on from.
    @Test func pausedWhileCatchingUpKeepsTheValue() {
        let w = StepWidths.standard
        let run = ResumedRun(stage: 4, shown: 0.64)
        #expect(run.isCatchingUp(running: true, at: 1))
        #expect(!run.isCatchingUp(running: false, at: nil))
        let readSoFar = w.overall(step: .library, completed: 30_000, total: 50_246)
        #expect(run.shown(running: true, catchingUp: true, overall: readSoFar, stopped: nil) == 0.64)
        #expect(run.shown(running: false, catchingUp: false, overall: 0, stopped: readSoFar) == 0.64)
        #expect(run.shown(running: false, catchingUp: false, overall: 0, stopped: nil) == 0.64)
    }

    /// Review of 9f0bc40 (A): a marker belongs to the database it was written for. A new or
    /// restored empty database (the database folder is not in the device backup, UserDefaults
    /// are) ignores an old marker; a marker without a stamp (older version) counts only for a
    /// database that has photos.
    @Test func markerBelongsToItsDatabase() {
        #expect(ResumedRun.markerApplies(markerDatabase: "A", database: "A", databaseHasPhotos: true))
        #expect(!ResumedRun.markerApplies(markerDatabase: "A", database: "B", databaseHasPhotos: true))
        #expect(!ResumedRun.markerApplies(markerDatabase: "A", database: "B", databaseHasPhotos: false))
        #expect(ResumedRun.markerApplies(markerDatabase: nil, database: "B", databaseHasPhotos: true))
        #expect(!ResumedRun.markerApplies(markerDatabase: nil, database: "B", databaseHasPhotos: false))
    }

    /// Review of 9f0bc40 (A), cases 1–3: with the marker bound to its database, a real value
    /// below the floor is always more work than before. The run goes on from the floor and
    /// moves with the time it works (review of 0305d20: the time share, not a re-spread):
    /// photos deleted (1), more work with the same total (2), and a first read that was cut
    /// off in step 1 (3).
    @Test(arguments: [
        (stoppedStage: 4, step: AnalysisStep.content, completed: 25_000, total: 45_000, stopAt: 30_000, stopOf: 50_000),
        (stoppedStage: 4, step: AnalysisStep.content, completed: 0, total: 50_000, stopAt: 30_000, stopOf: 50_000),
        (stoppedStage: 1, step: AnalysisStep.library, completed: 0, total: 50_000, stopAt: 40_000, stopOf: 50_000),
    ])
    func moreWorkGoesOnFromTheFloor(c: (stoppedStage: Int, step: AnalysisStep, completed: Int, total: Int, stopAt: Int, stopOf: Int)) {
        let w = StepWidths.standard
        let floor = w.overall(step: c.step, completed: c.stopAt, total: c.stopOf)
        var run = ResumedRun(stage: c.stoppedStage, shown: floor)
        let atStart = run.shown(running: true, catchingUp: false, overall: w.overall(step: c.step, completed: c.completed, total: c.total), stopped: nil)
        #expect(abs(atStart - floor) < 1e-9)
        // Two photos a second (the usual 0.5 s): the time left is what the step has left.
        let perSecond = 2.0
        var last = floor - 1e-9
        var values: Set<Int> = []
        for done in stride(from: c.completed, through: c.total, by: max(1, (c.total - c.completed) / 50)) {
            run.spend(active: Double(done - c.completed) / perSecond, remaining: Double(c.total - done) / perSecond)
            run.back(at: c.stoppedStage, completed: done, total: c.total)
            let v = run.shown(running: true, catchingUp: false, overall: w.overall(step: c.step, completed: done, total: c.total), stopped: nil)
            #expect(v >= last, "back at \(done): \(v) after \(last)")
            #expect(v <= AnalysisPercent.cap)
            last = v
            values.insert(Int((v * 1_000).rounded()))
        }
        #expect(values.count > 20, "stands still: \(values.sorted())")
        // At the end of the work it reads 99 %, not before 100 %.
        #expect(last > AnalysisPercent.cap - 0.01)
        // Paused there: the value it showed, not lower.
        #expect(run.shown(running: false, catchingUp: false, overall: 0, stopped: 0.1) >= last)
    }

    /// Back once, when the run passes where it stopped; nothing re-spread (review of 0305d20);
    /// the real value shows once it is ahead.
    @Test func backOnceAndTheRealValueWhenAhead() {
        var run = ResumedRun(stage: 4, completed: 2_000, shown: 0.64)
        let b101 = run.back(at: 4, completed: 1_999, total: 50_246)
        #expect(!b101)
        let b102 = run.back(at: 4, completed: 2_000, total: 50_246)
        #expect(b102)
        let b103 = run.back(at: 5, completed: 0, total: 900)
        #expect(!b103)
        #expect(run.shown(running: true, catchingUp: false, overall: 0.3, stopped: nil) == 0.64)
        var ahead = ResumedRun(stage: 4, shown: 0.30)
        let b104 = ahead.back(at: 4, completed: 4_000, total: 5_000)
        #expect(b104)
        #expect(ahead.shown(running: true, catchingUp: false, overall: 0.7, stopped: nil) == 0.7)
    }

    // MARK: A run that goes on (reviews of 83db832 and 11ef3e1)

    /// "Much more work": more than 1.5 times the work left when the run stopped, and at least
    /// 500 photos more. Both have to hold.
    @Test func muchMoreWorkHasAClearThreshold() {
        #expect(ResumedRun.isMuchMore(3_001, than: 2_000))
        #expect(!ResumedRun.isMuchMore(3_000, than: 2_000))      // exactly 1.5 times
        #expect(!ResumedRun.isMuchMore(700, than: 300))          // 2.3 times, but only 400 more
        #expect(ResumedRun.isMuchMore(800, than: 300))
        #expect(ResumedRun.isMuchMore(500, than: 0))             // stopped with nothing left
        #expect(!ResumedRun.isMuchMore(499, than: 0))
    }

    /// The work a marker keeps: photos still to look at and screenshots still to read.
    @Test func markerKeepsTheWorkLeft() {
        let w = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 40_000, textLeft: 1_500)
        #expect(w.heavyLeft(at: .places, completed: 10, total: 30_000) == 41_500)
        #expect(w.heavyLeft(at: .content, completed: 30_000, total: 40_000) == 11_500)
        #expect(w.heavyLeft(at: .text, completed: 1_000, total: 1_500) == 500)
        #expect(w.heavyLeft(at: .proposals, completed: 0, total: 0) == 0)
    }

    /// Label "Neue Fotos werden analysiert": stopped in the text step at 90 % with 2,000
    /// screenshots left; 10,000 photos came in. No label while the value is held (review of
    /// 0305d20); the workload starts the phase and its label together: its own honest value
    /// from its own start, under a title that was not there before, never back within the
    /// phase, never 100 % before the end. A few new photos start nothing.
    @Test func newPhotosStartTheirOwnPhase() {
        var few = ResumedRun(stage: 5, shown: 0.90, left: 2_000, photos: 50_000)
        let r1 = few.workload(AnalysisWorkload(photos: 50_300, located: 30_000, screenshots: 2_000, contentLeft: 300, textLeft: 2_000))
        #expect(!r1)
        #expect(few.newWork == nil)

        let w = StepWidths.standard
        var run = ResumedRun(stage: 5, shown: 0.90, left: 2_000, photos: 50_000)
        // Held, with the title it had ("Macht da weiter"): no label yet.
        #expect(run.newWork == nil)
        #expect(run.isCatchingUp(running: true, at: 1))
        #expect(run.shown(running: true, catchingUp: true, overall: 0.01, stopped: nil) == 0.90)
        let more = AnalysisWorkload(photos: 60_000, located: 30_000, screenshots: 2_100, contentLeft: 10_000, textLeft: 2_100)
        let r4 = run.workload(more)
        #expect(r4)
        // The label comes with the phase's own number.
        #expect(run.newWork == .newPhotos)
        #expect(run.ownStart)
        #expect(!run.isCatchingUp(running: true, at: 3))
        let b105 = run.back(at: 5, completed: 0, total: 2_100)
        #expect(!b105)
        // The phase's first value, under its new title; from there it never goes back.
        var last = run.shown(running: true, catchingUp: false, overall: w.overall(step: .trips, completed: 0, total: 1), stopped: nil)
        var path: [(AnalysisStep, Int)] = [(.trips, 1), (.places, 30_000), (.content, 10_000), (.text, 2_100)]
        path.append((.proposals, 1))
        for (step, total) in path {
            for done in stride(from: 0, through: total, by: max(1, total / 20)) {
                let v = run.shown(running: true, catchingUp: false, overall: w.overall(step: step, completed: done, total: total), stopped: nil)
                #expect(v >= last, "\(step) \(done): \(v) after \(last)")
                #expect(v <= AnalysisPercent.cap)
                last = v
            }
        }
        // Its own start: the number begins at the phase's real value, not at the floor.
        #expect(run.shown(running: true, catchingUp: false, overall: 0.08, stopped: nil) == 0.08)
        // Paused inside the phase: where it stood, not the old floor.
        #expect(run.shown(running: false, catchingUp: false, overall: 0, stopped: 0.2) == 0.2)
    }

    /// Label "Analyse nach Update": stopped near the end (99.6 %, nothing left), then an update
    /// changed the analysis and asks for every image again. The phase and its label start with
    /// the workload.
    @Test func updateStartsItsOwnPhase() {
        var run = ResumedRun(stage: 7, shown: 0.996, left: 0, photos: 50_000, updated: true)
        #expect(run.newWork == nil)
        #expect(run.isCatchingUp(running: true, at: 1))
        let update = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 50_000, textLeft: 0)
        let r6 = run.workload(update)
        #expect(r6)
        #expect(run.newWork == .afterUpdate)
        let widths = StepWidths(workload: update)
        let atStart = run.shown(running: true, catchingUp: run.isCatchingUp(running: true, at: 2),
                                overall: widths.overall(step: .trips, completed: 1, total: 1), stopped: nil)
        #expect(atStart < 0.1, "its own start: \(atStart)")
        // The same new work without an update says "Neue Fotos".
        var same = ResumedRun(stage: 7, shown: 0.996, left: 0, photos: 50_000)
        let r7 = same.workload(update)
        #expect(r7)
        #expect(same.newWork == .newPhotos)
        // A marker of an older version kept no work left: no phase (it goes on from the floor).
        var old = ResumedRun(stage: 7, shown: 0.996)
        let r8 = old.workload(update)
        #expect(!r8)
    }

    /// Review of 11ef3e1 (minor 1): the library read counts the whole library and every item,
    /// the work left counts the run's part and only what the analysis looks at. Stopped at the
    /// end with nothing left, with "Nur 2026": 600 photos from other years come in by iCloud.
    /// The workload (nothing new in 2026) starts no phase and shows no label.
    @Test func newPhotosOutsideTheScopeStartNoPhase() {
        var run = ResumedRun(stage: 7, completed: 0, shown: 0.98, left: 0, photos: 50_000)
        let in2026 = AnalysisWorkload(photos: 4_000, located: 3_000, screenshots: 100, contentLeft: 0, textLeft: 0)
        let r2 = run.workload(in2026)
        #expect(!r2)
        #expect(run.newWork == nil)
        #expect(!run.ownStart)
        #expect(run.shown(running: true, catchingUp: true, overall: 0.1, stopped: nil) == 0.98)
    }

    /// The same with 600 items the analysis does not look at (as the workload counts them): no
    /// phase, and the label of a phase the stopped run was in stays.
    @Test func newItemsTheAnalysisDoesNotLookAtStartNoPhase() {
        var run = ResumedRun(stage: 7, completed: 0, shown: 0.98, left: 0, photos: 50_000)
        let same = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: 0, textLeft: 0)
        let r2 = run.workload(same)
        #expect(!r2)
        #expect(run.newWork == nil)
        var inPhase = ResumedRun(stage: 7, completed: 0, shown: 0.6, left: 0, photos: 50_000, newWork: .afterUpdate)
        let r4 = inPhase.workload(same)
        #expect(!r4)
        #expect(inPhase.newWork == .afterUpdate)
    }

    /// Review of 11ef3e1 (IMPORTANT), with the time share of the review of 0305d20: stopped at
    /// 30,000 of 50,000 in the image step; nothing changed. The re-counted steps (library,
    /// trips, places) take 60 s of the run's time, the 20,000 photos left about 2,000 s. The
    /// value moves from the floor all the time, and back at photo 30,000 it reads barely above
    /// the value it was paused at (the 60 s): the work done before the stop is not counted
    /// again (11ef3e1 read 78-80 % there). From there it moves to 99 % with the work.
    @Test func backWhereItStoppedReadsAboutTheFloor() {
        let w = StepWidths.standard
        let floor = w.overall(step: .content, completed: 30_000, total: 50_000)
        var run = ResumedRun(stage: 4, completed: 30_000, shown: floor, left: 21_000, photos: 50_000, seconds: 2_000)
        var last = floor
        var values: Set<Int> = []
        for second in stride(from: 1.0, through: 60, by: 1) {
            run.spend(active: second, remaining: 2_000)
            let v = run.shown(running: true, catchingUp: true, overall: 0.1 * second / 60, stopped: nil)
            #expect(v >= last)
            last = v
            values.insert(Int((v * 10_000).rounded()))
        }
        #expect(values.count > 30, "stands still while re-counting: \(values.count) values")
        let b106 = run.back(at: 4, completed: 30_000, total: 50_000)
        #expect(b106)
        let atStop = run.shown(running: true, catchingUp: false, overall: floor, stopped: nil)
        #expect(atStop - floor < 0.02, "back at photo 30,000: \(atStop) after \(floor)")
        // On to the end with the work: 10 photos a second.
        for done in stride(from: 30_000, through: 50_000, by: 1_000) {
            run.spend(active: 60 + Double(done - 30_000) / 10, remaining: Double(50_000 - done) / 10)
            let v = run.shown(running: true, catchingUp: false, overall: w.overall(step: .content, completed: done, total: 50_000), stopped: nil)
            #expect(v >= last)
            last = v
        }
        #expect(last > 0.98)
    }

    /// Review of 0305d20 (2, 3): 450 new photos before the step it stopped in (not much more),
    /// or photos deleted so the count starts below where it stopped: the value moves with the
    /// time from the first seconds, also while the count is below the stopped position; a
    /// marker of an older version (no work left kept) moves the same once the time left is known.
    @Test func newOrDeletedPhotosBeforeTheStopDoNotHoldTheValue() {
        for (left, seconds) in [(Int?.some(2_000), Double?.some(1_000)), (nil, nil)] {
            var run = ResumedRun(stage: 5, completed: 500, shown: 0.90, left: left, seconds: seconds)
            let work = AnalysisWorkload(photos: 50_450, located: 30_000, screenshots: 2_000, contentLeft: 450, textLeft: 1_500)
            let r = run.workload(work)
            #expect(!r)
            var last = 0.90
            var changes = 0
            for second in stride(from: 1.0, through: 60, by: 1) {
                run.spend(active: second, remaining: 450 * 0.13 - second + 1_500 * 0.5)
                let b107 = run.back(at: 4, completed: 50_000 + Int(second * 7), total: 50_450)
                #expect(!b107)
                let v = run.shown(running: true, catchingUp: true, overall: 0.5, stopped: nil)
                #expect(v >= last)
                if v > last + 1e-6 { changes += 1 }
                last = v
            }
            #expect(changes >= 55, "value stood still: \(changes) changes in 60 s")
            #expect(last < 0.93, "ran ahead: \(last)")
        }
    }

    /// A marker of an older version kept no count: the run is back when it reaches the stage.
    @Test func olderMarkerIsBackAtItsStage() {
        var run = ResumedRun(stage: 4, shown: 0.5)
        #expect(!run.hasPassed(at: 3, completed: 30_000, total: 30_000))
        #expect(run.hasPassed(at: 4, completed: 0, total: 50_000))
        let b108 = run.back(at: 4, completed: 0, total: 50_000)
        #expect(b108)
        #expect(run.isBack)
    }

    /// Review of 11ef3e1 (minor 2): a run that throws after a complete one has no outcome of
    /// its own, so the details never say 100 % from the earlier report.
    @Test func onlyTheLastRunsOwnOutcomeIsComplete() {
        var outcome = LastRunOutcome()
        var complete = AnalysisPipeline.Report()
        complete.completedStages = AnalysisPipeline.Stage.allCases
        outcome.ended(with: complete)
        #expect(outcome.isComplete(running: false))
        #expect(AnalysisPercent.percent(0.97, isComplete: outcome.isComplete(running: false)) == 100)
        outcome.started()
        #expect(!outcome.isComplete(running: true))
        outcome.ended(with: nil)          // the next run threw
        #expect(!outcome.isComplete(running: false))
        #expect(AnalysisPercent.percent(0.97, isComplete: outcome.isComplete(running: false)) == 97)
        // Review of 0305d20 (5): a background refinement cut off by iOS (no report, or one
        // that paused) leaves a complete analysis complete; a complete one makes it complete.
        var done = LastRunOutcome()
        done.ended(with: complete)
        var cutOff = AnalysisPipeline.Report()
        cutOff.pausedBecause = .timeBudget
        let cutOffClears = done.refined(with: cutOff)
        let nothingClears = done.refined(with: nil)
        #expect(!cutOffClears && !nothingClears)
        #expect(done.isComplete(running: false))
        // Review of c772325 (6): a complete refinement says so, and AppModel clears the marker
        // of the unfinished run and its resume (no "Macht da weiter · 37 %" after 100 %).
        let clears = outcome.refined(with: complete)
        #expect(clears)
        #expect(outcome.isComplete(running: false))
    }

    /// A run that goes on inside a phase keeps the phase's label; its floor is the phase's
    /// value, held as usual.
    @Test func aPhaseKeepsItsLabelWhenItGoesOn() {
        let run = ResumedRun(stage: 4, shown: 0.35, left: 30_000, photos: 60_000, newWork: .newPhotos)
        #expect(run.newWork == .newPhotos)
        #expect(!run.ownStart)
        #expect(run.shown(running: true, catchingUp: true, overall: 0.02, stopped: nil) == 0.35)
    }

    /// Review of c772325 (1): new work the number could not visibly move through (less than
    /// 0.25 % per 10 s from where it stands to 99 % by the time left) starts a phase of its
    /// own, whatever the amount; the same amount with room to move does not.
    @Test func newWorkTooSlowToShowStartsAPhase() {
        let wl = AnalysisWorkload(photos: 50_450, located: 30_000, screenshots: 2_000, contentLeft: 450, textLeft: 10)
        #expect(!ResumedRun.isMuchMore(460, than: 10))
        var high = ResumedRun(stage: 5, completed: 1_990, shown: 0.985, left: 10, photos: 50_000, seconds: 30)
        #expect(ResumedRun.movesTooSlowly(from: 0.985, remaining: 65))
        let highStarts = high.workload(wl, remaining: 65)
        #expect(highStarts && high.newWork == .newPhotos)
        var low = ResumedRun(stage: 5, completed: 1_000, shown: 0.60, left: 10, photos: 50_000, seconds: 30)
        let lowStarts = low.workload(wl, remaining: 65)
        #expect(!lowStarts && low.newWork == nil)
        // No new work (only what was left then): no label, the value goes on from the floor.
        var same = ResumedRun(stage: 5, completed: 1_990, shown: 0.985, left: 460, photos: 50_000, seconds: 30)
        let sameStarts = same.workload(wl, remaining: 65)
        #expect(!sameStarts)
        // Without the estimate, only the amount decides.
        var unknown = ResumedRun(stage: 5, completed: 1_990, shown: 0.985, left: 10, photos: 50_000, seconds: 30)
        let unknownStarts = unknown.workload(wl)
        #expect(!unknownStarts)
    }

    /// Review of c772325 (2): a run that already shows "Neue Fotos werden analysiert" never
    /// starts again under that title. Much more work alone does not restart it; new work it
    /// could not visibly move through starts a phase under "Weitere neue Fotos werden
    /// analysiert" (and after that one, "Neue Fotos werden analysiert" again).
    @Test func aShownPhaseStartsAgainOnlyUnderAnotherTitle() {
        let much = AnalysisWorkload(photos: 52_000, located: 30_000, screenshots: 2_000, contentLeft: 1_600, textLeft: 0)
        var roomy = ResumedRun(stage: 4, completed: 700, shown: 0.63, left: 100, photos: 50_800, newWork: .newPhotos)
        let roomyStarts = roomy.workload(much, remaining: 300)
        #expect(!roomyStarts)
        #expect(roomy.newWork == .newPhotos && !roomy.ownStart)
        var stuck = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, newWork: .newPhotos)
        let stuckStarts = stuck.workload(much, remaining: 300)
        #expect(stuckStarts)
        #expect(stuck.newWork == .moreNewPhotos)
        var again = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, newWork: .moreNewPhotos)
        let againStarts = again.workload(much, remaining: 300)
        #expect(againStarts && again.newWork == .newPhotos)
        // An update phase that cannot move: a new-photos phase may follow it, and another
        // update alternates the update titles (review of ee36188, 3).
        var update = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, updated: false, newWork: .afterUpdate)
        let updateStarts = update.workload(much, remaining: 300)
        #expect(updateStarts && update.newWork == .newPhotos)
        var twice = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, updated: true, newWork: .afterUpdate)
        let twiceStarts = twice.workload(much, remaining: 300)
        #expect(twiceStarts && twice.newWork == .afterUpdateAgain)
        var thrice = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, updated: true, newWork: .afterUpdateAgain)
        let thriceStarts = thrice.workload(much, remaining: 300)
        #expect(thriceStarts && thrice.newWork == .afterUpdate)
        // An update that adds no work starts nothing, also near the cap (review of ee36188, 2).
        var noWork = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 1_600, photos: 50_800, updated: true)
        let noWorkStarts = noWork.workload(much, remaining: 300)
        #expect(!noWorkStarts && noWork.newWork == nil)
    }

    /// Review of c772325 (4): a marker of an older version without the time left moves the
    /// number within 10 s after the update: by the work left then at the usual times, or,
    /// without that either, by the library's photos once the library read counted them.
    @Test func olderMarkerWithoutTimeLeftMovesWithinTenSeconds() {
        func firstMove(_ run: inout ResumedRun, photosAt: Double?) -> Double {
            let start = AnalysisPercent.percent(run.shown(running: true, catchingUp: true, overall: 0.01, stopped: nil), isComplete: false)
            var t = 0.0
            while t < 60 {
                t += 0.25
                if let photosAt, t >= photosAt { run.library(photos: 10_000) }
                run.spend(active: t, remaining: nil)
                let p = AnalysisPercent.percent(run.shown(running: true, catchingUp: true, overall: 0.01, stopped: nil), isComplete: false)
                if p != start { return t }
            }
            return .infinity
        }
        var withLeft = ResumedRun(stage: 4, completed: 3_000, shown: 0.37, left: 6_000, photos: 10_000)
        #expect(withLeft.secondsThen != nil)
        #expect(firstMove(&withLeft, photosAt: nil) <= 10)
        var bare = ResumedRun(stage: 4, shown: 0.37)
        #expect(bare.secondsThen == nil)
        #expect(firstMove(&bare, photosAt: 1) <= 10)
        // Review of ee36188 (4): each step at its own usual rate: screenshots in the text step
        // at 0.5 s, photos before it at the image rate plus their texts' usual share.
        #expect(abs(ResumedRun.usualSeconds(left: 1_000, stage: 5) - (1_000 * 0.5 + 3)) < 1e-9)
        #expect(abs(ResumedRun.usualSeconds(left: 1_000, stage: 4) - (1_000 * 0.1 * 1.2 + 3)) < 1e-9)
        #expect(ResumedRun.usualSeconds(left: 1_000, stage: 7) == 3)
        // A marker that carries the time left keeps it.
        var stamped = ResumedRun(stage: 4, shown: 0.37, left: 6_000, seconds: 900)
        stamped.library(photos: 10_000)
        #expect(stamped.secondsThen == 900)
    }

    /// Never 100 % while work is left: the number, the glide and a floor from 99.6 % stop at
    /// 99 %; 100 % only once the analysis is complete.
    @Test func neverReads100BeforeTheEnd() {
        #expect(AnalysisPercent.percent(0.996, isComplete: false) == 99)
        #expect(AnalysisPercent.percent(1, isComplete: false) == 99)
        #expect(AnalysisPercent.percent(0.42, isComplete: true) == 100)
        let run = ResumedRun(stage: 7, shown: 0.996)
        #expect(run.shown(running: true, catchingUp: true, overall: 0.2, stopped: nil) == AnalysisPercent.cap)
        #expect(run.shown(running: false, catchingUp: false, overall: 0, stopped: nil) == AnalysisPercent.cap)
        let w = StepWidths.standard
        var glide = BarGlide()
        let t0 = ContinuousClock.now
        glide.update(real: w.overall(step: .proposals, completed: 9, total: 10), at: t0, step: .proposals, widths: w,
                     itemsPerSecond: 1, total: 10)
        #expect(glide.value(at: t0 + .seconds(60), gliding: true) <= AnalysisPercent.cap)
        glide.update(real: 1, at: t0 + .seconds(61), step: .proposals, widths: w, itemsPerSecond: 1, total: 10)
        #expect(glide.value(at: t0 + .seconds(62), gliding: true) <= AnalysisPercent.cap)
    }

    // MARK: Card states (P1, P5–P7, P10–P12, P17)

    static func running(_ configure: (inout AnalysisCardState.Inputs) -> Void) -> AnalysisCardState? {
        var i = AnalysisCardState.Inputs()
        i.isRunning = true
        i.runningFor = .seconds(60)
        i.position = .init(step: .content, completed: 2_431, total: 5_683)
        configure(&i)
        return AnalysisCardState.resolve(i)
    }

    @Test func pauseReactsAtOnceAndSaysMoreAfterTenSeconds() {
        let position = AnalysisCardState.Position(step: .content, completed: 2_431, total: 5_683)
        #expect(Self.running { $0.pausingFor = .zero } == .pausing(position, longer: false))
        #expect(Self.running { $0.pausingFor = .seconds(9) } == .pausing(position, longer: false))
        #expect(Self.running { $0.pausingFor = .seconds(10) } == .pausing(position, longer: true))
        // Pausing wins over waiting and over the quick check.
        #expect(Self.running { $0.pausingFor = .zero; $0.waiting = .thermal; $0.isQuickCheck = true } == .pausing(position, longer: false))
    }

    @Test func pausedByUserShowsWhereItStopped() {
        var i = AnalysisCardState.Inputs()
        i.pausedByUser = true
        i.pausedAt = .init(step: .places, completed: 1_296, total: 1_600)
        #expect(AnalysisCardState.resolve(i) == .paused(i.pausedAt))
        #expect(AnalysisCardState.resolve(i)?.isGrey == true)
        #expect(AnalysisCardState.resolve(i)?.isWorking == false)
    }

    @Test func cardStates() {
        let position = AnalysisCardState.Position(step: .content, completed: 2_431, total: 5_683)
        #expect(Self.running { _ in } == .running(position, slower: nil, appleWait: false, catchingUp: nil))
        #expect(Self.running { $0.waiting = .thermal } == .waiting(.cooling, position))
        #expect(Self.running { $0.waiting = .batteryLow } == .waiting(.charging, position))
        #expect(Self.running { $0.slower = .warm } == .running(position, slower: .warm, appleWait: false, catchingUp: nil))
        #expect(Self.running { $0.slower = .lowPower } == .running(position, slower: .lowPower, appleWait: false, catchingUp: nil))
        // Waiting keeps the accent (M5), only paused is grey; motion only while working.
        #expect(Self.running { $0.waiting = .thermal }?.isGrey == false)
        #expect(Self.running { $0.waiting = .thermal }?.isWorking == false)
        #expect(Self.running { _ in }?.isWorking == true)
        // Review minor: no light sweep while Apple's geocoder is waited for.
        #expect(Self.running { $0.appleWait = true }?.isWorking == false)
        #expect(position.hasCount)
        #expect(!AnalysisCardState.Position(step: .proposals, completed: 0, total: 0).hasCount)
        #expect(!AnalysisCardState.Position(step: .trips, completed: 1, total: 1).hasCount)
    }

    @Test func quickCheckShowsPauseAfterFiveSeconds() {
        #expect(Self.running { $0.isQuickCheck = true; $0.runningFor = .seconds(2) } == .quickCheck(showsPause: false))
        #expect(Self.running { $0.isQuickCheck = true; $0.runningFor = .seconds(5) } == .quickCheck(showsPause: true))
    }

    /// P10: a run that ended because the photo access went away is neither "pausiert" nor
    /// "fertig": the card shows its reason (plain card, `nil`).
    @Test func accessLostIsNotPausedNorFinished() {
        var i = AnalysisCardState.Inputs()
        i.pausedByUser = false
        #expect(AnalysisCardState.resolve(i) == nil)
    }

    /// P11, P17: the finish moment only for a complete, long, full run.
    @Test func finishMomentOnlyForACompleteLongRun() {
        #expect(AnalysisCardState.celebratesFinish(isComplete: true, wasQuickCheck: false, ranFor: .seconds(600)))
        #expect(!AnalysisCardState.celebratesFinish(isComplete: false, wasQuickCheck: false, ranFor: .seconds(600)))
        #expect(!AnalysisCardState.celebratesFinish(isComplete: true, wasQuickCheck: true, ranFor: .seconds(600)))
        #expect(!AnalysisCardState.celebratesFinish(isComplete: true, wasQuickCheck: false, ranFor: .seconds(5)))
        var i = AnalysisCardState.Inputs()
        i.finished = (photos: 5_683, proposals: 216)
        #expect(AnalysisCardState.resolve(i) == .finished(photos: 5_683, proposals: 216))
    }

    // MARK: Already done (P16)

    /// Fuchs 16.11.: the photo mosaic during the first analysis (also when it goes on after a
    /// pause), never on a later one; the switch turns it off for the first one too.
    @Test func mosaicOnlyOnTheFirstAnalysis() {
        #expect(ScanShowRule.onFirstAnalysis)
        // First analysis, running: shown.
        #expect(ScanShowRule.shows(isRunning: true, firstAnalysis: true, isQuickCheck: false))
        // Later analyses: not shown, also with real work to show (a big batch of new photos).
        #expect(!ScanShowRule.shows(isRunning: true, firstAnalysis: false, isQuickCheck: false))
        #expect(!ScanShowRule.shows(isRunning: true, firstAnalysis: false, isQuickCheck: true))
        // Not while nothing runs, and not with the switch off.
        #expect(!ScanShowRule.shows(isRunning: false, firstAnalysis: true, isQuickCheck: false))
        #expect(!ScanShowRule.shows(isRunning: true, firstAnalysis: true, isQuickCheck: false, enabled: false))
    }

    /// Re-review N1: the mosaic's sweep only while really working, on screen, below serious heat.
    @Test func mosaicMovesOnlyWhileWorking() {
        let working = Self.running { _ in }
        #expect(ScanShowRule.animates(card: working, isOnScreen: true, thermal: .fair, reduceMotion: false))
        // Heat: from serious up, also while the card still says "running, slower".
        #expect(!ScanShowRule.animates(card: Self.running { $0.slower = .warm }, isOnScreen: true, thermal: .serious, reduceMotion: false))
        #expect(!ScanShowRule.animates(card: working, isOnScreen: true, thermal: .critical, reduceMotion: false))
        // Waiting to cool down, Apple's wait, pausing, paused.
        #expect(!ScanShowRule.animates(card: Self.running { $0.waiting = .thermal }, isOnScreen: true, thermal: .fair, reduceMotion: false))
        #expect(!ScanShowRule.animates(card: Self.running { $0.appleWait = true }, isOnScreen: true, thermal: .nominal, reduceMotion: false))
        #expect(!ScanShowRule.animates(card: Self.running { $0.pausingFor = .seconds(1) }, isOnScreen: true, thermal: .nominal, reduceMotion: false))
        #expect(!ScanShowRule.animates(card: nil, isOnScreen: true, thermal: .nominal, reduceMotion: false))
        // Off screen, Reduce Motion.
        #expect(!ScanShowRule.animates(card: working, isOnScreen: false, thermal: .nominal, reduceMotion: false))
        #expect(!ScanShowRule.animates(card: working, isOnScreen: true, thermal: .nominal, reduceMotion: true))
    }

    /// Re-review a: the notification also comes at midnight and for small carrier
    /// corrections; only a real jump of the wall clock resets the finish time.
    @Test func onlyARealClockJumpCounts() {
        let then = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Midnight: wall and real time moved alike.
        #expect(!ProgressEstimator.clockJumped(wallThen: then, wallNow: then + 0.25, elapsed: .milliseconds(250)))
        // The carrier corrects by 3 s.
        #expect(!ProgressEstimator.clockJumped(wallThen: then, wallNow: then + 3.25, elapsed: .milliseconds(250)))
        // Set by hand: an hour ahead, or ten minutes back.
        #expect(ProgressEstimator.clockJumped(wallThen: then, wallNow: then + 3_600, elapsed: .milliseconds(250)))
        #expect(ProgressEstimator.clockJumped(wallThen: then, wallNow: then - 600, elapsed: .milliseconds(250)))
    }

    @Test func alreadyDoneCounts() {
        func proposal(_ kind: ProposalKind, _ n: Int) -> AlbumProposal {
            AlbumProposal(id: SortlyID("p\(n)"), kind: kind, title: "P\(n)", assetIDs: [])
        }
        let proposals = [proposal(.trip, 1), proposal(.trip, 2), proposal(.placeCollection(.country), 3),
                         proposal(.frequentPlace, 4), proposal(.imageCategory("dog"), 5)]
        #expect(AlreadyDone.counts(proposals: proposals, step: .places).isEmpty)
        #expect(AlreadyDone.counts(proposals: proposals, step: nil).isEmpty)
        #expect(AlreadyDone.counts(proposals: proposals, step: .content) == AlreadyDone(trips: 2, places: 2))
        #expect(AlreadyDone.counts(proposals: [], step: .text).isEmpty)
    }

    // MARK: Mailbox (S2)

    @Test func mailboxKeepsTheNewestAndTheWorkload() {
        let box = ProgressMailbox()
        box.post(.init(stage: .patterns, completed: 1, total: 1, workload: Self.owner))
        box.post(.init(stage: .content, completed: 10, total: 100, recent: ["a", "b"]))
        box.post(.init(stage: .content, completed: 20, total: 100))
        let taken = box.take()
        #expect(taken.progress?.completed == 20)
        #expect(taken.workload == Self.owner)
        #expect(taken.recent == ["a", "b"])
        let again = box.take()
        #expect(again.progress == nil && again.workload == nil && again.recent.isEmpty)
    }

    /// UI run 43930271358 (DeviceConditionUITests test02): the last report of the places step
    /// was posted, the wait for the battery began, and the tick took the report after that and
    /// cleared the wait, so "Wartet aufs Laden" never showed. The wait is now a state in the
    /// same box: a report sent before it never hides it, and it stays until the pipeline ends it.
    @Test func mailboxKeepsAWaitThatBeganAfterTheLastReport() {
        let box = ProgressMailbox()
        box.post(.init(stage: .places, completed: 40, total: 120))
        box.wait(.batteryLow)
        let first = box.take()
        #expect(first.progress?.stage == .places)
        #expect(first.waiting == .batteryLow)
        // Ticks during the wait: no reports, the wait is still said.
        #expect(box.take().waiting == .batteryLow)
        #expect(box.take().progress == nil)
        // The wait ends (admission's defer), then the next step reports.
        box.wait(nil)
        box.post(.init(stage: .content, completed: 0, total: 246))
        let after = box.take()
        #expect(after.waiting == nil)
        #expect(after.progress?.stage == .content)
        // A new wait, then a report of the same step (in-flight photos): the wait holds.
        box.wait(.thermal)
        box.post(.init(stage: .content, completed: 3, total: 246))
        #expect(box.take().waiting == .thermal)
    }
}

/// The overnight refinement on the card (second review of the no-wait fix for the geocoder,
/// device test 18.11., build 36): before, its reports reached no one, so its wait for Apple
/// never showed and the card stood on the last run's position without a word.
@Suite("Analysis card: the overnight refinement")
struct RefinementCardTests {
    typealias Progress = AnalysisPipeline.Progress

    @Test func aWaitForAppleReachesTheCardAndEnds() {
        var card = RefinementCard()
        let box = ProgressMailbox()
        let t0 = ContinuousClock.now
        box.post(Progress(stage: .places, completed: 100, total: 500))
        var shown = card.take(box.take(), at: t0, gliding: true)
        #expect(shown.position == AnalysisCardState.Position(step: .places, completed: 100, total: 500))
        #expect(shown.waitLeft == nil)
        box.post(Progress(stage: .places, completed: 100, total: 500, waitLeft: .seconds(48)))
        shown = card.take(box.take(), at: t0 + .seconds(1), gliding: true)
        #expect(shown.waitLeft == .seconds(48))
        #expect(shown.countdown == .seconds(48))
        // A tick without a new report keeps the wait (the next report comes within 2 s).
        shown = card.take(box.take(), at: t0 + .milliseconds(1_250), gliding: true)
        #expect(shown.waitLeft == .seconds(48))
        box.post(Progress(stage: .places, completed: 100, total: 500, waitLeft: .seconds(46)))
        shown = card.take(box.take(), at: t0 + .seconds(3), gliding: true)
        #expect(shown.countdown == .seconds(46))
        // The wait is over: the pipeline says so with the same count, and the countdown goes.
        box.post(Progress(stage: .places, completed: 100, total: 500))
        shown = card.take(box.take(), at: t0 + .seconds(48), gliding: true)
        #expect(shown.waitLeft == nil)
        #expect(shown.countdown == nil)
        box.post(Progress(stage: .places, completed: 140, total: 500))
        shown = card.take(box.take(), at: t0 + .seconds(49), gliding: true)
        #expect(shown.completed == 140)
    }

    @Test func countAndStepNeverGoBack() {
        var card = RefinementCard()
        let box = ProgressMailbox()
        let t0 = ContinuousClock.now
        box.post(Progress(stage: .places, completed: 200, total: 500))
        card.take(box.take(), at: t0, gliding: true)
        box.post(Progress(stage: .places, completed: 150, total: 500))
        #expect(card.take(box.take(), at: t0 + .seconds(1), gliding: true).completed == 200)
        box.post(Progress(stage: .patterns, completed: 3, total: 3))
        #expect(card.take(box.take(), at: t0 + .seconds(2), gliding: true).stage == .places)
        box.post(Progress(stage: .content, completed: 0, total: 40))
        #expect(card.take(box.take(), at: t0 + .seconds(3), gliding: true).stage == .content)
    }

    @Test func aWaitForTheDeviceIsSaid() {
        var card = RefinementCard()
        let box = ProgressMailbox()
        let t0 = ContinuousClock.now
        box.post(Progress(stage: .content, completed: 3, total: 40))
        box.wait(.thermal)
        #expect(card.take(box.take(), at: t0, gliding: true).waiting == .thermal)
        box.wait(nil)
        #expect(card.take(box.take(), at: t0 + .seconds(1), gliding: true).waiting == nil)
    }

    /// The bar moves with the refinement, glides between its reports, never goes back, and
    /// never reaches 100 % (`AnalysisPercent`).
    @Test func theBarMovesAndNeverGoesBack() {
        var card = RefinementCard()
        let box = ProgressMailbox()
        let t0 = ContinuousClock.now
        var bars: [Double] = []
        for (i, stage) in [AnalysisPipeline.Stage.inventory, .patterns, .places, .content, .text, .groups, .proposals].enumerated() {
            for done in stride(from: 0, through: 100, by: 10) {
                box.post(Progress(stage: stage, completed: done, total: 100))
                let t = t0 + .seconds(i * 60 + done / 2)
                bars.append(card.take(box.take(), at: t, gliding: true).bar)
                bars.append(card.take(box.take(), at: t + .milliseconds(250), gliding: true).bar)
            }
        }
        #expect(zip(bars, bars.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1e-12 })
        #expect(bars.first! < 0.05)
        #expect(bars.last! > 0.9)
        #expect(bars.allSatisfy { $0 <= AnalysisPercent.cap })
    }

    /// "weiter in 25 s", "weiter in 2 Minuten": whole seconds up to a minute, whole minutes
    /// above, always rounded up (never less than is left, never 0 while it waits).
    @Test func countdownInSecondsThenMinutes() {
        #expect(AppleWaitCountdown(.seconds(25)) == .seconds(25))
        #expect(AppleWaitCountdown(.milliseconds(24_200)) == .seconds(25))
        #expect(AppleWaitCountdown(.milliseconds(300)) == .seconds(1))
        #expect(AppleWaitCountdown(.zero) == .seconds(1))
        #expect(AppleWaitCountdown(.seconds(60)) == .seconds(60))
        #expect(AppleWaitCountdown(.milliseconds(60_500)) == .minutes(2))
        #expect(AppleWaitCountdown(.seconds(120)) == .minutes(2))
        #expect(AppleWaitCountdown(.seconds(121)) == .minutes(3))
        #expect(AppleWaitCountdown(.seconds(600)) == .minutes(10))
    }
}
