import SwiftUI
import AlbumistCore

/// The long press on a suggestion's card (design wave 2, DS-06a; draft E4 "lang drücken": "Auf
/// einer Vorschlags-Karte zeigt es dieselben Punkte wie „…“ im Vorschlag"): the items
/// `SuggestionMenu` decides, each going the way that exists for it, never around it.
///
/// - The card's word ("Anlegen", "Ergänzen …", "Benennen …", "Ansehen …") runs the card's own
///   action (`act`): "Anlegen" at once with its banner only where the button does it
///   (`quickCreateAtOnce`), the purchase sheet or the suggestion otherwise, "Ergänzen …" the
///   preview first.
/// - "Anpassen", "Reise teilen oder zusammenlegen" and "Keine Reise, hier bin ich öfter" open
///   what the open suggestion's "…" opens, on the page (`suggestionMenuFlows(_:)`): its sheets,
///   and the question before "Keine Reise", which waits and says why as it does there.
/// - "Nicht jetzt" sets the suggestion aside as its button does; photos and albums stay.
///
/// The menu stays open as long as the user leaves it, while the analysis may change the
/// suggestion or make it anew: every item acts on the suggestion as it is at the tap
/// (`AppModel.currentSuggestion`; the word through the page's action, which looks it up first),
/// and on one that went meanwhile not at all, which is said (review C of design wave 2, H1).
///
/// Reads the model only when the menu is drawn, so a card is as cheap to build as before. The
/// card hands in the model and the page's ways: what a menu shows is read from nothing of the
/// environment's (the system draws the menu, and VoiceOver reads its items, apart from the card).
/// The card's body has the items as actions for VoiceOver, Voice Control and Switch Control
/// (`forVoiceOver`, `PhotoCard.menuAccessibilityActions`): all that can be done now but the
/// card's word, which is the card's own button there (review C of design wave 2, L1, L3).
struct SuggestionMenuItems: View {
    var model: AppModel
    /// The page's sheets and question (`suggestionMenuFlows(_:)`); nil on a page without them.
    var openFlow: SuggestionMenuFlowAction?
    var proposal: AlbumProposal
    var card: ProposalCardText
    /// "✓ Angelegt": made from this card a moment ago.
    var made: Bool
    /// Its album is being made, or its preview prepared.
    var working: Bool
    /// Another card's album is being made, or its preview prepared.
    var waits: Bool
    /// The list selects suggestions.
    var selecting = false
    /// The actions of the card's body, not its menu: no groups, no word, nothing that waits.
    var forVoiceOver = false
    /// What the card's button does.
    var act: () -> Void

    var body: some View {
        let menu = model.suggestionMenu(for: proposal, action: card.action, made: made, working: working,
                                        waits: waits, selecting: selecting)
        if forVoiceOver {
            ForEach(menu.accessibilityItems, id: \.id) { action in
                item(SuggestionMenu.Entry(action))
            }
        } else {
            ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                ForEach(section) { entry in
                    item(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func item(_ entry: SuggestionMenu.Entry) -> some View {
        switch entry.item {
        case .action:
            actionItem
                .disabled(!entry.isEnabled)
        case .adjust:
            adjustItem
        case .reshapeTrip:
            reshapeItem
        case .notATrip:
            notATripItem
                .disabled(!entry.isEnabled)
        case .notNow:
            notNowItem
        }
    }

    /// The card's word, as its button shows it.
    private var actionItem: some View {
        Button(action: act) {
            Label(card.action.title, systemImage: card.action.menuSymbol)
        }
        .accessibilityIdentifier("suggestionMenu.action")
    }

    private var adjustItem: some View {
        Button {
            open(.adjust)
        } label: {
            Label("Anpassen", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("suggestionMenu.adjust")
    }

    private var reshapeItem: some View {
        Button {
            open(.reshapeTrip)
        } label: {
            Label("Reise teilen oder zusammenlegen", systemImage: "scissors")
        }
        .accessibilityIdentifier("suggestionMenu.reshapeTrip")
    }

    /// Asked first ("Keine Reise?"), as in the open suggestion. While it waits, why, in the
    /// suggestion's words: a second Text in the label is the item's second line.
    private var notATripItem: some View {
        Button {
            open(.notATrip)
        } label: {
            Label("Keine Reise, hier bin ich öfter", systemImage: "mappin.and.ellipse")
            if let reason = ProposalDetailView.oftenHereWaitReason(model, askedOnTheCard: false) {
                Text(reason)
            }
        }
        .accessibilityIdentifier("suggestionMenu.notATrip")
    }

    /// Takes only the suggestion away, as its "Nicht jetzt" does (no question: it can be made
    /// from "Nicht jetzt" any time).
    private var notNowItem: some View {
        Button {
            setAside()
        } label: {
            Label("Nicht jetzt", systemImage: "xmark.circle")
        }
        .accessibilityIdentifier("suggestionMenu.notNow")
    }

    /// What the open suggestion's "…" opens, on the page, for the suggestion as it is now.
    private func open(_ kind: SuggestionMenuFlow.Kind) {
        guard let current = model.currentSuggestion(proposal) else { return }
        openFlow?.open(SuggestionMenuFlow(kind: kind, proposal: current))
    }

    /// "Nicht jetzt" as its button does it, then said to VoiceOver: the card leaves the start
    /// page, or moves to "Nicht jetzt" in the list, and the focus with it (review C of design
    /// wave 2, L2). With high priority, so VoiceOver moving its focus to what comes next does not
    /// cut it off (review C2 of design wave 2, N5). In the words VoiceOver names the suggestion's
    /// own "Nicht jetzt" with (`ProposalCardText.spokenNotNow`, the same catalog key): a `Text`
    /// cannot be posted, so the words are written twice, and a test holds them together.
    private func setAside() {
        guard let current = model.currentSuggestion(proposal) else { return }
        model.setDecision(.reject, for: current)
        var spoken = AttributedString(String(localized: "Nicht jetzt: „\(card.title)“"))
        spoken.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(spoken).post()
    }
}

extension ProposalCardAction {
    /// The symbol of the card's word in its long press's menu.
    var menuSymbol: String {
        switch self {
        case .create: "rectangle.stack.badge.plus"
        case .add: "photo.badge.plus"
        case .name: "pencil"
        case .look: "eye"
        }
    }
}
