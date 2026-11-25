import Foundation

/// Whether the tab bar is open as "Anlegen" makes an album, so the small moment's cover flies
/// only into an open bar (draft E6; review E of design wave 2, finding 5). iOS shrinks the bar to
/// one round button as the user scrolls down (`.tabBarMinimizeBehavior(.onScrollDown)`) and opens
/// it as they scroll back up; no view of the system says which it is.
///
/// It is read from the scroll itself: the offset of the screens whose cards offer "Anlegen" (the
/// start page and the suggestion list, `onScrollGeometryChange`) and whether the user moves it
/// (`onScrollPhaseChange`). The cards' places on screen also change when something above them
/// changes height, and a bounce at the top gives back what the pull took; read from the cards,
/// both counted as scrolls (review E2 of design wave 2, N1 and N2). Which screen counts, a new
/// trail per tab, a pop and a tab switch are decided here too, so they are tested (N6).
///
/// What only a device can tell is decided the safe way (no flight), except where that would make
/// the cover rare at the top of the start page, where draft E6 shows it: after a pop the bar
/// counts as open at the top of the list. Device checks: the bar after a pop, after a refresh,
/// after a tab chosen by Siri; whether the large title's room counts in `contentInsets.top`.
extension QuickCreateMoment {
    /// One reading of a screen that scrolls, as `onScrollGeometryChange` gives it: points, y
    /// downwards, in the offset's terms (`contentOffset.y`).
    public struct ScrollSpot: Hashable, Sendable {
        /// How far the content is scrolled (`contentOffset.y`); it grows as the list scrolls down.
        public var offset: Double
        /// The offset at which the content rests at its top, below the bars (`-contentInsets.top`).
        /// While a refresh shows its spinner it lies further up by the spinner's height.
        public var top: Double
        /// The offset at the content's end (`contentSize.height + contentInsets.bottom -
        /// containerSize.height`); below `top` for content that fits the screen.
        public var end: Double

        public init(offset: Double, top: Double, end: Double) {
            self.offset = offset
            self.top = top
            self.end = end
        }

        /// The offset within the content: pulled beyond its top or its end, it is at that edge (the
        /// list bounces back by itself, which is no scroll).
        public var clamped: Double {
            min(max(offset, top), max(top, end))
        }

        /// At the top, or pulled down beyond it.
        public var isAtTop: Bool {
            offset <= top + BarTrail.edge
        }
    }

    /// What moves a screen's content.
    public enum ScrollMotion: Hashable, Sendable {
        /// The user: a finger on it, or the list slowing down after it (`ScrollPhase` tracking,
        /// interacting, decelerating).
        case user
        /// Nothing the user does: at rest while something above the cards changes height or a
        /// card comes or goes, or animated by the system, such as the end of a refresh (`idle`,
        /// `animating`). Never a scroll.
        case other
    }

    /// What the scroll of the screen that shows says of the tab bar: open on a tab just chosen
    /// (it was open to choose it), shrunk once the user scrolled down by more than
    /// `minimizesAfter`, open again once they scrolled back up by `opensAfter` or reached the top,
    /// or pulled down there. Only the user's scroll counts, within the content: a layout change
    /// (N1), a bounce at either end, the end of a refresh (N2) move nothing.
    public struct BarTrail: Hashable, Sendable {
        /// Scrolled down by more than this, the bar may have shrunk.
        public static let minimizesAfter = 8.0
        /// Scrolled back up by this much, it has opened again.
        public static let opensAfter = 32.0
        /// Points from the top that still count as the top (offsets are fractions of a point).
        public static let edge = 1.0

        public private(set) var isOpen: Bool
        /// The last reading of the screen that feeds the trail (`ScrollSpot.clamped`); nil before
        /// its first one, which is no scroll.
        private var last: Double?
        /// How far the user scrolled up, or down, since the scroll last turned.
        private var up = 0.0
        private var down = 0.0

        public init(isOpen: Bool = true) {
            self.isOpen = isOpen
        }

