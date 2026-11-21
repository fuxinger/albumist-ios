import Foundation
import Testing
@testable import AlbumistCore

/// Design 5C (approved 20.11.2026, draft `E4-alben`): the tab "Alben" shows on top what Albumist
/// made or extended as a shelf of covers ("Von Albumist", "Alle N"), each marked "Neu" or "+N",
/// then the rows Ordner „Reisen“, "Verlauf und Rückgängig" and "Ähnliche Alben" with plain
/// counts, then "Deine Alben". Every album and folder stands once (review P3-16).
@Suite("Albums tab design")
struct AlbumTabDesignTests {
    static func state(_ album: CollectionSnapshot, created: Bool = true, added: Set<AssetID>? = nil) -> ManagedAlbumState {
        ManagedAlbumState(albumID: album.id, sourceID: AlbumistID("s-\(album.id.rawValue)"), lastKnownTitle: album.title,
                          lastKnownParentID: album.parentID, lastKnownMembers: album.assetIDs,
                          addedByAlbumist: added ?? album.assetIDs, createdByAlbumist: created)
    }

    static func photos(_ count: Int, _ prefix: String = "p") -> Set<AssetID> {
        Set((0..<count).map { AssetID("\(prefix)\($0)") })
    }

    static let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))

    /// A finished run confirmed at `day` (days after a fixed date) that created `made` and
    /// added photos to the existing albums `extended`.
    static func run(_ id: String, day: Double, made: [CollectionID] = [], extended: [CollectionID] = [],
                    reverts: AlbumistID? = nil) -> ChangePlan {
        var steps: [PlanStep] = []
        var resolved: [String: CollectionID] = [:]
        for (index, album) in made.enumerated() {
            let key = "new-\(index)"
            steps.append(PlanStep(id: "\(id)-c\(index)", operation: .createAlbum(key: key, title: album.rawValue, parent: .topLevel),
                                  sourceID: nil, state: .succeeded(createdID: album, verifiedAt: Date())))
            steps.append(PlanStep(id: "\(id)-a\(index)", operation: .addAssets(album: .planned(key), assets: ["x"]), sourceID: nil, state: done))
            resolved[key] = album
        }
        for (index, album) in extended.enumerated() {
            steps.append(PlanStep(id: "\(id)-e\(index)", operation: .addAssets(album: .existing(album), assets: ["y"]), sourceID: nil, state: done))
        }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000 + day * 86_400)
        var plan = ChangePlan(id: AlbumistID(id), createdAt: date, confirmedAt: date, status: .completed, baseline: [:],
                              baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [], resolvedKeys: resolved)
        plan.reverts = reverts
        return plan
    }

    /// Every album and folder at most once over the shelf's list, the folder rows and "Deine Alben".
    static func listedOnce(_ sections: AlbumTabSections) -> Bool {
        let folders = sections.rows.compactMap { row -> CollectionID? in
            if case .folder(let folder, _) = row { folder.id } else { nil }
        }
        let ids = sections.albumistAlbums.map(\.id) + folders + sections.yours.map(\.id)
        return Set(ids).count == ids.count
    }

    // MARK: - "Neu" and "+N"

    @Test func anAlbumAlbumistCreatedIsNew() {
        let kyoto = CollectionSnapshot(id: "a1", title: "Kyoto, Oktober 2024", assetIDs: Self.photos(16))
        let sections = AlbumTabSections(inventory: CollectionInventory([kyoto]), managed: [Self.state(kyoto)])
        #expect(sections.albumistAlbums.map(\.mark) == [.new])
    }

    /// An album of the user's that Albumist added photos to says how many, and is never "Neu".
    @Test func anAlbumOfTheUsersSaysHowManyPhotosAlbumistAdded() {
        let toskana = CollectionSnapshot(id: "u1", title: "Toskana", assetIDs: Self.photos(57))
        let added = Set(Self.photos(57).sorted().prefix(12))
        let sections = AlbumTabSections(inventory: CollectionInventory([toskana]),
                                        managed: [Self.state(toskana, created: false, added: added)])
        #expect(sections.albumistAlbums.map(\.mark) == [.added(12)])
        #expect(sections.albumistAlbums.allSatisfy { $0.mark != .new })
    }

    /// The user took every added photo out again: no "+0", no "Neu" either, and nothing left to
    /// undo. The album is the user's again: it leaves "Von Albumist" and stands under "Deine
    /// Alben" (second review of wave 1).
    @Test func anAlbumOfTheUsersWithoutAlbumistsPhotosHasNoMark() {
        let garten = CollectionSnapshot(id: "u1", title: "Garten", assetIDs: Self.photos(3))
        let state = Self.state(garten, created: false, added: [])
        let sections = AlbumTabSections(inventory: CollectionInventory([garten]), managed: [state])
        #expect(AlbumTabSections.mark(state) == nil)
        #expect(sections.albumistAlbums.isEmpty)
        #expect(sections.yours.map(\.id) == ["u1"])
        #expect(!sections.saysNoAlbums)
        #expect(Self.listedOnce(sections))
    }

    /// Created and later extended by another run: still Albumist's own album, "Neu".
    @Test func anAlbumAlbumistCreatedStaysNewWhenExtendedLater() {
        let rom = CollectionSnapshot(id: "a1", title: "Rom", assetIDs: Self.photos(30))
        let sections = AlbumTabSections(inventory: CollectionInventory([rom]), managed: [Self.state(rom)],
                                        history: [Self.run("later", day: 5, extended: ["a1"]), Self.run("first", day: 1, made: ["a1"])])
        #expect(sections.albumistAlbums.map(\.mark) == [.new])
    }

    // MARK: - Order and "Alle N"

    @Test func theNewestChangeComesFirst() {
        let kyoto = CollectionSnapshot(id: "a1", title: "Kyoto", assetIDs: Self.photos(16))
        let lisbon = CollectionSnapshot(id: "a2", title: "Lissabon", assetIDs: Self.photos(42))
        let tuscany = CollectionSnapshot(id: "u1", title: "Toskana", assetIDs: Self.photos(57))
        let old = CollectionSnapshot(id: "a3", title: "Amsterdam", assetIDs: Self.photos(5))
        let history = [Self.run("3", day: 3, extended: ["u1"]), Self.run("2", day: 2, made: ["a2"]), Self.run("1", day: 1, made: ["a1"])]
        let sections = AlbumTabSections(inventory: CollectionInventory([kyoto, lisbon, tuscany, old]),
                                        managed: [Self.state(kyoto), Self.state(lisbon), Self.state(tuscany, created: false), Self.state(old)],
                                        history: history)
        // Amsterdam is older than the history that is loaded: after the others.
        #expect(sections.albumistAlbums.map(\.id) == ["u1", "a2", "a1", "a3"])
        let days: [Double?] = sections.albumistAlbums.map { $0.changedAt.map { ($0.timeIntervalSinceReferenceDate - 800_000_000) / 86_400 } }
        #expect(days == [3, 2, 1, nil])
    }

    /// A run that was taken back, and the undo run itself, date nothing.
    @Test func runsTakenBackDoNotCount() {
        let kyoto = CollectionSnapshot(id: "a1", title: "Kyoto", assetIDs: Self.photos(16))
        let berlin = CollectionSnapshot(id: "a2", title: "Berlin", assetIDs: Self.photos(4))
        let history = [Self.run("undo", day: 9, made: ["a2"], reverts: AlbumistID("taken")),
                       Self.run("taken", day: 8, extended: ["a2"]),
                       Self.run("kept", day: 2, made: ["a1"])]
        let sections = AlbumTabSections(inventory: CollectionInventory([kyoto, berlin]),
                                        managed: [Self.state(kyoto), Self.state(berlin)],
                                        history: history, undone: [AlbumistID("taken")])
        #expect(sections.albumistAlbums.map(\.id) == ["a1", "a2"])
        #expect(sections.albumistAlbums[1].changedAt == nil)
    }

    @Test func albumsWithoutAKnownChangeStandByTitle() {
        let ten = CollectionSnapshot(id: "x", title: "Album 10")
        let two = CollectionSnapshot(id: "y", title: "Album 2")
        let sections = AlbumTabSections(inventory: CollectionInventory([ten, two]), managed: [Self.state(ten), Self.state(two)])
        #expect(sections.albumistAlbums.map(\.id) == ["y", "x"])
    }

    /// One run made several albums: they changed at the same moment and stand by title, before
    /// the albums without a known change.
    @Test func albumsChangedAtTheSameMomentStandByTitle() {
        let berlin = CollectionSnapshot(id: "b", title: "Berlin", assetIDs: Self.photos(2, "b"))
        let amsterdam = CollectionSnapshot(id: "a", title: "Amsterdam", assetIDs: Self.photos(2, "a"))
        let older = CollectionSnapshot(id: "c", title: "Aachen", assetIDs: Self.photos(2, "c"))
        let sections = AlbumTabSections(inventory: CollectionInventory([berlin, amsterdam, older]),
                                        managed: [Self.state(berlin), Self.state(older), Self.state(amsterdam)],
                                        history: [Self.run("r", day: 4, made: ["b", "a"])])
        #expect(sections.albumistAlbums.map(\.id) == ["a", "b", "c"])
    }

    /// "Alle N" stands once more albums are there than the shelf shows at once: two side by side
    /// on the iPhone, four on the iPad, the column of three at the accessibility text sizes
    /// (second review of wave 1: not "Alle 3" beside four tiles that fit).
    @Test(arguments: [(0, 2, false), (2, 2, false), (3, 2, true), (4, 4, false), (5, 4, true),
                      (3, 3, false), (4, 3, true), (12, 2, true), (30, 4, true)])
    func allNStandsOnceMoreAlbumsAreThereThanShow(_ count: Int, _ visible: Int, _ showsAll: Bool) {
        let albums = (0..<count).map { CollectionSnapshot(id: CollectionID("a\($0)"), title: "Reise \($0)", assetIDs: Self.photos(2, "r\($0)-")) }
        let sections = AlbumTabSections(inventory: CollectionInventory(albums), managed: albums.map { Self.state($0) })
        #expect(sections.showsAll(visible: visible) == showsAll)
        #expect(sections.albumistAlbums.count == count)
        #expect(sections.shelf().count == min(count, AlbumTabSections.shelfLimit))
        #expect(sections.shelf().map(\.id) == Array(sections.albumistAlbums.prefix(AlbumTabSections.shelfLimit)).map(\.id))
        // The column at the accessibility text sizes: the first three, the rest behind "Alle N".
        #expect(sections.shelf(limit: AlbumTabSections.columnLimit).map(\.id)
                == Array(sections.albumistAlbums.prefix(3)).map(\.id))
    }

    // MARK: - Rows

    /// The draft: Ordner „Reisen“ 9, Verlauf und Rückgängig 3, Ähnliche Alben 2.
    @Test func theRowsOfTheDraft() {
        let trips = CollectionSnapshot(id: "f1", title: "Reisen", kind: .folder, childIDs: (0..<9).map { CollectionID("t\($0)") })
        let tripAlbums = (0..<9).map { CollectionSnapshot(id: CollectionID("t\($0)"), title: "Reise \($0)", parentID: "f1", assetIDs: Self.photos(3, "t\($0)-")) }
        let history = [Self.run("3", day: 3, made: ["t0"]), Self.run("2", day: 2, made: ["t1"]), Self.run("1", day: 1, made: ["t2"])]
        let sections = AlbumTabSections(inventory: CollectionInventory([trips] + tripAlbums), managed: tripAlbums.map { Self.state($0) },
                                        history: history, similar: 2)
        #expect(sections.rows == [.folder(trips, albums: 9), .history(changes: 3, more: false, interrupted: false), .similar(2)])
        #expect(sections.rows.map(\.id) == ["folder:f1", "history", "similar"])
        #expect(sections.yours.isEmpty)
        #expect(Self.listedOnce(sections))
    }

    /// "Verlauf und Rückgängig" is always there, also before the first change, so undo always
    /// has its place; "Ähnliche Alben" only with a suggestion.
    @Test func theHistoryRowIsAlwaysThereSimilarAlbumsOnlyWithASuggestion() {
        let sections = AlbumTabSections(inventory: CollectionInventory([]), managed: [])
        #expect(sections.rows == [.history(changes: 0, more: false, interrupted: false)])
        #expect(sections.saysNoAlbums && sections.showsYourAlbums)
    }

    @Test func theHistoryRowCountsFinishedChangesAndSaysWhenOneWasCutOff() {
        let history = (0..<50).map { Self.run("r\($0)", day: Double($0)) }
        let sections = AlbumTabSections(inventory: CollectionInventory([]), managed: [], history: history,
                                        moreHistory: true, interrupted: true)
        #expect(sections.rows == [.history(changes: 50, more: true, interrupted: true)])
        // An undo run is not a change of its own: it marks the run it took back.
        let withUndo = AlbumTabSections(inventory: CollectionInventory([]), managed: [],
                                        history: [Self.run("u", day: 2, reverts: AlbumistID("r")), Self.run("r", day: 1)])
        #expect(withUndo.rows == [.history(changes: 1, more: false, interrupted: false)])
    }

    /// The folder for new albums set in the settings ("Albumist") with its subfolders: one row,
    /// counting the albums at every depth, and the folder is not under "Deine Alben" again.
    @Test func aFolderRowCountsTheAlbumsAtEveryDepth() {
        let root = CollectionSnapshot(id: "f", title: "Albumist", kind: .folder, childIDs: ["f2", "a0"])
        let countries = CollectionSnapshot(id: "f2", title: "Länder", kind: .folder, parentID: "f", childIDs: ["a1", "a2"])
        let top = CollectionSnapshot(id: "a0", title: "Kyoto", parentID: "f", assetIDs: Self.photos(2))
        let italy = CollectionSnapshot(id: "a1", title: "Italien", parentID: "f2", assetIDs: Self.photos(2, "i"))
        let spain = CollectionSnapshot(id: "a2", title: "Spanien", parentID: "f2", assetIDs: Self.photos(2, "s"))
        let mine = CollectionSnapshot(id: "u1", title: "Garten", assetIDs: Self.photos(1, "g"))
        let sections = AlbumTabSections(inventory: CollectionInventory([root, countries, top, italy, spain, mine]),
                                        managed: [Self.state(italy), Self.state(top), Self.state(spain)])
        #expect(sections.rows.first == .folder(root, albums: 3))
        #expect(sections.yours.map(\.id) == ["u1"])
        #expect(Self.listedOnce(sections))
    }

    /// A folder of the user's with many albums of the user's and one Albumist made in it stays
    /// the user's (second review of wave 1): no row, it stands under "Deine Alben", and the album
    /// Albumist made is on the shelf.
    @Test func aFolderOfTheUsersWithOneAlbumOfAlbumistsStaysUnderYourAlbums() {
        let trips = CollectionSnapshot(id: "f", title: "Reisen", kind: .folder, childIDs: ["u1", "u2", "a1", "u3"])
        let own = (1...3).map { CollectionSnapshot(id: CollectionID("u\($0)"), title: "Urlaub \($0)", parentID: "f",
                                                   assetIDs: Self.photos(2, "u\($0)-")) }
        let kyoto = CollectionSnapshot(id: "a1", title: "Kyoto", parentID: "f", assetIDs: Self.photos(2, "k"))
        let sections = AlbumTabSections(inventory: CollectionInventory([trips, kyoto] + own), managed: [Self.state(kyoto)])
        #expect(sections.rows == [.history(changes: 0, more: false, interrupted: false)])
        #expect(sections.yours.map(\.id) == ["f"])
        #expect(sections.albumistAlbums.map(\.id) == ["a1"])
        #expect(Self.listedOnce(sections))
    }

    /// A folder row counts what the folder's tile and screen show: the folder's list of albums,
    /// walked down (`albums(in:inventory:)`). While Photos syncs, an album may name a folder that
    /// does not list it yet, or the other way round; row and tile still agree.
    @Test func aFolderRowCountsWhatItsTileShows() {
        let trips = CollectionSnapshot(id: "f", title: "Reisen", kind: .folder, childIDs: ["a1", "a2"])
        let listed = CollectionSnapshot(id: "a1", title: "Kyoto", parentID: "f", assetIDs: Self.photos(2, "k"))
        let movedAway = CollectionSnapshot(id: "a2", title: "Rom", parentID: nil, assetIDs: Self.photos(2, "r"))
        let notListedYet = CollectionSnapshot(id: "a3", title: "Paris", parentID: "f", assetIDs: Self.photos(2, "p"))
        let inventory = CollectionInventory([trips, listed, movedAway, notListedYet])
        let sections = AlbumTabSections(inventory: inventory,
                                        managed: [Self.state(listed), Self.state(movedAway), Self.state(notListedYet)])
        let tile = AlbumTabSections.albums(in: trips, inventory: inventory)
        #expect(sections.rows.first == .folder(trips, albums: tile.count))
        #expect(tile.map(\.id) == ["a1", "a2"])
        #expect(Self.listedOnce(sections))
    }

    /// An album Albumist remembers that is not in the list (deleted in Photos, or not synced yet)
    /// is neither on the shelf nor counted, also when its folder still lists it.
    @Test func aRememberedAlbumMissingFromTheListIsNeitherShownNorCounted() {
        let trips = CollectionSnapshot(id: "f", title: "Reisen", kind: .folder, childIDs: ["a1", "a9"])
        let kyoto = CollectionSnapshot(id: "a1", title: "Kyoto", parentID: "f", assetIDs: Self.photos(2, "k"))
        let gone = CollectionSnapshot(id: "a9", title: "Weg", parentID: "f", assetIDs: Self.photos(2, "w"))
        let sections = AlbumTabSections(inventory: CollectionInventory([trips, kyoto]),
                                        managed: [Self.state(gone), Self.state(kyoto)])
        #expect(sections.albumistAlbums.map(\.id) == ["a1"])
        #expect(sections.rows.first == .folder(trips, albums: 1))
        #expect(Self.listedOnce(sections))
    }

    /// An album remembered twice stands by its first record, the one the undo reads: without
    /// anything of Albumist's left there, it is the user's again, whatever a later record says;
    /// with it, it stands once.
    @Test func anAlbumRememberedTwiceGoesByItsFirstRecord() {
        let garden = CollectionSnapshot(id: "u1", title: "Garten", assetIDs: Self.photos(3))
        let empty = Self.state(garden, created: false, added: [])
        var later = Self.state(garden, created: false, added: Set(Self.photos(3).sorted().prefix(1)))
        later.sourceID = AlbumistID("later")
        let emptyFirst = AlbumTabSections(inventory: CollectionInventory([garden]), managed: [empty, later])
        #expect(emptyFirst.albumistAlbums.isEmpty)
        #expect(emptyFirst.yours.map(\.id) == ["u1"])
        let markedFirst = AlbumTabSections(inventory: CollectionInventory([garden]), managed: [later, empty])
        #expect(markedFirst.albumistAlbums.map(\.id) == ["u1"])
        #expect(markedFirst.albumistAlbums.map(\.mark) == [.added(1)])
        #expect(markedFirst.yours.isEmpty)
    }

    /// A folder of the user's with an album Albumist only extended stays the user's: no row.
    @Test func aFolderWithOnlyAnExtendedAlbumStaysUnderYourAlbums() {
        let holidays = CollectionSnapshot(id: "f", title: "Urlaub", kind: .folder, childIDs: ["u1"])
        let tuscany = CollectionSnapshot(id: "u1", title: "Toskana", parentID: "f", assetIDs: Self.photos(5))
        let sections = AlbumTabSections(inventory: CollectionInventory([holidays, tuscany]),
                                        managed: [Self.state(tuscany, created: false)])
        #expect(sections.rows == [.history(changes: 0, more: false, interrupted: false)])
        #expect(sections.yours.map(\.id) == ["f"])
        #expect(sections.albumistAlbums.map(\.id) == ["u1"])
        #expect(Self.listedOnce(sections))
    }

    @Test func folderRowsComeInTheOrderOfPhotos() {
        let trips = CollectionSnapshot(id: "f1", title: "Reisen", kind: .folder, childIDs: ["t"])
        let countries = CollectionSnapshot(id: "f2", title: "Länder", kind: .folder, childIDs: ["c"])
        let trip = CollectionSnapshot(id: "t", title: "Kyoto", parentID: "f1", assetIDs: Self.photos(2))
        let country = CollectionSnapshot(id: "c", title: "Japan", parentID: "f2", assetIDs: Self.photos(2, "j"))
        let sections = AlbumTabSections(inventory: CollectionInventory([trips, countries, trip, country]),
                                        managed: [Self.state(trip), Self.state(country)], similar: 1)
        #expect(sections.rows.map(\.id) == ["folder:f2", "folder:f1", "history", "similar"])
    }

    /// A folder whose parent is missing from the list (iCloud still syncing) gives no row; the
    /// album still stands on the shelf.
    @Test func anAlbumWhoseFoldersAreNotAllListedGivesNoRow() {
        let inner = CollectionSnapshot(id: "f2", title: "Länder", kind: .folder, parentID: "missing", childIDs: ["a1"])
        let album = CollectionSnapshot(id: "a1", title: "Italien", parentID: "f2", assetIDs: Self.photos(2))
        let sections = AlbumTabSections(inventory: CollectionInventory([inner, album]), managed: [Self.state(album)])
        #expect(sections.rows == [.history(changes: 0, more: false, interrupted: false)])
        #expect(sections.albumistAlbums.map(\.id) == ["a1"])
    }

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

    /// "Rückgängig machen" on one album, worked out without building the removal (the long
    /// press's line, the confirmation's button): exactly what `ManagedAlbumTracker` would plan.
    @Test func theUndoOfOneAlbumIsWhatTheRemovalPlans() {
        let ours = Self.photos(3, "o")
        let cases: [(String, CollectionSnapshot?, ManagedAlbumState, AlbumTabSections.UndoEffect)] = {
            let made = CollectionSnapshot(id: "a1", title: "Kyoto", assetIDs: ours)
            let filled = CollectionSnapshot(id: "a2", title: "Rom", assetIDs: ours.union(["mine"]))
            let partly = CollectionSnapshot(id: "a3", title: "Paris", assetIDs: Set(ours.sorted().prefix(1)).union(["mine"]))
            let extended = CollectionSnapshot(id: "u1", title: "Toskana", assetIDs: ours.union(Self.photos(5, "m")))
            let emptied = CollectionSnapshot(id: "u2", title: "Garten", assetIDs: Self.photos(2, "m"))
            let locked = CollectionSnapshot(id: "a4", title: "Geteilt", kind: .restrictedAlbum, assetIDs: ours)
            let gone = CollectionSnapshot(id: "a5", title: "Weg", assetIDs: ours)
            return [
                ("made, only Albumist's photos", made, Self.state(made, added: ours), .init(deletesAlbum: true, photosTakenOut: 0)),
                ("made, the user's photo too", filled, Self.state(filled, added: ours), .init(deletesAlbum: false, photosTakenOut: 3)),
                ("made, some taken out by the user", partly, Self.state(partly, added: ours), .init(deletesAlbum: false, photosTakenOut: 1)),
                ("the user's, extended", extended, Self.state(extended, created: false, added: ours), .init(deletesAlbum: false, photosTakenOut: 3)),
                ("the user's, all taken out again", emptied, Self.state(emptied, created: false, added: ours), .init(deletesAlbum: false, photosTakenOut: 0)),
                ("cannot be changed", locked, Self.state(locked, added: ours), .init(deletesAlbum: false, photosTakenOut: 0)),
                ("not in the list", nil, Self.state(gone, added: ours), .init(deletesAlbum: false, photosTakenOut: 0)),
            ]
        }()
        for (name, album, state, expected) in cases {
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
