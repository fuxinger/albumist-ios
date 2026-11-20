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
struct CardShelf<Content: View>: View {
    var count: Int = 2
    var spacing: CGFloat = Theme.Spacing.m
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // `count` cards and the spaces between them fill the shelf's width (without its
        // margins), each 5 pt narrower than its share so the next one peeks in from the edge.
        let shown = CGFloat(max(count, 1)), spacing = self.spacing
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
                            max(1, ((width - spacing * (shown - 1) - 5) / shown).rounded(.down))
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
