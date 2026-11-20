import SwiftUI

/// Tinted (not filled) word button for cards, ≥ 44 pt, wraps instead of truncating.
///
/// Design rule 3: one filled main button per page at most; actions on cards are tinted: the
/// accent as text on a light fill of the accent, a capsule at least 44 pt high ("Anlegen",
/// "Ergänzen …", "Benennen …", "Ansehen …", "✓ Angelegt"). Not glass: it sits in the content.
/// Under a compact `PhotoCard` it spans the card's width (`cardActionFillsWidth`), elsewhere it is
/// as wide as its words. At large text sizes the words wrap and the capsule grows; its corners
/// grow with the text, so a one-line button stays a capsule.
///
/// WCAG 2 contrast of the text on its fill (sRGB, alpha composited), on a card:
/// light 5.09:1 (11 % fill on white), Increase Contrast 6.92:1 (deeper teal);
/// dark 5.71:1 (18 % fill on #1C1C1E), 4.67:1 on a card in a sheet (#2C2C2E), Increase Contrast
/// 6.19:1 and 4.92:1. Pressed, the fill fades to half, so the text only gains contrast
/// (light 5.52:1, dark 6.92:1, in a sheet 5.62:1). Disabled: `Theme.noteText` on the grey fill
/// (5.13:1 light, 5.62:1 dark), never the accent. Increase Contrast adds an accent edge (the
/// accent itself on the card: 8.27:1 light, 9.48:1 dark, 7.38:1 in a sheet, far above the 3:1
/// for a control's outline). Off a card, on the grouped background: light 4.59:1, so keep it on cards.
struct CardActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardActionButtonBody(configuration: configuration)
    }
}

private struct CardActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.cardActionFillsWidth) private var fillsWidth
    /// Half the height of a one-line button, growing with the text.
    @ScaledMetric(relativeTo: .body) private var radius: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isEnabled ? Theme.accent : Theme.noteText)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .background(fill, in: shape)
            .overlay {
                if contrast == .increased && isEnabled {
                    shape.strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .hoverEffect(.highlight)
    }

    /// 11 % of the accent in light mode, 18 % in dark mode (the drafts' "tealtint"), half of it
    /// while pressed; the system's grey fill when disabled.
    private var fill: Color {
        guard isEnabled else { return Color(uiColor: .tertiarySystemFill) }
        let share = colorScheme == .dark ? 0.18 : 0.11
        return Theme.accent.opacity(configuration.isPressed ? share / 2 : share)
    }
}

private struct CardActionFillsWidthKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a `CardActionButtonStyle` button spans the width it is offered (`PhotoCard` sets
    /// it for the actions below a compact card's text and at accessibility sizes).
    var cardActionFillsWidth: Bool {
        get { self[CardActionFillsWidthKey.self] }
        set { self[CardActionFillsWidthKey.self] = newValue }
    }
}
