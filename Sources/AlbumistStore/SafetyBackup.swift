import Foundation
import AlbumistCore

/// What cannot be rebuilt from the photo library: the user's decisions (overrides, rules,
/// settings, names, trip corrections), the albums Albumist manages and the execution journal
/// (history and undo). The database itself is kept out of device backups because most of it
/// is analysis that can be recomputed; this small copy goes into the backup instead, so a
/// rebuilt database (or a restored iPhone) gets the user's decisions back.
///
/// Rows are copied as stored (raw payloads), so the copy does not depend on the shape of the
/// model types and a newer app can still read an older copy.
public struct SafetyBackup: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public struct Row: Codable, Sendable, Equatable {
        public var key: String
        public var secondary: String?
        public var number: Double?
        public var payload: Data

        public init(key: String, secondary: String? = nil, number: Double? = nil, payload: Data) {
            self.key = key
            self.secondary = secondary
            self.number = number
            self.payload = payload
        }

        // Payloads are JSON text: kept as text in the file (base64 would make it a third
        // larger and hide the repetitions the compression finds). Other bytes stay base64.
        enum CodingKeys: String, CodingKey { case key, secondary, number, json, payload }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            secondary = try c.decodeIfPresent(String.self, forKey: .secondary)
            number = try c.decodeIfPresent(Double.self, forKey: .number)
            if let text = try c.decodeIfPresent(String.self, forKey: .json) {
                payload = Data(text.utf8)
            } else {
                payload = try c.decode(Data.self, forKey: .payload)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encodeIfPresent(secondary, forKey: .secondary)
            try c.encodeIfPresent(number, forKey: .number)
            if let text = String(data: payload, encoding: .utf8) {
                try c.encode(text, forKey: .json)
            } else {
                try c.encode(payload, forKey: .payload)
            }
        }
    }

    public var formatVersion: Int
    public var createdAt: Date
    /// Database schema the rows come from.
    public var schemaVersion: Int
    public var overrides: [Row]
    public var rules: [Row]
    public var managedAlbums: [Row]
    public var plans: [Row]
    /// Settings rows except computed analysis results (`analysis.*`) and in-flight execution
    /// markers (`execution.*`).
    public var values: [Row]
    /// Plans that ran but whose results (Albumist's albums, free albums) were not stored yet
    /// when the copy was made. Part of the journal: restored together with the plans, so the
    /// next launch still finishes them (audit 2, 3.1). Missing in copies of older versions.
    public var pendingFinalization: [String]? = nil

    /// Values that are not the database's own stamp count (copies made by 83db832 carried it).
    public var isEmpty: Bool {
        overrides.isEmpty && rules.isEmpty && managedAlbums.isEmpty && plans.isEmpty
            && values.allSatisfy { !AlbumistStore.isSafetyValue($0.key) }
    }

    /// The managed-album records in this copy (to check that it belongs to this library).
    public func managedAlbumStates() -> [ManagedAlbumState] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return managedAlbums.compactMap { try? decoder.decode(ManagedAlbumState.self, from: $0.payload) }
    }

    /// Whether the copy belongs to the library whose albums are `existing`: at least half of
    /// the albums it manages are still there. After moving to a new iPhone the identifiers can
    /// differ; then only the decisions are restored, not the album records and history (they
    /// would point at albums that do not exist and read as "deleted by you").
    public func matchesLibrary(albums existing: Set<CollectionID>) -> Bool {
        let states = managedAlbumStates()
        guard !states.isEmpty else { return true }
        let found = states.filter { existing.contains($0.albumID) }.count
        return found * 2 >= states.count
    }

    /// Whether the album records and history of this copy may come back, for the photo
    /// access Albumist has and the albums it can see (`visibleAlbums`, nil when they could not
    /// be read). true: restore them; false: the copy comes from another library (a new iPhone
    /// with new album identifiers), only the decisions come back; nil: cannot be told yet,
    /// they wait (and the copy is not overwritten meanwhile).
    /// - No photo access: wait.
    /// - Limited access: the albums may be hidden, so only a match counts; otherwise wait.
    /// - Full access: a match restores, anything else is another library.
    public func belongsToLibrary(access: LibraryAccess, visibleAlbums: Set<CollectionID>?) -> Bool? {
        guard !managedAlbums.isEmpty else { return true }
        guard access.canRead, let visibleAlbums else { return nil }
        if matchesLibrary(albums: visibleAlbums) { return true }
        return access == .full ? false : nil
    }

    // MARK: File

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        #if canImport(Darwin)
        // Plans list photo identifiers again and again: compressed, a copy for a large library
        // stays a few megabytes in the backup.
        if let packed = try? (data as NSData).compressed(using: .lzfse) as Data { data = packed }
        #endif
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a crash while writing leaves the previous copy, never half a file.
        try data.write(to: url, options: [.atomic])
    }

    public static func read(from url: URL) throws -> SafetyBackup? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        var data = try Data(contentsOf: url)
        if data.first != UInt8(ascii: "{") {
            #if canImport(Darwin)
            data = try (data as NSData).decompressed(using: .lzfse) as Data
            #else
            throw CocoaError(.fileReadCorruptFile)
            #endif
        }
        let backup = try decoder.decode(SafetyBackup.self, from: data)
        // A copy from a newer app version is left alone rather than half understood.
        return backup.formatVersion <= formatVersion ? backup : nil
    }
}

