import Foundation

/// The two lists of the tab "Alben": the albums Albumist created or extended, and below them
/// the user's other albums and folders at the top level, as Photos shows them.
public struct AlbumTabSections: Sendable, Equatable {
    /// "Von Albumist angelegt oder ergänzt": every remembered album still in the library.
    public var fromAlbumist: [CollectionSnapshot]
    /// "Deine Alben": the other folders and albums at the top level, folders first, no smart albums.
    public var yours: [CollectionSnapshot]

    /// "Deine Alben" leaves out what the list above shows (review P3-16): the albums Albumist
    /// makes lie at the top level when no folder for new albums is set, and an album of the
    /// user's that Albumist extended is at the top level too, so both stood in both lists.
    public init(inventory: CollectionInventory, managed: [ManagedAlbumState]) {
        let ownIDs = Set(managed.map(\.albumID))
        fromAlbumist = ownIDs.compactMap { inventory[$0] }.sorted(by: Self.order)
        yours = inventory.collections.values
            .filter { $0.parentID == nil && $0.kind != .smartAlbum && !ownIDs.contains($0.id) }
            .sorted(by: Self.order)
    }

    /// The section "Deine Alben" is shown: when it lists something, or when the library has no
    /// album at all (then it says so). With only Albumist's albums it is left out: "Noch keine
    /// Alben" right under a list of albums read as wrong (UI run 44570945716).
    public var showsYourAlbums: Bool { !yours.isEmpty || fromAlbumist.isEmpty }
    /// "Noch keine Alben" stands in it: only for a library without any album.
    public var saysNoAlbums: Bool { yours.isEmpty && fromAlbumist.isEmpty }

    /// Folders before albums, then by title as Finder and Photos sort ("Album 2" before "Album 10").
    public static func order(_ a: CollectionSnapshot, _ b: CollectionSnapshot) -> Bool {
        if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.id < b.id
    }
}
