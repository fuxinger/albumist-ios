import SwiftUI
import AlbumistCore

/// The rules of a card's texts, apart from the views so the tests can check them.
enum CardTextMetrics {
    /// The heights of one and two lines of the title and of the subtitle, as measured in their
    /// fonts (`CardTextLayout`'s hidden probes).
    struct Lines: Equatable {
        var titleOne: CGFloat
        var titleTwo: CGFloat
        var subtitleOne: CGFloat
        var subtitleTwo: CGFloat
    }

    /// A compact card's inner margin, left and right: 10 pt (the drafts' 12 less 2 on each side,
    /// so a long German word fits on one line of a card of 163 pt, the small iPhone's).
    static let compactInset: CGFloat = 10
    /// The room beside the word inside a compact card's capsule (`CardActionButtonStyle`): 10 pt
    /// (the drafts' 18 where the capsule is only as wide as its word), "Benennen …" fits at
    /// every text size a card side by side is shown at.
    static let compactActionInset: CGFloat = 10
    /// The width the texts of a large card keep beside its action at the standard text size
    /// (grows with the text): a 15-letter word in the bold title ("Weihnachtsmarkt") stays on
    /// one line. Narrower, the action goes below the texts.
    static let minimumTextBesideAction: CGFloat = 176

    /// Whether a title of `height` takes two lines.
    static func titleTakesTwoLines(_ height: CGFloat, _ lines: Lines) -> Bool {
        height > (lines.titleOne + lines.titleTwo) / 2
    }

    /// The height the subtitle may take within three lines: under a two-line title one line
    /// (offered half a line more, which a text never fills, so it ends in "…" after one); nil
    /// under a one-line title, where it keeps its own limit of two.
    static func subtitleRoom(titleHeight: CGFloat, lines: Lines) -> CGFloat? {
        guard titleTakesTwoLines(titleHeight, lines) else { return nil }
        return (lines.subtitleOne + lines.subtitleTwo) / 2
    }

    /// The height a compact card keeps for its texts: the taller of a two-line title over a
    /// one-line subtitle and a one-line title over a two-line subtitle, so every card side by
    /// side is as high, whatever its texts, and a shelf neither stands ragged nor jumps when a
    /// taller card scrolls in.
    static func reservedHeight(lines: Lines, spacing: CGFloat) -> CGFloat {
        max(lines.titleTwo + spacing + lines.subtitleOne, lines.titleOne + spacing + lines.subtitleTwo)
    }

    /// Whether a large card's action fits beside its texts in `width`: the texts keep
    /// `minimumTextWidth` next to the action's own width.
    static func actionBesideText(width: CGFloat, actionWidth: CGFloat, spacing: CGFloat, minimumTextWidth: CGFloat) -> Bool {
        width - actionWidth - spacing >= minimumTextWidth
    }
}

/// A card's title and subtitle within three lines at the standard text sizes (design rule 4):
/// the title as it is (its own limit of two lines), the subtitle in the lines the title left,
/// at least one. `limitsLines` false (the accessibility sizes): both as long as they are.
/// `reservesLines`: the height of three lines whatever the texts (`CardTextMetrics.reservedHeight`),
/// the texts at the top. Subviews: the title, four hidden probes (one and two lines of the
/// title's font, then of the subtitle's), then the subtitle if there is one. A text offered less
/// height than it needs ends its last line in "…".
struct CardTextLayout: Layout {
    var limitsLines: Bool
    var reservesLines: Bool
    var spacing: CGFloat

    private static let subtitleIndex = 5

