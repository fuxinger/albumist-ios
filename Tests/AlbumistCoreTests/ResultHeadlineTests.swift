import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// What the result after a run says (design 7.1, N-07): the counts of the receipt, big "10 neue
/// Alben" and small "mit 342 Fotos"; a removal called a removal ("1 Album entfernt", never
/// "0 Fotos einsortiert"); the way to the new albums only when there are new albums; and what
/// "Rückgängig machen" below it does.
@Suite("Result headline")
struct ResultHeadlineTests {
    static let kyoto = AlbumProposal(id: AlbumistID("kyoto"), kind: .trip, title: "Kyoto, Oktober 2024", folderPath: ["Reisen"],
                                     assetIDs: ["k1", "k2", "k3"])
    static let rom = AlbumProposal(id: AlbumistID("rom"), kind: .trip, title: "Rom, Juni 2022", folderPath: ["Reisen"],
                                   assetIDs: ["r1", "r2"])
    static let assets: Set<AssetID> = ["k1", "k2", "k3", "r1", "r2", "own"]
    static let new = ProposalDecision.createNew(title: nil, folderPath: nil)

    static func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    static func run(_ plan: ChangePlan, in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(plan))
    }

    /// Makes the albums of `items` in `library`, as the preview's run does.
    static func make(_ items: [ConfirmedProposal], in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        let plan = OrganizationPlanner().makePlan(from: items, inventory: try await library.currentInventory())
        let made = try await run(plan, in: library)
        #expect(made.status == .completed)
        return made
    }

    // MARK: N-07: a removal says what it removed

    /// "Entfernen" in "Alben von Albumist" deleted the album: the result says "1 Album entfernt"
    /// and that the photos stay, not "0 Fotos einsortiert" and not where "Deine neuen Alben" are
    /// (screenshot ui-dc-15-album-removed of Build 40).
    @Test func aRemovedAlbumIsCalledRemoved() async throws {
        let library = InMemoryPhotoLibrary(assets: Self.assets)
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)], in: library)
        let tracker = ManagedAlbumTracker()
        let state = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first)
        let removal = try await Self.run(tracker.removalPlan(for: state, current: try await library.currentInventory()), in: library)
        #expect(removal.status == .completed)
        let after = try await library.currentInventory()
        #expect(after[state.albumID] == nil)

        let headline = ResultHeadline(plan: removal, inventory: after)
        #expect(headline.kind == .removed)
        #expect(headline.lead == .removedAlbums(1))
        #expect(headline.detail == .photosStay)
        #expect(!headline.showsWhereNewAlbumsAre)
        // "Rückgängig machen" brings the album back with its photos.
        #expect(headline.undoNote == .bringsBackAlbums(1))
        // The count is the receipt's.
        #expect(PlanReceipt(plan: removal, inventory: after).containersDeleted == 1)
    }

    /// An album that holds a photo of the user's stays; only Albumist's photos leave it.
    @Test func photosTakenOutOfAnAlbumThatStays() async throws {
        let library = InMemoryPhotoLibrary(assets: Self.assets)
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)], in: library)
        let tracker = ManagedAlbumTracker()
        let state = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first)
        try await library.addAssets(["own"], to: state.albumID)
        let removal = try await Self.run(tracker.removalPlan(for: state, current: try await library.currentInventory()), in: library)
        let after = try await library.currentInventory()
        #expect(after[state.albumID]?.assetIDs == ["own"])

        let headline = ResultHeadline(plan: removal, inventory: after)
        #expect(headline.kind == .removed)
        #expect(headline.lead == .takenOutPhotos(3))
        #expect(headline.detail == .photosStay)
        #expect(!headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .putsBackPhotos)
        #expect(PlanReceipt(plan: removal, inventory: after).membershipsRemoved == 3)
    }

    // MARK: 7.1: new albums, big and small

    /// "2 neue Alben" big, "mit 5 Fotos" small, the way to them, and that undo removes them:
    /// the numbers of the receipt.
    @Test func newAlbumsWithTheirPhotos() async throws {
        let library = InMemoryPhotoLibrary(assets: Self.assets)
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new),
                                        ConfirmedProposal(proposal: Self.rom, decision: Self.new)], in: library)
        let after = try await library.currentInventory()
        let receipt = PlanReceipt(plan: made, inventory: after)
        #expect(receipt.albumsCreated == 2 && receipt.photosAdded == 5)

        let headline = ResultHeadline(plan: made, inventory: after)
        #expect(headline.kind == .created)
        #expect(headline.lead == .newAlbums(2))
        #expect(headline.detail == .withPhotos(5))
        #expect(headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .removesNewAlbums(2))
    }

    /// Photos added to an album of the user's (draft E3, "nur ergänzt"): "2 Fotos" big, "in
    /// einem deiner Alben ergänzt" small, and nothing about new albums.
    @Test func anAlbumOfTheUsersGetsPhotos() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: Self.assets, collections: [mine])
        let made = try await Self.make([ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("mine"))], in: library)
        let after = try await library.currentInventory()
        #expect(after["mine"]?.assetIDs == ["own", "r1", "r2"])

        let headline = ResultHeadline(plan: made, inventory: after)
        #expect(headline.kind == .created)
        #expect(headline.lead == .addedPhotos(2))
        #expect(headline.detail == .inYourAlbums(1))
        #expect(!headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .takesOutAddedPhotos(albums: 1))
    }

    /// Draft E3, "nur ergänzt": "12 Fotos in 3 deiner Alben ergänzt", both numbers the receipt's
    /// (photos that were already in an album are not counted, a photo in two albums once).
    @Test func twelvePhotosInThreeOfTheUsersAlbums() async throws {
        let japan = CollectionSnapshot(id: "japan", title: "Japan", assetIDs: ["own"])
        let italy = CollectionSnapshot(id: "italy", title: "Italien", assetIDs: [])
        let spain = CollectionSnapshot(id: "spain", title: "Spanien", assetIDs: [])
        let photos = (1...12).map { AssetID("p\($0)") }
        let tokyo = AlbumProposal(id: AlbumistID("tokyo"), kind: .trip, title: "Tokio", assetIDs: Set(photos[0..<5]))
        let rome = AlbumProposal(id: AlbumistID("rome"), kind: .trip, title: "Rom", assetIDs: Set(photos[5..<9]))
        // "p9" goes to "Italien" and to "Spanien": it counts once.
        let madrid = AlbumProposal(id: AlbumistID("madrid"), kind: .trip, title: "Madrid", assetIDs: Set(photos[8..<12]))
        let library = InMemoryPhotoLibrary(assets: Set(photos + ["own"]), collections: [japan, italy, spain])
        let made = try await Self.make([ConfirmedProposal(proposal: tokyo, decision: .extendExisting("japan")),
                                        ConfirmedProposal(proposal: rome, decision: .extendExisting("italy")),
                                        ConfirmedProposal(proposal: madrid, decision: .extendExisting("spain"))], in: library)
        let after = try await library.currentInventory()
        let receipt = PlanReceipt(plan: made, inventory: after)
        #expect(receipt.albumsCreated == 0 && receipt.albumsExtended == 3 && receipt.photosAdded == 12)

        let headline = ResultHeadline(plan: made, inventory: after)
        #expect(headline.lead == .addedPhotos(receipt.photosAdded))
        #expect(headline.detail == .inYourAlbums(receipt.albumsExtended))
        #expect(!headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .takesOutAddedPhotos(albums: 3))
    }

    /// Draft E3, one album: "1 neues Album · mit 16 Fotos", the numbers of the receipt.
    @Test func oneNewAlbumWithSixteenPhotos() async throws {
        let photos = Set((1...16).map { AssetID("k\($0)") })
        let kyoto = AlbumProposal(id: AlbumistID("kyoto16"), kind: .trip, title: "Kyoto, Oktober 2024", folderPath: ["Reisen"],
                                  assetIDs: photos)
        let library = InMemoryPhotoLibrary(assets: photos)
        let made = try await Self.make([ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        let after = try await library.currentInventory()
        let receipt = PlanReceipt(plan: made, inventory: after)
        #expect(receipt.albumsCreated == 1 && receipt.photosAdded == 16)

        let headline = ResultHeadline(plan: made, inventory: after)
        #expect(headline.lead == .newAlbums(1))
        #expect(headline.detail == .withPhotos(16))
        #expect(headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .removesNewAlbums(1))
    }

    /// New albums and an album of the user's in one run: the photos are not said to be in the
    /// new albums ("mit 5 Fotos" under "1 neues Album" would count the user's album's too).
    @Test func newAndExtendedInOneRun() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: Self.assets, collections: [mine])
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new),
                                        ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("mine"))], in: library)
        let after = try await library.currentInventory()
        let receipt = PlanReceipt(plan: made, inventory: after)
        #expect(receipt.albumsCreated == 1 && receipt.albumsExtended == 1 && receipt.photosAdded == 5)

        let headline = ResultHeadline(plan: made, inventory: after)
        #expect(headline.lead == .newAlbums(1))
        #expect(headline.detail == .extendedAndSorted(albums: 1, photos: 5))
        #expect(headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .removesNewAlbumsAndAddedPhotos)
    }

    /// A run that makes an album and adds photos to one Albumist made, or a retry ("Fehlendes
    /// erneut versuchen" makes the album its first run could not and fills the one it made), says
    /// the general sentence under "Rückgängig machen": "… aus deinen Alben" would call Albumist's
    /// album the user's own (review E2 of design wave 2, N4). The count and the line stay.
    @Test func aMixedRunCallsOnlyTheUsersAlbumsTheirs() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: Self.assets, collections: [mine])
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new),
                                        ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("mine"))], in: library)
        let after = try await library.currentInventory()
        #expect(ResultHeadline(plan: made, inventory: after).undoNote == .removesNewAlbumsAndAddedPhotos)

        // The album that got photos is one Albumist made.
        let albumists = ResultHeadline(plan: made, inventory: after, albumistAlbums: ["mine"])
        #expect(albumists.lead == .newAlbums(1))
        #expect(albumists.detail == .extendedAndSorted(albums: 1, photos: 5))
        #expect(albumists.showsWhereNewAlbumsAre)
        #expect(albumists.undoNote == .general)
        // An album of Albumist's that got nothing is not named: the user's album keeps the words.
        #expect(ResultHeadline(plan: made, inventory: after, albumistAlbums: ["elsewhere"]).undoNote == .removesNewAlbumsAndAddedPhotos)

        // A retry fills the albums its first run made.
        var retry = made
        retry.retries = AlbumistID("first run")
        let retried = ResultHeadline(plan: retry, inventory: after)
        #expect(retried.lead == .newAlbums(1))
        #expect(retried.undoNote == .general)
    }

    // MARK: Whose albums (review E of design wave 2, finding 12)

    /// The key of the new album named `title` in `plan`.
    static func albumKey(_ title: String, in plan: ChangePlan) throws -> String {
        try #require(plan.steps.lazy.compactMap { step -> String? in
            if case .createAlbum(let key, let name, _) = step.operation, name == title { key } else { nil }
        }.first)
    }

    /// An album Albumist made (its records say so) that gets more photos is not one "deiner
    /// Alben": the neutral words of before, "1 Album ergänzt" over "mit 2 Fotos", and "Rückgängig
    /// machen" with the general sentence instead of "aus deinen Alben".
    @Test func anAlbumAlbumistMadeKeepsNeutralWords() async throws {
        let earlier = CollectionSnapshot(id: "earlier", title: "Rom, Juni 2022", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: Self.assets, collections: [earlier])
        let made = try await Self.make([ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("earlier"))], in: library)
        let after = try await library.currentInventory()
        let yours = ResultHeadline(plan: made, inventory: after)
        #expect(yours.lead == .addedPhotos(2) && yours.detail == .inYourAlbums(1))

        let albumists = ResultHeadline(plan: made, inventory: after, albumistAlbums: ["earlier"])
        #expect(albumists.kind == .created)
        #expect(albumists.lead == .extendedAlbums(1))
        #expect(albumists.detail == .withPhotos(2))
        #expect(!albumists.showsWhereNewAlbumsAre)
        #expect(albumists.undoNote == .general)
    }

    /// "Fehlendes erneut versuchen" fills the album its first run made: neutral words, whatever
    /// the records say.
    @Test func aRetryKeepsNeutralWords() async throws {
        let library = InMemoryPhotoLibrary(assets: Self.assets)
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)], in: library)
        var gapped = made
        let add = try #require(gapped.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } })
        gapped.steps[add].state = .failed(reason: "Fotos hat nicht geantwortet.")
        gapped.status = .completedWithErrors
        let album = try #require(gapped.resolvedKeys[try Self.albumKey(Self.kyoto.title, in: gapped)])
        try await library.removeAssets(["k2", "k3"], from: album)
        let retry = try #require(RetryPlanner().retryPlan(for: gapped, current: try await library.currentInventory()))
        let retried = try await Self.run(retry, in: library)
        let after = try await library.currentInventory()
        #expect(PlanReceipt(plan: retried, inventory: after).albumsExtended == 1)

        let headline = ResultHeadline(plan: retried, inventory: after)
        #expect(headline.lead == .extendedAlbums(1))
        #expect(headline.detail == .withPhotos(2))
        #expect(headline.undoNote == .general)
    }

    /// The big number counts the photos of the albums the line names: photos that went into an
    /// album found after an interruption ("adopted") are not "in deinen Alben", and an album of
    /// the user's beside one of Albumist's gets the neutral words for both.
    @Test func theBigNumberCountsWhatTheLineNames() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: Self.assets, collections: [mine])
        let made = try await Self.make([ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("mine")),
                                        ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)], in: library)
        var found = made
        let kyotoKey = try Self.albumKey(Self.kyoto.title, in: made)
        found.record?.adoptedKeys.insert(kyotoKey)
        let after = try await library.currentInventory()
        let receipt = PlanReceipt(plan: found, inventory: after)
        #expect(receipt.albumsCreated == 0 && receipt.albumsExtended == 1 && receipt.photosAdded == 5)

        let headline = ResultHeadline(plan: found, inventory: after)
        #expect(headline.lead == .addedPhotos(2), "the adopted album's photos are counted as in the user's album")
        #expect(headline.detail == .inYourAlbums(1))
        #expect(headline.undoNote == .takesOutAddedPhotos(albums: 1))

        // The user's album and one Albumist made, side by side.
        let japan = CollectionSnapshot(id: "japan", title: "Japan", assetIDs: [])
        let earlier = CollectionSnapshot(id: "earlier", title: "Rom", assetIDs: [])
        let both = InMemoryPhotoLibrary(assets: Self.assets, collections: [japan, earlier])
        let mixed = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: .extendExisting("japan")),
                                         ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("earlier"))], in: both)
        let mixedAfter = try await both.currentInventory()
        #expect(ResultHeadline(plan: mixed, inventory: mixedAfter).lead == .addedPhotos(5))
        let neutral = ResultHeadline(plan: mixed, inventory: mixedAfter, albumistAlbums: ["earlier"])
        #expect(neutral.lead == .extendedAlbums(2))
        #expect(neutral.detail == .withPhotos(5))
    }
}
