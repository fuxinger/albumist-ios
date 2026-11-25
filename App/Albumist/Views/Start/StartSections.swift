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
/// edge to edge; everything else keeps the page's margin. What a card's long press opens
/// ("Anpassen", the trip workshop, "Keine Reise?") is the page's scroll view's
/// (`suggestionMenuFlows(_:)` in `OverviewView`), not this tall stack's (review C of design
/// wave 2, M1).
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
        let _: Void = MainThreadWatch.shared.count("start page body")
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
        return model.startPage(StartPageState(visit: visit, libraryHint: libraryHint, starterSet: model.starterSet(limit: limit),
                                              starterSetLimit: limit, analysedOnce: analysedOnce, showsMosaic: showsMosaic,
                                              rebuilding: rebuilding, analysing: analysing))
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
        .quickCreateMomentSource(proposal, aspectRatio: style == .large ? 2 : 3.0 / 2.0) // Design W2 H6: moment source
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
        // The suggestion as the analysis has it now: the card's menu stays open while it may
        // change, or go, which is said then (review C of design wave 2, H1).
        guard let proposal = model.currentSuggestion(proposal) else { return }
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