/// Writes the copy one at a time and never puts an older snapshot over a newer one: two
/// saves close together may finish in either order, the file keeps the later state of the
/// database (audit 2, 3.2).
public actor SafetyBackupWriter {
    private let url: URL
    private let protect: @Sendable (URL) -> Void
    private var newestWritten: Int?

    public init(url: URL, protect: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.url = url
        self.protect = protect
    }

    /// Writes `backup`, taken as snapshot number `sequence` (`AlbumistStore.safetyBackupSnapshot`).
    /// Returns false, without writing, when a later snapshot is already on disk, or when an
    /// empty snapshot would replace a copy that holds decisions: an empty database next to a
    /// full copy is one whose restore did not happen (failed, full disk, a copy from a newer
    /// version); overwriting the copy then would lose the decisions for good.
    public func write(_ backup: SafetyBackup, sequence: Int) throws -> Bool {
        if let newest = newestWritten, newest > sequence { return false }
        if backup.isEmpty, FileManager.default.fileExists(atPath: url.path) {
            // Unreadable counts as holding something: it may be a newer format.
            let existing = try? SafetyBackup.read(from: url)
            if existing?.isEmpty != true { return false }
        }
        try backup.write(to: url)
        protect(url)
        newestWritten = sequence
        return true
    }
}

extension AlbumistStore {
    /// A copy together with its place in the order of copies taken from this database.
    public func safetyBackupSnapshot(now: Date = Date()) throws -> (backup: SafetyBackup, sequence: Int) {
        let backup = try safetyBackup(now: now)
        backupSequence += 1
        return (backup, backupSequence)
    }

    /// Whether the database holds anything a backup would restore (then it is never
    /// overwritten from a copy).
    public func hasSafetyData() throws -> Bool {
        for table in ["overrides", "rules", "managed_albums", "plans"] {
            if try db.query("SELECT 1 AS x FROM \(table) LIMIT 1").isEmpty == false { return true }
        }
        return try db.query("SELECT 1 AS x FROM settings WHERE \(Self.keptValues) LIMIT 1").isEmpty == false
    }

    /// Whether the database already knows managed albums or plans (then the album records and
    /// the history of a copy are never added to it).
    public func hasLibraryState() throws -> Bool {
        for table in ["managed_albums", "plans"] {
            if try db.query("SELECT 1 AS x FROM \(table) LIMIT 1").isEmpty == false { return true }
        }
        return false
    }

    /// Settings rows a copy keeps. Not the analysis results, not in-flight execution markers,
    /// and never the database's own stamp (`identity.%`; `database.identity` in 83db832):
    /// counted as safety data it made a fresh database refuse the restore, and its copy
    /// replace a good one (third review of the switches branch).
    private static let keptValues = "key NOT LIKE 'analysis.%' AND key NOT LIKE 'execution.%' AND key NOT LIKE 'identity.%' AND key <> 'database.identity'"

    /// The same rule for one key (a copy's rows on restore, `SafetyBackup.isEmpty`).
    public static func isSafetyValue(_ key: String) -> Bool {
        !key.hasPrefix("analysis.") && !key.hasPrefix("execution.") && !key.hasPrefix("identity.") && key != "database.identity"
    }
    /// Plans that finished but are not finalized yet (written by the app).
    public static let pendingFinalizationKey = "execution.pendingFinalization"

