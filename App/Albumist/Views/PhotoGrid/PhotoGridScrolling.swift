import SwiftUI
import AlbumistCore

extension View {
    /// Lets the photo grid in this scroll view move it (`PhotoGrid`, design wave 3, DS-06b): on
    /// by itself while a finger selects near its top or bottom edge, and to the photo two fingers
    /// hold after a zoom step. Set on the page's `ScrollView`, which the grid cannot reach from
    /// inside it; where the scroll view reaches up under the bars (`ignoresSafeArea`), after that
    /// modifier, so it reads where the bars end. Without it the grid still selects and zooms; it
    /// then neither scrolls by itself nor keeps its place when it zooms.
    func photoGridScrolling() -> some View {
        modifier(PhotoGridScrollHost())
    }
}

/// The scroll view's position and geometry for the grid inside it (`PhotoGridScroller`). Apart
/// from the page: the position the scroll view writes while it moves draws only this modifier
/// again, never the page (a page bound to it was drawn again at each write, `PlanReviewView`),
/// and the geometry it reports at every frame is kept unobserved.
private struct PhotoGridScrollHost: ViewModifier {
    @State private var scroller = PhotoGridScroller()

    func body(content: Content) -> some View {
        // Read here, so a step the grid asks for (`scroll(by:)`, `show`) reaches the scroll view.
        let _ = scroller.position
        content
            .scrollPosition($scroller.position, anchor: scroller.anchor)
            .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                geometry
            } action: { _, geometry in
                scroller.reported(geometry)
            }
            // Where the bars end, also on a page whose content reaches up under them.
            .onGeometryChange(for: PhotoGridSafeEdges.self) { proxy in
                PhotoGridSafeEdges(top: proxy.safeAreaInsets.top, bottom: proxy.safeAreaInsets.bottom)
            } action: { edges in
                scroller.reported(safeArea: edges)
            }
            .environment(\.photoGridScroller, scroller)
    }
}

/// What the grid can ask of the scroll view it is in: where it is and what of it is visible,
/// a step on while a finger selects at an edge (`PhotoGridAutoScroll`), and a photo to show at a
/// point of the visible area after a zoom step (`PhotoGridZoom.anchor`).
///
/// Offsets are the scroll view's own (UIKit's `contentOffset`, as `ScrollGeometry` reports it):
/// at the top it is minus the top inset (the bars). What `ScrollPosition.scrollTo(y:)` takes is
/// learned from the scroll view (`PhotoGridAutoScroll.Calibration`, review L5).
@MainActor @Observable
final class PhotoGridScroller {
    /// The scroll view's position (`scrollPosition`), which it writes as it moves.
    var position = ScrollPosition(idType: AssetID.self)
    /// The point of a photo and of the visible area that `show` lines up, while a zoom step lands;
    /// nil otherwise (the scroll view's plain scrolling).
    private(set) var anchor: UnitPoint?
    /// A zoom step's photo is on its way: only then the scroll view finds the grid's photos by id
    /// (the grid's scroll target layout is on), so otherwise it follows no photo (review L6).
    private(set) var findsPhotos = false
    /// The steps asked for, so only the last one's landing gives back plain scrolling.
    @ObservationIgnored private var steps = 0
    /// How long a zoom step takes to land: the grid settles in 0.3 s (`PhotoGridSettle`).
    static let landing: Duration = .milliseconds(350)
    /// The scroll view as it reported itself last, at every frame while it moves: not observed,
    /// nothing is drawn again for it.
    @ObservationIgnored private var geometry: ScrollGeometry?
    /// The scroll view's safe area as the page lays it out: a page whose content reaches up under
    /// its bars (`ignoresSafeArea`, a suggestion's cover) has no content inset there.
    @ObservationIgnored private var safeArea = PhotoGridSafeEdges()
    /// The offsets asked for while the grid scrolls by itself.
    @ObservationIgnored private var target = PhotoGridAutoScroll.Target()
    /// How `scrollTo(y:)` counts, learned for the app from a probe of scrolling by itself and
    /// checked again in each run (SwiftUI's way, the same on every page; review L5, W4).
    private static var calibration = PhotoGridAutoScroll.Calibration()
    /// This scroll view scrolls by itself: only its reports answer the steps asked (the lesson is
    /// the app's, every grid's).
    @ObservationIgnored private var scrollsByItself = false

