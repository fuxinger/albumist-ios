import Foundation
import Testing
@testable import AlbumistCore

/// How `scrollTo(y:)` counts, learned while the grid scrolls by itself (`PhotoGridGestureTests`).
extension PhotoGridGestureTests {
    // MARK: How scrollTo(y:) counts

    /// Whether `scrollTo(y:)` takes the content offset or counts from where the scroll view rests
    /// at the top is learned from the first step that can tell (review L5): asked as the content
    /// offset, the scroll view reports the same, or less by the top inset; from then on the steps
    /// ask so the scroll view goes where they mean, also to the content's last rows.
    @Test func howScrollToCountsIsLearnedFromTheFirstStep() {
        // Content offsets from -100 (at rest at the top, under 100 pt of bars) to 2,000.
        let range = -100.0...2_000
        var asOffset = PhotoGridAutoScroll.Calibration()
        #expect(asOffset.y(for: 510, insetTop: 100) == 510, "not known yet: as the content offset")
        asOffset.asked(510, from: 500, insetTop: 100, range: range)
        asOffset.reported(500)
        #expect(asOffset.convention == nil, "not moved yet")
        asOffset.reported(510)
        #expect(asOffset.convention == .contentOffset)
        #expect(asOffset.y(for: 2_000, insetTop: 100) == 2_000)

        var fromTop = PhotoGridAutoScroll.Calibration()
        fromTop.asked(510, from: 500, insetTop: 100, range: range)
        fromTop.reported(410)
        #expect(fromTop.convention == .fromRestingTop)
        #expect(fromTop.y(for: 520, insetTop: 100) == 620)
        #expect(fromTop.y(for: 2_000, insetTop: 100) == 2_100, "the last rows are reached")
        #expect(fromTop.y(for: -100, insetTop: 100) == 0, "the top")
        // One probe a run: a later step of the same run changes nothing.
        fromTop.asked(700, from: 520, insetTop: 100, range: range)
        fromTop.reported(700)
        #expect(fromTop.convention == .fromRestingTop)
    }

    /// A step that cannot tell teaches nothing: without a top inset (both ways agree), cut at an
    /// end of the content one way, answered with an offset of neither way (something else moved
    /// the scroll view), or let go before it was answered.
    @Test func aStepThatCannotTellTeachesNothing() {
        let range = -100.0...2_000
        var calibration = PhotoGridAutoScroll.Calibration()
        calibration.asked(510, from: 500, insetTop: 0, range: 0...2_000)
        calibration.reported(510)
        #expect(calibration.convention == nil, "no top inset: both ways agree")
        #expect(calibration.y(for: 510, insetTop: 0) == 510)
        calibration.asked(-95, from: -100, insetTop: 100, range: range)
        calibration.reported(-100)
        #expect(calibration.convention == nil, "from the top: counted from the top it would be cut there")
        calibration.asked(1_999.5, from: 1_990, insetTop: 100, range: range)
        calibration.reported(1_999.5)
        #expect(calibration.convention == nil, "at the bottom: as the content offset it would be cut")
        calibration.asked(510, from: 500, insetTop: 100, range: range)
        calibration.reported(455)
        #expect(calibration.convention == nil, "moved by something else")
        calibration.reset()
        calibration.reported(510)
        #expect(calibration.convention == nil, "a step let go teaches nothing")
        calibration.asked(510, from: 500, insetTop: 100, range: range)
        calibration.reported(510)
        #expect(calibration.convention == .contentOffset, "the next step that can tell")
    }

