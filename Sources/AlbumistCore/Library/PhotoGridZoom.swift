import Foundation

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
