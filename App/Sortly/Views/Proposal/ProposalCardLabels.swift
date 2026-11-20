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
    /// light and dark); the rest takes the card's note grey. Personal content says so on a line
    /// of its own with the lock before it, under the count (drafts E6: "9 Fotos", "🔒 Persönlicher
    /// Inhalt").
    var styledSubtitle: Text {
        if status == .personal, subtitleParts.count == 2 {
            let count = Text(verbatim: subtitleParts[0] + "\n")
            let lock = Image(systemName: "lock.fill")
            let personal = Text(verbatim: subtitleParts[1])
            let marked = Text("\(lock) \(personal)")
            return Text("\(count)\(marked)")
        }
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

extension ProposalCardText {
    /// What VoiceOver and Voice Control call the card's one button: its action with the album's
    /// name („Kyoto, Oktober 2024“ anlegen, „Toskana“ ergänzen), as on the start page; the button
    /// shows only the action. Its visible word stays a name for Voice Control
    /// (`actionInputLabels`).
    var spokenAction: Text {
        switch action {
        case .create:
            return Text("„\(title)“ anlegen")
        case .add(let album, _):
            let name = album.isEmpty ? title : album
            return Text("„\(name)“ ergänzen")
        case .name:
            return Text("„\(title)“ benennen")
        case .look:
            return Text("„\(title)“ ansehen")
        }
    }

    /// The names Voice Control knows the card's button by: the word it shows ("Anlegen") and the
    /// one VoiceOver says.
    var actionInputLabels: [Text] { [Text(action.title), spokenAction] }

    /// The card's button once its album is made from it ("Angelegt").
    var spokenMade: Text { Text("„\(title)“ angelegt") }

    /// The tick of a card the list can select, named with the album (every tick was
    /// "Auswählen", like the button that starts selecting; second review of the cards).
    var spokenTick: Text { Text("„\(title)“ auswählen") }
}

extension AlbumProposal {
    /// The symbol on the calm placeholder of a cover without a sharp photo (only screenshots or
    /// documents, or photos only in iCloud): the area's own symbol, so the card looks meant
    /// that way, not empty (`CoverPhoto.placeholderSymbol`).
    var placeholderSymbol: String { kind.area.symbol }
}
