import Foundation

/// The small moment after "Anlegen" on a card (draft E6, design wave 2): as the banner
/// "„Name“ angelegt · Widerrufen" comes, a small copy of the card's cover flies towards the tab
/// "Alben" and fades into the tab bar as it reaches it. This decides when, where and along which
/// path; the app draws it (`QuickCreateMomentLayer`), over the tabs only, where the banner shows,
/// never to be tapped and hidden from VoiceOver (decorative: the banner says what happened).
///
/// - It flies only from a card on screen whose sharp cover from the device is at hand (the very
///   image the card shows); the suggestion's page, a placeholder or "Vorschau ausgeblendet" make
///   no flight.
/// - Only into a tab bar that is open (`BarTrail`): it shrinks to one round button while the
///   content scrolls down, and then "Alben" is not there (review E of design wave 2, finding 5).
/// - Reduce Motion: nothing flies and nothing rests on the bar; the banner says it.
/// - No haptic of its own: the album's one haptic is the success tap with its banner, as before
///   the moment, whether or not the cover flies (finding 6).
/// - The tab: "Alben" is the third of three tabs in the floating bar, left of the round search
///   button (`TabBar`). The app is iPhone only and portrait only, so its place follows from the
///   screen's width and where the bar begins; no view of the system is looked up. The cover only
///   heads there and is gone as it reaches the bar, so a few points there do not show (finding 4).
///
/// Points as the app measures them (`.global`), y downwards.
public enum QuickCreateMoment {
    public enum Kind: Hashable, Sendable {
        /// The cover flies from the card towards the tab "Alben" and fades into the bar.
        case fly
        /// Nothing to show: the banner says it.
        case none
    }

    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Rect: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
    }

    /// Whether the cover flies: from a card on screen with its sharp cover at hand, into a tab bar
    /// that is open, never with Reduce Motion.
    public static func kind(reduceMotion: Bool, sourceOnScreen: Bool, hasSharpCover: Bool, barOpen: Bool) -> Kind {
        guard !reduceMotion, sourceOnScreen, hasSharpCover, barOpen else { return .none }
        return .fly
    }

    /// What the movement of the cards on a tab says of its tab bar, which shrinks to one round
    /// button as the content scrolls down (`.tabBarMinimizeBehavior(.onScrollDown)`) and opens
    /// again as it scrolls back up. No view of the system says whether it is open, so the cover
    /// flies only while this is sure it is: on a tab just chosen (the bar was open to choose it), as
    /// long as the content did not scroll down, or once it scrolled back up by `opensAfter`
    /// (review E of design wave 2, finding 5). The app makes a new one as another tab shows.
    public struct BarTrail: Hashable, Sendable {
        /// Content that moves up by more than this (scrolled down) may have shrunk the bar.
        public static let minimizesAfter = 8.0
        /// Content that moves down by this much (scrolled back up) has opened it again.
        public static let opensAfter = 32.0
        /// A step larger than this is the list laid out anew (a card came or went, a section
        /// opened), not a scroll: a scroll moves the cards a little with every frame.
        public static let largestScrollStep = 100.0

        public private(set) var isOpen = true
        /// How far the content moved up (scrolled down), or down, since it last turned.
        private var up = 0.0
        private var down = 0.0

        public init() {}

        /// The cards moved by `dy` points (downwards positive) since they were last seen.
        public mutating func moved(by dy: Double) {
            guard dy != 0, abs(dy) <= Self.largestScrollStep else { return }
            if dy < 0 {
                up -= dy
                down = 0
                if up > Self.minimizesAfter { isOpen = false }
            } else {
                down += dy
                up = 0
                if down >= Self.opensAfter { isOpen = true }
            }
        }

        /// No card of the tab is in sight any more (a screen was pushed over them): what its
        /// content does meanwhile is not seen, so the bar may be shrunk when they come back.
        public mutating func lostSight() {
            isOpen = false
            up = 0
            down = 0
        }
    }

    /// The floating tab bar of iOS 26 on an iPhone, as drawn in the drafts: a capsule with the
    /// three tabs, beside it the round search button.
    public enum TabBar {
        /// From the screen's edges.
        public static let margin = 16.0
        public static let searchSide = 62.0
        /// Between the capsule and the search button.
        public static let gap = 10.0
        /// Inside the capsule, around its tabs.
        public static let inset = 4.0
        public static let height = 62.0
        public static let tabs = 3
        /// "Vorschläge", "Unsortiert", "Alben".
        public static let albumsIndex = 2
        /// The symbol sits above the middle of its tab, its name below it.
        public static let symbolLift = 7.5
        /// The least room the bar takes below the tabs' content (49 pt on a 4.7-inch iPhone): with
        /// less, a screen hid the tab bar and only the home indicator's room is left.
        public static let minimumHeight = 44.0

        /// The middle of the symbol of "Alben": the bar begins at `barTop` (where the tabs' content
        /// ends its safe area) and reaches to `screenBottom`. Nil without a tab bar.
        public static func albumsTab(screenWidth: Double, barTop: Double, screenBottom: Double, rightToLeft: Bool) -> Point? {
            guard screenWidth > 0, screenBottom - barTop >= minimumHeight else { return nil }
            let capsuleEnd = screenWidth - margin - searchSide - gap
            let tabWidth = (capsuleEnd - margin - 2 * inset) / Double(tabs)
            let x = margin + inset + tabWidth * (Double(albumsIndex) + 0.5)
            let barHeight = max(0, screenBottom - barTop)
            let y = barTop + min(height / 2, barHeight / 2) - symbolLift
            return Point(x: rightToLeft ? screenWidth - x : x, y: y)
        }
    }

    /// A card's cover is a strip three times as wide as high at the accessibility text sizes
    /// (`PhotoCard`), otherwise its own aspect ratio.
    public static func shownAspectRatio(_ aspectRatio: Double, accessibilitySize: Bool) -> Double {
        max(accessibilitySize ? max(aspectRatio, 3) : aspectRatio, 0.1)
    }

    /// The size in pixels the card's `CoverPhoto` asked Photos for, and kept its sharp cover at:
    /// the width and height in whole points, times the screen's scale.
    public static func coverPixels(cardWidth: Double, aspectRatio: Double, accessibilitySize: Bool,
                                   scale: Double) -> (width: Double, height: Double) {
        let ratio = shownAspectRatio(aspectRatio, accessibilitySize: accessibilitySize)
        return (cardWidth.rounded(.up) * scale, (cardWidth / ratio).rounded(.up) * scale)
    }

    /// Where the cover is on a card: across its top.
    public static func coverFrame(card: Rect, aspectRatio: Double, accessibilitySize: Bool) -> Rect {
        Rect(x: card.x, y: card.y, width: card.width,
             height: card.width / shownAspectRatio(aspectRatio, accessibilitySize: accessibilitySize))
    }

    /// Whether the middle of the cover is to be seen: below `top`, above `bottom` (where the tab
    /// bar begins) and across the screen's width.
    public static func isOnScreen(_ cover: Rect, top: Double, bottom: Double, width: Double) -> Bool {
        cover.midY > top && cover.midY < bottom && cover.midX > 0 && cover.midX < width
    }

    /// The path of the flying cover (draft E6: 60, 44, then 26 pt): it lifts off the middle of
    /// the card's photo as a faint copy, gets solid on its way, falls and swings towards the tab,
    /// shrinking to the size of the tab's symbol, and fades out as it reaches the bar.
    public struct Flight: Hashable, Sendable {
        public var start: Point
        public var end: Point
        /// The curve's pull: below the start, most of the way down, so the cover falls first and
        /// swings into the tab at the end.
        public var control: Point
        public var startSide: Double

        public static let endSide = 26.0
        public static let duration = 0.7
        /// From here on (of the way) it fades, and is gone at the end: by the bar's edge it is
        /// mostly gone, so it never lands on a point of the bar that is worked out rather than read.
        public static let fadeFrom = 0.7

        public init(cover: Rect, to tab: Point) {
            start = Point(x: cover.midX, y: cover.midY)
            end = tab
            control = Point(x: start.x + 0.05 * (tab.x - start.x), y: start.y + 0.72 * (tab.y - start.y))
            // A third of the photo's height, as in the draft (60 pt from a 180 pt photo).
            startSide = min(72, max(44, cover.height / 3))
        }

        /// Where its middle is at `t` (0 at the card, 1 on the tab).
        public func point(at t: Double) -> Point {
            let t = min(1, max(0, t)), u = 1 - t
            return Point(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                         y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }

        /// Its side at `t`.
        public func side(at t: Double) -> Double {
            let t = min(1, max(0, t))
            return startSide + (Self.endSide - startSide) * t
        }

        /// A faint copy as it lifts off, solid from 40 % of the way, fading from `fadeFrom` to
        /// nothing at the end.
        public func opacity(at t: Double) -> Double {
            let t = min(1, max(0, t))
            let lift = min(1, 0.35 + 0.65 * t / 0.4)
            let fade = t <= Self.fadeFrom ? 1 : (1 - t) / (1 - Self.fadeFrom)
            return min(lift, fade)
        }
    }
}
