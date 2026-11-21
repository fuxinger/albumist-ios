import Foundation
import Testing
@testable import AlbumistUITestLogic

/// Which app process `UITestAppEnd.end` names to the Mac (`UITestLaunchRecord`): the one the last
/// launch started, also from a new `XCUIApplication` without launch arguments (the first launch
/// of every test ended the app of the test before that way, without a process id).
@Suite("UI test launch record")
struct UITestLaunchRecordTests {
    let stalls = "/tmp/runner/uitest-main-stalls.txt"
    let stress = "/tmp/runner/stress-main-stalls.txt"

    func arguments(_ file: String) -> [String] {
        ["-AppleLanguages", "(de)", "-AlbumistUITestUnlocked", "-AlbumistUITestWatchMainLog", file]
    }

    @Test func readsTheWatchFileAndTheProcessID() {
        #expect(UITestLaunchRecord.watchFile(in: arguments(stalls)) == stalls)
        #expect(UITestLaunchRecord.watchFile(in: ["-AlbumistUITestWatchMainLog"]) == nil)
        #expect(UITestLaunchRecord.watchFile(in: []) == nil)
        // The app writes "@ <pid> <start> <now>" first; stalls ("<end> <ms>") and stacks ("# ...") follow.
        #expect(UITestLaunchRecord.processID(inText: "@ 4711 1795074330.2 1795074331.0\n1795074340.5 812\n# after 5.0 s: a | b\n") == 4711)
        #expect(UITestLaunchRecord.processID(inText: "1795074340.5 812\n") == nil)
        #expect(UITestLaunchRecord.processID(inText: "") == nil)
        #expect(UITestLaunchRecord.processID(inText: "@ x 1 2\n") == nil)
    }

    /// The first end in a test: a new XCUIApplication has no arguments, the app running is the
    /// one the last launch (of the test before) started.
    @Test func aNewTestEndsTheAppOfTheLastLaunchByItsID() {
        let record = UITestLaunchRecord()
        record.launching(arguments(stalls))
        let files = [stalls: "@ 4711 1.0 2.0\n"]
        #expect(record.processID(fallback: nil) { files[$0] } == 4711)
        // Also when the object to end names another file than the last launch.
        #expect(record.processID(fallback: stress) { files[$0] } == 4711)
    }

    /// DeviceConditionUITests and AccessibilityUITests print the stalls in teardown, which
    /// removes the file while the app still runs: the id read then is kept for the next end.
    @Test func theIDStaysKnownWhenTheStallReportRemovedTheFile() {
        let record = UITestLaunchRecord()
        record.launching(arguments(stalls))
        record.read("@ 4711 1.0 2.0\n1795074340.5 2100\n", of: stalls)
        #expect(record.processID(fallback: nil) { _ in nil } == 4711)
        // A file of another launch does not change it.
        record.read("@ 999 1.0 2.0\n", of: stress)
        #expect(record.processID(fallback: nil) { _ in nil } == 4711)
    }

    /// A new launch forgets the last id: until the new app wrote its own, no id (never the
    /// id of an app that is gone, which the Mac would skip while the new one runs on).
    @Test func aNewLaunchForgetsTheLastID() {
        let record = UITestLaunchRecord()
        record.launching(arguments(stalls))
        record.read("@ 4711 1.0 2.0\n", of: stalls)
        record.launching(arguments(stress))
        #expect(record.processID(fallback: nil) { _ in nil } == nil)
        #expect(record.processID(fallback: nil) { $0 == stress ? "@ 5000 3.0 4.0\n" : "@ 4711 1.0 2.0\n" } == 5000)
        // Read once, kept after its file is gone.
        #expect(record.processID(fallback: nil) { _ in nil } == 5000)
    }

    /// The file on disk still holds the last app's line until the new app writes its own
    /// (Flow, Search and Locked never remove it): a launch that failed or came late would let the
    /// next end name that dead process, which the Mac skips ("had ended already") while the new
    /// app runs on, and the test waits 60 s for XCTest. A launch removes the file first.
    @Test func aLaunchRemovesTheLastAppsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("uitest-main-stalls.txt").path
        try "@ 4711 1.0 2.0\n".write(toFile: file, atomically: true, encoding: .utf8)
        let record = UITestLaunchRecord()
        record.launching(arguments(file))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(record.processID(fallback: nil) { try? String(contentsOfFile: $0, encoding: .utf8) } == nil)
        // The new app writes its own line: that one counts.
        try "@ 5000 3.0 4.0\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(record.processID(fallback: nil) { try? String(contentsOfFile: $0, encoding: .utf8) } == 5000)
    }

    /// No launch known (the test runner restarted after a crash): the object's own file or the
    /// default one, as before.
    @Test func withoutAKnownLaunchTheFallbackFileIsRead() {
        let record = UITestLaunchRecord()
        #expect(record.processID(fallback: stalls) { $0 == stalls ? "@ 4711 1.0 2.0\n" : nil } == 4711)
        #expect(record.processID(fallback: nil) { _ in "@ 4711 1.0 2.0\n" } == nil)
        #expect(record.processID(fallback: stalls) { _ in nil } == nil)
    }
}
