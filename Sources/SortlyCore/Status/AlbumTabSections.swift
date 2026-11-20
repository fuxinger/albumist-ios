import Foundation

/// The tab "Alben" (design 5C, approved 20.11.2026, draft `E4-alben`): on top a shelf of what
/// Albumist made or extended ("Von Albumist", "angelegt oder ergänzt", "Alle N"), then a short
/// list of rows (the folders Albumist's new albums lie in, "Verlauf und Rückgängig", "Ähnliche
/// Alben"), then the user's other albums and folders at the top level, as Photos shows them
/// ("Deine Alben"). Every album and folder stands once over all three.
public struct AlbumTabSections: Sendable, Equatable {
    /// The mark under the cover of an album of Albumist's (on a solid ground, never on the photo).
    public enum Mark: Sendable, Equatable {
        /// "Neu": Albumist created the album.
        case new
        /// "+N": Albumist added N photos to an album of the user's. Never "Neu": that album is
        /// the user's, not new.
        case added(Int)
    }

    /// An album Albumist created or extended, still in the library, with something of
    /// Albumist's in it (an album of the user's whose added photos the user took out again is
    /// the user's again: it stands under "Deine Alben").
    public struct AlbumistAlbum: Sendable, Equatable, Identifiable {
        public var collection: CollectionSnapshot
        /// What Albumist remembers about it: the undo of this one album starts from it.
        public var state: ManagedAlbumState
        public var mark: Mark
        /// When a run in the history last created or extended it (`nil`: older than the
        /// history that is loaded, or from a version that kept no history).
        public var changedAt: Date?

        public var id: CollectionID { collection.id }

        public init(collection: CollectionSnapshot, state: ManagedAlbumState, mark: Mark, changedAt: Date?) {
            self.collection = collection
            self.state = state
            self.mark = mark
            self.changedAt = changedAt
        }
    }

    /// The rows between the shelf and "Deine Alben", in this order.
    public enum Row: Sendable, Equatable, Identifiable {
        /// "Ordner „Reisen“": a folder at the top level whose albums, at any depth, are all albums
        /// Albumist created, with their number. It is not listed under "Deine Alben" again.
        case folder(CollectionSnapshot, albums: Int)
        /// "Verlauf und Rückgängig", always there: the number of finished changes it lists;
        /// `more` when older ones exist beyond those; `interrupted` when a run was cut off.
        case history(changes: Int, more: Bool, interrupted: Bool)
        /// "Ähnliche Alben": the number of suggestions to merge albums, only when there are any.
        case similar(Int)

        public var id: String {
            switch self {
            case .folder(let folder, _): "folder:" + folder.id.rawValue
            case .history: "history"
            case .similar: "similar"
            }
        }
    }

    /// Albums Albumist created or extended, newest change first; albums without a known change
    /// after them, by title.
    public var albumistAlbums: [AlbumistAlbum]
    public var rows: [Row]
    /// "Deine Alben": the other folders and albums at the top level, folders first, no smart
    /// albums, none that the shelf or a folder row shows.
    public var yours: [CollectionSnapshot]

    /// How many albums the shelf shows at most; "Alle N" opens the whole list.
    public static let shelfLimit = 12
    /// At the accessibility text sizes the shelf is a column of tiles across the screen: the
    /// first three, so the rows below stay near (second review of wave 1).
    public static let columnLimit = 3

