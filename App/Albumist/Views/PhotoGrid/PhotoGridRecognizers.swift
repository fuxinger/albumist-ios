import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import AlbumistCore

// The photo grid's two gestures (design wave 3, DS-06b): UIKit's own pan and pinch beside the
// scroll view's, so they and scrolling decide between them as in Photos, not SwiftUI's drag and
// magnify, which would wait for each other and for the scroll view.

/// Where the fingers of one of the grid's gestures are, as the grid reads them.
struct PhotoGridTouch {
    enum Phase {
        case began, changed, ended
    }

    var phase: Phase
    /// In the grid (`PhotoGridPlace.space`), where its photos' frames are.
    var inGrid: CGPoint
    /// In the scroll view around the grid (`.scrollView`): where on screen.
    var inScrollView: CGPoint
    /// How far the finger moved since it touched (drag to select): the gesture begins only once
    /// it moved a little, and the range begins where it touched.
    var moved: CGPoint = .zero
    /// The two fingers' scale since they touched (pinch to zoom).
    var scale: Double = 1
}

/// Drag to select, only while the grid selects ("Auswählen"): UIKit's pan beside the scroll
/// view's. It begins only on a mostly sideways start (`PhotoGridDrag.startsSelection`); the
/// scroll view's pan, and any other pan (the swipe back over the content), waits for it to fail,
/// so a vertical swipe scrolls as before and a sideways one over the photos selects instead of
/// going back. The swipe back from the screen's edge always goes back: the pan waits for it
/// (review L7). A tap never begins it: a tap still ticks one photo. One finger: two that move
/// apart or together end it, its ticks as they are, and are a pinch
/// (`PhotoGridPinchRecognizer.takeOver`, `stopSelecting`).
struct PhotoGridSelectDrag: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// The grid's coordinate space (`PhotoGridPlace.space`).
    var space: String
    /// A finger touched the grid: a tap after a gesture is one of its own (`PhotoGridLift`).
    var touchedDown: () -> Void
    var onTouch: (PhotoGridTouch) -> Void

    func makeUIGestureRecognizer(context: Context) -> PhotoGridSelectRecognizer {
        let recognizer = PhotoGridSelectRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = recognizer
        recognizer.isEnabled = isEnabled
        recognizer.touchedDown = touchedDown
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PhotoGridSelectRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        recognizer.touchedDown = touchedDown
    }

    func handleUIGestureRecognizerAction(_ recognizer: PhotoGridSelectRecognizer, context: Context) {
        let phase: PhotoGridTouch.Phase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled, .failed: phase = .ended
        default: return
        }
        onTouch(PhotoGridTouch(phase: phase, inGrid: context.converter.location(in: .named(space)),
                               inScrollView: context.converter.location(in: .scrollView),
                               moved: recognizer.translation(in: nil)))
    }
}

/// The pan of drag to select, its own delegate (as `LivePressRecognizer`).
final class PhotoGridSelectRecognizer: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    /// Told of each finger that touches the grid (`PhotoGridLift`).
    var touchedDown: (() -> Void)?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchedDown?()
        return true
    }

    /// Only a sideways start selects: a vertical or diagonal one is the scroll view's.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let moved = translation(in: view)
        return PhotoGridDrag.startsSelection(dx: Double(moved.x), dy: Double(moved.y))
    }

    /// The scroll view's pan and the swipe back over the content (iOS 26's
    /// `interactiveContentPopGestureRecognizer`) wait until this one failed. While the grid does
    /// not select it is switched off, and nothing waits for it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer !== self
            && (otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer === swipesBack().content)
            && !isEdgeSwipeBack(otherGestureRecognizer)
    }

    /// The swipe back from the screen's edge is never taken: this one waits for it to fail, so a
    /// finger from the left edge goes back, also over the photos while selecting (review L7).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        isEdgeSwipeBack(otherGestureRecognizer)
    }

    /// Whether `other` is the swipe back from the screen's edge: the navigation's own
    /// (`interactivePopGestureRecognizer`), or another edge swipe, but never the swipe back over
    /// the content. By its class alone the content's swipe back counted as the edge's, and a
    /// sideways drag over a trip's photos went back instead of ticking them (UI run 45603459548).
    private func isEdgeSwipeBack(_ other: UIGestureRecognizer) -> Bool {
        let pops = swipesBack()
        if other === pops.edge { return true }
        return other is UIScreenEdgePanGestureRecognizer && other !== pops.content
    }

    /// The swipes back of the navigation the grid's page is in: from the edge, and over the
    /// content; nil without one (the tabs' first pages).
    private func swipesBack() -> (edge: UIGestureRecognizer?, content: UIGestureRecognizer?) {
        var responder: UIResponder? = view
        while let next = responder {
            if let controller = next as? UIViewController, let navigation = controller.navigationController {
                return (navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer)
            }
            responder = next.next
        }
        return (nil, nil)
    }
}

