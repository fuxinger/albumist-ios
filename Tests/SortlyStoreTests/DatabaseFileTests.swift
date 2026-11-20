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

    /// The moves of a plan (none when it moves nothing).
    func moves(_ existing: Set<String>, current: String? = nil) -> [DatabaseFile.Move] {
        if case .move(let moves) = DatabaseFile.plan(existing: existing, legacy: old, current: current ?? new) { return moves }
        return []
    }

    // MARK: The plan (no files)

    @Test func onlyTheEarlierDatabaseMovesWithItsLogAndSharedMemoryTheDatabaseLast() {
        let planned = moves([old, old + "-wal", old + "-shm"])
        #expect(planned.map(\.from) == [old + "-wal", old + "-shm", old])
        #expect(planned.map(\.to) == [new + "-wal", new + "-shm", new])
        #expect(planned.allSatisfy { !$0.replacing })
    }

    @Test func aCurrentDatabaseIsNeverReplaced() {
        #expect(DatabaseFile.plan(existing: [old, old + "-wal", new], legacy: old, current: new) == .openCurrent)
    }

    @Test func noEarlierDatabaseNothingMoves() {
        #expect(DatabaseFile.plan(existing: [], legacy: old, current: new) == .openCurrent)
        // A log without its database is not a database: it stays where it is.
        #expect(DatabaseFile.plan(existing: [old + "-wal"], legacy: old, current: new) == .openCurrent)
    }

    @Test func theSameNameMovesNothing() {
        #expect(DatabaseFile.plan(existing: [old, old + "-wal"], legacy: old, current: old) == .openCurrent)
    }

    @Test func aLogAlreadyMovedByAnInterruptedStartStaysAndTheRestFollows() {
        // The earlier start moved the log, then stopped before the database file.
        let planned = moves([old, old + "-shm", new + "-wal"])
        #expect(planned.map(\.from) == [old + "-shm", old])
        #expect(planned.allSatisfy { !$0.replacing })
    }

    @Test func onlyAStraySharedMemoryFileGivesWayToTheEarlierOne() {
        #expect(moves([old, old + "-shm", new + "-shm"]) == [DatabaseFile.Move(from: old + "-shm", to: new + "-shm", replacing: true),
                                                             DatabaseFile.Move(from: old, to: new, replacing: false)])
    }

    @Test func aLogUnderBothNamesMovesNothing() {
        // Either log may hold committed rows: none is replaced (second review of prep/rename).
        #expect(DatabaseFile.plan(existing: [old, old + "-wal", new + "-wal"], legacy: old, current: new) == .keepEarlier)
    }

    @Test func theWayBackTakesEveryFileOfTheCurrentNameWithoutItsEarlierCounterpartDatabaseFirst() {
        // The database file moved (its move reported a failure), and a log an earlier start moved.
        let back = DatabaseFile.rollback(existing: [new, new + "-wal", old + "-shm", new + "-shm"], legacy: old, current: new)
        #expect(back == [DatabaseFile.Move(from: new, to: old, replacing: false),
                         DatabaseFile.Move(from: new + "-wal", to: old + "-wal", replacing: false)])
        #expect(DatabaseFile.rollback(existing: [old, new + "-wal"], legacy: old, current: old).isEmpty)
    }

    @Test func earlierFilesBesideTheCurrentDatabaseAreListedNotDeleted() {
        // An older build ran again after the move and wrote a new database under its name.
        #expect(DatabaseFile.filesLeftBeside(existing: [new, new + "-wal", old, old + "-wal"], legacy: old, current: new) == [old, old + "-wal"])
        #expect(DatabaseFile.filesLeftBeside(existing: [old, old + "-wal", new + "-wal"], legacy: old, current: new) == [new + "-wal"])
        #expect(DatabaseFile.filesLeftBeside(existing: [new, new + "-wal"], legacy: old, current: new).isEmpty)
        #expect(DatabaseFile.filesLeftBeside(existing: [old], legacy: old, current: old).isEmpty)
    }

    // MARK: On disk

    @Test func theEarlierDatabaseOpensUnderTheCurrentNameWithItsContent() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", old, in: dir)
        try write("log", old + "-wal", in: dir)
        try write("shm", old + "-shm", in: dir)
        let (url, outcome) = try DatabaseFile.prepare(in: dir, legacy: old, current: new)
        #expect(outcome == .moved(count: 3))
        #expect(url == dir.appendingPathComponent(new))
        #expect(read(new, in: dir) == "db" && read(new + "-wal", in: dir) == "log" && read(new + "-shm", in: dir) == "shm")
        for suffix in ["", "-wal", "-shm"] { #expect(read(old + suffix, in: dir) == nil) }
        // The next start finds the current database and does nothing.
        #expect(try DatabaseFile.prepare(in: dir, legacy: old, current: new).outcome == .unchanged)
    }

    @Test func bothThereTheCurrentOneOpensAndTheEarlierOneIsLeftAlone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("earlier", old, in: dir)
        try write("current", new, in: dir)
        let (url, outcome) = try DatabaseFile.prepare(in: dir, legacy: old, current: new)
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
        let (url, outcome) = try DatabaseFile.prepare(in: dir, legacy: old, current: new) { from, to in
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

    @Test func aLogLeftByAnEarlierStartGoesBackWithTheDatabaseWhenTheMoveFails() throws {
        // An earlier start moved the log and stopped; now the database file cannot move. The
        // earlier name opens: its log must be next to it, or committed rows are invisible.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", old, in: dir)
        try write("log", new + "-wal", in: dir)
        let (url, outcome) = try DatabaseFile.prepare(in: dir, legacy: old, current: new) { from, to in
            if from.lastPathComponent == old { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        #expect(outcome == .keptEarlierName)
        #expect(url == dir.appendingPathComponent(old))
        #expect(read(old + "-wal", in: dir) == "log")
        #expect(read(new + "-wal", in: dir) == nil)
    }

    @Test func aLogOnBothSidesIsNeverDeleted() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", old, in: dir)
        try write("earlier log", old + "-wal", in: dir)
        try write("stray log", new + "-wal", in: dir)
        let (url, outcome) = try DatabaseFile.prepare(in: dir, legacy: old, current: new)
        #expect(outcome == .logUnderBothNames)
        // Which log holds committed rows is not known: nothing moves, nothing is deleted, the
        // earlier database opens with its own log.
        #expect(url == dir.appendingPathComponent(old))
        #expect(read(old, in: dir) == "db" && read(old + "-wal", in: dir) == "earlier log")
        #expect(read(new + "-wal", in: dir) == "stray log")
    }

    @Test func aWayBackThatFailsTooFailsTheStartAndDeletesNothing() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", old, in: dir)
        try write("log", old + "-wal", in: dir)
        // The log moves, the database file does not, and the log cannot go back.
        var moved = 0
        #expect(throws: DatabaseFile.RollbackFailed.self) {
            _ = try DatabaseFile.prepare(in: dir, legacy: old, current: new) { from, to in
                moved += 1
                if moved > 1 { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        #expect(read(old, in: dir) == "db" && read(new + "-wal", in: dir) == "log")
        // The next start finds the same state and moves on from there.
        let (url, outcome) = try DatabaseFile.prepare(in: dir, legacy: old, current: new)
        #expect(outcome == .moved(count: 1) && url.lastPathComponent == new)
        #expect(read(new, in: dir) == "db" && read(new + "-wal", in: dir) == "log")
    }

    @Test func theEarlierNameIsTheOneOlderBuildsWrote() {
        // Spelled out: after the rename `name` changes and this one must not (the rename script
        // keeps exactly this line, tools/rename_albumist.py).
        #expect(DatabaseFile.legacyName == "sortly.sqlite")
    }

    @Test func theAppsNamesOpenTheDatabaseOlderBuildsWrote() throws {
        // With the app's own names: before the rename both are the same (nothing moves), after
        // it the earlier file moves. Either way the content written under the earlier name opens.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("db", DatabaseFile.legacyName, in: dir)
        let (url, _) = try DatabaseFile.prepare(in: dir)
        #expect(url.lastPathComponent == DatabaseFile.name)
        #expect(try Data(contentsOf: url) == Data("db".utf8))
    }
}
