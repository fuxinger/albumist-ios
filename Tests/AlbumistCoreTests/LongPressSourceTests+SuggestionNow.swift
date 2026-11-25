import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// A suggestion's long press acts on the suggestion as it is now (`LongPressSourceTests`).
extension LongPressSourceTests {
    // MARK: The suggestion as it is now (review C of design wave 2, H1, L1, L2)

    /// A menu can stay open while the analysis goes on: every item acts on the suggestion as the
    /// analysis has it at the tap, found by its id (`currentSuggestion`, `SuggestionMenu.current`),
    /// never on the copy the card was drawn with. One that went meanwhile is said ("Der Vorschlag
    /// hat sich geändert"), and nothing is made, opened, answered or set aside for it.
    @Test func everyItemActsOnTheSuggestionAsItIsNow() throws {
        let now = Self.squeezed(try Self.body(["func currentSuggestion(_ proposal: AlbumProposal) -> AlbumProposal?"], in: Self.model))
        #expect(now.contains("SuggestionMenu.current(proposal,in:proposals)"), "\(now)")
        #expect(now.contains("message=.suggestionChanged"), "\(now)")
        let said = Self.squeezed(try Self.body(["static var suggestionChanged: AppMessage"], in: Self.model))
        #expect(said.contains("title:String(localized:\"DerVorschlaghatsichgeändert\")"), "\(said)")
        // "Anlegen", wherever it is tapped (a card, its menu, the suggestion, after the purchase
        // sheet): the first thing `createNow` does, in the lines marked for this strand.
        let create = try Self.body(["func createNow("], in: Self.quickCreate)
        let resolved = try #require(create.range(of: "guard let proposal = currentSuggestion(proposal) else { return .notNow }"))
        let turn = try #require(create.range(of: "let state = QuickCreateState.shared"))
        #expect(resolved.lowerBound < turn.lowerBound, "resolved after the turn is taken")
        #expect(try AppSource.read(Self.quickCreate).contains("// Design W2 H7: current suggestion."))
        // The card's action, from its button or its menu's word: the page's way, first of all.
        // The suggestion found takes the parameter's name, so nothing after it can reach the
        // drawn copy (as in `createNow`).
        let start = Self.squeezed(try Self.body(["struct StartSections", "private func perform("], in: Self.start))
        #expect(start.hasPrefix("{guardletproposal=model.currentSuggestion(proposal)else{return}"), "\(start)")
        let list = Self.squeezed(try Self.body(["struct ProposalListView", "private func act("], in: Self.suggestions))
        #expect(list.hasPrefix("{guardletproposal=model.currentSuggestion(proposal)else{return}"), "\(list)")
        // The menu's other items, and the answer to "Keine Reise?" (the question can stay open
        // too): the suggestion found (`current`), never the drawn copy after it. A check of the
        // first line alone passed with a later `for: proposal` (review C2 of design wave 2, N6);
        // this one fails on it.
        let lookedUp = [
            ("open", try Self.body(["struct SuggestionMenuItems", "private func open("], in: Self.suggestionItems)),
            ("setAside", try Self.body(["struct SuggestionMenuItems", "private func setAside("], in: Self.suggestionItems)),
            ("answer", try Self.body(["private func answer("], in: Self.flows)),
        ]
        for (name, body) in lookedUp {
            #expect(Self.actsOnTheLookedUp(body), "\(name): \(body)")
            let stale = body.replacingOccurrences(of: "current)", with: "proposal)")
            #expect(stale != body && !Self.actsOnTheLookedUp(stale), "\(name): the check misses the drawn copy acted on")
        }
        // Nothing in the menu or its ways acts on the drawn copy any more.
        let items = try Self.code(Self.suggestionItems)
        #expect(!items.contains("for: proposal)") && !items.contains("proposal: proposal)"), "the drawn copy acted on")
    }

    /// The list's "Anlegen" waits while another album is made, as its button does, before the
    /// card says "✓ Angelegt": the menu's word and VoiceOver reach it too (L1).
    @Test func theListsAnlegenWaitsForTheOneBeingMade() throws {
        let act = try Self.body(["struct ProposalListView", "private func act("], in: Self.suggestions)
        let create = try #require(act.range(of: "case .create:"))
        let waits = try #require(act.range(of: "guard model.quickCreating == nil else { return }"))
        let made = try #require(act.range(of: "made[proposal.id] = proposal"))
        #expect(create.lowerBound < waits.lowerBound && waits.lowerBound < made.lowerBound)
    }

