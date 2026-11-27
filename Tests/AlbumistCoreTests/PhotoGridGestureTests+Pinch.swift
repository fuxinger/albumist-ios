import Foundation
import Testing
@testable import AlbumistCore

/// Two fingers show three, five or seven photos in a row (`PhotoGridGestureTests`).
extension PhotoGridGestureTests {
    // MARK: Pinch to zoom

    /// Three, five or seven in a row, as Photos offers 3 and 5 among others; three when
    /// nothing was chosen. A stored size from elsewhere is taken to the nearest step.
    @Test func theSteps() {
        #expect(PhotoGridZoom.columns == [3, 5, 7])
        #expect(PhotoGridZoom.standard == 3)
        #expect([0, -2, 1, 2, 3, 4, 5, 6, 7, 8, 40].map(PhotoGridZoom.columns(stored:)) == [3, 3, 3, 3, 3, 3, 5, 5, 7, 7, 7])
        #expect(PhotoGridZoom.fewer(than: 7) == 5 && PhotoGridZoom.fewer(than: 5) == 3 && PhotoGridZoom.fewer(than: 3) == nil)
        #expect(PhotoGridZoom.more(than: 3) == 5 && PhotoGridZoom.more(than: 5) == 7 && PhotoGridZoom.more(than: 7) == nil)
    }

    /// Every photo stays a target of at least 44 pt (design rule 2) on every iPhone from the
    /// smallest (375 pt) to the largest (440 pt) at every step.
    @Test func everyPhotoStaysAFingerWide() {
        for width in [375.0, 390, 393, 402, 414, 428, 430, 440] {
            for columns in PhotoGridZoom.columns {
                let side = PhotoGridZoom.side(width: width, columns: columns)
                #expect(side >= 44, "\(width) pt, \(columns) in a row")
                #expect(abs(side * Double(columns) + PhotoGridZoom.spacing * Double(columns - 1) - width) < 0.001)
            }
        }
        #expect(PhotoGridZoom.side(width: 0, columns: 3) == 0)
    }

    /// Spreading two fingers by a quarter shows fewer, larger photos, pinching by a quarter more,
    /// smaller ones; a long pinch goes on step by step; past the last step a turn back needs a
    /// quarter again, so the grid does not flicker between two steps.
    @Test func aPinchStepsByAQuarter() {
        var pinch = PhotoGridZoom.Pinch(columns: 5)
        #expect(pinch.update(scale: 1.1) == nil)
        #expect(pinch.update(scale: 1.26) == 3)
        #expect(pinch.update(scale: 1.6) == nil, "no fewer than three")
        #expect(pinch.update(scale: 2.0) == nil)
        #expect(pinch.update(scale: 1.7) == nil, "a little back from the furthest")
        #expect(pinch.update(scale: 1.59) == 5, "a quarter back from 2.0")
        #expect(pinch.columns == 5)
        #expect(pinch.update(scale: 1.3) == nil)
        #expect(pinch.update(scale: 1.27) == 7)
        #expect(pinch.update(scale: 0.5) == nil, "no more than seven")
        var out = PhotoGridZoom.Pinch(columns: 3)
        #expect(out.update(scale: 0.79) == 5)
        #expect(out.update(scale: 0.62) == 7)
    }

    /// The photo under the fingers stays under them: the point of the photo the fingers hold
    /// lands where they are, for the alignment the scroll view takes (`scrollTo(id:anchor:)`
    /// lines up the same unit point of the photo and of the visible area).
    @Test func thePhotoUnderTheFingersStaysThere() {
        let height = 600.0
        for side in [51.0, 74, 123] {
            for finger in stride(from: 0.0, through: height, by: 25) {
                for point in [0.0, 0.3, 1] {
                    let unit = PhotoGridZoom.anchor(fingerY: finger, visibleHeight: height, side: side, pointInPhoto: point)
                    #expect((0...1).contains(unit))
                    // Where the photo's top lands, and the held point with it.
                    let top = unit * (height - side)
                    let wanted = finger - point * side
                    if (0...(height - side)).contains(wanted) {
                        #expect(abs(top + point * side - finger) < 0.0001, "\(side) \(finger) \(point)")
                    } else {
                        #expect(abs(top - min(max(wanted, 0), height - side)) < 0.0001, "kept inside the visible area")
                    }
                }
            }
        }
        #expect(PhotoGridZoom.anchor(fingerY: 100, visibleHeight: 50, side: 80, pointInPhoto: 0.5) == 0, "a photo taller than the area")
    }

