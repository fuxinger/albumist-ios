import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// What the result after a run says (design 7.1, N-07): the counts of the receipt, big "10 neue
/// Alben" and small "mit 342 Fotos"; a removal called a removal ("1 Album entfernt", never
/// "0 Fotos einsortiert"); the way to the new albums only when there are new albums; and what
/// "Rückgängig machen" below it does.
@Suite("Result headline")
struct ResultHeadlineTests {
    static let kyoto = AlbumProposal(id: SortlyID("kyoto"), kind: .trip, title: "Kyoto, Oktober 2024", folderPath: ["Reisen"],
                                     assetIDs: ["k1", "k2", "k3"])
    static let rom = AlbumProposal(id: SortlyID("rom"), kind: .trip, title: "Rom, Juni 2022", folderPath: ["Reisen"],
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

    /// Photos added to an album of the user's: "1 Album ergänzt", "mit 2 Fotos", and nothing
    /// about new albums.
    @Test func anAlbumOfTheUsersGetsPhotos() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: Self.assets, collections: [mine])
        let made = try await Self.make([ConfirmedProposal(proposal: Self.rom, decision: .extendExisting("mine"))], in: library)
        let after = try await library.currentInventory()
        #expect(after["mine"]?.assetIDs == ["own", "r1", "r2"])

        let headline = ResultHeadline(plan: made, inventory: after)
        #expect(headline.kind == .created)
        #expect(headline.lead == .extendedAlbums(1))
        #expect(headline.detail == .withPhotos(2))
        #expect(!headline.showsWhereNewAlbumsAre)
        #expect(headline.undoNote == .takesOutAddedPhotos(albums: 1))
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

    // MARK: Undo

    /// The undo of new albums says it removed them again; the undo of a removal says that what
    /// was removed is back. An undo has no "Rückgängig machen" of its own.
    @Test func anUndoSaysWhatItDid() async throws {
        let library = InMemoryPhotoLibrary(assets: Self.assets)
        let tracker = ManagedAlbumTracker()
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)], in: library)
        let madeInventory = try await library.currentInventory()
        let madeStates = tracker.record(made, into: [], inventory: madeInventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: madeStates, current: madeInventory, earlierUndos: []),
                                      in: library)
        let removedAgain = ResultHeadline(plan: undo, inventory: try await library.currentInventory())
        #expect(removedAgain.kind == .undone)
        #expect(removedAgain.lead == .undone)
        #expect(removedAgain.detail == .undoRemoved)
        #expect(!removedAgain.showsWhereNewAlbumsAre)
        #expect(removedAgain.undoNote == nil)

        // "Entfernen" on another album, then "Rückgängig machen" on that removal.
        let rom = try await Self.make([ConfirmedProposal(proposal: Self.rom, decision: Self.new)], in: library)
        var states = tracker.record(rom, into: [], inventory: try await library.currentInventory())
        let state = try #require(states.first)
        let removal = try await Self.run(tracker.removalPlan(for: state, current: try await library.currentInventory()), in: library)
        let removedInventory = try await library.currentInventory()
        states = tracker.record(removal, into: states, inventory: removedInventory)
        let back = try await Self.run(UndoPlanner().undoPlan(for: removal, albums: states, current: removedInventory, earlierUndos: []),
                                      in: library)
        let after = try await library.currentInventory()
        #expect(after.albums.contains { $0.title == Self.rom.title && Set($0.assetIDs) == ["r1", "r2"] })
        let restored = ResultHeadline(plan: back, inventory: after)
        #expect(restored.kind == .undone)
        #expect(restored.lead == .undone)
        #expect(restored.detail == .undoRestored)
        #expect(restored.undoNote == nil)
    }

    // MARK: Nothing to count

    /// Steps the library never confirmed count nothing: no count at all, never "0 Fotos
    /// einsortiert", and no way to new albums that are not there.
    @Test func nothingConfirmedIsNotCountedAsZero() {
        var plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)],
                                                  inventory: CollectionInventory())
        for index in plan.steps.indices { plan.steps[index].state = .failed(reason: "Fotos hat nicht geantwortet.") }
        let headline = ResultHeadline(plan: plan)
        #expect(headline.kind == .created)
        #expect(headline.lead == .plain)
        #expect(headline.detail == nil)
        #expect(!headline.showsWhereNewAlbumsAre)
    }

    // MARK: The App says it (the App does not build on Linux: its code is read)

    static let view = "App/Sortly/Views/PlanReviewView.swift"

    static func resultCard() throws -> (body: String, file: String) {
        let file = AppSource.code(try AppSource.read(Self.view), keepStrings: true)
        let body = try #require(AppSource.body(of: ["struct ResultCard", "var body: some View"], in: file))
        return (body, file)
    }

    /// The result card counts with the receipt and the headline, not with the summary that said
    /// "0 Fotos einsortiert" after a removal.
    @Test func theResultCardCountsAsTheReceipt() throws {
        let (body, _) = try Self.resultCard()
        #expect(body.contains("ResultHeadline("), "the result card does not use ResultHeadline")
        #expect(body.contains("PlanReceipt(plan:"), "the result card does not count with the receipt")
        for old in ["Counted.resultLine(", "appliedSummary"] {
            #expect(!body.contains(old), "the result card still uses \(old)")
        }
    }

    /// The way to the new albums comes only with new albums: its sentences are in one function,
    /// which says nothing unless the headline says so, and the card's old sentence is gone.
    @Test func theWayToNewAlbumsOnlyWithNewAlbums() throws {
        let (body, file) = try Self.resultCard()
        #expect(!file.contains("Deine neuen Alben findest du"), "the old sentence about new albums is still there")
        let words = try #require(AppSource.body(of: "static func whereNewAlbums(", in: file), "no ResultText.whereNewAlbums")
        #expect(words.contains("showsWhereNewAlbumsAre"), "whereNewAlbums does not ask the headline")
        #expect(words.contains("Sammlungen › Alben"))
        // Every sentence with the way to the albums is in that function.
        let ways = file.components(separatedBy: "Sammlungen › Alben").count - 1
        let inWords = words.components(separatedBy: "Sammlungen › Alben").count - 1
        #expect(ways == inWords, "a sentence about where new albums are outside whereNewAlbums")
        #expect(AppSource.calls(of: "ResultText.whereNewAlbums(", in: body).count == 1)
    }

    /// A removal is called one on the card, and "Rückgängig machen" says what it does for each
    /// kind of plan; its question too.
    @Test func theCardNamesARemovalAndWhatUndoDoes() throws {
        let (body, file) = try Self.resultCard()
        for words in ["Album entfernt", "Alben entfernt", "Fotos herausgenommen", "Die Fotos bleiben in deiner Mediathek.",
                      "Legt die %lld Alben mit denselben Fotos wieder an.", "Legt die herausgenommenen Fotos wieder zurück.",
                      "Entfernt die %lld neuen Alben. Deine Fotos bleiben."] {
            let literal = words.replacingOccurrences(of: "%lld", with: #"\(count)"#)
            #expect(file.contains("\"\(words)\"") || file.contains("\"\(literal)\""), "PlanReviewView.swift does not say \(words)")
        }
        #expect(body.contains("ResultText.undoNote("), "the result card does not say what Rückgängig machen does")
        #expect(body.contains("ResultText.undoQuestion("), "the undo question does not follow the kind of plan")
    }
}