    /// - Parameters:
    ///   - history: finished runs, newest first (`AppModel.history`); undo runs are left out.
    ///   - undone: runs a completed undo took back (`AppModel.undonePlans`).
    ///   - moreHistory: older runs exist than `history` holds.
    ///   - interrupted: a run was cut off and waits in the history.
    ///   - similar: the number of suggestions to merge albums.
    public init(inventory: CollectionInventory, managed: [ManagedAlbumState], history: [ChangePlan] = [],
                undone: Set<SortlyID> = [], moreHistory: Bool = false, interrupted: Bool = false, similar: Int = 0) {
        let changed = Self.lastChanges(history, undone: undone)
        // An album remembered twice stands by its first record, as the undo reads it; one with
        // nothing of Albumist's left in it is the user's again.
        var seen = Set<CollectionID>()
        var albums: [AlbumistAlbum] = []
        for state in managed where seen.insert(state.albumID).inserted {
            guard let album = inventory[state.albumID], let mark = Self.mark(state) else { continue }
            albums.append(AlbumistAlbum(collection: album, state: state, mark: mark, changedAt: changed[album.id]))
        }
        albumistAlbums = albums.sorted(by: Self.newestFirst)

        // The folders Albumist's new albums lie in ("Reisen", "Länder", or the folder set for new
        // albums): a folder at the top level whose albums are all Albumist's own, each one row
        // with their number. Counted as the folder's tile and screen show it (`albums(in:)`, its
        // list walked down), so row and tile agree while Photos syncs. A folder of the user's
        // that holds albums of the user's too stays theirs, under "Deine Alben".
        let made = Set(albums.lazy.filter(\.state.createdBySortly).map(\.id))
        var folders: [CollectionSnapshot] = []
        var counts: [CollectionID: Int] = [:]
        if !made.isEmpty {
            for folder in inventory.collections.values where folder.kind == .folder && folder.parentID == nil {
                if let count = Self.countOfAlbumsIfAll(in: folder, inventory: inventory, are: made) {
                    folders.append(folder)
                    counts[folder.id] = count
                }
            }
        }
        var rows = folders.sorted(by: Self.order).map { Row.folder($0, albums: counts[$0.id] ?? 0) }
        rows.append(.history(changes: history.filter { $0.reverts == nil }.count, more: moreHistory, interrupted: interrupted))
        if similar > 0 { rows.append(.similar(similar)) }
        self.rows = rows

        // "Deine Alben" leaves out what stands above (review P3-16): the albums Albumist makes
        // lie at the top level when no folder for new albums is set, an album of the user's that
        // Albumist extended is at the top level too, and the folders of the rows have their row.
        let shown = Set(albums.map(\.id)).union(folders.map(\.id))
        yours = inventory.collections.values
            .filter { $0.parentID == nil && $0.kind != .smartAlbum && !shown.contains($0.id) }
            .sorted(by: Self.order)
    }

    /// Every album Albumist created or extended, in the order of the shelf.
    public var fromAlbumist: [CollectionSnapshot] { albumistAlbums.map(\.collection) }
    /// The albums the shelf shows, at most `limit` (`columnLimit` at the accessibility text
    /// sizes); the rest are behind "Alle N".
    public func shelf(limit: Int = shelfLimit) -> [AlbumistAlbum] { Array(albumistAlbums.prefix(max(limit, 0))) }
    /// "Alle N" stands beside "Von Albumist" once there are more albums than the shelf shows at
    /// once: `visible` is two side by side on the iPhone, four on the iPad, the column's three
    /// at the accessibility text sizes.
    public func showsAll(visible: Int) -> Bool { albumistAlbums.count > visible }

    /// The section "Deine Alben" is shown: when it lists something, or when the library has no
    /// album at all (then it says so). With only Albumist's albums it is left out: "Noch keine
    /// Alben" right under a list of albums read as wrong (UI run 44570945716).
    public var showsYourAlbums: Bool { !yours.isEmpty || albumistAlbums.isEmpty }
    /// "Noch keine Alben" stands in it: only for a library without any album.
    public var saysNoAlbums: Bool { yours.isEmpty && albumistAlbums.isEmpty }

    /// "Neu" for an album Albumist created, "+N" for one of the user's it added N photos to;
    /// `nil` for one of the user's whose added photos the user took out again.
    public static func mark(_ state: ManagedAlbumState) -> Mark? {
        if state.createdBySortly { return .new }
        return state.addedBySortly.isEmpty ? nil : .added(state.addedBySortly.count)
    }

    /// What "Rückgängig machen" on one album of Albumist's does now.
    public struct UndoEffect: Sendable, Equatable {
        /// The album goes (iOS asks once more before it is deleted).
        public var deletesAlbum: Bool
        /// Otherwise: how many of Albumist's photos come out of it.
        public var photosTakenOut: Int

        public init(deletesAlbum: Bool, photosTakenOut: Int) {
            self.deletesAlbum = deletesAlbum
            self.photosTakenOut = photosTakenOut
        }

        /// Something would change; otherwise the undo has nothing to do.
        public var doesSomething: Bool { deletesAlbum || photosTakenOut > 0 }
    }

