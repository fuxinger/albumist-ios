import Foundation
import AlbumistCore

/// What the tiles and screens of the tab "Alben" work out from the album list and the photos'
/// facts, kept until one of them changes (second review of wave 1: every tile sorted its album's
/// photos for its cover each time it was drawn, a folder's tile walked its folders, an album
/// sorted all its photos in `body`). An entry also holds the photos or the folder's list it was
/// worked out from, so an album handed in from an older list is never answered with what another
/// version of it showed; comparing them costs nothing while they are the same copy. Emptied on a
/// memory warning (`MemoryPressure`): what is shown is worked out again then.
@MainActor
final class AlbumTabCache {
    static let shared = AlbumTabCache()

    private struct CoverKey: Hashable {
        var album: CollectionID
        var count: Int
    }

    /// `AppModel.inventoryVersion` of the album list the entries were worked out from.
    private var version: Int?
    /// The model's dates and ranks the covers and orders were worked out from.
    private var dates: [AssetID: Date] = [:]
    private var ranks: [AssetID: PreviewRank] = [:]
    private var covers: [CoverKey: (photos: Set<AssetID>, cover: AlbumCover)] = [:]
    private var chronological: [CollectionID: (photos: Set<AssetID>, ids: [AssetID])] = [:]
    private var folderAlbums: [CollectionID: (list: [CollectionID], albums: [CollectionSnapshot])] = [:]
    private var folderChildren: [CollectionID: (list: [CollectionID], children: [CollectionSnapshot])] = [:]

    private init() {
        MemoryPressure.shared.register("album tiles", owner: self) { $0.empty() }
    }

    /// The cover of `album` (`AlbumCover`): up to `count` photos, four for an album's tile, two
    /// for a quarter of a folder's tile.
    func cover(of album: CollectionSnapshot, count: Int = 4, model: AppModel) -> AlbumCover {
        refresh(model)
        let key = CoverKey(album: album.id, count: count)
        if let kept = covers[key], kept.photos == album.assetIDs { return kept.cover }
        let cover = AlbumCover(album, dates: dates, ranks: ranks, count: count)
        covers[key] = (album.assetIDs, cover)
        return cover
    }

    /// The album's photos oldest first, as the album shows them (`AlbumScreen`, "Fotos ansehen").
    func photos(of album: CollectionSnapshot, model: AppModel) -> [AssetID] {
        refresh(model)
        if let kept = chronological[album.id], kept.photos == album.assetIDs { return kept.ids }
        let ids = PreviewPicker.chronological(album.assetIDs, dates: dates)
        chronological[album.id] = (album.assetIDs, ids)
        return ids
    }

    /// The albums in `folder` at any depth (`AlbumTabSections.albums(in:inventory:)`): the covers
    /// and the number of the folder's tile.
    func albums(in folder: CollectionSnapshot, model: AppModel) -> [CollectionSnapshot] {
        refresh(model)
        if let kept = folderAlbums[folder.id], kept.list == folder.childIDs { return kept.albums }
        let albums = AlbumTabSections.albums(in: folder, inventory: model.inventory)
        folderAlbums[folder.id] = (folder.childIDs, albums)
        return albums
    }

    /// What the folder's screen shows (`AlbumTabSections.children(of:in:)`).
    func children(of folder: CollectionSnapshot, model: AppModel) -> [CollectionSnapshot] {
        refresh(model)
        if let kept = folderChildren[folder.id], kept.list == folder.childIDs { return kept.children }
        let children = AlbumTabSections.children(of: folder, in: model.inventory)
        folderChildren[folder.id] = (folder.childIDs, children)
        return children
    }

    /// Starts over when the album list changed (`AppModel.inventoryVersion`), and drops the covers
    /// and orders when the photos' dates or ranks did. The model keeps one copy of each until the
    /// facts change, so the comparison costs nothing in between and once after a change.
    private func refresh(_ model: AppModel) {
        let version = model.inventoryVersion
        let dates = model.creationDates
        let ranks = model.previewRanks
        if version != self.version {
            empty()
        } else if dates != self.dates || ranks != self.ranks {
            covers = [:]
            chronological = [:]
        }
        self.version = version
        self.dates = dates
        self.ranks = ranks
    }

    /// Forgets everything, the model's dates and ranks too, so a memory warning frees them along
    /// with the model's own copies.
    private func empty() {
        version = nil
        dates = [:]
        ranks = [:]
        covers = [:]
        chronological = [:]
        folderAlbums = [:]
        folderChildren = [:]
    }
}
