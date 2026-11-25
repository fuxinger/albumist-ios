import Foundation

// Scrolling by itself while a finger selects in a photo grid (design wave 3, DS-06b): how fast, and how the scroll view counts.

/// The grid scrolling by itself while a finger selects near its top or bottom edge (DS-06b:
/// "Ziehen über mehr als einen Bildschirm"): smoothly from a standstill, faster the closer the
/// finger is to the edge, at the fastest at the edge and beyond it (over a bar).
public enum PhotoGridAutoScroll {
    /// How far from each edge of the visible area the grid scrolls by itself, in points; at most
    /// a quarter of that area each, so its middle stays still.
    public static let edge: Double = 72
    /// Points per second at the edge: about two screens of the small iPhone a second.
    public static let fastest: Double = 1_400
    /// The longest time one frame's step counts: after a stall the grid does not jump.
    public static let longestFrame: Double = 1.0 / 30

    /// The speed for a finger at `y` in a visible area from `top` to `bottom` (one space), in
    /// points per second: negative scrolls up, positive down, 0 in the middle. It grows with the
    /// square of how deep the finger is in the edge's zone.
    public static func speed(y: Double, top: Double, bottom: Double) -> Double {
        let height = bottom - top
        guard height > 0 else { return 0 }
        let zone = min(edge, height / 4)
        if y < top + zone {
            let depth = min(1, (top + zone - y) / zone)
            return -fastest * depth * depth
        }
        if y > bottom - zone {
            let depth = min(1, (y - (bottom - zone)) / zone)
            return fastest * depth * depth
        }
        return 0
    }

    /// The part of a scroll view `height` points high that the user sees, from top to bottom in
    /// its own space, where the edges' zones are: below what covers its top and above what covers
    /// its bottom, at each edge the larger of the scroll view's content inset and its safe area.
    /// A page whose content reaches up under the bars (a suggestion's cover) has no content inset
    /// at the top, and the bars cover it all the same. Nil when nothing is seen.
    public static func seenArea(height: Double, insetTop: Double, insetBottom: Double,
                                safeTop: Double, safeBottom: Double) -> ClosedRange<Double>? {
        let top = max(insetTop, safeTop, 0)
        let bottom = height - max(insetBottom, safeBottom, 0)
        return top < bottom ? top...bottom : nil
    }

    /// One frame's step in points: `speed` for the frame's `seconds`, at most `longestFrame`.
    public static func step(speed: Double, seconds: Double) -> Double {
        speed * min(max(seconds, 0), longestFrame)
    }

    /// The offsets to ask the scroll view for, step by step: from the last one asked until the
    /// scroll view reports it (it applies a new offset with the next frame), within the content.
    public struct Target: Equatable, Sendable {
        private var pending: Double?

        public init() {}

        /// The offset to ask for after a step of `step` points from `offset` (the reported one),
        /// kept within `range`; nil when that is where the grid is (at an end).
        public mutating func next(by step: Double, offset: Double, range: ClosedRange<Double>) -> Double? {
            let base = pending ?? offset
            let target = min(max(base + step, range.lowerBound), range.upperBound)
            guard abs(target - base) >= 0.01 else { return nil }
            pending = target
            return target
        }

        /// The scroll view reports `offset`: once it is where it was asked to be, the next step
        /// goes on from there.
        public mutating func reported(_ offset: Double) {
            if let pending, abs(pending - offset) < 1 { self.pending = nil }
        }

        /// The grid stopped scrolling by itself.
        public mutating func reset() {
            pending = nil
        }
    }

    /// How `scrollTo(y:)` counts, learned from the scroll view (`PhotoGridScrollCalibration`).
    public typealias Calibration = PhotoGridScrollCalibration
}

