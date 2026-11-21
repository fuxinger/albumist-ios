import SwiftUI

/// A row of cards that scrolls sideways (the start page's trips, the albums Albumist made), and
/// one column at the accessibility text sizes (design rule 4: rows become one column, nothing is
/// cut off).
///
/// Each card gets `count` cards' share of the width, a little less, so the next card shows at the
/// edge and it is clear there are more (draft E1: two cards of 172 pt on a 393 pt screen, the third
/// one peeking in); the cards snap to the leading edge. The page's margin (16 pt) stays left and
/// right; at the accessibility sizes the cards are full width under each other. Content: the cards,
/// each one view (`ForEach` over the suggestions, or single cards); the shelf sizes them.
///
/// A card never gets narrower than `CardShelfMetrics.minimumCardWidth`, which grows with the text:
/// with larger text the shelf shows fewer, wider cards (two of 172 pt on the 393 pt iPhone at the
/// standard size, one of 356 pt from the next size on), so a long German word ("Weihnachtsmarkt")
/// stays on one line of the title and every button word fits. Compact `PhotoCard`s are all equally
/// high (each keeps three text lines), so the row neither stands ragged nor jumps when a taller
/// card scrolls in; give the cards of one shelf the same `aspectRatio` and the same kind of actions.
struct CardShelf<Content: View>: View {
    var count: Int = 2
    var spacing: CGFloat = Theme.Spacing.m
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var minimumCardWidth: CGFloat = CardShelfMetrics.minimumCardWidth

    var body: some View {
        let count = self.count, spacing = self.spacing, minimum = minimumCardWidth
        if typeSize.isAccessibilitySize {
            LazyVStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, Theme.Spacing.l)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(subviews: content) { card in
                        card.containerRelativeFrame(.horizontal) { width, _ in
                            CardShelfMetrics.cardWidth(container: width, count: count, spacing: spacing, minimum: minimum)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, Theme.Spacing.l, for: .scrollContent)
        }
    }
}

/// The widths of a `CardShelf`'s cards, apart from the view so they can be checked in tests.
enum CardShelfMetrics {
    /// The narrowest card at the standard text size (the shelf scales it with the headline
    /// style): a 15-letter word in the compact card's title ("Weihnachtsmarkt", about 140 pt of
    /// SF Pro semibold at 17 pt) fits between its 10 pt margins. Two cards still fit on the small
    /// iPhone (163 pt each); from the next text size on the 393 pt iPhone shows one card.
    static let minimumCardWidth: CGFloat = 162

    /// The width of each card: `count` cards, or fewer when they would be narrower than `minimum`
    /// (at least one), and the spaces between them fill `container` (the shelf's width without
    /// its margins), each 5 pt narrower than its share so the next one peeks in from the edge;
    /// whole points, at least one.
    static func cardWidth(container: CGFloat, count: Int, spacing: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        guard container.isFinite, container > 0 else { return 1 }
        func width(_ shown: Int) -> CGFloat {
            ((container - spacing * CGFloat(shown - 1) - 5) / CGFloat(shown)).rounded(.down)
        }
        var shown = min(max(count, 1), 50)
        while shown > 1, width(shown) < minimum { shown -= 1 }
        return max(1, width(shown))
    }
}
