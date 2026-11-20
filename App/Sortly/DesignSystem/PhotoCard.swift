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
    /// Side by side (a shelf, two in a row): title in the headline style, its actions full width
    /// below the text.
    case compact
    /// Across the page ("Schon gefunden", a new trip): a larger title, its action next to the
    /// text, below it at the accessibility text sizes.
    case large
}

/// Photo on top, text below (title up to 2 lines, one subtitle line), optional badge on a solid light ground,
/// actions below the text; stacks at accessibility sizes; one VoiceOver element (caller adds actions).
///
/// - No text on the photo: name and count sit below it; the badge has its own white ground.
/// - The cover is a `CoverPhoto`: sharp from the device or a calm placeholder, "Vorschau
///   ausgeblendet" with `hidesPreview`.
/// - VoiceOver: one element, "title, subtitle", the badge as its value ("Neu", "+12 Fotos",
///   "Angelegt"). The buttons in `actions` are for touch; the caller gives the card the same
///   actions with `.accessibilityAction(named:)` (and a default action if tapping it opens
///   something).
/// - Accessibility text sizes: everything below each other, nothing cut off (no line limits),
///   the badge moves from the photo into the text so it never covers the photo.
/// - Dark mode: the card colour of the system; Increase Contrast: the card gets an edge.
struct PhotoCard<Actions: View>: View {
    private let coverIDs: [AssetID]
    private let title: Text
    private let subtitle: Text?
    private let badge: CardBadge?
    private let hidesPreview: Bool
    private let aspectRatio: CGFloat
    private let style: PhotoCardStyle
    private let actions: Actions

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact, @ViewBuilder actions: () -> Actions) {
        self.coverIDs = coverIDs
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.hidesPreview = hidesPreview
        self.aspectRatio = aspectRatio
        self.style = style
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style == .large ? Theme.Radius.largeCard : Theme.Radius.compactCard,
                                     style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            CoverPhoto(ids: coverIDs, aspectRatio: aspectRatio, cornerRadius: 0, hidesPreview: hidesPreview)
                .overlay(alignment: .topLeading) {
                    if let badge, !typeSize.isAccessibilitySize {
                        CardBadgeLabel(badge: badge)
                            .padding(Theme.Spacing.s)
                    }
                }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(badge?.spoken ?? Text(verbatim: ""))
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }

    /// The drafts' 20 pt bold title across the page, 17 pt semibold side by side.
    private var titleFont: Font { style == .large ? Font.title3.weight(.bold) : Font.headline }
    private var subtitleFont: Font { style == .large ? Font.subheadline : Font.footnote }

    /// "Kyoto, Oktober 2024, 16 Fotos · Neues Album".
    private var spokenTitle: Text {
        guard let subtitle else { return title }
        return Text("\(title), \(subtitle)")
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let badge, typeSize.isAccessibilitySize {
                CardBadgeLabel(badge: badge)
                    .padding(.bottom, Theme.Spacing.xs)
            }
            title
                .font(titleFont)
                .foregroundStyle(.primary)
                .compactLineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                subtitle
                    .font(subtitleFont)
                    .foregroundStyle(.noteText)
                    .compactLineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var details: some View {
        switch style {
        case .compact:
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
            .padding(.top, Theme.Spacing.m)
            .padding(.leading, Theme.Spacing.l)
            .padding(.trailing, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.m)
        }
    }
}

extension PhotoCard where Actions == EmptyView {
    /// A card without buttons (an album, a cover to look at).
    init(coverIDs: [AssetID], title: Text, subtitle: Text?, badge: CardBadge? = nil, hidesPreview: Bool = false,
         aspectRatio: CGFloat = 4.0 / 3.0, style: PhotoCardStyle = .compact) {
        self.init(coverIDs: coverIDs, title: title, subtitle: subtitle, badge: badge, hidesPreview: hidesPreview,
                  aspectRatio: aspectRatio, style: style) { EmptyView() }
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
/// edge that keeps its shape on a white sky.
struct CardBadgeLabel: View {
    var badge: CardBadge

    var body: some View {
        label
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
            .environment(\.colorScheme, .light)
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
