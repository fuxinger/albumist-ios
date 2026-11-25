import Foundation
import Testing
@testable import AlbumistCore

/// The albums tab inside a folder, the undo of one album, and large libraries (`AlbumTabDesignTests`).
extension AlbumTabDesignTests {
    // MARK: - Inside a folder

    /// A folder shows its folders first, then its albums, each by title as Photos sorts them
    /// ("Album 2" before "Album 10"); a smart album and a child missing from the list are not shown.
    @Test func aFolderShowsItsFoldersFirstThenItsAlbumsByTitle() {
        let trips = CollectionSnapshot(id: "f", title: "Reisen", kind: .folder, childIDs: ["a10", "sub", "a2", "smart", "gone"])
        let sub = CollectionSnapshot(id: "sub", title: "2024", kind: .folder, parentID: "f")
        let ten = CollectionSnapshot(id: "a10", title: "Album 10", parentID: "f")
        let two = CollectionSnapshot(id: "a2", title: "Album 2", parentID: "f")
        let smart = CollectionSnapshot(id: "smart", title: "Favoriten", kind: .smartAlbum, parentID: "f")
        let inventory = CollectionInventory([trips, sub, ten, two, smart])
        #expect(AlbumTabSections.children(of: trips, in: inventory).map(\.id) == ["sub", "a2", "a10"])
        #expect(AlbumTabSections.children(of: sub, in: inventory).isEmpty)
    }

    /// A folder's tile shows covers of its own albums first, then of its folders' albums, and
    /// counts the albums at every depth (as its row does); a folder listed twice or inside itself
    /// counts once.
    @Test func aFoldersAlbumsAreItsOwnFirstThenThoseOfItsFolders() {
        let trips = CollectionSnapshot(id: "f", title: "Reisen", kind: .folder, childIDs: ["y24", "rom", "y23", "y24"])
        let y24 = CollectionSnapshot(id: "y24", title: "2024", kind: .folder, parentID: "f", childIDs: ["kyoto", "f"])
        let y23 = CollectionSnapshot(id: "y23", title: "2023", kind: .folder, parentID: "f", childIDs: ["lissabon"])
        let rome = CollectionSnapshot(id: "rom", title: "Rom", parentID: "f", assetIDs: Self.photos(3))
        let kyoto = CollectionSnapshot(id: "kyoto", title: "Kyoto", parentID: "y24", assetIDs: Self.photos(2, "k"))
        let lisbon = CollectionSnapshot(id: "lissabon", title: "Lissabon", parentID: "y23", assetIDs: Self.photos(2, "l"))
        let inventory = CollectionInventory([trips, y24, y23, rome, kyoto, lisbon])
        #expect(AlbumTabSections.albums(in: trips, inventory: inventory).map(\.id) == ["rom", "lissabon", "kyoto"])
        #expect(AlbumTabSections.albums(in: y24, inventory: inventory).map(\.id) == ["kyoto", "rom", "lissabon"])
        // The count of the tile is the count of the row.
        let sections = AlbumTabSections(inventory: inventory, managed: [rome, kyoto, lisbon].map { Self.state($0) })
        #expect(sections.rows.first == .folder(trips, albums: 3))
        #expect(AlbumTabSections.albums(in: CollectionSnapshot(id: "e", title: "Leer", kind: .folder), inventory: inventory).isEmpty)
    }

    // MARK: - What the undo of one album does

    /// One album's undo: what the case is, the album as the list has it (nil: not in it), what
    /// Albumist remembers of it, and what its undo does.
    struct UndoCase {
        var name: String
        var album: CollectionSnapshot?
        var state: ManagedAlbumState
        var expected: AlbumTabSections.UndoEffect

        init(_ name: String, _ album: CollectionSnapshot?, _ state: ManagedAlbumState, _ expected: AlbumTabSections.UndoEffect) {
            self.name = name
            self.album = album
            self.state = state
            self.expected = expected
        }
    }

