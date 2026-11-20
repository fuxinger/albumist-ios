import Foundation

/// The database's file name in the app's support folder, and the one-time move from an earlier
/// name. The rename of the internal working name to Albumist (`tools/rename_albumist.py`) changes
/// `name`; `legacyName` stays, because on devices that ran an older build the database (and its
/// write-ahead log) still carries it. Without the move an update would open a new, empty database
/// next to the old one: every decision, plan and album record would be gone.
public enum DatabaseFile {
    /// The name the database is opened under.
    public static let name = "albumist.sqlite"
    /// The name older builds wrote. Never renamed (listed in the rename script's exclusions).
    public static let legacyName = "sortly.sqlite"
    /// The files of one database: the write-ahead log and shared memory first, the database file
    /// last (a move cut off half way leaves the database where it was, so the next start retries).
    static let suffixes = ["-wal", "-shm", ""]

    /// One file to move from one name to the other.
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String
        /// A shared memory file of the current name is in the way (no current database exists,
        /// so no connection uses it; it holds no committed data, only an index SQLite rebuilds).
        /// It is deleted first. Never set for a write-ahead log or a database file.
        public let replacing: Bool
    }

    public enum Plan: Equatable, Sendable {
        /// Nothing to move: the current name opens (an existing database or a new one).
        case openCurrent
        /// These moves, then the current name opens.
        case move([Move])
        /// A write-ahead log under both names: the earlier database's own log is the one next to
        /// it; the one under the current name is stale. It must not stay there: once the earlier
        /// database closes cleanly (its log checkpointed and deleted), the next move would put the
        /// database next to the stale log and SQLite would replay it over newer rows (second
        /// review of prep/rename, 250 updates and an insert lost). So the stale log and shared
        /// memory of the current name go into `Quarantine/<time>-stray/` (moved, not deleted;
        /// only "Neu aufbauen" later thins those folders out to the two newest, apart from the
        /// quarantined databases), then the earlier database moves as usual.
        case setAsideStrayLog
    }

    /// What the start does with the folder's files. Pure, so the rules are tested without files.
    ///
    /// - The current database file exists: it is used, earlier files stay untouched.
    /// - Only the earlier database file exists: it moves together with its log and shared memory.
    ///   A log or shared memory file already under the current name (an earlier start moved it
    ///   and stopped before the database file) stays: it belongs to the database that follows.
    /// - Neither exists: a new database starts under the current name.
    public static func plan(existing: Set<String>, legacy: String = legacyName, current: String = name) -> Plan {
        guard legacy != current, !existing.contains(current), existing.contains(legacy) else { return .openCurrent }
        if existing.contains(legacy + "-wal"), existing.contains(current + "-wal") { return .setAsideStrayLog }
        return .move(suffixes.compactMap { suffix in
            let from = legacy + suffix, to = current + suffix
            guard existing.contains(from) else { return nil }
            return Move(from: from, to: to, replacing: existing.contains(to))
        })
    }

    /// After a failed move, before the earlier name opens: every file under the current name
    /// whose earlier counterpart is missing goes back, also a log an earlier start moved (no
    /// current database exists, so they all belong to the earlier one). Without them the earlier
    /// database would open without its log: committed rows invisible, later lost.
    public static func rollback(existing: Set<String>, legacy: String = legacyName, current: String = name) -> [Move] {
        guard legacy != current else { return [] }
        return suffixes.reversed().compactMap { suffix in
            let from = current + suffix, to = legacy + suffix
            guard existing.contains(from), !existing.contains(to) else { return nil }
            return Move(from: from, to: to, replacing: false)
        }
    }

    /// Files of the other name that stay where they are and are never deleted silently: earlier
    /// files next to the current database (an older build ran again after the move and wrote a
    /// new one; they still hold the user's data, recognized text included), or a log under the
    /// current name while the earlier database opens (a stray log that could not be set aside). The diagnostic report
    /// lists them.
    public static func filesLeftBeside(existing: Set<String>, legacy: String = legacyName, current: String = name) -> [String] {
        guard legacy != current else { return [] }
        let other = existing.contains(current) ? legacy : existing.contains(legacy) ? current : nil
        guard let other else { return [] }
        return suffixes.reversed().map { other + $0 }.filter { existing.contains($0) }
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing to move.
        case unchanged
        /// The earlier files now carry the current name.
        case moved(count: Int)
        /// A move failed; everything went back, so the database opens under its earlier name
        /// this time and the next start tries again.
        case keptEarlierName
        /// A stale log under the current name went into the quarantine folder
        /// (`Plan.setAsideStrayLog`), then the earlier files moved.
        case straySetAsideThenMoved(count: Int)
    }

    /// A failed move whose way back failed too, or a stray log that could not be set aside: the
    /// start fails (the start error screen), so no database opens without its log or next to a
    /// stale one. Nothing is deleted.
    public struct RollbackFailed: Error, CustomStringConvertible {
        public let files: [String]
        public var description: String { "database files could not be moved back: \(files.joined(separator: ", "))" }
    }

    /// The names of the database files in `folder`.
    public static func existing(in folder: URL, legacy: String = legacyName, current: String = name) -> Set<String> {
        let candidates = suffixes.flatMap { [legacy + $0, current + $0] }
        return Set(candidates.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
    }

    /// Moves an earlier database in `folder` to the current name when the plan says so and
    /// returns the file to open: the current name, or the earlier one (with its log next to it)
    /// when the move failed and everything went back. Never a new, empty database next to the
    /// user's data. Call before the database opens.
    ///
    /// `move` is the file move (tests hand in one that fails).
    /// - Throws: `RollbackFailed` when a failed move cannot be undone completely.
    public static func prepare(in folder: URL, legacy: String = legacyName, current: String = name, now: Date = Date(),
                               move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) })
        throws -> (url: URL, outcome: Outcome) {
        let url = { (file: String) in folder.appendingPathComponent(file) }
        switch plan(existing: existing(in: folder, legacy: legacy, current: current), legacy: legacy, current: current) {
        case .openCurrent:
            return (url(current), .unchanged)
        case .setAsideStrayLog:
            // Moved, not deleted; if that fails the start fails (nothing opens next to it).
            let stray = [current + "-wal", current + "-shm"].filter { FileManager.default.fileExists(atPath: url($0).path) }
            do {
                let aside = strayFolder(in: folder, now: now)
                try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
                for file in stray { try move(url(file), aside.appendingPathComponent(file)) }
            } catch {
                throw RollbackFailed(files: stray.filter { FileManager.default.fileExists(atPath: url($0).path) })
            }
            let (opened, outcome) = try prepare(in: folder, legacy: legacy, current: current, now: now, move: move)
            if case .moved(let count) = outcome { return (opened, .straySetAsideThenMoved(count: count)) }
            return (opened, outcome)
        case .move(let moves):
            do {
                for step in moves {
                    if step.replacing { try FileManager.default.removeItem(at: url(step.to)) }
                    try move(url(step.from), url(step.to))
                }
                return (url(current), .moved(count: moves.count))
            } catch {
                for step in rollback(existing: existing(in: folder, legacy: legacy, current: current), legacy: legacy, current: current) {
                    try? move(url(step.from), url(step.to))
                }
                let left = rollback(existing: existing(in: folder, legacy: legacy, current: current), legacy: legacy, current: current)
                guard left.isEmpty, FileManager.default.fileExists(atPath: url(legacy).path) else {
                    throw RollbackFailed(files: left.map(\.from))
                }
                return (url(legacy), .keptEarlierName)
            }
        }
    }

    /// Marks the quarantine folders of stray logs (`Quarantine/<time>-stray`): the quarantine
    /// of "Neu aufbauen" counts them apart from the quarantined databases.
    static let straySuffix = "-stray"

    /// A new folder `Quarantine/<time>-stray` next to the database (in the folder "Neu
    /// aufbauen" uses; a running number when one of that time exists).
    static func strayFolder(in folder: URL, now: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = folder.appendingPathComponent("Quarantine", isDirectory: true)
        var target = base.appendingPathComponent(stamp + straySuffix, isDirectory: true)
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            attempt += 1
            target = base.appendingPathComponent("\(stamp)\(straySuffix)-\(attempt)", isDirectory: true)
        }
        return target
    }

    /// The other of the two names (`name`, `legacyName`) for a database file name, or nil when
    /// both are the same or the name is neither (a test's own file).
    public static func otherName(for file: String) -> String? {
        guard name != legacyName else { return nil }
        return file == name ? legacyName : file == legacyName ? name : nil
    }
}
