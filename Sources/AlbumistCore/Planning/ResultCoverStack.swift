import Foundation

/// The big moment after a run (draft E3, design wave 2): the covers of the new albums lie fanned
/// above "10 neue Alben", and lie down there one after another. This decides which albums and
/// which of their photos; the app loads only what is sharp on the device (`CoverLoader`, never
/// from iCloud) and lays the covers down (`ResultCoverMoment`).
///
/// - The albums the run made, in the order of the plan ("10 neue Alben"); when it made none, the
///   albums of the user's that got photos ("12 Fotos in 3 deiner Alben ergänzt"). New albums and
///   albums of the user's are never mixed: two covers above "1 neues Album" would count two.
/// - One album is one card, with up to `candidatesPerCard` photos to try for its cover, best
///   first: the cover its suggestion's card showed (`covers`), so the stack shows the photos the
///   user knows from the cards; then its favourites and newest photos, as Photos shows an album
///   (`PreviewPicker.coverCandidates`). Never a sensitive document, a screenshot or another
///   document (a big cover is a photo, design rule 9). Whatever order the plan lists its photos
///   in, the same photos in the same order.
/// - Never an album or a photo of a personal suggestion (`personalSources`: a sensitive suggestion,
///   one whose card hides its preview, "Vorschau ausgeblendet", or one the analysis does not know),
///   and never a photo another card tries before (a country album holds its trips): the same
///   photo never lies on two cards.
/// - At most `tried` albums are tried (one whose photos are only in iCloud makes room for the
///   next), at most `limit` lie on the stack (`limitAtLargestText` at the accessibility text
///   sizes), and four lie as three (`ResultCoverFan.count`).
/// - No stack, the symbol as before, after an undo, a removal, a run with failed steps
///   ("Teilweise fertig") or a run that confirmed nothing.
///
/// Counted as in the receipt: only photos the library confirmed (`ChangePlan.confirmedMedia`).
/// `expected`: before the run, from what the plan sets out to do, so the preview can load the
/// covers while the plan runs (the same albums and photos when everything is done).
public struct ResultCoverStack: Hashable, Sendable {
    /// One album on the stack.
    public struct Card: Hashable, Sendable, Identifiable {
        /// The album as the receipt names it (`PlanReceipt.Album.id`): "planned:" and the plan's
        /// key for a new album, the collection id for an album of the user's.
        public var id: String
        /// The photos its cover tries, best first; none of them is tried by another card.
        public var candidates: [AssetID]

        public init(id: String, candidates: [AssetID]) {
            self.id = id
            self.candidates = candidates
        }
    }

    /// Which albums the stack shows.
    public enum Albums: Hashable, Sendable {
        /// The albums the run made.
        case created
        /// No album was made: the albums of the user's that got photos.
        case extended
    }

    /// One cover on the stack: the card and the photo it shows.
    public struct Shown: Hashable, Sendable {
        public var card: String
        public var photo: AssetID

        public init(card: String, photo: AssetID) {
            self.card = card
            self.photo = photo
        }
    }

    /// Nil when there is no stack.
    public var albums: Albums?
    /// The albums to try, in the order of the plan; the first is the main cover.
    public var cards: [Card]

    /// Covers on the stack at most (draft E3: five).
    public static let limit = 5
    /// At the accessibility text sizes: the stack gives the count and the buttons room.
    public static let limitAtLargestText = 3
    /// Albums tried at most.
    public static let tried = 8
    /// Photos one cover tries at most (as a card's cover, `CoverLoader.attempts`).
    public static let candidatesPerCard = 4

    public var isEmpty: Bool { cards.isEmpty }