/// How `ScrollPosition.scrollTo(y:)` counts, learned from the scroll view (review L5 of
/// design wave 3): SwiftUI's documentation does not say whether `y` is the scroll view's
/// content offset (minus the top inset at rest at the top, as `ScrollGeometry` reports it)
/// or counts from where the scroll view rests at the top. A step tells: the scroll view
/// reports `y`, or less by the top inset. Until a step told (and where the top inset is too
/// small to tell, so both ways agree) `y` is taken as the content offset; once known, the
/// steps ask so the scroll view goes where they mean.
///
/// Only a probe teaches, and no lesson stands unchecked (review W4): a step is a probe when
/// it can tell and no other step is on its way (whose report could land where one of the two
/// ways puts it), and nothing else is asked until its report came or `patience` frames
/// passed (then it is dropped and teaches nothing, so no later step's report passes where the
/// other way would have put it). Each run of scrolling by itself probes until one probe is
/// answered: a lesson is learned, kept, or flipped where the probe lands the other way.
///
/// Where the scroll view reports a step a frame or two late, a step is always on its way
/// (review Y1): then the run's first step that could tell lets the steps before the probe be
/// answered first. It waits as a probe does, teaching nothing, and the next step that can tell
/// probes.
///
/// A report answers a waiting step only when it is the step's own (review Z1): the scroll view
/// reports the steps in their order, one report for each step that moved it, so it is the
/// step's own when no step before it is still on its way. A report of an older step can land
/// where one of the two ways puts the waiting step (where the steps between add up to the top
/// inset). Where a report did not come (two steps in one update, a step that did not move the
/// scroll view), the step's wait ends with where the scroll view came to rest meanwhile: its
/// last report then, if it lands where one of the two ways puts the step, answers it. A probe
/// whose wait ran out while older steps' reports came is the run's last: they come later than
/// `patience`, so would the next probe's.
///
/// So each run's probe pauses the page for up to two frames (`patience`), and where the
/// reports come late the steps before it pause it for up to two more, once a run.
public struct PhotoGridScrollCalibration: Equatable, Sendable {
    public enum Convention: Equatable, Sendable {
        /// `y` is the content offset.
        case contentOffset
        /// `y` is 0 where the scroll view rests at the top: the content offset plus the top inset.
        case fromRestingTop
    }

    /// The frames after a probe (or the last step before it, review Y1) that ask nothing while
    /// it waits for its report; at the next one it is dropped. The scroll view takes a step with
    /// the next frame and reports it.
    public static let patience = 2

    public private(set) var convention: Convention?
    /// The last step asked, until a report answers it (lands where one of the two ways puts it).
    private var last: Step?
    /// The steps asked whose reports have not come (review Z1): each report that moved the scroll
    /// view is the oldest one's.
    private var onTheirWay = 0
    /// Where the scroll view is, as the last step was asked or as it reported itself since: a
    /// report that did not move it (its content grew) is no step's.
    private var position: Double?
    /// This run of scrolling by itself probes no more: a probe was answered, or its wait ran out
    /// while older steps' reports came (review Z1).
    private var checked = false
    /// This run let the steps before its probe be answered first (review Y1).
    private var cleared = false

    private struct Step: Equatable, Sendable {
        var y: Double
        var insetTop: Double
        /// What it waits for, while nothing else is asked; nil for a step among others.
        var wait: Wait?
        /// The frames it has waited.
        var frames = 0
        /// The last report while it waits: where the scroll view came to rest when the wait ends.
        var heard: Double?

        /// Where the scroll view goes if `scrollTo(y:)` counts the way `convention` says.
        func landing(_ convention: Convention) -> Double {
            convention == .contentOffset ? y : y - insetTop
        }

        /// The way that puts it at `offset`; nil where neither does.
        func way(to offset: Double) -> Convention? {
            if abs(offset - landing(.contentOffset)) < 1 { return .contentOffset }
            if abs(offset - landing(.fromRestingTop)) < 1 { return .fromRestingTop }
            return nil
        }
    }

    /// Why a step waits for its report.
    private enum Wait: Equatable, Sendable {
        /// The run's probe: answered, it teaches.
        case probe
        /// The last step before the probe, asked while the steps before it were on their way
        /// (review Y1): answered, they are all in, and the next step that can tell probes.
        case clearing
    }

