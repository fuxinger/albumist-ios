import StoreKit
import SwiftUI
import AlbumistCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            // Says what is loading, not only "In Bearbeitung" (design review N2).
            ProgressView().controlSize(.large)
                .accessibilityLabel(Text("Albumist wird geladen"))
        case .failed(let message):
            ContentUnavailableView {
                Label("Albumist konnte nicht starten", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                // A damaged database is no dead end: Albumist's own data can always be rebuilt
                // from the library. Photos, albums and the purchase are not affected.
                Button("Neu aufbauen") { Task { await model.rebuildAfterFailure() } }
                    .buttonStyle(.borderedProminent)
                if AppModel.safetyBackupDate() != nil {
                    Text("Albumist beginnt dann neu und holt deine Entscheidungen aus der Sicherung zurück. Deine Fotos, Alben und dein Kauf bleiben, wie sie sind.")
                        .font(.footnote).foregroundStyle(.noteText)
                } else {
                    Text("Albumist beginnt dann neu. Deine Fotos, Alben und dein Kauf bleiben, wie sie sind.")
                        .font(.footnote).foregroundStyle(.noteText)
                }
            }
        case .onboarding:
            OnboardingView()
        case .noAccess:
            NoPhotoAccessView()
        case .ready:
            MainTabs()
        }
    }
}

/// Photo access taken away after the introduction (plugin review W4). The introduction used
/// to start again and ended with "Analyse starten" for the whole library, which replaced a
/// part chosen before. This screen leads to Settings (or to the iOS question when iOS forgot
/// the answer); once access is back, Albumist goes on where it was.
struct NoPhotoAccessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Kein Zugriff auf deine Fotos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Albumist darf deine Fotos gerade nicht lesen. Sobald du den Zugriff wieder erlaubst, geht es dort weiter, wo du warst. Deine Auswahl und deine Alben bleiben, wie sie sind.")
        } actions: {
            if model.access == .notDetermined {
                // "Weiter", not "Zugriff erlauben": the iOS question comes next (plugin review K5).
                Button("Weiter") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("access.continue")
            } else {
                // iOS does not ask a second time: the way back is the Settings app.
                Button("Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("access.settings")
                Text("Einstellungen › Apps › Albumist › Fotos › Voller Zugriff")
                    .font(.footnote).foregroundStyle(.noteText)
            }
        }
    }
}

