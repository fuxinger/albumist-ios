import Foundation
import Testing
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Audit 2, 5.3: what the execution journal costs for a very large plan (100,000 photos in
/// 200 albums, 401 steps of up to 500 photos). The journal is written before and after every
/// step with full durability. Measured in the Linux container: 160 s when every save wrote
/// the whole plan (9 MB), 1.7 s step by step (schema v4); the executor alone takes 0.4 s.
/// The id of each new album written down inside its change (P2-01) read and wrote the whole
/// plan for every album: 28.4 s in CI, 51 s in the container (3.7 s before). It reads and
/// writes the plan's header row only now: 4.2 to 4.5 s (second review of P2-01).
/// Run with SORTLY_LOAD_TEST=1.
@Suite("Journal load", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SORTLY_LOAD_TEST"] != nil))
struct JournalLoadTests {
    @Test func hundredThousandPhotosIntoTwoHundredAlbums() async throws {
        let photos = 100_000, albums = 200
        let ids = (0..<photos).map { AssetID(String(format: "%08X-0000-4000-8000-%012X/L0/001", $0, $0)) }
        let lib = InMemoryPhotoLibrary(assets: Set(ids))
        let perAlbum = photos / albums
        let confirmed = (0..<albums).map { a in
            ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("p\(a)"), kind: .trip, title: "Reise \(a)", folderPath: [],
                                                      assetIDs: Set(ids[a * perAlbum..<(a + 1) * perAlbum])),
                              decision: .createNew(title: nil, folderPath: nil))
        }
        var plan = OrganizationPlanner().makePlan(from: confirmed, inventory: try await lib.currentInventory())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SortlyStore(url: folder.appendingPathComponent("db.sqlite"))
        let clock = ContinuousClock()
        let base = clock.now
        _ = try await ChangeExecutor(library: InMemoryPhotoLibrary(assets: Set(ids)), store: InMemoryPlanStore()).execute(plan)
        print("JOURNAL without database \(clock.now - base)")
        let started = clock.now
        let result = try await ChangeExecutor(library: lib, store: store).execute(plan)
        let elapsed = clock.now - started
        let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("db.sqlite").path)[.size] as? Int) ?? 0
        let saved = try #require(try await store.plan(plan.id))
        print("JOURNAL steps \(plan.steps.count), elapsed \(elapsed), db \(size / 1_000_000) MB, peak \(LoadTests.peakMemoryMB() ?? -1) MB")
        #expect(result.status == .completed)
        #expect(saved.appliedAssets.count == photos)
        #expect(elapsed < .seconds(20))
        // Reading the history must stay quick too (the overview reads it after every change).
        let read = clock.now
        for _ in 0..<10 { _ = try await store.undoneTargets(); _ = try await store.planHistory(limit: 20) }
        print("JOURNAL history reads x10 \(clock.now - read)")
    }

    /// Second review of P2-01 (S1): every save keeps the ids written down inside a change by
    /// reading the stored plan's header row (never its steps and media). What that costs on a
    /// plan of 2,000 steps (1,000 new albums), saved before and after every step with full
    /// durability, while each album's id is written down inside its change. Measured in the
    /// Linux container (debug build, three runs each): 24.8 to 26.2 s without the merge, 24.0
    /// to 28.4 s with it; the merge itself (header read and compare) took 1.6 s of it, about
    /// 0.3 ms per save, the rest are the 5,000 durable writes. The large plan above stays at
    /// 4.2 to 4.5 s either way.
    @Test func stepSavesOfAPlanWithTwoThousandStepsStayQuick() async throws {
        let albums = 1_000
        let ids = (0..<(albums * 5)).map { AssetID(String(format: "%08X-0000-4000-8000-%012X/L0/001", $0, $0)) }
        let lib = InMemoryPhotoLibrary(assets: Set(ids))
        let confirmed = (0..<albums).map { a in
            ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("p\(a)"), kind: .trip, title: "Reise \(a)", folderPath: [],
                                                      assetIDs: Set(ids[a * 5..<(a + 1) * 5])),
                              decision: .createNew(title: nil, folderPath: nil))
        }
        var plan = OrganizationPlanner(rootFolderTitle: "").makePlan(from: confirmed, inventory: try await lib.currentInventory())
        plan.confirmedAt = Date()
        plan.status = .running
        plan.record = ExecutionRecord()
        #expect(plan.steps.count == 2 * albums)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SortlyStore(url: folder.appendingPathComponent("db.sqlite"))
        try await store.save(plan)
        let clock = ContinuousClock()
        let started = clock.now
        for index in plan.steps.indices {
            plan.steps[index].state = .running(startedAt: Date())
            try await store.save(plan)
            if case .createAlbum(let key, _, _) = plan.steps[index].operation {
                // Written inside the change; the run's copy hears of it when Photos returns.
                try await store.noteCreated(CollectionID("album-\(index)"), key: key, in: plan)
                plan.record?.noteRequested(CollectionID("album-\(index)"), key: key)
            }
            plan.steps[index].state = .succeeded(createdID: nil, verifiedAt: Date())
            try await store.save(plan)
        }
        let elapsed = clock.now - started
        print("JOURNAL 2,000 steps, \(2 * plan.steps.count) saves and \(albums) ids written inside the change: \(elapsed)")
        let saved = try #require(try await store.plan(plan.id))
        #expect(saved.record?.maybeCreated.count == albums)
        #expect(saved.steps.allSatisfy { $0.state.isFinished })
        #expect(elapsed < .seconds(60))
    }
}
