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

    /// Third review (1), the whole sequence as AppModel.load runs it on a new iPhone: an old
    /// copy with decisions, a fresh database that is asked for its stamp first, then the
    /// restore, then the next copy. The decisions come back, the new database keeps its own
    /// stamp, and the copy is never replaced by an empty one.
    @Test func newPhoneGetsTheDecisionsBackAndTheCopySurvives() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("safety.json")

        // The old iPhone: a stamp, a decision, a copy on disk.
        let old = try SortlyStore(url: nil)
        let oldID = try await old.identity().id
        try await old.setValue(["trip-rom": "Rom im Mai"], forKey: "user.titles")
        let first = try await old.safetyBackupSnapshot()
        #expect(try await SafetyBackupWriter(url: file).write(first.backup, sequence: first.sequence))

        // The new iPhone: load asks for the stamp first (as AppModel.load).
        let fresh = try SortlyStore(url: nil)
        let newID = try await fresh.identity().id
        // A copy taken before the restore is empty and does not replace the good one.
        let early = try await fresh.safetyBackupSnapshot()
        #expect(early.backup.isEmpty)
        #expect(try await SafetyBackupWriter(url: file).write(early.backup, sequence: early.sequence) == false)
        // restoreFromBackupIfNeeded.
        let copy = try #require(try SafetyBackup.read(from: file))
        #expect(!copy.isEmpty)
        #expect(try await fresh.hasSafetyData() == false)
        #expect(try await fresh.restore(copy, includingLibraryState: false))
        #expect(try await fresh.value([String: String].self, forKey: "user.titles") == ["trip-rom": "Rom im Mai"])
        #expect(try await fresh.identity().id == newID)
        #expect(newID != oldID)
        // The next copy holds the decisions again.
        let next = try await fresh.safetyBackupSnapshot()
        #expect(try await SafetyBackupWriter(url: file).write(next.backup, sequence: next.sequence))
        let after = try #require(try SafetyBackup.read(from: file))
        #expect(!after.isEmpty)
        #expect(after.values.contains { $0.key == "user.titles" })
        #expect(!after.values.contains { $0.key.hasPrefix("identity.") })
    }

    /// "Analyse neu aufbauen" with the decisions: the database stays the same database.
    @Test func resetKeepsTheStamp() async throws {
        let store = try SortlyStore(url: nil)
        let id = try await store.identity().id
        try await store.resetAnalysis(includingDecisions: true)
        #expect(try await store.identity().id == id)
        try await store.resetAnalysis()
        #expect(try await store.identity().id == id)
    }
}
