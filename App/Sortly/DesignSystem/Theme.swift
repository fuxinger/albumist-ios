import SwiftUI
import SortlyCore

/// Design tokens for direction A "Klar" (chosen 2026-11-13): calm, light, close to iOS.
/// System font (SF Pro) with Dynamic Type everywhere; numbers use monospaced digits.
/// Liquid Glass comes from the system: tab bar, toolbars and the two button styles below;
/// content stays plain.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 20
        static let tile: CGFloat = 10
        static let button: CGFloat = 16
        /// A `PhotoCard` across the page and one of two side by side (the drafts' 26 and 22 pt:
        /// the smaller card, the smaller corner).
        static let largeCard: CGFloat = 26
        static let compactCard: CGFloat = 22
    }

    /// Named asset instead of `Color.accentColor`, so off-screen renders (share image) keep the teal too.
    /// The asset has Increase Contrast variants (a deeper teal in light mode, a lighter one in
    /// dark mode). WCAG 2 contrast ratios (sRGB, alpha composited):
    /// white on teal 5.97:1 (light), 8.27:1 (light, Increase Contrast);
    /// near-black on teal 8.95:1 (dark), black on teal 12.86:1 (dark, Increase Contrast);
    /// teal text on white cards 5.97:1, on the grouped background 5.35:1, on its own 12 % badge 5.01:1.
    static let accent = Color("AccentColor")
    /// Text and symbols on an accent fill: white on the dark teal of light mode, near-black
    /// on the lighter teal of dark mode (white there would fall below 3:1 contrast).
    static let onAccent = Color(uiColor: UIColor { traits in
        guard traits.userInterfaceStyle == .dark else { return .white }
        return traits.accessibilityContrast == .high ? .black : UIColor(white: 0.07, alpha: 1)
    })
    /// One-line buttons are capsules (radius = half of 50 pt); a label that wraps at the
    /// largest text sizes keeps rounded corners instead of turning into an oval.
    static var buttonShape: RoundedRectangle { RoundedRectangle(cornerRadius: 25, style: .continuous) }
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    /// Small secondary text (footnote, caption, subheadline) on cards, list rows, the grouped
    /// background and the grey fill chips, as `.foregroundStyle(.noteText)` (review P3-14). The
    /// system `secondaryLabel` is 3.4:1 on white and 3.3:1 on the grouped background in light
    /// mode (WCAG 1.4.3 asks 4.5:1). This is the lightest grey that holds 4.6:1 on all of them,
    /// so it stays clearly lighter than the primary text, as Apple's grey does:
    /// light 5.9:1 on white, 5.3:1 on the grouped background, 5.1:1 on a fill chip on a card,
    /// 4.6:1 on a fill chip on the grouped background; dark 7.5:1 on cards, 9.2:1 on black,
    /// 6.1:1 on cards in a sheet, 5.6:1 on a fill chip, 4.7:1 on a fill chip in a sheet;
    /// Increase Contrast clearly stronger: light 8.4:1 on white, 5.7:1 at the least (chip on
    /// the grouped background); dark 9.0:1 on cards, 5.2:1 at the least (chip in a sheet).
    /// Not on the photo colour wash: there it falls short, that is `secondaryText`.
    /// `.github/scripts/tests/test_secondary_text_rule.py` recomputes these numbers.
    static let noteText = adaptive(light: (0.39, 0.39, 0.42), dark: (0.67, 0.67, 0.70),
                                   lightHigh: (0.30, 0.30, 0.33), darkHigh: (0.77, 0.77, 0.80))
    /// Secondary text on the photo colour wash (suggestion and country headers), where the
    /// lighter `noteText` and the system grey do not hold 4.5:1: the system `secondaryLabel` is
    /// 3.4:1 on white and drops below 3:1 on a tinted wash ("Contrast failed" in the audit).
    /// This grey: light 9.5:1 on white, 8.5:1 on the grouped background, 4.7:1 on the strongest
    /// wash; dark 12.5:1 on black, 10.1:1 on cards, 5.4:1 on the strongest wash; Increase
    /// Contrast (no wash) 11.6:1 and 14.5:1. Almost as dark as the primary text, so use it only
    /// on the wash (and on the muted search token on its own tinted capsule).
    static let secondaryText = Color(uiColor: UIColor { traits in
        let high = traits.accessibilityContrast == .high
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: high ? 0.84 : 0.78, green: high ? 0.84 : 0.78, blue: high ? 0.86 : 0.81, alpha: 1)
        }
        return UIColor(red: high ? 0.22 : 0.27, green: high ? 0.22 : 0.27, blue: high ? 0.24 : 0.30, alpha: 1)
    })

    /// Area colors: distinct in lightness, not only hue (accessibility). Dark mode uses
    /// lighter variants so text in these colors keeps at least 4.5:1 contrast there too
    /// (on cards and on their own 12 % badges: 5.0–7.6:1). Increase Contrast moves each one
    /// further from the background (6.8–11:1).
    static func tint(for area: OrganizationAreaStyle) -> Color {
        switch area {
        case .trips: adaptive(light: (0.04, 0.43, 0.48), dark: (0.32, 0.77, 0.79),
                              lightHigh: (0.00, 0.34, 0.38), darkHigh: (0.46, 0.86, 0.88))
        case .places: adaptive(light: (0.18, 0.31, 0.66), dark: (0.55, 0.67, 1.00),
                               lightHigh: (0.12, 0.23, 0.55), darkHigh: (0.68, 0.77, 1.00))
        case .documents: adaptive(light: (0.54, 0.35, 0.07), dark: (0.93, 0.70, 0.36),
                                  lightHigh: (0.43, 0.27, 0.04), darkHigh: (0.97, 0.79, 0.50))
        case .neutral: Color(uiColor: .secondaryLabel)
        }
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double),
                                 lightHigh: (Double, Double, Double), darkHigh: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let c = traits.userInterfaceStyle == .dark ? (high ? darkHigh : dark) : (high ? lightHigh : light)
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

