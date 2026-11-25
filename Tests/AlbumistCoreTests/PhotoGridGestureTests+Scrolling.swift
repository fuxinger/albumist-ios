import Foundation
import Testing
@testable import AlbumistCore

/// The grid scrolls by itself near an edge while a finger drags (`PhotoGridGestureTests`).
extension PhotoGridGestureTests {
    // MARK: Scrolling by itself

    /// Near the top or bottom edge of what is visible the grid scrolls by itself, faster the
    /// closer the finger is to the edge, at the fastest at it and beyond (over a bar); in the
    /// middle it stands still.
    @Test func nearAnEdgeTheGridScrollsFasterTheCloserTheFinger() {
        let top = 100.0, bottom = 800.0
        #expect(PhotoGridAutoScroll.speed(y: 450, top: top, bottom: bottom) == 0)
        #expect(PhotoGridAutoScroll.speed(y: top + PhotoGridAutoScroll.edge, top: top, bottom: bottom) == 0)
        var last = 0.0
        for y in stride(from: bottom - PhotoGridAutoScroll.edge + 1, through: bottom, by: 4) {
            let speed = PhotoGridAutoScroll.speed(y: y, top: top, bottom: bottom)
            #expect(speed > last, "\(y)")
            last = speed
        }
        #expect(PhotoGridAutoScroll.speed(y: bottom, top: top, bottom: bottom) == PhotoGridAutoScroll.fastest)
        #expect(PhotoGridAutoScroll.speed(y: bottom + 60, top: top, bottom: bottom) == PhotoGridAutoScroll.fastest)
        #expect(PhotoGridAutoScroll.speed(y: top + 10, top: top, bottom: bottom) < 0, "up")
        #expect(PhotoGridAutoScroll.speed(y: top - 30, top: top, bottom: bottom) == -PhotoGridAutoScroll.fastest)
        // Smooth from a standstill: the first points into the zone barely move it.
        #expect(PhotoGridAutoScroll.speed(y: bottom - PhotoGridAutoScroll.edge + 2, top: top, bottom: bottom) < 5)
        // Symmetric.
        #expect(PhotoGridAutoScroll.speed(y: top + 20, top: top, bottom: bottom) == -PhotoGridAutoScroll.speed(y: bottom - 20, top: top, bottom: bottom))
    }

    /// The edges' zones begin where the bars end. "Unsortiert" insets its content by the bars;
    /// a suggestion's cover reaches up under them (no content inset at the top), and they cover
    /// it all the same: at each edge what covers more counts.
    @Test func theEdgesAreWhereTheBarsEnd() {
        // "Unsortiert" on the small iPhone: the navigation bar above, the tab bar below.
        #expect(PhotoGridAutoScroll.seenArea(height: 667, insetTop: 116, insetBottom: 83, safeTop: 116, safeBottom: 83) == 116...584)
        // A suggestion: the cover under the status bar and the bar's buttons, the toolbar below.
        #expect(PhotoGridAutoScroll.seenArea(height: 852, insetTop: 0, insetBottom: 83, safeTop: 103, safeBottom: 34) == 103...769)
        let top = PhotoGridAutoScroll.seenArea(height: 852, insetTop: 0, insetBottom: 83, safeTop: 103, safeBottom: 34)?.lowerBound ?? 0
        #expect(PhotoGridAutoScroll.speed(y: top + 10, top: top, bottom: 769) < 0, "just below the bar scrolls up")
        #expect(PhotoGridAutoScroll.speed(y: top + PhotoGridAutoScroll.edge + 10, top: top, bottom: 769) == 0)
        // Nothing to see, or the page not laid out yet.
        #expect(PhotoGridAutoScroll.seenArea(height: 100, insetTop: 60, insetBottom: 0, safeTop: 0, safeBottom: 40) == nil)
        #expect(PhotoGridAutoScroll.seenArea(height: 0, insetTop: 0, insetBottom: 0, safeTop: 0, safeBottom: 0) == nil)
        // An inset below zero does not widen the area beyond the scroll view.
        #expect(PhotoGridAutoScroll.seenArea(height: 500, insetTop: -20, insetBottom: -10, safeTop: 0, safeBottom: 0) == 0...500)
    }

    /// On a short visible area the edges take at most a quarter each, so the middle stays still.
    @Test func aShortAreaKeepsAStillMiddle() {
        #expect(PhotoGridAutoScroll.speed(y: 150, top: 100, bottom: 200) == 0)
        #expect(PhotoGridAutoScroll.speed(y: 120, top: 100, bottom: 200) < 0)
        #expect(PhotoGridAutoScroll.speed(y: 180, top: 100, bottom: 200) > 0)
        #expect(PhotoGridAutoScroll.speed(y: 150, top: 100, bottom: 100) == 0, "no area")
    }

    /// One frame's step: speed times its time, a frame after a stall no larger than one of a
    /// thirtieth of a second, so the grid never jumps.
    @Test func aFramesStep() {
        #expect(abs(PhotoGridAutoScroll.step(speed: 600, seconds: 1.0 / 60) - 10) < 1e-9)
        #expect(abs(PhotoGridAutoScroll.step(speed: -600, seconds: 1.0 / 60) + 10) < 1e-9)
        #expect(abs(PhotoGridAutoScroll.step(speed: 600, seconds: 2) - 20) < 1e-9)
        #expect(PhotoGridAutoScroll.step(speed: 600, seconds: -1) == 0)
    }

    /// Steps go on from the last one asked for until the scroll view reports it, within the
    /// content; at an end nothing more is asked.
    @Test func targetsGoOnFromTheLastAskedWithinTheContent() {
        var target = PhotoGridAutoScroll.Target()
        #expect(target.next(by: 10, offset: 100, range: -50...1_000) == 110)
        // The scroll view has not reported 110 yet: the next step goes on from it.
        #expect(target.next(by: 10, offset: 100, range: -50...1_000) == 120)
        target.reported(120)
        #expect(target.next(by: -30, offset: 120, range: -50...1_000) == 90)
        target.reset()
        #expect(target.next(by: 30, offset: 990, range: -50...1_000) == 1_000)
        target.reported(1_000)
        #expect(target.next(by: 30, offset: 1_000, range: -50...1_000) == nil, "at the end")
        #expect(target.next(by: -60, offset: -20, range: -50...1_000) == -50)
    }

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
        calibration.asked(700.5, from: 700, insetTop: 100, range: range)
        // The next frame's step could tell, but the one before has not been reported: no probe,
        // and it holds nothing back.
        var asks = calibration.mayAsk()
        #expect(asks)
        calibration.asked(800, from: 700, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(asks, "no probe waits")
        // The step before lands where counting from the top would have put this one.
        calibration.reported(700.5)
        #expect(calibration.convention == nil, "no probe, no lesson")
        calibration.reported(800)
        // Nothing on its way now: the next step that can tell probes.
        calibration.asked(820, from: 800, insetTop: 100, range: range)
        asks = calibration.mayAsk()
        #expect(!asks)
        calibration.reported(820)
        #expect(calibration.convention == .contentOffset)
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
}
