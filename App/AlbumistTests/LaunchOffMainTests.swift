import Foundation
import Testing
@testable import Albumist

/// The database folder is made and marked off the main thread (UI run 45589509156, 25.11.2026:
/// its file calls in `AppModel.databaseURL` held the main thread at launch). `databaseURL` is
/// nonisolated, so `AppModel.load` runs it in a detached task; this test calls it there too
/// (it would not compile if it belonged to the main actor) and checks what it promises.
@Suite("Launch work off the main thread")
struct LaunchOffMainTests {
    @Test func theDatabaseFolderIsMadeOffTheMainThread() async throws {
        let (url, onMain) = try await Task.detached(priority: .userInitiated) {
            (try AppModel.databaseURL(), Thread.isMainThread)
        }.value
        #expect(!onMain)
        let folder = url.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
