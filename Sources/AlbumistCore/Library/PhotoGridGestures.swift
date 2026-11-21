import Foundation

// Drag to select and pinch to zoom in the photo grids (design wave 3, DS-06b): what the gestures decide.

/// A rectangle of a photo grid in points (the app's `CGRect`, kept in the core as numbers).
public struct GridRect: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        minX = x
        minY = y
        maxX = x + width
        maxY = y + height
    }
}

/// Drag to select in a photo grid (design wave 3, DS-06b), as in Photos: while the grid
/// selects ("Auswählen"), a finger drawn across the photos ticks every photo from the first one
/// it touched to the one under it, in the grid's order (row by row, day after day); when the
/// first photo was ticked, it unticks instead. Moving back shrinks the range again, and the
/// photos it leaves are as they were before the drag. Positions count the grid's photos in its
/// order (the headers are no positions), so a range runs on across rows and days.
public struct PhotoGridDrag: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case select, deselect
    }

    /// What one move of the finger changes: the positions that take the drag's mode, and the
    /// ones that go back to how they were before the drag.
    public struct Change: Equatable, Sendable {
        public var marked: [ClosedRange<Int>]
        public var restored: [ClosedRange<Int>]

        public init(marked: [ClosedRange<Int>] = [], restored: [ClosedRange<Int>] = []) {
            self.marked = marked
            self.restored = restored
        }

        public var isEmpty: Bool { marked.isEmpty && restored.isEmpty }
    }

    /// The photo the drag began on.
    public let anchor: Int
    public let mode: Mode
    /// The photo under the finger now.
    public private(set) var current: Int

    /// A drag begins on the photo at `anchor`: it ticks, or unticks when that photo was ticked.
    public init(anchor: Int, anchorWasSelected: Bool) {
        self.anchor = anchor
        current = anchor
        mode = anchorWasSelected ? .deselect : .select
    }

    /// The photos the drag covers now.
    public var range: ClosedRange<Int> { min(anchor, current)...max(anchor, current) }

    /// The change of the drag's beginning: its first photo.
    public var start: Change { Change(marked: [anchor...anchor]) }

    /// The finger is over the photo at `position` now: the photos the range takes in, and the
    /// ones it gives back (only the difference, so a long range costs nothing per move).
    public mutating func move(to position: Int) -> Change {
        let old = range
        current = position
        let new = range
        var change = Change()
        if new.lowerBound < old.lowerBound { change.marked.append(new.lowerBound...(old.lowerBound - 1)) }
        if new.upperBound > old.upperBound { change.marked.append((old.upperBound + 1)...new.upperBound) }
        if old.lowerBound < new.lowerBound { change.restored.append(old.lowerBound...(new.lowerBound - 1)) }
        if old.upperBound > new.upperBound { change.restored.append((new.upperBound + 1)...old.upperBound) }
        return change
    }

    /// The selection, as positions, the drag makes now of `base` (the selection when it began).
    public func selection(from base: Set<Int>) -> Set<Int> {
        switch mode {
        case .select: return base.union(range)
        case .deselect: return base.subtracting(range)
        }
    }

    /// Whether a finger that moved by `dx`, `dy` before the drag was recognized starts a
    /// selection: only a mostly sideways start, as in Photos. A vertical or diagonal one (45° or
    /// steeper) scrolls the grid as before.
    public static func startsSelection(dx: Double, dy: Double) -> Bool {
        abs(dx) > abs(dy)
    }

    /// `change` applied to `selection`: the marked positions take `mode`, the restored ones go
    /// back to `base` (the selection before the drag). `ids`: the grid's photos in its order;
    /// positions beyond them change nothing.
    public static func apply<ID: Hashable>(_ change: Change, mode: Mode, to selection: inout Set<ID>, base: Set<ID>, ids: [ID]) {
        func positions(_ range: ClosedRange<Int>) -> ClosedRange<Int>? {
            let low = max(range.lowerBound, 0), high = min(range.upperBound, ids.count - 1)
            return low <= high ? low...high : nil
        }
        for range in change.marked {
            guard let valid = positions(range) else { continue }
            for position in valid {
                switch mode {
                case .select: selection.insert(ids[position])
                case .deselect: selection.remove(ids[position])
                }
            }
        }
        for range in change.restored {
            guard let valid = positions(range) else { continue }
            for position in valid {
                let id = ids[position]
                if base.contains(id) { selection.insert(id) } else { selection.remove(id) }
            }
        }
    }
}

