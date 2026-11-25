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

    public var height: Double { maxY - minY }

    /// Whether it and `other` lie over each other by more than a sliver (a point each way):
    /// neighbours that touch or lie 2 pt apart do not.
    public func overlaps(_ other: GridRect) -> Bool {
        min(maxX, other.maxX) - max(minX, other.minX) > 1 && min(maxY, other.maxY) - max(minY, other.minY) > 1
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

    /// The drag over the grid's photos `old` (in its order when the range was made) over `new`
    /// (in its order now: more photos loaded, the days made anew; review L3): the same photos
    /// from the first to the one under the finger, where they are now. Nil when they are no
    /// longer together in that order (one of them went, or one came between): there is no range
    /// to keep, and the drag ends with its photos ticked as they are.
    public func rebased<ID: Equatable>(from old: [ID], to new: [ID]) -> PhotoGridDrag? {
        let range = self.range
        guard range.lowerBound >= 0, range.upperBound < old.count else { return nil }
        let photos = old[range]
        // In place: what changed is before or after the range (more photos loaded below).
        if range.upperBound < new.count, new[range] == photos { return self }
        guard let first = new.firstIndex(of: photos[range.lowerBound]), first + range.count <= new.count,
              new[first..<(first + range.count)] == photos else { return nil }
        let shift = first - range.lowerBound
        var moved = PhotoGridDrag(anchor: anchor + shift, anchorWasSelected: mode == .deselect)
        moved.current = current + shift
        return moved
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

/// The lift that ends a drag or a pinch, which UIKit may hand a photo's button too as a tap,
/// before or right after the gesture's end (review L8 of design wave 3): it neither ticks nor
/// opens a photo, as the drag ticked its first photo already and a pinch opens nothing. Only
/// that lift: once no gesture runs, the next finger that touches the grid begins a tap of its
/// own, however soon (a tap right after a drag ticks or unticks, one right after a pinch opens).
public struct PhotoGridLift: Equatable, Sendable {
    /// The gestures running (a drag and a pinch may run at once).
    private var running = 0
    /// A gesture ended and no finger touched since: a tap now is its lift.
    private var lifting = false

    public init() {}

    public mutating func gestureBegan() {
        running += 1
    }

    public mutating func gestureEnded() {
        running = max(0, running - 1)
        lifting = true
    }

    /// A finger touched the grid: once no gesture runs, what follows is no gesture's lift. A
    /// finger that touches while one runs (a pinch's second finger) is part of it.
    public mutating func touchedDown() {
        if running == 0 { lifting = false }
    }

    /// Whether a tap on a photo now is a gesture's, not one of its own.
    public var swallowsTap: Bool {
        running > 0 || lifting
    }
}

/// Which photo of a grid is under a finger, from the frames of the photos on screen.
public enum PhotoGridHitTest {
    /// What a finger on what lies over the photos (a day's header pinned over the photos
    /// scrolling under it) is on.
    public enum Covered: Sendable {
        /// No photo: the drag ticks nothing the user cannot see, and one that begins there waits
        /// for the finger to reach a photo (review L4).
        case noPhoto
        /// The first row below it, at the finger's place across: a running drag goes on with the
        /// rows that come out below the header while the page scrolls up under the finger
        /// (review W2). One that lies over no photo (a header in its own place) is on none.
        case rowBelow
    }

    /// The position of the photo at (`x`, `y`) among `cells` (position and frame, in one space):
    /// the photo under it; in the gap between two photos of a row the nearer one; beside a row
    /// its first or last photo (a short last row of a day: its last). Nil between rows, on a
    /// day's header and where no photo is: the drag keeps the photo it has. `covered`: what lies
    /// over the photos there (a day's header pinned over the photos scrolling under it); a point
    /// on it is on what `onCovered` says.
    public static func position(x: Double, y: Double, in cells: [(position: Int, frame: GridRect)],
                                covered: [GridRect] = [], onCovered: Covered = .noPhoto) -> Int? {
        let over = covered.filter { $0.minX <= x && x <= $0.maxX && $0.minY <= y && y <= $0.maxY }
        guard !over.isEmpty else { return under(x: x, y: y, in: cells) }
        guard onCovered == .rowBelow,
              let bottom = over.filter({ header in cells.contains { $0.frame.overlaps(header) } }).map(\.maxY).max(),
              let top = cells.lazy.filter({ $0.frame.maxY > bottom }).map(\.frame.minY).min()
        else { return nil }
        // The first row below it: of the photos that reach below its bottom, the highest ones.
        let row = cells.filter { $0.frame.maxY > bottom && $0.frame.minY - top < 0.5 }
        guard let first = row.first else { return nil }
        return under(x: x, y: (first.frame.minY + first.frame.maxY) / 2, in: row)
    }

    /// The photo at (`x`, `y`) among `cells`, nothing lying over them.
    private static func under(x: Double, y: Double, in cells: [(position: Int, frame: GridRect)]) -> Int? {
        var best: (position: Int, distance: Double)?
        for cell in cells where cell.frame.minY <= y && y <= cell.frame.maxY {
            let distance = x < cell.frame.minX ? cell.frame.minX - x : (x > cell.frame.maxX ? x - cell.frame.maxX : 0)
            if best == nil || distance < best!.distance || (distance == best!.distance && cell.position < best!.position) {
                best = (cell.position, distance)
            }
        }
        return best?.position
    }

    /// The part of a grid that its scroll view shows, from top to bottom in the grid's space, for
    /// a finger at `gridY` in the grid and at `scrollViewY` in the scroll view (its own space,
    /// which moves with it), in a scroll view `height` points high (review W1). Nil while the
    /// height is not known: every photo laid out counts then.
    public static func visiblePart(gridY: Double, scrollViewY: Double, height: Double?) -> ClosedRange<Double>? {
        guard let height, height > 0 else { return nil }
        let top = gridY - scrollViewY
        return top...(top + height)
    }

    /// The position of the photo two fingers hold at (`x`, `y`), whose place a zoom keeps: the
    /// photo under them (`position(x:y:in:)`), else the nearest one (between rows, on a header,
    /// beside or past the grid); on a tie the earlier one. Nil when no photo is on screen.
    public static func nearest(x: Double, y: Double, in cells: [(position: Int, frame: GridRect)]) -> Int? {
        if let under = position(x: x, y: y, in: cells) { return under }
        var best: (position: Int, distance: Double)?
        for cell in cells {
            let dx = x < cell.frame.minX ? cell.frame.minX - x : (x > cell.frame.maxX ? x - cell.frame.maxX : 0)
            let dy = y < cell.frame.minY ? cell.frame.minY - y : (y > cell.frame.maxY ? y - cell.frame.maxY : 0)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance || (distance == best!.distance && cell.position < best!.position) {
                best = (cell.position, distance)
            }
        }
        return best?.position
    }
}

/// How a grid lays its photos out (review W1 of design wave 3): photos in a row and the grid's
/// width in points (0 while it was not measured yet). Each photo's frame changes with either.
public struct PhotoGridLayout: Equatable, Sendable {
    public var columns: Int
    public var width: Double

    public init(columns: Int, width: Double) {
        self.columns = columns
        self.width = width
    }
}

/// What of a photo grid is on screen, for its gestures: where its photos (or its days' headers)
/// are, from the frames each one reported last (review W1 of design wave 3). On screen is what
/// lies in the part of the grid the scroll view shows now, read from the frames themselves, never
/// from SwiftUI's word that a view appeared or went: SwiftUI promises neither the order of those
/// words (a rebuilt cell may appear before the old one goes, and "Auswählen" and "Fertig" rebuild
/// every photo on screen) nor that they come in pairs (a swipe back that is called off).
///
/// - A frame in the grid's own space does not move while the page scrolls, and SwiftUI reports
///   it anew whenever it changes: what a photo reported stays true while it is away (its page
///   left for another tab or page and shown again, review L1) until the grid lays its photos out
///   anew (`laidOut`). Then every report of before is dropped, and the photos on screen report
///   their new frames.
/// - One report per photo, the latest. Of two photos' reports at one place the later one counts:
///   the other is of a photo that went before it could report its move (a day's header grew
///   while it was away), and the photo there now reported after it.
/// - Kept for the latest `kept` reports (at most twice as many before the older ones are
///   cleared): scrolling through a large library keeps no more, and the photos on screen, which
///   reported last, are always among them.
public struct PhotoGridOnScreen<Key: Hashable, Value> {
    /// The reports kept: many more than the photos on one screen, even at seven in a row.
    public static var kept: Int { 1_000 }

    private var reports: [Key: (value: Value, made: Int)] = [:]
    /// Reports made so far, which orders them.
    private var made = 0
    private var layout: PhotoGridLayout?

    public init() {}

    /// How many reports are kept.
    public var count: Int { reports.count }

    /// The grid lays its photos out as `layout` (each of its bodies says so): another number in a
    /// row or another width makes every report of before stale, and it is dropped. The grid's
    /// first width (from 0, not measured yet) changes nothing: its photos were laid out at that
    /// width already, and report nothing anew.
    public mutating func laidOut(_ layout: PhotoGridLayout) {
        let width = layout.width > 0 ? layout.width : (self.layout?.width ?? 0)
        let now = PhotoGridLayout(columns: layout.columns, width: width)
        if let before = self.layout,
           before.columns != now.columns || (before.width > 0 && abs(before.width - now.width) > 0.5) {
            reports = [:]
        }
        self.layout = now
    }

    /// `key` reports `value`: where it is (its frame among it), in the layout now.
    public mutating func report(_ key: Key, _ value: Value) {
        made += 1
        reports[key] = (value, made)
        if reports.count > 2 * Self.kept {
            let oldest = made - Self.kept
            reports = reports.filter { $0.value.made > oldest }
        }
    }

    /// What is on screen: of the reports that count (`counts`; a photo still at the place in the
    /// grid's order it reported, say), the ones whose frame (`frame`) meets `visible` (the part
    /// of the grid the scroll view shows, from top to bottom in the grid's space; nil: all of
    /// them), less each one a later report at the same place replaced.
    public func onScreen(_ visible: ClosedRange<Double>?, frame: (Value) -> GridRect,
                         where counts: (Key, Value) -> Bool = { _, _ in true }) -> [(key: Key, value: Value)] {
        var seen: [(key: Key, value: Value, frame: GridRect, made: Int)] = []
        for (key, report) in reports {
            let box = frame(report.value)
            if let visible, box.maxY < visible.lowerBound || box.minY > visible.upperBound { continue }
            guard counts(key, report.value) else { continue }
            seen.append((key, report.value, box, report.made))
        }
        seen.sort { $0.made > $1.made }
        var shown: [(key: Key, value: Value, frame: GridRect)] = []
        shown.reserveCapacity(seen.count)
        for report in seen where !shown.contains(where: { $0.frame.overlaps(report.frame) }) {
            shown.append((report.key, report.value, report.frame))
        }
        return shown.map { (key: $0.key, value: $0.value) }
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

    /// How `ScrollPosition.scrollTo(y:)` counts, learned from the scroll view (review L5 of
    /// design wave 3): SwiftUI's documentation does not say whether `y` is the scroll view's
    /// content offset (minus the top inset at rest at the top, as `ScrollGeometry` reports it)
    /// or counts from where the scroll view rests at the top. A step asked as the content offset
    /// tells: the scroll view then reports the same, or less by the top inset. Until a step told
    /// (and where the top inset is too small to tell, so both ways agree) `y` is taken as the
    /// content offset; once known, for the app's life, the steps ask so the scroll view goes
    /// where they mean, at most one step off on the way.
    public struct Calibration: Equatable, Sendable {
        public enum Convention: Equatable, Sendable {
            /// `y` is the content offset.
            case contentOffset
            /// `y` is 0 where the scroll view rests at the top: the content offset plus the top inset.
            case fromRestingTop
        }

        public private(set) var convention: Convention?
        /// A step asked while the convention is not known, which can tell it.
        private var probe: Probe?

        private struct Probe: Equatable, Sendable {
            var y: Double
            var insetTop: Double
        }

        public init() {}

        /// The `y` to ask for, so the scroll view goes to the content offset `offset`, with the top
        /// inset `insetTop`.
        public func y(for offset: Double, insetTop: Double) -> Double {
            convention == .fromRestingTop ? offset + insetTop : offset
        }

        /// `y` was asked while the scroll view was at `from`, in content offsets `range`. While the
        /// convention is not known it is a step that tells, when the two ways' answers are apart
        /// from each other (a top inset of 2 pt or more) and from no move at all, and neither is
        /// cut at an end of the content.
        public mutating func asked(_ y: Double, from: Double, insetTop: Double, range: ClosedRange<Double>) {
            guard convention == nil, probe == nil, insetTop >= 2 else { return }
            let asOffset = y, fromTop = y - insetTop
            guard fromTop >= range.lowerBound + 1, asOffset <= range.upperBound - 1,
                  abs(asOffset - from) >= 2, abs(fromTop - from) >= 2 else { return }
            probe = Probe(y: y, insetTop: insetTop)
        }

        /// The scroll view reports the content offset `offset`: at the step's `y` it takes the
        /// content offset, less by the top inset it counts from the top; anything else (not moved
        /// yet, moved by something else) waits for the next report.
        public mutating func reported(_ offset: Double) {
            guard let probe else { return }
            if abs(offset - probe.y) < 1 {
                convention = .contentOffset
                self.probe = nil
            } else if abs(offset - (probe.y - probe.insetTop)) < 1 {
                convention = .fromRestingTop
                self.probe = nil
            }
        }

        /// The grid stopped scrolling by itself: a step not answered tells nothing.
        public mutating func reset() {
            probe = nil
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

    /// The sides of a grid `width` points wide at each of its sizes (three, five and seven in a
    /// row): the sides its thumbnails are asked for, where a photo's images may be kept.
    public static func sides(width: Double) -> [Double] {
        columns.map { side(width: width, columns: $0) }
    }

    /// The smallest a photo of a grid `gridWidth` points wide is lifted by its long press on its
    /// short side, for a cell of `cell` points (review L9 of design wave 3): as large as at three
    /// in a row (the grids' size before they zoomed, and the menu's lift then), never under
    /// 110 pt (the grids' photos before), also at five and seven in a row, where the cell is much
    /// smaller; the cell's own side where it is larger. The lift's floor
    /// (`PhotoMenu.liftSize(cellSide:)`).
    public static func liftSide(cell: Double, gridWidth: Double) -> Double {
        max(cell, 110, side(width: gridWidth, columns: standard))
    }

    /// Of the images kept in memory of a photo (`width` × `height` pixels each: at the grid's
    /// sizes, and the one a grid showed last), the one its long press lifts: the one with the most
    /// pixels, the sharpest at any size; on a tie the first (the cell's own). Nil when none is
    /// kept: the lift asks Photos for nothing of its own (review L9).
    public static func sharpestKept(_ images: [(width: Double, height: Double)]) -> Int? {
        var best: (index: Int, pixels: Double)?
        for (index, image) in images.enumerated() {
            let pixels = image.width * image.height
            if best == nil || pixels > best!.pixels { best = (index, pixels) }
        }
        return best?.index
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
