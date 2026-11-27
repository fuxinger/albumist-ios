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
/// own, however soon (a tap right after a drag ticks or unticks, one right after a pinch opens),
/// and so does an activation that comes later without a touch (VoiceOver's double tap, Switch
/// Control): the lift comes with the gesture's end, within `window` of it (review W3).
public struct PhotoGridLift: Equatable, Sendable {
    /// How long after a gesture's end a tap may still be its lift, in seconds: UIKit hands the
    /// lift to the button with the end, or a frame or two after it.
    public static let window = 0.5
    /// The gestures running (a drag and a pinch may run at once).
    private var running = 0
    /// When the last gesture ended (seconds on a clock that never jumps), while no finger touched
    /// the grid since.
    private var ended: Double?

    public init() {}

    public mutating func gestureBegan() {
        running += 1
    }

    /// A gesture ended at `time`.
    public mutating func gestureEnded(at time: Double) {
        running = max(0, running - 1)
        ended = time
    }

    /// A finger touched the grid: once no gesture runs, what follows is no gesture's lift. A
    /// finger that touches while one runs (a pinch's second finger) is part of it.
    public mutating func touchedDown() {
        if running == 0 { ended = nil }
    }

    /// Whether a tap on a photo at `time` is a gesture's, not one of its own: while one runs, and
    /// within `window` of the last one's end before a finger touched again.
    public func swallowsTap(at time: Double) -> Bool {
        if running > 0 { return true }
        guard let ended else { return false }
        return time - ended < Self.window
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
        var seen: [Seen] = []
        for (key, report) in reports {
            let box = frame(report.value)
            if let visible, box.maxY < visible.lowerBound || box.minY > visible.upperBound { continue }
            guard counts(key, report.value) else { continue }
            seen.append(Seen(key: key, value: report.value, frame: box, made: report.made))
        }
        seen.sort { $0.made > $1.made }
        var shown: [Seen] = []
        shown.reserveCapacity(seen.count)
        for report in seen where !shown.contains(where: { $0.frame.overlaps(report.frame) }) {
            shown.append(report)
        }
        return shown.map { (key: $0.key, value: $0.value) }
    }

    /// A report on screen: its frame, and its number (later ones are higher).
    private struct Seen {
        var key: Key
        var value: Value
        var frame: GridRect
        var made: Int
    }
}
