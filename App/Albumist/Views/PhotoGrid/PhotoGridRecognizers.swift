import SwiftUI
import UIKit
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
/// scroll view's pan, and any other pan (the swipe back), waits for it to fail, so a vertical
/// swipe scrolls as before and a sideways one selects instead of going back. A tap never begins
/// it: a tap still ticks one photo. One finger: two are a pinch.
struct PhotoGridSelectDrag: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// The grid's coordinate space (`PhotoGridPlace.space`).
    var space: String
    var onTouch: (PhotoGridTouch) -> Void

    func makeUIGestureRecognizer(context: Context) -> PhotoGridSelectRecognizer {
        let recognizer = PhotoGridSelectRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = recognizer
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PhotoGridSelectRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
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
    /// Only a sideways start selects: a vertical or diagonal one is the scroll view's.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let moved = translation(in: view)
        return PhotoGridDrag.startsSelection(dx: Double(moved.x), dy: Double(moved.y))
    }

    /// The scroll view's pan and the swipe back wait until this one failed. While the grid does
    /// not select it is switched off, and nothing waits for it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer !== self && otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// Pinch to zoom: UIKit's pinch beside the scroll view's pan. Once it begins, the scroll view
/// lets go of the fingers, so the grid changes its size where it is and does not also scroll.
struct PhotoGridPinch: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// The grid's coordinate space (`PhotoGridPlace.space`).
    var space: String
    var onTouch: (PhotoGridTouch) -> Void

    func makeUIGestureRecognizer(context: Context) -> PhotoGridPinchRecognizer {
        let recognizer = PhotoGridPinchRecognizer()
        recognizer.delegate = recognizer
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PhotoGridPinchRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: PhotoGridPinchRecognizer, context: Context) {
        let phase: PhotoGridTouch.Phase
        switch recognizer.state {
        case .began:
            recognizer.stopScrolling()
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
/// it runs, the scroll view's pan does not begin beside it.
final class PhotoGridPinchRecognizer: UIPinchGestureRecognizer, UIGestureRecognizerDelegate {
    /// The pan of the scroll view the grid is in, met while the pinch had not begun.
    private weak var scrollPan: UIGestureRecognizer?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
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
}
