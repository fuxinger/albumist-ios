import SwiftUI
import UIKit

/// Pull down to close the photo view: a pan that begins only when it starts mostly downwards,
/// so it never competes with the pages' sideways swipe (Build 41, A12). The SwiftUI drag it
/// replaces ran beside every touch, and a finger's slower, drifting swipe to the next photo
/// went through only every third or fourth time.
struct PullDownToClose: UIGestureRecognizerRepresentable {
    /// Only at normal size: zoomed, the drag moves the photo.
    var isEnabled: Bool
    /// How far the photo is pulled down, in points (never below 0).
    var changed: (CGFloat) -> Void
    /// The distance down, the distance sideways (never negative) and the downward speed
    /// (points per second) when the finger lifts.
    var ended: (CGFloat, _ sideways: CGFloat, _ speed: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let moved = recognizer.translation(in: recognizer.view)
        let distance = max(moved.y, 0)
        switch recognizer.state {
        case .began, .changed: changed(distance)
        case .ended: ended(distance, abs(moved.x), recognizer.velocity(in: recognizer.view).y)
        case .cancelled, .failed: ended(0, 0, 0)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Mostly downwards so far (more down than sideways, as the drag before it); anything
        /// sideways or upwards is the pages' swipe. The way moved, not the speed of the moment:
        /// a slow pull with a small wobble still begins.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let moved = pan.translation(in: pan.view)
            return moved.y > 0 && moved.y > abs(moved.x)
        }

        /// The pages' scroll view and the Live Photo press may follow the same touch; the pages
        /// do not move on a pull straight down.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
