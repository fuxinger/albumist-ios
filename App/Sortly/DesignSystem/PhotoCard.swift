import SwiftUI
import SortlyCore

/// The small label on a card's photo, on a solid light ground (design rule 1): "Neu" for an album
/// Albumist made, "+12" for photos it added to an album (never "Neu" there), "✓ Angelegt" right
/// after "Anlegen" on the card.
enum CardBadge: Equatable, Sendable {
    case new
    case added(Int)
    case created
}

/// How a `PhotoCard` sits on the page.
enum PhotoCardStyle: Sendable {
    /// Side by side (a shelf, two in a row; drafts E1, E6): a white card, the title in the
    /// headline style, its actions full width below the text. Every compact card keeps the
    /// height of three text lines, so cards side by side are equally high whatever their texts.
    case compact
    /// Across the page ("Schon gefunden", "Neue Reisen"; drafts E6): a larger title, the action
    /// next to the text while the text keeps room for a long word, below it otherwise and at the
    /// accessibility text sizes.
    case large
    /// An album in a row or a grid (draft E4): the photo with round corners on the page, name
    /// and count below it, no card around them.
    case tile
}

/// Photo on top, text below (title up to 2 lines, the subtitle in what is left of 3), optional badge on a
/// solid light ground, actions below the text; stacks at accessibility sizes. For assistive technologies the
/// card is a container: its body (cover, title, subtitle, badge) is one element, its actions are real buttons.
///
/// - No text on the photo: name and count sit below it; the badge has its own white ground.
/// - The cover is a `CoverPhoto`: sharp from the device or a calm placeholder, "Vorschau
///   ausgeblendet" with `hidesPreview`. `coverIDs`: `PreviewPicker.coverCandidates`.
/// - Text within three lines at the standard sizes (design rule 4): the title up to two, the
///   subtitle the lines the title leaves (one under a two-line title, two under a one-line one,
///   as "Florenz, Mai 2023 / Kommt in dein Album „Toskana“ · +12 Fotos" in the drafts).
/// - Accessibility text sizes: everything below each other and nothing cut off (no line limits),
///   the photo a wide strip so name and button stay in view (draft E7), the badge moves from the
///   photo into the text so it never covers the photo, buttons span the card.
/// - VoiceOver, Switch Control, Voice Control, Full Keyboard Access: the card is a container
///   (`.contain`; an `.accessibilityIdentifier` on the card names it). Its body is one element,
///   first: "title, subtitle", the badge as its value ("Neu", "+12 Fotos", "Angelegt"), the title
///   as its Voice Control name; with `onOpen` it is a button that opens the card. The views in
///   `actions` stay buttons of their own ("Anlegen tippen"), so nothing needs to be repeated as
///   an accessibility action, and nothing is nested: `onOpen` is the body's own button, behind
///   the cover and the texts (they let touches through to it), never a button around the card.
/// - Long press (`menu:`, optionally `preview:` for what it lifts instead of the card): the menu
///   sits on the card, so a long press lifts what was pressed, and its buttons are also actions
///   of the body, because the card around the body is a container that VoiceOver, Switch
///   Control, Voice Control and Full Keyboard Access do not stop on (second review of wave 1).
///   A card with a menu still passes its actions first (`{}` when it has none): the first
///   trailing closure is always `actions`.
/// - Dark mode: the card colour of the system; Increase Contrast: the card gets an edge (as
///   `Card`); the actions' own contrast: `CardActionButtonStyle`.
struct PhotoCard<Actions: View, MenuItems: View, MenuPreview: View>: View {
    private let coverIDs: [AssetID]
    private let title: Text
    private let subtitle: Text?
    private let badge: CardBadge?
    private let hidesPreview: Bool
    private let aspectRatio: CGFloat
    private let style: PhotoCardStyle
    private let placeholderSymbol: String?
    private let onCoverOutcome: (@MainActor (CoverOutcome) -> Void)?
    private let onOpen: (@MainActor () -> Void)?
    private let actions: Actions
    /// The long press's menu, also the body's accessibility actions; `EmptyView`: none.
    private let menuItems: MenuItems
    /// What the long press lifts; `EmptyView`: the card itself.
    private let menuPreview: MenuPreview
    /// Ticked in a list that selects (`selected(_:)`).
    private var isSelected = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    /// The texts of a large card keep this much width beside the action (`ActionBesideText`).
    @ScaledMetric(relativeTo: .title3) private var minimumTextWidth: CGFloat = CardTextMetrics.minimumTextBesideAction
    /// The body's button is held: cover and texts dim, as a plain button's label does.
    @State private var pressed = false

