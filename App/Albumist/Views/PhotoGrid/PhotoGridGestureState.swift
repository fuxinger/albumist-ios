import SwiftUI
import UIKit
import AlbumistCore

/// What the grid's gestures (`PhotoGridSelectDrag`, `PhotoGridPinch`) keep while they run, apart
/// from what the grid draws: where its photos on screen are, the drag's range and the pinch's
/// steps. A class in the grid's state that is not observed: a finger's move changes the
/// selection (which the grid draws) and nothing else, and the frames the photos report draw
/// nothing again. What the gestures decide is the core's (`PhotoGridDrag`, `PhotoGridHitTest`,
/// `PhotoGridAutoScroll`, `PhotoGridZoom`).
@MainActor
final class PhotoGridGestureState {
    /// The photos on screen: their place in the grid's order and their frames in the grid, as
    /// each photo reports them (`PhotoGrid.cell`); kept while a photo is away, so the photos of
    /// a page shown again, which report nothing new, are found (review L1).
    private var photos = PhotoGridOnScreen<AssetID, PhotoGridPlace>()
    /// The days' headers on screen and their frames in the grid, by day: pinned, one lies over
    /// the photos scrolling under it, and a finger on it is on none of them (review L4).
    private var headers = PhotoGridOnScreen<Int, CGRect>()
    /// The photos the grid shows now, as each of its bodies hands them over (`show`), and their
    /// order, made when a gesture asks and again only when they changed (`order()`).
    private var shown = PhotoGridShown([])
    private var made: (shown: PhotoGridShown, ids: [AssetID])?
    private var drag: Drag?
    /// A drag that began where no photo is (on a day's header): it begins at the first photo the
    /// finger reaches.
    private var waiting: Waiting?
    private var zooming: Zooming?
    /// The lift that ends a drag or a pinch is no tap of its own, only that lift
    /// (`swallowsTap`, review L8).
    private var lift = PhotoGridLift()
    let ticker = PhotoGridTicker()

    /// One drag to select.
    private struct Drag {
        var range: PhotoGridDrag
        /// The selection when the drag began: what the photos the range gives back return to.
        var base: Set<AssetID>
        /// The grid's photos in the order the range counts in (`follow()` keeps it the grid's
        /// order now).
        var ids: [AssetID]
        var selection: Binding<Set<AssetID>>
        var scroller: PhotoGridScroller?
        /// The finger at its last move, in the grid and in the scroll view, and the scroll
        /// view's offset then: while the grid scrolls by itself under the still finger, the
        /// finger is over the photos the offset brought there.
        var inGrid: CGPoint
        var inScrollView: CGPoint
        var offset: Double
    }

    private struct Waiting {
        var selection: Binding<Set<AssetID>>
        var scroller: PhotoGridScroller?
    }

    /// One pinch.
    private struct Zooming {
        var steps: PhotoGridZoom.Pinch
        /// The photo the fingers hold, and the point of it under them (0 its top, 1 its bottom).
        var photo: AssetID?
        var pointInPhoto: Double
        var scroller: PhotoGridScroller?
    }

    /// One step of a pinch, for the grid: from and to how many photos in a row, the photo the
    /// fingers hold and where they are, so the grid scrolls it there (`PhotoGridZoom.anchor`).
    struct ZoomStep {
        var from: Int
        var to: Int
        var photo: AssetID?
        var pointInPhoto: Double
        /// The fingers from the top of the scroll view's visible area, and that area's height.
        var fingerY: Double
        var visibleHeight: Double
        /// The fingers in the scroll view, where the grid settles around (`PhotoGridSettle`).
        var point: CGPoint
    }

    // MARK: The photos on screen

    func place(_ id: AssetID, _ place: PhotoGridPlace) {
        photos.report(id, place)
    }

    func appeared(_ id: AssetID) {
        photos.appeared(id)
    }

    func disappeared(_ id: AssetID) {
        photos.disappeared(id)
    }

    func header(_ day: Int, _ frame: CGRect) {
        headers.report(day, frame)
    }

    func headerAppeared(_ day: Int) {
        headers.appeared(day)
    }

    func headerDisappeared(_ day: Int) {
        headers.disappeared(day)
    }

    /// What lies over the photos: the headers on screen (a pinned one over the photos under it).
    private var covered: [GridRect] {
        headers.shown.values.map(GridRect.init)
    }

    /// The photos on screen of the grid whose photos are `ids`, in its order, with their frames.
    /// A photo that reports a place in another order (the days changed and it is about to go)
    /// is left out.
    private func cells(in ids: [AssetID]) -> [(position: Int, frame: GridRect)] {
        photos.shown.compactMap { id, place in
            guard place.position >= 0, place.position < ids.count, ids[place.position] == id else { return nil }
            return (position: place.position, frame: GridRect(place.frame))
        }
    }

