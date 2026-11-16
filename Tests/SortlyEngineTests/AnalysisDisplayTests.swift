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
        e.setWorkload(Self.owner)
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
}
