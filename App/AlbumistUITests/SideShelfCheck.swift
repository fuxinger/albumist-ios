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
/// the few points of "Neu" on screen). Any scroll view inside another one counts as a shelf, so
/// the atlas' row of years does too. Any other text that runs off the side is a layout fault and
/// fails as before: a line wider than its card, a row as wide as the screen, a card pushed off the
/// page by its neighbours (no shelf of its own around it), a card wider than the screen, a shelf
/// that runs off the side itself.
enum SideShelfCheck {
    /// An element of the accessibility tree above a text, outermost first: its frame, whether it
    /// is a scroll view, and its type and identifier for the log when the text fails.
    struct Ancestor: Equatable {
        var frame: CGRect
        var isScrollView: Bool
        var name = ""
    }

    /// Runs off the left or the right side of the screen (by more than a point).
    static func runsOffSide(_ frame: CGRect, screen: CGRect) -> Bool {
        frame.minX < screen.minX - 1 || frame.maxX > screen.maxX + 1
    }

    /// The shelf an element lies in: the innermost scroll view above it, when that one lies in
    /// another scroll view (a shelf on a page) and is on screen from side to side itself, so a
    /// swipe brings each of its cards in whole. Nil otherwise.
    static func shelf(_ ancestors: [Ancestor], screen: CGRect) -> CGRect? {
        guard let index = ancestors.lastIndex(where: \.isScrollView),
              ancestors[...index].filter(\.isScrollView).count >= 2,
              !runsOffSide(ancestors[index].frame, screen: screen) else { return nil }
        return ancestors[index].frame
    }

    /// An element (not a text) that can be a card of a shelf: in a shelf and narrower than the
    /// screen. The tree check notes those that run off the side, for `peekingCard(of:…cards:)`.
    static func isShelfCard(_ frame: CGRect, ancestors: [Ancestor], screen: CGRect) -> Bool {
        frame.width < screen.width - 1 && shelf(ancestors, screen: screen) != nil
    }

    /// The card of a text that runs off the side, when that card peeks in from the side of a
    /// shelf and runs off the same side itself. By the tree: the outermost element inside the
    /// text's shelf that holds the text whole and is narrower than the screen. The tree may also
    /// list a card's texts beside the card (they are hidden from VoiceOver, the card's body speaks
    /// for them): then by frame, the first of `cards` (`isShelfCard`, same snapshot) that holds
    /// the text. Nil for anything else.
    static func peekingCard(of text: CGRect, ancestors: [Ancestor], cards: [CGRect] = [], screen: CGRect) -> CGRect? {
        guard runsOffSide(text, screen: screen) else { return nil }
        func offTheSameSide(_ card: CGRect) -> Bool {
            (text.minX < screen.minX - 1 && card.minX < screen.minX - 1)
                || (text.maxX > screen.maxX + 1 && card.maxX > screen.maxX + 1)
        }
        if shelf(ancestors, screen: screen) != nil, let inner = ancestors.lastIndex(where: \.isScrollView),
           let card = ancestors[(inner + 1)...].first(where: { holds($0.frame, text) && $0.frame.width < screen.width - 1 })?.frame {
            return offTheSameSide(card) ? card : nil
        }
        return cards.first { holds($0, text) && offTheSameSide($0) }
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

    /// The elements above a text, for the log line of a text that fails.
    static func chain(_ ancestors: [Ancestor]) -> String {
        ancestors.map { a in
            "\(a.isScrollView ? "scroll " : "")\(a.name) \(Int(a.frame.minX)),\(Int(a.frame.minY)) \(Int(a.frame.width))x\(Int(a.frame.height))"
        }.joined(separator: " > ")
    }
}
