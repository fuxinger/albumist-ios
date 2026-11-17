import SwiftUI
import SortlyCore

/// Navigation by value on a path, for every stack of the app (`NavigationRoot`).
///
/// A screen that opens another one in code (after a dialog or after a plan was built) pushes an
/// `AppScreen` onto its stack's path through the `Navigator` in the environment. It never uses
/// `navigationDestination(isPresented:)` or `navigationDestination(item:)`: SwiftUI presented
/// such destinations again and again inside its navigation updates and held the main thread
/// for up to 352 s (UI runs 44055738268 and 44066730498: the preview drawn 11,062 times in
/// 36 s, the atlas map 9,644 times, the preview of "Alben von Albumist" 502 times in 5.9 s).
/// `.github/scripts/navigation_rule.py` keeps both out of the app.
///
/// The screens on the way to such a screen are pushed by value too (rows are `PushLink`s), so a
/// stack never holds a destination link below a value: a value pushed above a destination
/// link would not belong to the screen that pushed it. Every stack is a `NavigationRoot`,
/// which registers the destinations, so no push leads nowhere (the reason for the
/// destination-link rule in DECISIONS: value links in screens without a registered
/// destination did nothing). Plain `NavigationLink { destination }` stays for screens that
/// open nothing in code (photos, albums, folders, settings pages).
enum AppScreen: Hashable {
    /// All suggestions, or those of one area.
    case proposals
    case areaProposals(OrganizationArea)
    case proposal(ProposalRef)
    /// The preview of the selected suggestions.
    case plan
    /// The preview of the starter set; leaving it ends the preview selection (`OverviewView`).
    case starterPlan
    /// The preview of a plan made elsewhere: an album merge, a removal, one suggestion right
    /// away, "Fehlendes erneut versuchen", "Zu Album hinzufügen".
    case prebuiltPlan(PlanToken)
    case receipt(PlanToken)
    case atlas
    case country(code: String, year: Int?)
    /// Where Siri, Shortcuts, Spotlight or a card's button wants to go (`AppModel.route`).
    case route(AppModel.Route)
    case managedAlbums
    case history

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .proposals: ProposalListView(area: nil)
        case .areaProposals(let area): ProposalListView(area: area)
        case .proposal(let ref): ProposalScreen(ref: ref)
        case .plan, .starterPlan: PlanReviewView()
        case .prebuiltPlan(let token): PlanReviewView(prebuilt: token.plan)
        case .receipt(let token): PlanReceiptView(plan: token.plan)
        case .atlas: AtlasView()
        case .country(let code, let year): CountryPhotosView(code: code, year: year)
        case .route(let route): RouteDestination(route: route)
        case .managedAlbums: ManagedAlbumsView()
        case .history: HistoryView()
        }
    }
}

/// A plan on a path. Equal only to itself (one push), so comparing paths never compares the
/// steps of two plans.
struct PlanToken: Hashable {
    let plan: ChangePlan
    private let push = UUID()

    init(_ plan: ChangePlan) { self.plan = plan }

    static func == (a: PlanToken, b: PlanToken) -> Bool { a.push == b.push }
    func hash(into hasher: inout Hasher) { hasher.combine(push) }
}

/// A suggestion on a path, compared by its id.
struct ProposalRef: Hashable {
    let proposal: AlbumProposal

    init(_ proposal: AlbumProposal) { self.proposal = proposal }

    static func == (a: ProposalRef, b: ProposalRef) -> Bool { a.proposal.id == b.proposal.id }
    func hash(into hasher: inout Hasher) { hasher.combine(proposal.id) }
}

/// A pushed suggestion shows its current state; when the analysis no longer has it (split,
/// merged, planned anew), the state it was opened with, so the screen and its sheets stay
/// until it closes itself.
struct ProposalScreen: View {
    @Environment(AppModel.self) private var model
    var ref: ProposalRef

    var body: some View {
        ProposalDetailView(proposal: model.proposals.first(where: { $0.id == ref.proposal.id }) ?? ref.proposal)
    }
}

/// The path of one navigation stack, in the environment of every screen on it.
@MainActor @Observable
final class Navigator {
    var path: [AppScreen] = []

    func push(_ screen: AppScreen) { path.append(screen) }

    /// Pushes `screen` onto the stack of the screen that asks. Every stack is a
    /// `NavigationRoot`; a screen without a navigator is a programming error.
    static func push(_ screen: AppScreen, on navigator: Navigator?) {
        guard let navigator else {
            assertionFailure("No Navigator: the stack is not a NavigationRoot (\(screen))")
            return
        }
        navigator.push(screen)
    }
}

/// A navigation stack with a path of `AppScreen`s, their destinations and its `Navigator` in
/// the environment. Each stack owns its navigator (a sheet starts empty every time it opens);
/// the overview tab passes its own, which Siri, Shortcuts and Spotlight push onto.
struct NavigationRoot<Root: View>: View {
    @State private var own = Navigator()
    private let shared: Navigator?
    private let root: Root

    init(_ navigator: Navigator? = nil, @ViewBuilder root: () -> Root) {
        shared = navigator
        self.root = root()
    }

    var body: some View {
        let navigator = shared ?? own
        NavigationStack(path: Bindable(navigator).path) {
            root.navigationDestination(for: AppScreen.self) { $0.destination }
        }
        .environment(navigator)
    }
}

/// A row that pushes `screen` and looks like a navigation link: its label, then a chevron.
struct PushLink<Label: View>: View {
    @Environment(Navigator.self) private var navigator: Navigator?
    private let screen: AppScreen
    private let chevron: Bool
    private let label: Label

    /// `chevron: false` where the label draws its own.
    init(_ screen: AppScreen, chevron: Bool = true, @ViewBuilder label: () -> Label) {
        self.screen = screen
        self.chevron = chevron
        self.label = label()
    }

    var body: some View {
        Button {
            Navigator.push(screen, on: navigator)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}