    /// "Rückgängig machen" on one album, worked out without building the removal (the long
    /// press's line, the confirmation's button): exactly what `ManagedAlbumTracker` would plan.
    @Test func theUndoOfOneAlbumIsWhatTheRemovalPlans() {
        let ours = Self.photos(3, "o")
        let cases: [UndoCase] = {
            let made = CollectionSnapshot(id: "a1", title: "Kyoto", assetIDs: ours)
            let filled = CollectionSnapshot(id: "a2", title: "Rom", assetIDs: ours.union(["mine"]))
            let partly = CollectionSnapshot(id: "a3", title: "Paris", assetIDs: Set(ours.sorted().prefix(1)).union(["mine"]))
            let extended = CollectionSnapshot(id: "u1", title: "Toskana", assetIDs: ours.union(Self.photos(5, "m")))
            let emptied = CollectionSnapshot(id: "u2", title: "Garten", assetIDs: Self.photos(2, "m"))
            let locked = CollectionSnapshot(id: "a4", title: "Geteilt", kind: .restrictedAlbum, assetIDs: ours)
            let gone = CollectionSnapshot(id: "a5", title: "Weg", assetIDs: ours)
            return [
                UndoCase("made, only Albumist's photos", made, Self.state(made, added: ours), .init(deletesAlbum: true, photosTakenOut: 0)),
                UndoCase("made, the user's photo too", filled, Self.state(filled, added: ours), .init(deletesAlbum: false, photosTakenOut: 3)),
                UndoCase("made, some taken out by the user", partly, Self.state(partly, added: ours),
                         .init(deletesAlbum: false, photosTakenOut: 1)),
                UndoCase("the user's, extended", extended, Self.state(extended, created: false, added: ours),
                         .init(deletesAlbum: false, photosTakenOut: 3)),
                UndoCase("the user's, all taken out again", emptied, Self.state(emptied, created: false, added: ours),
                         .init(deletesAlbum: false, photosTakenOut: 0)),
                UndoCase("cannot be changed", locked, Self.state(locked, added: ours), .init(deletesAlbum: false, photosTakenOut: 0)),
                UndoCase("not in the list", nil, Self.state(gone, added: ours), .init(deletesAlbum: false, photosTakenOut: 0)),
            ]
        }()
        for undo in cases {
            let name = undo.name, album = undo.album, state = undo.state, expected = undo.expected
            let effect = AlbumTabSections.undoEffect(state, album: album)
            #expect(effect == expected, "\(name)")
            let plan = ManagedAlbumTracker().removalPlan(for: state, current: CollectionInventory(album.map { [$0] } ?? []))
            #expect(effect.deletesAlbum == plan.deletesCollections, "\(name)")
            let removed = plan.steps.reduce(0) { count, step in
                if case .removeAssets(_, let assets) = step.operation { count + assets.count } else { count }
            }
            #expect(effect.photosTakenOut == removed, "\(name)")
            #expect(effect.doesSomething == !plan.steps.isEmpty, "\(name)")
        }
    }

    // MARK: - Large libraries

    /// 300 albums of Albumist's in 3 folders and 40 of the user's: every one once, the shelf
    /// holds 12, "Alle 300".
    @Test func aLargeLibraryListsEveryAlbumOnce() {
        let made = (0..<300).map { CollectionSnapshot(id: CollectionID("a\($0)"), title: "Album \($0)", parentID: CollectionID("f\($0 % 3)"),
                                                      assetIDs: Self.photos(1, "a\($0)-")) }
        let folders = ["Reisen", "Länder", "Orte"].enumerated().map { folder in
            CollectionSnapshot(id: CollectionID("f\(folder.offset)"), title: folder.element, kind: .folder,
                               childIDs: made.filter { $0.parentID == CollectionID("f\(folder.offset)") }.map(\.id))
        }
        let mine = (0..<40).map { CollectionSnapshot(id: CollectionID("u\($0)"), title: "Mein Album \($0)", assetIDs: Self.photos(1, "u\($0)-")) }
        let sections = AlbumTabSections(inventory: CollectionInventory(folders + made + mine), managed: made.map { Self.state($0) },
                                        history: [Self.run("r", day: 1, made: ["a7"])])
        #expect(sections.albumistAlbums.count == 300)
        #expect(sections.albumistAlbums.first?.id == "a7")
        #expect(sections.shelf().count == 12 && sections.showsAll(visible: 2))
        #expect(sections.rows.compactMap { if case .folder(_, let albums) = $0 { albums } else { nil } } == [100, 100, 100])
        #expect(sections.yours.count == 40)
        #expect(Self.listedOnce(sections))
    }
}