    // MARK: Drag to select

    // MARK: The photos the grid shows

    /// The grid shows `shown` now (each of its bodies hands it over; nothing is made here).
    func show(_ shown: PhotoGridShown) {
        self.shown = shown
    }

    /// The photos the grid shows now in its order: made again only when they changed, so a drag
    /// that follows them each frame costs nothing while they stay.
    private func order() -> [AssetID] {
        if let made, made.shown.isSame(as: shown) { return made.ids }
        let ids = shown.ids
        made = (shown, ids)
        return ids
    }

    /// The same array (its storage), whatever its contents: both are alive here, so no other
    /// array can have the same storage.
    private static func same(_ a: [AssetID], _ b: [AssetID]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }

    // MARK: Drag to select

    /// A finger began to draw sideways across the grid.
    func beginDrag(_ touch: PhotoGridTouch, selection: Binding<Set<AssetID>>, scroller: PhotoGridScroller?) {
        endDrag()
        lift.gestureBegan()
        // Where the finger touched: the pan begins only once it moved a little.
        let touched = CGPoint(x: touch.inGrid.x - touch.moved.x, y: touch.inGrid.y - touch.moved.y)
        waiting = Waiting(selection: selection, scroller: scroller)
        start(touch, at: [touched, touch.inGrid])
    }

    func moveDrag(_ touch: PhotoGridTouch) {
        guard var current = drag else {
            if waiting != nil { start(touch, at: [touch.inGrid]) }
            return
        }
        current.inGrid = touch.inGrid
        current.inScrollView = touch.inScrollView
        current.offset = current.scroller?.offset ?? 0
        drag = current
        extend(to: touch.inGrid)
        followEdges()
    }

    func endDrag() {
        ticker.stop()
        drag?.scroller?.endAutoScroll()
        if drag != nil || waiting != nil { lift.gestureEnded() }
        drag = nil
        waiting = nil
    }

    /// Whether a tap on a photo now is the lift that ends a drag or a pinch (UIKit may hand it to
    /// the photo's button too, before or right after the gesture's end): it neither ticks nor
    /// opens a photo of its own. A tap after the next finger touched is a tap again
    /// (`PhotoGridLift`).
    var swallowsTap: Bool {
        lift.swallowsTap
    }

    /// A finger touched the grid (either gesture's recognizer tells).
    func touchedDown() {
        lift.touchedDown()
    }

    /// The range begins at the first of `points` with a photo under it; with none the drag
    /// waits for the finger to reach one.
    private func start(_ touch: PhotoGridTouch, at points: [CGPoint]) {
        guard let pending = waiting else { return }
        let ids = order()
        let onScreen = cells(in: ids)
        let covered = self.covered
        let found = points.lazy.compactMap { point in
            PhotoGridHitTest.position(x: Double(point.x), y: Double(point.y), in: onScreen, covered: covered)
        }.first
        guard let anchor = found else { return }
        let base = pending.selection.wrappedValue
        let range = PhotoGridDrag(anchor: anchor, anchorWasSelected: base.contains(ids[anchor]))
        waiting = nil
        drag = Drag(range: range, base: base, ids: ids, selection: pending.selection, scroller: pending.scroller,
                    inGrid: touch.inGrid, inScrollView: touch.inScrollView, offset: pending.scroller?.offset ?? 0)
        apply(range.start)
        extend(to: touch.inGrid)
        followEdges()
    }

    /// The finger is at `point` in the grid: the range runs to the photo under it; between rows
    /// and on a header (also one pinned over photos) it keeps the photo it has.
    private func extend(to point: CGPoint) {
        follow()
        guard var current = drag,
              let position = PhotoGridHitTest.position(x: Double(point.x), y: Double(point.y), in: cells(in: current.ids),
                                                       covered: covered)
        else { return }
        let change = current.range.move(to: position)
        drag = current
        apply(change)
    }

    /// The grid shows other photos than the range counts in (more were loaded below, the days
    /// were made anew): the range follows its photos by id into the grid's order now
    /// (`PhotoGridDrag.rebased`), or, where they are no longer together, the drag ends, its photos
    /// ticked as they are (review L3).
    private func follow() {
        guard let current = drag else { return }
        let now = order()
        guard !Self.same(now, current.ids) else { return }
        guard let range = current.range.rebased(from: current.ids, to: now) else {
            endDrag()
            return
        }
        drag?.range = range
        drag?.ids = now
    }