    public init(plan: ChangePlan, ranks: [AssetID: PreviewRank] = [:], dates: [AssetID: Date] = [:],
                favorites: Set<AssetID> = [], covers: [AlbumistID: AssetID] = [:],
                personalSources: Set<AlbumistID> = [], expected: Bool = false) {
        albums = nil
        cards = []
        guard PlanReceipt.Kind(plan) == .created, let found = Self.albums(of: plan, expected: expected) else { return }
        let (group, counted) = found

        // The photos of each album in plan order, its suggestion, and what is personal.
        var order: [String] = []
        var seen = Set<String>()
        var media: [String: [AssetID]] = [:]
        var sources: [String: AlbumistID] = [:]
        var personalAlbums = Set<String>()
        var personalPhotos = Set<AssetID>()
        for step in plan.steps {
            let album: String
            var added: [AssetID] = []
            switch step.operation {
            case .createAlbum(let key, _, _):
                album = "planned:" + key
            case .addAssets(let ref, let assets):
                album = Self.id(of: ref)
                added = expected ? assets : plan.confirmedMedia(of: step)
                media[album, default: []].append(contentsOf: added)
            default:
                continue
            }
            if seen.insert(album).inserted { order.append(album) }
            guard let source = step.sourceID else { continue }
            if sources[album] == nil { sources[album] = source }
            if personalSources.contains(source) {
                personalAlbums.insert(album)
                personalPhotos.formUnion(added)
            }
        }

        var used = Set<AssetID>()
        var made: [Card] = []
        for album in order where counted.contains(album) && !personalAlbums.contains(album) {
            guard made.count < Self.tried else { break }
            let photos = Set(media[album] ?? []).subtracting(personalPhotos).subtracting(used)
            guard !photos.isEmpty else { continue }
            // The cover its card showed, when the album holds it.
            let cover = sources[album].flatMap { covers[$0] }.flatMap { photos.contains($0) ? $0 : nil }
            let candidates = PreviewPicker.coverCandidates(photos, cover: cover, dates: dates, ranks: ranks,
                                                           favorites: favorites, count: Self.candidatesPerCard)
            guard !candidates.isEmpty else { continue }
            used.formUnion(candidates)
            made.append(Card(id: album, candidates: candidates))
        }
        guard !made.isEmpty else { return }
        albums = group
        cards = made
    }

    /// The covers that lie on the stack once loaded: card by card in plan order, the photo each
    /// shows (`sharp`: card id → its first photo that is sharp on the device; a card without one
    /// is left out), at most `limit`, four laid as three (`ResultCoverFan.count`).
    public func shown(sharp: [String: AssetID], limit: Int) -> [Shown] {
        var shown: [Shown] = []
        var photos = Set<AssetID>()
        for card in cards where shown.count < max(0, limit) {
            guard let photo = sharp[card.id], card.candidates.contains(photo), photos.insert(photo).inserted else { continue }
            shown.append(Shown(card: card.id, photo: photo))
        }
        return Array(shown.prefix(ResultCoverFan.count(shown.count)))
    }

    /// Which photo each card shows as the result appears (card id → photo): the one kept for it
    /// while the plan ran (`held`: the result's own, so a covers' store emptied meanwhile, by a
    /// memory warning or a moment in the background, does not lose it; review E2 of design wave
    /// 2, N3), else the first of its candidates the covers' store still keeps (`stored`). A kept
    /// photo that is no candidate of its card (a step the library did not confirm) is passed over.
    public func sharpPhotos(held: [String: AssetID], stored: (AssetID) -> Bool) -> [String: AssetID] {
        var sharp: [String: AssetID] = [:]
        for card in cards {
            if let photo = held[card.id], card.candidates.contains(photo) {
                sharp[card.id] = photo
            } else if let photo = card.candidates.first(where: stored) {
                sharp[card.id] = photo
            }
        }
        return sharp
    }