enum OrganizationAreaStyle { case trips, places, documents, neutral }

extension Font {
    /// Big numbers ("10 neue Alben", the counts of the map): SF Pro in its expanded width with
    /// monospaced digits, Apple's own type for figures (DS-11; no font of our own). Grows with
    /// Dynamic Type like `style`; a number that counts keeps its width.
    static func wideNumber(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, weight: weight).width(.expanded).monospacedDigit()
    }
}

extension Text {
    /// A big number in the wide figures (`Font.wideNumber`), e.g. `Text(count, format: .number).wideNumber(.largeTitle)`.
    func wideNumber(_ style: Font.TextStyle = .largeTitle, weight: Font.Weight = .bold) -> Text {
        font(.wideNumber(style, weight: weight))
    }
}

extension ShapeStyle where Self == Color {
    /// The one style for small secondary text on cards, list rows and the grouped background:
    /// `Theme.noteText` (4.6:1 and more there, light and dark) instead of the system grey
    /// `.secondary` (3.4:1 on a white card). Use it wherever `.footnote`, `.caption`,
    /// `.caption2` or `.subheadline` text is grey: `.font(.footnote).foregroundStyle(.noteText)`.
    /// Works on `Text` too, so it keeps a `Text` a `Text`. On the photo colour wash use
    /// `Theme.secondaryText`. CI: `.github/scripts/secondary_text_rule.py`.
    static var noteText: Color { Theme.noteText }
}

/// White rounded card on the grouped background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { content }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: shape)
            // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge.
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                }
            }
    }
}

/// Progress ring for the organized share. Below 1 it shows at most 99 % (`Progress.shownShare`):
/// the percent format rounds to the nearest, and 199 of 200 read "100 %" with a photo still open.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 10

    var body: some View {
        let shown = OrganizationStatusResolver.Progress.shownShare(fraction)
        ZStack {
            Circle().stroke(Color(uiColor: .systemFill), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, shown))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(shown, format: .percent.precision(.fractionLength(0)))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                // Large text sizes shrink the number to fit inside the ring instead of "6…".
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(lineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sortiert"))
        .accessibilityValue(Text(shown, format: .percent.precision(.fractionLength(0))))
    }
}

/// Full-width primary action: a solid accent capsule (`Theme.buttonShape`), Apple's filled button.
///
/// Deliberately not Liquid Glass (`glassProminent`, used until 15.11.): glass belongs to the
/// navigation layer that floats above content (HIG), these buttons sit in the content. And
/// XCTest's accessibility audit cannot measure text on glass: every glass button was reported
/// as "Contrast failed" although it rendered white on teal at 5.97:1, while the solid
/// `borderedProminent` "Teilen" button with the same colours passed. A plain fill keeps the
/// contrast fixed and measurable in light, dark and Increase Contrast.
/// The label wraps and the capsule grows with Dynamic Type; it is never shorter than 50 pt.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // Disabled: the system's grey fill and secondary text, like a disabled filled button.
            .foregroundStyle(isEnabled ? Theme.onAccent : Color(uiColor: .secondaryLabel))
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isEnabled ? Theme.accent : Color(uiColor: .tertiarySystemFill), in: Theme.buttonShape)
            .contentShape(Theme.buttonShape)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

