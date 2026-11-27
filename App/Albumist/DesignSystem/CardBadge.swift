import SwiftUI
import AlbumistCore

/// The small label on a card's photo, on a solid light ground (design rule 1): "Neu" for an album
/// Albumist made, "+12" for photos it added to an album (never "Neu" there), "✓ Angelegt" right
/// after "Anlegen" on the card.
enum CardBadge: Equatable, Sendable {
    case new
    case added(Int)
    case created
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
