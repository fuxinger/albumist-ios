import SwiftUI
import AlbumistCore

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
///   sits on the card, so a long press lifts what was pressed, in the card's own shape, and its
///   buttons are also actions of the body, because the card around the body is a container that
///   VoiceOver, Switch Control, Voice Control and Full Keyboard Access do not stop on (second
///   review of wave 1). A card with a menu still passes its actions first (`{}` when it has
///   none): the first trailing closure is always `actions`. `menuOffered(false)` switches the
///   long press off by a menu closure that returns nothing, as Apple documents it for
///   `contextMenu(menuItems:)` (no lift, no menu, no actions): only for a card that lifts
///   itself, as beside a preview of its own that is not documented to lift nothing (review C2
///   of design wave 2, N1); no card with a preview of its own is switched off.
///   `menuAccessibilityActions(_:)` gives the body other actions than the menu's items, such as
///   all but the card's own button (review C of design wave 2, M4, L3).
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
    /// The long press is offered now (`menuOffered(_:)`); without it the menu's closure returns
    /// nothing.
    private var isMenuOffered = true
    /// The body's accessibility actions instead of the menu's items (`menuAccessibilityActions(_:)`).
    private var accessibilityMenuItems: MenuItems?
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
            // behind cover and texts); assistive technologies get the items on the body. Beside
            // a preview of its own, a menu closure that returns nothing is not documented to
            // lift nothing (review C2 of design wave 2, N1): no such card is switched off.
            shaped.contextMenu {
                if isMenuOffered { menuItems }
            } preview: {
                menuPreview
            }
        } else {
            // A menu closure that returns nothing switches the long press off, as Apple
            // documents it for `contextMenu(menuItems:)`.
            shaped.contextMenu {
                if isMenuOffered { menuItems }
            }
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
        // A long press lifts the card itself in its own shape (the system's has smaller corners).
        .contentShape(.contextMenuPreview, shape)
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
            // The long press's items as the body's own actions (VoiceOver: swipe up or down), or
            // those given for them; none while the long press is off.
            described.accessibilityActions {
                if isMenuOffered { accessibilityMenuItems ?? menuItems }
            }
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

    /// Whether the long press is offered now: without it the menu's closure returns nothing, as
    /// Apple documents it to switch `contextMenu(menuItems:)` off, so a long press lifts nothing
    /// and the body has no actions (a card made a moment ago, one whose album is made, a list
    /// that selects; review C of design wave 2, M4). Only for a card that lifts itself (`menu:`
    /// without `preview:`): beside a preview of its own that is not documented (review C2 of
    /// design wave 2, N1).
    func menuOffered(_ offered: Bool) -> Self {
        var card = self
        card.isMenuOffered = offered
        return card
    }

    /// The body's actions for VoiceOver, Voice Control and Switch Control instead of the menu's
    /// items, such as all but what the card shows as its own button (review C of design wave 2,
    /// L3).
    func menuAccessibilityActions(_ items: MenuItems) -> Self {
        var card = self
        card.accessibilityMenuItems = items
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
