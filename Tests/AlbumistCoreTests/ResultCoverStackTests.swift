import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The big moment after a run (draft E3, design wave 2): the covers of the new albums lie fanned
/// above "10 neue Alben". Which albums, which photos each one tries, in which order and how many
/// is decided here (`ResultCoverStack`); the app only loads what is sharp on the device and lays
/// it down. Undo, removal and failed steps keep the symbol they always had; so does a run whose
/// albums have no photo that may be shown (sensitive documents, personal suggestions).
@Suite("Result cover stack")
struct ResultCoverStackTests {
    static let new = ProposalDecision.createNew(title: nil, folderPath: nil)

    /// A trip with `count` photos "<id>-1" … "<id>-<count>".
    static func trip(_ id: String, photos count: Int = 3, cover: AssetID? = nil) -> AlbumProposal {
        AlbumProposal(id: AlbumistID(id), kind: .trip, title: "Reise \(id)", folderPath: ["Reisen"],
                      assetIDs: Set((1...count).map { AssetID("\(id)-\($0)") }), coverAssetID: cover)
    }

    static func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    static func run(_ plan: ChangePlan, in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(plan))
    }

    /// The plan for `items` and the same plan after its run.
    static func planAndRun(_ items: [ConfirmedProposal], in library: InMemoryPhotoLibrary) async throws -> (planned: ChangePlan, made: ChangePlan) {
        let plan = OrganizationPlanner().makePlan(from: items, inventory: try await library.currentInventory())
        let made = try await run(plan, in: library)
        #expect(made.status == .completed)
        return (plan, made)
    }

    static func library(_ proposals: [AlbumProposal], extra: Set<AssetID> = [], collections: [CollectionSnapshot] = []) -> InMemoryPhotoLibrary {
        InMemoryPhotoLibrary(assets: proposals.reduce(extra) { $0.union($1.assetIDs) }, collections: collections)
    }

    // MARK: Which albums

    /// New albums come first: a run that made albums and added photos to one of the user's shows
    /// the new ones only ("1 neues Album" above two covers would count two albums).
    @Test func theNewAlbumsComeFirst() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom"), lissabon = Self.trip("lissabon")
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = Self.library([kyoto, rom, lissabon], extra: ["own"], collections: [mine])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                  ConfirmedProposal(proposal: rom, decision: .extendExisting("mine")),
                                                  ConfirmedProposal(proposal: lissabon, decision: Self.new)], in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.albums == .created)
        #expect(stack.cards.count == 2)
        #expect(stack.cards.allSatisfy { $0.id.hasPrefix("planned:") }, "\(stack.cards.map(\.id))")
        // In the order of the plan: Kyoto, then Lisbon.
        #expect(stack.cards.map { $0.candidates.first?.rawValue.components(separatedBy: "-").first } == ["kyoto", "lissabon"])
    }

    /// Nothing made, photos added to albums of the user's: their covers ("12 Fotos in 3 deiner
    /// Alben ergänzt").
    @Test func theUsersAlbumsWhenNothingWasMade() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom")
        let japan = CollectionSnapshot(id: "japan", title: "Japan", assetIDs: ["own1"])
        let italy = CollectionSnapshot(id: "italy", title: "Italien", assetIDs: ["own2"])
        let library = Self.library([kyoto, rom], extra: ["own1", "own2"], collections: [japan, italy])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: .extendExisting("japan")),
                                                  ConfirmedProposal(proposal: rom, decision: .extendExisting("italy"))], in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.albums == .extended)
        #expect(stack.cards.map(\.id) == ["japan", "italy"])
        // Only photos the run added: never the user's own photo of the album.
        #expect(stack.cards.allSatisfy { !$0.candidates.contains("own1") && !$0.candidates.contains("own2") })
    }

    /// One album is one card, with a few photos to try for its cover (the app shows the first one
    /// that is sharp on the device).
    @Test func oneAlbumIsOneCard() async throws {
        let kyoto = Self.trip("kyoto", photos: 16)
        let library = Self.library([kyoto])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.cards.count == 1)
        let candidates = try #require(stack.cards.first?.candidates)
        #expect(candidates.count == ResultCoverStack.candidatesPerCard)
        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.allSatisfy { kyoto.assetIDs.contains($0) })
    }

    /// Ten new albums: eight are tried (an album whose photos are only in iCloud makes room for
    /// the next), five lie on the stack, three at the largest text sizes.
    @Test func atMostFiveCoversLieOnTheStack() async throws {
        let trips = (0..<10).map { Self.trip("t\($0)", photos: 2) }
        let library = Self.library(trips)
        let (_, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.cards.count == ResultCoverStack.tried)
        #expect(ResultCoverStack.limit == 5 && ResultCoverStack.limitAtLargestText == 3)
        var sharp: [String: AssetID] = [:]
        for card in stack.cards { sharp[card.id] = card.candidates.first }
        #expect(stack.shown(sharp: sharp, limit: ResultCoverStack.limit).count == 5)
        #expect(stack.shown(sharp: sharp, limit: ResultCoverStack.limitAtLargestText).count == 3)
        // Cards without a sharp photo are left out; the next ones take their place, in order.
        sharp[stack.cards[0].id] = nil
        sharp[stack.cards[2].id] = nil
        let shown = stack.shown(sharp: sharp, limit: 5)
        #expect(shown.map(\.card) == [stack.cards[1], stack.cards[3], stack.cards[4], stack.cards[5], stack.cards[6]].map(\.id))
    }

    /// Four covers are laid as three: the main cover keeps the middle of the fan (draft E3). Two
    /// stay two.
    @Test func fourCoversAreLaidAsThree() async throws {
        let trips = (0..<4).map { Self.trip("t\($0)", photos: 2) }
        let library = Self.library(trips)
        let (_, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        let stack = ResultCoverStack(plan: made)
        var sharp: [String: AssetID] = [:]
        for card in stack.cards { sharp[card.id] = card.candidates.first }
        #expect(stack.shown(sharp: sharp, limit: 5).map(\.card) == stack.cards.prefix(3).map(\.id))
        sharp[stack.cards[3].id] = nil
        sharp[stack.cards[2].id] = nil
        #expect(stack.shown(sharp: sharp, limit: 5).count == 2)
    }

    // MARK: No stack

    /// No stack, the symbol as before: an undo, a removal, a run with failed steps, a run that
    /// confirmed nothing.
    @Test func undoRemovalAndFailuresKeepTheSymbol() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom")
        let library = Self.library([kyoto, rom])
        let (planned, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        #expect(!ResultCoverStack(plan: made).isEmpty)

        // Undo.
        let tracker = ManagedAlbumTracker()
        let inventory = try await library.currentInventory()
        let states = tracker.record(made, into: [], inventory: inventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: states, current: inventory, earlierUndos: []), in: library)
        #expect(ResultCoverStack(plan: undo).isEmpty)
        #expect(ResultCoverStack(plan: undo, expected: true).isEmpty)

        // Removal from "Alben von Albumist".
        let (_, romMade) = try await Self.planAndRun([ConfirmedProposal(proposal: rom, decision: Self.new)], in: library)
        let romState = try #require(tracker.record(romMade, into: [], inventory: try await library.currentInventory()).first)
        let removal = try await Self.run(tracker.removalPlan(for: romState, current: try await library.currentInventory()), in: library)
        #expect(ResultCoverStack(plan: removal).isEmpty)
        #expect(ResultCoverStack(plan: removal, expected: true).isEmpty)

        // A step failed: "Teilweise fertig" under its symbol.
        var failed = made
        let add = try #require(failed.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } })
        failed.steps[add].state = .failed(reason: "Fotos hat nicht geantwortet.")
        #expect(PlanReceipt(plan: failed, inventory: CollectionInventory()).failedSteps == 1)
        #expect(ResultCoverStack(plan: failed).isEmpty)

        // Nothing confirmed.
        var nothing = planned
        for index in nothing.steps.indices { nothing.steps[index].state = .failed(reason: "") }
        #expect(ResultCoverStack(plan: nothing).isEmpty)
        #expect(ResultCoverStack(plan: nothing).albums == nil)
    }

    // MARK: Skipping the show

    /// The show's counter ends on the photos the receipt counts ("mit 342 Fotos"), also when the
    /// library did not confirm a step: skipping the show or watching it to the end leaves the same
    /// numbers. `appliedAssets` counted the planned photos of such a step.
    @Test func theShowEndsOnTheReceiptsCount() async throws {
        let kyoto = Self.trip("kyoto", photos: 4), rom = Self.trip("rom", photos: 2)
        let library = Self.library([kyoto, rom])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                  ConfirmedProposal(proposal: rom, decision: Self.new)], in: library)
        let receipt = PlanReceipt(plan: made, inventory: CollectionInventory())
        #expect(made.confirmedAddedMedia.count == receipt.photosAdded)
        #expect(receipt.photosAdded == 6)

        // A step whose outcome the library did not confirm.
        var unclear = made
        let add = try #require(unclear.steps.lastIndex { if case .addAssets = $0.operation { true } else { false } })
        let step = unclear.steps[add].id
        unclear.record?.unverified.insert(step)
        unclear.record?.media[step] = nil
        let unclearReceipt = PlanReceipt(plan: unclear, inventory: CollectionInventory())
        #expect(unclear.confirmedAddedMedia.count == unclearReceipt.photosAdded)
        #expect(unclear.appliedAssets.count > unclearReceipt.photosAdded, "the old count already agreed")

        // A plan of an older version, without a journal: its succeeded steps.
        var older = made
        older.record = nil
        #expect(older.confirmedAddedMedia.count == PlanReceipt(plan: older, inventory: CollectionInventory()).photosAdded)
    }
}