    /// The offset the scroll view reported last.
    var offset: Double {
        Double(geometry?.contentOffset.y ?? 0)
    }

    /// The scroll view's height, also what of it lies under the bars; nil before it reported
    /// itself. The grid reads in it which of its photos are on screen (review W1).
    var height: Double? {
        geometry.map { Double($0.containerSize.height) }
    }

    /// The part of the scroll view inside its content insets, from top to bottom in its own space
    /// (`.scrollView`): where `show` lines a photo up (`scrollTo(id:anchor:)` aligns in it). Nil
    /// before it reported itself.
    var visibleArea: ClosedRange<Double>? {
        guard let geometry else { return nil }
        let top = Double(geometry.contentInsets.top)
        let bottom = Double(geometry.containerSize.height - geometry.contentInsets.bottom)
        return top < bottom ? top...bottom : nil
    }

    /// The part of the scroll view the user sees, from top to bottom in its own space: below the
    /// bars, also where the page's content reaches up under them. The edges' zones of scrolling
    /// by itself are in it. Nil before it reported itself.
    var seenArea: ClosedRange<Double>? {
        guard let geometry else { return nil }
        return PhotoGridAutoScroll.seenArea(height: Double(geometry.containerSize.height),
                                            insetTop: Double(geometry.contentInsets.top),
                                            insetBottom: Double(geometry.contentInsets.bottom),
                                            safeTop: Double(safeArea.top), safeBottom: Double(safeArea.bottom))
    }

    func reported(_ geometry: ScrollGeometry) {
        self.geometry = geometry
        let offset = Double(geometry.contentOffset.y)
        target.reported(offset)
        if scrollsByItself { Self.calibration.reported(offset) }
    }

    func reported(safeArea: PhotoGridSafeEdges) {
        self.safeArea = safeArea
    }

    /// One frame's step of scrolling by itself, `step` points (negative: up), within the content;
    /// none while a probe of how `scrollTo(y:)` counts waits for its report (review W4).
    func scroll(by step: Double) {
        guard let geometry, Self.calibration.mayAsk() else { return }
        scrollsByItself = true
        let insetTop = Double(geometry.contentInsets.top)
        let top = -insetTop
        let bottom = max(top, Double(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height))
        guard let wanted = target.next(by: step, offset: offset, range: top...bottom) else { return }
        let y = Self.calibration.y(for: wanted, insetTop: insetTop)
        Self.calibration.asked(y, from: offset, insetTop: insetTop, range: top...bottom)
        position.scrollTo(y: CGFloat(y))
    }

    /// The finger left the edge or lifted: the next steps go on from where the scroll view is.
    func endAutoScroll() {
        scrollsByItself = false
        target.reset()
        Self.calibration.reset()
    }

    /// Scrolls `photo` to where the point `unitY` of it (0 its top, 1 its bottom) and of the
    /// visible area meet: the modifier's anchor and the step's, both, while the step lands (the
    /// scroll view keeps the photo there as the grid lays out its new size).
    func show(_ photo: AssetID, unitY: Double) {
        let point = UnitPoint(x: 0.5, y: unitY)
        findsPhotos = true
        anchor = point
        position.scrollTo(id: photo, anchor: point)
        steps += 1
        let step = steps
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PhotoGridScroller.landing)
            guard let self, self.steps == step else { return }
            self.land()
        }
    }

    /// The zoom step landed: the scroll view scrolls plainly again, as before the zoom. No anchor
    /// is left, its position names no photo (one that goes leaves nothing behind), and it finds
    /// and follows none while the user scrolls (review L6).
    private func land() {
        anchor = nil
        findsPhotos = false
        position = ScrollPosition(idType: AssetID.self)
    }
}

/// What covers the top and the bottom of the scroll view, from its safe area.
struct PhotoGridSafeEdges: Equatable, Sendable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

private struct PhotoGridScrollerKey: EnvironmentKey {
    static var defaultValue: PhotoGridScroller? { nil }
}

extension EnvironmentValues {
    /// The scroll view around a photo grid, when the page lets the grid move it
    /// (`photoGridScrolling()`).
    var photoGridScroller: PhotoGridScroller? {
        get { self[PhotoGridScrollerKey.self] }
        set { self[PhotoGridScrollerKey.self] = newValue }
    }
}