    /// At five and seven in a row a grid's cell is small (52 pt on a 375-pt iPhone): its photo is
    /// still lifted at least as large as at three in a row, the grids' size before they zoomed and
    /// the menu's lift then, never under 110 pt (review L9); as large as it is sharp from a larger
    /// image kept of it, as at three in a row.
    @Test func aSmallCellsPhotoIsLiftedAsLargeAsAtThreeInARow() {
        let width = 375.0
        let three = PhotoGridZoom.side(width: width, columns: 3)
        let seven = PhotoGridZoom.side(width: width, columns: 7)
        #expect(PhotoGridZoom.liftSide(cell: seven, gridWidth: width) == three)
        #expect(PhotoGridZoom.liftSide(cell: three, gridWidth: width) == three)
        #expect(PhotoGridZoom.liftSide(cell: 50, gridWidth: 300) == 110, "never under 110 pt")
        #expect(PhotoGridZoom.liftSide(cell: 140, gridWidth: 300) == 140, "a larger cell: its own side")
        #expect(PhotoGridZoom.sides(width: width) == [3, 5, 7].map { PhotoGridZoom.side(width: width, columns: $0) })
        let lifted = PhotoGridZoom.liftSide(cell: seven, gridWidth: width)
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
        // Only the cell's own thumbnail at seven in a row (156 px on a 3x screen): as large as at three.
        let small = PhotoMenu.liftSize(imageWidth: 156, imageHeight: 156, scale: 3, cellSide: lifted)
        #expect(close(small.width, three) && close(small.height, three))
        let across = PhotoMenu.liftSize(imageWidth: 208, imageHeight: 156, scale: 3, cellSide: lifted)
        #expect(close(across.height, three) && close(across.aspectRatio, 4.0 / 3.0))
        // The three-in-a-row thumbnail kept: lifted as at three in a row.
        #expect(PhotoMenu.liftSize(imageWidth: 440, imageHeight: 330, scale: 3, cellSide: lifted)
                == PhotoMenu.liftSize(imageWidth: 440, imageHeight: 330, scale: 3, cellSide: three))
        // No image in memory: a square as large as at three in a row.
        let none = PhotoMenu.liftSize(imageWidth: 0, imageHeight: 0, scale: 3, cellSide: lifted)
        #expect(close(none.width, three) && close(none.height, three))
    }

    /// Of the images kept in memory of a photo (at the grid's sizes, and the one a grid showed
    /// last) the one with the most pixels is lifted, the sharpest at any size; on a tie the first
    /// (the cell's own). Nothing kept: none, and nothing is asked of Photos for the lift.
    @Test func theSharpestImageKeptIsLifted() {
        #expect(PhotoGridZoom.sharpestKept([(width: 156, height: 156), (width: 440, height: 330), (width: 260, height: 260)]) == 1)
        #expect(PhotoGridZoom.sharpestKept([(width: 156, height: 156), (width: 156, height: 156)]) == 0)
        #expect(PhotoGridZoom.sharpestKept([]) == nil)
    }

    /// Calm: the new size settles from the old one around the fingers, a little in from far
    /// out (Reduce Motion: no settling at all, in the app).
    @Test func theSettleScale() {
        #expect(PhotoGridZoom.settleScale(oldSide: 123, newSide: 74) > 1, "pinched in: settles from larger")
        #expect(abs(PhotoGridZoom.settleScale(oldSide: 74, newSide: 123) - 0.85) < 0.0001, "spread: a little only")
        #expect(PhotoGridZoom.settleScale(oldSide: 123, newSide: 51) <= 1.7)
        #expect(PhotoGridZoom.settleScale(oldSide: 0, newSide: 51) == 1)
    }
}