    /// A copy of everything that cannot be recomputed.
    public func safetyBackup(now: Date = Date()) throws -> SafetyBackup {
        func rows(_ sql: String, key: String, secondary: String? = nil, number: String? = nil) throws -> [SafetyBackup.Row] {
            try db.query(sql).compactMap { r in
                guard let k = r[key]?.string, let payload = r["payload"]?.data else { return nil }
                return SafetyBackup.Row(key: k, secondary: secondary.flatMap { r[$0]?.string }, number: number.flatMap { r[$0]?.double }, payload: payload)
            }
        }
        return try db.transaction {
            SafetyBackup(
                formatVersion: SafetyBackup.formatVersion,
                createdAt: now,
                schemaVersion: db.userVersion,
                overrides: try rows("SELECT id, payload, created_at FROM overrides ORDER BY id", key: "id", number: "created_at"),
                rules: try rows("SELECT id, CAST(version AS REAL) AS version, payload, updated_at FROM rules ORDER BY id, version",
                                key: "id", number: "version"),
                managedAlbums: try rows("SELECT album_id, source_id, payload FROM managed_albums ORDER BY album_id", key: "album_id", secondary: "source_id"),
                // Whole plans (steps and media put back), so the copy keeps one row per plan.
                plans: try db.query("SELECT id, status, created_at, payload FROM plans ORDER BY id").compactMap { r in
                    guard let k = r["id"]?.string, let plan = try loadPlan(r["payload"]), case .blob(let payload) = try json(plan) else { return nil }
                    return SafetyBackup.Row(key: k, secondary: r["status"]?.string, number: r["created_at"]?.double, payload: payload)
                },
                values: try rows("SELECT key, payload FROM settings WHERE \(Self.keptValues) ORDER BY key", key: "key"),
                pendingFinalization: try db.query("SELECT payload FROM settings WHERE key = ?", [.text(Self.pendingFinalizationKey)])
                    .first.flatMap { try decode([String].self, $0["payload"]) }
            )
        }
    }

    /// Restores a copy into a database without safety data (fresh or rebuilt), in one
    /// transaction. With `includingLibraryState` false only the decisions come back, not the
    /// managed albums and the journal (they can follow later with `restoreLibraryState`, once
    /// it is clear that the copy belongs to this library). Returns false and changes nothing
    /// if the database already holds safety data.
    @discardableResult
    public func restore(_ backup: SafetyBackup, includingLibraryState: Bool) throws -> Bool {
        guard try !hasSafetyData() else { return false }
        try db.durably {
            try db.transaction {
                for r in backup.overrides {
                    try db.execute("INSERT OR REPLACE INTO overrides (id, payload, created_at) VALUES (?, ?, ?)",
                                   [.text(r.key), .blob(r.payload), r.number.map { .real($0) } ?? .null])
                }
                for r in backup.rules {
                    try db.execute("INSERT OR REPLACE INTO rules (id, version, payload, updated_at) VALUES (?, ?, ?, NULL)",
                                   [.text(r.key), .integer(Int64(r.number ?? 1)), .blob(r.payload)])
                }
                // Never the old database's stamp: the new one keeps its own.
                for r in backup.values where Self.isSafetyValue(r.key) {
                    try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(r.key), .blob(r.payload)])
                }
                if includingLibraryState { try insertLibraryState(backup) }
            }
        }
        return true
    }

    /// Adds the managed albums and the journal of a copy whose decisions were restored
    /// earlier. Returns false and changes nothing if the database already has either.
    @discardableResult
    public func restoreLibraryState(_ backup: SafetyBackup) throws -> Bool {
        guard try !hasLibraryState() else { return false }
        try db.durably {
            try db.transaction { try insertLibraryState(backup) }
        }
        return true
    }

    private func insertLibraryState(_ backup: SafetyBackup) throws {
        for r in backup.managedAlbums {
            try db.execute("INSERT OR REPLACE INTO managed_albums (album_id, source_id, payload) VALUES (?, ?, ?)",
                           [.text(r.key), .text(r.secondary ?? ""), .blob(r.payload)])
        }
        for r in backup.plans {
            // Whole plans as in older versions: they are read as such until saved again.
            try db.execute("INSERT OR REPLACE INTO plans (id, status, created_at, payload) VALUES (?, ?, ?, ?)",
                           [.text(r.key), .text(r.secondary ?? "completed"), r.number.map { .real($0) } ?? .null, .blob(r.payload)])
            try db.execute("DELETE FROM plan_steps WHERE plan_id = ?", [.text(r.key)])
            try db.execute("DELETE FROM plan_media WHERE plan_id = ?", [.text(r.key)])
            try db.execute("DELETE FROM plan_wanted WHERE plan_id = ?", [.text(r.key)])
            journalCache[AlbumistID(r.key)] = nil
            headerCache[AlbumistID(r.key)] = nil
        }
        // Only plans that are part of this copy.
        let planIDs = Set(backup.plans.map(\.key))
        let pending = (backup.pendingFinalization ?? []).filter(planIDs.contains)
        if !pending.isEmpty {
            try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)",
                           [.text(Self.pendingFinalizationKey), try json(pending)])
        }
    }
}
