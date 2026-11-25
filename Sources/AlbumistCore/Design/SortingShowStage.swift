import Foundation

/// The scene of the sorting show (DS-17, design wave 3: "größere Fotos, Album mit Titelbild"):
/// a loose pile of the user's photos at the top, the album the photos fly into below it, and the
/// album's name under its cover. Its sizes follow the width the show gets on screen; at every
/// width the photos are bigger than the 76 pt of before and the album is its real cover, no
/// longer a pale box of 124 pt.
///
/// - The album's cover takes `coverShare` of the width, at least `minimumCover` (the old album)
///   and at most `maximumCover` (the iPad's focused column); a photo is `photoShare` of it, so it
///   shrinks into its album as it lands (`ArcFlight` ends at 62 % of it).
/// - The text size changes only the room under the cover: the scene's labels stop growing at
///   xxLarge (`largeText` from there on), its photos keep their size.
/// - Where the screen is too low for the whole scene (`room`), the pile gives way first: its loose
///   photos lie closer together up and down, and the gap the photos fly through narrows to
///   `minimumFlightGap` (second review, K6). Only what is still missing is scaled away with the
///   whole scene (`SortingShow.sceneScale`), so the counts and "Animation überspringen" stay on
///   screen at every text size. On the 4.7" iPhone (about 313 pt for a scene of 431) the photos
///   show at about 82 pt instead of 73 with the whole scene scaled (76 pt in a scene of 360 pt
///   before DS-17, about 66 pt on that screen).
/// - All in points, whole numbers, so a cover asks Photos for the same pixels every time.
public struct SortingShowLayout: Hashable, Sendable {
    /// How far the pile's loose photos lie from its centre at most, to each side.
    public struct Spread: Hashable, Sendable {
        public var dx: Double
        public var dy: Double
    }