/// Secondary full-width action: a grey filled capsule with the primary text colour
/// (15.7–17.4:1 in light mode, 11.4–15:1 in dark mode). Not glass, for the reasons above.
/// Increase Contrast adds an edge so the capsule stands out from the card it sits on.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(uiColor: .secondarySystemFill), in: Theme.buttonShape)
            .overlay {
                if contrast == .increased {
                    Theme.buttonShape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                }
            }
            .contentShape(Theme.buttonShape)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

/// A panel that floats above scrolling content (the split preview of the trip workshop, the
/// actions for selected photos): an opaque card with a soft shadow instead of Liquid Glass.
/// Text on glass took on the colours of the photos scrolling underneath (the audit reported
/// "Contrast failed" for "12 Fotos" on the split preview); on the card it keeps its contrast.
struct FloatingPanel: ViewModifier {
    var cornerRadius: CGFloat = 28
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Theme.card, in: shape)
            .overlay {
                shape.strokeBorder(Color(uiColor: contrast == .increased ? UIColor.opaqueSeparator : UIColor.separator),
                                   lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
    }
}

/// Swaps a sliding transition for a cross-fade when Reduce Motion is on.
struct MotionAwareTransition: ViewModifier {
    var transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

/// A line limit that only applies below the accessibility text sizes: with the largest sizes
/// a title wraps as far as it needs instead of ending in "…" (audit: "Text clipped").
struct CompactLineLimit: ViewModifier {
    var limit: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.lineLimit(typeSize.isAccessibilitySize ? nil : limit)
    }
}

extension View {
    func floatingPanel(cornerRadius: CGFloat = 28) -> some View {
        modifier(FloatingPanel(cornerRadius: cornerRadius))
    }

    /// `transition`, or a cross-fade with Reduce Motion.
    func motionAwareTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionAwareTransition(transition: transition))
    }

    /// `lineLimit(limit)` up to the largest standard text size, unlimited at accessibility sizes.
    func compactLineLimit(_ limit: Int) -> some View {
        modifier(CompactLineLimit(limit: limit))
    }

    /// At least 44 × 44 pt to tap (HIG), without changing how the control looks.
    func minimumHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

/// A menu picker squeezes its value into one line next to or under the label; at the
/// accessibility text sizes the value ends in "…" ("Gan…thek", audit: "Text clipped").
/// There the picker becomes a navigation row whose choices are full-width, wrapping rows.
struct AdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.navigationLink)
        } else {
            content.pickerStyle(.menu)
        }
    }
}

extension View {
    /// Menu picker, or a navigation row at the accessibility text sizes (needs a NavigationStack).
    func adaptivePickerStyle() -> some View {
        modifier(AdaptivePickerStyle())
    }
}

/// Leaves a decorative view out at the accessibility text sizes, where a leading icon would
/// squeeze the text next to it into a column so narrow that words break mid-word.
struct HiddenAtAccessibilitySizes: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if !typeSize.isAccessibilitySize { content }
    }
}

extension View {
    func hiddenAtAccessibilitySizes() -> some View {
        modifier(HiddenAtAccessibilitySizes())
    }
}

/// Lays its content out side by side, and below each other at the accessibility text sizes,
/// where a row with a trailing value would squeeze the title into a narrow column.
struct AdaptiveStack<Content: View>: View {
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content }
    }
}

/// Small icon tile used in lists. It grows a little with the text (36 pt up to 48 pt) and
/// the symbol stops at the largest standard size, so it never spills out of its tile.
struct IconTile: View {
    var systemName: String
    var tint: Color
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 36

    var body: some View {
        let side = min(self.side, 48)
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Capsule label for statuses ("Neu", "Album da", "Unsicher").
struct StatusBadge: View {
    var text: LocalizedStringKey
    var tint: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// An error in words with a red symbol in front (design review D2). The text keeps the
/// primary colour: system red text was 3.6:1 on a white card (WCAG 1.4.3 asks 4.5:1), and the
/// colour alone said "error" (WCAG 1.4.1). The filled symbol says it without colour and as a
/// graphic only needs 3:1; VoiceOver hears "Fehler" first. Same pattern as the
/// "Nicht alles hat geklappt" card of the preview.
struct ErrorNote: View {
    var text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
        .font(.footnote)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fehler: \(text)"))
        .accessibilityIdentifier("error.note")
    }
}

/// The visible choice of a menu at the largest text sizes: wraps instead of being cut,
/// with the up-down chevron of a system pop-up menu.
struct MenuChoiceLabel: View {
    var text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            text
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
        }
        .font(.headline)
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