    /// A card with a long-press menu and what the long press lifts (an album's large cover and
    /// its line, draft E4). The other initializers leave out the menu, the preview, or both.
    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, placeholderSymbol: String? = nil,
         onCoverOutcome: (@MainActor (CoverOutcome) -> Void)? = nil, onOpen: (@MainActor () -> Void)? = nil,
         @ViewBuilder actions: () -> Actions, @ViewBuilder menu: () -> MenuItems, @ViewBuilder preview: () -> MenuPreview) {
        self.coverIDs = coverIDs
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.hidesPreview = hidesPreview
        self.aspectRatio = aspectRatio
        self.style = style
        self.placeholderSymbol = placeholderSymbol
        self.onCoverOutcome = onCoverOutcome
        self.onOpen = onOpen
        self.actions = actions()
        self.menuItems = menu()
        self.menuPreview = preview()
    }

    var body: some View {
        if !hasMenu {
            shaped
        } else if hasMenuPreview {
            // On the card, so a long press lifts what was pressed (the body is a clear button
            // behind cover and texts); assistive technologies get the items on the body.
            shaped.contextMenu { menuItems } preview: { menuPreview }
        } else {
            shaped.contextMenu { menuItems }
        }
    }

    @ViewBuilder private var shaped: some View {
        if style == .tile {
            tile
        } else {
            card
        }
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }
    private var hasMenu: Bool { MenuItems.self != EmptyView.self }
    private var hasMenuPreview: Bool { MenuPreview.self != EmptyView.self }

    /// "Kyoto, Oktober 2024, 16 Fotos · Neues Album".
    private var spokenTitle: Text {
        guard let subtitle else { return title }
        return Text("\(title), \(subtitle)")
    }

    /// At the accessibility sizes the photo becomes a wide strip (draft E7: 343 × 104 pt on the
    /// small iPhone), so the name and the button are in view with it.
    private var shownAspectRatio: CGFloat {
        typeSize.isAccessibilitySize ? max(aspectRatio, 3) : aspectRatio
    }

    private var cover: some View {
        CoverPhoto(ids: coverIDs, aspectRatio: shownAspectRatio, cornerRadius: style == .tile ? Theme.Radius.photoTile : 0,
                   hidesPreview: hidesPreview, placeholderSymbol: placeholderSymbol, onOutcome: onCoverOutcome)
            .overlay(alignment: .topLeading) {
                if let badge, !typeSize.isAccessibilitySize {
                    CardBadgeLabel(badge: badge)
                        .padding(Theme.Spacing.s)
                }
            }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: style == .large ? Theme.Radius.largeCard : Theme.Radius.compactCard,
                                     style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            face(cover)
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBody }
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 7) {
            face(cover)
            face(texts)
            if hasActions {
                actionsView(fillsWidth: true, inset: CardTextMetrics.compactActionInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBody }
        .accessibilityElement(children: .contain)
    }

    /// Cover and texts: drawn in front, but touches go through to the card's body behind them,
    /// and assistive technologies read them as that body (`cardBody`).
    private func face(_ content: some View) -> some View {
        content
            .opacity(pressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The card's body as one element, behind the whole card: a button that opens the card when
    /// there is `onOpen`, otherwise only what it says. First in the card for VoiceOver; its
    /// Voice Control name is the title ("Kyoto, Oktober 2024 tippen").
    @ViewBuilder private var cardBody: some View {
        if let onOpen {
            describedAsBody(
                Button(action: onOpen) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(PressReportingButtonStyle(pressed: $pressed))
            )
        } else {
            describedAsBody(Color.clear.accessibilityElement())
        }
    }

    @ViewBuilder
    private func describedAsBody(_ element: some View) -> some View {
        let described = element
            .accessibilityLabel(spokenTitle)
            .accessibilityValue(badge?.spoken ?? Text(verbatim: ""))
            .accessibilityInputLabels([title])
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilitySortPriority(1)
            .accessibilityIdentifier("photoCard.body")
        if hasMenu {
            // The long press's items as the body's own actions (VoiceOver: swipe up or down).
            described.accessibilityActions { menuItems }
        } else {
            described
        }
    }

    /// The drafts: 20 pt bold across the page, 17 pt semibold in a card side by side, 15 pt
    /// semibold under an album tile; the line below in the note grey.
    private var titleFont: Font {
        switch style {
        case .large: Font.title3.weight(.bold)
        case .compact: Font.headline
        case .tile: Font.subheadline.weight(.semibold)
        }
    }

    private var subtitleFont: Font { style == .large ? Font.subheadline : Font.footnote }

    private var texts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let badge, typeSize.isAccessibilitySize {
                CardBadgeLabel(badge: badge)
            }
            CardTextLayout(limitsLines: !typeSize.isAccessibilitySize,
                           reservesLines: style == .compact && !typeSize.isAccessibilitySize, spacing: 2) {
                title
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .compactLineLimit(2)
                // One and two lines in each font: the heights `CardTextLayout` counts with.
                probe("A", font: titleFont)
                probe("A\nA", font: titleFont)
                probe("A", font: subtitleFont)
                probe("A\nA", font: subtitleFont)
                if let subtitle {
                    subtitle
                        .font(subtitleFont)
                        .foregroundStyle(.noteText)
                        .compactLineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func probe(_ lines: String, font: Font) -> some View {
        Text(verbatim: lines)
            .font(font)
            .hidden()
            .accessibilityHidden(true)
    }

    /// The actions in one view (a layout would take several apart), told how wide to be and how
    /// much room the word gets inside its capsule (`CardActionButtonStyle`).
    private func actionsView(fillsWidth: Bool, inset: CGFloat) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            actions
        }
        .environment(\.cardActionFillsWidth, fillsWidth)
        .environment(\.cardActionInset, inset)
    }

    @ViewBuilder private var details: some View {
        switch style {
        case .compact, .tile:
            VStack(alignment: .leading, spacing: 10) {
                face(texts)
                if hasActions {
                    actionsView(fillsWidth: true, inset: CardTextMetrics.compactActionInset)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, CardTextMetrics.compactInset)
            .padding(.bottom, Theme.Spacing.m)
        case .large:
            ActionBesideText(spacing: Theme.Spacing.m, minimumTextWidth: minimumTextWidth,
                             stacks: typeSize.isAccessibilitySize) {
                face(texts)
                if hasActions {
                    actionsView(fillsWidth: true, inset: 18)
                }
            }
            .padding(.top, 10)
            .padding(.leading, Theme.Spacing.l)
            .padding(.trailing, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.m)
        }
    }
}

extension PhotoCard {
    /// The card is ticked in a list that selects, as in Photos: VoiceOver says "ausgewählt" on
    /// its body too, where it starts, not only on the tick (second review of the suggestion
    /// cards). The tick itself stays the list's.
    func selected(_ selected: Bool) -> Self {
        var card = self
        card.isSelected = selected
        return card
    }
}

extension PhotoCard where MenuPreview == EmptyView {
    /// A card with a long-press menu that lifts the card itself.
    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, placeholderSymbol: String? = nil,
         onCoverOutcome: (@MainActor (CoverOutcome) -> Void)? = nil, onOpen: (@MainActor () -> Void)? = nil,
         @ViewBuilder actions: () -> Actions, @ViewBuilder menu: () -> MenuItems) {
        self.init(coverIDs: coverIDs, title: title, subtitle: subtitle, badge: badge, hidesPreview: hidesPreview,
                  aspectRatio: aspectRatio, style: style, placeholderSymbol: placeholderSymbol,
                  onCoverOutcome: onCoverOutcome, onOpen: onOpen, actions: actions, menu: menu, preview: { EmptyView() })
    }
}

extension PhotoCard where MenuItems == EmptyView, MenuPreview == EmptyView {
    /// A card with buttons and no long-press menu.
    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, placeholderSymbol: String? = nil,
         onCoverOutcome: (@MainActor (CoverOutcome) -> Void)? = nil, onOpen: (@MainActor () -> Void)? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.init(coverIDs: coverIDs, title: title, subtitle: subtitle, badge: badge, hidesPreview: hidesPreview,
                  aspectRatio: aspectRatio, style: style, placeholderSymbol: placeholderSymbol,
                  onCoverOutcome: onCoverOutcome, onOpen: onOpen, actions: actions, menu: { EmptyView() }, preview: { EmptyView() })
    }
}

extension PhotoCard where Actions == EmptyView, MenuItems == EmptyView, MenuPreview == EmptyView {
    /// A card without buttons (an album, a cover to look at).
    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, placeholderSymbol: String? = nil,
         onCoverOutcome: (@MainActor (CoverOutcome) -> Void)? = nil, onOpen: (@MainActor () -> Void)? = nil) {
        self.init(coverIDs: coverIDs, title: title, subtitle: subtitle, badge: badge, hidesPreview: hidesPreview,
                  aspectRatio: aspectRatio, style: style, placeholderSymbol: placeholderSymbol,
                  onCoverOutcome: onCoverOutcome, onOpen: onOpen, actions: { EmptyView() }, menu: { EmptyView() },
                  preview: { EmptyView() })
    }
}