    /// The suggestions of `plan` whose albums and photos stay off the stack (`personalSources`):
    /// the personal ones (`personal`: sensitive, or their card hides its preview) and every one
    /// the analysis does not know (`known`). A step keeps the suggestion it came from, also in
    /// "Fehlendes erneut versuchen" and after the analysis made its suggestions anew, so an
    /// unknown one may have been personal; a plan made by hand has an id of its own, which the
    /// analysis does not know either, and keeps the symbol.
    public static func personalSources(of plan: ChangePlan, known: Set<AlbumistID>, personal: Set<AlbumistID>) -> Set<AlbumistID> {
        let sources = Set(plan.steps.lazy.compactMap(\.sourceID))
        return sources.subtracting(known).union(sources.intersection(personal))
    }

    /// The receipt's name of the album `ref` (`PlanReceipt.Album.id`, `PlanCovers.key`).
    static func id(of ref: AlbumRef) -> String {
        PlanCovers.key(of: ref)
    }

    /// Which albums the stack may show, and their ids: the new ones, else the user's that got
    /// photos; nil when there are none or steps failed.
    private static func albums(of plan: ChangePlan, expected: Bool) -> (Albums, Set<String>)? {
        if expected {
            var created = Set<String>(), extended = Set<String>()
            for step in plan.steps {
                switch step.operation {
                case .createAlbum(let key, _, _): created.insert("planned:" + key)
                case .addAssets(.existing(let id), let assets) where !assets.isEmpty: extended.insert(id.rawValue)
                default: continue
                }
            }
            if !created.isEmpty { return (.created, created) }
            return extended.isEmpty ? nil : (.extended, extended)
        }
        let receipt = PlanReceipt(plan: plan, inventory: CollectionInventory())
        // Steps that did not happen: "Teilweise fertig" under the symbol it always had.
        guard receipt.failedSteps == 0 else { return nil }
        let group: Albums
        if receipt.albumsCreated > 0 {
            group = .created
        } else if receipt.albumsExtended > 0 {
            group = .extended
        } else {
            return nil
        }
        let change: PlanReceipt.Album.Change = group == .created ? .created : .extended
        let ids = Set(receipt.albums.lazy.filter { $0.change == change && $0.added > 0 }.map(\.id))
        return ids.isEmpty ? nil : (group, ids)
    }
}

/// How the covers of the big moment lie (draft E3): the main cover upright in the middle and on
/// top, the others turned 7° and 14° to each side behind it. Points of a 124 × 156 pt cover, the
/// main cover's middle at 0, y downwards; the app scales the fan to fit (`scale`).
public enum ResultCoverFan {
    /// One cover's place.
    public struct Slot: Hashable, Sendable {
        /// Turned by this many degrees (clockwise).
        public var angle: Double
        /// Its middle, from the main cover's middle.
        public var x: Double
        public var y: Double
        /// Higher lies on top.
        public var layer: Int
    }

    public static let cardWidth = 124.0
    public static let cardHeight = 156.0
    /// The stack gives way to what stands below it (the count, the way to Photos, "Alle
    /// Änderungen" and "Rückgängig machen"), but not below six tenths: smaller covers stop being
    /// photos one can make out. The stack keeps this size then and the screen scrolls.
    public static let minimumScale = 0.6

    /// How the covers lie down (`ResultCoverMoment`): one after another, `layingStep` apart, the
    /// main cover last, lying `lastFall` after it began to fall; with Reduce Motion all of them
    /// fade in where they lie over `fadeIn`.
    public static let layingStep = 0.11
    public static let lastFall = 0.3
    public static let fadeIn = 0.35
    /// The success tap comes as the main cover lies down, and the screen never holds it longer
    /// than this after the result shows (`PlanReviewView`), whatever the covers do.
    public static let successDeadline = 1.5

    /// Seconds from the start of the moment until the main cover lies, which is when the success
    /// tap comes: none without covers (the symbol shows at once).
    public static func settleTime(count covers: Int, calm: Bool) -> Double {
        let laid = count(covers)
        guard laid > 0 else { return 0 }
        return calm ? fadeIn : Double(laid - 1) * layingStep + lastFall
    }

