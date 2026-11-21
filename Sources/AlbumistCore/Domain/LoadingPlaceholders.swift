import Foundation

/// What one page of the photo view shows of its photo or video's still once Photos answered
/// (design wave 3, DS-18: "ruhige Platzhalter beim Laden statt grauer Flächen und Kreisel"), as
/// in Photos: the picture, when it is sharp at the screen's size. When no sharp picture comes
/// (only Photos' small preview is on the iPhone, the photo itself is in iCloud, or Photos has
/// nothing), the calm note says why, for a video once the video is known not to play
/// (`ViewerPage`): no big blurry picture is left standing (design rule 6).
/// Until Photos answers, the page waits by itself with the thumbnail the grid showed, from
/// memory, fitted as the picture will be (the black page without one), never a spinner.
public enum ViewerPicture: Equatable, Sendable {
    /// The picture.
    case sharp
    /// No sharp picture will come: "Dieses Foto ist gerade nicht verfügbar."
    case unavailable

    /// How much of the pixels it fills a picture must bring, per side, to count as sharp: the
    /// grids' and the covers' measure (`ThumbnailRequest.sharpShare`).
    public static let sharpShare = 0.7

    /// - Parameters:
    ///   - delivered: The pixels of the picture Photos delivered; nil when none came.
    ///   - original: The photo's own pixels, as Photos knows them, if known.
    ///   - screen: The page's area in pixels.
    public static func choose(delivered: PixelSize?, original: PixelSize?, screen: PixelSize) -> ViewerPicture {
        guard let delivered, !delivered.isEmpty else { return .unavailable }
        return isSharp(delivered, original: original, on: screen) ? .sharp : .unavailable
    }

    /// Sharp on `screen`, fitted (the photo view shows the whole picture): stretched by at most
    /// 1 / `sharpShare`. A photo that is small itself (an old 640 × 480 photo) is sharp as large
    /// as it is: the picture is the whole photo (at least `sharpShare` of its pixels per side),
    /// not a preview of it.
    static func isSharp(_ picture: PixelSize, original: PixelSize?, on screen: PixelSize) -> Bool {
        guard !screen.isEmpty else { return true }
        let stretch = min(screen.width / picture.width, screen.height / picture.height)
        if stretch * sharpShare <= 1 { return true }
        guard let original, !original.isEmpty else { return false }
        return picture.width >= original.width * sharpShare && picture.height >= original.height * sharpShare
    }
}

/// What one page of the photo view shows (DS-16, DS-18; review V1 of design wave 3): the picture
/// once its still came sharp or its video plays over it; the calm note only once nothing will
/// come, for a video only once the video itself is known not to play. Until then the page waits
/// by itself with the grid's thumbnail from memory (the black page without one): a video's small
/// poster frame made its page say "nicht verfügbar" for the moment the video took to come, before
/// every such video and again after a swipe away and back.
public enum ViewerPage: Equatable, Sendable {
    /// The sharp still, and over it the video while it has its player.
    case picture
    /// The grid's thumbnail from memory, fitted as the picture will be; without one the black page.
    case waiting
    /// "Dieses Foto ist gerade nicht verfügbar." / "Dieses Video ist gerade nicht verfügbar."
    case unavailable

    /// - Parameters:
    ///   - still: What Photos' answer for the still was (`ViewerPicture.choose`); nil until it answered.
    ///   - playing: The page's video has its player: it is its own sharp picture (review F, F6).
    ///   - video: For a video, where it is for this page: `.unknown` while it is not asked for or
    ///     not answered (also on a page beside the one on screen, or swiped away and back). Nil for
    ///     a photo.
    public static func shows(still: ViewerPicture?, playing: Bool, video: VideoAvailability?) -> ViewerPage {
        if still == .sharp || playing { return .picture }
        guard still == .unavailable else { return .waiting }
        switch video {
        case nil, .onlyInICloud, .unavailable: return .unavailable
        case .unknown, .onDevice: return .waiting
        }
    }
}

/// A picture's size in pixels.
public struct PixelSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    var isEmpty: Bool { !(width >= 1 && height >= 1) }
}

/// How a grid's thumbnail shows its photo once it is there (DS-18): one that was in memory, or
/// came at once, is simply there, so a cell rebuilt or scrolled back never flickers; one that
/// took a moment fades in, as the covers do (`CoverPhoto`). A fade with Reduce Motion too: it
/// does not move.
public enum ThumbnailAppearance {
    /// What "at once" is: within this many seconds nobody sees a ground before the photo.
    public static let quick = 0.06
    /// The fade's length in seconds.
    public static let fadeLength = 0.2

    /// The fade's length in seconds, or nil: at once.
    /// - Parameters:
    ///   - seeded: The thumbnail started with the photo from memory.
    ///   - waited: Seconds from asking until the photo came.
    public static func fade(seeded: Bool, waited: Double) -> Double? {
        guard !seeded, waited >= quick else { return nil }
        return fadeLength
    }
}

/// The ground of a thumbnail while its photo comes (DS-18): a soft wash of the accent over the
/// card, top-leading to bottom-trailing, the family of the covers' placeholder (`CoverPhoto`),
/// never a flat grey slab. Lighter than a cover's (0.16 to 0.06): in a grid there are many. A
/// little stronger in dark mode, where the card is dark and a faint wash vanishes, and with
/// Increase Contrast, so the tile keeps its edge on the page; never strong enough to be a
/// coloured block. The opacities of the accent at the two ends.
public struct ThumbnailGroundTint: Equatable, Sendable {
    public let top: Double
    public let bottom: Double

    public init(dark: Bool, increasedContrast: Bool) {
        let extra = increasedContrast ? 0.06 : 0
        top = (dark ? 0.16 : 0.12) + extra
        bottom = (dark ? 0.07 : 0.05) + extra
    }
}

/// A video's length on its thumbnail (DS-16) stands in its corner only where it leaves most of
/// the photo free: at most 60 % of the tile's width (in a dense grid or at a large text size it
/// gives way; VoiceOver still says the length).
public enum VideoBadge {
    public static let widestShare = 0.6

    public static func fits(badgeWidth: Double, tileWidth: Double) -> Bool {
        guard tileWidth >= 1, badgeWidth > 0 else { return false }
        return badgeWidth <= tileWidth * widestShare
    }
}