/// A plain button that says when it is held, so the card can dim its cover and texts, which lie
/// in front of the button.
private struct PressReportingButtonStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
    }
}

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
private struct CardTextLayout: Layout {
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
private struct ActionBesideText: Layout {
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

extension CardBadge {
    /// What VoiceOver says for the badge (the card's value): "+12" is "+12 Fotos" (the
    /// integer picks the plural form, the grouped number is shown: "+1.234 Fotos").
    var spoken: Text {
        switch self {
        case .new: Text("Neu")
        case .added(let count): Text("+\(count) \(count.formatted()) Fotos")
        case .created: Text("Angelegt")
        }
    }
}

/// A `CardBadge` on its solid light ground: the accent on white, in dark mode too, so it reads
/// the same on any photo (5.97:1; Increase Contrast 8.27:1 with the deeper teal), with a hairline
/// edge that keeps its shape on a white sky; with Increase Contrast the edge is the deeper teal
/// itself, 1 pt (8.27:1 against the white badge and a white sky alike). Like the mosaic's
/// "+N" it stops growing at the first accessibility size and keeps to one line (on the photo it is
/// never cut; `PhotoCard` moves it below the photo at the accessibility sizes).
struct CardBadgeLabel: View {
    var badge: CardBadge
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        label
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white, in: Capsule())
            .overlay {
                Capsule().strokeBorder(contrast == .increased ? Theme.accent : Color.black.opacity(0.08),
                                       lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        switch badge {
        case .new:
            Text("Neu")
        case .added(let count):
            // Grouped like every large count ("+1.234"); a number needs no translation.
            Text(verbatim: "+" + count.formatted())
        case .created:
            Label("Angelegt", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
        }
    }
}
