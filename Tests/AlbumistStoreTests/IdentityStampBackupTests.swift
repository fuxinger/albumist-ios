import Foundation
import Testing
@testable import AlbumistStore
import AlbumistCore

/// The identity stamp and the safety backup (from the third review pass of the progress work): the identity stamp lives in `settings` under a
/// key the safety backup keeps ("database.identity" is not "analysis.%" / "execution.%").
@Suite("Identity stamp and the safety backup")
struct IdentityStampBackupTests {
    /// AppModel.load asks for the identity BEFORE restoreFromBackupIfNeeded. On a new iPhone or
    /// after "Neu aufbauen" the fresh database then already "has safety data", so the user's
    /// decisions and settings are not restored.
    @Test func freshDatabaseWithItsStampStillGetsTheDecisionsBack() async throws {
        let old = try AlbumistStore(url: nil)
        _ = try await old.identity()
        try await old.setValue(["trip-rom": "Rom im Mai"], forKey: "user.titles")
        let backup = try await old.safetyBackup()

        let fresh = try AlbumistStore(url: nil)
        _ = try await fresh.identity()                    // as AppModel.load does first
        #expect(try await fresh.hasSafetyData() == false, "a stamp alone counts as safety data")
        let restored = try await fresh.restore(backup, includingLibraryState: false)
        #expect(restored, "restore refused")
        #expect(try await fresh.value([String: String].self, forKey: "user.titles") == ["trip-rom": "Rom im Mai"])
    }

    /// The copy of a database with nothing but its stamp must count as empty, or it replaces a
    /// copy that holds decisions (SafetyBackupWriter's guard).
    @Test func copyOfAnEmptyDatabaseIsEmpty() async throws {
        let fresh = try AlbumistStore(url: nil)
        _ = try await fresh.identity()
        #expect(try await fresh.safetyBackup().isEmpty)
    }

    /// The copy carries the old stamp; restoring it gives the new database the old database's
    /// identity, so the marker written in this session (new stamp) is reset at the next launch.
    @Test func restoreKeepsTheNewStamp() async throws {
        let old = try AlbumistStore(url: nil)
        let oldID = try await old.identity().id
        try await old.setValue(["trip-rom": "Rom im Mai"], forKey: "user.titles")
        let backup = try await old.safetyBackup()
        let fresh = try AlbumistStore(url: nil)
        _ = try await fresh.restore(backup, includingLibraryState: false)   // without the stamp first
        let after = try await fresh.identity()
        #expect(after.id != oldID, "the restored copy brought the old database's stamp")
    }
}
