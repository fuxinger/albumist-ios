import Foundation

/// The covers of the changes Albumist made (design wave 3, DS-15): the history ("Verlauf und
/// Rückgängig") shows one per change, made of the albums of that run, and the receipt
/// ("Änderungen") one per album, larger than the small pictures they had. Pure, so the screens
/// only draw them; the app shows the first photo of each that is sharp on the device
/// (`CoverPhoto`, never from iCloud).
///
/// - An album's photos are the ones the change added to it: what the library confirmed, as the
///   receipt counts them (`ChangePlan.confirmedMedia`), or, for a plan cut off on its way
///   (`applied: false`), what it sets out to add, so its row is recognised before it is complete.
///   Never the user's own photos of an album the change extended.
/// - An album shows them as the tab "Alben" shows an album (`AlbumCover` in the app): newest
///   first, a photo only (`PreviewPicker.coverCandidates`: never a screenshot, a document or a
///   sensitive document; photos the analysis has not looked at yet only after the analysed
///   ones), "Vorschau ausgeblendet" when every photo is a sensitive document, the calm ground with
///   its symbol when there is no photo to try (an album of screenshots).
/// - A change shows up to `tiles` of its albums in the order of the plan, as a folder's tile shows
///   its albums; a photo is tried by one of them only (a country album holds its trip's photos),
///   and an album with no photo left to show makes room for the next, so no place stays empty.
///   "Vorschau ausgeblendet" when every photo of the change is a sensitive document.
/// - An undo or a removal from "Alben von Albumist" only takes photos out and removes albums: no
///   cover of photos, its symbol (as the receipt shows a removed album).
///
/// Albums are named as the receipt names them (`PlanReceipt.Album.id`), so each of its rows finds
/// its own cover. One pass over the change's photos: a starter pack of 50,000 costs no sorting.
public enum PlanCovers {
    /// One album's cover.
    public struct Cover: Hashable, Sendable {
        /// The photos it tries, best first: the first one sharp on the device is shown.
        public var ids: [AssetID]
        /// Every photo the change added to it is a sensitive document: "Vorschau ausgeblendet".
        public var hidden: Bool

        public init(ids: [AssetID], hidden: Bool) {
            self.ids = ids
            self.hidden = hidden
        }
    }

    /// The cover of a whole change, in the history.
    public struct Mosaic: Hashable, Sendable {
        /// Up to `tiles` albums, in the order of the plan: the photos each one tries, best first.
        /// No photo is tried by two of them.
        public var tiles: [[AssetID]]
        /// No album has a photo to show and every photo of the change is a sensitive document:
        /// "Vorschau ausgeblendet".
        public var hidden: Bool

        public init(tiles: [[AssetID]], hidden: Bool) {
            self.tiles = tiles
            self.hidden = hidden
        }

        /// No photo to show and nothing hidden: the change's symbol on the calm ground.
        public var isEmpty: Bool { tiles.isEmpty && !hidden }
    }

    /// Photos a cover tries at most (as a card's cover, `CoverLoader.attempts` in the app).
    public static let candidates = 4
    /// Albums a change's cover shows at most: four in a square, as a folder's tile.
    public static let tiles = 4

    /// The cover of an album of `photos`, as the tab "Alben" shows an album: newest first, photos
    /// only; hidden when every one is a sensitive document. Also what the preview before a run can
    /// show for an album it adds `photos` to.
    public static func cover(of photos: some Collection<AssetID>, dates: [AssetID: Date],
                             ranks: [AssetID: PreviewRank]) -> Cover {
        let ids = PreviewPicker.coverCandidates(photos, cover: nil, dates: dates, ranks: ranks, count: candidates)
        let hidden = ids.isEmpty && !photos.isEmpty && photos.allSatisfy { ranks[$0] == .sensitive }
        return Cover(ids: ids, hidden: hidden)
    }

    /// The cover of each album `plan` added photos to (the receipt's rows), named as the receipt
    /// names its albums (`PlanReceipt.Album.id`). Albums without photos (taken out, removed) have
    /// none.
    public static func albums(of plan: ChangePlan, applied: Bool = true, dates: [AssetID: Date],
                              ranks: [AssetID: PreviewRank]) -> [String: Cover] {
        var covers: [String: Cover] = [:]
        for album in photos(of: plan, applied: applied) {
            covers[album.album] = cover(of: album.photos, dates: dates, ranks: ranks)
        }
        return covers
    }

    /// The cover of the change `plan` (its row in the history).
    public static func mosaic(of plan: ChangePlan, applied: Bool = true, dates: [AssetID: Date],
                              ranks: [AssetID: PreviewRank]) -> Mosaic {
        var made: [[AssetID]] = []
        var tried = Set<AssetID>()
        var anyPhoto = false
        var onlySensitive = true
        for album in photos(of: plan, applied: applied) {
            anyPhoto = true
            if onlySensitive { onlySensitive = album.photos.allSatisfy { ranks[$0] == .sensitive } }
            let ids = PreviewPicker.coverCandidates(album.photos.subtracting(tried), cover: nil, dates: dates, ranks: ranks,
                                                    count: candidates)
            guard !ids.isEmpty else { continue }
            tried.formUnion(ids)
            made.append(ids)
            if made.count == tiles { break }
        }
        return Mosaic(tiles: made, hidden: made.isEmpty && anyPhoto && onlySensitive)
    }

    /// The photos a change added to one album.
    struct AlbumPhotos: Hashable, Sendable {
        /// The album as the receipt names it (`PlanReceipt.Album.id`).
        var album: String
        var photos: Set<AssetID>
    }

    /// The albums `plan` added photos to, in the order the receipt lists them (a new album where
    /// the plan makes it), each with the photos it got: confirmed, or planned (`applied: false`).
    static func photos(of plan: ChangePlan, applied: Bool = true) -> [AlbumPhotos] {
        var order: [String] = []
        var listed = Set<String>()
        var photos: [String: Set<AssetID>] = [:]
        for step in plan.steps {
            let album: String
            switch step.operation {
            case .createAlbum(let key, _, _):
                album = ResultCoverStack.id(of: .planned(key))
            case .addAssets(let ref, let assets):
                album = ResultCoverStack.id(of: ref)
                photos[album, default: []].formUnion(applied ? plan.confirmedMedia(of: step) : assets)
            default:
                continue
            }
            if listed.insert(album).inserted { order.append(album) }
        }
        return order.compactMap { album in
            guard let got = photos[album], !got.isEmpty else { return nil }
            return AlbumPhotos(album: album, photos: got)
        }
    }
}
