import SwiftUI
import AlbumistCore

/// All suggestions, or those of one area (the start page's "Alle 41"; design E1, E6): photo
/// cards two in a row, one at the accessibility text sizes, grouped by area, the album's name and
/// its status under each photo and its one action on each card (`ProposalCardText`).
///
/// "Auswählen" works as in Photos (decision 9 of 18.11.2026, in place of a basket): tick the
/// cards, then "N Alben anlegen" opens the preview of those suggestions; "Fertig" or leaving the
/// list drops the ticks. Only what a card could make itself can be ticked ("Anlegen",
/// "Ergänzen …"): a name, a look or a choice needs the suggestion's own page first. "Alle
/// auswählen" leaves out what "Nicht jetzt" set aside: those are ticked one by one.
struct ProposalListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator: Navigator?
    @Environment(\.dynamicTypeSize) private var typeSize
    var area: OrganizationArea?
    @State private var selecting = false
    @State private var selected: Set<AlbumistID> = []
    /// Suggestions made from a card here ("Anlegen"): kept in place with "Angelegt" while their
    /// banner shows (draft E6 "nach dem Anlegen"), so the cards do not move under the finger and
    /// "Widerrufen" brings the suggestion back where it was.
    @State private var made: [AlbumistID: AlbumProposal] = [:]
    /// The cards zoom into the suggestion they open and back (`ProposalDetailView.zoom`).
    @Namespace private var zoom
    /// What a card's long press opens, kept by the list, made when the list is made, not at each
    /// of its drawings (`suggestionMenuFlows(_:)`; review C2 of design wave 2, N2).
    @State private var menuFlows = SuggestionMenuFlowAction()

    /// The suggestions shown, in the app's one suggestion order (also the start page's and the
    /// preview's), with one just made from a card while its banner shows.
    private var proposals: [AlbumProposal] {
        let open = model.proposals.filter { area == nil || $0.kind.area == area }
        let banner = model.quickCreateBanner?.proposalID
        let kept = made.values.filter { p in
            p.id == banner && (area == nil || p.kind.area == area) && !open.contains { $0.id == p.id }
        }
        return (open + kept).inDisplayOrder()
    }

    /// Suggestions grouped by area in the app's area order, those set aside with "Nicht jetzt"
    /// in a group of their own at the end.
    private struct CardSection: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let items: [AlbumProposal]
    }

    private func sections(of all: [AlbumProposal]) -> [CardSection] {
        // Set aside, or made from "Nicht jetzt" while its banner shows: its pick, then its album,
        // would move the card to its area under the finger, and "Widerrufen" sets it aside again
        // (`AppModel.quickCreateKeepsNotNow`).
        let isNotNow = { (proposal: AlbumProposal) in
            model.decisions[proposal.id] == .reject || model.quickCreateKeepsNotNow(proposal.id)
        }
        let open = all.filter { !isNotNow($0) }
        let notNow = all.filter(isNotNow)
        var result: [CardSection] = []
        if area == nil {
            // All suggestions: one section per area, so a trip "Rom, Mai 2024" is not mistaken
            // for a city album next to the countries (Fuchs, 14.11.).
            let groups = Dictionary(grouping: open) { $0.kind.area }
            result = OrganizationArea.allCases.compactMap { area in
                groups[area].map { CardSection(id: area.rawValue, title: area.title, items: $0) }
            }
        } else if !open.isEmpty {
            result = [CardSection(id: "open", title: area?.title ?? "Vorschläge", items: open)]
        }
        if !notNow.isEmpty {
            result.append(CardSection(id: "notNow", title: "Nicht jetzt", items: notNow))
        }
        return result
    }

    /// The suggestions a tick can take: what their card would make itself.
    private func isSelectable(_ proposal: AlbumProposal, _ card: ProposalCardText?) -> Bool {
        guard made[proposal.id] == nil, let card else { return false }
        switch card.action {
        case .create, .add: return true
        case .name, .look: return false
        }
    }

    var body: some View {
        // Once per drawing: the suggestions and each one's card, which the toolbar, the ticks and
        // the cards read (they were made up to three times over; second review of design wave 1).
        let shown = proposals
        let cards = Dictionary(shown.map { ($0.id, model.proposalCard(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let groups = sections(of: shown)
        ScrollView {
            if groups.isEmpty {
                ContentUnavailableView("Keine Vorschläge", systemImage: "checkmark.circle",
                                       description: Text("Für diesen Bereich gibt es gerade nichts zu tun."))
                    .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(groups) { section in
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            // The list's own title names a single area: no header repeating it.
                            if area == nil || section.id == "notNow" {
                                Text(section.title)
                                    .font(.title2.weight(.bold))
                                    .accessibilityAddTraits(.isHeader)
                            }
                            grid(section.items, cards: cards)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .quickCreateMomentScrollTrail() // Design W2 H6: scroll trail
        .background(Theme.background)
        // The words of the start page's row that opens it, never the start page's own title:
        // "Vorschläge" twice read as nothing happening (UI run 44862187776).
        .navigationTitle(area?.title ?? "Alle Vorschläge")
        // While ticking, "Alle auswählen" takes the place of Back, as in Photos and Files.
        .navigationBarBackButtonHidden(selecting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selected = []
                    }
                }
                .disabled(!selecting && !shown.contains { isSelectable($0, cards[$0.id]) })
                .accessibilityIdentifier(selecting ? "suggestions.selectDone" : "suggestions.select")
            }
            if selecting {
                ToolbarItem(placement: .topBarLeading) {
                    // Not what "Nicht jetzt" set aside: the user ticks those one by one.
                    let all = shown.filter { model.decisions[$0.id] != .reject && isSelectable($0, cards[$0.id]) }.map(\.id)
                    let allTicked = !all.isEmpty && Set(all).isSubset(of: selected)
                    Button(allTicked ? "Auswahl aufheben" : "Alle auswählen") {
                        selected = allTicked ? [] : selected.union(all)
                    }
                    .disabled(all.isEmpty)
                    .accessibilityIdentifier("suggestions.selectAll")
                }
                ToolbarItem(placement: .bottomBar) {
                    // The ticked suggestions that are still there.
                    let count = shown.filter { selected.contains($0.id) }.count
                    Button {
                        createTicked(from: shown)
                    } label: {
                        Text("\(count) \(count.formatted()) Alben anlegen")
                    }
                    .disabled(count == 0)
                    .accessibilityIdentifier("suggestions.createSelected")
                }
            }
        }
        // While ticking, the tab bar goes, as in Photos: the bottom bar with "N Alben anlegen"
        // takes its place (review P3-01).
        .toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)
        // Leaving the list drops the ticks (decision 9): the preview has its own pick.
        .onDisappear {
            selecting = false
            selected = []
        }
        // A card made here shows "Angelegt" only while its banner does.
        .onChange(of: model.quickCreateBanner?.id) {
            let banner = model.quickCreateBanner?.proposalID
            made = made.filter { $0.key == banner }
        }
        // What a card's long press opens: "Anpassen", the trip workshop, "Keine Reise?" (DS-06a).
        .suggestionMenuFlows(menuFlows)
    }

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .top)]
            : [GridItem(.adaptive(minimum: 160), spacing: Theme.Spacing.m, alignment: .top)]
    }

    private func grid(_ items: [AlbumProposal], cards: [AlbumistID: ProposalCardText]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.m) {
            ForEach(items) { proposal in
                let card = cards[proposal.id] ?? model.proposalCard(for: proposal)
                ProposalListCard(proposal: proposal, card: card,
                                 made: made[proposal.id] != nil && model.quickCreateBanner?.proposalID == proposal.id,
                                 selecting: selecting, selectable: selecting && isSelectable(proposal, card),
                                 isSelected: selected.contains(proposal.id)) {
                    open(proposal)
                } toggle: {
                    if selected.contains(proposal.id) { selected.remove(proposal.id) } else { selected.insert(proposal.id) }
                } act: { action in
                    act(action, on: proposal)
                }
                .matchedTransitionSource(id: proposal.id, in: zoom)
                .quickCreateMomentSource(proposal, aspectRatio: 4.0 / 3.0) // Design W2 H6: moment source
            }
        }
    }

    /// The suggestion's page, pushed by value (`AppScreen`): it may push its own preview. It zooms
    /// out of its card and back into it (`ProposalDetailView.zoom`).
    private func open(_ proposal: AlbumProposal) {
        Navigator.push(.proposal(ProposalRef(proposal, zoom: zoom)), on: navigator)
    }

    /// Whether "Anlegen" makes the album at once on this stack: only on a tab's, where its banner
    /// shows (`NavigationRoot`).
    @Environment(\.quickCreateAtOnce) private var quickCreateAtOnce

    /// The card's one action: "Anlegen" makes the album at once with its banner (decision 7B),
    /// "Ergänzen …" opens the preview (an album of the user's is changed only after a look,
    /// Punkt 5), "Benennen …" and "Ansehen …" open the suggestion.
    private func act(_ action: ProposalCardAction, on proposal: AlbumProposal) {
        // The suggestion as the analysis has it now: the card's menu stays open while it may
        // change, or go, which is said then (review C of design wave 2, H1).
        guard let proposal = model.currentSuggestion(proposal) else { return }
        switch action {
        case .create:
            // One album at a time, as the button waits: the menu's word and VoiceOver reach this
            // too, and the card would say "✓ Angelegt" before it is taken back (L1).
            guard model.quickCreating == nil else { return }
            // Where no banner shows (a sheet's own stack), the suggestion opens instead, as for
            // a card that needs a look; its "Album anlegen" goes through the preview there.
            guard quickCreateAtOnce else {
                open(proposal)
                return
            }
            made[proposal.id] = proposal
            Task {
                let outcome = await model.createNow(proposal)
                if outcome != .created { made[proposal.id] = nil }
            }
        case .add:
            openPreview(of: [proposal])
        case .name, .look:
            open(proposal)
        }
    }

    /// "N Alben anlegen": the preview of the ticked suggestions that are still there, in the
    /// list's order; the ticks go with the list.
    private func createTicked(from shown: [AlbumProposal]) {
        let items = shown.filter { selected.contains($0.id) }
        withAnimation(.snappy) {
            selecting = false
            selected = []
        }
        openPreview(of: items)
    }

    /// The preview of `items`, each with the user's choice for it or else its recommendation,
    /// selected for the preview only: leaving the preview without creating gives every pick
    /// back (`AppModel.endPreview`), as for "Dein Startpaket".
    private func openPreview(of items: [AlbumProposal]) {
        guard !items.isEmpty, let navigator else { return }
        let selection = model.selectForPreview(items.map { proposal in
            let chosen = model.decision(for: proposal)
            return (proposal, chosen.isAccepted ? chosen : model.recommendedDecision(for: proposal))
        })
        guard navigator.push(.plan(selection)) else {
            model.endPreview(selection)
            return
        }
        navigator.onLeave(.plan(selection)) { [model] in model.endPreview(selection) }
    }
}

