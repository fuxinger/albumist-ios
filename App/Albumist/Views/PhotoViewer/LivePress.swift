import SwiftUI
import UIKit

/// The long press that plays a Live Photo whole (design wave 2, DS-10), as in Photos. It is
/// UIKit's own long press beside SwiftUI's gestures, not SwiftUI's long press followed by a
/// drag: that one, inside the pager, kept the swipe to the next photo from the pager on exactly
/// the Live Photo pages (review D, H1).
///
/// It runs together with every other gesture (the pager's swipe, the pinch, the pull down; the
/// photo view ignores a tap or a pull that was the press), begins after 0.3 s and with one
/// finger only (two fingers resting on the photo are a pinch, never the motion), and says when
/// the press begins and when it ends, is cancelled or fails.
struct LivePress: UIGestureRecognizerRepresentable {
    /// Only on a photo whose Live Photo is here: on any other a slow tap stays a tap.
    var isEnabled: Bool
    /// True when the press begins, false when it is over.
    var onPress: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> LivePressRecognizer {
        let recognizer = LivePressRecognizer()
        recognizer.minimumPressDuration = 0.3
        recognizer.numberOfTouchesRequired = 1
        recognizer.delegate = recognizer
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: LivePressRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: LivePressRecognizer, context: Context) {
        switch recognizer.state {
        case .began: onPress(true)
        case .ended, .cancelled, .failed: onPress(false)
        default: break
        }
    }
}

/// A long press that is its own delegate: every other gesture runs beside it, and it begins
/// only under one finger.
final class LivePressRecognizer: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.numberOfTouches == 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
