import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The receipt's "Album-Zuordnungen" (`PlanReceipt.assignmentsAdded`, `PlanReceiptView`): how many
/// album memberships a plan really added. A photo sorted into two albums is one photo
/// ("Fotos einsortiert") and two memberships; the receipt shows the row only when the two
/// numbers differ. It had no test of its own (review of 18.11.2026, G5-05).
@Suite("Change receipt: album memberships")
struct PlanReceiptAssignmentTests {
    let planner = OrganizationPlanner(rootFolderTitle: "Albumist")

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    @Test func aPhotoInTwoAlbumsIsOnePhotoAndTwoMemberships() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["a", "b", "c", "s1"],
                                       collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["s1"])])
        // "a" goes into all three albums, "b" into two, "c" into one; "gone" is no longer in the
        // library and adds nothing.
        let italy = AlbumProposal(id: SortlyID("italien"), kind: .trip, title: "Italien", folderPath: ["Reisen"],
                                  assetIDs: ["a", "b", "gone"])
        let rome = AlbumProposal(id: SortlyID("rom"), kind: .trip, title: "Rom", folderPath: ["Reisen"], assetIDs: ["a", "b"])
        let summer = AlbumProposal(id: SortlyID("sommer"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["a", "c"])
        let plan = confirmed(planner.makePlan(from: [
            ConfirmedProposal(proposal: italy, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: rome, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: summer, decision: .extendExisting("sommer")),
        ], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let receipt = PlanReceipt(plan: result, inventory: try await lib.currentInventory())

        #expect(receipt.photosAdded == 3)
        #expect(receipt.assignmentsAdded == 6)
        // The sum of the albums' lines, as the library has them now.
        #expect(receipt.assignmentsAdded == receipt.albums.reduce(0) { $0 + $1.added })
        let inventory = try await lib.currentInventory()
        let memberships = inventory.albums.filter { ["Italien", "Rom", "Sommer"].contains($0.title) }
            .reduce(0) { $0 + $1.assetIDs.count }
        #expect(receipt.assignmentsAdded == memberships - 1)   // minus the user's own "s1" in "Sommer"
    }

    @Test func everyPhotoInOneAlbumGivesEqualNumbers() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["a", "b", "c"])
        let italy = AlbumProposal(id: SortlyID("italien"), kind: .trip, title: "Italien", folderPath: [], assetIDs: ["a", "b"])
        let rome = AlbumProposal(id: SortlyID("rom"), kind: .trip, title: "Rom", folderPath: [], assetIDs: ["c"])
        let plan = confirmed(planner.makePlan(from: [
            ConfirmedProposal(proposal: italy, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: rome, decision: .createNew(title: nil, folderPath: nil)),
        ], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let receipt = PlanReceipt(plan: result, inventory: try await lib.currentInventory())

        // Equal numbers: the receipt leaves the row out.
        #expect(receipt.photosAdded == 3)
        #expect(receipt.assignmentsAdded == 3)
    }

    @Test func onlyConfirmedMembershipsCount() {
        // s0 confirmed two photos (the journal), s1 failed, s2's outcome the library never
        // confirmed, s3 succeeded in a version without a journal for it (its planned photos).
        var record = ExecutionRecord()
        record.media["s0"] = ["x", "y"]
        record.media["s2"] = ["x", "z"]
        record.unverified = ["s2"]
        let plan = ChangePlan(id: SortlyID("p"), createdAt: Date(), confirmedAt: Date(), status: .completedWithErrors, baseline: [:],
                              baselineCollectionIDs: [],
                              steps: [
                                  PlanStep(id: "s0", operation: .addAssets(album: .existing("a"), assets: ["x", "y", "w"]), sourceID: nil,
                                           state: .succeeded(createdID: nil, verifiedAt: Date())),
                                  PlanStep(id: "s1", operation: .addAssets(album: .existing("b"), assets: ["x"]), sourceID: nil,
                                           state: .failed(reason: "Album nicht bearbeitbar")),
                                  PlanStep(id: "s2", operation: .addAssets(album: .existing("b"), assets: ["x", "z"]), sourceID: nil,
                                           state: .running(startedAt: Date())),
                                  PlanStep(id: "s3", operation: .addAssets(album: .existing("c"), assets: ["x"]), sourceID: nil,
                                           state: .succeeded(createdID: nil, verifiedAt: Date())),
                              ],
                              conflicts: [], notes: [], resolvedKeys: [:], record: record)
        let receipt = PlanReceipt(plan: plan, inventory: CollectionInventory([
            CollectionSnapshot(id: "a", title: "Familie"), CollectionSnapshot(id: "b", title: "Urlaub"),
            CollectionSnapshot(id: "c", title: "Garten"),
        ]))
        #expect(receipt.assignmentsAdded == 3)   // x and y in "Familie", x in "Garten"
        #expect(receipt.photosAdded == 2)
    }

    @Test func undoAddsNoMemberships() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["a", "b"])
        let italy = AlbumProposal(id: SortlyID("italien"), kind: .trip, title: "Italien", folderPath: [], assetIDs: ["a", "b"])
        let executor = ChangeExecutor(library: lib, store: InMemoryPlanStore())
        let result = try await executor.execute(confirmed(planner.makePlan(from: [
            ConfirmedProposal(proposal: italy, decision: .createNew(title: nil, folderPath: nil)),
        ], inventory: try await lib.currentInventory())))
        let undo = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: result, current: try await lib.currentInventory())))
        let receipt = PlanReceipt(plan: undo, inventory: try await lib.currentInventory())

        #expect(receipt.isUndo)
        #expect(receipt.assignmentsAdded == 0)
        #expect(receipt.photosAdded == 0)
    }
}
