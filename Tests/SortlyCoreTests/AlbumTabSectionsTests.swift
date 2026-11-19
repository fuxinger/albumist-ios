import Foundation
import Testing
@testable import SortlyCore

/// Review 18.11. P3-16 (= G3-02): in the tab "Alben" the albums Albumist made stood twice,
/// under "Von Albumist angelegt oder ergänzt" and again under "Deine Alben" (`ui-18-albums.jpg`,
/// no folder for new albums set, so they lie at the top level). Every album is listed once.
@Suite("Albums tab lists")
struct AlbumTabSectionsTests {
    static func state(_ album: CollectionSnapshot, created: Bool = true) -> ManagedAlbumState {
        ManagedAlbumState(albumID: album.id, sourceID: SortlyID("s-\(album.id.rawValue)"), lastKnownTitle: album.title,
                          lastKnownParentID: album.parentID, lastKnownMembers: album.assetIDs,
                          addedBySortly: album.assetIDs, createdBySortly: created)
    }

    static let photos: Set<AssetID> = [AssetID("p1"), AssetID("p2")]

    /// Every album and folder at most once over both lists.
    static func listedOnce(_ sections: AlbumTabSections) -> Bool {
        let ids = (sections.fromAlbumist + sections.yours).map(\.id)
        return Set(ids).count == ids.count
    }

    @Test func albumsAlbumistMadeAtTheTopLevelStandOnlyUnderAlbumist() {
        let done = CollectionSnapshot(id: "a1", title: "Testalbum Vollendet", assetIDs: Self.photos)
        let restored = CollectionSnapshot(id: "a2", title: "Testalbum Wiederhergestellt", assetIDs: Self.photos)
        let sections = AlbumTabSections(inventory: CollectionInventory([done, restored]),
                                        managed: [Self.state(done), Self.state(restored)])
        #expect(sections.fromAlbumist.map(\.id) == ["a1", "a2"])
        #expect(sections.yours.isEmpty)
        #expect(Self.listedOnce(sections))
    }

    @Test func aUsersAlbumAlbumistExtendedStandsOnce() {
        let mine = CollectionSnapshot(id: "u1", title: "Italien", assetIDs: Self.photos)
        let other = CollectionSnapshot(id: "u2", title: "Garten", assetIDs: [AssetID("p3")])
        let sections = AlbumTabSections(inventory: CollectionInventory([mine, other]),
                                        managed: [Self.state(mine, created: false)])
        #expect(sections.fromAlbumist.map(\.id) == ["u1"])
        #expect(sections.yours.map(\.id) == ["u2"])
        #expect(Self.listedOnce(sections))
    }

    @Test func albumsInAlbumistsFolderKeepTheFolderUnderYourAlbums() {
        let folder = CollectionSnapshot(id: "f", title: "Albumist", kind: .folder, childIDs: ["a1"])
        let album = CollectionSnapshot(id: "a1", title: "Rom", parentID: "f", assetIDs: Self.photos)
        let mine = CollectionSnapshot(id: "u1", title: "Garten", assetIDs: [AssetID("p3")])
        let smart = CollectionSnapshot(id: "s", title: "Favoriten", kind: .smartAlbum)
        let sections = AlbumTabSections(inventory: CollectionInventory([folder, album, mine, smart]),
                                        managed: [Self.state(album)])
        #expect(sections.fromAlbumist.map(\.id) == ["a1"])
        #expect(sections.yours.map(\.id) == ["f", "u1"])
        #expect(Self.listedOnce(sections))
    }

    @Test func anAlbumRememberedTwiceStandsOnce() {
        let album = CollectionSnapshot(id: "a1", title: "Rom", assetIDs: Self.photos)
        var second = Self.state(album)
        second.sourceID = SortlyID("other")
        let sections = AlbumTabSections(inventory: CollectionInventory([album]), managed: [Self.state(album), second])
        #expect(sections.fromAlbumist.map(\.id) == ["a1"])
        #expect(Self.listedOnce(sections))
    }

    @Test func aRememberedAlbumThatIsGoneIsNotListed() {
        let mine = CollectionSnapshot(id: "u1", title: "Garten")
        let gone = CollectionSnapshot(id: "a9", title: "Weg")
        let sections = AlbumTabSections(inventory: CollectionInventory([mine]), managed: [Self.state(gone)])
        #expect(sections.fromAlbumist.isEmpty)
        #expect(sections.yours.map(\.id) == ["u1"])
    }

    @Test func foldersComeFirstThenTitlesInNaturalOrder() {
        let ten = CollectionSnapshot(id: "x", title: "Album 10")
        let two = CollectionSnapshot(id: "y", title: "Album 2")
        let folder = CollectionSnapshot(id: "z", title: "Zuletzt", kind: .folder)
        let sections = AlbumTabSections(inventory: CollectionInventory([ten, two, folder]), managed: [])
        #expect(sections.yours.map(\.id) == ["z", "y", "x"])
    }
}