        /// A new reading of the screen that feeds the trail.
        public mutating func scrolled(to spot: ScrollSpot, _ motion: ScrollMotion) {
            let now = spot.clamped
            defer { last = now }
            guard motion == .user, let last else { return }
            let dy = now - last
            if dy > 0 {
                down += dy
                up = 0
                if down > Self.minimizesAfter { isOpen = false }
            } else {
                if dy < 0 {
                    up -= dy
                    down = 0
                }
                // Back at the top, or pulled down there: open, however little it took.
                if up >= Self.opensAfter || spot.isAtTop { isOpen = true }
            }
        }

        /// Another screen feeds the trail from now on (`spot`: its last reading): what it shows is
        /// where its next reading counts from.
        public mutating func follow(_ spot: ScrollSpot?) {
            last = spot?.clamped
            up = 0
            down = 0
        }

        /// Back on a screen after others showed over it (a pop): they may have changed the bar
        /// unseen. Open at the top of the list (where draft E6 shows the moment; a device check),
        /// else shrunk until the user scrolls back up. A screen without a reading (`spot` nil)
        /// never scrolled: it is at its top.
        public mutating func cameBack(to spot: ScrollSpot?) {
            isOpen = Self.isAtTop(spot)
            follow(spot)
        }

        static func isAtTop(_ spot: ScrollSpot?) -> Bool {
            spot?.isAtTop ?? true
        }
    }

    /// A tab's screen as `QuickCreateMomentBarProbe` measures it, over the whole screen with its
    /// safe area (points, `.global`): where the tab bar begins, and where the safe area begins at
    /// the top (the status bar's edge).
    public struct TabPlace: Hashable, Sendable {
        public var barTop: Double
        public var top: Double

        public init(barTop: Double, top: Double) {
            self.barTop = barTop
            self.top = top
        }
    }

    /// What the small moment knows of the tabs: which tab's screen shows and where its bar begins
    /// (`measured`, `show`), the screens with cards that scroll on it (`appeared`, `scrolled`,
    /// `disappeared`) and what their scroll says of the bar (`barOpen`). The app tells it as
    /// things happen and asks once per banner (`QuickCreateMomentSources`).
    ///
    /// - Only the screen on top of the tab that shows feeds the trail (during a push both show);
    ///   a screen's first reading is no scroll.
    /// - Another tab: a new trail, open (the bar was open to choose the tab); its screens showing
    ///   with it (within `arrivalTime`, before or after it) are no pop. A tab chosen in code (Siri,
    ///   Spotlight) may come with a shrunk bar: the new trail counts it as shrunk.
    /// - A push keeps the trail. A pop (a screen shows again on its own): open at the top, else
    ///   shrunk (`BarTrail.cameBack`), once the screens it came back over are gone; a back swipe
    ///   the user takes back leaves the trail as it was.
    /// - At most `keptPlaces` tabs' screens are kept: the one measured longest ago that does not
    ///   show goes first, and is measured again when it shows (review E of design wave 2,
    ///   finding 14).
    public struct TabWatch: Sendable {
        /// Four tabs, and screens made anew.
        public static let keptPlaces = 8
        /// Screens that show this soon after their tab came with it (seconds).
        public static let arrivalTime = 0.5

        /// Each tab's screen, the order they were measured in (the latest last), and the tabs
        /// that show, the one shown last at the end.
        private(set) var places: [UUID: TabPlace] = [:]
        private var placesMeasured: [UUID] = []
        private var shownPlaces: [UUID] = []
        /// When a tab last showed (seconds, the app's clock).
        private var shownAt = -Double.infinity
        private var chosenInCode = false
        /// The tab bar's trail, the tab it is for, and the screen whose readings it follows.
        public private(set) var trail = BarTrail()
        private var trailPlace: UUID?
        private var fedBy: UUID?
        /// The screens with cards that show, in the order they appeared, with their tabs.
        private var screens: [TabWatchScreen] = []
        private var returning: TabWatchReturn?

        public init() {}

        /// The tab's screen that shows; nil while none does (another screen covers the tabs).
        public var shownPlace: UUID? {
            shownPlaces.last
        }

        /// Where the bar begins on the tab that shows; nil before it was measured.
        public var place: TabPlace? {
            shownPlace.flatMap { places[$0] }
        }