    private struct Measured {
        var title: CGSize
        var subtitle: CGSize?
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = measure(width: proposal.width, subviews: subviews)
        // The width offered, or the texts' own width when none or no limit is offered.
        let own = max(measured.title.width, measured.subtitle?.width ?? 0)
        let width = proposal.width.map { $0.isFinite ? $0 : own } ?? own
        return CGSize(width: width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            switch index {
            case 0:
                subview.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: measured.title.height))
            case Self.subtitleIndex:
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + measured.title.height + spacing), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: measured.subtitle?.height ?? 0))
            default:
                // The hidden probes.
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
            }
        }
    }

    private func measure(width: CGFloat?, subviews: Subviews) -> Measured {
        guard let title = subviews.first else { return Measured(title: .zero, subtitle: nil, height: 0) }
        let titleSize = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
        guard subviews.count >= Self.subtitleIndex else { return Measured(title: titleSize, subtitle: nil, height: titleSize.height) }
        let lines = CardTextMetrics.Lines(titleOne: subviews[1].sizeThatFits(.unspecified).height,
                                          titleTwo: subviews[2].sizeThatFits(.unspecified).height,
                                          subtitleOne: subviews[3].sizeThatFits(.unspecified).height,
                                          subtitleTwo: subviews[4].sizeThatFits(.unspecified).height)
        var subtitleSize: CGSize?
        if subviews.count > Self.subtitleIndex {
            let subtitle = subviews[Self.subtitleIndex]
            var size = subtitle.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if limitsLines, let room = CardTextMetrics.subtitleRoom(titleHeight: titleSize.height, lines: lines), size.height > room {
                size = subtitle.sizeThatFits(ProposedViewSize(width: width, height: room))
            }
            subtitleSize = size
        }
        var height = titleSize.height + (subtitleSize.map { spacing + $0.height } ?? 0)
        if reservesLines { height = max(height, CardTextMetrics.reservedHeight(lines: lines, spacing: spacing)) }
        return Measured(title: titleSize, subtitle: subtitleSize, height: height)
    }
}

/// A large card's texts and its action: side by side while the texts keep `minimumTextWidth`
/// next to the action (`CardTextMetrics.actionBesideText`), both centred on each other as in the
/// drafts; otherwise, and always with `stacks` (the accessibility sizes), the action below the
/// texts and as wide as they are. Subviews: the texts, then the actions (one view).
struct ActionBesideText: Layout {
    var spacing: CGFloat
    var minimumTextWidth: CGFloat
    var stacks: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (index, subview) in subviews.enumerated() {
            let frame = index < frames.count ? frames[index] : .zero
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        guard let texts = subviews.first else { return ([], .zero) }
        let offered = width.flatMap { $0.isFinite ? $0 : nil }
        guard subviews.count > 1 else {
            let size = texts.sizeThatFits(ProposedViewSize(width: offered, height: nil))
            let shownWidth = offered ?? size.width
            return ([CGRect(x: 0, y: 0, width: shownWidth, height: size.height)], CGSize(width: shownWidth, height: size.height))
        }
        let action = subviews[1]
        let natural = action.sizeThatFits(.unspecified)
        if !stacks, CardTextMetrics.actionBesideText(width: offered ?? .infinity, actionWidth: natural.width, spacing: spacing,
                                                        minimumTextWidth: minimumTextWidth) {
            let textSize = texts.sizeThatFits(ProposedViewSize(width: offered.map { $0 - natural.width - spacing }, height: nil))
            let textWidth = offered.map { $0 - natural.width - spacing } ?? textSize.width
            let height = max(textSize.height, natural.height)
            let textFrame = CGRect(x: 0, y: (height - textSize.height) / 2, width: textWidth, height: textSize.height)
            let actionFrame = CGRect(x: textWidth + spacing, y: (height - natural.height) / 2, width: natural.width, height: natural.height)
            return ([textFrame, actionFrame], CGSize(width: actionFrame.maxX, height: height))
        }
        let textSize = texts.sizeThatFits(ProposedViewSize(width: offered, height: nil))
        let shownWidth = offered ?? max(textSize.width, natural.width)
        let actionSize = action.sizeThatFits(ProposedViewSize(width: shownWidth, height: nil))
        let textFrame = CGRect(x: 0, y: 0, width: shownWidth, height: textSize.height)
        let actionFrame = CGRect(x: 0, y: textSize.height + spacing, width: shownWidth, height: actionSize.height)
        return ([textFrame, actionFrame], CGSize(width: shownWidth, height: actionFrame.maxY))
    }
}
