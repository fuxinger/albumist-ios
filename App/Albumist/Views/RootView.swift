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
    /// What is typed in the search field; the search page reads it (`SearchView`).
    @State private var search = SearchInput()

    enum MainTab: Hashable { case suggestions, unsorted, albums, search }

    /// Where the search field sits (design wave 3, DS-12a, draft E1), as the owner chose on
    /// 25.11.2026 ("Runder Knopf, Suche bleibt"): the search is a round button of its own at the
    /// bar's end; choosing it shows the page with its starting points and the field, the keyboard
    /// comes when the field is tapped, and the query, the hits and the scroll position stay while
    /// another tab is looked at, also when a route (a notification, Siri) leaves the tab. iOS 26
    /// draws the search role as that button and the field on the tab view in the bar's place
    /// (`.tabView`). iOS 27.2 drew the same tab as a fourth tab in the row and showed no field
    /// until it was activated, which put the field at the top (UI run 45567033486): there the tab
    /// takes the prominent role (`searchRole`), and the field sits on the page's own stack under
    /// its title, always shown (`.page`).
    static var searchField: SearchInput.Placement {
        if #available(iOS 27, *) { return .page }
        return .tabView
    }

    /// The search tab's role: the search role on iOS 26, which iOS draws as the round button at
    /// the bar's end; the prominent role on iOS 27, which Apple documents as the one tab with
    /// the prominent treatment in a separate place at the bar's end ("Only one tab can receive
    /// the prominent treatment"). Its shape is the system's: the frame test checks for a round
    /// button apart from the tabs. On iOS 27 UIKit makes a search tab prominent by itself only
    /// when choosing it starts the search with the keyboard, which the owner did not choose
    /// (`searchField`): a step away from Apple's search tab on purpose (docs/DECISIONS.md). One
    /// role per tab: the prominent one has no system label, so the tab names itself.
    static var searchRole: TabRole {
        if #available(iOS 27, *) { return .prominent }
        return .search
    }

    /// Two cards for "Vorschläge", as in the draft: never sparkles, which stand for AI at Apple.
    /// The fanned portrait cards came with iOS 17; should iOS not have them, the fanned cards
    /// of iOS 14, so the tab never stands without a symbol.
    static let suggestionsSymbol = UIImage(systemName: "rectangle.portrait.on.rectangle.portrait.angled") != nil
        ? "rectangle.portrait.on.rectangle.portrait.angled" : "rectangle.on.rectangle.angled"

    var body: some View {
        // Read here, in `body`, which SwiftUI tracks: read only inside the sheet's binding, a new
        // request is not sure to redraw the tabs, and the purchase sheet did not come (locked UI
        // test 8, run 44862187776).
        let purchase = model.quickCreatePurchase
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
            // The round button at the bar's end (`searchRole`), with the field where its system
            // puts it (`searchField`).
            Tab("Suchen", systemImage: "magnifyingglass", value: MainTab.search, role: Self.searchRole) {
                NavigationRoot(quickCreate: true) { SearchView(input: search) }
                    .showsQuickCreateBanner()
            }
        }
        // The search field on the tab view, as Apple shows a search tab on iOS 26; on iOS 27 the
        // search page has it (`searchField` above).
        .searchField(search, on: .tabView)
        // iPad: tabs become a sidebar; iPhone: the Liquid Glass tab bar shrinks while scrolling.
        .tabViewStyle(.sidebarAdaptable)
        // UI tests tap every tab by name; a shrunken bar hides all but the current one.
        .tabBarMinimizeBehavior(UITestSupport.isRunning ? .never : .onScrollDown)
        // "Anlegen" on a card made an album (draft E6): the card's cover flies towards "Alben" as
        // its banner comes, when the tab bar is open (`QuickCreateMomentLayer`): over the tabs,
        // never tapped, hidden from VoiceOver, no haptic of its own.
        .overlay {
            QuickCreateMomentLayer(showsAlbumsTab: tab != .search || MainTabs.searchField == .page)
        }
        // Siri, Shortcuts, Spotlight and the analysis card's buttons open their target from
        // the tab "Vorschläge": pushed onto its path, and the route is taken.
        .onChange(of: model.route, initial: true) { _, target in
            guard let target else { return }
            // Chosen here, not on the bar, which may be shrunk: the small moment's cover does not
            // count on it being open (`QuickCreateMoment.TabWatch`).
            if tab != .suggestions { QuickCreateMomentSources.shared.tabChosenInCode() }
            // Leaving the search in code (`SearchInput.leftInCode`): only the keyboard goes, and
            // the search stays as after a look at another tab.
            if tab == .search { search.leftInCode() }
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
        // "Anlegen" on a card made an album: one success tap as its banner comes, as after the
        // preview's run (`ExecutionHaptics`), whether or not its cover flies.
        .sensoryFeedback(.success, trigger: model.quickCreateBanner?.id) { (old: AlbumistID?, new: AlbumistID?) in
            new != nil && new != old
        }
        // "Anlegen" found the free albums used up: the purchase sheet instead of the album. Once
        // Albumist is unlocked, the album is made as tapped; closed without buying, the
        // suggestion stays open. Shows what `body` read (`purchase` above), so a new request
        // redraws the tabs.
        .sheet(item: Binding(get: { purchase }, set: { model.quickCreatePurchase = $0 })) { request in
            UnlockSheet(reason: .quickCreate) {
                Task { await model.continueQuickCreate(after: request) }
            }
            .sheetSize(.short)
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
