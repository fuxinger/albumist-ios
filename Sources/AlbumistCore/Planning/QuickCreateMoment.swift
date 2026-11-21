import Foundation

/// The small moment after "Anlegen" on a card (draft E6, design wave 2): as the banner
/// "„Name“ angelegt · Widerrufen" comes, a small copy of the card's cover flies into the tab
/// "Alben" and lands there as a small album, with one light tap. This decides when, where and
/// along which path; the app draws it (`QuickCreateMomentLayer`), over the tabs only, where the
/// banner shows, never to be tapped and hidden from VoiceOver (decorative: the banner says what
/// happened).
///
/// - It flies only from a card on screen whose sharp cover from the device is at hand (the very
///   image the card shows); the suggestion's page, a placeholder or "Vorschau ausgeblendet" make
///   no flight.
/// - Reduce Motion: nothing flies; the small album fades in on the tab and out again.
/// - One haptic per album, as before: the success tap with the banner, or, when the cover flies,
///   the light tap as it lands instead.
/// - The tab: "Alben" is the third of three tabs in the floating bar, left of the round search
///   button (`TabBar`). The app is iPhone only and portrait only, so its place follows from the
///   screen's width and where the bar begins; no view of the system is looked up.
///
/// Points as the app measures them (`.global`), y downwards.
public enum QuickCreateMoment {
    public enum Kind: Hashable, Sendable {
        /// The cover flies from the card into the tab "Alben".
        case fly
        /// Reduce Motion: the small album fades in on the tab and out again.
        case fadeAtTab
        /// Nothing to show.
        case none
    }

    /// The one haptic of an album made with "Anlegen".
    public enum Haptic: Hashable, Sendable {
        /// The success tap as the banner comes (as before the moment).
        case successWithBanner
        /// A light tap as the flying cover lands on the tab, instead of the success tap.
        case lightTapAtLanding
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

    public static func kind(reduceMotion: Bool, sourceOnScreen: Bool, hasSharpCover: Bool) -> Kind {
        guard sourceOnScreen, hasSharpCover else { return .none }
        return reduceMotion ? .fadeAtTab : .fly
    }

    public static func haptic(for kind: Kind) -> Haptic {
        kind == .fly ? .lightTapAtLanding : .successWithBanner
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

        /// The middle of the symbol of "Alben": the bar begins at `barTop` (where the tabs' content
        /// ends its safe area) and reaches to `screenBottom`.
        public static func albumsTab(screenWidth: Double, barTop: Double, screenBottom: Double, rightToLeft: Bool) -> Point {
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
    /// the card's photo as a faint copy, gets solid on its way, falls and swings into the tab, and
    /// lands the size of the tab's symbol.
    public struct Flight: Hashable, Sendable {
        public var start: Point
        public var end: Point
        /// The curve's pull: below the start, most of the way down, so the cover falls first and
        /// swings into the tab at the end.
        public var control: Point
        public var startSide: Double

        public static let endSide = 26.0
        public static let duration = 0.7

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

        /// A faint copy as it lifts off, solid from 40 % of the way.
        public func opacity(at t: Double) -> Double {
            min(1, 0.35 + 0.65 * max(0, t) / 0.4)
        }
    }
}
