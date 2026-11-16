import Foundation
import Testing
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Audit 2, 5.3: what the execution journal costs for a very large plan (100,000 photos in
/// 200 albums, 401 steps of up to 500 photos). The journal is written before and after every
/// step with full durability. Measured in the Linux container: 160 s when every save wrote
/// the whole plan (9 MB), 1.7 s step by step (schema v4); the executor alone takes 0.4 s.
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
}