/// One suggestion of the list as a photo card (drafts E1, E6): its cover, the album's name as
/// Photos will show it, its status, and its one action, or a tick while the list selects.
private struct ProposalListCard: View {
    @Environment(AppModel.self) private var model
    /// The list's sheets and question for the long press (`suggestionMenuFlows(_:)`).
    @Environment(\.openSuggestionMenuFlow) private var openFlow
    var proposal: AlbumProposal
    /// Its words (`AppModel.proposalCard`), made once for the whole list.
    var card: ProposalCardText
    /// Made from this card a moment ago: "✓ Angelegt" in place of its action while its banner
    /// shows (draft E6 b; no badge on the photo besides). It opens nothing: its suggestion is gone.
    var made: Bool
    var selecting: Bool
    var selectable: Bool
    var isSelected: Bool
    var open: () -> Void
    var toggle: () -> Void
    var act: (ProposalCardAction) -> Void

    // The body is built from small parts, each with its own type: as one expression (a closure
    // chosen by a condition, the card and all its modifiers) Xcode could not type-check it
    // ("failed to produce diagnostic for expression", CI 44847306162).
    var body: some View {
        photoCard
            // Names the card's container (UI tests: the card, its body and its one button).
            .accessibilityIdentifier("suggestion.row")
            .overlay(alignment: .topTrailing) {
                if selectable {
                    tick
                }
            }
            // What cannot be ticked steps back while the list selects, and cannot be tapped.
            .opacity(selecting && !selectable ? 0.45 : 1)
            .disabled(selecting && !selectable)
    }

    /// The photo card, ticked while the list selects and the card is chosen. Its long press lifts
    /// the card itself: the photo it shows, what it hides hidden, in its shape (review C of
    /// design wave 2, M2).
    private var photoCard: some View {
        PhotoCard(coverIDs: covers, title: Text(verbatim: card.title),
                  subtitle: card.styledSubtitle, hidesPreview: card.hidesPreview,
                  placeholderSymbol: proposal.placeholderSymbol, onOpen: opens) {
            cardAction
        } menu: {
            menuItems
        }
        .selected(selecting && isSelected)
        .menuOffered(SuggestionMenu.isOffered(made: made, working: model.quickCreating == proposal.id, selecting: selecting))
        .menuAccessibilityActions(voiceOverItems)
    }

    /// The cover's candidates; none while its photos are hidden (every one a sensitive document).
    private var covers: [AssetID] {
        card.hidesPreview ? [] : model.proposalCoverIDs(for: proposal)
    }

    /// The long press (design wave 2, DS-06a; draft E4): the card's word first, doing what its
    /// button does, then what the open suggestion's "…" offers; nothing while its album is made,
    /// once it is made, or while the list selects.
    private var menuItems: SuggestionMenuItems {
        SuggestionMenuItems(model: model, openFlow: openFlow, proposal: proposal, card: card, made: made,
                            working: model.quickCreating == proposal.id,
                            waits: model.quickCreating != nil && model.quickCreating != proposal.id,
                            selecting: selecting, act: { act(card.action) })
    }

    /// The same items as actions of the card's body, but the word (review C of design wave 2, L3).
    private var voiceOverItems: SuggestionMenuItems {
        SuggestionMenuItems(model: model, openFlow: openFlow, proposal: proposal, card: card, made: made,
                            working: model.quickCreating == proposal.id,
                            waits: model.quickCreating != nil && model.quickCreating != proposal.id,
                            selecting: selecting, forVoiceOver: true, act: { act(card.action) })
    }

    /// The card's body opens the suggestion, or ticks it while the list selects (`onOpen`: its
    /// own button behind cover and texts); its one action stays a real button. A card just made
    /// opens nothing, so its body is no button.
    private var opens: (@MainActor () -> Void)? {
        if made { return nil }
        return { tap() }
    }

    /// While the list selects, a tap ticks the card: the button keeps its place, so nothing
    /// moves, but cannot be seen, tapped or reached any other way.
    private var cardAction: some View {
        actionButton
            .opacity(selecting ? 0 : 1)
            .allowsHitTesting(!selecting)
            .accessibilityHidden(selecting)
            .disabled(selecting)
    }

    /// The tick of a card the list can select, as in Photos. A touch goes through to the card's
    /// body, which ticks; for VoiceOver it is a button of its own, named with the album, that
    /// says whether the card is ticked (the body only says what the card is).
    private var tick: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.3))
            .padding(Theme.Spacing.s)
            .allowsHitTesting(false)
            .accessibilityLabel(card.spokenTick)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { toggle() }
            .accessibilityIdentifier("suggestion.tick")
    }

    private func tap() {
        if !selecting {
            open()
        } else if selectable {
            toggle()
        }
    }

    /// One button: what the card does, a wait while its album is made, "Angelegt" after it. Its
    /// name for VoiceOver and Voice Control holds the album's ("„Kyoto, Oktober 2024“ anlegen"),
    /// as on the start page.
    @ViewBuilder
    private var actionButton: some View {
        if made {
            Button {} label: {
                Label("Angelegt", systemImage: "checkmark")
            }
            .buttonStyle(CardActionButtonStyle())
            .disabled(true)
            .accessibilityLabel(card.spokenMade)
        } else {
            let creating = model.quickCreating == proposal.id
            Button {
                act(card.action)
            } label: {
                if creating {
                    ProgressView()
                        .accessibilityLabel(Text("Album wird angelegt"))
                } else {
                    Text(card.action.title)
                }
            }
            .buttonStyle(CardActionButtonStyle())
            // One album at a time: a second tap meanwhile is no second album.
            .disabled(model.quickCreating != nil)
            .accessibilityLabel(creating ? Text("Album wird angelegt") : card.spokenAction)
            .accessibilityInputLabels(card.actionInputLabels)
        }
    }
}

