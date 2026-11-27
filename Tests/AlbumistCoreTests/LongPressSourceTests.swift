import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How the app wires the long press (design wave 2, DS-06a; draft E4 "lang drücken"): read from
/// its sources, as the app does not build on Linux. What the menus offer is decided in the core
/// (`SuggestionMenuTests`, `PhotoMenuTests`); here: every card and grid has it, each item goes
/// the way that exists for it (never a new way around a confirmation), the lifted card hides
/// what its card hides, nothing while selecting, VoiceOver gets the items as actions, and the
/// new words are in the catalog with English.
@Suite("Long press in the app (source)")
struct LongPressSourceTests {
    static let start = "App/Albumist/Views/Start/StartSections.swift"
    static let startCard = "App/Albumist/Views/Start/StartProposalCard.swift"
    /// The start page's other cards ("Dein Startpaket", the quiet card, "Alle Vorschläge"),
    /// once in `StartSections.swift`.
    static let startCards = "App/Albumist/Views/Start/StartPageCards.swift"
    static let suggestions = "App/Albumist/Views/ProposalViews.swift"
    static let library = "App/Albumist/Views/LibraryView.swift"
    /// The grid of "Unsortiert" and of a suggestion's photos (design wave 3, DS-06b).
    static let photoGrid = "App/Albumist/Views/PhotoGrid/PhotoGrid.swift"
    static let search = "App/Albumist/Views/SearchView.swift"
    static let albums = "App/Albumist/Views/AlbumsView.swift"
    static let suggestionItems = "App/Albumist/Views/Menus/SuggestionMenuItems.swift"
    static let flows = "App/Albumist/Views/Menus/SuggestionMenuFlows.swift"
    static let photoMenu = "App/Albumist/Views/Menus/PhotoMenuItems.swift"
    static let model = "App/Albumist/Model/AppModel+LongPress.swift"
    static let quickCreate = "App/Albumist/Model/AppModel+QuickCreate.swift"
    static let overview = "App/Albumist/Views/OverviewView.swift"
    static let photoQuestion = "App/Albumist/Views/Menus/PhotoRemovalQuestion.swift"
    static let photoCard = "App/Albumist/DesignSystem/PhotoCard.swift"
    static let thumbnails = "App/Albumist/Views/AssetThumbnail.swift"