    /// The photos of the show before DS-17: never smaller than these at the scene's own size.
    public static let previousPhoto = 76.0
    /// The album of the show before DS-17, and the smallest cover now.
    public static let minimumCover = 124.0
    public static let maximumCover = 196.0
    public static let coverShare = 0.46
    public static let photoShare = 0.64
    /// The neighbours of the album in the centre are drawn this much smaller.
    public static let neighbourScale = 0.76
    /// Where one of the pile's loose photos lies from the pile's centre, and how it is turned
    /// (degrees).
    public struct Loose: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var angle: Double
    }

    /// The pile's loose photos as they were made for 76 pt photos: offset x, offset y, turn in
    /// degrees (applied at 60 %). Grown with the photo; the offsets up and down at 60 %, so the
    /// bigger photos take less of the screen's height.
    static let loosePhotos = [
        Loose(x: -54, y: -4, angle: -11), Loose(x: 46, y: -12, angle: 8), Loose(x: -14, y: 12, angle: -3),
        Loose(x: 60, y: 16, angle: 13), Loose(x: -66, y: 24, angle: -16), Loose(x: 8, y: -22, angle: 5),
    ]
    static let verticalScatter = 0.6
    /// Above the pile: a turned photo reaches a little higher than its centre plus half its side.
    static let topRoom = 4.0
    /// Between the pile and the album's layers: where the photos fly.
    static let flightGap = 16.0
    /// The gap where the screen is low (`room`): the photos still lift off the pile before they
    /// reach the album.
    public static let minimumFlightGap = 12.0
    /// Between the cover and the album's name.
    public static let labelGap = 8.0

    /// The side of a photo on the pile and in flight.
    public var photo: Double
    /// The side of the album's square cover.
    public var cover: Double
    /// How far the album's two layers reach above its cover (a stack, as an album in Photos).
    public var layers: Double
    /// The corner radius of the cover and its layers.
    public var coverRadius: Double
    /// The corner radius of a photo.
    public var photoRadius: Double
    /// Between the centres of two albums of the strip.
    public var spacing: Double
    /// The loose photos lie at most this far from the pile's centre.
    public var scatter: Spread
    /// How far up and down the loose photos lie, from 1 (as made) to 0 (side by side, where the
    /// screen is low, `room`).
    public var looseness: Double
    /// Between the pile and the album's layers.
    public var gap: Double
    public var pileHeight: Double
    public var pileCenterY: Double
    public var coverCenterY: Double
    /// Below the cover: the album's name (two lines) and its count.
    public var labelRoom: Double
    /// The whole scene, top to the end of the album's count.
    public var height: Double

    /// - Parameters:
    ///   - width: the width the show has on screen, in points (not measured yet: the smallest).
    ///   - largeText: the text size is xxLarge or one of the accessibility sizes.
    ///   - room: the height the screen has for the scene, in points (nil: not measured yet, or
    ///     no limit). Where the scene needs more, the pile gives way first, as far as it can.
    public init(width: Double, largeText: Bool, room: Double? = nil) {
        let width = width.isFinite ? max(0, width) : 0
        cover = min(max(width * Self.coverShare, Self.minimumCover), Self.maximumCover).rounded()
        photo = (cover * Self.photoShare).rounded()
        layers = (cover * 0.11).rounded()
        coverRadius = (cover * 0.16).rounded()
        photoRadius = (photo * 0.17).rounded()
        spacing = (cover * 0.95 + 30).rounded()
        let grown = photo / Self.previousPhoto
        let farthest = Self.loosePhotos.reduce(into: (x: 0.0, y: 0.0)) { far, loose in
            far.x = max(far.x, abs(loose.x))
            far.y = max(far.y, abs(loose.y))
        }
        let spread = farthest.y * grown * Self.verticalScatter
        labelRoom = largeText ? 80 : 66
        // Turned by up to 10°, a photo needs 1.16 of its side.
        let needed = Self.topRoom + (photo * 1.16 + spread.rounded(.up) * 2 + 4).rounded(.up) + Self.flightGap + layers
            + cover + Self.labelGap + labelRoom
        // What the pile can give: its scatter up and down, and the gap down to its minimum.
        let most = spread.rounded(.up) * 2 + Self.flightGap - Self.minimumFlightGap
        var squeeze = 0.0
        if let room, room.isFinite, needed.rounded(.up) > room, most > 0 {
            squeeze = min(1, (needed.rounded(.up) - room) / most)
        }
        looseness = 1 - squeeze
        gap = (Self.flightGap - (Self.flightGap - Self.minimumFlightGap) * squeeze).rounded()
        scatter = Spread(dx: (farthest.x * grown).rounded(.up), dy: (spread * looseness).rounded(.up))
        pileHeight = (photo * 1.16 + scatter.dy * 2 + 4).rounded(.up)
        pileCenterY = Self.topRoom + pileHeight / 2
        let coverTop = Self.topRoom + pileHeight + gap + layers
        coverCenterY = coverTop + cover / 2
        height = (coverTop + cover + Self.labelGap + labelRoom).rounded(.up)
    }

    /// Where the pile's `index`-th loose photo lies, from the pile's centre, and how it is turned
    /// (degrees). The pile repeats the pattern after six photos.
    public func loose(_ index: Int) -> Loose {
        let base = Self.loosePhotos[((index % Self.loosePhotos.count) + Self.loosePhotos.count) % Self.loosePhotos.count]
        let grown = photo / Self.previousPhoto
        return Loose(x: base.x * grown, y: base.y * grown * Self.verticalScatter * looseness, angle: base.angle * 0.6)
    }
}

/// One album of the sorting show (DS-17): what it counts, which of its photos fly from the pile
/// into it, which may be its cover, and whether it shows "Vorschau ausgeblendet" instead.
///
/// The same care as the result's stack of covers (`ResultCoverStack`), so the show and the result
/// that follows it show the same photos and keep the same ones away:
/// - Never a photo of a personal suggestion (`personal`: a sensitive suggestion, one whose card
///   hides its preview, or one the analysis does not know, `ResultCoverStack.personalSources`),
///   also not in another album of the plan (a country holds its trips); its own album shows
///   "Vorschau ausgeblendet", and nothing flies into it. So does an album of only sensitive
///   documents, as its suggestion's card did (`AppModel.previewHidden(for:)`).
/// - Flying: the photos the show let fly before (`FilledAlbum.shown`: ordinary photos first,
///   never a sensitive document), without the personal ones.
/// - Cover: the cover its suggestion's card showed, when the album holds it, then its favourites
///   and newest photos (`PreviewPicker.coverCandidates`: a big cover is a photo, never a
///   screenshot or a document, design rule 9), at most `coverCandidates`, tried in order and
///   shown only sharp from the device (`CoverPhoto`). A photo that already leads an earlier
///   album's cover goes to the end, so two albums side by side do not show the same photo.
public struct SortingShowAlbum: Hashable, Sendable, Identifiable {
    /// The index of the album's last "add photos" step: the album is done once that step is.
    public var lastStep: Int
    public var title: String?
    /// Every photo the plan adds to it: what the show counts.
    public var assets: [AssetID]
    public var flying: [AssetID]
    public var cover: [AssetID]
    public var hidesPreview: Bool

