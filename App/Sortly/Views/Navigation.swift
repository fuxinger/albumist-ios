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
/// open nothing in code (photos, albums, folders, settings pages). A screen that opens a
/// preview after building its plan and also holds such links (albums and folders under
/// "Alben", a suggestion's photos) turns them off while the plan is built. What a screen hands
/// to a screen it pushes and takes back when that one goes (a preview's pick) is tied to the
/// pushed screen (`Navigator.onLeave`): a pop to the root or back to an earlier screen takes the
/// screen that pushed along without telling it.
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

    /// The same screen as `other`: equal, or the same suggestion opened from a list and from
    /// Siri, Shortcuts or Spotlight.
    func isSame(as other: AppScreen) -> Bool {
        if self == other { return true }
        guard let id = suggestionID else { return false }
        return id == other.suggestionID
    }

    private var suggestionID: SortlyID? {
        switch self {
        case .proposal(let ref): ref.proposal.id
        case .route(.suggestion(let id)): id
        default: nil
        }
    }

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

/// A plan on a path, compared by the plan's id, so comparing paths never compares the steps
/// of two plans, and a second tap on the same plan's link is recognised (`Navigator.push`).
struct PlanToken: Hashable {
    let plan: ChangePlan

    init(_ plan: ChangePlan) { self.plan = plan }

    static func == (a: PlanToken, b: PlanToken) -> Bool { a.plan.id == b.plan.id }
    func hash(into hasher: inout Hasher) { hasher.combine(plan.id) }
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
    var path: [AppScreen] = [] {
        didSet {
            guard path != oldValue else { return }
            changes &+= 1
            runLeaving()
        }
    }
    /// Counts the changes of `path`: a push and the pop after it are two, although the path is
    /// the same again (`mark`). Asking for the screen on top again counts too (`push(_:)`).
    @ObservationIgnored private var changes = 0

    /// The stack is on screen: its tab is the chosen one, its sheet is up. Set by
    /// `NavigationRoot` from the onAppear/onDisappear of the stack itself, which TabView sends
    /// when the user changes tabs. A swipe back that is called off sends them to the screens
    /// on the stack, not to the stack, so this does not depend on them being paired.
    private(set) var showing = false
    /// Goes up each time the stack comes on screen. A screen whose result waits for its stack
    /// watches this (`onChange`): it changes at every return, also for a screen that was not
    /// drawn while its tab was away and so never saw `showing` turn false.
    private(set) var appearances = 0

    func appeared() {
        showing = true
        appearances &+= 1
    }

    func disappeared() { showing = false }

    /// What runs when a screen leaves the path (`onLeave(_:perform:)`), by screen.
    @ObservationIgnored private var leaving: [AppScreen: [@MainActor () -> Void]] = [:]

    /// Runs `action` once `screen` is no longer on the path: Back from it, a pop to the root
    /// (its tab tapped again) or back to an earlier screen (a long press on Back), also when the
    /// screen that pushed it goes along, and when the whole stack goes (its sheet closed). For
    /// what a screen hands to the screen it pushes and must take back (a preview's pick): the
    /// screen that pushed may be gone before it could see its preview leave.
    func onLeave(_ screen: AppScreen, perform action: @escaping @MainActor () -> Void) {
        leaving[screen, default: []].append(action)
    }

    private func runLeaving() {
        guard !leaving.isEmpty else { return }
        for screen in leaving.keys.filter({ !path.contains($0) }) {
            for action in leaving.removeValue(forKey: screen) ?? [] { action() }
        }
    }

    /// The stack goes with its screens (its sheet closed): what waits for them to leave runs
    /// now, on the main actor.
    deinit {
        let actions = leaving.values.flatMap { $0 }
        if !actions.isEmpty { Task { @MainActor in for action in actions { action() } } }
    }

    /// Where the stack stands, read when work starts on the screen on top. The same mark later
    /// means nothing was pushed or popped meanwhile (Back, a screen from Siri, Back and the same
    /// screen opened again, the screen on top asked for again), so that screen is still the one
    /// on top. Read from the navigator, not from the screen's onAppear/onDisappear, which a
    /// swipe back that is called off may leave unpaired. Marks of two stacks never match.
    var mark: Mark { Mark(stack: ObjectIdentifier(self), changes: changes) }

    struct Mark: Equatable {
        fileprivate let stack: ObjectIdentifier
        fileprivate let changes: Int
    }

    /// The screen that read `mark` is still on top of this stack, and the stack is on screen.
    func isShowing(_ mark: Mark?) -> Bool { showing && self.mark == mark }

    /// Pushes `screen`, unless it is already on top (a second tap on the same row, the map or
    /// a link pushes nothing more). Returns whether it pushed. Asking for the screen on top
    /// still moves the `mark`: Siri opening the suggestion that already shows means that
    /// suggestion, not a preview its screen built before.
    @discardableResult
    func push(_ screen: AppScreen) -> Bool {
        if let last = path.last, last.isSame(as: screen) {
            changes &+= 1
            return false
        }
        path.append(screen)
        return true
    }

