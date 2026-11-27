import SwiftUI
import AlbumistCore

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
    /// of its own with the lock before it (drafts E6: "🔒 Persönlicher Inhalt", "9 Fotos"), first:
    /// under a two-line name a card has one line for its status, and the count is what gets cut,
    /// never what makes the card "Ansehen …" (review B of design wave 1, 5). VoiceOver says the
    /// status in words (`spokenStatus`), not the lock's symbol.
    var styledSubtitle: Text {
        let shown: Text
        if status == .personal, subtitleParts.count == 2 {
            let lock = Image(systemName: "lock.fill")
            let personal = Text(verbatim: subtitleParts[1])
            let marked = Text("\(lock) \(personal)")
            let count = Text(verbatim: "\n" + subtitleParts[0])
            shown = Text("\(marked)\(count)")
        } else {
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
            shown = Text(line)
        }
        return shown.accessibilityLabel(Text(verbatim: spokenStatus))
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

    /// What VoiceOver calls the open suggestion's main button: its words with the album they
    /// act on ("Album „Kyoto, Oktober 2024“ anlegen", "„Toskana“ um 1.354 Fotos ergänzen"), so
    /// the bar says it wherever VoiceOver reads it, also before the page's header (review B of
    /// design wave 1, 6). Nil for "Namen eingeben": its words name the field it acts on.
    var spokenMainAction: Text? {
        switch outcome {
        case .needsName:
            return nil
        case .chooseAlbum:
            return Text("Album für „\(title)“ auswählen")
        case .newAlbum(let name, _):
            return Text("Album „\(name)“ anlegen")
        case .addsTo(_, let name, let missing):
            return Text("„\(name)“ um \(missing) \(missing.formatted()) Fotos ergänzen")
        case .alreadyIn(_, let name):
            return Text("Album „\(name)“ so lassen")
        case .renames(_, let from, _):
            return Text("Album „\(from)“ umbenennen")
        case .moves(_, let name, _):
            return Text("Album „\(name)“ verschieben")
        }
    }

    /// "Nicht jetzt" with what it sets aside, for VoiceOver ("Nicht jetzt: „Kyoto, Oktober
    /// 2024“"), as the main button names its album.
    var spokenNotNow: Text { Text("Nicht jetzt: „\(title)“") }
}

extension AlbumProposal {
    /// The symbol on the calm placeholder of a cover without a sharp photo (only screenshots or
    /// documents, or photos only in iCloud): the area's own symbol, so the card looks meant
    /// that way, not empty (`CoverPhoto.placeholderSymbol`).
    var placeholderSymbol: String { kind.area.symbol }
}