/// A suggestion as a row of a list (the photo's suggestions, "Vorschläge" in "Unsortiert"): its
/// cover small, the album's name as Photos will show it and its status as on its card.
struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var proposal: AlbumProposal

    var body: some View {
        let card = model.proposalCard(for: proposal)
        HStack(spacing: Theme.Spacing.m) {
            // Never a sensitive document (a bank card, owner's iPhone build 36): `coverID`.
            CoverThumbnail(id: model.coverID(for: proposal), side: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: card.title).font(.body.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                // "Name fehlt · 38 Fotos", "Kommt in dein Album „Toskana“ · +12 Fotos" (Punkt 3).
                card.styledSubtitle.font(.footnote).foregroundStyle(.noteText)
                if model.decisions[proposal.id] == .reject {
                    Label("Nicht jetzt", systemImage: "xmark.circle")
                        .labelStyle(CompactLabelStyle())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.noteText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// An open suggestion (design E2, "Vorschlag offen"): its cover big at the top with no text on
/// it, the sign that nothing is in Photos yet, the album's name as Photos will show it, how many
/// photos of which days and where the album goes, then its photos by day. Its two buttons stay
/// at the bottom where the tab bar was ("Nicht jetzt", "Album anlegen"; decision 6B); everything
/// else is behind "…" at the top right (P3-06), and "Auswählen" takes photos out as in Photos.
/// "Album anlegen" makes a new album at once with its banner (decision 7B); an album of the user's
/// is changed only through the preview (Punkt 5).
struct ProposalDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var navigator: Navigator?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    var proposal: AlbumProposal
    /// The namespace of the card the page was opened from: the page zooms out of that card and
    /// back into it (design report, Scheibe 2). Nil where it was opened another way.
    var zoom: Namespace.ID?
    @State private var name = ""
    @State private var showAdjust = false
    @State private var suggesting = false
    /// The preview of "Album anlegen", pushed onto the stack's path (`AppScreen`).
    @State private var directPlan: PlanToken?
    /// A preview of "Album anlegen" that was ready while another tab was chosen: offered again
    /// when this tab shows (`showWaiting()`). Its pick for the preview is undone while it waits,
    /// so nothing stays selected that the user did not choose.
    @State private var waiting: WaitingPlan?
    /// "Album anlegen" is making its preview. The photos do not open meanwhile (the preview
    /// would be pushed under them), and nothing the plan is made from can be changed here: the
    /// name, the album ("Anpassen", "passt nicht"), the trip, the place or its photos.
    @State private var preparing = false
    /// "Album anlegen" is making the album right now, without a preview (`AppModel.createNow`).
    @State private var creating = false
    @State private var applied = false
    @State private var rejectingMatch = false
    /// Set by "Album anlegen" for its preview only; given back when the preview leaves the path
    /// (`Navigator.onLeave`) or is not shown (`endSelection()`). A suggestion whose album was
    /// created stays done.
    @State private var previewSelection: AppModel.PreviewSelection?
    @State private var explainReliability = false
    @State private var showWorkshop = false
    /// Set when the trip was split or merged: this suggestion is gone, back to the list.
    @State private var reshaped = false
    @State private var confirmOftenHere = false
    /// Photos are being picked to take them out of the suggestion ("Auswählen", as in Photos).
    @State private var selecting = false
    @State private var selected: Set<AssetID> = []
    @State private var confirmRemove = false
    /// The photo whose long press chose "Aus Vorschlag entfernen", being asked about.
    @State private var removingPhoto: AssetID?
    /// "Fotos anzeigen": the photos of a suggestion of sensitive documents only, shown on purpose.
    @State private var revealed = false
    /// The cover shows a sharp photo, not the calm placeholder: the status bar and the bar's
    /// buttons are light on it until it has scrolled away.
    @State private var coverIsPhoto = false
    @State private var pastCover = false
    /// The calm colour of the cover on screen (DS-11, `PhotoTint`): the page's ground, under the
    /// header, the photos and the bar. Nil while not known or without one: the grouped background.
    @State private var tint: PhotoTint? // Design W3 H13: photo tint
    /// The page's title has gone under the bar: the bar shows the name, as Photos does in an album.
    @State private var pastTitle = false
    /// Where the bar ends at the top of the page, in the scroll view's space: the status bar and
    /// the navigation bar as the page measures them (about 103 pt on an iPhone held upright,
    /// less across it or on an iPad), with a little room.
    @State private var barBottom: CGFloat = 110
    /// The page went back once: a second way out (the banner of its album, its button) does not
    /// take a second screen with it.
    @State private var left = false
    /// Its photos by day and its cover's candidates, kept while they stay the same.
    @State private var cache = ProposalPageCache()
    /// The heights of the two words in the bar, measured: side by side each gets the taller
    /// one's, so both buttons are as tall when "1.354 Fotos ergänzen" takes two lines (the
    /// button styles grow with their words, not with the height the bar offers; review B, 7).
    @State private var barWords = BarWordHeights()
    /// The keyboard is in the name field; "Namen eingeben" puts it there.
    @FocusState private var nameFocused: Bool
    /// VoiceOver goes along to the name field.
    @AccessibilityFocusState private var nameFieldVoiceOverFocus: Bool

    /// Only trips get a creative name; places and dates keep their exact titles.
    private var canSuggestTitle: Bool {
        if case .trip = proposal.kind { return SmartAssistant.isAvailable && recommended.isCreatingNew }
        return false
    }

    private func suggestTitle() async {
        suggesting = true
        defer { suggesting = false }
        let details = proposal.reasons.map { ReasonText.text($0) }
        guard let title = await SmartAssistant.tripTitle(currentTitle: proposal.title, details: details, language: model.settings.titleLanguage) else { return }
        let year = proposal.dateRange.map { String(Calendar.current.component(.year, from: $0.start)) }
        model.setUserTitle([title, year].compactMap { $0 }.joined(separator: " "), for: proposal)
    }

    private var match: MatchResult? { model.match(for: proposal) }

    /// The name in the field of a place or group only the user can name (not stored before an
    /// album is made from it); nil for every other suggestion, whose name is the stored one.
    private var typedName: String? { proposal.requiresUserName ? name : nil }

    /// What the primary button does: the user's choice from "Anpassen" wins over Albumist's
    /// recommendation (it must never be overwritten by accepting the suggestion).
    private var recommended: ProposalDecision {
        let chosen = model.decision(for: proposal)
        if chosen.isAccepted { return chosen }
        return ProposalDecision.recommended(for: proposal, match: match, userTitle: typedName ?? model.userTitles[proposal.id])
    }

    /// Something for this suggestion is being made: its buttons wait.
    private var busy: Bool { preparing || creating || model.quickCreating == proposal.id }

    /// The suggestion as the analysis has it now, with the same photos. One that went meanwhile
    /// (made from its card or after the purchase sheet, split, merged, made anew) shows as it was
    /// opened (`ProposalScreen`), and nothing is made from it any more.
    private var isCurrent: Bool {
        model.proposals.contains { $0.id == proposal.id && $0.assetIDs == proposal.assetIDs }
    }

    /// Photos lets an app make albums only when all photos are shared: the page says so where
    /// the album would be made, as the preview does, instead of an alert after the tap.
    private var needsFullAccess: Bool { model.access == .limited && !UITestSupport.isRunning }

    /// Its photos by day and its cover's candidates, made again only when what they are made of
    /// changes (`ProposalPageCache`), not at every letter of a name or tick of a photo.
    private func pagePhotos() -> (days: [PhotoDay], coverIDs: [AssetID]) {
        let key = ProposalPageCache.Key(id: proposal.id, photos: proposal.assetIDs,
                                        removed: model.removedFromProposals[proposal.id] ?? [],
                                        cover: proposal.coverAssetID, words: model.proposalWords,
                                        analysis: model.snapshot?.generatedAt, facts: model.facts.count)
        cache.update(for: key) {
            model.proposalPhotoDays(for: proposal)
        } coverIDs: {
            model.proposalCoverIDs(for: proposal, favorites: model.proposalFavorites(for: proposal))
        }
        return (cache.days, cache.coverIDs)
    }

    /// The page's ground: the cover's calm colour, else the grouped background; Increase Contrast
    /// always gets the grouped background (`PhotoTintGround`).
    private var ground: Color { PhotoTintGround.color(tint) } // Design W3 H13: photo tint

    /// Back to where the page was opened from, once.
    private func leave() {
        guard !left else { return }
        left = true
        dismiss()
    }

    var body: some View {
        // The card's words: the album's name and folder exactly as the plan will make them.
        let card = model.proposalCard(for: proposal, typedTitle: typedName)
        let photos = pagePhotos()
        let days = photos.days
        let text = ProposalDetailText(card: card, days: days, words: model.proposalWords)
        let photosHidden = card.hidesPreview && !revealed
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cover(card, ids: photos.coverIDs)
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    header(card, text)
                        // VoiceOver reads the header, then the two buttons at the bottom, then
                        // the rest: the buttons came after every photo (second review).
                        .accessibilityElement(children: .contain)
                        .accessibilitySortPriority(2)
                    if needsFullAccess {
                        FullAccessCard()
                    }
                    if proposal.requiresUserName {
                        nameSection
                    }
                    // Asked once per place, before the user decides on the album: the answer may
                    // turn the trips there into one album of the place.
                    if let question = model.recurringPlaceQuestion(for: proposal) {
                        recurringPlaceCard(question)
                    }
                    if showsAlbumCard {
                        albumCard
                    }
                    // At the accessibility sizes the bar keeps only the main button (`actionBar`):
                    // "Nicht jetzt" follows what the page says about the album, before its photos,
                    // and goes with the bar while photos are picked.
                    if typeSize.isAccessibilitySize && !needsFullAccess && !selecting {
                        notNowButton(card, beside: false)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.l)
                ProposalPhotosView(days: days, selecting: selecting, selected: $selected, hidden: photosHidden,
                                   disabled: busy, isCurrent: isCurrent) {
                    revealed = true
                } askToRemove: { id in
                    removingPhoto = id
                }
                // With the space above a day's title (`PhotoGridHeader`), 24 pt below the cards.
                .padding(.top, Theme.Spacing.m)
            }
            .padding(.bottom, Theme.Spacing.l)
        }
        // The cover reaches up under the status bar and the bar's glass buttons (draft E2).
        .ignoresSafeArea(edges: .top)
        // The grid scrolls the page while a finger selects at an edge, and keeps its place when
        // it zooms (`PhotoGrid`, design wave 3, DS-06b). Here, after the cover reaches up: from
        // here it reads where the bars end, as the measurement below does.
        .photoGridScrolling()
        // Where the bar ends: measured, as status bar and navigation bar differ upright, across
        // and on an iPad.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.top
        } action: { top in
            if top > 0 { barBottom = top + 7 }
        }
        // Dragging the page down puts the name field's keyboard away, as in Apple's apps.
        .scrollDismissesKeyboard(.interactively)
        .background(ground.ignoresSafeArea()) // Design W3 H13: photo tint
        // The two buttons where the tab bar was, always in reach of the thumb (decision 6B, as
        // the preview's bar, P3-05). While photos are picked, the system bottom bar takes over.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selecting {
                actionBar(card)
            }
        }
        // One container for VoiceOver, so the header and the bar can go first.
        .accessibilityElement(children: .contain)
        // The bar's title: kept for the stack and VoiceOver's screen name, shown as the album's
        // name only once the page's own title went under the bar (no text on the photo).
        .navigationTitle("Vorschlag")
        .navigationBarTitleDisplayMode(.inline)
        // Leaving while the album is made would look like cancelling it; it is made either way.
        .navigationBarBackButtonHidden(creating)
        .toolbarVisibility(.hidden, for: .tabBar)
        // The system's bottom bar holds "N aus Vorschlag entfernen" only while photos are picked;
        // left empty after, it stayed over the page's own bar, which showed and could not be
        // tapped (UI runs 45567033486 and 45603459548).
        .toolbarVisibility(selecting ? .visible : .hidden, for: .bottomBar)
        .toolbarColorScheme(coverIsPhoto && !pastCover ? ColorScheme.dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: card.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(pastTitle ? 1 : 0)
                    .accessibilityHidden(!pastTitle)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selected = []
                    }
                }
                // Picks only photos to take out: not of a suggestion that went (review C2, N4).
                .disabled(!selecting && (busy || !isCurrent || days.isEmpty || photosHidden))
                .accessibilityIdentifier(selecting ? "proposalPhotos.selectDone" : "proposalPhotos.select")
            }
            if !selecting {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) { moreActions }
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Text("\(selected.count.formatted()) aus Vorschlag entfernen")
                    }
                    // Waits for a suggestion that went meanwhile, as the page's own buttons do.
                    .disabled(selected.isEmpty || !isCurrent)
                    .accessibilityIdentifier("proposalPhotos.remove")
                }
            }
        }
        .confirmationDialog("Fotos aus diesem Vorschlag entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                // The question can stay open while the suggestion goes: nothing is kept for one
                // that no one has any more (review C2 of design wave 2, N4).
                guard isCurrent else { return }
                let chosen = selected
                // The selection ends as the photos leave the page, at once, as in Photos; the
                // suggestion is matched again behind it (UI run 45567033486: the selection's bar
                // stayed over 5 s while that ran).
                withAnimation(.snappy) {
                    selected = []
                    selecting = false
                }
                Task { await model.removeFromProposal(chosen, proposal: proposal) }
            }
        } message: {
            Text("Sie kommen nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleiben sie.")
        }
        // One photo from its long press, asked the same way here, not from the middle of its days.
        .photoRemovalQuestion($removingPhoto) { id in
            guard isCurrent else { return }
            Task { await model.removeFromProposal([id], proposal: proposal) }
        }
        // Asked for by "Keine Reise, hier bin ich öfter" in the menu; on the screen, because the
        // menu is gone once its item is tapped.
        .confirmationDialog("Keine Reise?", isPresented: $confirmOftenHere, titleVisibility: .visible) {
            Button("Keine Reise, hier bin ich öfter") { answerOftenHere(true) }
        } message: {
            Text("Aufenthalte an diesem Ort werden keine Reisen mehr, auch bei jeder neuen Analyse. Albumist schlägt stattdessen ein Album für den Ort vor. Rückgängig machen kannst du das in den Einstellungen.")
        }
        .onAppear {
            // A name given before is where the field starts. A name typed here stays while
            // another screen was on top (a photo, the preview): it was wiped on the way back.
            if name.isEmpty { name = model.userTitles[proposal.id] ?? "" }
            showWaiting()
        }
        // The tab shows again (`Navigator.appearances`): a result that waited is offered now.
        .onChange(of: navigator?.appearances) { showWaiting() }
        .sheet(isPresented: $showAdjust) {
            // A place only the user can name: "Titel" in "Anpassen" is this name field.
            NavigationRoot { AdjustProposalView(proposal: proposal, name: proposal.requiresUserName ? $name : nil) }
                .sheetSize(.short)
        }
        .sheet(isPresented: $showWorkshop, onDismiss: { if reshaped { dismiss() } }) {
            NavigationRoot { TripWorkshopView(proposal: proposal) { reshaped = true } }
                .sheetSize(.page)
        }
        // Swiped away while the change was being stored: told after the sheet closed, the trip
        // view still closes instead of staying on the trip that goes.
        .onChange(of: reshaped) { _, now in if now && !showWorkshop { dismiss() } }
        // Done once the plan of its own preview ran: a plan that ended on another tab meanwhile
        // does not close the page (review B of design wave 1, 12).
        .onChange(of: model.execution.finished) { _, finished in
            if showsDirect, let finished, finished.id == directPlan?.plan.id { applied = true }
        }
        .onChange(of: showsDirect) { _, showing in
            guard !showing else { return }
            // Its pick went back with the preview (`offer`, `Navigator.onLeave`).
            previewSelection = nil
            directPlan = nil
            // Back from the finished preview: the suggestion is done, return to the list.
            if applied { leave() }
        }
        // Its album was made meanwhile (after the purchase sheet, or from its card): nothing is
        // left to do here.
        .onChange(of: model.quickCreateBanner?.id) {
            if model.quickCreateBanner?.proposalID == proposal.id { leave() }
        }
        .modifier(ZoomedFromCard(source: proposal.id, namespace: zoom))
    }

    // MARK: Cover and header

    /// The cover across the page with no text on it: sharp from the device, or a calm
    /// placeholder; "Vorschau ausgeblendet" for sensitive documents (`CoverPhoto`). Never a
    /// screenshot, a document or a sensitive photo (`AppModel.proposalCoverIDs`).
    private func cover(_ card: ProposalCardText, ids: [AssetID]) -> some View {
        // A plain number for the geometry closure, which runs off the main actor.
        let barBottom = self.barBottom
        let ratio: CGFloat = typeSize.isAccessibilitySize ? 2 : 1.25
        return CoverPhoto(ids: ids,
                          aspectRatio: ratio, cornerRadius: 0, hidesPreview: card.hidesPreview,
                          placeholderSymbol: proposal.placeholderSymbol) { outcome in
            coverIsPhoto = outcome == .sharp
        }
        // Its calm colour, once a sharp photo shows: never of "Vorschau ausgeblendet" or the
        // placeholder.
        .coverTint(of: ids, aspectRatio: ratio, sharp: coverIsPhoto, hidden: card.hidesPreview, into: $tint) // Design W3 H13: photo tint
        // The status bar and the bar's buttons stay readable on a bright sky; only on a photo.
        .overlay(alignment: .top) {
            if coverIsPhoto {
                LinearGradient(colors: [Color.black.opacity(0.32), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .scrollView).maxY < barBottom
        } action: { gone in
            pastCover = gone
        }
        .accessibilityHidden(true)
    }

    /// The sign, the name, the count with the days and where the album goes (draft E2), then
    /// what the user should know before it is made.
    private func header(_ card: ProposalCardText, _ text: ProposalDetailText) -> some View {
        let barBottom = self.barBottom
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            pill(card, text)
            Text(verbatim: card.title)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.frame(in: .scrollView).maxY < barBottom
                } action: { gone in
                    pastTitle = gone
                }
            VStack(alignment: .leading, spacing: 2) {
                // "16 Fotos · 12. bis 16. Oktober", "Kommt als neues Album in „Reisen › 2024“".
                Text(verbatim: text.facts)
                Text(verbatim: text.destination)
            }
            .font(.subheadline)
            .foregroundStyle(.noteText)
            .fixedSize(horizontal: false, vertical: true)
            // Why its buttons wait: nothing is made from a suggestion that went meanwhile.
            if !isCurrent && !left {
                Label("Dieser Vorschlag ist schon erledigt oder nicht mehr aktuell.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // "Möglich" and the like only where the user should look (Punkt 3).
            if case .pleaseLook(let reliability?) = card.status {
                reliabilityNote(reliability)
            }
            ForEach(Array(extraReasons.enumerated()), id: \.offset) { _, reason in
                Text(reason).font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canSuggestTitle {
                suggestTitleButton
            }
            if proposal.isSensitive {
                Label("Persönlicher Inhalt: wird nie automatisch ausgewählt.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.noteText)
            }
        }
    }

    /// "Namen vorschlagen" under the name; a small spinner while the name is being suggested.
    private var suggestTitleButton: some View {
        Button {
            Task { await suggestTitle() }
        } label: {
            // 44 pt to tap on the label, where the button takes the tap; leading, so
            // nothing moves (review S3 of H14).
            Group {
                if suggesting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("Name wird vorgeschlagen"))
                } else {
                    Label("Namen vorschlagen", systemImage: "apple.intelligence")
                }
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .font(.subheadline.weight(.semibold))
        .disabled(suggesting || busy)
    }

    /// "Vorschlag · noch nicht in Fotos" on its own tinted ground, never on the photo: it stays
    /// until the album is made (design report, Scheibe 2). The accent on its 12 % ground is
    /// 5.01:1; Increase Contrast adds an edge.
    private func pill(_ card: ProposalCardText, _ text: ProposalDetailText) -> some View {
        let inPhotos: Bool = { if case .alreadyIn = card.outcome { true } else { false } }()
        return Label(text.pill, systemImage: inPhotos ? "checkmark.circle" : "rectangle.dashed")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .padding(.vertical, 5)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
    }

    /// "Möglich · Bitte kurz ansehen": a tap says what the word means.
    private func reliabilityNote(_ reliability: Reliability) -> some View {
        Button { explainReliability = true } label: {
            let look = Text("Bitte kurz ansehen")
            HStack(spacing: 4) {
                Text("\(Text(reliability.label)) · \(look)")
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.accent)
            }
            // The app's warning colour (5.0–7.6:1); the symbol alone carries the accent.
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.tint(for: .documents))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(reliability.explanation))
        .popover(isPresented: $explainReliability) {
            Text(reliability.explanation)
                .font(.subheadline)
                .padding()
                .frame(idealWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// What the suggestion says about itself beyond its count, days and place, which the lines
    /// above already say: a recurring place, what the photos show, photos only suggested, a
    /// disputed area.
    private var extraReasons: [String] {
        proposal.reasons.compactMap { reason -> String? in
            switch reason {
            case .photosInPlaceDuringPeriod, .photosInPlace, .photosInPeriod: return nil
            default: return ReasonText.text(reason)
            }
        }
    }

    /// The name of a place or group only the user can name, as a section of the system's
    /// grouped forms: a header, the field filled like a list row, a footer. The field with
    /// `.roundedBorder` and the place's title as its grey prompt read as a title, and its edge
    /// all but vanished in dark mode (owner's device test 18.11.: nobody saw where the name
    /// goes). Grows with the text size; no fixed height.
    private var nameSection: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Name für das Album")
                .font(.footnote)
                .textCase(.uppercase)
                .foregroundStyle(.noteText)
                .padding(.horizontal, Theme.Spacing.l)
                // The field carries the same words as its label; VoiceOver says them once.
                .accessibilityHidden(true)
            TextField("Name für das Album", text: $name, prompt: nameExamples)
                .font(.body)
                .textInputAutocapitalization(.words)
                // Return only closes the keyboard: an album is made by the button alone.
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                .focused($nameFocused)
                .accessibilityFocused($nameFieldVoiceOverFocus)
                .accessibilityLabel(Text("Name für das Album"))
                .accessibilityIdentifier("proposal.nameField")
                .disabled(busy)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .background {
                    // A tap anywhere on the row puts the keyboard in the field, not only on its line.
                    shape.fill(Theme.card)
                        .onTapGesture { if !busy { nameFocused = true } }
                        .accessibilityHidden(true)
                }
                // With Increase Contrast the row gets an edge, like `Card`.
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
            nameFootnote
                .font(.footnote)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.l)
        }
        .padding(.top, Theme.Spacing.s)
    }

    /// Examples in the empty field that fit what is named: a place, or a person or an animal.
    private var nameExamples: Text {
        proposal.kind == .personOrPet ? Text("z. B. Oma, Bello, Minka") : Text("z. B. Bei Oma, Garten, Ferienhaus")
    }

    private var nameFootnote: Text {
        proposal.kind == .personOrPet
            ? Text("Albumist benennt Personen und Tiere nie selbst.")
            : Text("Albumist benennt persönliche Orte nie selbst.")
    }

    /// "Bist du hier öfter?": the user's answer is the only thing that says what a place is
    /// to them, and it is never shown as a title.
    private func recurringPlaceCard(_ question: RecurringPlaceCandidate) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Bist du hier öfter, etwa Zweitwohnsitz, Arbeit oder Familie?").font(.headline)
                Text("Du warst \(question.stayCount)-mal hier, zuletzt \(question.lastVisit.formatted(.dateTime.month(.wide).year())).")
                    .font(.subheadline).foregroundStyle(.noteText)
            }
            Button("Ja, hier bin ich öfter") { answerOftenHere(true) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.canChangeHome || busy)
                .accessibilityIdentifier("proposal.oftenHere.yes")
            Button("Nein, das sind Reisen") { answerOftenHere(false) }
                .buttonStyle(SecondaryButtonStyle())
                // While a change in "Dein Zuhause" is applied, like "Ja": the answer would be
                // stored beside it and the question come back until the suggestions are new.
                .disabled(model.homeChangeRunning || busy)
                .accessibilityIdentifier("proposal.oftenHere.no")
            // Why a button waits (design review N8 found the two buttons behaving differently
            // without a word why): "Ja" plans the trips anew, "Nein" changes nothing.
            if let reason = Self.oftenHereWaitReason(model, askedOnTheCard: true) {
                Text(reason)
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why "Ja, hier bin ich öfter" on the question card (and during a change in "Dein
    /// Zuhause" also "Nein"), or "Keine Reise, hier bin ich öfter" on a trip, waits; nil when it
    /// can be tapped. Also the reason in a card's long press (`SuggestionMenuItems`).
    static func oftenHereWaitReason(_ model: AppModel, askedOnTheCard: Bool) -> LocalizedStringKey? {
        if model.homeChangeRunning {
            return LocalizedStringKey("Gleich wieder möglich: Albumist passt gerade die Vorschläge an deine Änderung in „Dein Zuhause“ an.")
        }
        if model.analysisResetting {
            return askedOnTheCard
                ? LocalizedStringKey("„Ja“ geht, sobald die Analyse neu aufgebaut ist, denn danach plant Albumist deine Reisen neu.")
                : LocalizedStringKey("„Keine Reise“ geht, sobald die Analyse neu aufgebaut ist, denn danach plant Albumist deine Reisen neu.")
        }
        if model.execution.isRunning {
            return askedOnTheCard
                ? LocalizedStringKey("„Ja“ geht, sobald das Anlegen fertig ist, denn danach plant Albumist deine Reisen neu.")
                : LocalizedStringKey("„Keine Reise“ geht, sobald das Anlegen fertig ist, denn danach plant Albumist deine Reisen neu.")
        }
        if model.analysis.isRunning {
            return askedOnTheCard
                ? LocalizedStringKey("„Ja“ geht, sobald die Analyse fertig ist, denn danach plant Albumist deine Reisen neu.")
                : LocalizedStringKey("„Keine Reise“ geht, sobald die Analyse fertig ist, denn danach plant Albumist deine Reisen neu.")
        }
        return nil
    }

    /// A "Ja" makes this suggestion go away when the suggestions are made again (like every
    /// change in "Dein Zuhause"): back to the list.
    private func answerOftenHere(_ oftenHere: Bool) {
        Task {
            if await model.answerRecurringPlace(oftenHere, for: proposal), oftenHere { leave() }
        }
    }

    // MARK: The album

    /// The album card: what Albumist found among the user's albums, the user's pick, photos only
    /// suggested. Not for a plain new album: the line under the title says where it goes.
    private var showsAlbumCard: Bool {
        if !proposal.optionalAssetIDs.isEmpty || chosenAlbumText != nil { return true }
        guard let match else { return false }
        return match.status != .newAlbumRequired
    }

    private var albumCard: some View {
        Card {
            matchContent
            if !proposal.optionalAssetIDs.isEmpty {
                let count = proposal.optionalAssetIDs.count
                if match != nil { Divider() }
                // Says what the number is (design review N5: "Nur vorgeschlagen: 12").
                LabeledContent("Vielleicht passend") { Text("\(count) \(count.formatted()) Fotos") }
            }
        }
    }

    @ViewBuilder
    private var matchContent: some View {
        if let match {
            Group {
                Label {
                    Text(match.status.label).font(.headline)
                } icon: {
                    // A possible match gets a new album too: no check mark that reads as "done".
                    Image(systemName: [.newAlbumRequired, .possibleMatch].contains(match.status) ? "plus.rectangle.on.folder" : "checkmark.circle.fill")
                        .foregroundStyle(match.status.tint)
                }
                ForEach(Array(shownReasons(match).enumerated()), id: \.offset) { _, reason in
                    Text(ReasonText.text(reason)).font(.subheadline).foregroundStyle(.noteText)
                }
                // The other way for an album Albumist leaves alone, right below the hint that
                // says so. The hint sent the user to "Anpassen", which is behind "…" since P3-06
                // (second review): the card offers it itself, as a small text button like
                // "passt nicht" below. It opens "Anpassen", where the album is chosen.
                if let album = albumLeftAlone(match) {
                    Button { showAdjust = true } label: {
                        Text("Stattdessen „\(album)“ ergänzen …")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("proposal.addInstead")
                }
                if let choice = chosenAlbumText {
                    Label(choice, systemImage: "hand.point.up.left")
                        .font(.subheadline.weight(.semibold))
                }
                // "Passt nicht" names one album; with several albums the choice happens under "Album auswählen".
                if let best = match.best, best.isEditable, ![.newAlbumRequired, .multipleMatches].contains(match.status) {
                    // A possible match already gets a new album: the button only stops offering it.
                    let onlyOffered = match.status == .possibleMatch
                    Button { rejectingMatch = true } label: {
                        Group {
                            if onlyOffered {
                                Text("„\(best.albumTitle)“ nicht mehr anbieten")
                            } else {
                                Text("„\(best.albumTitle)“ passt nicht")
                            }
                        }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                        .disabled(busy)
                        .confirmationDialog("Dieses Album passt nicht?", isPresented: $rejectingMatch, titleVisibility: .visible) {
                            Button("Nicht mehr für diesen Vorschlag anbieten") {
                                Task { await model.rejectMatch(best.albumID, for: proposal) }
                            }
                        } message: {
                            if onlyOffered {
                                Text("Albumist legt ohnehin ein neues Album an und bietet es für diesen Vorschlag nicht mehr an. Am Album selbst ändert sich nichts.")
                            } else {
                                Text("Albumist merkt sich das und schlägt stattdessen ein neues oder ein anderes passendes Album vor. Am Album selbst ändert sich nichts.")
                            }
                        }
                }
            }
        }
    }

    /// "Albumist legt ein neues Album an" is not true any more once the user picked the
    /// album under "Anpassen"; "Deine Wahl" says what happens instead.
    private func shownReasons(_ match: MatchResult) -> [MatchReason] {
        guard case .extendExisting = model.decision(for: proposal) else { return match.reasons }
        return match.reasons.filter { if case .keptUnchangedUntilChosen = $0 { false } else { true } }
    }

    /// The album a possible match leaves alone until the user picks it, while the card says so
    /// ("Albumist legt ein neues Album an und ändert „X“ nicht"): "Stattdessen „X“ ergänzen …".
    private func albumLeftAlone(_ match: MatchResult) -> String? {
        shownReasons(match).lazy.compactMap { reason -> String? in
            if case .keptUnchangedUntilChosen(let album) = reason { return album }
            return nil
        }.first
    }

    /// The user's pick from "Anpassen", shown where Albumist could not decide alone (several
    /// albums, none clearly, or only a possible match).
    private var chosenAlbumText: String? {
        guard let match, [.multipleMatches, .ambiguous, .possibleMatch].contains(match.status) else { return nil }
        switch model.decision(for: proposal) {
        case .extendExisting(let id):
            let title = model.inventory[id]?.title ?? ""
            return String(localized: "Deine Wahl: „\(title)“ ergänzen")
        case .createNew:
            return String(localized: "Deine Wahl: neues Album")
        default:
            return nil
        }
    }

    // MARK: The two buttons and the menu

    /// "Nicht jetzt" and the main button, fixed at the bottom on the page's background, so the
    /// photos that scroll under it never show through its words. Side by side with the main
    /// button wider (draft E2: 1 to 1.4). At the accessibility text sizes only the main button,
    /// in reach without scrolling as in the preview's bar (P3-05): both, one above the other,
    /// took 267 of the small iPhone's 667 points at the largest size, and the page opened
    /// without the album's name (UI run 44852630315). "Nicht jetzt" is then in the page.
    private func actionBar(_ card: ProposalCardText) -> some View {
        Group {
            if needsFullAccess {
                // Nothing can be made before full access: the page's one filled button is
                // "Einstellungen öffnen" (`FullAccessCard`).
                notNowButton(card, beside: false)
            } else if typeSize.isAccessibilitySize {
                primaryButton(card, beside: false)
            } else {
                ActionBarLayout(spacing: Theme.Spacing.s) {
                    notNowButton(card, beside: true)
                    primaryButton(card, beside: true)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
        // Down to the screen's edge: no tab bar below it, and no photo shows under the home
        // indicator either. Above it the photos fade out (draft E2) instead of being cut.
        .background(ground.ignoresSafeArea(edges: .bottom)) // Design W3 H13: photo tint
        .background(alignment: .top) {
            LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom) // Design W3 H13: photo tint
                .frame(height: 28)
                .offset(y: -28)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // A container of its own: an identifier on a plain container is handed down to every
        // element inside (`EmptyLibraryCard`), and the buttons keep theirs. Read right after
        // the header, before the photos (the header goes first).
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
        .accessibilityIdentifier("proposal.bar")
    }

    /// Takes only the suggestion away; its photos and albums stay as they are (Scheibe 2).
    /// VoiceOver hears what it sets aside ("Nicht jetzt: „Kyoto, Oktober 2024“"), also where it
    /// reads the bar before the page's header; Voice Control knows it by its words too (review
    /// B, 6). `beside`: next to the main button, as tall as it (`barWords`).
    private func notNowButton(_ card: ProposalCardText, beside: Bool) -> some View {
        Button {
            model.setDecision(.reject, for: proposal)
            leave()
        } label: {
            Text("Nicht jetzt")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barWords.notNow = $0 }
                .frame(minHeight: beside ? barWords.tallest : nil)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(busy || !isCurrent)
        .accessibilityLabel(card.spokenNotNow)
        .accessibilityInputLabels([Text("Nicht jetzt"), card.spokenNotNow])
        .accessibilityIdentifier("proposal.notNow")
    }

    /// The one filled button of the page: what the suggestion needs next, in words that say
    /// what happens ("Album anlegen", "12 Fotos ergänzen", "Namen eingeben", "Album auswählen").
    /// VoiceOver hears the album it acts on with them (`ProposalCardText.spokenMainAction`), or
    /// what runs; Voice Control knows it by its words too (review B, 6). `beside`: next to
    /// "Nicht jetzt", as tall as it (`barWords`).
    private func primaryButton(_ card: ProposalCardText, beside: Bool) -> some View {
        let word = primaryTitle(card)
        let named = card.spokenMainAction ?? Text(word)
        let spoken = creating ? Text("Album wird angelegt") : preparing ? Text("Wird vorbereitet") : named
        return Button {
            primaryAction(card)
        } label: {
            if preparing || creating {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: beside ? barWords.tallest : nil)
                    .accessibilityHidden(true) // the button's label says what runs
            } else {
                Text(word)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barWords.main = $0 }
                    .frame(minHeight: beside ? barWords.tallest : nil)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        // One album at a time, also one made from a card meanwhile (`AppModel.createNow`).
        .disabled(busy || model.quickCreating != nil || !canAct(card) || !isCurrent)
        .accessibilityLabel(spoken)
        .accessibilityInputLabels([Text(word), named])
        .accessibilityIdentifier("proposal.create")
    }

    private func primaryTitle(_ card: ProposalCardText) -> LocalizedStringKey {
        switch card.outcome {
        case .needsName: "Namen eingeben"
        case .chooseAlbum: "Album auswählen"
        case .newAlbum: "Album anlegen"
        case .addsTo(_, _, let missing): "\(missing) \(missing.formatted()) Fotos ergänzen"
        case .alreadyIn: "Album so lassen"
        case .renames: "Album umbenennen"
        case .moves: "Album verschieben"
        }
    }

    /// An album without photos is no album: nothing to make once every photo was taken out.
    private func canAct(_ card: ProposalCardText) -> Bool {
        if case .newAlbum = card.outcome { return card.photoCount > 0 }
        return true
    }

    private func primaryAction(_ card: ProposalCardText) {
        switch card.outcome {
        case .needsName:
            // Opens the keyboard in the name field; nothing is chosen or created.
            nameFocused = true
            nameFieldVoiceOverFocus = true
        case .chooseAlbum:
            // Several albums fit (or none clearly): the user picks one, Albumist does not guess.
            showAdjust = true
        case .newAlbum:
            Task { await create(card) }
        case .addsTo, .alreadyIn, .renames, .moves:
            // An album of the user's changes only through the preview (Punkt 5).
            Task { await applyNow() }
        }
    }

    /// Whether "Album anlegen" makes the album at once on this stack: only on a tab's, where its
    /// banner shows (`NavigationRoot`).
    @Environment(\.quickCreateAtOnce) private var quickCreateAtOnce

    /// "Album anlegen" for a new album: made at once, with the banner to take it back (decision
    /// 7B), through the preview's own plan and run (`AppModel.createNow`). What may not skip the
    /// preview (personal content, whose photos the user may not have seen; a plan with something
    /// to point out, such as an album of the same name in the folder) goes through the preview
    /// from here, and so does every suggestion opened where no banner shows (a sheet over the
    /// tabs, such as a photo's "Info"). A suggestion that went meanwhile is not made again.
    private func create(_ card: ProposalCardText) async {
        guard isCurrent else { return }
        storeTypedName()
        guard quickCreateAtOnce, !card.isPersonal,
              QuickCreate.mayCreateAtOnce(proposal, decision: recommended, hidesPreview: card.hidesPreview) else {
            await applyNow()
            return
        }
        creating = true
        let outcome = await model.createNow(proposal)
        creating = false
        // This page is open already: the way to it that `createNow` asks for when the
        // suggestion is to be looked at is not needed (it would switch to the overview's tab).
        if outcome != .created, model.route == .suggestion(proposal.id) { model.route = nil }
        switch outcome {
        case .created:
            // Done: the banner "„Name“ angelegt · Widerrufen" shows where the user goes back to.
            leave()
        case .needsLook:
            // Its plan has something to point out: the preview says it.
            await applyNow()
        case .needsPurchase, .notNow, .failed:
            // The purchase sheet or a message says what happened; the suggestion stays open.
            break
        }
    }

    /// The name in the field of a place or group only the user can name is its name: stored, and
    /// in a new album chosen before under "Anpassen" too, whose stored name would win over the
    /// field ("Oma" chosen there, "Opa" typed here afterwards).
    private func storeTypedName() {
        guard proposal.requiresUserName else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setUserTitle(typed, for: proposal)
        if !typed.isEmpty, case .createNew(let title, let folderPath) = model.decision(for: proposal), title != typed {
            model.setDecision(.createNew(title: typed, folderPath: folderPath), for: proposal)
        }
    }

    /// Everything a suggestion offers besides its two buttons, behind "…" at the top right like
    /// "Album löschen" in Photos: first for the album ("Anpassen"), then for a trip (the
    /// workshop, "Keine Reise, hier bin ich öfter"). Each item is there, waits and says why
    /// exactly as its button on the page did before. Choosing suggestions to make together is
    /// "Auswählen" in their list, as in Photos (decision 9 of 18.11.).
    private var moreActions: some View {
        Menu {
            Section {
                Button { showAdjust = true } label: {
                    Label("Anpassen", systemImage: "slider.horizontal.3")
                }
                .disabled(busy)
                .accessibilityIdentifier("proposal.adjust")
            }
            if model.canReshape(proposal) || offersOftenHere {
                Section {
                    // Reise-Werkstatt (I07): only before Albumist made the trip's album.
                    if model.canReshape(proposal) {
                        Button { showWorkshop = true } label: {
                            Label("Reise aufteilen oder zusammenlegen", systemImage: "scissors")
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("proposal.reshapeTrip")
                    }
                    if offersOftenHere {
                        Button { confirmOftenHere = true } label: {
                            Label("Keine Reise, hier bin ich öfter", systemImage: "mappin.and.ellipse")
                            // Why it waits, as on the question card: a second Text in the label
                            // is the menu item's second line (screenshot 63b-trip-menu-analysis).
                            if let reason = Self.oftenHereWaitReason(model, askedOnTheCard: false) {
                                Text(reason)
                            }
                        }
                        .disabled(!model.canChangeHome || busy)
                        .accessibilityIdentifier("proposal.oftenHere")
                    }
                }
            }
        } label: {
            Label("Weitere Aktionen", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("proposal.more")
    }

    /// "Keine Reise, hier bin ich öfter": the same answer without being asked, for a place
    /// visited too rarely for the question (a semester abroad, a new second home). Not while
    /// the question card asks it.
    private var offersOftenHere: Bool {
        model.offersNotATrip(proposal)
    }

    // MARK: The preview

    /// The preview of "Album anlegen" is on the stack.
    private var showsDirect: Bool {
        guard let directPlan, let navigator else { return false }
        return navigator.path.contains(.prebuiltPlan(directPlan))
    }

    /// Opens the preview of this one suggestion (then the album exists in Photos once the user
    /// confirms there): an album of the user's to add to, one to keep, or a new album that may
    /// not skip the preview.
    private func applyNow(attempt: Int = 1) async {
        waiting = nil
        storeTypedName()
        let chosen = recommended
        let previous = model.decisions[proposal.id]
        previewSelection = model.selectForPreview([(proposal, chosen)])
        let basis = planBasis
        let request = PlanRequest(model: model, navigator: navigator)
        preparing = true
        let plan = await model.singlePlan(for: proposal)
        preparing = false
        guard let plan else {
            // Nothing to change (album already complete or kept as it is): the pick goes back,
            // and the suggestion closes if it still shows.
            endSelection()
            if navigator?.isShowing(request.mark) == true { leave() }
            return
        }
        offer(WaitingPlan(token: PlanToken(plan), request: request, chosen: chosen, previous: previous, basis: basis), attempt: attempt)
    }

    /// A preview of "Album anlegen" that is ready, or that waited for this tab, with the same
    /// checks both times (`PlanRequest`, `PlanBasis`): shown with its pick (made again after a
    /// wait); kept without the pick while another tab is chosen; made again once when the album
    /// list or the suggestion changed meanwhile (a second change says Albumist is busy);
    /// dropped when the user went elsewhere on this stack or chose otherwise for the suggestion.
    /// Whenever it is not shown, its pick goes back at once. Never pushed twice: `waiting`
    /// holds it only while it is not shown.
    private func offer(_ ready: WaitingPlan, attempt: Int) {
        var verdict = ready.request.verdict(model: model, navigator: navigator)
        if verdict == .show || verdict == .stale {
            // While the pick is on, the decision is the pick; while the plan waits, the one before.
            let expected = previewSelection == nil ? ready.previous : ready.chosen
            if model.decisions[proposal.id] != expected {
                verdict = .gone
            } else if planBasis != ready.basis {
                verdict = .stale
            }
        }
        if verdict == .show {
            if previewSelection == nil { previewSelection = model.selectForPreview([(proposal, ready.chosen)]) }
            if Navigator.push(.prebuiltPlan(ready.token), on: navigator, ifStill: ready.request.mark) == .pushed {
                directPlan = ready.token
                // The pick goes back when the preview leaves the path, also when this screen
                // goes along without seeing it (a pop to the root or back to an earlier screen,
                // the sheet closed), and after a plan whose step for this suggestion failed
                // (an applied suggestion was cleared by the execution and stays as it is).
                if let navigator, let selection = previewSelection {
                    navigator.onLeave(.prebuiltPlan(ready.token)) { [model] in model.endPreview(selection) }
                }
                return
            }
            verdict = .gone
        }
        endSelection()
        switch verdict {
        case .wait:
            waiting = ready
        case .busy:
            model.message = .busy
        case .stale:
            if attempt > 1 {
                model.message = .busy
            } else if planBasis.proposal != nil {
                // The spinner stays on until the new plan is made.
                preparing = true
                Task { await applyNow(attempt: attempt + 1) }
            }
            // Otherwise the analysis no longer has this suggestion: nothing is made from it.
        case .show, .gone:
            break
        }
    }

    /// The tab shows again: a preview that was ready meanwhile is offered now.
    private func showWaiting() {
        guard let ready = waiting, navigator?.showing == true else { return }
        waiting = nil
        offer(ready, attempt: 1)
    }

    /// The preview's pick goes back (`AppModel.endPreview`).
    private func endSelection() {
        if let selection = previewSelection { model.endPreview(selection) }
        previewSelection = nil
    }

    /// A preview of "Album anlegen" kept for this screen (`waiting`).
    private struct WaitingPlan {
        let token: PlanToken
        let request: PlanRequest
        /// The decision the preview selects, and the one it replaced.
        let chosen: ProposalDecision
        let previous: ProposalDecision?
        let basis: PlanBasis
    }

    /// What a plan of this suggestion is made from besides the album list (`PlanRequest`), as
    /// far as the app can see it changing: the suggestion as the analysis has it now, the photos
    /// taken out of it, its name and the folder for new albums.
    private struct PlanBasis: Equatable {
        let proposal: AlbumProposal?
        let removed: Set<AssetID>?
        let title: String?
        let rootFolder: String
    }

    private var planBasis: PlanBasis {
        PlanBasis(proposal: model.proposals.first { $0.id == proposal.id },
                  removed: model.removedFromProposals[proposal.id],
                  title: model.userTitles[proposal.id],
                  rootFolder: model.settings.rootFolderTitle)
    }
}

/// The page zooms out of the card it was opened from and back into it (design E2); opened any
/// other way, it is pushed as usual.
private struct ZoomedFromCard: ViewModifier {
    var source: AlbumistID
    var namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: source, in: namespace))
        } else {
            content
        }
    }
}

/// Two buttons side by side, the second (the main one) wider: 1.4 parts to 1, as in draft E2.
/// A long main word ("1.354 Fotos ergänzen") still takes two lines on most iPhones: the bar is
/// as tall as the taller button, the words of both get the taller word's height
/// (`BarWordHeights`), and both sit centred on the bar (review B of design wave 1, 7).
private struct ActionBarLayout: Layout {
    var spacing: CGFloat
    /// The main button's share of the width.
    private let mainShare: CGFloat = 1.4 / 2.4

    private func widths(_ total: CGFloat) -> (first: CGFloat, second: CGFloat) {
        let available = max(0, total - spacing)
        let second = (available * mainShare).rounded()
        return (available - second, second)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(spacing, +)
        let total = proposal.width.map { $0.isFinite ? $0 : ideal } ?? ideal
        let (first, second) = widths(total)
        let height = max(subviews[0].sizeThatFits(ProposedViewSize(width: first, height: nil)).height,
                         subviews[1].sizeThatFits(ProposedViewSize(width: second, height: nil)).height)
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (first, second) = widths(bounds.width)
        // Centred on the bar's height: each button style keeps a height of its own.
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: first, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + first + spacing, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: second, height: bounds.height))
    }
}

/// The measured heights of the two words in the open suggestion's bar
/// (`ProposalDetailView.barWords`): side by side, both words get the taller one's height.
private struct BarWordHeights: Equatable {
    var notNow: CGFloat = 0
    var main: CGFloat = 0

    /// The taller word's height; 0 until a word was measured.
    var tallest: CGFloat { max(notNow, main) }
}

/// Choose between creating a new album and using one of the matching albums.
struct AdjustProposalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var proposal: AlbumProposal
    /// For a place or group only the user can name: the suggestion's own name field. "Titel"
    /// is the same text, so a name typed there is here, and a name changed here is there after
    /// closing, also with "Abbrechen" (owner's device test 18.11.: "Dahoam" typed in the
    /// suggestion, "Titel" here was empty). Nothing is stored before an album is chosen.
    var name: Binding<String>?
    @State private var ownTitle = ""

    /// The text of "Titel".
    private var title: Binding<String> { name ?? $ownTitle }

    private var candidates: [MatchCandidate] {
        guard let match = model.match(for: proposal) else { return [] }
        return ([match.best].compactMap { $0 } + match.alternatives).filter(\.isEditable)
    }

    var body: some View {
        Form {
            // Choosing only selects; nothing is created here (design review W3).
            Section {
                TextField("Titel", text: title)
                    .textInputAutocapitalization(proposal.requiresUserName ? .words : nil)
                    .accessibilityIdentifier("adjust.titleField")
                Button("Neues Album wählen") {
                    let trimmed = title.wrappedValue.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { model.setUserTitle(trimmed, for: proposal) }
                    model.setDecision(.createNew(title: trimmed.isEmpty ? nil : trimmed, folderPath: nil), for: proposal)
                    dismiss()
                }
                .disabled(proposal.requiresUserName && title.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Neues Album")
            } footer: {
                // The suggestion's own button makes it ("Album anlegen", decision 7B).
                Text("Angelegt wird erst mit „Album anlegen“.")
            }
            Section {
                ForEach(candidates, id: \.albumID) { candidate in
                    Button {
                        model.setDecision(.extendExisting(candidate.albumID), for: proposal)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(candidate.albumTitle)
                            Text("\(candidate.metrics.intersection) \(candidate.metrics.intersection.formatted()) gemeinsame Fotos").font(.footnote).foregroundStyle(.noteText)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                NavigationLink("Anderes Album wählen") {
                    AlbumPickerView(excluded: Set(candidates.map(\.albumID))) { id in
                        model.setDecision(.extendExisting(id), for: proposal)
                        dismiss()
                    }
                }
            } header: {
                Text("Vorhandenes Album ergänzen")
            } footer: {
                // An album of the user's changes only after the preview (Punkt 5).
                Text("Ergänzt wird erst, wenn du in der Vorschau bestätigst.")
            }
        }
        .navigationTitle("Anpassen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
        }
        .onAppear {
            // With the suggestion's name field, "Titel" already holds what was typed there.
            if name == nil { ownTitle = model.userTitles[proposal.id] ?? (proposal.requiresUserName ? "" : proposal.title) }
        }
    }
}

/// Every album Albumist may change, searchable; used when no suggested album fits.
struct AlbumPickerView: View {
    @Environment(AppModel.self) private var model
    var excluded: Set<CollectionID> = []
    var onPick: (CollectionID) -> Void
    @State private var query = ""

    private var albums: [CollectionSnapshot] {
        let all = model.inventory.albums.filter { $0.isEditableAlbum && !excluded.contains($0.id) }
        let filtered = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            // The system's empty search state (design review N12).
            if albums.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if albums.isEmpty {
                Text("Noch keine Alben").foregroundStyle(.secondary)
            }
            ForEach(albums) { album in
                Button {
                    onPick(album.id)
                } label: {
                    HStack {
                        Label(album.title, systemImage: "rectangle.stack")
                        Spacer()
                        Text(album.assetIDs.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $query, prompt: Text("Album suchen"))
        .navigationTitle("Album wählen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The photos of one suggestion by day, as Photos shows its days (design E2), in the grid
/// "Unsortiert" has too (`PhotoGrid`, design wave 3, DS-06b): a header with the day and its
/// count, then the day's photos edge to edge with 2 pt between them, three in a row until two
/// fingers or VoiceOver's zoom change that; photos without a date last. A tap opens a photo
/// large, zooming out of its tile and back (`PhotoViewer`); while the suggestion picks photos
/// ("Auswählen") a tap ticks it, and a finger drawn sideways ticks the photos it crosses.
/// Photos taken out of a suggestion stay in the library and in other suggestions.
struct ProposalPhotosView: View {
    @Environment(AppModel.self) private var model
    /// The suggestion's photos by day (`AppModel.proposalPhotoDays`).
    var days: [PhotoDay]
    var selecting: Bool
    @Binding var selected: Set<AssetID>
    /// Every photo is a sensitive document: "Vorschau ausgeblendet" until "Fotos anzeigen".
    var hidden: Bool
    /// The photos do not open while the suggestion is being made (its preview would be pushed
    /// under them).
    var disabled: Bool
    /// The suggestion is still the analysis' (`ProposalDetailView.isCurrent`): a photo's long
    /// press offers nothing for one that went, whose photos can no longer be taken out of it
    /// (review C2 of design wave 2, N4).
    var isCurrent: Bool
    var reveal: () -> Void
    /// A photo's long press chose "Aus Vorschlag entfernen": the suggestion asks first, on its
    /// scroll view (`photoRemovalQuestion`), and takes it out as "Auswählen" takes several out.
    var askToRemove: (AssetID) -> Void
    @State private var viewing: PhotoViewer.Start?
    @Namespace private var zoom
    /// The days as the grid's sections, made again only when the page hands over other days.
    @State private var grid = PhotoGridSectionsCache()

    var body: some View {
        Group {
            if hidden {
                Card {
                    Label("Vorschau ausgeblendet", systemImage: "eye.slash")
                        .font(.headline)
                    Button("Fotos anzeigen", action: reveal)
                        .buttonStyle(CardActionButtonStyle())
                }
                .padding(.horizontal, Theme.Spacing.l)
                // As far below the page's cards as a day's title is (`PhotoGridHeader`).
                .padding(.top, Theme.Spacing.m)
            } else {
                PhotoGrid(sections: sections[...], place: .suggestion, selecting: selecting, selection: $selected,
                          available: !disabled && isCurrent, disabled: disabled, zoom: zoom,
                          identifier: "proposalPhotos.photo") { id in
                    open(id)
                } perform: { item, id in
                    perform(item, on: id)
                }
            }
        }
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
                .navigationTransition(.zoom(sourceID: start.id, in: zoom))
        }
    }

    /// The days with each photo's date and time on the clock where it was taken, as its day's
    /// header says it (what VoiceOver says of a photo), made again when the facts or the iPhone's
    /// clock it is read from change (review L12).
    private var sections: [PhotoGridSection] {
        grid.sections(for: days, facts: model.factsVersion, zone: .current) {
            let facts = model.factsByID
            return PhotoGridSection.sections(days) { facts[$0]?.wallClock(or: .current) }
        }
    }

    /// The photo large, the suggestion's others to swipe through (a snapshot: a photo ignored
    /// from its details must not reshuffle the pages).
    private func open(_ id: AssetID) {
        viewing = PhotoViewer.Start(id: id, ids: days.flatMap(\.ids))
    }

    /// An item of the photo's long press: "Ansehen" as a tap, "Aus Vorschlag entfernen" asked
    /// first.
    private func perform(_ item: PhotoMenu.Item, on id: AssetID) {
        switch item {
        case .view: open(id)
        case .removeFromSuggestion: askToRemove(id)
        // Not offered for a suggestion's photos (`PhotoMenu`): they stay behind "Ansehen" › "Info".
        case .addToAlbum, .ignore, .stopIgnoring: break
        }
    }
}

/// Symbol and text close together, like a status line (the list's own label style
/// puts the symbol in a wide icon column).
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
