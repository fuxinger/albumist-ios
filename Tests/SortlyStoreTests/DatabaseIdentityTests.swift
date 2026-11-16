import Foundation
import Testing
@testable import SortlyStore
import SortlyCore

/// Review of 9f0bc40 (A): the analysis marker is bound to the database it was written for.
/// A database keeps its stamp across launches; a new one (rebuilt, set aside, restored empty
/// on a new iPhone) has another, so an old marker never meets it.
@Suite("Database identity")
struct DatabaseIdentityTests {
    @Test func stampStaysWithTheFileAndANewDatabaseGetsAnother() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sortly.sqlite")

        let first = try await SortlyStore(url: url).identity()
        #expect(first.isNew)
        let again = try await SortlyStore(url: url).identity()
        #expect(!again.isNew)
        #expect(again.id == first.id)

        // Set aside (as "Neu aufbauen" does): the new file is a new database.
        _ = SortlyStore.quarantineDatabase(at: url)
        let rebuilt = try await SortlyStore(url: url).identity()
        #expect(rebuilt.isNew)
        #expect(rebuilt.id != first.id)

        let other = try await SortlyStore(url: nil).identity()
        #expect(other.id != first.id)
    }
}
