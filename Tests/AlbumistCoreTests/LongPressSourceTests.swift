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
    static let suggestions = "App/Albumist/Views/ProposalViews.swift"
    static let library = "App/Albumist/Views/LibraryView.swift"
    static let search = "App/Albumist/Views/SearchView.swift"
    static let albums = "App/Albumist/Views/AlbumsView.swift"
    static let suggestionItems = "App/Albumist/Views/Menus/SuggestionMenuItems.swift"
    static let suggestionPreview = "App/Albumist/Views/Menus/SuggestionPreview.swift"
    static let flows = "App/Albumist/Views/Menus/SuggestionMenuFlows.swift"
    static let photoMenu = "App/Albumist/Views/Menus/PhotoMenuItems.swift"
    static let model = "App/Albumist/Model/AppModel+LongPress.swift"
    static let quickCreate = "App/Albumist/Model/AppModel+QuickCreate.swift"
    static let overview = "App/Albumist/Views/OverviewView.swift"
    static let photoQuestion = "App/Albumist/Views/Menus/PhotoRemovalQuestion.swift"
    static let photoCard = "App/Albumist/DesignSystem/PhotoCard.swift"

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

    // MARK: Suggestion cards

    /// The start page's cards: `PhotoCard`'s own long press (`menu:`, `preview:`), no second
    /// mechanism, each part a typed property of its own (Xcode gave up on long expressions with
    /// several trailing closures, CI 44847306162).
    @Test func startCardsHaveTheMenuAndTheLiftedCard() throws {
        let card = try Self.body(["struct StartProposalCard"], in: Self.start)
        let body = Self.squeezed(try Self.body(["struct StartProposalCard", "var body: some View"], in: Self.start))
        #expect(body == "{photoCard.accessibilityIdentifier(identifier)}", "the body is short: \(body)")
        let shown = Self.squeezed(try Self.body(["struct StartProposalCard", "private var photoCard: some View"], in: Self.start))
        #expect(shown.contains("}menu:{menuItems}preview:{menuPreview}"), "\(shown)")
        #expect(shown.contains("aspectRatio:aspectRatio,") && !shown.contains("?"), "no condition in the card's call: \(shown)")
        #expect(card.contains("private var aspectRatio: CGFloat"))
        #expect(card.contains("private var identifier: String"))
        #expect(card.contains("private var menuItems: SuggestionMenuItems"))
        #expect(card.contains("private var menuPreview: SuggestionPreview"))
        // No menu at all once it is made or while it works (an empty menu closure, M4), and for
        // VoiceOver the items without the card's word (its own button, L3).
        #expect(shown.contains(".menuOffered(SuggestionMenu.isOffered(made:made,working:working,selecting:false))"), "\(shown)")
        #expect(shown.contains(".menuAccessibilityActions(voiceOverItems)"), "\(shown)")
        let spoken = Self.squeezed(try Self.body(["struct StartProposalCard", "private var voiceOverItems: SuggestionMenuItems"], in: Self.start))
        #expect(spoken.contains("forVoiceOver:true") && spoken.contains("act:onAction"), "\(spoken)")
        let items = Self.squeezed(try Self.body(["struct StartProposalCard", "private var menuItems"], in: Self.start))
        // The word does what the card's button does (`perform`, `quickCreateAtOnce`, the
        // purchase sheet), in the card's state.
        #expect(items.contains("act:onAction"), "\(items)")
        #expect(items.contains("model:model,openFlow:openFlow"), "handed in by the card: \(items)")
        #expect(items.contains("made:made") && items.contains("working:working") && items.contains("waits:waits"))
        let preview = Self.squeezed(try Self.body(["struct StartProposalCard", "private var menuPreview"], in: Self.start))
        #expect(preview.contains("covers:covers") && preview.contains("hidesPreview:text.hidesPreview"), "\(preview)")
        #expect(preview.contains("line:text.styledSubtitle"), "the card's own status line")
        // The page gives its cards no covers while their photos are hidden.
        let page = Self.squeezed(try Self.body(["private func card("], in: Self.start))
        #expect(page.contains("covers:text.hidesPreview?[]:model.proposalCoverIDs(for:proposal)"), "\(page)")
        // The page shows what the menu opens ("Anpassen", the trip workshop, "Keine Reise?"): on
        // its scroll view, so the question comes from the screen, not from the middle of all the
        // cards (review C of design wave 2, M1).
        #expect(!(try Self.code(Self.start)).contains(".suggestionMenuFlows()"), "on the cards' tall stack")
        let overview = Self.squeezed(try Self.body(["struct OverviewView", "var body: some View"], in: Self.overview))
        #expect(overview.contains("}.suggestionMenuFlows().background(Theme.background).navigationTitle(\"Vorschläge\")"), "\(overview)")
        #expect(overview.components(separatedBy: ".suggestionMenuFlows()").count == 2, "once, on the scroll view")
    }

    /// The page hands its cards one object for what their menus open, kept by the page: the same
    /// one each time the page is drawn, so handing it down redraws no card (a closure made anew
    /// would, at every change of the analysis, now that the start page's scroll view has it).
    @Test func thePageHandsItsCardsOneLastingWayToOpen() throws {
        let flows = try Self.code(Self.flows)
        #expect(flows.contains("@MainActor @Observable\nfinal class SuggestionMenuFlowAction {"))
        #expect(flows.contains("@State private var flows = SuggestionMenuFlowAction()"))
        #expect(flows.contains(".environment(\\.openSuggestionMenuFlow, flows)"))
        #expect(!flows.contains("SuggestionMenuFlowAction(open:"), "a closure made anew at each drawing")
        #expect(flows.contains(".sheet(item: $flows.adjusting)") && flows.contains(".sheet(item: $flows.reshaping)"))
        #expect(flows.contains("presenting: flows.askingNotATrip"))
    }

    /// The list's cards: the same, in their state (made, the list selecting).
    @Test func listCardsHaveTheMenuAndTheLiftedCard() throws {
        let card = try Self.body(["private struct ProposalListCard"], in: Self.suggestions)
        let shown = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var photoCard"], in: Self.suggestions))
        #expect(shown.contains("}menu:{menuItems}preview:{menuPreview}"), "\(shown)")
        #expect(card.contains("private var menuItems: SuggestionMenuItems"))
        #expect(card.contains("private var menuPreview: SuggestionPreview"))
        let items = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var menuItems"], in: Self.suggestions))
        #expect(items.contains("act:{act(card.action)}"), "the card's own action: \(items)")
        #expect(items.contains("model:model,openFlow:openFlow"), "handed in by the card: \(items)")
        #expect(items.contains("made:made") && items.contains("selecting:selecting"), "\(items)")
        #expect(items.contains("working:model.quickCreating==proposal.id"), "\(items)")
        #expect(shown.contains(".menuOffered(SuggestionMenu.isOffered(made:made,working:model.quickCreating==proposal.id,selecting:selecting))"), "\(shown)")
        #expect(shown.contains(".menuAccessibilityActions(voiceOverItems)"), "\(shown)")
        let spoken = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var voiceOverItems: SuggestionMenuItems"], in: Self.suggestions))
        #expect(spoken.contains("forVoiceOver:true") && spoken.contains("act:{act(card.action)}"), "\(spoken)")
        let preview = Self.squeezed(try Self.body(["private struct ProposalListCard", "private var menuPreview"], in: Self.suggestions))
        #expect(preview.contains("hidesPreview:card.hidesPreview") && preview.contains("line:card.styledSubtitle"), "\(preview)")
        let list = try Self.body(["struct ProposalListView", "var body: some View"], in: Self.suggestions)
        #expect(list.contains(".suggestionMenuFlows()"))
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
        let start = Self.squeezed(try Self.body(["struct StartSections", "private func perform("], in: Self.start))
        #expect(start.hasPrefix("{guardletproposal=model.currentSuggestion(proposal)else{return}"), "\(start)")
        let list = Self.squeezed(try Self.body(["struct ProposalListView", "private func act("], in: Self.suggestions))
        #expect(list.hasPrefix("{guardletproposal=model.currentSuggestion(proposal)else{return}"), "\(list)")
        // The menu's other items, and the answer to "Keine Reise?" (the question can stay open too).
        let open = Self.squeezed(try Self.body(["struct SuggestionMenuItems", "private func open("], in: Self.suggestionItems))
        #expect(open.hasPrefix("{guardletcurrent=model.currentSuggestion(proposal)else{return}"), "\(open)")
        let notNow = Self.squeezed(try Self.body(["struct SuggestionMenuItems", "private func setAside("], in: Self.suggestionItems))
        #expect(notNow.hasPrefix("{guardletcurrent=model.currentSuggestion(proposal)else{return}"), "\(notNow)")
        let answer = Self.squeezed(try Self.body(["private func answer("], in: Self.flows))
        #expect(answer.hasPrefix("{guardletcurrent=model.currentSuggestion(proposal)else{return}"), "\(answer)")
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
    /// focus with it (L2).
    @Test func nichtJetztIsSaidToVoiceOver() throws {
        let notNow = try Self.body(["struct SuggestionMenuItems", "private func setAside("], in: Self.suggestionItems)
        let set = try #require(notNow.range(of: "model.setDecision(.reject, for: current)"))
        let said = try #require(notNow.range(of: "AccessibilityNotification.Announcement(String(localized: \"Nicht jetzt: „\\(card.title)“\")).post()"))
        #expect(set.lowerBound < said.lowerBound)
        let labels = try Self.code("App/Albumist/Views/Proposal/ProposalCardLabels.swift")
        #expect(labels.contains("var spokenNotNow: Text { Text(\"Nicht jetzt: „\\(title)“\") }"), "the button's name, the same words")
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

    /// The lifted card hides what the card hides ("Vorschau ausgeblendet"), and at the
    /// accessibility text sizes the cover is a strip and the name wraps, never cut.
    @Test func theLiftedCardHidesWhatTheCardHidesAndKeepsTheWholeName() throws {
        let preview = try Self.body(["struct SuggestionPreview"], in: Self.suggestionPreview)
        #expect(preview.contains("hidesPreview ? [] : covers"), "no photo handed to a hidden cover")
        #expect(preview.contains("hidesPreview: hidesPreview"))
        #expect(preview.contains("typeSize.isAccessibilitySize ? 3 : 1.28"))
        #expect(preview.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(!preview.contains("lineLimit"), "a name cut at the accessibility sizes")
        #expect(preview.contains(".foregroundStyle(.noteText)"))
        #expect(!preview.contains("@Environment(AppModel"), "the system draws the lifted card apart: everything handed in")
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
        #expect(body.contains("shaped.contextMenu{ifisMenuOffered{menuItems}}preview:{menuPreview}"), "\(body)")
        #expect(body.contains("shaped.contextMenu{ifisMenuOffered{menuItems}}"), "\(body)")
        let actions = Self.squeezed(try Self.body(["struct PhotoCard<", "private func describedAsBody("], in: Self.photoCard))
        #expect(actions.contains("described.accessibilityActions{ifisMenuOffered{accessibilityMenuItems??menuItems}}"), "\(actions)")
        let code = try Self.code(Self.photoCard)
        #expect(code.contains("func menuOffered(_ offered: Bool) -> Self {"))
        #expect(code.contains("func menuAccessibilityActions(_ items: MenuItems) -> Self {"))
        // For VoiceOver the items say what can be done beside the card's button, nothing that waits.
        let items = try Self.body(["struct SuggestionMenuItems", "var body: some View"], in: Self.suggestionItems)
        #expect(items.contains("if forVoiceOver {") && items.contains("menu.accessibilityItems"), "\(items)")
    }

    // MARK: Photos
    // MARK: Photos

    /// Every grid of photos has the long press, at its place, off while it selects; the
    /// country's photos (the map's) are not touched here.
    @Test func everyPhotoGridHasTheLongPress() throws {
        let grids: [(path: String, declaration: [String], call: String)] = [
            (Self.library, ["struct LibraryView", "private func cell("], ".photoMenu(id, place: .unsorted, selecting: selecting)"),
            (Self.suggestions, ["struct ProposalPhotosView", "private func tile("],
             ".photoMenu(id, place: .suggestion, selecting: selecting, available: !disabled)"),
            (Self.albums, ["struct AlbumScreen", "private func tile("], ".photoMenu(photo, place: .album)"),
            (Self.search, ["struct SearchView", "private func thumbnail("], ".photoMenu(id, place: .search, available: hit != nil)"),
        ]
        for grid in grids {
            let cell = try Self.body(grid.declaration, in: grid.path)
            #expect(cell.contains(grid.call), "\(grid.path): \(cell)")
        }
        let country = try Self.code("App/Albumist/Views/CountryPhotosView.swift")
        #expect(!country.contains(".photoMenu("), "the map's files are not this strand's")
    }

    /// One mechanism for every photo: Apple's long press with the photo lifted larger, the same
    /// items as VoiceOver's actions of the photo, "Ansehen" left out there (the photo's own).
    @Test func thePhotosLongPressLiftsThePhotoAndGivesVoiceOverTheItems() throws {
        let press = try Self.body(["private struct PhotoLongPress", "func body(content: Content)"], in: Self.photoMenu)
        #expect(press.contains(".contextMenu {"))
        #expect(press.contains("} preview: {"))
        #expect(press.contains(".accessibilityActions {"))
        #expect(press.contains("items(forVoiceOver: true)") && press.contains("items(forVoiceOver: false)"))
        // Switched off the documented way while the grid selects or the photo cannot open: the
        // closures return nothing (review C of design wave 2, M4).
        let squeezedPress = Self.squeezed(press)
        #expect(squeezedPress.contains(".contextMenu{ifoffered{items(forVoiceOver:false)}}preview:{"), "\(squeezedPress)")
        #expect(squeezedPress.contains(".accessibilityActions{ifoffered{items(forVoiceOver:true)}}"), "\(squeezedPress)")
        let offered = Self.squeezed(try Self.body(["private struct PhotoLongPress", "private var offered: Bool"], in: Self.photoMenu))
        #expect(offered == "{PhotoMenu.isOffered(selecting:selecting,available:available)}", "\(offered)")
        let items = try Self.body(["struct PhotoMenuItems", "var body: some View"], in: Self.photoMenu)
        #expect(items.contains("menu.accessibilityItems"))
        #expect(!(try Self.body(["struct PhotoMenuItems"], in: Self.photoMenu)).contains("@Environment("),
                "the items read nothing from the environment: the long press hands the model in")
        #expect(Self.squeezed(press).contains("items(forVoiceOver:true)"))
        let handed = Self.squeezed(try Self.body(["private struct PhotoLongPress", "private func items("], in: Self.photoMenu))
        #expect(handed.contains("PhotoMenuItems(model:model,"), "\(handed)")
        #expect(items.contains("PhotoMenu(place: place"))
        let lifted = try Self.body(["struct PhotoPreview"], in: Self.photoMenu)
        #expect(lifted.contains("CoverPhoto(ids: [id]"), "only from the device, sharp or calm")
        #expect(!lifted.contains("AssetThumbnail"), "a small preview stretched large")
        #expect(!lifted.contains("@Environment(AppModel"), "the system draws the lifted photo apart: everything handed in")
        let size = Self.squeezed(try Self.body(["private struct PhotoLongPress", "private var liftedPhoto"], in: Self.photoMenu))
        #expect(size.contains("PhotoMenu.previewSize(pixelWidth:"), "\(size)")
    }

    /// Each photo item goes the place's way: "Ansehen" as the tap opens it, "Zu Album
    /// hinzufügen …" the sheet that leads to the preview, ignoring as everywhere (with
    /// "Widerrufen" on the screen), taking a photo out of a suggestion asked first.
    @Test func thePhotosMenuGoesTheWaysThatExist() throws {
        let items = try Self.code(Self.photoMenu)
        #expect(items.contains("model.ignore([id])") && items.contains("model.unignore([id])"))
        #expect(items.contains("Label(\"Zu Album hinzufügen …\""))
        #expect(items.contains("Button(role: .destructive) { perform(.removeFromSuggestion) }"))
        for bypass in ["removeFromProposal(", "manualPlan(", "execute(", "ShareLink", "Teilen"] {
            #expect(!items.contains(bypass), "\(bypass) in the photo's menu")
        }
        // The tap and "Ansehen" open the photo the same way; "Zu Album hinzufügen …" the sheet.
        let places: [(path: String, type: String, perform: String, tap: String)] = [
            (Self.library, "struct LibraryView", "private func perform(", "open(id, in: members)"),
            (Self.search, "struct SearchView", "private func perform(", "open(id, from: key)"),
            (Self.albums, "struct AlbumScreen", "private func perform(", "open(photo, ids: ids)"),
        ]
        for place in places {
            let type = try Self.body([place.type], in: place.path)
            let perform = try Self.body([place.type, place.perform], in: place.path)
            #expect(perform.contains("case .view: \(place.tap)"), "\(place.path): \(perform)")
            #expect(perform.contains("case .addToAlbum: addingToAlbum = [id]")
                    || perform.contains("case .addToAlbum: addingToAlbum = [photo]"), "\(place.path): \(perform)")
            #expect(type.components(separatedBy: place.tap).count - 1 >= 2, "\(place.path): the tap opens it the same way")
            #expect(type.contains("AddToAlbumSheet(assets: addingToAlbum ?? [])"), "\(place.path)")
            #expect(type.contains("IgnoreUndoBar()"), "\(place.path): „Widerrufen“ after „Ignorieren“")
        }
        // A suggestion's photo: asked first, on the suggestion's scroll view beside the question
        // for several (not from the middle of all its days; review C of design wave 2, M1), then
        // taken out as "Auswählen" takes several out.
        let photos = try Self.body(["struct ProposalPhotosView"], in: Self.suggestions)
        #expect(!photos.contains(".confirmationDialog("), "asked from the middle of all its days")
        #expect(photos.contains("case .removeFromSuggestion: askToRemove(id)"))
        #expect(photos.contains("case .view: open(id)"))
        let detail = Self.squeezed(try Self.body(["struct ProposalDetailView", "var body: some View"], in: Self.suggestions))
        #expect(detail.contains("}askToRemove:{idinremovingPhoto=id}"), "\(detail)")
        let several = try #require(detail.range(of: ".confirmationDialog(\"FotosausdiesemVorschlagentfernen?\""))
        let one = try #require(detail.range(of: ".photoRemovalQuestion($removingPhoto){idinTask{awaitmodel.removeFromProposal([id],proposal:proposal)}}"))
        #expect(several.lowerBound < one.lowerBound)
        let question = try Self.code(Self.photoQuestion)
        #expect(question.contains(".confirmationDialog(\"Foto aus diesem Vorschlag entfernen?\""))
        #expect(question.contains("Button(\"Entfernen\", role: .destructive) { remove(id) }"))
        #expect(question.contains("Text(\"Es kommt nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleibt es.\")"))
    }

    /// A photo the user ignored offers "Nicht mehr ignorieren" also without a state of its own
    /// (an album's photo the analysis has not read yet: "Ignorieren" gives it none): the model
    /// reads the photos the user ignored (`PhotoMenu.isIgnored`), and keeps them observed, so the
    /// menu follows a tap at once (review C of design wave 2, L6).
    @Test func anIgnoredPhotoWithoutAStateOffersTheWayBack() throws {
        let ignored = Self.squeezed(try Self.body(["func isIgnored(_ id: AssetID) -> Bool"], in: Self.model))
        #expect(ignored == "{PhotoMenu.isIgnored(id,ignored:ignoredIDs,state:states[id])}", "\(ignored)")
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        #expect(model.contains("    private(set) var ignoredIDs: Set<AssetID> = [] // Design W2 H7"))
        #expect(!model.contains("@ObservationIgnored private var ignoredIDs"), "the menu would not follow a tap")
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
        for word in ["\"Anpassen\"", "\"Reise teilen oder zusammenlegen\"", "\"Keine Reise, hier bin ich öfter\"", "\"Nicht jetzt\""] {
            #expect(items.contains(word), "\(word)")
            #expect(english(String(word.dropFirst().dropLast())) != nil, "\(word)")
        }
        let photo = try Self.code(Self.photoMenu)
        for word in ["\"Ansehen\"", "\"Ignorieren\"", "\"Nicht mehr ignorieren\"", "\"Aus Vorschlag entfernen\""] {
            #expect(photo.contains(word), "\(word)")
        }
    }
}