    public var id: Int { lastStep }

    /// As many as a cover tries (`CoverLoader.attempts`).
    public static let coverCandidates = 4

    public init(lastStep: Int, title: String?, assets: [AssetID], flying: [AssetID], cover: [AssetID], hidesPreview: Bool) {
        self.lastStep = lastStep
        self.title = title
        self.assets = assets
        self.flying = flying
        self.cover = cover
        self.hidesPreview = hidesPreview
    }

    /// The albums of the show for `filled` (`ChangePlan.filledAlbums`, in plan order) of `plan`.
    /// `cardCovers`: the cover each suggestion's card showed; `personal`: the suggestions whose
    /// photos never show (`ResultCoverSources`, taken as the plan starts).
    public static func cast(_ filled: [FilledAlbum], plan: ChangePlan, cardCovers: [AlbumistID: AssetID] = [:],
                            personal: Set<AlbumistID> = [], ranks: [AssetID: PreviewRank] = [:],
                            dates: [AssetID: Date] = [:], favorites: Set<AssetID> = []) -> [SortingShowAlbum] {
        // The photos the personal suggestions add: they show in no album.
        var personalPhotos = Set<AssetID>()
        if !personal.isEmpty {
            for step in plan.steps {
                guard let source = step.sourceID, personal.contains(source),
                      case .addAssets(_, let assets) = step.operation else { continue }
                personalPhotos.formUnion(assets)
            }
        }
        var leading = Set<AssetID>()
        return filled.map { album in
            let source = plan.steps.indices.contains(album.lastStep) ? plan.steps[album.lastStep].sourceID : nil
            let onlySensitive = !album.assets.isEmpty && album.assets.allSatisfy { ranks[$0] == .sensitive }
            if onlySensitive || source.map(personal.contains) == true {
                return SortingShowAlbum(lastStep: album.lastStep, title: album.title, assets: album.assets,
                                        flying: [], cover: [], hidesPreview: true)
            }
            let shown: [AssetID]
            let photos: [AssetID]
            if personalPhotos.isEmpty {
                shown = album.shown
                photos = album.assets
            } else {
                photos = album.assets.filter { !personalPhotos.contains($0) }
                shown = PreviewPicker.firstSuited(photos, count: FilledAlbum.shownLimit, ranks: ranks)
            }
            let card = source.flatMap { cardCovers[$0] }
            var cover = PreviewPicker.coverCandidates(Set(photos), cover: card, dates: dates, ranks: ranks,
                                                      favorites: favorites, count: coverCandidates)
            if let first = cover.firstIndex(where: { !leading.contains($0) }), first > 0 {
                cover = Array(cover[first...]) + Array(cover[..<first])
            }
            if let lead = cover.first { leading.insert(lead) }
            return SortingShowAlbum(lastStep: album.lastStep, title: album.title, assets: album.assets,
                                    flying: shown, cover: cover, hidesPreview: false)
        }
    }
}

/// What the sorting show writes of its photos (DS-17), in the line under its count and in its
/// VoiceOver value: their number, grouped as the screen's language writes it ("1.234" in German,
/// "1,234" in English). The sentences around it are the App's catalog ("%lld %@ Fotos
/// einsortiert"): the bare count picks the plural form, this number is what it shows
/// (`SortingShowSourceTests.theCountReadsAsTheCatalogWritesIt`).
public enum SortingShowWords {
    /// `count` grouped as `locale` writes it: "1.234" / "1,234"; below a thousand the digits.
    public static func number(_ count: Int, locale: Locale) -> String {
        count.formatted(.number.locale(locale))
    }
}