/// Pinch to zoom: UIKit's pinch beside the scroll view's pan. Once it begins, the scroll view
/// lets go of the fingers, so the grid changes its size where it is and does not also scroll.
/// Two fingers on the grid that move apart or together are a pinch (`PhotoGridPinchRecognizer`).
struct PhotoGridPinch: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// The grid's coordinate space (`PhotoGridPlace.space`).
    var space: String
    /// A finger touched the grid: a tap after a gesture is one of its own (`PhotoGridLift`). The
    /// pinch is on whenever the grid's photos can be tapped, so it sees every finger.
    var touchedDown: () -> Void
    var onTouch: (PhotoGridTouch) -> Void

    func makeUIGestureRecognizer(context: Context) -> PhotoGridPinchRecognizer {
        let recognizer = PhotoGridPinchRecognizer()
        recognizer.delegate = recognizer
        recognizer.isEnabled = isEnabled
        recognizer.touchedDown = touchedDown
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PhotoGridPinchRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        recognizer.touchedDown = touchedDown
    }

    func handleUIGestureRecognizerAction(_ recognizer: PhotoGridPinchRecognizer, context: Context) {
        let phase: PhotoGridTouch.Phase
        switch recognizer.state {
        case .began:
            recognizer.stopScrolling()
            recognizer.stopSelecting()
            phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled, .failed: phase = .ended
        default: return
        }
        onTouch(PhotoGridTouch(phase: phase, inGrid: context.converter.location(in: .named(space)),
                               inScrollView: context.converter.location(in: .scrollView), scale: Double(recognizer.scale)))
    }
}

/// The pinch of pinch to zoom, its own delegate: it may begin while the scroll view's pan
/// follows the fingers (two fingers that touched a moment apart), and then stops that pan; once
/// it runs, the scroll view's pan does not begin beside it. Two fingers on the grid that move
/// apart or together are a pinch, as in Photos: they end what the photos under them do with one
/// (`takeOver`); two that only tap, two thumbs ticking photos, stay taps.
final class PhotoGridPinchRecognizer: UIPinchGestureRecognizer, UIGestureRecognizerDelegate {
    /// The pan of the scroll view the grid is in, met while the pinch had not begun.
    private weak var scrollPan: UIGestureRecognizer?
    /// The grid's drag to select, which runs beside the pinch until the pinch begins.
    private weak var selectPan: UIGestureRecognizer?
    /// Told of each finger that touches the grid (`PhotoGridLift`).
    var touchedDown: (() -> Void)?
    /// How far apart the first two fingers were when the second touched (pt); nil with one.
    private var apartAtSecondFinger: CGFloat?
    /// Whether these fingers took over already (`takeOver`, once per touch of the grid).
    private var tookOver = false
    /// What this touch of the grid did, for a UI run's record (`PhotoGridPinchRecord`).
    private var record = PhotoGridPinchRecord()

