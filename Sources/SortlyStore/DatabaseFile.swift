import Foundation

/// The database's file name in the app's support folder, and the one-time move from an earlier
/// name. The rename of the internal working name to Albumist (`tools/rename_albumist.py`) changes
/// `name`; `legacyName` stays, because on devices that ran an older build the database (and its
/// write-ahead log) still carries it. Without the move an update would open a new, empty database
/// next to the old one: every decision, plan and album record would be gone.
public enum DatabaseFile {
    /// The name the database is opened under.
    public static let name = "sortly.sqlite"
    /// The name older builds wrote. Never renamed (listed in the rename script's exclusions).
    public static let legacyName = "sortly.sqlite"
    /// The files of one database: the write-ahead log and shared memory first, the database file
    /// last (a move cut off half way leaves the database where it was, so the next start retries).
    static let suffixes = ["-wal", "-shm", ""]

    /// One file to move from the earlier name to the current one.
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String
        /// A file of the current name is in the way (left over from nowhere the database can be
        /// opened from: the current database file does not exist). The earlier file wins.
        public let replacing: Bool
    }

    /// What the start does with the folder's files: nothing, or these moves. Pure, so the rules
    /// are tested without files.
    ///
    /// - The current database file exists: it is used, earlier files stay untouched.
    /// - Only the earlier database file exists: it moves together with its log and shared memory.
    ///   A log or shared memory file already under the current name (an earlier start moved it
    ///   and stopped before the database file) stays: it belongs to the database that follows.
    /// - Neither exists: a new database starts under the current name.
    public static func plan(existing: Set<String>, legacy: String = legacyName, current: String = name) -> [Move] {
        guard legacy != current, !existing.contains(current), existing.contains(legacy) else { return [] }
        return suffixes.compactMap { suffix in
            let from = legacy + suffix, to = current + suffix
            guard existing.contains(from) else { return nil }
            return Move(from: from, to: to, replacing: existing.contains(to))
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing to move.
        case unchanged
        /// The earlier files now carry the current name.
        case moved(count: Int)
        /// A move failed; what had moved went back, so the database opens under its earlier name
        /// this time and the next start tries again.
        case keptEarlierName
    }

    /// Moves an earlier database in `folder` to the current name when the plan says so and
    /// returns the file to open: the current name, or the earlier one when the move failed
    /// (never a new, empty database next to the user's data). Call before the database opens.
    ///
    /// `move` is the file move (tests hand in one that fails).
    public static func prepare(in folder: URL, legacy: String = legacyName, current: String = name,
                               move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) })
        -> (url: URL, outcome: Outcome) {
        let fm = FileManager.default
        let currentURL = folder.appendingPathComponent(current)
        let candidates = suffixes.flatMap { [legacy + $0, current + $0] }
        let existing = Set(candidates.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) })
        let moves = plan(existing: existing, legacy: legacy, current: current)
        guard !moves.isEmpty else { return (currentURL, .unchanged) }
        var done: [Move] = []
        do {
            for step in moves {
                let from = folder.appendingPathComponent(step.from), to = folder.appendingPathComponent(step.to)
                if step.replacing { try fm.removeItem(at: to) }
                try move(from, to)
                done.append(step)
            }
        } catch {
            for step in done.reversed() {
                try? move(folder.appendingPathComponent(step.to), folder.appendingPathComponent(step.from))
            }
            return (folder.appendingPathComponent(legacy), .keptEarlierName)
        }
        return (currentURL, .moved(count: done.count))
    }
}
