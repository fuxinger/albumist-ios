import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Review P2-09: two plans fill the same album. A plan only wrote down what it added itself,
/// so taking back the older one took out the photos the newer one wanted there too, and the
/// newer one's receipt still said "done". Decision Fuchs 26.11.2026: an undo takes out only
/// photos no other change of the user's still wants; the later undo of that change takes them.
@Suite("Review P2-09: two plans, one album")
struct TwoPlansOneAlbumTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)
    let allAssets: Set<AssetID> = ids("a", 0..<100)

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    func newAlbum(_ id: String, _ title: String, _ assets: Set<AssetID>) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: AlbumistID(id), kind: .trip, title: title, folderPath: ["Reisen"], assetIDs: assets),
                          decision: .createNew(title: nil, folderPath: nil))
    }

    func extend(_ id: String, _ album: CollectionID, _ assets: Set<AssetID>) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: AlbumistID(id), kind: .trip, title: "Rom", folderPath: ["Reisen"], assetIDs: assets),
                          decision: .extendExisting(album))
    }

    /// The app's way: Albumist's album records after each run, and every finished plan.
    final class World {
        let library: InMemoryPhotoLibrary
        let executor: ChangeExecutor
        var states: [ManagedAlbumState] = []
        var plans: [ChangePlan] = []
        var undone: Set<AlbumistID> = []

        init(library: InMemoryPhotoLibrary) {
            self.library = library
            executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        }

        func run(_ plan: ChangePlan) async throws -> ChangePlan {
            var p = plan
            p.confirmedAt = Date()
            p.status = .confirmed
            let done = try await executor.execute(p)
            states = ManagedAlbumTracker().record(done, into: states, inventory: try await library.currentInventory())
            plans.append(done)
            if let target = done.reverts, done.status == .completed { undone.insert(target) }
            return done
        }

        func undoPlan(_ plan: ChangePlan) async throws -> ChangePlan {
            let keep = UndoPlanner.keptForOthers(undoing: plan, plans: plans, undone: undone)
            return UndoPlanner().undoPlan(for: plan, albums: states, current: try await library.currentInventory(),
                                          keptForOthers: keep, earlierUndos: [])
        }

        func undo(_ plan: ChangePlan) async throws -> ChangePlan { try await run(undoPlan(plan)) }

        func members(_ album: CollectionID) async throws -> Set<AssetID>? { try await library.currentInventory()[album]?.assetIDs }
    }

    /// P makes "Rom" with 10 photos; Q, a later suggestion, wants those 10 and 5 more in "Rom"
    /// (it adds only the 5). Taking back P leaves all 15: Q still wants them. Taking back Q
    /// then empties "Rom", Albumist's own album, and it goes. Before: P's undo took its 10
    /// out, and "Rom" kept only Q's 5.
    @Test func undoingTheOlderPlanKeepsWhatTheNewerOneWants() async throws {
        let world = World(library: InMemoryPhotoLibrary(assets: allAssets))
        let p = try await world.run(planner.makePlan(from: [newAlbum("p", "Rom", ids("a", 0..<10))], inventory: try await world.library.currentInventory()))
        let rome = try #require(world.states.first { $0.lastKnownTitle == "Rom" }).albumID
        let q = try await world.run(planner.makePlan(from: [extend("q", rome, ids("a", 0..<15))], inventory: try await world.library.currentInventory()))
        #expect(try await world.members(rome) == ids("a", 0..<15))

        let undoP = try await world.undoPlan(p)
        #expect(!undoP.deletesCollections)
        #expect(undoP.notes.contains(.keptForOtherPlans(album: rome, count: 10)))
        _ = try await world.run(undoP)
        #expect(try await world.members(rome) == ids("a", 0..<15))

        let undoQ = try await world.undoPlan(q)
        #expect(undoQ.steps.contains { $0.operation == .deleteCollection(rome, title: "Rom") })
        _ = try await world.run(undoQ)
        #expect(try await world.members(rome) == nil)
        #expect(await world.library.assets == allAssets)
    }

    /// Q wants only part of P's photos: the others leave with P's undo.
    @Test func onlyThePhotosTheOtherPlanWantsStay() async throws {
        let world = World(library: InMemoryPhotoLibrary(assets: allAssets))
        let p = try await world.run(planner.makePlan(from: [newAlbum("p", "Rom", ids("a", 0..<10))], inventory: try await world.library.currentInventory()))
        let rome = try #require(world.states.first { $0.lastKnownTitle == "Rom" }).albumID
        let q = try await world.run(planner.makePlan(from: [extend("q", rome, ids("a", 5..<15))], inventory: try await world.library.currentInventory()))
        _ = try await world.undo(p)
        #expect(try await world.members(rome) == ids("a", 5..<15))
        _ = try await world.undo(q)
        #expect(try await world.members(rome) == nil)
    }

    /// The newer plan first: only its own photos leave, P's stay for P; then P's undo deletes
    /// "Rom" as before.
    @Test func undoingTheNewerPlanFirstLeavesTheOlderOnesPhotos() async throws {
        let world = World(library: InMemoryPhotoLibrary(assets: allAssets))
        let p = try await world.run(planner.makePlan(from: [newAlbum("p", "Rom", ids("a", 0..<10))], inventory: try await world.library.currentInventory()))
        let rome = try #require(world.states.first { $0.lastKnownTitle == "Rom" }).albumID
        let q = try await world.run(planner.makePlan(from: [extend("q", rome, ids("a", 0..<15))], inventory: try await world.library.currentInventory()))
        _ = try await world.undo(q)
        #expect(try await world.members(rome) == ids("a", 0..<10))
        _ = try await world.undo(p)
        #expect(try await world.members(rome) == nil)
    }

    /// The user's own album, extended by two plans: each undo takes out only what no other
    /// plan wants; the user's photo always stays, and so does the album.
    @Test func theUsersAlbumKeepsTheirPhotoAndWhatAnotherPlanWants() async throws {
        let family = CollectionSnapshot(id: "familie", title: "Familie", assetIDs: ["a-90"])
        let world = World(library: InMemoryPhotoLibrary(assets: allAssets, collections: [family]))
        let p = try await world.run(planner.makePlan(from: [extend("p", "familie", ids("a", 0..<4))], inventory: try await world.library.currentInventory()))
        let q = try await world.run(planner.makePlan(from: [extend("q", "familie", ids("a", 2..<6))], inventory: try await world.library.currentInventory()))
        #expect(try await world.members("familie") == ids("a", 0..<6).union(["a-90"]))
        _ = try await world.undo(p)
        #expect(try await world.members("familie") == ids("a", 2..<6).union(["a-90"]))
        _ = try await world.undo(q)
        #expect(try await world.members("familie") == ["a-90"])
    }

    /// A plan already taken back wants nothing any more; nor does the undo of the same change.
    @Test func aPlanTakenBackKeepsNothing() async throws {
        let world = World(library: InMemoryPhotoLibrary(assets: allAssets))
        let p = try await world.run(planner.makePlan(from: [newAlbum("p", "Rom", ids("a", 0..<10))], inventory: try await world.library.currentInventory()))
        let rome = try #require(world.states.first { $0.lastKnownTitle == "Rom" }).albumID
        let q = try await world.run(planner.makePlan(from: [extend("q", rome, ids("a", 0..<15))], inventory: try await world.library.currentInventory()))
        _ = try await world.undo(q)
        #expect(UndoPlanner.keptForOthers(undoing: p, plans: world.plans, undone: world.undone).isEmpty)
        // A retry of P is the same change: it keeps nothing for P either.
        var retry = q
        retry.id = AlbumistID("retry")
        retry.retries = p.id
        #expect(UndoPlanner.keptForOthers(undoing: p, plans: [p, retry], undone: []).isEmpty)
        #expect(!UndoPlanner.keptForOthers(undoing: p, plans: [p, q], undone: []).isEmpty)
    }

    /// Plans of older versions wrote down no wishes: what they added stands for them, and the
    /// undo works as before.
    @Test func plansWithoutWishesWorkAsBefore() async throws {
        let world = World(library: InMemoryPhotoLibrary(assets: allAssets))
        var p = try await world.run(planner.makePlan(from: [newAlbum("p", "Rom", ids("a", 0..<10))], inventory: try await world.library.currentInventory()))
        let rome = try #require(world.states.first { $0.lastKnownTitle == "Rom" }).albumID
        var q = try await world.run(planner.makePlan(from: [extend("q", rome, ids("a", 0..<15))], inventory: try await world.library.currentInventory()))
        p.wanted = nil
        q.wanted = nil
        world.plans = [p, q]
        #expect(q.wantedMembers() == [rome: ids("a", 10..<15)])
        _ = try await world.undo(p)
        #expect(try await world.members(rome) == ids("a", 10..<15))
    }

    /// The plan writes down every photo each suggestion wants, also those already there; a
    /// plan stored without them still reads.
    @Test func thePlanRecordsWhatItWantsAndOldPlansStillRead() throws {
        let rome = CollectionSnapshot(id: "rom", title: "Rom", assetIDs: ids("a", 0..<10))
        let plan = planner.makePlan(from: [extend("q", "rom", ids("a", 0..<15))], inventory: CollectionInventory([rome]))
        #expect(plan.wanted == [AlbumWish(album: .existing("rom"), assets: ids("a", 0..<15).sorted())])
        #expect(plan.steps.flatMap { step -> [AssetID] in
            if case .addAssets(_, let assets) = step.operation { return assets }
            return []
        } == ids("a", 10..<15).sorted())
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        old["wanted"] = nil
        let decoded = try JSONDecoder().decode(ChangePlan.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.wanted == nil)
    }
}