    /// Ticks or unticks what the range took in, and gives back what it left.
    private func apply(_ change: PhotoGridDrag.Change) {
        guard let current = drag, !change.isEmpty else { return }
        var selected = current.selection.wrappedValue
        PhotoGridDrag.apply(change, mode: current.range.mode, to: &selected, base: current.base, ids: current.ids)
        if selected != current.selection.wrappedValue { current.selection.wrappedValue = selected }
    }

    // MARK: Scrolling by itself

    /// While the finger is near the top or bottom edge, the screen's frame clock runs and the
    /// grid scrolls on under the still finger.
    private func followEdges() {
        guard edgeSpeed() != 0 else { return }
        ticker.start { [weak self] seconds in self?.scrollStep(seconds) ?? false }
    }

    /// The speed for where the finger is now, in the part of the scroll view the user sees (below
    /// the bars); 0 in the middle, and without a scroll view to move.
    private func edgeSpeed() -> Double {
        guard let current = drag, let scroller = current.scroller, let area = scroller.seenArea else { return 0 }
        return PhotoGridAutoScroll.speed(y: Double(current.inScrollView.y), top: area.lowerBound, bottom: area.upperBound)
    }

    /// One frame of scrolling by itself; false stops the clock (the finger left the edge, or the
    /// drag ended because its range could not follow the photos the grid shows now).
    private func scrollStep(_ seconds: Double) -> Bool {
        guard let current = drag, let scroller = current.scroller else { return false }
        let speed = edgeSpeed()
        guard speed != 0 else {
            scroller.endAutoScroll()
            return false
        }
        scroller.scroll(by: PhotoGridAutoScroll.step(speed: speed, seconds: seconds))
        // The photos the grid brought under the still finger join the range.
        extend(to: CGPoint(x: current.inGrid.x, y: current.inGrid.y + CGFloat(scroller.offset - current.offset)))
        return drag != nil
    }

    // MARK: Pinch to zoom

    /// Two fingers touched the grid, which shows `columns` photos in a row: the photo they hold
    /// (`PhotoGridHitTest.nearest`) and the point of it under them.
    func beginPinch(_ touch: PhotoGridTouch, columns: Int, scroller: PhotoGridScroller?) {
        endPinch()
        lift.gestureBegan()
        let all = photos.shown.map { (position: $0.value.position, frame: GridRect($0.value.frame)) }
        var photo: AssetID?
        var pointInPhoto = 0.5
        if let position = PhotoGridHitTest.nearest(x: Double(touch.inGrid.x), y: Double(touch.inGrid.y), in: all),
           let held = photos.shown.first(where: { $0.value.position == position }) {
            photo = held.key
            let frame = held.value.frame
            if frame.height > 0 {
                pointInPhoto = min(max(Double((touch.inGrid.y - frame.minY) / frame.height), 0), 1)
            }
        }
        zooming = Zooming(steps: PhotoGridZoom.Pinch(columns: columns), photo: photo, pointInPhoto: pointInPhoto,
                          scroller: scroller)
    }

    /// The fingers moved: a step when they spread or pinched far enough, with where they are now.
    func pinch(_ touch: PhotoGridTouch) -> ZoomStep? {
        guard var current = zooming else { return nil }
        let from = current.steps.columns
        let next = current.steps.update(scale: touch.scale)
        zooming = current
        guard let next else { return nil }
        let area = current.scroller?.visibleArea
        let top = area?.lowerBound ?? 0
        return ZoomStep(from: from, to: next, photo: current.photo, pointInPhoto: current.pointInPhoto,
                        fingerY: Double(touch.inScrollView.y) - top, visibleHeight: (area?.upperBound ?? 0) - top,
                        point: touch.inScrollView)
    }

    func endPinch() {
        if zooming != nil { lift.gestureEnded() }
        zooming = nil
    }
}

/// The screen's frame clock while the grid scrolls by itself (`CADisplayLink`), on the main run
/// loop in its common modes, so it ticks while a finger is down. It holds its target until it
/// stops: a tick whose grid went stops it.
@MainActor
final class PhotoGridTicker: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var tick: (@MainActor (Double) -> Bool)?

    /// Calls `tick` every frame with the seconds since the frame before, until it says false or
    /// `stop()`.
    func start(_ tick: @escaping @MainActor (Double) -> Bool) {
        self.tick = tick
        guard link == nil else { return }
        last = nil
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        // Up to the screen's own rate: 120 Hz on a ProMotion iPhone (the app's Info.plist allows
        // it, `CADisableMinimumFrameDurationOnPhone`), never below 60 (review L13).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        last = nil
        tick = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let seconds = last.map { link.timestamp - $0 } ?? link.duration
        last = link.timestamp
        if tick?(seconds) != true { stop() }
    }
}

extension GridRect {
    init(_ frame: CGRect) {
        self.init(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height))
    }
}
