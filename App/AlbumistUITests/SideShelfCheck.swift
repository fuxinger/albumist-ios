import Foundation

/// Text that runs off the side of the screen in the accessibility test, apart from text in a card
/// that peeks in from the side of a shelf. Plain Foundation, so SwiftPM also builds it on Linux
/// (target `AlbumistUITestLogic`, tests in `SideShelfCheckTests`).
///
/// The shelves of design wave 1 (`CardShelf`: the start page's rows, "Von Albumist" in the tab
/// "Alben") show two cards and the edge of the third, so the third card's text runs off the side
/// of the screen by design, as in Photos and the App Store: a swipe brings the card in whole,
/// VoiceOver scrolls to it. UI run 44852630315 failed "landscape albums" on the third album of
/// "Von Albumist" (its "Neu", name and count off the side, and the audit's contrast measured on
/// the few points of "Neu" on screen). Any other text that runs off the side is a layout fault
/// and fails as before: a line wider than its card, a row as wide as the screen, a card pushed off
/// the page by its neighbours (no shelf of its own around it), a card wider than the screen.
enum SideShelfCheck {
    /// An element of the accessibility tree above a text, outermost first: its frame and whether
    /// it is a scroll view.
    struct Ancestor: Equatable {
        var frame: CGRect
        var isScrollView: Bool
    }

    /// Runs off the left or the right side of the screen (by more than a point).
    static func runsOffSide(_ frame: CGRect, screen: CGRect) -> Bool {
        frame.minX < screen.minX - 1 || frame.maxX > screen.maxX + 1
    }

    /// The card of a text that runs off the side, when that card peeks in from the side of a
    /// shelf: the outermost element inside the text's scroll view that holds the text whole and
    /// is narrower than the screen, running off the same side itself, in a scroll view that lies
    /// in another one (a shelf on a page). Nil for anything else.
    static func peekingCard(of text: CGRect, ancestors: [Ancestor], screen: CGRect) -> CGRect? {
        guard runsOffSide(text, screen: screen),
              let shelf = ancestors.lastIndex(where: \.isScrollView),
              ancestors[...shelf].filter(\.isScrollView).count >= 2 else { return nil }
        let card = ancestors[(shelf + 1)...].first { holds($0.frame, text) && $0.frame.width < screen.width - 1 }?.frame
        guard let card else { return nil }
        let offLeft = text.minX < screen.minX - 1 && card.minX < screen.minX - 1
        let offRight = text.maxX > screen.maxX + 1 && card.maxX > screen.maxX + 1
        return offLeft || offRight ? card : nil
    }

    /// An element the audit names (by its frame only) lies in one of the peeking `cards` the
    /// tree check noted, and runs off the side itself: the audit measured only the part on screen.
    static func inPeekingCard(_ frame: CGRect, cards: [CGRect], screen: CGRect) -> Bool {
        runsOffSide(frame, screen: screen) && cards.contains { holds($0, frame) }
    }

    /// `outer` holds `inner` whole, give or take a point.
    static func holds(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -1, dy: -1).contains(inner)
    }
}
