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
    /// The point of a photo and of the visible area that `show` lines up; nil until the first
    /// zoom step (the scroll view's own default then).
    private(set) var anchor: UnitPoint?
    /// The scroll view as it reported itself last, at every frame while it moves: not observed,
    /// nothing is drawn again for it.
    @ObservationIgnored private var geometry: ScrollGeometry?
    /// The scroll view's safe area as the page lays it out: a page whose content reaches up under
    /// its bars (`ignoresSafeArea`, a suggestion's cover) has no content inset there.
    @ObservationIgnored private var safeArea = PhotoGridSafeEdges()
    /// The offsets asked for while the grid scrolls by itself.
    @ObservationIgnored private var target = PhotoGridAutoScroll.Target()
    /// How `scrollTo(y:)` counts, learned once for the app from the first step of scrolling by
    /// itself that can tell (SwiftUI's way, the same on every page).
    private static var calibration = PhotoGridAutoScroll.Calibration()

    /// The offset the scroll view reported last.
    var offset: Double {
        Double(geometry?.contentOffset.y ?? 0)
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
        Self.calibration.reported(offset)
    }

    func reported(safeArea: PhotoGridSafeEdges) {
        self.safeArea = safeArea
    }

    /// One frame's step of scrolling by itself, `step` points (negative: up), within the content.
    func scroll(by step: Double) {
        guard let geometry else { return }
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
        target.reset()
        Self.calibration.reset()
    }

    /// Scrolls `photo` to where the point `unitY` of it (0 its top, 1 its bottom) and of the
    /// visible area meet: the modifier's anchor and the step's, both.
    func show(_ photo: AssetID, unitY: Double) {
        let point = UnitPoint(x: 0.5, y: unitY)
        anchor = point
        position.scrollTo(id: photo, anchor: point)
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
