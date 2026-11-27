import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The small moment of quick create (draft E6) in the App (`MomentsSourceTests`).
extension MomentsSourceTests {
    // MARK: The small moment (draft E6)

    /// The layer lies over the tabs, where the banner shows: never tapped, hidden from VoiceOver,
    /// no haptic of its own. The album's one haptic is the success tap with every banner, given by
    /// the tabs as before the moment, whether or not the cover flies: never late, never lost
    /// (review E of design wave 2, finding 6). The cover fades into the bar on its way and never
    /// lands (finding 4); the tab bar's behaviour is never switched for it (finding 5).
    @Test func theSmallMomentFliesOverTheTabsOnly() throws {
        let tabs = try Self.code(Self.tabs)
        let main = try Self.body(["struct MainTabs", "var body: some View"], in: tabs)
        #expect(main.contains(".tabBarMinimizeBehavior(UITestSupport.isRunning ? .never : .onScrollDown)"), "\(main)")
        let overlay = try #require(AppSource.body(of: ".overlay", in: main), "\(main)")
        // "Alben" is in the bar but while the search tab is chosen on iOS 26, where the bar is the
        // field beside one round button; on iOS 27 the bar stays as it is (`MainTabs.searchField`).
        #expect(overlay.contains("QuickCreateMomentLayer(showsAlbumsTab: tab != .search || MainTabs.searchField == .page)"), "\(overlay)")
        #expect(Self.count(".sensoryFeedback(", in: main) == 1, "\(main)")
        #expect(main.contains(".sensoryFeedback(.success, trigger: model.quickCreateBanner?.id)"), "the banner's success tap is gone")
        #expect(main.contains("new != nil && new != old"), "\(main)")
        var layers = 0
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let file = try AppSource.read(path)
            layers += AppSource.calls(of: "QuickCreateMomentLayer(", in: file).count
            #expect(!file.contains("oldsTabBar"), "\(path) switches the tab bar for the moment")
        }
        #expect(layers == 1, "the moment is drawn somewhere else too")
        // The layer and its sources (`QuickCreateMomentSources`, once in the layer's file).
        for path in [Self.layer, Self.sources] {
            #expect(!(try Self.code(path)).contains("sensoryFeedback"), "\(path): the moment has a haptic of its own")
        }
        let file = try Self.code(Self.layer)
        let layer = try Self.body(["struct QuickCreateMomentLayer", "var body: some View"], in: file)
        for part in [".allowsHitTesting(false)", ".accessibilityHidden(true)", ".ignoresSafeArea()"] {
            #expect(layer.contains(part), "\(part): \(layer)")
        }
        #expect(layer.contains(".task(id: pending) { await begin() }"), "\(layer)")
        let begin = try Self.body(["struct QuickCreateMomentLayer", "func begin("], in: file)
        #expect(begin.contains("QuickCreateMoment.kind(reduceMotion: reduceMotion"), "\(begin)")
        #expect(begin.contains("barOpen: sources.barOpen"), "\(begin)")
        // Looked at a moment after the banner came: a list puts the made card back in its place.
        let look = try #require(begin.range(of: "try? await Task.sleep(for: Self.lookDelay)"), "\(begin)")
        let lookup = try #require(begin.range(of: "sources.photo(for:"), "\(begin)")
        #expect(look.upperBound <= lookup.lowerBound, "\(begin)")
        // A banner without a flight leaves a cover still flying for the one before.
        #expect(!begin.contains("finish()") && !begin.contains("moment = nil"), "\(begin)")
        let play = try Self.body(["struct QuickCreateMomentLayer", "func play()"], in: file)
        #expect(play.contains("QuickCreateMoment.Flight.duration"), "\(play)")
        #expect(!play.contains("landings") && !play.contains("fading") && !play.contains("fadeAtTab"), "\(play)")
        let placement = try Self.body(["struct MomentPlacement", "func body(content: Content)"], in: file)
        #expect(placement.contains(".opacity(flight.opacity(at: t))"), "\(placement)")
    }

    /// The cover flies only into an open tab bar (review E of design wave 2, finding 5): what the
    /// bar does is read from the scroll of the screens with cards, the start page and the
    /// suggestion list, not from where the cards are (review E2, N1 and N2), and decided in the
    /// core (`QuickCreateMoment.TabWatch`, `QuickCreateMomentBarTests`; N6). Each of the two
    /// screens marks its scroll view with one line; the modifier hands over the offset, the
    /// phase and when the screen shows and goes, only on a tab's own stack (a sheet's says no).
    @Test func theCoverFliesOnlyIntoAnOpenTabBar() throws {
        // One marked line on each screen's scroll view, and no other screen calls it. On the start
        // page before the sheets of a card's long press (`suggestionMenuFlows`), so that no scroll
        // in "Anpassen" or the trip workshop reaches it.
        let chains = [Self.overview: "}.quickCreateMomentScrollTrail().suggestionMenuFlows(menuFlows).background(Theme.background)",
                      Self.list: "}.quickCreateMomentScrollTrail().background(Theme.background)"]
        for (path, chain) in chains {
            let file = try AppSource.read(path)
            let lines = file.split(separator: "\n").filter { $0.contains(Self.trailMark) }
            #expect(lines.count == 1, "\(path): \(lines)")
            let line = try #require(lines.first).trimmingCharacters(in: .whitespaces)
            #expect(line == ".quickCreateMomentScrollTrail() \(Self.trailMark)", "\(path): \(line)")
            let view = path == Self.overview ? "struct OverviewView" : "struct ProposalListView"
            let body = try Self.body([view, "var body: some View"], in: try Self.code(path))
            let squeezed = String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
            #expect(squeezed.contains(chain), "\(path): not on the scroll view")
        }
        for path in AppSource.swiftFiles(under: "App/Albumist") where ![Self.overview, Self.list, Self.layer].contains(path) {
            let file = try AppSource.read(path)
            #expect(AppSource.calls(of: "quickCreateMomentScrollTrail(", in: file).isEmpty, "\(path) reads a scroll too")
        }
        let layer = try Self.code(Self.layer)
        let trail = try Self.body(["struct QuickCreateMomentScrollTrail", "func body(content: Content)"], in: layer)
        for part in [".onScrollGeometryChange(for: QuickCreateMoment.ScrollSpot.self)", "offset: Double(geometry.contentOffset.y)",
                     "top: -Double(geometry.contentInsets.top)",
                     "end: Double(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)",
                     ".onScrollPhaseChange", "QuickCreateMomentSources.shared.scrolled(token, to: now, motion)",
                     "QuickCreateMomentSources.shared.appeared(token, on: place, at: spot, again: shownBefore)",
                     ".onDisappear { QuickCreateMomentSources.shared.disappeared(token) }"] {
            #expect(trail.contains(part), "\(part): \(trail)")
        }
        // Only a tab's own stack: a sheet over the tabs has a stack of its own.
        #expect(Self.count("guard onTab", in: trail) == 2, "\(trail)")
        #expect(layer.contains("@Environment(\\.quickCreateAtOnce) private var onTab"), "the modifier does not ask for the tab's stack")
        // The user's scroll only: at rest, laid out anew or animated by the system is none.
        let motion = try Self.body(["struct QuickCreateMomentScrollTrail", "static func motion("], in: layer)
        #expect(motion.contains("case .tracking, .interacting, .decelerating: .user"), "\(motion)")
        #expect(motion.contains("default: .other"), "\(motion)")
        // The app keeps no trail of its own: the core's watch decides.
        let sources = try Self.code(Self.sources)
        for file in [layer, sources] {
            #expect(!file.contains("BarTrail(") && !file.contains("anchor") && !file.contains("lostSight"), "a trail in the app")
        }
        let note = try Self.body(["final class QuickCreateMomentSources", "func note(_ source: Source"], in: sources)
        #expect(!note.contains("trail") && !note.contains("watch"), "the cards' frames feed the trail again: \(note)")
        let open = try Self.body(["final class QuickCreateMomentSources", "var barOpen: Bool"], in: sources)
        #expect(open.contains("watch.barOpen"), "\(open)")
        let show = try Self.body(["final class QuickCreateMomentSources", "func show(place"], in: sources)
        #expect(show.contains("watch.show(place: token, shown, now: Self.now)"), "\(show)")
        // A tab chosen in code (Siri, Spotlight, the analysis card) may come with a shrunk bar.
        let chosen = try Self.body(["final class QuickCreateMomentSources", "func tabChosenInCode()"], in: sources)
        #expect(chosen.contains("watch.tabChosenInCode()"), "\(chosen)")
        let tabs = try Self.code(Self.tabs)
        let route = try #require(AppSource.body(of: [".onChange(of: model.route, initial: true)"], in: tabs), "the route is gone")
        let mark = try #require(route.range(of: "if tab != .suggestions { QuickCreateMomentSources.shared.tabChosenInCode() }"), "\(route)")
        let chooses = try #require(route.range(of: "tab = .suggestions"), "\(route)")
        #expect(mark.upperBound <= chooses.lowerBound, "\(route)")
    }

    /// The cover lands on "Alben": the third of three tabs beside the round search button, as
    /// `QuickCreateMoment.TabBar` places it. The search tab names itself (the prominent role of
    /// iOS 27 has no system label) and stands apart at the bar's end by its role, so it is not one
    /// of the three.
    @Test func theAlbumsTabIsWhereTheMomentLands() throws {
        let tabs = try Self.code(Self.tabs)
        let main = try Self.body(["struct MainTabs", "var body: some View"], in: tabs)
        let search = "Tab(\"Suchen\", systemImage: \"magnifyingglass\", value: MainTab.search, role: Self.searchRole)"
        #expect(main.components(separatedBy: search).count - 1 == 1, "no round search button beside the tabs")
        let titles = main.matches(of: /Tab\("([^"]+)"/).map { String($0.output.1) }
        #expect(titles.last == "Suchen", "the search is not the last tab: \(titles)")
        let row = titles.dropLast()
        #expect(row.count == QuickCreateMoment.TabBar.tabs, "\(titles)")
        #expect(row.firstIndex(of: "Alben") == QuickCreateMoment.TabBar.albumsIndex, "\(titles)")
        let roles = main.matches(of: /Tab\("[^"]+"[^)]*\)/).map { String($0.output) }.filter { $0.contains("role:") }
        #expect(roles == [search], "a tab of the row takes a role: \(roles)")
    }

    /// Each card that offers "Anlegen" marks itself with one line, with its suggestion as the card
    /// shows it and the cover's own aspect ratio; nothing else marks a card.
    @Test func eachCardMarksWhereTheMomentStarts() throws {
        let expected = [Self.start: "style == .large ? 2 : 3.0 / 2.0", Self.list: "4.0 / 3.0"]
        for (path, ratio) in expected {
            let lines = try AppSource.read(path).split(separator: "\n").filter { $0.contains(Self.mark) }
            #expect(lines.count == 1, "\(path): \(lines)")
            let line = try #require(lines.first)
            #expect(line.contains(".quickCreateMomentSource(proposal, aspectRatio: \(ratio))"), "\(line)")
        }
        // The ratios are the ones the cards draw their covers at.
        let start = try Self.code("App/Albumist/Views/Start/StartProposalCard.swift")
        // The start card is built from small typed parts (Xcode's type checker, wave 2 H7): its
        // photo card takes the ratio from its own property.
        let startCard = try Self.body(["struct StartProposalCard", "private var photoCard: some View"], in: start)
        #expect(startCard.contains("aspectRatio: aspectRatio"), "\(startCard)")
        let startRatio = try Self.body(["struct StartProposalCard", "private var aspectRatio: CGFloat"], in: start)
        #expect(startRatio.contains("style == .large ? 2 : 3.0 / 2.0"), "\(startRatio)")
        let list = try Self.code(Self.list)
        let listCard = try Self.body(["var photoCard: some View"], in: list)
        #expect(listCard.contains("PhotoCard(") && !listCard.contains("aspectRatio:"), "\(listCard)")
        let card = try Self.code(Self.card)
        #expect(card.contains("aspectRatio: CGFloat = 4.0 / 3.0"), "PhotoCard's own ratio changed")
        var marked: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") where !AppSource.calls(of: ".quickCreateMomentSource(", in: try AppSource.read(path)).isEmpty {
            marked.append(path)
        }
        #expect(Set(marked) == Set(expected.keys), "\(marked)")
    }

    /// Where the tab bar begins is measured on every tab's screen, where the banner shows, and
    /// only while that tab shows; the cards note where they are, and on which tab, while on
    /// screen. Both measures are taken inside the area they ignore: what `ignoresSafeArea()`
    /// itself reports is the safe frame (review E of design wave 2, finding 2). The tabs' screens
    /// noted are pruned (finding 14).
    @Test func theTabBarIsMeasuredWhereTheBannerShows() throws {
        let banner = try Self.code(Self.banner)
        let shows = try Self.body(["func showsQuickCreateBanner()"], in: banner)
        #expect(shows.contains(".modifier(QuickCreateMomentBarProbe())"), "\(shows)")
        let layer = try Self.code(Self.layer)
        let probe = try Self.body(["struct QuickCreateMomentBarProbe", "func body(content: Content)"], in: layer)
        #expect(probe.contains(".environment(\\.quickCreateMomentPlace, token)"), "\(probe)")
        #expect(probe.contains("QuickCreateMomentSources.shared.show(place: token, true)"), "\(probe)")
        #expect(probe.contains(".onDisappear { QuickCreateMomentSources.shared.show(place: token, false) }"), "\(probe)")
        let measured = try Self.body(["struct QuickCreateMomentBarProbe", "var probe: some View"], in: layer)
        #expect(measured.contains("proxy.safeAreaInsets"), "\(measured)")
        let drawn = try Self.body(["struct QuickCreateMomentLayer", "var body: some View"], in: layer)
        for (name, code) in [("probe", measured), ("layer", drawn)] {
            let measure = try #require(code.range(of: ".onGeometryChange("), "\(name): \(code)")
            let ignores = try #require(code.range(of: ".ignoresSafeArea()"), "\(name): \(code)")
            #expect(measure.lowerBound < ignores.lowerBound, "\(name) measures outside the area it ignores")
        }
        let source = try Self.body(["struct QuickCreateMomentSource:", "func body(content: Content)"], in: layer)
        #expect(source.contains(".onDisappear { QuickCreateMomentSources.shared.forget(token) }"), "\(source)")
        #expect(source.contains(".onAppear"), "a card back on screen is not noted again: \(source)")
        let note = try Self.body(["struct QuickCreateMomentSource:", "func note("], in: layer)
        #expect(note.contains("place: place"), "\(note)")
        // Pruned in the core (`QuickCreateMomentBarTests.theTabsScreensArePruned`).
        let places = try Self.body(["final class QuickCreateMomentSources", "func note(_ place: Place"], in: try Self.code(Self.sources))
        #expect(places.contains("watch.measured("), "the tabs' screens are never pruned: \(places)")
    }
}