    /// How many covers the fan lays: four as three, so the main cover keeps the middle, and five
    /// at most.
    public static func count(_ covers: Int) -> Int {
        let count = min(max(0, covers), ResultCoverStack.limit)
        return count == 4 ? 3 : count
    }

    /// The places of `count` covers (`count(_:)`), the main cover first.
    public static func slots(_ covers: Int) -> [Slot] {
        switch count(covers) {
        case 0: []
        case 1: [Slot(angle: 0, x: 0, y: 0, layer: 1)]
        // Two: the main cover a little to the right and on top, the other peeking out on the
        // left, so the pair stays balanced.
        case 2: [Slot(angle: 4, x: 22, y: 0, layer: 2), Slot(angle: -6, x: -26, y: 8, layer: 1)]
        case 3: [Slot(angle: 0, x: 0, y: 0, layer: 2), Slot(angle: -7, x: -52, y: 9, layer: 1),
                 Slot(angle: 7, x: 52, y: 9, layer: 1)]
        default: [Slot(angle: 0, x: 0, y: 0, layer: 3), Slot(angle: -7, x: -52, y: 9, layer: 2),
                  Slot(angle: 7, x: 52, y: 9, layer: 2), Slot(angle: -14, x: -100, y: 24, layer: 1),
                  Slot(angle: 14, x: 100, y: 24, layer: 1)]
        }
    }

    /// The order the covers lie down in (indices of `slots`): from the back to the front, left
    /// before right, the main cover last.
    public static func layingOrder(_ covers: Int) -> [Int] {
        let slots = slots(covers)
        return slots.indices.sorted { a, b in
            slots[a].layer != slots[b].layer ? slots[a].layer < slots[b].layer : slots[a].x < slots[b].x
        }
    }

    /// The box the turned covers fill, from the main cover's middle (without their shadow).
    public static func bounds(_ covers: Int) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let slots = slots(covers)
        guard !slots.isEmpty else { return (0, 0, 0, 0) }
        var box = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for slot in slots {
            let turn = abs(slot.angle) * .pi / 180
            let halfWidth = (cardWidth * cos(turn) + cardHeight * sin(turn)) / 2
            let halfHeight = (cardWidth * sin(turn) + cardHeight * cos(turn)) / 2
            box.minX = min(box.minX, slot.x - halfWidth)
            box.maxX = max(box.maxX, slot.x + halfWidth)
            box.minY = min(box.minY, slot.y - halfHeight)
            box.maxY = max(box.maxY, slot.y + halfHeight)
        }
        return box
    }

    /// The fan's size at full scale.
    public static func size(_ covers: Int) -> (width: Double, height: Double) {
        let box = bounds(covers)
        return (box.maxX - box.minX, box.maxY - box.minY)
    }

    /// The scale that fits the fan into `width` × `height`: never larger than drawn, never below
    /// `minimumScale`. `height` nil: the room is not measured yet, and the fan is laid out at
    /// `minimumScale`, so once the room is known it can only grow and what stands below it never
    /// jumps up as the result comes (review E2 of design wave 2, N7).
    public static func scale(count covers: Int, width: Double, height: Double?) -> Double {
        guard let height else { return minimumScale }
        let size = size(covers)
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(minimumScale, min(1, width / size.width, height / size.height))
    }
}

extension ChangePlan {
    /// Distinct photos the library confirmed this plan put into albums: what the receipt counts
    /// as `photosAdded` ("mit 342 Fotos"), so the sorting show's counter ends where the result
    /// begins, whether the show was watched to its end or skipped. Unlike `appliedAssets` a step
    /// whose outcome is unclear counts nothing (`confirmedMedia`).
    public var confirmedAddedMedia: Set<AssetID> {
        var photos = Set<AssetID>()
        for step in steps {
            guard case .addAssets = step.operation else { continue }
            photos.formUnion(confirmedMedia(of: step))
        }
        return photos
    }
}