    /// "Nicht jetzt" from a card's menu is said to VoiceOver as its button is named ("Nicht jetzt:
    /// „Kyoto, Oktober 2024“"): the card leaves the start page (in the list it moves), and the
    /// focus with it (L2). With high priority, so the focus moving on does not cut it off (review
    /// C2 of design wave 2, N5).
    @Test func nichtJetztIsSaidToVoiceOver() throws {
        let notNow = try Self.body(["struct SuggestionMenuItems", "private func setAside("], in: Self.suggestionItems)
        let steps = Self.squeezed(notNow)
        let set = try #require(steps.range(of: "model.setDecision(.reject,for:current)"), "\(steps)")
        let words = try #require(steps.range(of: "varspoken=AttributedString(String(localized:\"Nichtjetzt:„\\(card.title)“\"))"), "\(steps)")
        let high = try #require(steps.range(of: "spoken.accessibilitySpeechAnnouncementPriority=.high"), "\(steps)")
        let said = try #require(steps.range(of: "AccessibilityNotification.Announcement(spoken).post()"), "\(steps)")
        #expect(set.lowerBound < words.lowerBound && words.lowerBound < high.lowerBound && high.lowerBound < said.lowerBound)
        // One catalog key for the words said and the name of the suggestion's own "Nicht jetzt"
        // (`spokenNotNow`): a `Text` cannot be posted, so the words are written twice, and held
        // together here.
        let posted = try #require(Self.key(after: "String(localized: ", in: notNow), "\(notNow)")
        let labels = try Self.code("App/Albumist/Views/Proposal/ProposalCardLabels.swift")
        let name = try #require(AppSource.body(of: "var spokenNotNow: Text", in: labels))
        let named = try #require(Self.key(after: "Text(", in: name), "\(name)")
        #expect(posted == named, "said „\(posted)“, the button named „\(named)“")
        #expect(posted == "Nicht jetzt: „%@“")
    }

    /// The catalog key of the first string literal after `call` in `code`: its words, each
    /// interpolation `\(…)` as "%@" (the names said here are strings).
    static func key(after call: String, in code: String) -> String? {
        guard let start = code.range(of: call + "\"") else { return nil }
        var key = ""
        var rest = code[start.upperBound...]
        while let character = rest.first {
            if character == "\"" { return key }
            if rest.hasPrefix("\\(") {
                var depth = 0
                var index = rest.index(after: rest.startIndex)
                repeat {
                    if rest[index] == "(" { depth += 1 }
                    if rest[index] == ")" { depth -= 1 }
                    index = rest.index(after: index)
                } while depth > 0 && index < rest.endIndex
                key += "%@"
                rest = rest[index...]
            } else if rest.hasPrefix("\\\"") {
                key += "\""
                rest = rest.dropFirst(2)
            } else {
                key.append(character)
                rest = rest.dropFirst()
            }
        }
        return nil
    }

    /// What the menu offers is read where the open suggestion reads it: "Keine Reise" from one
    /// rule, its wait from `canChangeHome` as the suggestion's item waits, "Nicht jetzt" not for
    /// what is set aside (the list's own "Nicht jetzt" group).
    @Test func theCardsMenuReadsWhatTheSuggestionReads() throws {
        // Read only where the menu shows what they decide (`SuggestionMenu`'s lazy init, review C
        // of design wave 2, M5): nothing for a card without a menu, the state of the analysis and
        // the plans only where "Keine Reise" is offered.
        let model = Self.squeezed(try Self.body(["func suggestionMenu(for proposal: AlbumProposal"], in: Self.model))
        #expect(model.contains("setAside:{isSetAside(proposal)}"), "\(model)")
        #expect(model.contains("canReshape:{canReshape(proposal)}"))
        #expect(model.contains("offersNotATrip:{offersNotATrip(proposal)}"))
        #expect(model.contains("canAnswerNotATrip:{canChangeHome}"))
        #expect(!(try Self.code(Self.model)).contains("SuggestionMenu.Card("), "every fact read for every card")
        let offers = try Self.body(["struct ProposalDetailView", "private var offersOftenHere"], in: Self.suggestions)
        #expect(offers.contains("model.offersNotATrip(proposal)"), "the suggestion's „…“ and the card ask the same")
        let aside = Self.squeezed(try Self.body(["func isSetAside("], in: Self.model))
        #expect(aside.contains("decisions[proposal.id]==.reject||quickCreateKeepsNotNow(proposal.id)"))
        // The list's "Nicht jetzt" group by the same rule (`QuickCreateSafeguardTests` reads it there).
        let sections = Self.squeezed(try Self.body(["struct ProposalListView", "private func sections("], in: Self.suggestions))
        #expect(sections.contains("model.decisions[proposal.id]==.reject||model.quickCreateKeepsNotNow(proposal.id)"), "\(sections)")
    }

