import SwiftUI
import SortlyCore

/// The words of a suggestion's card in SwiftUI (`ProposalCardText`, design wave 1: E1, E6): its
/// one action and its status line.
extension ProposalCardAction {
    /// The card's button (decision "Punkt 2" of 16.11.2026): "Anlegen" creates the album at once,
    /// the others open a page first, which their "…" says.
    var title: LocalizedStringKey {
        switch self {
        case .create: LocalizedStringKey("Anlegen")
        case .add: LocalizedStringKey("Ergänzen …")
        case .name: LocalizedStringKey("Benennen …")
        case .look: LocalizedStringKey("Ansehen …")
        }
    }

    /// One word for the kind of action, for accessibility identifiers ("suggestion.card.create").
    var kind: String {
        switch self {
        case .create: "create"
        case .add: "add"
        case .name: "name"
        case .look: "look"
        }
    }
}

extension ProposalCardText {
    /// The status line as a card shows it, its parts joined with " · ": "Name fehlt" in the app's
    /// warning colour and bold, as its badge said it before (design review D1: 5.0–7.6:1 on cards,
    /// light and dark); the rest takes the card's note grey.
    var styledSubtitle: Text {
        var line = AttributedString()
        for (index, part) in subtitleParts.enumerated() {
            if index > 0 { line.append(AttributedString(" · ")) }
            var run = AttributedString(part)
            if index == 0, status == .nameMissing {
                run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.tint(for: .documents)
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            line.append(run)
        }
        return Text(line)
    }
}

extension AlbumProposal {
    /// The symbol on the calm placeholder of a cover without a sharp photo (only screenshots or
    /// documents, or photos only in iCloud): the area's own symbol, so the card looks meant
    /// that way, not empty (`CoverPhoto.placeholderSymbol`).
    var placeholderSymbol: String { kind.area.symbol }
}
