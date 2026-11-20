import Foundation
import Testing
@testable import SortlyStore

/// The one-time move of the database from its earlier file name (rename of the working name,
/// `tools/rename_albumist.py`): an update must open the user's database, never a new empty one.
@Suite("Database file name")
struct DatabaseFileTests {
    let old = "old.sqlite", new = "new.sqlite"

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, _ name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    func read(_ name: String, in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: The plan (no files)

    @Test func onlyTheEarlierDatabaseMovesWithItsLogAndSharedMemoryTheDatabaseLast() {
        let moves = DatabaseFile.plan(existing: [old, old + "-wal", old + "-shm"], legacy: old, current: new)
        #expect(moves.map(\.from) == [old + "-wal", old + "-shm", old])
        #expect(moves.map(\.to) == [new + "-wal", new + "-shm", new])
        #expect(moves.allSatisfy { !$0.replacing })
    }

    @Test func aCurrentDatabaseIsNeverReplaced() {
        #expect(DatabaseFile.plan(existing: [old, old + "-wal", new], legacy: old, current: new).isEmpty)
    }

    @Test func noEarlierDatabaseNothingMoves() {
        #expect(DatabaseFile.plan(existing: [], legacy: old, current: new).isEmpty)
        // A log without its database is not a database: it stays where it is.
        #expect(DatabaseFile.plan(existing: [old + "-wal"], legacy: old, current: new).isEmpty)
    }

    @Test func theSameNameMovesNothing() {
        #expect(DatabaseFile.plan(existing: [old, old + "-wal"], legacy: old, current: old).isEmpty)
    }

    @Test func aLogAlreadyMovedByAnInterruptedStartStaysAndTheRestFollows() {
        // The earlier start moved the log, then stopped before the database file.
        let moves = DatabaseFile.plan(existing: [old, old + "-shm", new + "-wal"], legacy: old, current: new)
        #expect(moves.map(\.from) == [old + "-shm", old])
        #expect(moves.allSatisfy { !$0.replacing })
    }

    @Test func aStrayFileOfTheCurrentNameGivesWayToTheEarlierOne() {
        let moves = DatabaseFile.plan(existing: [old, old + "-shm", new + "-shm"], legacy: old, current: new)
        #expect(moves == [DatabaseFile.Move(from: old + "-shm", to: new + "-shm", replacing: true),
                          DatabaseFile.Move(from: old, to: new, replacing: false)])
    }

    // MARK: On disk

    @Test func theEarlierDatabaseOpensUnderTheCurrentNameWithItsContent() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", old, in: dir)
        try write("log", old + "-wal", in: dir)
        try write("shm", old + "-shm", in: dir)
        let (url, outcome) = DatabaseFile.prepare(in: dir, legacy: old, current: new)
        #expect(outcome == .moved(count: 3))
        #expect(url == dir.appendingPathComponent(new))
        #expect(read(new, in: dir) == "db" && read(new + "-wal", in: dir) == "log" && read(new + "-shm", in: dir) == "shm")
        for suffix in ["", "-wal", "-shm"] { #expect(read(old + suffix, in: dir) == nil) }
        // The next start finds the current database and does nothing.
        #expect(DatabaseFile.prepare(in: dir, legacy: old, current: new).outcome == .unchanged)
    }

    @Test func bothThereTheCurrentOneOpensAndTheEarlierOneIsLeftAlone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("earlier", old, in: dir)
        try write("current", new, in: dir)
        let (url, outcome) = DatabaseFile.prepare(in: dir, legacy: old, current: new)
        #expect(outcome == .unchanged && url.lastPathComponent == new)
        #expect(read(old, in: dir) == "earlier" && read(new, in: dir) == "current")
    }

    @Test func aFailedMovePutsEverythingBackAndOpensTheEarlierName() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", old, in: dir)
        try write("log", old + "-wal", in: dir)
        // The log moves, then the database file cannot (a full or locked folder).
        var tried: [String] = []
        let (url, outcome) = DatabaseFile.prepare(in: dir, legacy: old, current: new) { from, to in
            tried.append(from.lastPathComponent)
            if from.lastPathComponent == old { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        // The log first, then the database file, then the log back.
        #expect(tried == [old + "-wal", old, new + "-wal"])
        #expect(outcome == .keptEarlierName)
        #expect(url == dir.appendingPathComponent(old))
        #expect(read(old, in: dir) == "db" && read(old + "-wal", in: dir) == "log")
        #expect(read(new + "-wal", in: dir) == nil && read(new, in: dir) == nil)
    }

    @Test func theAppsNamesOpenTheDatabaseOlderBuildsWrote() throws {
        // With the app's own names: before the rename both are the same (nothing moves), after
        // it the earlier file moves. Either way the content written under the earlier name opens.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", DatabaseFile.legacyName, in: dir)
        let (url, _) = DatabaseFile.prepare(in: dir)
        #expect(url.lastPathComponent == DatabaseFile.name)
        #expect(try Data(contentsOf: url) == Data("db".utf8))
    }
}
