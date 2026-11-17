import Foundation
import Testing
@testable import SortlyCore

/// The plan preview reads `PlanReviewFacts`, made once off the main thread, instead of working
/// everything out in its body. The facts must say exactly what the body said before.
@Suite("Plan preview facts")
struct PlanReviewFactsTests {
    let planner = OrganizationPlanner(rootFolderTitle: "Albumist", chunkSize: 5)

    private func plans() -> [(ChangePlan, CollectionInventory, [SortlyID])] {
        let italy = AlbumProposal(id: SortlyID("it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"], assetIDs: ids("a", 0..<12))
        let trip = AlbumProposal(id: SortlyID("t"), kind: .trip, title: "Rom · 10.05.–14.05.2024", folderPath: ["Reisen", "2024"], assetIDs: ids("a", 0..<8))
        let summer = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Gardasee", assetIDs: ids("b", 0..<10))
        let existing = CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ids("b", 0..<6))
        let inventory = CollectionInventory([existing])
        let mixed = planner.makePlan(from: [
            ConfirmedProposal(proposal: italy, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: trip, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: summer, decision: .extendExisting("sommer")),
        ], inventory: inventory)
        // A manual album of two photos (the plan of "Zu Album hinzufügen").
        let manual = planner.makePlan(from: [
            ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("m"), kind: .rule, title: "Testalbum", assetIDs: ids("c", 0..<2), reliability: .certain),
                              decision: .createNew(title: "Testalbum", folderPath: nil)),
        ], inventory: CollectionInventory([]))
        var withConflicts = mixed
        withConflicts.conflicts = [.albumMissing("sommer"), .albumChangedSincePreview("weg"), .titleExistsInFolder(title: "Italien", existing: "sommer"),
                                   .assetsUnavailable(count: 3)]
        var empty = manual
        empty.steps = []
        return [(mixed, inventory, [SortlyID("s"), SortlyID("it")]), (manual, CollectionInventory([]), []),
                (withConflicts, inventory, []), (empty, CollectionInventory([]), [])]
    }

    @Test func factsSayWhatTheBodyWorkedOutBefore() {
        for (plan, inventory, order) in plans() {
            let facts = PlanReviewFacts(plan: plan, inventory: inventory, order: order)
            #expect(facts.planID == plan.id)
            #expect(facts.summary == plan.summary)
            #expect(facts.albums == plan.albumPreview(inventory: inventory, order: order))
            #expect(facts.conflicts.map(\.conflict) == plan.conflicts)
            #expect(facts.isBlocking == plan.conflicts.contains(where: \.isBlocking))
            #expect(facts.freeAlbumUse == plan.freeAlbumUse(applied: false))
            #expect(facts.hasNoSteps == plan.steps.isEmpty)
        }
    }

    @Test func conflictsCarryTheAlbumNames() {
        let (plan, inventory, _) = plans()[2]
        let conflicts = PlanReviewFacts(plan: plan, inventory: inventory).conflicts
        #expect(conflicts.map(\.albumTitle) == ["Sommer", nil, nil, nil])
        #expect(PlanReviewFacts(plan: plan, inventory: inventory).isBlocking)
    }

    @Test func filledAlbumsMergeChunksInPlanOrder() {
        let (plan, inventory, _) = plans()[0]
        let albums = plan.filledAlbums(inventory: inventory)
        #expect(albums.map(\.title) == plan.albumPreview(inventory: inventory).map(\.title))
        let italy = albums.first { $0.title == "Italien" }
        #expect(italy?.assets.count == 12)   // three chunks of at most 5
        #expect(Set(italy?.assets ?? []) == ids("a", 0..<12))
        // The album is done with its last chunk.
        let lastItaly = plan.steps.lastIndex { step in
            if case .addAssets(let ref, _) = step.operation, case .planned = ref { return step.sourceID == SortlyID("it") }
            return false
        }
        #expect(italy?.lastStep == lastItaly)
        // An existing album keeps its own name; only the photos it lacks are added.
        let sommer = albums.first { $0.title == "Sommer" }
        #expect(sommer.map { Set($0.assets) } == ids("b", 6..<10))
        // Without the album in the inventory its name is not known.
        #expect(plan.filledAlbums(inventory: CollectionInventory([])).contains { $0.title == nil })
    }

    @Test func aManualAlbumIsOneAlbumWithItsPhotos() {
        let (plan, inventory, _) = plans()[1]
        let facts = PlanReviewFacts(plan: plan, inventory: inventory)
        #expect(facts.filledAlbums.count == 1)
        #expect(facts.filledAlbums.first?.title == "Testalbum")
        #expect(facts.filledAlbums.first?.assets.count == 2)
        #expect(facts.albums.map(\.title) == ["Testalbum"])
        #expect(facts.summary.newAlbums == 1)
        #expect(!facts.isBlocking)
    }
}
