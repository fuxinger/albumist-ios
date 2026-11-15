import SwiftUI
import SortlyCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.large)
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
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Albumist beginnt dann neu. Deine Fotos, Alben und dein Kauf bleiben, wie sie sind.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab: MainTab = .overview

    enum MainTab: Hashable { case overview, library, albums, search }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Übersicht", systemImage: "square.grid.2x2", value: MainTab.overview) {
                NavigationStack {
                    OverviewView()
                        .navigationDestination(item: route) { RouteDestination(route: $0) }
                }
            }
            Tab("Mediathek", systemImage: "photo.on.rectangle", value: MainTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Alben", systemImage: "folder", value: MainTab.albums) {
                NavigationStack { AlbumsView() }
            }
            Tab(value: MainTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        // iPad: tabs become a sidebar; iPhone: the Liquid Glass tab bar shrinks while scrolling.
        .tabViewStyle(.sidebarAdaptable)
        // UI tests tap every tab by name; a shrunken bar hides all but the current one.
        .tabBarMinimizeBehavior(UITestSupport.isRunning ? .never : .onScrollDown)
        // Siri, Shortcuts and Spotlight open their target from the overview.
        .onChange(of: model.route, initial: true) { _, target in
            if target != nil { tab = .overview }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var route: Binding<AppModel.Route?> {
        Binding(get: { model.route }, set: { model.route = $0 })
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