        /// The screen whose scroll counts: the one that appeared last on the tab that shows.
        public var feeding: UUID? {
            guard let shownPlace else { return nil }
            return screens.last { $0.place == shownPlace }?.screen
        }

        /// Whether the tab bar is open, as far as the scroll tells.
        public var barOpen: Bool {
            if let returning, returning.screen == feeding { return BarTrail.isAtTop(returning.spot) }
            return trail.isOpen
        }

        /// A tab's screen was measured (`QuickCreateMomentBarProbe`).
        public mutating func measured(_ place: TabPlace, for token: UUID) {
            places[token] = place
            placesMeasured.removeAll { $0 == token }
            placesMeasured.append(token)
            while placesMeasured.count > Self.keptPlaces, let old = placesMeasured.first(where: { !shownPlaces.contains($0) }) {
                placesMeasured.removeAll { $0 == old }
                places[old] = nil
            }
        }

        /// A tab's screen shows (`shown`) or went (another tab chosen, or a screen covers the
        /// tabs). Another tab than before: a new trail.
        public mutating func show(place token: UUID, _ shown: Bool, now: Double) {
            shownPlaces.removeAll { $0 == token }
            if shown {
                shownPlaces.append(token)
                shownAt = now
            }
            guard let place = shownPlaces.last, place != trailPlace else { return }
            trail = BarTrail(isOpen: !chosenInCode)
            chosenInCode = false
            trailPlace = place
            fedBy = nil
            returning = nil
        }

        /// The next tab comes without the user's tap on the bar (Siri, Spotlight, a route): the
        /// bar may be shrunk.
        public mutating func tabChosenInCode() {
            chosenInCode = true
        }

        /// A screen with cards shows on the tab `place`; `spot`: its last reading (nil before the
        /// first: it has not scrolled), `again`: it showed before (back after a pop, or with its
        /// tab).
        public mutating func appeared(screen: UUID, on place: UUID, at spot: ScrollSpot?, again: Bool, now: Double) {
            screens.removeAll { $0.screen == screen }
            let over = Set(screens.lazy.filter { $0.place == place }.map(\.screen))
            screens.append(TabWatchScreen(screen: screen, place: place))
            guard again, place == shownPlace, place == trailPlace, now - shownAt > Self.arrivalTime else { return }
            returning = TabWatchReturn(screen: screen, over: over, spot: spot)
            if over.isEmpty { settleReturn() }
        }

        /// A screen with cards went (covered by a push, popped, or its tab left).
        public mutating func disappeared(screen: UUID) {
            screens.removeAll { $0.screen == screen }
            if fedBy == screen { fedBy = nil }
            guard var back = returning else { return }
            if back.screen == screen {
                // A back swipe taken back: the screen on top stays, and so does its trail.
                returning = nil
            } else if back.over.remove(screen) != nil {
                returning = back
                if back.over.isEmpty { settleReturn() }
            }
        }

        /// A screen's new reading; only the one that feeds the trail counts.
        public mutating func scrolled(screen: UUID, to spot: ScrollSpot, _ motion: ScrollMotion) {
            guard screen == feeding else { return }
            if returning?.screen == screen { settleReturn() }
            guard fedBy == screen else {
                trail.follow(spot)
                fedBy = screen
                return
            }
            trail.scrolled(to: spot, motion)
        }

        /// The pop is done: the screen back on top feeds the trail from where it was.
        private mutating func settleReturn() {
            guard let back = returning else { return }
            trail.cameBack(to: back.spot)
            fedBy = back.screen
            returning = nil
        }
    }
}

/// A screen with cards that shows, with its tab (`QuickCreateMoment.TabWatch`).
private struct TabWatchScreen: Hashable, Sendable {
    var screen: UUID
    var place: UUID
}

/// A screen back on top (a pop under way, or a back swipe), with the screens it came back over
/// and its last reading (`QuickCreateMoment.TabWatch`).
private struct TabWatchReturn: Hashable, Sendable {
    var screen: UUID
    var over: Set<UUID>
    var spot: QuickCreateMoment.ScrollSpot?
}