    /// What the undo of one album does, worked out from the album as the list holds it without
    /// building the removal (the line of "Rückgängig machen" in a menu, the button of its
    /// confirmation), by the rule of `ManagedAlbumTracker.removalPlan(for:current:)` (tested
    /// against it): an album Albumist created goes while nothing but Albumist's photos is in
    /// it; from any other album only Albumist's photos come out; an album that cannot be
    /// changed, or is not in the list, stays as it is. The preview then shows the removal made
    /// from what Photos holds at that moment.
    public static func undoEffect(_ state: ManagedAlbumState, album: CollectionSnapshot?) -> UndoEffect {
        guard let album, album.id == state.albumID, album.isEditableAlbum else {
            return UndoEffect(deletesAlbum: false, photosTakenOut: 0)
        }
        if state.createdBySortly && album.assetIDs.isSubset(of: state.addedBySortly) {
            return UndoEffect(deletesAlbum: true, photosTakenOut: 0)
        }
        return UndoEffect(deletesAlbum: false, photosTakenOut: album.assetIDs.intersection(state.addedBySortly).count)
    }

    /// Folders before albums, then by title as Finder and Photos sort ("Album 2" before "Album 10").
    public static func order(_ a: CollectionSnapshot, _ b: CollectionSnapshot) -> Bool {
        if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.id < b.id
    }

    /// Newest change first; albums without a known change after them, by `order`.
    static func newestFirst(_ a: AlbumistAlbum, _ b: AlbumistAlbum) -> Bool {
        switch (a.changedAt, b.changedAt) {
        case let (x?, y?) where x != y: x > y
        case (.some, nil): true
        case (nil, .some): false
        default: order(a.collection, b.collection)
        }
    }

    /// When each album was last created or extended by a run that is not taken back: the albums
    /// a run made and the ones it verifiably added photos to (`collectionsMade`,
    /// `extendedAlbums`), at the time the run was confirmed.
    static func lastChanges(_ history: [ChangePlan], undone: Set<SortlyID>) -> [CollectionID: Date] {
        var dates: [CollectionID: Date] = [:]
        for plan in history where plan.reverts == nil && !undone.contains(plan.id) {
            let date = plan.confirmedAt ?? plan.createdAt
            for id in plan.collectionsMade.union(plan.extendedAlbums) where (dates[id] ?? .distantPast) < date {
                dates[id] = date
            }
        }
        return dates
    }

    /// What a folder shows (`FolderScreen`): its folders and albums, folders first, then by title
    /// as Photos sorts them; no smart albums (Photos keeps them out of folders).
    public static func children(of folder: CollectionSnapshot, in inventory: CollectionInventory) -> [CollectionSnapshot] {
        folder.childIDs.compactMap { inventory[$0] }.filter { $0.kind != .smartAlbum }.sorted(by: order)
    }

    /// The albums in `folder` at any depth, as the folder shows them: its own albums first, then
    /// those of its folders, level by level (the covers and the number of a folder's tile). A
    /// folder listed twice, or inside itself, counts once.
    public static func albums(in folder: CollectionSnapshot, inventory: CollectionInventory) -> [CollectionSnapshot] {
        var albums: [CollectionSnapshot] = []
        walk(folder, inventory: inventory, sorted: true) { albums.append($0); return true }
        return albums
    }

    /// The number of albums in `folder` at any depth when every one of them is in `made` (and
    /// there is one at least), otherwise `nil`. The same walk as `albums(in:inventory:)`, so the
    /// row counts what the tile shows; unsorted, and it stops at the first album that is not in
    /// `made` (a folder of the user's with many albums costs little).
    static func countOfAlbumsIfAll(in folder: CollectionSnapshot, inventory: CollectionInventory,
                                   are made: Set<CollectionID>) -> Int? {
        var count = 0
        let complete = walk(folder, inventory: inventory, sorted: false) { album in
            guard made.contains(album.id) else { return false }
            count += 1
            return true
        }
        return complete && count > 0 ? count : nil
    }

    /// Walks down the folder's list (`childIDs`), level by level, and hands each album to
    /// `visit` until it returns `false`; `false` then. No smart albums and nothing missing from
    /// the list; a folder listed twice, or inside itself, is walked once. `sorted`: in the order
    /// the folder shows (`children(of:in:)`).
    @discardableResult
    private static func walk(_ folder: CollectionSnapshot, inventory: CollectionInventory, sorted: Bool,
                             visit: (CollectionSnapshot) -> Bool) -> Bool {
        var queue = [folder]
        var seen: Set<CollectionID> = [folder.id]
        var next = 0
        while next < queue.count {
            let current = queue[next]
            next += 1
            let children = sorted ? Self.children(of: current, in: inventory)
                                  : current.childIDs.compactMap { inventory[$0] }.filter { $0.kind != .smartAlbum }
            for child in children where seen.insert(child.id).inserted {
                if child.kind == .folder {
                    queue.append(child)
                } else if !visit(child) {
                    return false
                }
            }
        }
        return true
    }
}
