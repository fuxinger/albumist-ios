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
    /// headline style, its actions full width below the text.
    case compact
    /// Across the page ("Schon gefunden", "Neue Reisen"; drafts E6): a larger title, the action
    /// next to the text, below it at the accessibility text sizes.
    case large
    /// An album in a row or a grid (draft E4): the photo with round corners on the page, name
    /// and count below it, no card around them.
    case tile
}

/// Photo on top, text below (title up to 2 lines, one subtitle line), optional badge on a solid light ground,
/// actions below the text; stacks at accessibility sizes; one VoiceOver element (caller adds actions).
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
/// - VoiceOver: one element, "title, subtitle", the badge as its value ("Neu", "+12 Fotos",
///   "Angelegt"). The buttons in `actions` are for touch; the caller gives the card the same
///   actions with `.accessibilityAction(named:)` (and `.accessibilityAddTraits(.isButton)` with a
///   default action if tapping the card opens something).
/// - Dark mode: the card colour of the system; Increase Contrast: the card gets an edge (as
///   `Card`); the actions' own contrast: `CardActionButtonStyle`.
struct PhotoCard<Actions: View>: View {
    private let coverIDs: [AssetID]
    private let title: Text
    private let subtitle: Text?
    private let badge: CardBadge?
    private let hidesPreview: Bool
    private let aspectRatio: CGFloat
    private let style: PhotoCardStyle
    private let placeholderSymbol: String?
    private let onCoverOutcome: (@MainActor (CoverOutcome) -> Void)?
    private let actions: Actions

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, placeholderSymbol: String? = nil,
         onCoverOutcome: (@MainActor (CoverOutcome) -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
        self.coverIDs = coverIDs
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.hidesPreview = hidesPreview
        self.aspectRatio = aspectRatio
        self.style = style
        self.placeholderSymbol = placeholderSymbol
        self.onCoverOutcome = onCoverOutcome
        self.actions = actions()
    }

    var body: some View {
        Group {
            if style == .tile {
                tile
            } else {
                card
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(badge?.spoken ?? Text(verbatim: ""))
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }

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
            cover
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .contentShape(shape)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 7) {
            cover
            texts
            if hasActions {
                actions
                    .environment(\.cardActionFillsWidth, true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            CardTextLayout(lines: typeSize.isAccessibilitySize ? nil : 3, spacing: 2) {
                title
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .compactLineLimit(2)
                if let subtitle {
                    subtitle
                        .font(subtitleFont)
                        .foregroundStyle(.noteText)
                        .compactLineLimit(2)
                    // One line in the subtitle's font: its line height (`CardTextLayout`).
                    Text(verbatim: "A")
                        .font(subtitleFont)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var details: some View {
        switch style {
        case .compact, .tile:
            VStack(alignment: .leading, spacing: 10) {
                texts
                if hasActions {
                    actions
                        .environment(\.cardActionFillsWidth, true)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.m)
        case .large:
            AdaptiveStack(verticalAlignment: .center, spacing: Theme.Spacing.m) {
                texts
                if hasActions {
                    actions
                        .environment(\.cardActionFillsWidth, typeSize.isAccessibilitySize)
                }
            }
            .padding(.top, 10)
            .padding(.leading, Theme.Spacing.l)
            .padding(.trailing, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.m)
        }
    }
}

extension PhotoCard where Actions == EmptyView {
    /// A card without buttons (an album, a cover to look at).
    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, placeholderSymbol: String? = nil,
         onCoverOutcome: (@MainActor (CoverOutcome) -> Void)? = nil) {
        self.init(coverIDs: coverIDs, title: title, subtitle: subtitle, badge: badge, hidesPreview: hidesPreview,
                  aspectRatio: aspectRatio, style: style, placeholderSymbol: placeholderSymbol,
                  onCoverOutcome: onCoverOutcome) { EmptyView() }
    }
}

/// A card's title and subtitle within three lines at the standard text sizes (design rule 4):
/// the title as it is (its own limit of two lines), the subtitle in the lines the title left,
/// at least one. `lines` nil (the accessibility sizes): both as long as they are. Subviews: the
/// title, then the subtitle and a hidden line in its font that gives its line height (a
/// subtitle may break a line of its own, so its own one-line height says nothing). A text
/// offered less height than it needs ends its last line in "…".
private struct CardTextLayout: Layout {
    var lines: Int?
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(width: proposal.width, subviews: subviews)
        let height = sizes.title.height + (sizes.subtitle.map { spacing + $0.height } ?? 0)
        return CGSize(width: proposal.width ?? max(sizes.title.width, sizes.subtitle?.width ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            switch index {
            case 0:
                subview.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: sizes.title.height))
            case 1:
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes.title.height + spacing), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: sizes.subtitle?.height ?? 0))
            default:
                // The hidden line that measures the subtitle's line height.
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
            }
        }
    }

    private func measure(width: CGFloat?, subviews: Subviews) -> (title: CGSize, subtitle: CGSize?) {
        guard let title = subviews.first else { return (.zero, nil) }
        let titleSize = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
        guard subviews.count > 1 else { return (titleSize, nil) }
        let subtitle = subviews[1]
        let full = subtitle.sizeThatFits(ProposedViewSize(width: width, height: nil))
        guard let lines, subviews.count > 2 else { return (titleSize, full) }
        let titleLine = title.sizeThatFits(.unspecified).height
        let subtitleLine = subviews[2].sizeThatFits(.unspecified).height
        guard titleLine > 0, subtitleLine > 0 else { return (titleSize, full) }
        let titleLines = max(1, Int((titleSize.height / titleLine).rounded()))
        // Room for the lines left and half a line more: a text never fits half a line, so it
        // shows exactly the lines left.
        let room = CGFloat(max(1, lines - titleLines)) * subtitleLine + subtitleLine / 2
        guard full.height > room else { return (titleSize, full) }
        return (titleSize, subtitle.sizeThatFits(ProposedViewSize(width: width, height: room)))
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
/// edge that keeps its shape on a white sky. Like the mosaic's "+N" it stops growing at the first
/// accessibility size and keeps to one line (on the photo it is never cut; `PhotoCard` moves it
/// below the photo at the accessibility sizes).
struct CardBadgeLabel: View {
    var badge: CardBadge

    var body: some View {
        label
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
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
