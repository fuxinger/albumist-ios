import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The covers of the changes Albumist made (design wave 3, DS-15): the history shows one per
/// change, made of the albums of that run, the receipt one per album, each chosen as the tab
/// "Alben" chooses an album's cover (`PreviewPicker.coverCandidates`: photos only, newest first,
/// never a screenshot, a document or a sensitive document; "Vorschau ausgeblendet" for an album of
/// nothing but sensitive documents). Which photos is decided here (`PlanCovers`); the app shows the
/// first one that is sharp on the device (`CoverPhoto`).
@Suite("Covers of the history and the receipt")
struct PlanCoversTests {
    static let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))
    static let new = ProposalDecision.createNew(title: nil, folderPath: nil)

    /// A plan of `operations`, each step done unless `states` says otherwise.
    static func plan(_ operations: [PlannedOperation], states: [Int: StepState] = [:], record: ExecutionRecord? = nil,
                     status: PlanStatus = .completed) -> ChangePlan {
        let steps = operations.enumerated().map { index, operation in
            PlanStep(id: "s\(index)", operation: operation, sourceID: nil, state: states[index] ?? Self.done)
        }
        var plan = ChangePlan(id: AlbumistID("p"), createdAt: Date(timeIntervalSince1970: 0), confirmedAt: Date(timeIntervalSince1970: 0),
                              status: status, baseline: [:], baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [],
                              resolvedKeys: [:])
        plan.record = record
        return plan
    }

    /// A new album `key` with `photos`.
    static func newAlbum(_ key: String, _ photos: [AssetID]) -> [PlannedOperation] {
        [.createAlbum(key: key, title: key, parent: .topLevel), .addAssets(album: .planned(key), assets: photos)]
    }

    /// `count` photos "<name>-1" … "<name>-<count>".
    static func photos(_ name: String, _ count: Int) -> [AssetID] {
        (1...count).map { AssetID("\(name)-\($0)") }
    }

    /// Each photo a day after the one before it in `ids`: the last one is the newest.
    static func dates(_ ids: [AssetID]) -> [AssetID: Date] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, Date(timeIntervalSince1970: Double($0.offset) * 86_400)) })
    }

    /// A trip with `count` photos "<id>-1" … "<id>-<count>".
    static func trip(_ id: String, photos count: Int = 3) -> AlbumProposal {
        AlbumProposal(id: AlbumistID(id), kind: .trip, title: "Reise \(id)", folderPath: ["Reisen"],
                      assetIDs: Set(Self.photos(id, count)))
    }

    static func run(_ plan: ChangePlan, in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        var confirmed = plan
        confirmed.confirmedAt = Date()
        confirmed.status = .confirmed
        return try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed)
    }

    // MARK: The receipt: one cover per album

    /// Every album the run gave photos has its cover, under the name the receipt gives the album
    /// (`PlanReceipt.Album.id`: "planned:" and the key for a new one, the collection id for one of
    /// the user's), so each row of the receipt finds its own.
    @Test func eachAlbumOfTheReceiptHasItsCover() async throws {
        let kyoto = Self.trip("kyoto", photos: 16), rom = Self.trip("rom"), lissabon = Self.trip("lissabon")
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: kyoto.assetIDs.union(rom.assetIDs).union(lissabon.assetIDs).union(["own"]),
                                           collections: [mine])
        let plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                         ConfirmedProposal(proposal: rom, decision: .extendExisting("mine")),
                                                         ConfirmedProposal(proposal: lissabon, decision: Self.new)],
                                                  inventory: try await library.currentInventory())
        let made = try await Self.run(plan, in: library)
        #expect(made.status == .completed)

        let covers = PlanCovers.albums(of: made, dates: [:], ranks: [:])
        let receipt = PlanReceipt(plan: made, inventory: CollectionInventory())
        let withPhotos = receipt.albums.filter { $0.added > 0 }.map(\.id)
        #expect(withPhotos.count == 3)
        #expect(Set(covers.keys) == Set(withPhotos))
        #expect(covers["mine"] != nil, "the user's album that got photos has no cover")
        // Only photos the run added: never the user's own photo of the album.
        #expect(covers["mine"]?.ids.contains("own") == false)
        #expect(covers.values.allSatisfy { !$0.ids.isEmpty && !$0.hidden })
        // In the order of the receipt.
        #expect(PlanCovers.photos(of: made).map(\.album) == withPhotos)
    }

    /// An album's cover is its newest photo, then the next newest to try, as the tab "Alben" shows
    /// the album once it is made (`AlbumCover`), whatever order the plan lists them in.
    @Test func anAlbumShowsItsNewestPhotoAsTheAlbumsTabDoes() {
        let rome = Self.photos("rom", 6)
        let dates = Self.dates(rome)
        let plan = Self.plan(Self.newAlbum("rom", [rome[2], rome[5], rome[0], rome[4], rome[1], rome[3]]))
        let cover = PlanCovers.albums(of: plan, dates: dates, ranks: [:])["planned:rom"]
        #expect(cover?.ids == ["rom-6", "rom-5", "rom-4", "rom-3"])
        #expect(cover?.hidden == false)
        #expect(PlanCovers.candidates == 4)
        #expect(cover == PlanCovers.cover(of: rome, dates: dates, ranks: [:]))
        #expect(cover?.ids == PreviewPicker.coverCandidates(rome, cover: nil, dates: dates, ranks: [:], count: 4))
    }

    /// Only what the library confirmed counts, as in the receipt's numbers: a step whose outcome is
    /// unclear or that failed shows nothing. A plan cut off on its way (`applied: false`) shows
    /// what it sets out to add, so its row in the history is recognised before it is complete.
    @Test func onlyWhatTheLibraryConfirmedCounts() {
        var record = ExecutionRecord()
        record.media["s1"] = ["a-1", "a-2"]
        record.unverified = ["s3"]
        // Steps: 0 and 1 make "a" (the library confirmed two of its four photos), 2 and 3 make "b"
        // (its photos unclear), 4 adds to an album of the user's and failed.
        let plan = Self.plan(Self.newAlbum("a", Self.photos("a", 4)) + Self.newAlbum("b", Self.photos("b", 2))
                             + [.addAssets(album: .existing("mine"), assets: ["c-1"])],
                             states: [4: .failed(reason: "Fotos hat nicht geantwortet.")], record: record,
                             status: .completedWithErrors)
        let covers = PlanCovers.albums(of: plan, dates: [:], ranks: [:])
        #expect(Set(covers.keys) == ["planned:a"])
        #expect(Set(covers["planned:a"]?.ids ?? []) == ["a-1", "a-2"])

        let interrupted = Self.plan(Self.newAlbum("a", Self.photos("a", 2)) + Self.newAlbum("b", Self.photos("b", 2)),
                                    states: [2: .pending, 3: .pending], status: .running)
        #expect(PlanCovers.albums(of: interrupted, dates: [:], ranks: [:]).keys.sorted() == ["planned:a"])
        let planned = PlanCovers.albums(of: interrupted, applied: false, dates: [:], ranks: [:])
        #expect(planned.keys.sorted() == ["planned:a", "planned:b"])
        #expect(Set(planned["planned:b"]?.ids ?? []) == ["b-1", "b-2"])
    }

    /// A big cover is a photo (design rule 9): never a sensitive document, never a screenshot or
    /// another document; analysed photos before photos the analysis has not looked at yet. An album
    /// of nothing but sensitive documents says "Vorschau ausgeblendet"; one of only screenshots has
    /// no photo to try and shows the calm ground with its symbol, as in the tab "Alben".
    @Test func neverASensitiveDocumentAScreenshotOrADocument() {
        let ranks: [AssetID: PreviewRank] = ["mixed-2": .sensitive, "mixed-3": .document, "mixed-4": .unknown,
                                             "cards-1": .sensitive, "cards-2": .sensitive,
                                             "shots-1": .document, "shots-2": .document]
        let plan = Self.plan(Self.newAlbum("mixed", Self.photos("mixed", 4)) + Self.newAlbum("cards", Self.photos("cards", 2))
                             + Self.newAlbum("shots", Self.photos("shots", 2)))
        let covers = PlanCovers.albums(of: plan, dates: Self.dates(Self.photos("mixed", 4)), ranks: ranks)
        #expect(covers["planned:mixed"] == PlanCovers.Cover(ids: ["mixed-1", "mixed-4"], hidden: false))
        #expect(covers["planned:cards"] == PlanCovers.Cover(ids: [], hidden: true))
        #expect(covers["planned:shots"] == PlanCovers.Cover(ids: [], hidden: false))
    }

    // MARK: The history: one cover per change

    /// A change's cover holds up to four of its albums, in the order of the plan, one photo row to
    /// try for each (as a folder's tile shows its albums).
    @Test func aChangeShowsUpToFourOfItsAlbumsInTheOrderOfThePlan() {
        let names = ["t1", "t2", "t3", "t4", "t5", "t6"]
        let six = Self.plan(names.flatMap { Self.newAlbum($0, Self.photos($0, 2)) })
        let mosaic = PlanCovers.mosaic(of: six, dates: [:], ranks: [:])
        #expect(PlanCovers.tiles == 4)
        #expect(mosaic.tiles.count == 4)
        #expect(mosaic.tiles.map { $0.first?.rawValue.components(separatedBy: "-").first } == ["t1", "t2", "t3", "t4"])
        #expect(!mosaic.hidden && !mosaic.isEmpty)
        for count in 1...3 {
            let fewer = Self.plan(names.prefix(count).flatMap { Self.newAlbum($0, Self.photos($0, 2)) })
            #expect(PlanCovers.mosaic(of: fewer, dates: [:], ranks: [:]).tiles.count == count)
        }
        // Each album its newest photos first, as its own cover.
        let one = Self.plan(Self.newAlbum("rom", Self.photos("rom", 6)))
        let dates = Self.dates(Self.photos("rom", 6))
        #expect(PlanCovers.mosaic(of: one, dates: dates, ranks: [:]).tiles
                == [PlanCovers.cover(of: Self.photos("rom", 6), dates: dates, ranks: [:]).ids])
    }

    /// The same photo never shows twice in one cover: a country album holds its trip's photos, so
    /// it tries its other ones; an album with nothing left to try makes room for the next.
    @Test func aPhotoIsTriedByOneAlbumOfTheCoverOnly() {
        let rome = Self.photos("rom", 3)
        let plan = Self.plan(Self.newAlbum("rom", rome) + Self.newAlbum("italien", rome + ["italien-1"])
                             + Self.newAlbum("same", rome) + Self.newAlbum("kyoto", ["kyoto-1"]))
        let mosaic = PlanCovers.mosaic(of: plan, dates: Self.dates(rome), ranks: [:])
        #expect(mosaic.tiles == [["rom-3", "rom-2", "rom-1"], ["italien-1"], ["kyoto-1"]])
        let tried = mosaic.tiles.flatMap { $0 }
        #expect(Set(tried).count == tried.count)
    }

    /// Never an empty place in a change's cover: an album with no photo to show (only sensitive
    /// documents, only screenshots) makes room for the next.
    @Test func albumsWithoutAPhotoToShowMakeRoomForTheNext() {
        let ranks: [AssetID: PreviewRank] = ["cards-1": .sensitive, "shots-1": .document]
        let plan = Self.plan(Self.newAlbum("cards", ["cards-1"]) + Self.newAlbum("shots", ["shots-1"])
                             + Self.newAlbum("rom", ["rom-1"]))
        let mosaic = PlanCovers.mosaic(of: plan, dates: [:], ranks: ranks)
        #expect(mosaic == PlanCovers.Mosaic(tiles: [["rom-1"]], hidden: false))
    }

    /// A change of nothing but sensitive documents says "Vorschau ausgeblendet"; one with no photo
    /// to show but screenshots among them shows the calm ground with its symbol.
    @Test func aChangeOfOnlySensitiveDocumentsHidesItsPreview() {
        let ranks: [AssetID: PreviewRank] = ["cards-1": .sensitive, "cards-2": .sensitive, "ids-1": .sensitive, "shots-1": .document]
        let sensitive = Self.plan(Self.newAlbum("cards", ["cards-1", "cards-2"]) + Self.newAlbum("ids", ["ids-1"]))
        let hidden = PlanCovers.mosaic(of: sensitive, dates: [:], ranks: ranks)
        #expect(hidden == PlanCovers.Mosaic(tiles: [], hidden: true))
        #expect(!hidden.isEmpty)
        let withScreenshots = Self.plan(Self.newAlbum("cards", ["cards-1"]) + Self.newAlbum("shots", ["shots-1"]))
        let calm = PlanCovers.mosaic(of: withScreenshots, dates: [:], ranks: ranks)
        #expect(calm == PlanCovers.Mosaic(tiles: [], hidden: false))
        #expect(calm.isEmpty)
    }

    /// An undo and a removal from "Alben von Albumist" only take photos out and remove albums: no
    /// cover of photos, their symbol on the calm ground (as the receipt shows removed albums).
    @Test func anUndoAndARemovalHaveNoCoverOfPhotos() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom")
        let library = InMemoryPhotoLibrary(assets: kyoto.assetIDs.union(rom.assetIDs))
        let made = try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: kyoto, decision: Self.new)],
                                                                    inventory: try await library.currentInventory()), in: library)
        #expect(!PlanCovers.mosaic(of: made, dates: [:], ranks: [:]).isEmpty)

        let tracker = ManagedAlbumTracker()
        let inventory = try await library.currentInventory()
        let states = tracker.record(made, into: [], inventory: inventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: states, current: inventory, earlierUndos: []), in: library)
        #expect(PlanReceipt.Kind(undo) == .undone)
        #expect(PlanCovers.albums(of: undo, dates: [:], ranks: [:]).isEmpty)
        #expect(PlanCovers.mosaic(of: undo, dates: [:], ranks: [:]).isEmpty)
        #expect(PlanCovers.mosaic(of: undo, applied: false, dates: [:], ranks: [:]).isEmpty)

        let romMade = try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: rom, decision: Self.new)],
                                                                       inventory: try await library.currentInventory()), in: library)
        let romState = try #require(tracker.record(romMade, into: [], inventory: try await library.currentInventory()).first)
        let removal = try await Self.run(tracker.removalPlan(for: romState, current: try await library.currentInventory()), in: library)
        #expect(PlanReceipt.Kind(removal) == .removed)
        #expect(PlanCovers.albums(of: removal, dates: [:], ranks: [:]).isEmpty)
        #expect(PlanCovers.mosaic(of: removal, dates: [:], ranks: [:]).isEmpty)
    }

    /// The same covers whatever order the plan lists its albums' photos in, and a photo added twice
    /// to one album is one photo.
    @Test func theSameCoversWhateverTheOrder() {
        let rome = Self.photos("rom", 8), kyoto = Self.photos("kyoto", 5)
        let dates = Self.dates(rome + kyoto)
        let ranks: [AssetID: PreviewRank] = ["rom-8": .sensitive, "kyoto-5": .document]
        let ordered = Self.plan(Self.newAlbum("rom", rome) + Self.newAlbum("kyoto", kyoto))
        let shuffled = Self.plan(Self.newAlbum("rom", rome.reversed()) + Self.newAlbum("kyoto", [kyoto[3], kyoto[0], kyoto[4], kyoto[2], kyoto[1]])
                                 + [.addAssets(album: .planned("rom"), assets: [rome[0], rome[7]])])
        #expect(PlanCovers.albums(of: ordered, dates: dates, ranks: ranks) == PlanCovers.albums(of: shuffled, dates: dates, ranks: ranks))
        #expect(PlanCovers.mosaic(of: ordered, dates: dates, ranks: ranks) == PlanCovers.mosaic(of: shuffled, dates: dates, ranks: ranks))
        #expect(PlanCovers.photos(of: shuffled).first?.photos.count == 8)
    }

    /// A large change (the starter pack of a big library): 50,000 photos in 50 albums, worked out in
    /// one pass over them, four albums with four photos each to try in the history.
    @Test func aLargeChange() {
        let albums = (0..<50).map { album in (0..<1_000).map { AssetID("a\(album)-\($0)") } }
        let plan = Self.plan(albums.enumerated().flatMap { Self.newAlbum("a\($0.offset)", $0.element) })
        let covers = PlanCovers.albums(of: plan, dates: [:], ranks: [:])
        #expect(covers.count == 50)
        #expect(covers.values.allSatisfy { $0.ids.count == PlanCovers.candidates })
        let mosaic = PlanCovers.mosaic(of: plan, dates: [:], ranks: [:])
        #expect(mosaic.tiles.count == PlanCovers.tiles)
        #expect(mosaic.tiles.allSatisfy { $0.count == PlanCovers.candidates })
    }
}