    /// A long press lifts the card itself, in its own shape (review C of design wave 2, M2, L5):
    /// the photo the card shows, never another of its cover candidates or the calm placeholder
    /// where the card shows a photo, no second cover counted, "Vorschau ausgeblendet" where the
    /// card says it, and at the largest text sizes the card as it is, which the system fits
    /// beside the menu.
    @Test func aCardLiftsItselfInItsOwnShape() throws {
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            #expect(!(try Self.code(path)).contains("SuggestionPreview"), "\(path): a second card lifted")
        }
        let card = try Self.body(["struct PhotoCard<", "private var card: some View"], in: Self.photoCard)
        #expect(card.contains(".contentShape(.contextMenuPreview, shape)"))
        #expect(try Self.code(Self.photoCard).contains("extension PhotoCard where MenuPreview == EmptyView {"))
    }

    /// A card's long press is switched off the documented way: its menu closure returns nothing
    /// (`menuOffered`), so a made or working card, or a card of a list that selects, lifts
    /// nothing and has no actions (review C of design wave 2, M4). Its body's actions can leave
    /// out what the card shows as a button (`menuAccessibilityActions`, L3).
    @Test func aCardsMenuIsSwitchedOffByAnEmptyClosure() throws {
        let card = try Self.body(["struct PhotoCard<"], in: Self.photoCard)
        #expect(card.contains("private var isMenuOffered = true"))
        #expect(card.contains("private var accessibilityMenuItems: MenuItems?"))
        let body = Self.squeezed(try Self.body(["struct PhotoCard<", "var body: some View"], in: Self.photoCard))
        // Both kinds of card, each branch checked on its own (review C2 of design wave 2, N6: the
        // check for the card that lifts itself was a prefix of the other and passed without it).
        let offered = "shaped.contextMenu{ifisMenuOffered{menuItems}}"
        #expect(body.components(separatedBy: offered).count - 1 == 2, "\(body)")
        #expect(body.contains("elseifhasMenuPreview{\(offered)preview:{menuPreview}}"), "with a preview of its own: \(body)")
        #expect(body.hasSuffix("}else{\(offered)}}"), "the card that lifts itself: \(body)")
        // Only cards that lift themselves are switched off (the suggestion cards): beside a
        // preview of its own, a menu that returns nothing is not documented to lift nothing (N1).
        var switched: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") where path != Self.photoCard {
            if !AppSource.calls(of: "menuOffered(", in: try AppSource.read(path)).isEmpty { switched.append(path) }
        }
        #expect(switched == [Self.suggestions, Self.startCard], "\(switched)")
        let actions = Self.squeezed(try Self.body(["struct PhotoCard<", "private func describedAsBody("], in: Self.photoCard))
        #expect(actions.contains("described.accessibilityActions{ifisMenuOffered{accessibilityMenuItems??menuItems}}"), "\(actions)")
        let code = try Self.code(Self.photoCard)
        #expect(code.contains("func menuOffered(_ offered: Bool) -> Self {"))
        #expect(code.contains("func menuAccessibilityActions(_ items: MenuItems) -> Self {"))
        // For VoiceOver the items say what can be done beside the card's button, nothing that waits.
        let items = try Self.body(["struct SuggestionMenuItems", "var body: some View"], in: Self.suggestionItems)
        #expect(items.contains("if forVoiceOver {") && items.contains("menu.accessibilityItems"), "\(items)")
    }
}
