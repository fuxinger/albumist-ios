import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// "Rest anlegen" after an interruption fills the albums the interrupted plan created itself
/// (UI run 43949880264: DeviceConditionUITests test07 left "Testalbum Vollendet" with 0 photos).
/// A Photos change is all or nothing, so in such an album "nothing of the step arrived" means
/// the request never went through; the user's own albums still get nothing without a preview
/// (audit 2, 1.1, 1.2; docs/DECISIONS.md).
@Suite("Resume fills the plan's own albums")
struct ResumeFillTests {
    private func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan; p.confirmedAt = Date(); p.status = .confirmed; return p
    }
    private func running(_ state: StepState) -> Bool { if case .running = state { return true }; return false }

    /// A new album "Reise" with x and y; with `extendOwn`, also z into the user's album "sommer"
    /// (which holds the user's own photo "o").
    private func setup(extendOwn: Bool = false) async throws -> (InMemoryPhotoLibrary, ChangePlan) {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y", "z", "o", "u"],
                                       collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["o"])])
        var proposals = [ConfirmedProposal(
            proposal: AlbumProposal(id: AlbumistID("reise"), kind: .trip, title: "Reise", folderPath: [], assetIDs: ["x", "y"]),
            decision: .createNew(title: nil, folderPath: nil))]
        if extendOwn {
            proposals.append(ConfirmedProposal(
                proposal: AlbumProposal(id: AlbumistID("sommer-src"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["z"]),
                decision: .extendExisting("sommer")))
        }
        let plan = confirmed(OrganizationPlanner().makePlan(from: proposals, inventory: try await lib.currentInventory()))
        return (lib, plan)
    }

    /// The index of the add step into the new album.
    private func newAlbumAdd(_ plan: ChangePlan) throws -> Int {
        try #require(plan.steps.firstIndex { if case .addAssets(.planned, _) = $0.operation { true } else { false } })
    }

    /// Runs the plan until the app "stops" in step `index` (at its library write, before or
    /// after Photos applied it), and returns the journal the next launch finds: the last one
    /// saved while that step was running (the executor itself goes on after a simulated crash;
    /// the app would not).
    private func interrupt(_ plan: ChangePlan, _ lib: InMemoryPhotoLibrary, _ store: InMemoryPlanStore,
                           step index: Int, afterApplying: Bool) async throws -> ChangePlan {
        let writesBefore = plan.steps[..<index].filter { !$0.state.isFinished }.count
        await lib.setFailAfterWrites(writesBefore, afterApplying: afterApplying)
        _ = try? await ChangeExecutor(library: lib, store: store).execute(plan)
        await lib.setFailAfterWrites(nil)
        let journal = try #require(await store.saved.last { running($0.steps[index].state) })
        // What the app had not reached yet is still open in that journal.
        #expect(journal.steps[(index + 1)...].allSatisfy { $0.state == .pending || $0.state.isFinished })
        return journal
    }

    private func newAlbum(_ lib: InMemoryPhotoLibrary) async throws -> CollectionSnapshot {
        try #require(try await lib.currentInventory().albums.first { $0.title == "Reise" })
    }

    /// The case of test07: the album was made, the add request never reached Photos.
    @Test func planCreatedAlbumGetsItsPhotos() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let add = try newAlbumAdd(plan)
        let crashed = try await interrupt(plan, lib, store, step: add, afterApplying: false)
        #expect(try await newAlbum(lib).assetIDs.isEmpty)

        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed.respecting(OverrideSet()))
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await newAlbum(lib).assetIDs == ["x", "y"])
        #expect(resumed.appliedAssets == ["x", "y"])
        #expect(resumed.record?.unverified.isEmpty == true)
        #expect(PlanReceipt(plan: resumed, inventory: try await lib.currentInventory()).isComplete)
        // Nothing is left for "Fehlendes erneut versuchen".
        #expect(RetryPlanner().retryPlan(for: resumed, current: try await lib.currentInventory()) == nil)
    }

    /// A photo the user ignored (or excluded) after the interruption is not added by "Rest
    /// anlegen", the same as in a run started fresh (second review of resume-fill, D1).
    @Test func photoIgnoredSinceIsNotFilledIn() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let crashed = try await interrupt(plan, lib, store, step: try newAlbumAdd(plan), afterApplying: false)
        let ignored = OverrideSet([UserOverride(scope: .asset("x"), decision: .ignoreAsset)])
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed.respecting(ignored))
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await newAlbum(lib).assetIDs == ["y"])
        #expect(resumed.appliedAssets == ["y"])
    }

    /// Ignoring photos does not change what the user's own album gets on resume: still
    /// nothing without a preview, and the journaled intent is what is checked.
    @Test func ignoredPhotoDoesNotTouchTheUsersAlbumOnResume() async throws {
        let (lib, plan) = try await setup(extendOwn: true)
        let store = InMemoryPlanStore()
        let own = try #require(plan.steps.firstIndex { if case .addAssets(.existing("sommer"), _) = $0.operation { true } else { false } })
        let crashed = try await interrupt(plan, lib, store, step: own, afterApplying: false)
        let ignored = OverrideSet([UserOverride(scope: .asset("z"), decision: .ignoreAsset)])
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed.respecting(ignored))
        #expect(try await lib.currentInventory()["sommer"]?.assetIDs == ["o"])
        #expect(resumed.steps[own].state == .failed(reason: StepState.unclearReason))
    }

    /// The user's own album gets nothing without a preview, while the plan's own album next to
    /// it is filled in the same resume.
    @Test func userAlbumUntouched() async throws {
        let (lib, plan) = try await setup(extendOwn: true)
        let store = InMemoryPlanStore()
        let own = try #require(plan.steps.firstIndex { if case .addAssets(.existing("sommer"), _) = $0.operation { true } else { false } })
        let add = try newAlbumAdd(plan)
        let crashed = try await interrupt(plan, lib, store, step: own, afterApplying: false)

        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed.respecting(OverrideSet()))
        let inv = try await lib.currentInventory()
        #expect(inv["sommer"]?.assetIDs == ["o"])
        #expect(resumed.steps[own].state == .failed(reason: StepState.unclearReason))
        #expect(resumed.steps[add].state.isFinished)
        if own < add {
            // The new album's step had not started yet: it runs normally.
            #expect(try await newAlbum(lib).assetIDs == ["x", "y"])
        }
        // z only after the user confirms the preview.
        let retry = try #require(RetryPlanner().retryPlan(for: resumed, current: inv))
        #expect(retry.steps.map(\.operation) == [.addAssets(album: .existing("sommer"), assets: ["z"])])
        #expect(retry.confirmedAt == nil)
    }

    /// The same with the plan's own add interrupted: it is filled, the user's album is not
    /// touched by the resume (its step had not started, or it ran normally once).
    @Test func userAlbumUntouchedWhenTheNewAlbumWasInterrupted() async throws {
        let (lib, plan) = try await setup(extendOwn: true)
        let store = InMemoryPlanStore()
        let add = try newAlbumAdd(plan)
        let crashed = try await interrupt(plan, lib, store, step: add, afterApplying: false)
        let before = try await lib.currentInventory()["sommer"]?.assetIDs
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed.respecting(OverrideSet()))
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await newAlbum(lib).assetIDs == ["x", "y"])
        // The user's album only got what the plan said for it, at most once.
        let sommer = try #require(try await lib.currentInventory()["sommer"]?.assetIDs)
        #expect(sommer == ["o", "z"])
        #expect(before == ["o"] || before == ["o", "z"])
    }

    /// Interrupted again while "Rest anlegen" adds (this time the photos reached Photos), then
    /// resumed once more: the album holds each photo once, and the last resume writes nothing.
    @Test func secondInterruptionThenResume() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let add = try newAlbumAdd(plan)
        let first = try await interrupt(plan, lib, store, step: add, afterApplying: false)

        let second = try await interrupt(first.respecting(OverrideSet()), lib, store, step: add, afterApplying: true)
        #expect(try await newAlbum(lib).assetIDs == ["x", "y"])
        #expect(second.record?.unverified.contains(second.steps[add].id) == true)

        // Any write now would fail: the last resume only confirms what arrived.
        await lib.setFailAfterWrites(0)
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(second.respecting(OverrideSet()))
        await lib.setFailAfterWrites(nil)
        #expect(resumed.status == .completed, "\(resumed.steps.map(\.state))")
        #expect(try await newAlbum(lib).assetIDs == ["x", "y"])
        #expect(resumed.appliedAssets == ["x", "y"])
        #expect(try await lib.currentInventory().albums.filter { $0.title == "Reise" }.count == 1)
    }

    /// Interrupted twice before the request reached Photos: the third run still fills it.
    @Test func secondInterruptionBeforeTheRequestThenResume() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let add = try newAlbumAdd(plan)
        let first = try await interrupt(plan, lib, store, step: add, afterApplying: false)
        let second = try await interrupt(first.respecting(OverrideSet()), lib, store, step: add, afterApplying: false)
        #expect(try await newAlbum(lib).assetIDs.isEmpty)
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(second.respecting(OverrideSet()))
        #expect(resumed.status == .completed)
        #expect(try await newAlbum(lib).assetIDs == ["x", "y"])
    }

    /// Undo afterwards takes out exactly what Albumist added: x and y, and z from the user's
    /// album. A photo the user put into the new album meanwhile stays, and so does that album.
    @Test func undoAfterwardsRemovesExactlyWhatAlbumistAdded() async throws {
        let (lib, plan) = try await setup(extendOwn: true)
        let store = InMemoryPlanStore()
        let add = try newAlbumAdd(plan)
        let crashed = try await interrupt(plan, lib, store, step: add, afterApplying: false)
        let executor = ChangeExecutor(library: lib, store: store)
        let resumed = try await executor.execute(crashed.respecting(OverrideSet()))
        #expect(resumed.appliedAssets.contains("x"))
        let album = try await newAlbum(lib)
        await lib.userEdit { inv in if var a = inv[album.id] { a.assetIDs.insert("u"); inv.upsert(a) } }

        let undo = confirmed(UndoPlanner().undoPlan(for: resumed, current: try await lib.currentInventory()))
        let undone = try await executor.execute(undo)
        #expect(undone.status == .completed, "\(undone.steps.map(\.state))")
        let inv = try await lib.currentInventory()
        #expect(inv["sommer"]?.assetIDs == ["o"])
        #expect(inv[album.id]?.assetIDs == ["u"])
        #expect(await lib.assets == ["x", "y", "z", "o", "u"])
    }

    /// Without the user's photo the undo removes the album it made.
    @Test func undoAfterwardsRemovesTheFilledAlbum() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let crashed = try await interrupt(plan, lib, store, step: try newAlbumAdd(plan), afterApplying: false)
        let executor = ChangeExecutor(library: lib, store: store)
        let resumed = try await executor.execute(crashed.respecting(OverrideSet()))
        let undone = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: resumed, current: try await lib.currentInventory())))
        #expect(undone.status == .completed)
        #expect(try await lib.currentInventory().albums.map(\.id) == ["sommer"])
    }

    /// The managed-album record after the resume knows x and y as Albumist's, so a later
    /// removal by the user is noticed as the user's decision.
    @Test func managedRecordKnowsTheFilledPhotos() async throws {
        let (lib, plan) = try await setup()
        let store = InMemoryPlanStore()
        let crashed = try await interrupt(plan, lib, store, step: try newAlbumAdd(plan), afterApplying: false)
        let resumed = try await ChangeExecutor(library: lib, store: store).execute(crashed.respecting(OverrideSet()))
        let states = ManagedAlbumTracker().record(resumed, into: [], inventory: try await lib.currentInventory())
        let album = try await newAlbum(lib)
        #expect(states.first { $0.albumID == album.id }?.addedByAlbumist == ["x", "y"])
    }
}
