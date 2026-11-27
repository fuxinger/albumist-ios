import SwiftUI
import AlbumistCore
import AlbumistEngine

/// One suggestion as a photo card (design rule 1: the name and the line below the photo, never
/// on it), with the one word that says what happens (`ProposalCardText`): "Anlegen",
/// "Ergänzen …", "Benennen …", "Ansehen …", and "✓ Angelegt" once made from here. Tapping the
/// card opens the suggestion. The word is a real button of its own (VoiceOver, Voice Control,
/// Switch Control, keyboard) that names the album („Kyoto, Oktober 2024“ anlegen) and answers
/// to its visible word in Voice Control; the card is the container the UI tests find by its
/// identifier.
struct StartProposalCard: View {
    var proposal: AlbumProposal
    var text: ProposalCardText
    var covers: [AssetID]
    var made: Bool
    var working: Bool
    /// Another card's album is being made: this one's word waits.
    var waits: Bool
    var style: PhotoCardStyle
    var onOpen: () -> Void
    var onAction: () -> Void
    /// For the long press's menu and the body's actions, which read the model in their own
    /// bodies, not in the card's (`SuggestionMenuItems`).
    @Environment(AppModel.self) private var model
    @Environment(\.openSuggestionMenuFlow) private var openFlow

    // Built from small parts, each with its own type: Xcode gave up on one expression with a
    // condition and several trailing closures in the list's card (CI 44847306162).
    var body: some View {
        photoCard
            .accessibilityIdentifier(identifier)
    }

    /// The card with its one button and the long press's menu, which lifts the card itself: the
    /// photo it shows, what it hides hidden, in its shape (review C of design wave 2, M2). No
    /// menu once it is made or while it works; for VoiceOver its items but the card's word, its
    /// own button.
    private var photoCard: some View {
        PhotoCard(coverIDs: covers, title: Text(verbatim: text.title), subtitle: text.styledSubtitle,
                  hidesPreview: text.hidesPreview, aspectRatio: aspectRatio, style: style,
                  placeholderSymbol: proposal.kind.area.symbol, onOpen: onOpen) {
            button
        } menu: {
            menuItems
        }
        .menuOffered(SuggestionMenu.isOffered(made: made, working: working, selecting: false))
        .menuAccessibilityActions(voiceOverItems)
    }

    /// Wide on a large card, 3:2 in a row.
    private var aspectRatio: CGFloat {
        style == .large ? 2 : 3.0 / 2.0
    }

    /// For UI tests: `suggestion.card.create` (`add`, `name`, `look`), `suggestion.card.made`.
    private var identifier: String {
        "suggestion.card.\(made ? "made" : text.action.kind)"
    }

    /// The long press (design wave 2, DS-06a; draft E4): the card's word first, doing what its
    /// button does, then what the open suggestion's "…" offers; nothing while it works or once
    /// it is made. Each part a typed property of its own, so Xcode type-checks the card at once.
    private var menuItems: SuggestionMenuItems {
        SuggestionMenuItems(model: model, openFlow: openFlow, proposal: proposal, card: text, made: made,
                            working: working, waits: waits, act: onAction)
    }

    /// The same items as actions of the card's body, but the word (review C of design wave 2, L3).
    private var voiceOverItems: SuggestionMenuItems {
        SuggestionMenuItems(model: model, openFlow: openFlow, proposal: proposal, card: text, made: made,
                            working: working, waits: waits, forVoiceOver: true, act: onAction)
    }

    @ViewBuilder
    private var button: some View {
        if made {
            // Made from this card in this visit (7B): it keeps its place; "Widerrufen" is on
            // the banner. A button that cannot be tapped, so VoiceOver says what happened
            // („Kyoto, Oktober 2024“ angelegt, dimmed) where the word was.
            Button {} label: { StartMadeLabel() }
                .buttonStyle(StartMadeButtonStyle())
                .disabled(true)
                .accessibilityLabel(text.spokenMade)
        } else {
            Button(action: onAction) {
                ZStack {
                    // The word keeps the button's width while the spinner shows.
                    actionWord.opacity(working ? 0 : 1)
                    if working {
                        ProgressView()
                            .accessibilityHidden(true) // the button's label says what runs
                    }
                }
            }
            .buttonStyle(CardActionButtonStyle())
            .disabled(working || waits)
            // The suggestion list's words („Toskana“ ergänzen names the album that gets the
            // photos), so a card says the same on both screens; while it works, what runs.
            .accessibilityLabel(working ? workingLabel : text.spokenAction)
            .accessibilityInputLabels(text.actionInputLabels)
        }
    }

    /// While the album is made ("Anlegen") or the preview prepared ("Ergänzen …"): the words
    /// the suggestion list says then (review A of design wave 1).
    private var workingLabel: Text {
        switch text.action {
        case .create: Text("Album wird angelegt")
        case .add, .name, .look: Text("Wird vorbereitet")
        }
    }

    /// The visible word ("Anlegen", "Ergänzen …"), the suggestion list's (`ProposalCardAction.title`).
    private var actionWord: Text { Text(text.action.title) }
}

/// "✓ Angelegt" where the card's button was (draft E6 "nach dem Anlegen"): drawn like the
/// tinted card button (`CardActionButtonStyle`: the same fill, size, room beside the word and
/// edge), so nothing moves when the word changes; in the accent, not greyed out like a button
/// that waits.
private struct StartMadeLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.cardActionFillsWidth) private var fillsWidth
    @Environment(\.cardActionInset) private var inset
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var radius: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Label("Angelegt", systemImage: "checkmark")
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, inset)
            .padding(.vertical, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .background(Theme.accent.opacity(colorScheme == .dark ? 0.18 : 0.11), in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
    }
}

/// The made card's button as its label draws it: no pressed or disabled look of its own.
private struct StartMadeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
