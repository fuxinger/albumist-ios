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

    /// An album Albumist created or extended, still in the library.
    public struct AlbumistAlbum: Sendable, Equatable, Identifiable {
        public var collection: CollectionSnapshot
        /// What Albumist remembers about it: the undo of this one album starts from it.
        public var state: ManagedAlbumState
        /// `nil` for an album of the user's whose added photos the user took out again.
        public var mark: Mark?
        /// When a run in the history last created or extended it (`nil`: older than the
        /// history that is loaded, or from a version that kept no history).
        public var changedAt: Date?

        public var id: CollectionID { collection.id }

        public init(collection: CollectionSnapshot, state: ManagedAlbumState, mark: Mark?, changedAt: Date?) {
            self.collection = collection
            self.state = state
            self.mark = mark
            self.changedAt = changedAt
        }
    }

    /// The rows between the shelf and "Deine Alben", in this order.
    public enum Row: Sendable, Equatable, Identifiable {
        /// "Ordner „Reisen“": a folder at the top level that holds albums Albumist created, with
        /// the number of albums in it (at any depth). It is not listed under "Deine Alben" again.
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
    /// How many tiles the shelf shows side by side on the smallest iPhone without scrolling.
    public static let visibleWithoutScrolling = 2

    /// - Parameters:
    ///   - history: finished runs, newest first (`AppModel.history`); undo runs are left out.
    ///   - undone: runs a completed undo took back (`AppModel.undonePlans`).
    ///   - moreHistory: older runs exist than `history` holds.
    ///   - interrupted: a run was cut off and waits in the history.
    ///   - similar: the number of suggestions to merge albums.
    public init(inventory: CollectionInventory, managed: [ManagedAlbumState], history: [ChangePlan] = [],
                undone: Set<SortlyID> = [], moreHistory: Bool = false, interrupted: Bool = false, similar: Int = 0) {
        let changed = Self.lastChanges(history, undone: undone)
        // An album remembered twice stands once (the first record, as the undo reads it).
        var seen = Set<CollectionID>()
        var albums: [AlbumistAlbum] = []
        for state in managed where seen.insert(state.albumID).inserted {
            guard let album = inventory[state.albumID] else { continue }
            albums.append(AlbumistAlbum(collection: album, state: state, mark: Self.mark(state), changedAt: changed[album.id]))
        }
        albumistAlbums = albums.sorted(by: Self.newestFirst)

        // The folders Albumist's new albums lie in ("Reisen", "Länder", or the folder set for
        // new albums), each as one row with its number of albums.
        var folders: [CollectionID: CollectionSnapshot] = [:]
        for album in albumistAlbums where album.state.createdBySortly {
            if let top = Self.topFolder(above: album.collection, in: inventory) { folders[top.id] = top }
        }
        var counts: [CollectionID: Int] = [:]
        if !folders.isEmpty {
            for collection in inventory.collections.values where collection.kind != .folder {
                if let top = Self.topFolder(above: collection, in: inventory), folders[top.id] != nil {
                    counts[top.id, default: 0] += 1
                }
            }
        }
        var rows = folders.values.sorted(by: Self.order).map { Row.folder($0, albums: counts[$0.id] ?? 0) }
        rows.append(.history(changes: history.filter { $0.reverts == nil }.count, more: moreHistory, interrupted: interrupted))
        if similar > 0 { rows.append(.similar(similar)) }
        self.rows = rows

        // "Deine Alben" leaves out what stands above (review P3-16): the albums Albumist makes
        // lie at the top level when no folder for new albums is set, an album of the user's that
        // Albumist extended is at the top level too, and the folders of the rows have their row.
        let shown = seen.union(folders.keys)
        yours = inventory.collections.values
            .filter { $0.parentID == nil && $0.kind != .smartAlbum && !shown.contains($0.id) }
            .sorted(by: Self.order)
    }

    /// Every album Albumist created or extended, in the order of the shelf.
    public var fromAlbumist: [CollectionSnapshot] { albumistAlbums.map(\.collection) }
    /// The albums the shelf shows; the rest are behind "Alle N".
    public var shelf: [AlbumistAlbum] { Array(albumistAlbums.prefix(Self.shelfLimit)) }
    /// "Alle N" stands beside "Von Albumist" once the shelf has more than fits side by side.
    public var showsAll: Bool { albumistAlbums.count > Self.visibleWithoutScrolling }

    /// The section "Deine Alben" is shown: when it lists something, or when the library has no
    /// album at all (then it says so). With only Albumist's albums it is left out: "Noch keine
    /// Alben" right under a list of albums read as wrong (UI run 44570945716).
    public var showsYourAlbums: Bool { !yours.isEmpty || albumistAlbums.isEmpty }
    /// "Noch keine Alben" stands in it: only for a library without any album.
    public var saysNoAlbums: Bool { yours.isEmpty && albumistAlbums.isEmpty }

    /// "Neu" for an album Albumist created, "+N" for one of the user's it added N photos to.
    public static func mark(_ state: ManagedAlbumState) -> Mark? {
        if state.createdBySortly { return .new }
        return state.addedBySortly.isEmpty ? nil : .added(state.addedBySortly.count)
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
        var queue = [folder]
        var seen: Set<CollectionID> = [folder.id]
        var next = 0
        while next < queue.count {
            let current = queue[next]
            next += 1
            for child in children(of: current, in: inventory) where seen.insert(child.id).inserted {
                if child.kind == .folder {
                    queue.append(child)
                } else {
                    albums.append(child)
                }
            }
        }
        return albums
    }

    /// The folder at the top level that `collection` lies in, at any depth; `nil` for a
    /// collection at the top level itself, or one whose folders are not all in the list.
    static func topFolder(above collection: CollectionSnapshot, in inventory: CollectionInventory) -> CollectionSnapshot? {
        var current = collection
        var depth = 0
        while let parentID = current.parentID, depth < 64 {
            guard let parent = inventory[parentID], parent.kind == .folder else { return nil }
            current = parent
            depth += 1
        }
        return current.id == collection.id || current.parentID != nil ? nil : current
    }
}
