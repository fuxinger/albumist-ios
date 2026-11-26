import Foundation
import Testing
@testable import AlbumistStore
@testable import AlbumistCore
import AlbumistTestSupport

/// Review P2-09: the store tells an undo what the other changes still want, from the whole
/// journal: finished plans not taken back, without the plan itself.
@Suite("Review P2-09: what other changes want, from the journal")
struct KeptForOthersStoreTests {
    func plan(_ id: String, status: PlanStatus, reverts: AlbumistID? = nil, wants: [AssetID]) -> ChangePlan {
        var p = ChangePlan(id: AlbumistID(id), createdAt: Date(), confirmedAt: Date(), status: status, baseline: [:],
                           baselineCollectionIDs: [], steps: [], conflicts: [], notes: [], resolvedKeys: [:])
        p.reverts = reverts
        p.wanted = [AlbumWish(album: .existing("rom"), assets: wants)]
        return p
    }

    @Test func onlyFinishedPlansNotTakenBackCount() async throws {
        let store = try AlbumistStore(url: nil)
        let p = plan("p", status: .completed, wants: ["a-1", "a-2"])
        let q = plan("q", status: .completed, wants: ["a-2", "a-3"])
        let running = plan("r", status: .running, wants: ["a-4"])
        try await store.save(p)
        try await store.save(q)
        try await store.save(running)
        #expect(try await store.keptForOthers(undoing: p) == ["rom": ["a-2", "a-3"]])
        // Q taken back: it wants nothing any more.
        try await store.save(plan("undo-q", status: .completed, reverts: q.id, wants: []))
        #expect(try await store.keptForOthers(undoing: p) == [:])
    }
}