    public init() {}

    /// The `y` to ask for, so the scroll view goes to the content offset `offset`, with the top
    /// inset `insetTop`.
    public func y(for offset: Double, insetTop: Double) -> Double {
        convention == .fromRestingTop ? offset + insetTop : offset
    }

    /// A frame of scrolling by itself begins (once a frame, before its step): whether its step
    /// may be asked. Not while a step waits for its report (the probe, or the last step before
    /// it), for `patience` frames; at the next frame the wait ends: where the scroll view came to
    /// rest answers it (review Z1), or it is dropped and stays a step on its way.
    public mutating func mayAsk() -> Bool {
        guard var step = last, step.wait != nil else { return true }
        step.frames += 1
        last = step
        guard step.frames > Self.patience else { return false }
        if let heard = step.heard, let way = step.way(to: heard) {
            answer(step, way)
        } else {
            if step.wait == .probe, step.heard != nil { checked = true }
            last?.wait = nil
        }
        return true
    }

    /// `y` is asked while the scroll view is at `from`, in content offsets `range`. A probe
    /// when the run has no answered probe yet, the step before was answered, and the step can
    /// tell (`tells`). With the step before still on its way (review Y1), a step that can tell,
    /// also from where that one lands either way (so can the probe after it), lets the steps
    /// be answered first, once a run.
    public mutating func asked(_ y: Double, from: Double, insetTop: Double, range: ClosedRange<Double>) {
        let teaches = !checked && Self.tells(y, from: from, insetTop: insetTop, range: range)
        var wait: Wait?
        if let before = last {
            // No probe: the report of the step before could land where one of the two ways puts it.
            if teaches, !cleared, Self.tells(y, from: before.landing(.contentOffset), insetTop: insetTop, range: range),
               Self.tells(y, from: before.landing(.fromRestingTop), insetTop: insetTop, range: range) {
                wait = .clearing
                cleared = true
            }
        } else if teaches {
            wait = .probe
        }
        last = Step(y: y, insetTop: insetTop, wait: wait)
        onTheirWay += 1
        position = from
    }

    /// Whether `y`, asked while the scroll view is at `from`, can tell how `scrollTo(y:)`
    /// counts: the two ways' landings are apart from each other (a top inset of 2 pt or more)
    /// and from no move at all, and neither is cut at an end of the content.
    private static func tells(_ y: Double, from: Double, insetTop: Double, range: ClosedRange<Double>) -> Bool {
        let asOffset = y, fromTop = y - insetTop
        return insetTop >= 2 && fromTop >= range.lowerBound + 1 && asOffset <= range.upperBound - 1
            && abs(asOffset - from) >= 2 && abs(fromTop - from) >= 2
    }

    /// The scroll view reports the content offset `offset`. Where one of the two ways puts the
    /// last step, it answered it, and a probe teaches that way; a waiting step only by its own
    /// report, with no step before it on its way (review Z1). Anything else (not moved yet, moved
    /// by something else, an older step's report) waits for the next report.
    public mutating func reported(_ offset: Double) {
        guard offset != position else { return }
        position = offset
        let own = onTheirWay <= 1
        onTheirWay = max(onTheirWay - 1, 0)
        guard var step = last else { return }
        if step.wait != nil {
            step.heard = offset
            last = step
        }
        guard let way = step.way(to: offset), step.wait == nil || own else { return }
        answer(step, way)
    }

    /// `step` was answered: it landed where `way` puts it.
    private mutating func answer(_ step: Step, _ way: Convention) {
        if step.wait == .probe {
            convention = way
            checked = true
        }
        // A wait that ended with its answer: no step is on its way.
        if step.wait != nil { onTheirWay = 0 }
        last = nil
    }

    /// The grid stopped scrolling by itself: a step not answered tells nothing, and the next
    /// run probes again.
    public mutating func reset() {
        last = nil
        onTheirWay = 0
        position = nil
        checked = false
        cleared = false
    }
}
