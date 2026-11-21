import SwiftUI
import AlbumistCore
import AlbumistEngine

/// The start page "Vorschläge" under its ring card, as `StartPage` decides it (design wave 1,
/// drafts E1, E6, E7): the photo mosaic of the first analysis, one big part ("Schon gefunden",
/// "Dein Startpaket" or "Neue Reisen"), the rows of cards with "Alle 41", the entry to "Deine
/// Welt" under the trips, one calm card that says why when nothing is open, and "Alle
/// Vorschläge" at the end.
///
/// Its own view with plain values from the page above, so the analysis' many changes do not
/// redraw the cards: it reads the suggestions, the decisions and the purchases. What it keeps
/// for one visit (`StartVisit`) begins afresh each time the page appears. The shelves run from
/// edge to edge; everything else keeps the page's margin.
struct StartSections: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    @Environment(Navigator.self) private var navigator: Navigator?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    /// The card for an empty library is shown above: it explains the empty page itself.
    var libraryHint: Bool
    /// The first analysis went through once (`AppModel.analysedOnce`).
    var analysedOnce: Bool
    /// The photo mosaic of the first analysis is shown (`AppModel.showsScanShow`).
    var showsMosaic: Bool
    /// The suggestions are being made anew (`AppModel.suggestionsRebuilding`).
    var rebuilding: Bool
    /// An analysis runs that may bring suggestions (`AppModel.analysisMayBringSuggestions`).
    var analysing: Bool

    @State private var visit = StartVisit()
    /// The suggestion whose preview ("Ergänzen …") is being made.
    @State private var previewing: AlbumistID?
    /// The app went to the background since: its return begins a new visit.
    @State private var wasInBackground = false

    /// At the accessibility text sizes a row is one column of whole cards (draft E7): three of
    /// them, "Alle 41" shows the rest.
    private static let rowLimitAtLargestText = 3

    var body: some View {
        // How often the page is drawn, for the main thread's stall lines in UI runs.
        let _ = MainThreadWatch.shared.count("start page body")
        let page = makePage(for: visit)
        let byID = Dictionary(model.proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(page.sections) { section in
                self.section(section, page: page, proposals: byID)
            }
        }
        .onAppear {
            // A new visit, but not under a swipe back that has not ended: the page appears when
            // the swipe begins, while the screen above is still on the path and a preview's
            // picks are still chosen; the visit would have no "Dein Startpaket" until the swipe
            // ends (review A of design wave 1).
            if navigator?.path.isEmpty != false { beginVisit() }
        }
        // Back on top: the swipe back ended (the preview's picks are given back by then), Back,
        // or the tab tapped again.
        .onChange(of: navigator?.path.isEmpty ?? true) { _, onTop in
            if onTop { beginVisit() }
        }
        // The app opened again from the background is a new visit too.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
            case .active where wasInBackground:
                wasInBackground = false
                if navigator?.path.isEmpty != false { beginVisit() }
            default:
                break
            }
        }
        .onChange(of: page) { _, shown in visit.saw(shown) }
        // "Widerrufen" on the banner, or the history, took back a plan a card made here: the
        // card says "Anlegen" again.
        .onChange(of: model.undonePlans) { _, plans in visit.undone(plans) }
        // The banner "„Name“ angelegt" for a card tapped here says "Angelegt" on it, also when
        // the album was made only after the purchase sheet (`continueQuickCreate`).
        .onChange(of: model.quickCreateBanner?.id) { _, _ in
            if let banner = model.quickCreateBanner { visit.announced(banner.proposalID, by: banner.plan.id) }
        }
    }

    /// A new visit (`StartVisit`), which remembers at once what it shows (whatever runs first,
    /// this or a change of the page).
    private func beginVisit() {
        var fresh = StartVisit(lastMade: model.lastAlbumsMade)
        fresh.saw(makePage(for: fresh))
        visit = fresh
    }

    /// How many albums "Dein Startpaket" may hold now (`StartPage.starterSetLimit`).
    private var starterSetLimit: Int {
        StartPage.starterSetLimit(unlocked: purchases.isUnlocked || Purchases.unlockedForUITests,
                                  freeAlbumsLeft: purchases.remainingFreeAlbums)
    }

    private func makePage(for visit: StartVisit) -> StartPage {
        let limit = starterSetLimit
        return model.startPage(visit: visit, libraryHint: libraryHint, starterSet: model.starterSet(limit: limit),
                               starterSetLimit: limit, analysedOnce: analysedOnce, showsMosaic: showsMosaic,
                               rebuilding: rebuilding, analysing: analysing)
    }

    /// "Dein Startpaket": the preview of the set, each album picked for the preview only.
    /// Leaving it without creating gives every pick back (`AppModel.endPreview`), whichever way
    /// it goes: Back, the tab tapped again, this page going along. A second tap pushes nothing.
    private func openStarterPreview(_ set: [AlbumProposal]) {
        guard !set.isEmpty, let navigator else { return }
        let selection = model.selectForPreview(set.map { ($0, model.recommendedDecision(for: $0)) })
        guard navigator.push(.starterPlan(selection)) else {
            model.endPreview(selection)
            return
        }
        navigator.onLeave(.starterPlan(selection)) { [model] in model.endPreview(selection) }
    }

    @ViewBuilder
    private func section(_ section: StartPage.Section, page: StartPage, proposals: [AlbumistID: AlbumProposal]) -> some View {
        switch section {
        case .mosaic:
            ScanShow()
                .padding(.horizontal, Theme.Spacing.l)
        case .earlyTrips(let ids):
            bigCards(Text("Schon gefunden"), ids: ids, page: page, proposals: proposals)
                .accessibilityIdentifier("startPage.earlyTrips")
        case .newTrips(let ids):
            bigCards(Text("Neue Reisen"), ids: ids, page: page, proposals: proposals)
                .accessibilityIdentifier("startPage.newTrips")
        case .starterSet(let ids):
            // What is left of the set shown in this visit (`StartPage`).
            let set = ids.compactMap { proposals[$0] }
            StarterSetCard(set: set) { openStarterPreview(set) }
                .padding(.horizontal, Theme.Spacing.l)
        case .row(let row):
            self.row(row, page: page, proposals: proposals)
        case .atlas:
            // "Deine Welt" under the trips; the map strand draws the entry itself.
            AtlasTeaser(onOpen: { Navigator.push(.atlas, on: navigator) })
                .accessibilityIdentifier("startPage.atlas")
                .padding(.horizontal, Theme.Spacing.l)
        case .caughtUp:
            StartQuietCard(title: Text("Alles erledigt"), symbol: "checkmark.circle",
                           text: Text("Neue Vorschläge kommen von selbst, sobald du neue Fotos machst."))
                .accessibilityIdentifier("startPage.caughtUp")
                .padding(.horizontal, Theme.Spacing.l)
        case .rebuilding:
            StartQuietCard(title: Text("Wird neu berechnet"), symbol: "arrow.triangle.2.circlepath",
                           text: Text("Vorschläge erscheinen hier, sobald Albumist sie findet."))
                .accessibilityIdentifier("startPage.rebuilding")
                .padding(.horizontal, Theme.Spacing.l)
        case .noSuggestionsYet(let running):
            StartQuietCard(title: Text("Noch keine Vorschläge"), symbol: "sparkles",
                           text: running ? Text("Vorschläge erscheinen hier, sobald Albumist sie findet.")
                               : Text("Neue Vorschläge kommen von selbst, sobald du neue Fotos machst."))
                .accessibilityIdentifier("startPage.noSuggestionsYet")
                .padding(.horizontal, Theme.Spacing.l)
        case .allSuggestions(let all):
            StartAllSuggestionsRow(all: all) { Navigator.push(.proposals, on: navigator) }
                .padding(.horizontal, Theme.Spacing.l)
        }
    }

    /// "Schon gefunden" or "Neue Reisen": the cards across the page, under each other.
    private func bigCards(_ title: Text, ids: [AlbumistID], page: StartPage, proposals: [AlbumistID: AlbumProposal]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            StartSectionHeader(title: title)
            ForEach(ids.compactMap { proposals[$0] }) { proposal in
                card(proposal, page: page, style: .large)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .accessibilityElement(children: .contain)
    }

    /// One area: its title with "Alle 41", then the cards side by side (one column at the
    /// accessibility sizes); a single card goes across the page.
    private func row(_ row: StartPage.Row, page: StartPage, proposals: [AlbumistID: AlbumProposal]) -> some View {
        let cards = row.cards.compactMap { proposals[$0] }
        let shown = typeSize.isAccessibilitySize ? Array(cards.prefix(Self.rowLimitAtLargestText)) : cards
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            StartSectionHeader(title: Text(row.area.title), all: row.showsAll ? row.openCount : nil,
                               allIdentifier: "startPage.all.\(row.area.rawValue)") {
                Navigator.push(.areaProposals(row.area), on: navigator)
            }
            .padding(.horizontal, Theme.Spacing.l)
            if shown.count == 1, let only = shown.first {
                card(only, page: page, style: .large)
                    .padding(.horizontal, Theme.Spacing.l)
            } else {
                CardShelf(count: 2) {
                    ForEach(shown) { proposal in
                        card(proposal, page: page, style: .compact)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startPage.row.\(row.area.rawValue)")
    }

    private func card(_ proposal: AlbumProposal, page: StartPage, style: PhotoCardStyle) -> some View {
        let text = model.proposalCard(for: proposal)
        let creating = model.quickCreating
        return StartProposalCard(
            proposal: proposal, text: text, covers: text.hidesPreview ? [] : model.proposalCoverIDs(for: proposal),
            made: page.made.contains(proposal.id),
            working: creating == proposal.id || previewing == proposal.id,
            // One album at a time (`createNow`): the other cards wait meanwhile.
            waits: (creating != nil && creating != proposal.id) || (previewing != nil && previewing != proposal.id),
            style: style, onOpen: { open(proposal) }, onAction: { perform(text.action, on: proposal) })
        .quickCreateMomentSource(proposal.id, aspectRatio: style == .large ? 2 : 3.0 / 2.0) // Design W2 H6: moment source
    }

    // MARK: Actions

    /// The card itself opens the suggestion, as "Benennen …" and "Ansehen …" do.
    private func open(_ proposal: AlbumProposal) {
        Navigator.push(.proposal(ProposalRef(proposal)), on: navigator)
    }

    /// Whether "Anlegen" makes the album at once on this stack: only on a tab's, where its banner
    /// shows (`NavigationRoot`).
    @Environment(\.quickCreateAtOnce) private var quickCreateAtOnce

    private func perform(_ action: ProposalCardAction, on proposal: AlbumProposal) {
        switch action {
        case .create:
            // 7B: made at once, then the banner "„Name“ angelegt · Widerrufen" (`createNow`).
            // The card keeps its place from the tap on; while the album is made it shows its
            // work, then "Angelegt", which it keeps until the plan is taken back
            // (`StartVisit.made`). What cannot be made at once opens its page, the purchase
            // sheet or a message (`createNow`), and the card offers "Anlegen" again.
            guard model.quickCreating == nil, previewing == nil else { return }
            // Where no banner shows (a sheet's own stack), the suggestion opens instead.
            guard quickCreateAtOnce else {
                open(proposal)
                return
            }
            visit.create(proposal.id)
            Task {
                guard await model.createNow(proposal) == .created else { return }
                let banner = model.quickCreateBanner
                visit.made(proposal.id, by: banner?.proposalID == proposal.id ? banner?.plan.id : nil)
            }
        case .add:
            // The user's own album changes: through the preview first (Punkt 5).
            guard model.quickCreating == nil, previewing == nil else { return }
            previewing = proposal.id
            Task {
                await preview(proposal)
                previewing = nil
            }
        case .name, .look:
            open(proposal)
        }
    }

    /// The preview of this one suggestion, as "Album ergänzen" on its page makes it: selected
    /// only while the preview is open, pushed only if this page is still the one on top. The
    /// albums changed meanwhile: made once more, then said to be busy, as on the page.
    private func preview(_ proposal: AlbumProposal, attempt: Int = 1) async {
        let request = PlanRequest(model: model, navigator: navigator)
        let chosen = model.decision(for: proposal)
        let pick = chosen.isAccepted ? chosen : model.recommendedDecision(for: proposal)
        let selection = model.selectForPreview([(proposal, pick)])
        guard let plan = await model.singlePlan(for: proposal) else {
            // Nothing to change after all (the album holds every photo by now): its page says
            // what there is, if this page is still the one on top (review A of design wave 1).
            model.endPreview(selection)
            if model.message == nil {
                Navigator.push(.proposal(ProposalRef(proposal)), on: navigator, ifStill: request.mark)
            }
            return
        }
        switch request.verdict(model: model, navigator: navigator) {
        case .show:
            let token = PlanToken(plan)
            if Navigator.push(.prebuiltPlan(token), on: navigator, ifStill: request.mark) == .pushed, let navigator {
                navigator.onLeave(.prebuiltPlan(token)) { [model] in model.endPreview(selection) }
            } else {
                model.endPreview(selection)
            }
        case .busy:
            model.endPreview(selection)
            model.message = .busy
        case .stale:
            model.endPreview(selection)
            if attempt > 1 {
                model.message = .busy
            } else {
                await preview(proposal, attempt: attempt + 1)
            }
        case .wait, .gone:
            // Another tab, or another screen on this one meanwhile: nothing is pushed there,
            // the card can be tapped again.
            model.endPreview(selection)
        }
    }
}

/// A section's title ("Reisen", "Schon gefunden") with "Alle 41" at the side, below it at the
/// accessibility text sizes.
struct StartSectionHeader: View {
    var title: Text
    var all: Int?
    /// The identifier of "Alle 41" (UI tests); on the button only, not on the title too.
    var allIdentifier = ""
    var onAll: () -> Void = {}

    var body: some View {
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            title
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let all {
                Spacer(minLength: Theme.Spacing.s)
                Button(action: onAll) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Alle \(all.formatted())")
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(allIdentifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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

    var body: some View {
        PhotoCard(coverIDs: covers, title: Text(verbatim: text.title), subtitle: text.styledSubtitle,
                  hidesPreview: text.hidesPreview, aspectRatio: style == .large ? 2 : 3.0 / 2.0, style: style,
                  placeholderSymbol: proposal.kind.area.symbol, onOpen: onOpen) {
            button
        }
        .accessibilityIdentifier("suggestion.card.\(made ? "made" : text.action.kind)")
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

/// "Dein Startpaket" (draft E1): the photos of its best albums, what it is, and the one filled
/// button of the page. Its preview shows every album before anything is made.
struct StarterSetCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    @Environment(\.colorSchemeContrast) private var contrast
    var set: [AlbumProposal]
    var onStart: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.largeCard, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // One cover per album, best first; tiles whose photo is not sharp try the ones after.
            StarterSetMosaic(ids: set.compactMap { model.proposalCoverIDs(for: $0).first })
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.top, Theme.Spacing.m)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Dein Startpaket")
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Die \(set.count) besten Alben aus deiner Mediathek. Du siehst vorher genau, was passiert.")
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onStart) {
                    if purchases.isUnlocked {
                        Text("\(set.count) Alben anlegen")
                    } else {
                        Text("\(set.count) Alben kostenlos anlegen")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, Theme.Spacing.s)
                .accessibilityIdentifier("starterSet.create")
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startPage.starterSet")
    }
}

/// Nothing is open: one calm card that says why instead of empty rows ("Alles erledigt", "Wird
/// neu berechnet", "Noch keine Vorschläge"). Read as one element; the way to every suggestion is
/// "Alle Vorschläge" at the end of the page.
struct StartQuietCard: View {
    var title: Text
    var symbol: String
    var text: Text

    var body: some View {
        Card {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.headline)
            text
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Alle Vorschläge" at the end of the page (second review of the start page): the way to every
/// suggestion, also those of an area without an open one, a single one and those set aside with
/// "Nicht jetzt"; with their number and what the area list said before ("12 davon in deinen
/// Alben", "Wird neu berechnet"). A row like the system's lists: the symbol, the words, the
/// number at the end, the chevron; at the accessibility text sizes the words go below.
struct StartAllSuggestionsRow: View {
    var all: StartPage.AllSuggestions
    var onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        Button(action: onOpen) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack {
                            IconTile(systemName: "rectangle.stack", tint: Theme.accent)
                            Spacer(minLength: Theme.Spacing.s)
                            count
                            chevron
                        }
                        words
                    }
                } else {
                    HStack(spacing: Theme.Spacing.m) {
                        IconTile(systemName: "rectangle.stack", tint: Theme.accent)
                        words
                        Spacer(minLength: Theme.Spacing.s)
                        count
                        chevron
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(RingCardRowButtonStyle())
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the row gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("startPage.allSuggestions")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Alle Vorschläge")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
            Group {
                if all.rebuilding {
                    Text("Wird neu berechnet")
                } else if all.inYourAlbums > 0 {
                    // The area list's words before design wave 1.
                    Text("\(all.inYourAlbums) davon in deinen Alben")
                }
            }
            .font(.footnote)
            .foregroundStyle(.noteText)
            .monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var count: some View {
        Text(all.total.formatted())
            .font(.body)
            .foregroundStyle(.noteText)
            .monospacedDigit()
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