    /// A probe waits alone for its answer (review W4): nothing else is asked in the two frames
    /// after it, so no later step's report can pass where the other way would have put it. Not
    /// answered by then, it is dropped and teaches nothing, and the steps go on. (`mayAsk()`
    /// counts a frame, so it is called outside `#expect`.)
    @Test func aProbeWaitsAloneForItsAnswer() {
        let range = -100.0...2_000
        var calibration = PhotoGridAutoScroll.Calibration()
        var asks = calibration.mayAsk()
        #expect(asks)
        calibration.asked(980, from: 1_000, insetTop: 100, range: range)
        calibration.reported(1_000)
        let frames = (1...3).map { _ in calibration.mayAsk() }
        #expect(frames == [false, false, true], "two frames ask nothing; then it is dropped, the steps go on")
        calibration.reported(980)
        #expect(calibration.convention == nil, "a dropped probe teaches nothing")
        // The next step that can tell, with nothing else on its way, probes again.
        calibration.asked(960, from: 980, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(!asks)
        calibration.reported(960)
        #expect(calibration.convention == .contentOffset)
        asks = calibration.mayAsk()
        #expect(asks, "answered: the steps go on at once")
    }

    /// A probe is taken only when no other step is on its way (review W4): that step's report
    /// can land where one of the two ways would put the probe.
    @Test func aProbeIsTakenOnlyWhenNoOtherStepIsOnItsWay() {
        let range = -100.0...2_000
        var calibration = PhotoGridAutoScroll.Calibration()
        // A step too small to tell, on its way.
        calibration.asked(701.5, from: 700, insetTop: 100, range: range)
        // The next frame's step could tell (both ways 2 pt or more from where the scroll view
        // is), but the one before has not been reported: no probe. Counted from the top it lands
        // where the step before does, so the probe after it could not tell either: it holds
        // nothing back (review Y1).
        var asks = calibration.mayAsk()
        #expect(asks)
        calibration.asked(802, from: 700, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(asks, "no probe waits")
        // The step before lands where counting from the top would have put this one.
        calibration.reported(701.5)
        #expect(calibration.convention == nil, "no probe, no lesson")
        calibration.reported(802)
        // Nothing on its way now: the next step that can tell probes.
        calibration.asked(820, from: 802, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(!asks)
        calibration.reported(820)
        #expect(calibration.convention == .contentOffset)
    }

    /// Where the scroll view reports each step a frame or two late (review Y1), a step is always
    /// on its way, and no step could probe: the run's first step that could tell, also from where
    /// the step before it lands, lets the steps be answered first (nothing is asked until it is),
    /// and the next step probes.
    @Test func theStepsBeforeTheProbeAreAnsweredFirst() {
        let range = -100.0...2_000
        var calibration = PhotoGridAutoScroll.Calibration()
        // A step too small to tell, then one that could tell; the first is not reported yet.
        calibration.asked(701, from: 700, insetTop: 100, range: range)
        var asks = calibration.mayAsk()
        #expect(asks)
        calibration.asked(704, from: 700, insetTop: 100, range: range)
        calibration.reported(701)
        asks = calibration.mayAsk()
        #expect(!asks, "the steps before the probe are answered first")
        calibration.reported(704)
        #expect(calibration.convention == nil, "no probe, no lesson")
        asks = calibration.mayAsk()
        #expect(asks, "all answered: the steps go on")
        // The next step that can tell probes, alone.
        calibration.asked(707, from: 704, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(!asks)
        calibration.reported(707)
        #expect(calibration.convention == .contentOffset)
    }

    /// The steps before the probe are waited for once a run, for `patience` frames: not answered
    /// by then, the last of them is dropped, and while its report may still come no step probes
    /// (it could land where one of the two ways puts that step).
    @Test func theStepsBeforeTheProbeAreWaitedForOnceARun() {
        let range = -100.0...2_000
        var calibration = PhotoGridAutoScroll.Calibration()
        calibration.asked(510, from: 500, insetTop: 100, range: range)
        calibration.reported(510)
        #expect(calibration.convention == .contentOffset)
        // The next run: the reports do not come.
        calibration.reset()
        calibration.asked(708, from: 707, insetTop: 100, range: range)
        var asks = calibration.mayAsk()
        #expect(asks)
        calibration.asked(711, from: 707, insetTop: 100, range: range)
        let frames = (1...3).map { _ in calibration.mayAsk() }
        #expect(frames == [false, false, true], "two frames ask nothing; then the steps go on")
        // Once a run: the next step that could tell holds nothing back, and it is no probe.
        calibration.asked(811, from: 707, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(asks, "once a run")
        // The dropped step's report comes late, where counting from the top puts the last one.
        calibration.reported(711)
        #expect(calibration.convention == .contentOffset, "a step on its way, no probe")
    }

    /// The review's case (Y1): a finger selects into the bottom edge, and the scroll view reports
    /// each step in the same frame, one or two frames late, or never. Whichever way `scrollTo(y:)`
    /// counts, how fast the finger comes and at 60 or 120 frames a second, the run learns that
    /// way where the reports come; the page stands still for at most two frames for each frame
    /// they come late, at most twice `patience` frames.
    @Test func aRunLearnsAlsoWhereTheScrollViewReportsLate() {
        typealias Convention = PhotoGridAutoScroll.Calibration.Convention
        let most = 2 * PhotoGridAutoScroll.Calibration.patience
        for truth in [Convention.contentOffset, .fromRestingTop] {
            for late in [0, 1, 2, nil] as [Int?] {
                for rate in [60.0, 120] {
                    for fingerSpeed in [50.0, 100, 200, 400, 800, 1_600] {
                        let run = Self.selectIntoTheEdge(EdgeRun(truth: truth, late: late, rate: rate, fingerSpeed: fingerSpeed))
                        let label = "\(truth), \(late.map { "\($0) late" } ?? "never"), \(rate) Hz, \(fingerSpeed) pt/s"
                        #expect(run.learned == (late == nil ? nil : truth), "\(label)")
                        #expect(run.still <= min(2 * (late ?? most), most), "\(label): \(run.still) frames still")
                    }
                }
            }
        }
    }

    /// The review's case (Z1): where the scroll view reports each step three frames late, beyond
    /// `patience`, the report of a step three before lands where counting from the top puts the
    /// latest one when the steps between add up to the top inset (three steps of 23.3 pt under
    /// 70 pt of bars). A report answers a waiting step only when no step before it is still on its
    /// way: the run learns nothing then, and never the wrong way, and as its probe's wait ran out
    /// while older steps' reports came, it probes no more (the page stands still for at most
    /// three waits). Two frames late it learns the right way, also where two steps add up to the
    /// top inset (47 pt, from the resting top).
    @Test func aLateReportAnswersOnlyItsOwnStep() {
        typealias Convention = PhotoGridAutoScroll.Calibration.Convention
        for truth in [Convention.contentOffset, .fromRestingTop] {
            for start in [nil, 3_000] as [Double?] {
                for fingerSpeed in [50, 400, EdgeRun.atOnce] {
                    for rate in [60.0, 120] {
                        let run = EdgeRun(truth: truth, late: 3, rate: rate, fingerSpeed: fingerSpeed, insetTop: 70, start: start)
                        let result = Self.selectIntoTheEdge(run)
                        #expect(result.learned == nil, "\(run)")
                        #expect(result.still <= 3 * PhotoGridAutoScroll.Calibration.patience, "\(run): \(result.still) frames still")
                    }
                }
            }
            let run = EdgeRun(truth: truth, late: 2, fingerSpeed: EdgeRun.atOnce, insetTop: 47, start: nil)
            #expect(Self.selectIntoTheEdge(run).learned == truth, "\(run)")
        }
    }

    /// No lesson stands unchecked (review W4): each run of scrolling by itself probes once more,
    /// and a probe that lands where the other way puts it flips the lesson; one that lands where
    /// the lesson puts it keeps it. One probe a run: the rest of the run is not held back.
    @Test func eachRunChecksTheLessonAndFlipsAWrongOne() {
        let range = -100.0...2_000
        var calibration = PhotoGridAutoScroll.Calibration()
        // A wrong lesson: the probe's report came from something else that moved the scroll view.
        calibration.asked(510, from: 500, insetTop: 100, range: range)
        calibration.reported(410)
        #expect(calibration.convention == .fromRestingTop)
        // The rest of the run: a step's report where the other way puts it changes nothing yet.
        calibration.asked(calibration.y(for: 430, insetTop: 100), from: 410, insetTop: 100, range: range)
        var asks = calibration.mayAsk()
        #expect(asks, "no probe: nothing waits")
        calibration.reported(530)
        #expect(calibration.convention == .fromRestingTop, "one probe a run")
        calibration.reset()
        // The next run's first step that can tell is a probe: the scroll view goes to `y` as the
        // content offset.
        let y = calibration.y(for: 550, insetTop: 100)
        #expect(y == 650)
        calibration.asked(y, from: 530, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(!asks)
        calibration.reported(650)
        #expect(calibration.convention == .contentOffset, "flipped")
        #expect(calibration.y(for: 670, insetTop: 100) == 670)
        calibration.reset()
        // A lesson that holds stays.
        calibration.asked(670, from: 650, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(!asks)
        calibration.reported(670)
        #expect(calibration.convention == .contentOffset)
        asks = calibration.mayAsk()
        #expect(asks)
    }

    /// The review's case (W4): the probe's own report never comes (two steps applied in one
    /// update, a report merged with the next) while the page scrolls on. Whatever the step and
    /// whichever way `scrollTo(y:)` counts, what is learned is that way.
    @Test func aMissedAnswerTeachesNothingWrong() {
        typealias Convention = PhotoGridAutoScroll.Calibration.Convention
        for truth in [Convention.contentOffset, .fromRestingTop] {
            for step in [-25.0, -20, -12.5, -10, -5, 5, 10, 12.5, 20, 25] {
                for missed in [Set<Int>(), [0], [0, 3, 4]] {
                    let learned = Self.scrollByItself(truth: truth, step: step, missed: missed)
                    #expect(learned == truth, "\(truth), \(step) a frame, missed \(missed.sorted())")
                }
            }
        }
    }

    /// Scrolls a scroll view that takes `scrollTo(y:)` the way `truth` says by itself, frame by
    /// frame as `PhotoGridScroller.scroll(by:)` does, `step` points a frame from 2,000 (under
    /// 100 pt of bars); it reports where it is after each step, except after the frames in
    /// `missed`. What the calibration learned.
    private static func scrollByItself(truth: PhotoGridAutoScroll.Calibration.Convention, step: Double,
                                       missed: Set<Int>) -> PhotoGridAutoScroll.Calibration.Convention? {
        let insetTop = 100.0, range = -insetTop...5_000
        var calibration = PhotoGridAutoScroll.Calibration()
        var target = PhotoGridAutoScroll.Target()
        var reported = 2_000.0
        for frame in 0..<24 {
            guard calibration.mayAsk(),
                  let wanted = target.next(by: step, offset: reported, range: range) else { continue }
            let y = calibration.y(for: wanted, insetTop: insetTop)
            calibration.asked(y, from: reported, insetTop: insetTop, range: range)
            let landed = min(max(truth == .contentOffset ? y : y - insetTop, range.lowerBound), range.upperBound)
            guard !missed.contains(frame) else { continue }
            reported = landed
            target.reported(landed)
            calibration.reported(landed)
        }
        return calibration.convention
    }

    /// A finger that selects into the bottom edge, and the scroll view the grid is in
    /// (`selectIntoTheEdge`).
    private struct EdgeRun {
        /// How the scroll view takes `scrollTo(y:)`.
        var truth: PhotoGridAutoScroll.Calibration.Convention
        /// The frames after a step's that report it; nil: never.
        var late: Int?
        /// Frames a second.
        var rate = 60.0
        /// Points a second the finger moves into the edge's zone (`atOnce`: at the edge from the
        /// first frame on).
        var fingerSpeed = 400.0
        /// The bars over the scroll view: its top inset. Below them 468 pt are seen.
        var insetTop = 116.0
        /// The content offset the run starts at; nil: at rest at the top.
        var start: Double? = 3_000

        static let atOnce = 100_000.0
    }

    /// A finger that selects into the bottom edge (`run`), on to 20 pt past it, for two seconds of
    /// frames; the grid scrolls by itself as `PhotoGridScroller.scroll(by:)` does, and the scroll
    /// view goes where `scrollTo(y:)` takes it the way `run.truth` says and reports each move
    /// `run.late` frames later, in the update after that frame's step. What the calibration
    /// learned, and the frames it asked nothing.
    private static func selectIntoTheEdge(_ run: EdgeRun) -> (learned: PhotoGridAutoScroll.Calibration.Convention?, still: Int) {
        let seen = run.insetTop...(run.insetTop + 468), range = -run.insetTop...20_000
        var calibration = PhotoGridAutoScroll.Calibration()
        var target = PhotoGridAutoScroll.Target()
        var reported = run.start ?? -run.insetTop, position = reported, still = 0
        var due: [(frame: Int, offset: Double)] = []
        for frame in 0..<Int(2 * run.rate) {
            let finger = min(seen.upperBound - PhotoGridAutoScroll.edge + run.fingerSpeed * Double(frame) / run.rate, seen.upperBound + 20)
            let speed = PhotoGridAutoScroll.speed(y: finger, top: seen.lowerBound, bottom: seen.upperBound)
            if speed != 0, !calibration.mayAsk() {
                still += 1
            } else if speed != 0,
                      let wanted = target.next(by: PhotoGridAutoScroll.step(speed: speed, seconds: 1 / run.rate), offset: reported, range: range) {
                let y = calibration.y(for: wanted, insetTop: run.insetTop)
                calibration.asked(y, from: reported, insetTop: run.insetTop, range: range)
                let landed = min(max(run.truth == .contentOffset ? y : y - run.insetTop, range.lowerBound), range.upperBound)
                if let late = run.late, landed != position { due.append((frame + late, landed)) }
                position = landed
            }
            // The frame's update: the reports due now, in order.
            while let next = due.first, next.frame == frame {
                due.removeFirst()
                reported = next.offset
                target.reported(next.offset)
                calibration.reported(next.offset)
            }
        }
        return (calibration.convention, still)
    }
}