/// The tabs (design W1, 6B): "Vorschläge · Unsortiert · Alben · Suche".
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.requestReview) private var requestReview
    @State private var tab: MainTab = .suggestions
    /// The stack of the tab "Vorschläge", also for Siri, Shortcuts and Spotlight (`AppScreen`).
    @State private var suggestionsNavigator = Navigator()
    /// The tab bar stays open while a new album comes to "Alben" (`QuickCreateMomentLayer`).
    @State private var momentHoldsTabBar = false

    enum MainTab: Hashable { case suggestions, unsorted, albums, search }

    /// Two cards for "Vorschläge", as in the draft: never sparkles, which stand for AI at Apple.
    /// The fanned portrait cards came with iOS 17; should iOS not have them, the fanned cards
    /// of iOS 14, so the tab never stands without a symbol.
    static let suggestionsSymbol = UIImage(systemName: "rectangle.portrait.on.rectangle.portrait.angled") != nil
        ? "rectangle.portrait.on.rectangle.portrait.angled" : "rectangle.on.rectangle.angled"

    var body: some View {
        TabView(selection: $tab) {
            // Every tab shows the banner after "Anlegen" above the tab bar (decision 7B), so on
            // the tabs' stacks "Anlegen" makes the album at once (`quickCreateAtOnce`); a sheet's
            // own stack over them does not.
            Tab("Vorschläge", systemImage: Self.suggestionsSymbol, value: MainTab.suggestions) {
                NavigationRoot(suggestionsNavigator, quickCreate: true) { OverviewView() }
                    .showsQuickCreateBanner()
            }
            // What is not sorted yet, unsure or ignored (`LibraryView`).
            Tab("Unsortiert", systemImage: "photo.on.rectangle", value: MainTab.unsorted) {
                NavigationRoot(quickCreate: true) { LibraryView() }
                    .showsQuickCreateBanner()
            }
            // The symbol Photos uses for albums (design review N1).
            Tab("Alben", systemImage: "rectangle.stack", value: MainTab.albums) {
                NavigationRoot(quickCreate: true) { AlbumsView() }
                    .showsQuickCreateBanner()
            }
            Tab(value: MainTab.search, role: .search) {
                NavigationRoot(quickCreate: true) { SearchView() }
                    .showsQuickCreateBanner()
            }
        }
        // iPad: tabs become a sidebar; iPhone: the Liquid Glass tab bar shrinks while scrolling.
        .tabViewStyle(.sidebarAdaptable)
        // UI tests tap every tab by name; a shrunken bar hides all but the current one, so it
        // also stays open while a new album comes to "Alben".
        .tabBarMinimizeBehavior(UITestSupport.isRunning || momentHoldsTabBar ? .never : .onScrollDown)
        // "Anlegen" on a card made an album (draft E6): the card's cover flies into "Alben" as
        // its banner comes, with the album's one haptic (`QuickCreateMomentLayer`): over the
        // tabs, never tapped, hidden from VoiceOver.
        .overlay {
            QuickCreateMomentLayer(holdsTabBar: $momentHoldsTabBar, showsAlbumsTab: tab != .search)
        }
        // Siri, Shortcuts, Spotlight and the analysis card's buttons open their target from
        // the tab "Vorschläge": pushed onto its path, and the route is taken.
        .onChange(of: model.route, initial: true) { _, target in
            guard let target else { return }
            tab = .suggestions
            // A suggestion that exists opens like one from a list (`ProposalScreen`: it stays
            // when the analysis drops it while its preview is open). The same target twice in a
            // row, or a suggestion already on top, opens once (`Navigator.push`).
            if case .suggestion(let id) = target, let found = model.proposals.first(where: { $0.id == id }) {
                suggestionsNavigator.push(.proposal(ProposalRef(found)))
            } else {
                suggestionsNavigator.push(.route(target))
            }
            model.route = nil
        }
        // Each message brings its own title (design review W15), e.g. "Das hat nicht geklappt".
        .alert(model.message?.title ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
               presenting: model.message) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.text)
        }
        // "Anlegen" found the free albums used up: the purchase sheet instead of the album. Once
        // Albumist is unlocked, the album is made as tapped; closed without buying, the
        // suggestion stays open.
        .sheet(item: Binding(get: { model.quickCreatePurchase }, set: { model.quickCreatePurchase = $0 })) { request in
            UnlockSheet(reason: .quickCreate) {
                Task { await model.continueQuickCreate(after: request) }
            }
        }
        // The App Store rating question: a moment after the user left the result of a plan that
        // made new albums, never at a start (`ReviewPrompt`, `ReviewPromptPolicy`).
        .task(id: ReviewPrompt.shared.due) { await askForRatingIfDue() }
    }

    /// Waits until the screen after the result has settled, and briefly for the check for new
    /// photos that follows every plan and for the banner after "Anlegen" (the question would
    /// cover its "Widerrufen"); then asks if `ReviewPromptPolicy` still allows it. A newer
    /// moment, Albumist leaving the screen, or the tabs going away cancels the wait; a wait that
    /// ran long (`ReviewPromptPolicy.momentLasts`), or a banner still there, asks nothing. iOS
    /// decides whether the question appears (at most three times a year); Albumist never shows a
    /// rating screen of its own.
    private func askForRatingIfDue() async {
        guard let moment = ReviewPrompt.shared.due else { return }
        do {
            try await Task.sleep(for: ReviewPromptPolicy.delay)
            var waited = Duration.zero
            while (model.analysis.isRunning || model.quickCreateBanner != nil) && waited < ReviewPromptPolicy.analysisWait {
                try await Task.sleep(for: .milliseconds(500))
                waited += .milliseconds(500)
            }
        } catch {
            return
        }
        guard model.quickCreateBanner == nil else { return }
        if ReviewPrompt.shared.confirm(moment, model: model) { requestReview() }
    }
}

/// A screen opened from Siri, Shortcuts or Spotlight.
struct RouteDestination: View {
    @Environment(AppModel.self) private var model
    var route: AppModel.Route

    var body: some View {
        switch route {
        case .country(let code):
            CountryPhotosView(code: code, year: nil)
        case .proposals:
            ProposalListView(area: nil)
        case .suggestion(let id):
            if let proposal = model.proposals.first(where: { $0.id == id }) {
                ProposalDetailView(proposal: proposal)
            } else {
                ContentUnavailableView("Vorschlag nicht gefunden", systemImage: "rectangle.stack",
                                       description: Text("Dieser Vorschlag ist schon erledigt oder nicht mehr aktuell."))
            }
        }
    }
}
