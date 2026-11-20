import Foundation

/// What a plan may have changed in Photos that its undo leaves as it is, because Albumist
/// cannot prove it was its own doing (review P2-01, 18.11.2026). The undo never touches what
/// may be the user's; instead the app names it, so "Alles zurücknehmen" never ends with
/// something left in Photos that nobody was told about:
/// - an album or folder found by its name after an interruption (`ExecutionRecord.adoptedKeys`):
///   it is never deleted. Since the id of every new album is written down inside the change
///   that creates it, this is rare (a journal that could not be written, plans from older
///   versions);
/// - photos in an album the plan did not create, from an add that was cut off, or found there
///   by a resumed run whose journal may have been one entry behind (P2-07): a photo there may
///   be Albumist's or the user's (audit 2, 1.1), and stays.
public struct UndoRemainder: Hashable, Sendable {
    public struct Collection: Hashable, Sendable {
        public var id: CollectionID
        public var title: String
        /// Titles of the folders above it, outermost first.
        public var folderPath: [String]
        public var isFolder: Bool
    }

    public struct Photos: Hashable, Sendable {
        public var album: CollectionID
        public var title: String
        public var folderPath: [String]
        public var assets: Set<AssetID>
    }

    /// Albums and folders found by their name after an interruption, still in Photos.
    public var collections: [Collection] = []
    /// Per album, photos an interrupted add may have put there that are still in it.
    public var photos: [Photos] = []

    public var isEmpty: Bool { collections.isEmpty && photos.isEmpty }

    public init() {}

    /// - Parameters:
    ///   - plan: the plan as it ran (settled after an interruption).
    ///   - current: the library now (before or after the undo: the undo leaves both alone).
    public init(plan: ChangePlan, current: CollectionInventory) {
        func path(_ id: CollectionID) -> [String] {
            var titles: [String] = []
            var parent = current[id]?.parentID
            while let p = parent, let folder = current[p], titles.count < 32 {
                titles.insert(folder.title, at: 0)
                parent = folder.parentID
            }
            return titles
        }
        let record = plan.record
        for key in (record?.adoptedKeys ?? []).sorted() {
            guard let id = plan.resolvedKeys[key], let found = current[id] else { continue }
            collections.append(Collection(id: id, title: found.title, folderPath: path(id), isFolder: found.kind == .folder))
        }
        var byAlbum: [CollectionID: Set<AssetID>] = [:]
        for step in plan.steps {
            guard case .addAssets(let ref, _) = step.operation else { continue }
            // An add that was cut off, and photos a resumed run found there already (P2-07).
            var maybe = Set(record?.unclear[step.id] ?? [])
            if record?.unverified.contains(step.id) == true { maybe.formUnion(record?.media[step.id] ?? []) }
            guard !maybe.isEmpty else { continue }
            let albumID: CollectionID? = switch ref {
            case .existing(let id): id
            case .planned(let key): plan.resolvedKeys[key]
            }
            // In an album the plan made itself, what is there is Albumist's: the undo takes it.
            guard let albumID, !plan.createdVerifiably(albumID), let album = current[albumID] else { continue }
            let there = album.assetIDs.intersection(maybe)
            if !there.isEmpty { byAlbum[albumID, default: []].formUnion(there) }
        }
        for (id, assets) in byAlbum.sorted(by: { $0.key < $1.key }) {
            photos.append(Photos(album: id, title: current[id]?.title ?? "", folderPath: path(id), assets: assets))
        }
    }
}