    /// The code of `path` (comments blanked, strings kept).
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    /// The body of a declaration path in the code of `path`.
    static func body(_ declarations: [String], in path: String) throws -> String {
        try #require(AppSource.body(of: declarations, in: try code(path)), "\(declarations) is not in \(path)")
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// How often `pattern` (ICU, as `NSRegularExpression` reads it) matches in `text`.
    static func count(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    /// Whether a function's body (comments blanked) acts only on the suggestion it looked up:
    /// its first statement is `guard let current = model.currentSuggestion(proposal) else {
    /// return }`, and after it `current` is used and the drawn `proposal` is never named again
    /// (`proposal:` as an argument's label is no use of it).
    static func actsOnTheLookedUp(_ body: String) -> Bool {
        let lookUp = #"\A\{\s*guard\s+let\s+current\s*=\s*model\.currentSuggestion\(\s*proposal\s*\)\s*else\s*\{\s*return\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: lookUp),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let end = Range(match.range, in: body)?.upperBound else { return false }
        let after = String(body[end...])
        return count(#"(?<![\w.])proposal\b(?!\s*:)"#, in: after) == 0 && count(#"(?<![\w.])current\b"#, in: after) > 0
    }

    /// The labels of a call's arguments, read at the call's own level ("id: id, side: 80" →
    /// ["id", "side"]; "_" for an argument without one).
    static func labels(_ arguments: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var depth = 0
        for character in arguments {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        parts.append(part)
        return parts.map { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { return "_" }
            let label = trimmed[..<colon]
            return !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? String(label) : "_"
        }
    }

    // MARK: Suggestion cards

    /// The start page's cards: `PhotoCard`'s own long press (`menu:`), which lifts the card
    /// itself (review C of design wave 2, M2), no second mechanism, each part a typed property of
    /// its own (Xcode gave up on long expressions with several trailing closures, CI 44847306162).
    @Test func startCardsHaveTheMenuAndTheLiftedCard() throws {
        let card = try Self.body(["struct StartProposalCard"], in: Self.startCard)
        let body = Self.squeezed(try Self.body(["struct StartProposalCard", "var body: some View"], in: Self.startCard))
        #expect(body == "{photoCard.accessibilityIdentifier(identifier)}", "the body is short: \(body)")
        let shown = Self.squeezed(try Self.body(["struct StartProposalCard", "private var photoCard: some View"], in: Self.startCard))
        #expect(shown.contains("}menu:{menuItems}.menuOffered("), "\(shown)")
        #expect(!shown.contains("preview:"), "a second card lifted: \(shown)")
        #expect(shown.contains("aspectRatio:aspectRatio,") && !shown.contains("?"), "no condition in the card's call: \(shown)")
        #expect(card.contains("private var aspectRatio: CGFloat"))
        #expect(card.contains("private var identifier: String"))
        #expect(card.contains("private var menuItems: SuggestionMenuItems"))
        // No menu at all once it is made or while it works (an empty menu closure, M4), and for
        // VoiceOver the items without the card's word (its own button, L3).
        #expect(shown.contains(".menuOffered(SuggestionMenu.isOffered(made:made,working:working,selecting:false))"), "\(shown)")
        #expect(shown.contains(".menuAccessibilityActions(voiceOverItems)"), "\(shown)")
        let spoken = Self.squeezed(try Self.body(["struct StartProposalCard", "private var voiceOverItems: SuggestionMenuItems"], in: Self.startCard))
        #expect(spoken.contains("forVoiceOver:true") && spoken.contains("act:onAction"), "\(spoken)")
        let items = Self.squeezed(try Self.body(["struct StartProposalCard", "private var menuItems"], in: Self.startCard))
        // The word does what the card's button does (`perform`, `quickCreateAtOnce`, the
        // purchase sheet), in the card's state.
        #expect(items.contains("act:onAction"), "\(items)")
        #expect(items.contains("model:model,openFlow:openFlow"), "handed in by the card: \(items)")
        #expect(items.contains("made:made") && items.contains("working:working") && items.contains("waits:waits"))
        // The page gives its cards no covers while their photos are hidden.
        let page = Self.squeezed(try Self.body(["private func card("], in: Self.start))
        #expect(page.contains("covers:text.hidesPreview?[]:model.proposalCoverIDs(for:proposal)"), "\(page)")
        // The page shows what the menu opens ("Anpassen", the trip workshop, "Keine Reise?"): on
        // its scroll view, so the question comes from the screen, not from the middle of all the
        // cards (review C of design wave 2, M1).
        for path in [Self.start, Self.startCard, Self.startCards] {
            #expect(!(try Self.code(path)).contains(".suggestionMenuFlows("), "on the cards' tall stack: \(path)")
        }
        let overview = Self.squeezed(try Self.body(["struct OverviewView", "var body: some View"], in: Self.overview))
        // Right after the scroll trail of the small moment, which sits on the scroll view itself so
        // that no scroll inside these sheets can reach it (`MomentsSourceTests`).
        #expect(overview.contains("}.quickCreateMomentScrollTrail().suggestionMenuFlows(menuFlows).background(Theme.background)"
                                  + ".navigationTitle(\"Vorschläge\")"),
                "\(overview)")
        #expect(overview.components(separatedBy: ".suggestionMenuFlows(").count == 2, "once, on the scroll view")
    }

    /// The page hands its cards one object for what their menus open: the same one each time the
    /// page is drawn, so handing it down redraws no card (a closure made anew would, at every
    /// change of the analysis, now that the start page's scroll view has it). The page keeps it
    /// in its own state, made when the page is made: as the state of the modifier, its first
    /// value was made anew at every drawing of the page and thrown away (review C2 of design
    /// wave 2, N2).
    @Test func thePageHandsItsCardsOneLastingWayToOpen() throws {
        let flows = try Self.code(Self.flows)
        #expect(flows.contains("@MainActor @Observable\nfinal class SuggestionMenuFlowAction {"))
        #expect(!flows.contains("SuggestionMenuFlowAction()"), "made by the modifier at each drawing of the page")
        #expect(flows.contains("func suggestionMenuFlows(_ flows: SuggestionMenuFlowAction) -> some View {"))
        let modifier = try Self.body(["private struct SuggestionMenuFlows: ViewModifier"], in: Self.flows)
        #expect(modifier.contains("    var flows: SuggestionMenuFlowAction\n") && !modifier.contains("@State"), "\(modifier)")
        #expect(flows.contains(".environment(\\.openSuggestionMenuFlow, flows)"))
        #expect(!flows.contains("SuggestionMenuFlowAction(open:"), "a closure made anew at each drawing")
        #expect(flows.contains(".sheet(item: $flows.adjusting)") && flows.contains(".sheet(item: $flows.reshaping)"))
        #expect(flows.contains("presenting: flows.askingNotATrip"))
        // Each page keeps its own and hands it to its sheets and question.
        for (path, page) in [(Self.overview, "struct OverviewView"), (Self.suggestions, "struct ProposalListView")] {
            let type = try Self.body([page], in: path)
            #expect(type.contains("@State private var menuFlows = SuggestionMenuFlowAction()"), "\(path)")
            #expect(type.components(separatedBy: ".suggestionMenuFlows(menuFlows)").count == 2, "\(path): handed once")
        }
    }

    /// The list's cards: the same, in their state (made, the list selecting).
    @Test func listCardsHaveTheMenuAndTheLiftedCard() throws {
        let card = try Self.body(["private struct ProposalListCard"], in: Self.suggestions)
        let shown = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var photoCard"], in: Self.suggestions))
        #expect(shown.contains("}menu:{menuItems}.selected("), "\(shown)")
        #expect(!shown.contains("preview:"), "a second card lifted: \(shown)")
        #expect(card.contains("private var menuItems: SuggestionMenuItems"))
        let items = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var menuItems"], in: Self.suggestions))
        #expect(items.contains("act:{act(card.action)}"), "the card's own action: \(items)")
        #expect(items.contains("model:model,openFlow:openFlow"), "handed in by the card: \(items)")
        #expect(items.contains("made:made") && items.contains("selecting:selecting"), "\(items)")
        #expect(items.contains("working:model.quickCreating==proposal.id"), "\(items)")
        #expect(shown.contains(".menuOffered(SuggestionMenu.isOffered(made:made,working:model.quickCreating==proposal.id,selecting:selecting))"), "\(shown)")
        #expect(shown.contains(".menuAccessibilityActions(voiceOverItems)"), "\(shown)")
        let spoken = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var voiceOverItems: SuggestionMenuItems"], in: Self.suggestions))
        #expect(spoken.contains("forVoiceOver:true") && spoken.contains("act:{act(card.action)}"), "\(spoken)")
        let list = try Self.body(["struct ProposalListView", "var body: some View"], in: Self.suggestions)
        #expect(list.contains(".suggestionMenuFlows(menuFlows)"))
    }

    /// Each item goes the way that exists: the word through the card's action, "Anpassen" and
    /// the trip's items to what the open suggestion's "…" opens, "Nicht jetzt" as its button
    /// does. Nothing makes an album here, and "Keine Reise" is asked first.
    @Test func theCardsMenuGoesTheWaysThatExist() throws {
        let items = try Self.code(Self.suggestionItems)
        #expect(items.contains("model.suggestionMenu(for: proposal"))
        // The system draws the menu, and VoiceOver reads its items, apart from the card: they
        // read nothing from the environment (an `AppModel` missing there would stop the app).
        #expect(!items.contains("@Environment("))
        #expect(items.contains("Button(action: act)"), "the word runs the card's own action")
        #expect(items.contains("Label(card.action.title"), "the word as the card shows it")
        #expect(items.contains("open(.adjust)") && items.contains("open(.reshapeTrip)") && items.contains("open(.notATrip)"))
        #expect(items.contains("openFlow?.open(SuggestionMenuFlow(kind: kind, proposal: current))"))
        #expect(items.contains("model.setDecision(.reject, for: current)"))
        let notNow = try Self.body(["struct ProposalDetailView", "private func notNowButton("], in: Self.suggestions)
        #expect(notNow.contains("model.setDecision(.reject, for: proposal)"), "the suggestion's own „Nicht jetzt“")
        for bypass in ["createNow(", "execute(", "answerRecurringPlace(", "removeFromProposal(", "selectForPreview("] {
            #expect(!items.contains(bypass), "\(bypass) in the card's menu")
        }
        // Why "Keine Reise" waits: the open suggestion's words, from one place.
        #expect(items.contains("ProposalDetailView.oftenHereWaitReason(model, askedOnTheCard: false)"))
        let detail = try Self.body(["struct ProposalDetailView"], in: Self.suggestions)
        #expect(detail.contains("static func oftenHereWaitReason(_ model: AppModel, askedOnTheCard: Bool)"))
        #expect(!detail.contains("private func oftenHereWaitReason("), "a second copy of the reasons")

        let flows = try Self.code(Self.flows)
        #expect(flows.contains("AdjustProposalView(proposal: proposal)"))
        #expect(flows.contains("TripWorkshopView(proposal: proposal)"))
        #expect(flows.contains(".confirmationDialog(\"Keine Reise?\""))
        #expect(flows.contains("Button(\"Keine Reise, hier bin ich öfter\")"))
        #expect(flows.contains("model.answerRecurringPlace(true, for: current)"))
        // The question's words are the open suggestion's.
        let message = "Aufenthalte an diesem Ort werden keine Reisen mehr, auch bei jeder neuen Analyse."
        #expect(flows.contains(message) && detail.contains(message))
    }

    // MARK: Words

    /// The new words are in the catalog with English, in Apple's title case for the menu items.
    @Test func theNewWordsHaveEnglish() throws {
        let data = try AppSource.read("App/Albumist/Resources/Localizable.xcstrings").data(using: .utf8) ?? Data()
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        func english(_ key: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let en = (entry?["localizations"] as? [String: Any])?["en"] as? [String: Any]
            return (en?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        let expected = [
            "Zu Album hinzufügen …": "Add to Album…",
            "Aus Vorschlag entfernen": "Remove from Suggestion",
            "Foto aus diesem Vorschlag entfernen?": "Remove Photo from This Suggestion?",
            "Es kommt nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleibt es.":
                "It won’t go into this album. It stays in your library and in other suggestions.",
            "Albumist hat die Vorschläge eben aktualisiert. Angelegt oder geändert wurde nichts; den neuen Stand siehst du auf der Seite „Vorschläge“.":
                "Albumist just updated its suggestions. Nothing was created or changed; you’ll see the latest on the Suggestions page.",
            "Der Vorschlag hat sich geändert": "The Suggestion Has Changed",
            "Nicht jetzt: „%@“": "Not Now: “%@”",
        ]
        for (german, en) in expected {
            #expect(english(german) == en, "\(german): \(english(german) ?? "missing")")
        }
        // The menus use the app's words for everything else (no second word for the same).
        let items = try Self.code(Self.suggestionItems)
        for word in ["\"Anpassen\"", "\"Reise aufteilen oder zusammenlegen\"", "\"Keine Reise, hier bin ich öfter\"", "\"Nicht jetzt\""] {
            #expect(items.contains(word), "\(word)")
            #expect(english(String(word.dropFirst().dropLast())) != nil, "\(word)")
        }
        let photo = try Self.code(Self.photoMenu)
        for word in ["\"Ansehen\"", "\"Ignorieren\"", "\"Nicht mehr ignorieren\"", "\"Aus Vorschlag entfernen\""] {
            #expect(photo.contains(word), "\(word)")
        }
    }
}