    /// Pushes `screen` onto the stack of the screen that asks. Every stack is a
    /// `NavigationRoot`; a screen without a navigator is a programming error.
    static func push(_ screen: AppScreen, on navigator: Navigator?) {
        guard let navigator else {
            assertionFailure("No Navigator: the stack is not a NavigationRoot (\(screen))")
            return
        }
        navigator.push(screen)
    }

    /// What became of a screen pushed at the end of work (`push(_:on:ifStill:)`).
    enum Outcome {
        /// Pushed: the screen that asked is on top of an unchanged stack, and the stack shows.
        case pushed
        /// Not yet: the stack is unchanged, but it is not on screen (`showing`: another tab is
        /// chosen, or its sheet was closed). A screen in a tab keeps the result and pushes it
        /// when its stack shows again, if the result is still current then (`PlanRequest`); a
        /// screen in a sheet drops it.
        case waiting
        /// Not pushed: the stack changed since the work started (a push, a pop, the screen on
        /// top asked for again), so the result has no place on it any more.
        case dropped
    }

    /// The end of work that started on a screen (a plan being built) pushes its result only if
    /// that screen is still on top of its stack and the stack shows: the stack's `mark` still
    /// `before`, as read when the work started, and `showing`. Otherwise the result is not
    /// pushed, as with the old `navigationDestination(isPresented:)` of a screen that had gone,
    /// or waits (`Outcome`).
    @discardableResult
    static func push(_ screen: AppScreen, on navigator: Navigator?, ifStill before: Mark?) -> Outcome {
        guard let navigator, let before, navigator.mark == before else { return .dropped }
        guard navigator.showing else { return .waiting }
        return navigator.push(screen) ? .pushed : .dropped
    }
}

/// A preview asked for by a tap (an album merge, "Album anlegen", "Fehlendes erneut
/// versuchen"): where the screen's stack stood and what the album list held at the tap. When
/// the plan is ready, and again when it waited for its stack to show, `verdict` says what
/// becomes of it, the same way both times.
struct PlanRequest {
    let mark: Navigator.Mark?
    /// Compared by content, not by `AppModel.inventoryVersion`: that goes up with every
    /// refresh, also one that read the same albums again (the check after every plan).
    let inventory: CollectionInventory

    @MainActor init(model: AppModel, navigator: Navigator?) {
        mark = navigator?.mark
        inventory = model.inventory
    }

    enum Verdict {
        /// Push the preview now.
        case show
        /// The stack is not on screen (another tab): keep the plan until it is.
        case wait
        /// The user went elsewhere on this stack: the plan has no place on it.
        case gone
        /// A plan runs, a change in "Dein Zuhause" is applied or the analysis is rebuilt: the
        /// preview could not be used now. Said (`AppMessage.busy`), not shown.
        case busy
        /// The album list changed since the tap: the plan is made again.
        case stale
    }

    @MainActor func verdict(model: AppModel, navigator: Navigator?) -> Verdict {
        guard let navigator, let mark, navigator.mark == mark else { return .gone }
        guard navigator.showing else { return .wait }
        if model.execution.isRunning || model.homeChangeRunning || model.analysisResetting { return .busy }
        return model.inventory == inventory ? .show : .stale
    }
}

/// A navigation stack with a path of `AppScreen`s, their destinations and its `Navigator` in
/// the environment. Each stack owns its navigator (a sheet starts empty every time it opens);
/// the overview tab passes its own, which Siri, Shortcuts and Spotlight push onto.
struct NavigationRoot<Root: View>: View {
    @State private var navigator: Navigator
    private let root: Root

    init(_ navigator: Navigator? = nil, @ViewBuilder root: () -> Root) {
        _navigator = State(initialValue: navigator ?? Navigator())
        self.root = root()
    }

    var body: some View {
        NavigationStack(path: $navigator.path) {
            root.navigationDestination(for: AppScreen.self) { $0.destination }
        }
        .environment(navigator)
        // The stack as a whole: another tab chosen, the sheet closed (`Navigator.showing`).
        .onAppear { navigator.appeared() }
        .onDisappear { navigator.disappeared() }
    }
}

/// A row that pushes `screen` and looks like a navigation link: its label, then a chevron.
struct PushLink<Label: View>: View {
    @Environment(Navigator.self) private var navigator: Navigator?
    /// Made at the tap, not at every drawing (a history row's plan token).
    private let screen: () -> AppScreen
    private let chevron: Bool
    private let label: Label

    /// `chevron: false` where the label draws its own.
    init(_ screen: @autoclosure @escaping () -> AppScreen, chevron: Bool = true, @ViewBuilder label: () -> Label) {
        self.screen = screen
        self.chevron = chevron
        self.label = label()
    }

    var body: some View {
        Button {
            Navigator.push(screen(), on: navigator)
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
