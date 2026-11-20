import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Second review of the plan safety work (6b34b20): album records follow run order, and a
/// folder alone carries out no suggestion.
@Suite("Plan safety: record order, a folder alone")
struct PlanRecordOrderTests {
    let h = InterruptedPlanUndoTests()

    /// P makes "Rom", R adds photos to it; with records stored in run order (the app stores
    /// waiting results before every run), undoing R and then P leaves no album behind.
    @Test func undoingTwoPlansOnOneAlbumLeavesNothingWhenRecordsFollowRunOrder() async throws {
        let library = h.library()
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let tracker = ManagedAlbumTracker()
        let p = try await executor.execute(h.confirmed(h.planner.makePlan(from: [h.newAlbum("r", "Rom", ids("a", 0..<10))],
                                                                         inventory: try await library.currentInventory())))
        let rome = try #require(try await library.currentInventory().albums.first { $0.title == "Rom" }?.id)
        var states = tracker.record(p, into: [], inventory: try await library.currentInventory())
        let extend = ConfirmedProposal(proposal: AlbumProposal(id: AlbumistID("x"), kind: .rule, title: "Rom", folderPath: [], assetIDs: ids("a", 20..<25)),
                                       decision: .extendExisting(rome))
        let r = try await executor.execute(h.confirmed(h.planner.makePlan(from: [extend], inventory: try await library.currentInventory())))
        #expect(r.status == .completed)
        states = tracker.record(r, into: states, inventory: try await library.currentInventory())
        states = tracker.reconcile(states, with: try await library.currentInventory()).updatedStates
        let undoR = try await executor.execute(h.confirmed(UndoPlanner().undoPlan(for: r, current: try await library.currentInventory(), owned: h.owned(states))))
        states = tracker.record(undoR, into: states, inventory: try await library.currentInventory())
        states = tracker.reconcile(states, with: try await library.currentInventory()).updatedStates
        _ = try await executor.execute(h.confirmed(UndoPlanner().undoPlan(for: p, current: try await library.currentInventory(), owned: h.owned(states))))
        let left = try await library.currentInventory()[rome]
        #expect(left == nil, "Rom left behind with \(left?.assetIDs.count ?? 0) photos")
    }

    /// Cut off right after the folder "Reisen" was made: no album of any suggestion exists,
    /// so every suggestion stays selected.
    @Test func aFolderAloneCarriesOutNoSuggestion() async throws {
        let library = h.library()
        var plan = h.parisAndRome(try await library.currentInventory())
        let folder = try #require(plan.steps.firstIndex { if case .createFolder = $0.operation { true } else { false } })
        guard case .createFolder(let key, _, _) = plan.steps[folder].operation else { return }
        plan.steps[folder].state = .succeeded(createdID: "made-folder", verifiedAt: Date())
        plan.resolvedKeys[key] = "made-folder"
        let kept = plan.keptAsIs(current: try await library.currentInventory())
        #expect(kept.appliedSources.isEmpty)
    }
}