    /// How far two fingers move apart or together before they are a pinch and take over (pt):
    /// about where UIKit's pinch itself begins; two thumbs that tap stay well within it.
    static let takeOverSpread: CGFloat = 6

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if apartAtSecondFinger == nil { apartAtSecondFinger = fingersApart() }
        if ProgressLineLog.isOn { record.touched(fingers: numberOfTouches, apart: fingersApart()) }
    }

    /// Two fingers that moved apart or together by `takeOverSpread` take over (`takeOver`), also
    /// when the pinch began without them (a scroll that became a pinch): after every gesture of
    /// these fingers heard of them, so none of them hears of them again once ended.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        let apart = fingersApart()
        if ProgressLineLog.isOn { record.moved(apart: apart, running: state == .began || state == .changed, scale: scale) }
        guard !tookOver, [.possible, .began, .changed].contains(state), let apart, let start = apartAtSecondFinger,
              abs(apart - start) >= Self.takeOverSpread else { return }
        tookOver = true
        takeOver(event.touches(for: self) ?? touches)
    }

    /// The fingers lifted: what they did goes to the record (only while a UI run asks for it).
    override func reset() {
        super.reset()
        if let line = record.line, ProgressLineLog.isOn { ProgressLineLog.mark(line) }
        record = PhotoGridPinchRecord()
        apartAtSecondFinger = nil
        tookOver = false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchedDown?()
        return true
    }

    /// Beside the pinch run the drag to select, so a second finger reaches the pinch while a drag
    /// runs (`takeOver` and `stopSelecting` end the drag), and the scroll view's pan until the
    /// pinch begins. Nothing else: beside a pinch, a photo's button or its long press could open
    /// it or lift it under the fingers; once the pinch begins, they fail.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is PhotoGridSelectRecognizer {
            selectPan = otherGestureRecognizer
            return true
        }
        guard state == .possible, let scrollView = otherGestureRecognizer.view as? UIScrollView,
              otherGestureRecognizer === scrollView.panGestureRecognizer else { return false }
        scrollPan = otherGestureRecognizer
        return true
    }

    /// The scroll view's pan lets go of the fingers: switched off and on again, it cancels, and
    /// the scroll view stays where it is (UIKit's documented way to cancel a recognizer).
    func stopScrolling() {
        guard let scrollPan, scrollPan.state == .began || scrollPan.state == .changed else { return }
        scrollPan.isEnabled = false
        scrollPan.isEnabled = true
    }

    /// The drag to select ends as the pinch begins, its ticks as they are (it ran beside the pinch
    /// until then): never both at once, also when the fingers took over late or not at all.
    func stopSelecting() {
        guard let selectPan, selectPan.state == .began || selectPan.state == .changed else { return }
        selectPan.isEnabled = false
        selectPan.isEnabled = true
    }

    /// Two fingers that move apart or together are a pinch, never a tap, a long press or a drag:
    /// the gestures these fingers started with one end (the photo's button with its tap and
    /// pressed look, the long press's menu before it lifts, and while the grid selects the drag,
    /// its ticks as they are), so the pinch waits for none of them to fail. Attached with
    /// `.gesture`, the only way a representable has, it may give way to the photos' own gestures
    /// as SwiftUI's own gestures do, and two fingers on one photo never fail them: on a Mac they
    /// made no step (UI run 45567033486). Each is switched off and on again, which ends it, as
    /// `stopScrolling` does; its name goes to the record once.
    private func takeOver(_ touches: Set<UITouch>) {
        if ProgressLineLog.isOn { record.tookOver = true }
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
        for other in touches.flatMap({ $0.gestureRecognizers ?? [] }) where seen.insert(ObjectIdentifier(other)).inserted {
            guard Self.givesWay(other) else { continue }
            other.isEnabled = false
            other.isEnabled = true
            if ProgressLineLog.isOn { record.stopped.append(String(describing: type(of: other))) }
        }
    }

    /// Whether a pinch's fingers end `other` (`takeOver`): the drag to select, also while it
    /// runs; any other gesture that has not ended but a pan, so scrolling (also with two
    /// fingers, until the pinch begins) and the swipe back go on; never one of the scroll view's
    /// own (it is their delegate) or of the window (the system's).
    private static func givesWay(_ other: UIGestureRecognizer) -> Bool {
        guard other.isEnabled, !(other.delegate is UIScrollView), !(other.view is UIWindow) else { return false }
        if other is PhotoGridSelectRecognizer { return true }
        return !(other is UIPanGestureRecognizer) && [.possible, .began, .changed].contains(other.state)
    }

    /// How far apart the first two fingers are, in points on the screen; nil with one.
    private func fingersApart() -> CGFloat? {
        guard numberOfTouches > 1 else { return nil }
        let first = location(ofTouch: 0, in: nil)
        let second = location(ofTouch: 1, in: nil)
        let dx = first.x - second.x
        let dy = first.y - second.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// What one touch of the grid did with the pinch, for the record of a UI run that asks for it
/// (`ProgressLineLog`, `-AlbumistUITestProgressLog`; never otherwise): one line when the fingers
/// lift, "grid pinch: fingers 2, apart 212, began 0.96, scale 0.78, spread 0.70, stopped 2 […]".
/// Fingers: how many touched the grid; apart: how far apart the first two were (pt); began:
/// their own scale when the pinch began ("-": it never began); scale: UIKit's at the end,
/// counted from where it began; spread: their own scale at the end; stopped: the gestures the
/// fingers ended when they moved apart or together (`takeOver`; "-": they never did). The
/// grid's UI test reads it when a pinch made no step.
struct PhotoGridPinchRecord {
    var fingers = 0
    /// How far apart the first two fingers were when the second touched, and at the last move.
    var apart: CGFloat?
    var now: CGFloat?
    var began: CGFloat?
    var scale: CGFloat?
    /// Whether the fingers took over (`takeOver`), and what they ended.
    var tookOver = false
    var stopped: [String] = []

    mutating func touched(fingers count: Int, apart distance: CGFloat?) {
        fingers = max(fingers, count)
        if apart == nil { apart = distance }
        if let distance { now = distance }
    }

    /// The fingers moved; `running`: the pinch has begun, its scale is UIKit's.
    mutating func moved(apart distance: CGFloat?, running: Bool, scale: CGFloat) {
        if let distance { now = distance }
        guard running else { return }
        if began == nil, let apart, apart > 0, let now { began = now / apart }
        self.scale = scale
    }

    /// The record's line; nil when no finger touched.
    var line: String? {
        guard fingers > 0 else { return nil }
        let spread = apart.flatMap { first in now.map { first > 0 ? $0 / first : 1 } }
        let distance = apart.map { "\(Int($0.rounded()))" } ?? "-"
        let ended = tookOver ? "\(stopped.count) [\(stopped.joined(separator: ", "))]" : "-"
        return "grid pinch: fingers \(fingers), apart \(distance), began \(Self.text(began)), scale \(Self.text(scale)), "
            + "spread \(Self.text(spread)), stopped \(ended)"
    }

    private static func text(_ value: CGFloat?) -> String {
        value.map { String(format: "%.2f", Double($0)) } ?? "-"
    }
}
