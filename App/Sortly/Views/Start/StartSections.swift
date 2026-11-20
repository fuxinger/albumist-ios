import SwiftUI
import SortlyCore
import SortlyEngine

/// The start page "Vorschläge" under its ring card, as `StartPage` decides it (design wave 1,
/// drafts E1, E6, E7): the photo mosaic of the first analysis, one big part ("Schon gefunden",
/// "Dein Startpaket" or "Neue Reisen"), the rows of cards with "Alle 41", the entry to "Deine
/// Welt" under the trips, or one calm card when nothing is open.
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
    /// The card for an empty library is shown above: it explains the empty page itself.
    var libraryHint: Bool
    /// The first analysis went through once (`AppModel.analysedOnce`).
    var analysedOnce: Bool
    /// The photo mosaic of the first analysis is shown (`AppModel.showsScanShow`).
    var showsMosaic: Bool

    @State private var visit = StartVisit()
    /// The suggestion whose preview ("Ergänzen …") is being made.
    @State private var previewing: SortlyID?

    /// At the accessibility text sizes a row is one column of whole cards (draft E7): three of
    /// them, "Alle 41" shows the rest.
    private static let rowLimitAtLargestText = 3

    var body: some View {
        let starterSet = model.starterSet(limit: starterSetLimit)
        let page = makePage(for: visit, starterSetSize: starterSet.count)
        let byID = Dictionary(model.proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(page.sections) { section in
                self.section(section, page: page, proposals: byID, starterSet: starterSet)
            }
        }
        .onAppear {
            // A new visit, which remembers at once what it shows (whatever runs first on
            // appearing, this or a change of the page).
            var fresh = StartVisit(lastMade: model.lastAlbumsMade)
            fresh.saw(makePage(for: fresh, starterSetSize: model.starterSet(limit: starterSetLimit).count))
            visit = fresh
        }
        .onChange(of: page) { _, shown in visit.saw(shown) }
    }

    /// How many albums "Dein Startpaket" may hold now (`StartPage.starterSetLimit`).
    private var starterSetLimit: Int {
        StartPage.starterSetLimit(unlocked: purchases.isUnlocked || Purchases.unlockedForUITests,
                                  freeAlbumsLeft: purchases.remainingFreeAlbums)
    }

    private func makePage(for visit: StartVisit, starterSetSize: Int) -> StartPage {
        model.startPage(visit: visit, libraryHint: libraryHint, starterSetSize: starterSetSize,
                        analysedOnce: analysedOnce, showsMosaic: showsMosaic)
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
    private func section(_ section: StartPage.Section, page: StartPage, proposals: [SortlyID: AlbumProposal],
                         starterSet: [AlbumProposal]) -> some View {
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
        case .starterSet:
            StarterSetCard(set: starterSet) { openStarterPreview(starterSet) }
            .padding(.horizontal, Theme.Spacing.l)
        case .row(let row):
            self.row(row, page: page, proposals: proposals)
        case .atlas:
            // "Deine Welt" under the trips; the map strand draws the entry itself.
            AtlasTeaser(onOpen: { Navigator.push(.atlas, on: navigator) })
                .accessibilityIdentifier("startPage.atlas")
                .padding(.horizontal, Theme.Spacing.l)
        case .caughtUp:
            StartCaughtUpCard()
                .padding(.horizontal, Theme.Spacing.l)
        }
    }

    /// "Schon gefunden" or "Neue Reisen": the cards across the page, under each other.
    private func bigCards(_ title: Text, ids: [SortlyID], page: StartPage, proposals: [SortlyID: AlbumProposal]) -> some View {
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
    private func row(_ row: StartPage.Row, page: StartPage, proposals: [SortlyID: AlbumProposal]) -> some View {
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
        let text = model.startCardText(for: proposal)
        let creating = model.quickCreating
        return StartProposalCard(
            proposal: proposal, text: text, covers: text.hidesPreview ? [] : model.startCardCovers(for: proposal),
            made: page.made.contains(proposal.id),
            working: creating == proposal.id || previewing == proposal.id,
            // One album at a time (`createNow`): the other cards wait meanwhile.
            waits: (creating != nil && creating != proposal.id) || (previewing != nil && previewing != proposal.id),
            style: style, onOpen: { open(proposal) }, onAction: { perform(text.action, on: proposal) })
    }

    // MARK: Actions

    /// The card itself opens the suggestion, as "Benennen …" and "Ansehen …" do.
    private func open(_ proposal: AlbumProposal) {
        Navigator.push(.proposal(ProposalRef(proposal)), on: navigator)
    }

    private func perform(_ action: ProposalCardAction, on proposal: AlbumProposal) {
        switch action {
        case .create:
            // 7B: made at once, then the banner "„Name“ angelegt · Widerrufen" (`createNow`).
            // The card keeps its place and says "Angelegt" (`StartVisit.created`). What cannot
            // be made at once opens its page, the purchase sheet or a message (`createNow`).
            guard model.quickCreating == nil, previewing == nil else { return }
            visit.create(proposal.id)
            Task { await model.createNow(proposal) }
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
            // what there is.
            model.endPreview(selection)
            if model.message == nil { open(proposal) }
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
/// Switch Control, keyboard); the card is the container the UI tests find by its identifier.
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
        PhotoCard(coverIDs: covers, title: Text(verbatim: text.title), subtitle: subtitle,
                  hidesPreview: text.hidesPreview, aspectRatio: style == .large ? 2 : 3.0 / 2.0, style: style,
                  placeholderSymbol: proposal.kind.area.symbol, onOpen: onOpen) {
            button
        }
        .accessibilityIdentifier("suggestion.card.\(made ? "made" : kind)")
    }

    /// The line under the name (Punkt 3), with the parts the drafts mark: "Name fehlt" in the
    /// warning colour, the lock before "Persönlicher Inhalt".
    private var subtitle: Text? {
        let parts = text.subtitleParts
        guard let first = parts.first else { return nil }
        switch text.status {
        case .nameMissing:
            let missing = Text(verbatim: first).foregroundStyle(Theme.tint(for: .documents))
            return joined(missing, parts.dropFirst())
        case .personal:
            guard parts.count == 2 else { return Text(verbatim: parts.joined(separator: " · ")) }
            let lock = Image(systemName: "lock.fill")
            let personal = Text(verbatim: parts[1])
            let marked = Text("\(lock) \(personal)")
            let count = Text(verbatim: first)
            return Text("\(count) · \(marked)")
        default:
            return Text(verbatim: parts.joined(separator: " · "))
        }
    }

    private func joined(_ head: Text, _ rest: ArraySlice<String>) -> Text {
        guard !rest.isEmpty else { return head }
        let tail = Text(verbatim: rest.joined(separator: " · "))
        return Text("\(head) · \(tail)")
    }

    private var kind: String {
        switch text.action {
        case .create: "create"
        case .add: "add"
        case .name: "name"
        case .look: "look"
        }
    }

    @ViewBuilder
    private var button: some View {
        if made {
            // Made from this card in this visit (7B): it keeps its place; "Widerrufen" is on
            // the banner. Says what happened, nothing to tap.
            StartMadeLabel()
        } else {
            Button(action: onAction) {
                ZStack {
                    // The word keeps the button's width while the spinner shows.
                    actionWord.opacity(working ? 0 : 1)
                    if working {
                        ProgressView()
                            .accessibilityHidden(true) // the button's word says what runs
                    }
                }
            }
            .buttonStyle(CardActionButtonStyle())
            .disabled(working || waits)
            .accessibilityLabel(actionWord)
        }
    }

    private var actionWord: Text {
        switch text.action {
        case .create: Text("Anlegen")
        case .add: Text("Ergänzen …")
        case .name: Text("Benennen …")
        case .look: Text("Ansehen …")
        }
    }
}

/// "✓ Angelegt" where the card's button was (draft E6 "nach dem Anlegen"): drawn like the
/// tinted card button (`CardActionButtonStyle`, same fill, size and edge), but words, not a
/// button, so nothing offers a tap that does nothing.
private struct StartMadeLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.cardActionFillsWidth) private var fillsWidth
    @ScaledMetric(relativeTo: .body) private var radius: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Label("Angelegt", systemImage: "checkmark")
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .background(Theme.accent.opacity(colorScheme == .dark ? 0.18 : 0.11), in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .combine)
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
            StarterSetMosaic(ids: set.compactMap { model.startCardCovers(for: $0).first })
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

/// Nothing is open after the analysis: one calm card instead of empty rows, with the way to
/// every suggestion (the ones set aside with "Nicht jetzt" too).
struct StartCaughtUpCard: View {
    @Environment(Navigator.self) private var navigator: Navigator?

    var body: some View {
        Card {
            Label("Alles erledigt", systemImage: "checkmark.circle")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Neue Vorschläge kommen von selbst, sobald du neue Fotos machst.")
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Navigator.push(.proposals, on: navigator)
            } label: {
                Text("Alle Vorschläge")
            }
            .buttonStyle(CardActionButtonStyle())
            .accessibilityIdentifier("startPage.allSuggestions")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startPage.caughtUp")
    }
}