/// Which photo of a grid is under a finger, from the frames of the photos on screen.
public enum PhotoGridHitTest {
    /// The position of the photo at (`x`, `y`) among `cells` (position and frame, in one space):
    /// the photo under it; in the gap between two photos of a row the nearer one; beside a row
    /// its first or last photo (a short last row of a day: its last). Nil between rows, on a
    /// day's header and where no photo is: the drag keeps the photo it has.
    public static func position(x: Double, y: Double, in cells: [(position: Int, frame: GridRect)]) -> Int? {
        var best: (position: Int, distance: Double)?
        for cell in cells where cell.frame.minY <= y && y <= cell.frame.maxY {
            let distance = x < cell.frame.minX ? cell.frame.minX - x : (x > cell.frame.maxX ? x - cell.frame.maxX : 0)
            if best == nil || distance < best!.distance || (distance == best!.distance && cell.position < best!.position) {
                best = (cell.position, distance)
            }
        }
        return best?.position
    }
}

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
}

/// Pinch to zoom in a photo grid (DS-06b): two fingers change the number of photos in a row in
/// steps and keep the place (the photo under the fingers stays under them).
public enum PhotoGridZoom {
    /// Photos in a row: three (large, the grids' size so far and Photos' first step on an
    /// iPhone), five (Photos' next step) and seven (an overview; each photo still a 44-pt target
    /// on the smallest iPhone, design rule 2, which nine would not be).
    public static let columns = [3, 5, 7]
    /// Until the user pinches.
    public static let standard = 3
    /// Between two photos, across and down, as in Photos and the suggestion's draft (E2).
    public static let spacing: Double = 2
    /// Two fingers spread or pinched by a quarter make one step.
    public static let stepScale: Double = 1.25

    /// A stored size (`@AppStorage`) taken to the nearest step; on a tie the larger photos;
    /// nothing sensible stored: the standard.
    public static func columns(stored: Int) -> Int {
        guard stored > 0 else { return standard }
        return columns.min { a, b in
            let da = abs(a - stored), db = abs(b - stored)
            return da != db ? da < db : a < b
        } ?? standard
    }

    /// The next step with fewer, larger photos; nil at the largest.
    public static func fewer(than current: Int) -> Int? {
        columns.last { $0 < current }
    }

    /// The next step with more, smaller photos; nil at the smallest.
    public static func more(than current: Int) -> Int? {
        columns.first { $0 > current }
    }

    /// The side of one photo in a row of `columns` across `width` points.
    public static func side(width: Double, columns: Int) -> Double {
        guard width > 0, columns > 0 else { return 0 }
        return max(0, (width - spacing * Double(columns - 1)) / Double(columns))
    }

    /// One pinch: a step each time the fingers spread (fewer photos) or pinch (more) by
    /// `stepScale` since the last step. Past the last step the furthest scale counts, so turning
    /// back needs a full step again and the grid never flickers between two steps.
    public struct Pinch: Equatable, Sendable {
        public private(set) var columns: Int
        /// The pinch's scale at the last step (or the furthest past the last one).
        private var reference = 1.0

        public init(columns: Int) {
            self.columns = columns
        }

        /// The new number in a row once the pinch's scale (from its start) is `scale`; nil while
        /// it stays.
        public mutating func update(scale: Double) -> Int? {
            guard scale > 0 else { return nil }
            if scale >= reference * stepScale {
                guard let next = PhotoGridZoom.fewer(than: columns) else {
                    reference = max(reference, scale)
                    return nil
                }
                columns = next
                reference = scale
                return next
            }
            if scale * stepScale <= reference {
                guard let next = PhotoGridZoom.more(than: columns) else {
                    reference = min(reference, scale)
                    return nil
                }
                columns = next
                reference = scale
                return next
            }
            return nil
        }
    }

    /// The alignment (a unit point's y) to scroll the photo the fingers hold to
    /// (`ScrollPosition.scrollTo(id:anchor:)`, which lines up the same unit point of the photo
    /// and of the visible area), so its point `pointInPhoto` (0 its top, 1 its bottom) lands at
    /// `fingerY` from the visible area's top: for a photo of `side` points in an area of
    /// `visibleHeight`. Kept between 0 and 1: the photo stays wholly visible.
    public static func anchor(fingerY: Double, visibleHeight: Double, side: Double, pointInPhoto: Double) -> Double {
        let room = visibleHeight - side
        guard room > 0 else { return 0 }
        return min(max((fingerY - pointInPhoto * side) / room, 0), 1)
    }

    /// The scale the grid settles from after a step, around the fingers (not under Reduce
    /// Motion): the old photos' size, so the step looks like a zoom; from far out only a little
    /// in (`0.85`: the grid shows only what it has laid out) and at most 1.7 times.
    public static func settleScale(oldSide: Double, newSide: Double) -> Double {
        guard oldSide > 0, newSide > 0 else { return 1 }
        return min(max(oldSide / newSide, 0.85), 1.7)
    }
}
