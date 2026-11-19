import Foundation
import SortlyCore

/// Local persistence for Albumist. Stores metadata and analysis results only – never image
/// data or copies of originals (prompt §13). All access is serialized by this actor.
public actor SortlyStore: PlanJournal {
    let db: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var hasFullTextSearch = false
    /// Counts the writes that can change a photo's place or its location (`setPlace`,
    /// `upsertAssets`, `removeAssets`, `resetAnalysis`): what is worked out from the places of
    /// all photos holds as long as it stays the same (their time zones, second review of P1-15).
    public private(set) var placesRevision = 0
    /// How often each read that goes over every photo (or every album or override) ran:
    /// `allAssets`, `places`, `results` of each kind, `loadInventory`, `overrides`. Tests count
    /// with it that a refresh of the overview reads each of them once (review P4-02).
    public private(set) var wholeLibraryReads: [String: Int] = [:]
    private func counted(_ read: String) { wholeLibraryReads[read, default: 0] += 1 }
    /// Rows written or deleted for the photos and the albums (`upsertAssets`, `removeAssets`,
    /// `saveInventory`). Tests count with it that a run without a change in the library writes
    /// nothing (review P4-03).
    public private(set) var libraryRowWrites = 0

    /// - Parameter url: database file; `nil` creates an in-memory store (tests, previews).
    public init(url: URL?) throws {
        db = try SQLiteDatabase(path: url?.path)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Dates are stored as exact Double seconds since the reference date, so values
        // round-trip bit-identically (milliseconds would truncate and break equality checks
        // such as plan fingerprints and override de-duplication).
        encoder.dateEncodingStrategy = .deferredToDate
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        // A stray infinity or NaN (a distance without a home, a score from Vision) must never
        // make a save throw: that ended the whole analysis run, every time.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        // A damaged database fails here, at the start, where the app offers "Neu aufbauen"
        // (the file is set aside, the decisions come back from the backup copy), instead of
        // in the middle of an analysis or a plan. Checked before migrating: a migration must
        // never build on a damaged file.
        if url != nil { try db.verifyIntegrity() }
        try Migrations.migrate(db)
        hasFullTextSearch = (try? db.query("SELECT 1 FROM sqlite_master WHERE name = 'text_fts'").isEmpty == false) ?? false
    }

    public var schemaVersion: Int { db.userVersion }

    // MARK: - Helpers

    /// Copies of the safety data taken so far (orders them for `SafetyBackupWriter`).
    var backupSequence = 0
    /// What the database holds of each plan saved by this store: the next save of that plan
    /// writes only what differs (see `insertPlan`).
    var journalCache: [SortlyID: (steps: [PlanStep], media: [String: [AssetID]])] = [:]
    /// The header row this store last wrote for each plan, and the ids written down for new
    /// albums and folders it holds: a save that finds exactly that row stored takes them from
    /// here instead of decoding it again (`storedNotedIDs`). A row written in another way (from
    /// inside a change, `noteCreated`) differs and is read in full.
    var headerCache: [SortlyID: (payload: Data, noted: ExecutionRecord)] = [:]
    func json<T: Encodable>(_ value: T) throws -> SQLValue { .blob(try encoder.encode(value)) }
    func decode<T: Decodable>(_ type: T.Type, _ value: SQLValue?) throws -> T? {
        guard let data = value?.data else { return nil }
        return try decoder.decode(type, from: data)
    }
    private static func date(_ d: Date?) -> SQLValue { d.map { .real($0.timeIntervalSince1970) } ?? .null }
    private static func text(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }

    // MARK: - Assets

    /// Inserts or updates asset metadata in one transaction. Returns ids whose metadata
    /// changed (new or modified), which drives incremental re-analysis (prompt §14.4).
    @discardableResult
    ///
    /// A snapshot without file details (`uniformTypeIdentifier == nil`, see
    /// `PhotoLibraryReading.fetchAssets`) keeps the stored type and RAW flag. When the image
    /// itself changed (edited, new size), its recognized text and content labels are dropped so
    /// they are read again; when its location changed or was removed, so is its place.
    public func upsertAssets(_ assets: [AssetSnapshot]) throws -> Set<AssetID> {
        var changed = Set<AssetID>()
        try db.transaction {
            for incoming in assets {
                var a = incoming
                let row = try db.query("""
                    SELECT fingerprint, subtypes, uti, latitude, longitude, modification_date, pixel_width, pixel_height
                    FROM assets WHERE id = ?
                    """, [.text(a.id.rawValue)]).first
                if let row, a.uniformTypeIdentifier == nil, let storedType = row["uti"]?.string {
                    a.uniformTypeIdentifier = storedType
                    let stored = MediaSubtypes(rawValue: UInt32(truncatingIfNeeded: row["subtypes"]?.int ?? 0))
                    if stored.contains(.raw) { a.subtypes.insert(.raw) }
                }
                let fingerprint = Self.fingerprint(a)
                if row?["fingerprint"]?.string == fingerprint { continue }
                changed.insert(a.id)
                if let row {
                    let id: SQLValue = .text(a.id.rawValue)
                    if row["latitude"]?.double != a.location?.latitude || row["longitude"]?.double != a.location?.longitude {
                        try db.execute("DELETE FROM asset_places WHERE asset_id = ?", [id])
                    }
                    if row["modification_date"]?.double != a.modificationDate?.timeIntervalSince1970
                        || row["pixel_width"]?.int != a.pixelWidth || row["pixel_height"]?.int != a.pixelHeight {
                        try db.execute("DELETE FROM analysis_results WHERE asset_id = ? AND kind IN ('content', 'text', 'labels')", [id])
                        try db.execute("DELETE FROM text_plain WHERE asset_id = ?", [id])
                        // Its labels went with the result (the upsert below keeps this column).
                        try db.execute("UPDATE assets SET labels_version = 0 WHERE id = ?", [id])
                    }
                }
                libraryRowWrites += 1
                try db.execute("""
                    INSERT INTO assets (id, kind, subtypes, creation_date, modification_date, latitude, longitude, location_accuracy,
                        pixel_width, pixel_height, duration, burst_id, is_favorite, original_filename, uti, fingerprint, analysis_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, subtypes = excluded.subtypes, creation_date = excluded.creation_date,
                        modification_date = excluded.modification_date, latitude = excluded.latitude, longitude = excluded.longitude,
                        location_accuracy = excluded.location_accuracy, pixel_width = excluded.pixel_width, pixel_height = excluded.pixel_height,
                        duration = excluded.duration, burst_id = excluded.burst_id, is_favorite = excluded.is_favorite,
                        original_filename = COALESCE(excluded.original_filename, assets.original_filename), uti = COALESCE(excluded.uti, assets.uti),
                        fingerprint = excluded.fingerprint, analysis_version = 0
                    """, [
                        .text(a.id.rawValue), .text(a.kind.rawValue), .integer(Int64(a.subtypes.rawValue)), Self.date(a.creationDate),
                        Self.date(a.modificationDate), a.location.map { .real($0.latitude) } ?? .null, a.location.map { .real($0.longitude) } ?? .null,
                        a.locationAccuracy.map { .real($0) } ?? .null, .integer(Int64(a.pixelWidth)), .integer(Int64(a.pixelHeight)),
                        .real(a.duration), Self.text(a.burstIdentifier), .integer(a.isFavorite ? 1 : 0), Self.text(a.originalFilename),
                        Self.text(a.uniformTypeIdentifier), .text(fingerprint),
                    ])
            }
        }
        if !changed.isEmpty { placesRevision += 1 }
        return changed
    }

    static func fingerprint(_ a: AssetSnapshot) -> String {
        StableHash.hex([
            a.kind.rawValue, String(a.subtypes.rawValue), String(a.creationDate?.timeIntervalSince1970 ?? -1),
            String(a.modificationDate?.timeIntervalSince1970 ?? -1), String(a.location?.latitude ?? 999), String(a.location?.longitude ?? 999),
            String(a.pixelWidth), String(a.pixelHeight), String(a.duration),
        ].joined(separator: "|"))
    }

    /// Removes assets that no longer exist in the library (and all their analysis results).
    public func removeAssets(notIn existing: Set<AssetID>) throws -> Int {
        let all = try db.query("SELECT id FROM assets").compactMap { $0["id"]?.string }
        let stale = all.filter { !existing.contains(AssetID($0)) }
        try db.transaction {
            for id in stale { try db.execute("DELETE FROM assets WHERE id = ?", [.text(id)]) }
        }
        libraryRowWrites += stale.count
        if !stale.isEmpty { placesRevision += 1 }
        return stale.count
    }

    /// Removes these assets (deleted from the library, or no longer readable) and all their
    /// analysis results, like `removeAssets(notIn:)`. Returns how many were stored.
    public func removeAssets(_ ids: Set<AssetID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var removed = 0
        try db.transaction {
            for id in ids.sorted() {
                guard try db.query("SELECT 1 AS x FROM assets WHERE id = ?", [.text(id.rawValue)]).isEmpty == false else { continue }
                try db.execute("DELETE FROM assets WHERE id = ?", [.text(id.rawValue)])
                removed += 1
            }
        }
        libraryRowWrites += removed
        if removed > 0 { placesRevision += 1 }
        return removed
    }

    /// Which of these assets are stored.
    public func storedAssets(among ids: Set<AssetID>) throws -> Set<AssetID> {
        Set(try ids.filter { id in
            try db.query("SELECT 1 AS x FROM assets WHERE id = ?", [.text(id.rawValue)]).isEmpty == false
        })
    }

    /// `assetsWithFileDetails` for these assets only (a read of the photos that changed).
    public func fileDetails(for ids: Set<AssetID>) throws -> [AssetID: Date] {
        var out: [AssetID: Date] = [:]
        for id in ids {
            guard let r = try db.query("SELECT modification_date FROM assets WHERE id = ? AND uti IS NOT NULL", [.text(id.rawValue)]).first else { continue }
            out[id] = r["modification_date"]?.double.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        }
        return out
    }

    /// Assets whose file details (name, type, RAW) are stored, with the modification date they
    /// were read at (`.distantPast` for none). The library reads the details again only for
    /// assets missing here or changed since, so a new or rebuilt database gets all of them.
    public func assetsWithFileDetails() throws -> [AssetID: Date] {
        var out: [AssetID: Date] = [:]
        for r in try db.query("SELECT id, modification_date FROM assets WHERE uti IS NOT NULL") {
            guard let id = r["id"]?.string else { continue }
            out[AssetID(id)] = r["modification_date"]?.double.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        }
        return out
    }

    public func assetCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM assets").first?["n"]?.int ?? 0
    }

    public func allAssets() throws -> [AssetSnapshot] {
        counted("allAssets")
        return try db.query("SELECT * FROM assets ORDER BY creation_date, id").map(Self.asset)
    }

    public func asset(_ id: AssetID) throws -> AssetSnapshot? {
        try db.query("SELECT * FROM assets WHERE id = ?", [.text(id.rawValue)]).first.map(Self.asset)
    }

    /// Assets whose analysis is older than `version` (new, changed or affected by a pipeline upgrade).
    /// Newest first. With `olderThan` (the last asset of the previous batch) the scan continues
    /// where it stopped instead of skipping every already-analyzed photo again: without it a
    /// first run over 100,000 photos spent about 18 s in this query alone.
    /// `within`: only photos taken in this time (a trial run over one year), `excluding` these
    /// (`span`).
    /// `labelsVersion`: also the photos whose image labels are older than this (asked for
    /// only while labels are wanted: "Themen" or "Dokumente" on). `nil`: labels are not wanted.
    public func assetsNeedingAnalysis(version: Int, labelsVersion: Int? = nil, limit: Int, olderThan last: AssetSnapshot? = nil,
                                      within range: Range<Date>? = nil, excluding excluded: Set<AssetID> = []) throws -> [AssetSnapshot] {
        var (filter, values) = Self.needingAnalysis(version: version, labelsVersion: labelsVersion)
        let span = try Self.span(range, excluding: excluded)
        filter += span.filter
        values += span.values
        if let last, let date = last.creationDate?.timeIntervalSince1970 {
            return try db.query("""
                SELECT * FROM assets WHERE \(filter)
                  AND (creation_date < ? OR (creation_date = ? AND id < ?))
                ORDER BY creation_date DESC, id DESC LIMIT ?
                """, values + [.real(date), .real(date), .text(last.id.rawValue), .integer(Int64(limit))]).map(Self.asset)
        }
        return try db.query("SELECT * FROM assets WHERE \(filter) ORDER BY creation_date DESC, id DESC LIMIT ?", values + [.integer(Int64(limit))]).map(Self.asset)
    }

    /// See `assetsNeedingAnalysis` (the same photos).
    public func countNeedingAnalysis(version: Int, labelsVersion: Int? = nil, within range: Range<Date>? = nil,
                                     excluding excluded: Set<AssetID> = []) throws -> Int {
        var (filter, values) = Self.needingAnalysis(version: version, labelsVersion: labelsVersion)
        let span = try Self.span(range, excluding: excluded)
        filter += span.filter
        values += span.values
        return try db.query("SELECT COUNT(*) AS n FROM assets WHERE \(filter)", values).first?["n"]?.int ?? 0
    }

    /// Of `countNeedingAnalysis(version:labelsVersion:within:excluding:)`: the photos analysed
    /// already (at least `version`) whose image labels are older than `labelsVersion`, the ones
    /// the image step gives only their labels. For the analysis card, which names this work apart
    /// from new photos; a photo given up as unreadable is counted here too (it gets a full look
    /// instead).
    public func countNeedingLabelsOnly(version: Int, labelsVersion: Int, within range: Range<Date>? = nil,
                                       excluding excluded: Set<AssetID> = []) throws -> Int {
        var filter = "analysis_version >= ? AND labels_version < ?"
        var values: [SQLValue] = [.integer(Int64(version)), .integer(Int64(labelsVersion))]
        let span = try Self.span(range, excluding: excluded)
        filter += span.filter
        values += span.values
        return try db.query("SELECT COUNT(*) AS n FROM assets WHERE \(filter)", values).first?["n"]?.int ?? 0
    }

    private static func needingAnalysis(version: Int, labelsVersion: Int?) -> (filter: String, values: [SQLValue]) {
        guard let labelsVersion else { return ("analysis_version < ?", [.integer(Int64(version))]) }
        return ("(analysis_version < ? OR labels_version < ?)", [.integer(Int64(version)), .integer(Int64(labelsVersion))])
    }

    /// The part of the library the image step of a trial run over one year works on, as SQL to
    /// add to a filter over the assets (`table`: their name in a join): photos taken in `range`,
    /// none of `excluded` (the photos in that time that are of another year on their own clock,
    /// review P1-15). The ids go in as one JSON array: one parameter for any number of them.
    private static func span(_ range: Range<Date>?, excluding excluded: Set<AssetID>, table: String? = nil) throws -> (filter: String, values: [SQLValue]) {
        let column = table.map { "\($0)." } ?? ""
        var filter = ""
        var values: [SQLValue] = []
        if let range {
            filter += " AND \(column)creation_date >= ? AND \(column)creation_date < ?"
            values += [.real(range.lowerBound.timeIntervalSince1970), .real(range.upperBound.timeIntervalSince1970)]
        }
        if !excluded.isEmpty {
            filter += " AND \(column)id NOT IN (SELECT value FROM json_each(?))"
            values.append(.text(String(decoding: try JSONEncoder().encode(excluded.map(\.rawValue).sorted()), as: UTF8.self)))
        }
        return (filter, values)
    }

    /// The results of one batch and the photos it is done with, in one transaction: one write
    /// per batch instead of one per photo, and a batch is either stored with its marks or not
    /// at all (a run ended in between does it again).
    /// `labelsVersion`: the photos in `done` also have their image labels (of this version).
    public func saveResults<T: Encodable>(_ results: [(AssetID, T)], kind: String, version: Int, markingAnalyzed done: [AssetID],
                                          labelsVersion: Int? = nil) throws {
        guard !results.isEmpty || !done.isEmpty else { return }
        try db.transaction {
            for (asset, value) in results {
                try db.execute("INSERT OR REPLACE INTO analysis_results (asset_id, kind, version, payload) VALUES (?, ?, ?, ?)", [
                    .text(asset.rawValue), .text(kind), .integer(Int64(version)), try json(value),
                ])
            }
            for id in done {
                if let labelsVersion {
                    try db.execute("UPDATE assets SET analysis_version = ?, labels_version = ? WHERE id = ?",
                                   [.integer(Int64(version)), .integer(Int64(labelsVersion)), .text(id.rawValue)])
                } else {
                    try db.execute("UPDATE assets SET analysis_version = ? WHERE id = ?", [.integer(Int64(version)), .text(id.rawValue)])
                }
            }
        }
    }

    /// Of `ids`, the photos whose analysis is current (at least `version`), with their result
    /// of `kind`: in the image step, the photos that only need their labels (`labelsVersion`).
    public func analyzedResults<T: Decodable>(_ type: T.Type, kind: String, version: Int, of ids: [AssetID]) throws -> [AssetID: T] {
        guard !ids.isEmpty else { return [:] }
        var out: [AssetID: T] = [:]
        // In chunks: SQLite allows a limited number of parameters per statement.
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = ids[start..<min(ids.count, start + 500)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try db.query("""
                SELECT r.asset_id, r.payload FROM analysis_results r JOIN assets a ON a.id = r.asset_id
                WHERE r.kind = ? AND a.analysis_version >= ? AND r.asset_id IN (\(marks))
                """, [.text(kind), .integer(Int64(version))] + chunk.map { .text($0.rawValue) })
            for r in rows {
                if let id = r["asset_id"]?.string, let v = try decode(T.self, r["payload"]) { out[AssetID(id)] = v }
            }
        }
        return out
    }

    /// Photos analysed already (at least `version`) whose image labels are older than
    /// `labelsVersion`: the ones "Themen" and "Dokumente" still wait for, counted on the overview
    /// (`DerivedLibraryStatus.labelsMissing`). Through `idx_assets_labels`: no rows once the labels
    /// are caught up (second review of the labels fix: every labelled photo was read at every
    /// refresh of the overview, 94 ms for 100,000 photos on the actor the analysis writes through).
    /// A photo given up as unreadable for its labels is marked and not among them.
    public func unlabelledAssets(version: Int, labelsVersion: Int) throws -> Set<AssetID> {
        Set(try db.query("SELECT id FROM assets WHERE labels_version < ? AND analysis_version >= ?",
                         [.integer(Int64(labelsVersion)), .integer(Int64(version))])
            .compactMap { $0["id"]?.string.map { AssetID($0) } })
    }

    /// Of `unlabelledAssets(version:labelsVersion:)`, the photos that have a result of `kind`:
    /// with the image step's failed tries for labels, the photos whose labels could not be read
    /// yet and wait for their retry. Through the results of that kind: usually none or a handful.
    public func unlabelledAssets(version: Int, labelsVersion: Int, withResult kind: String) throws -> Set<AssetID> {
        Set(try db.query("""
            SELECT a.id FROM analysis_results r JOIN assets a ON a.id = r.asset_id
            WHERE r.kind = ? AND a.labels_version < ? AND a.analysis_version >= ?
            """, [.text(kind), .integer(Int64(labelsVersion)), .integer(Int64(version))])
            .compactMap { $0["id"]?.string.map { AssetID($0) } })
    }

    /// Removes the results of `kind` of these photos.
    public func removeResults(kind: String, assets ids: [AssetID]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.execute("DELETE FROM analysis_results WHERE asset_id = ? AND kind = ?", [.text(id.rawValue), .text(kind)])
            }
        }
    }

    /// The stored bytes of one result, as written. Tests and diagnostics.
    public func rawResult(kind: String, asset: AssetID) throws -> Data? {
        try db.query("SELECT payload FROM analysis_results WHERE kind = ? AND asset_id = ?", [.text(kind), .text(asset.rawValue)]).first?["payload"]?.data
    }

    /// The labels version of each photo (0: no labels computed). Tests and diagnostics.
    public func labelsVersions() throws -> [AssetID: Int] {
        var out: [AssetID: Int] = [:]
        for r in try db.query("SELECT id, labels_version FROM assets") {
            if let id = r["id"]?.string { out[AssetID(id)] = r["labels_version"]?.int ?? 0 }
        }
        return out
    }

    public func markAnalyzed(_ ids: [AssetID], version: Int) throws {
        try db.transaction {
            for id in ids { try db.execute("UPDATE assets SET analysis_version = ? WHERE id = ?", [.integer(Int64(version)), .text(id.rawValue)]) }
        }
    }

    static func asset(_ r: SQLRow) -> AssetSnapshot {
        let lat = r["latitude"]?.double, lon = r["longitude"]?.double
        return AssetSnapshot(
            id: AssetID(r["id"]?.string ?? ""),
            kind: MediaKind(rawValue: r["kind"]?.string ?? "") ?? .unknown,
            subtypes: MediaSubtypes(rawValue: UInt32(r["subtypes"]?.int ?? 0)),
            creationDate: r["creation_date"]?.double.map { Date(timeIntervalSince1970: $0) },
            modificationDate: r["modification_date"]?.double.map { Date(timeIntervalSince1970: $0) },
            location: (lat != nil && lon != nil) ? GeoCoordinate(latitude: lat!, longitude: lon!) : nil,
            locationAccuracy: r["location_accuracy"]?.double,
            pixelWidth: r["pixel_width"]?.int ?? 0,
            pixelHeight: r["pixel_height"]?.int ?? 0,
            duration: r["duration"]?.double ?? 0,
            burstIdentifier: r["burst_id"]?.string,
            isFavorite: r["is_favorite"]?.int == 1,
            originalFilename: r["original_filename"]?.string,
            uniformTypeIdentifier: r["uti"]?.string
        )
    }

    // MARK: - Album inventory

    /// Replaces the stored inventory snapshot (albums, folders, memberships). Writes only the
    /// albums and folders that differ from the stored ones: a library read again without a
    /// change wrote every album and every membership again (review P4-03).
    public func saveInventory(_ inventory: CollectionInventory) throws {
        let stored = try storedInventory()
        let changed = inventory.collections.values.filter { stored[$0.id] != $0 }.sorted(by: { $0.id < $1.id })
        let gone = stored.collections.keys.filter { inventory[$0] == nil }.sorted()
        guard !changed.isEmpty || !gone.isEmpty else { return }
        try db.transaction {
            for id in gone + changed.map(\.id) {
                let raw: SQLValue = .text(id.rawValue)
                libraryRowWrites += (stored[id]?.assetIDs.count ?? 0) + (stored[id] == nil ? 0 : 1)
                try db.execute("DELETE FROM collection_members WHERE collection_id = ?", [raw])
                try db.execute("DELETE FROM collections WHERE id = ?", [raw])
            }
            for c in changed {
                try db.execute("INSERT INTO collections (id, title, kind, capabilities, parent_id, child_ids) VALUES (?, ?, ?, ?, ?, ?)", [
                    .text(c.id.rawValue), .text(c.title), .text(c.kind.rawValue), .integer(Int64(c.capabilities.rawValue)),
                    Self.text(c.parentID?.rawValue), try json(c.childIDs),
                ])
                for a in c.assetIDs.sorted() {
                    try db.execute("INSERT INTO collection_members (collection_id, asset_id) VALUES (?, ?)", [.text(c.id.rawValue), .text(a.rawValue)])
                }
                libraryRowWrites += 1 + c.assetIDs.count
            }
        }
    }

    public func loadInventory() throws -> CollectionInventory {
        counted("loadInventory")
        return try storedInventory()
    }

    private func storedInventory() throws -> CollectionInventory {
        var members: [String: Set<AssetID>] = [:]
        for row in try db.query("SELECT collection_id, asset_id FROM collection_members") {
            if let c = row["collection_id"]?.string, let a = row["asset_id"]?.string { members[c, default: []].insert(AssetID(a)) }
        }
        let collections = try db.query("SELECT * FROM collections").map { r -> CollectionSnapshot in
            let id = r["id"]?.string ?? ""
            return CollectionSnapshot(
                id: CollectionID(id),
                title: r["title"]?.string ?? "",
                kind: CollectionKind(rawValue: r["kind"]?.string ?? "") ?? .restrictedAlbum,
                capabilities: CollectionCapabilities(rawValue: UInt8(r["capabilities"]?.int ?? 0)),
                parentID: r["parent_id"]?.string.map { CollectionID($0) },
                assetIDs: members[id] ?? [],
                childIDs: (try? decode([CollectionID].self, r["child_ids"])) ?? []
            )
        }
        return CollectionInventory(collections)
    }

    // MARK: - Places (geocoding cache)

    /// Cached reverse-geocoding result for a geographic cell (prompt §4.1: a resolved place
    /// is not requested again for every photo).
    public func cachedPlace(cell: GeoCell) throws -> PlaceComponents? {
        try decode(PlaceComponents.self, db.query("SELECT components FROM place_cache WHERE cell = ?", [.text(cell.description)]).first?["components"])
    }

    public func cachePlace(_ components: PlaceComponents, cell: GeoCell, resolvedAt: Date = Date()) throws {
        try db.execute("INSERT OR REPLACE INTO place_cache (cell, components, resolved_at) VALUES (?, ?, ?)", [
            .text(cell.description), try json(components), Self.date(resolvedAt),
        ])
    }

    public func placeCacheCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM place_cache").first?["n"]?.int ?? 0
    }

    public func setPlace(_ place: ResolvedPlace?, for asset: AssetID) throws {
        placesRevision += 1
        if let place {
            try db.execute("INSERT OR REPLACE INTO asset_places (asset_id, components, source, resolved_at, precision_m) VALUES (?, ?, ?, ?, ?)", [
                .text(asset.rawValue), try json(place.components), .text(place.source.rawValue), Self.date(place.resolvedAt),
                place.precisionMeters.map { .real($0) } ?? .null,
            ])
        } else {
            try db.execute("DELETE FROM asset_places WHERE asset_id = ?", [.text(asset.rawValue)])
        }
    }

    /// Writes many places in one transaction (geocoding results arrive in batches).
    public func setPlaces(_ places: [AssetID: ResolvedPlace]) throws {
        try db.transaction {
            for (asset, place) in places { try setPlace(place, for: asset) }
        }
    }

    public func places() throws -> [AssetID: ResolvedPlace] {
        counted("places")
        var result: [AssetID: ResolvedPlace] = [:]
        for r in try db.query("SELECT * FROM asset_places") {
            guard let id = r["asset_id"]?.string, let c = try decode(PlaceComponents.self, r["components"]),
                  let source = PlaceSource(rawValue: r["source"]?.string ?? "") else { continue }
            result[AssetID(id)] = ResolvedPlace(
                components: c, source: source, resolvedAt: Date(timeIntervalSince1970: r["resolved_at"]?.double ?? 0),
                precisionMeters: r["precision_m"]?.double
            )
        }
        return result
    }

    // MARK: - Generic analysis results

    /// Stores a versioned analysis result per asset and kind ("vision", "ocr", "document", ...).
    public func saveResult<T: Encodable>(_ value: T, kind: String, asset: AssetID, version: Int) throws {
        try db.execute("INSERT OR REPLACE INTO analysis_results (asset_id, kind, version, payload) VALUES (?, ?, ?, ?)", [
            .text(asset.rawValue), .text(kind), .integer(Int64(version)), try json(value),
        ])
    }

    public func results<T: Decodable>(_ type: T.Type, kind: String, minimumVersion: Int = 0) throws -> [AssetID: T] {
        counted("results." + kind)
        var out: [AssetID: T] = [:]
        for r in try db.query("SELECT asset_id, payload FROM analysis_results WHERE kind = ? AND version >= ?", [.text(kind), .integer(Int64(minimumVersion))]) {
            if let id = r["asset_id"]?.string, let v = try decode(T.self, r["payload"]) { out[AssetID(id)] = v }
        }
        return out
    }

    /// Results of `kind` (of at least `version`) for assets whose analysis is older than
    /// `version`: labels a run saved before it could mark the photo (the app was ended in
    /// between, or only the place or date of the photo changed since), and photos that could
    /// not be read yet. Usually a handful, where `results(_:kind:)` reads every photo's result.
    public func pendingResults<T: Decodable>(_ type: T.Type, kind: String, version: Int, within range: Range<Date>? = nil,
                                             excluding excluded: Set<AssetID> = []) throws -> [AssetID: T] {
        var sql = """
            SELECT r.asset_id, r.payload FROM analysis_results r JOIN assets a ON a.id = r.asset_id
            WHERE r.kind = ? AND r.version >= ? AND a.analysis_version < ?
            """
        var values: [SQLValue] = [.text(kind), .integer(Int64(version)), .integer(Int64(version))]
        let span = try Self.span(range, excluding: excluded, table: "a")
        sql += span.filter
        values += span.values
        var out: [AssetID: T] = [:]
        for r in try db.query(sql, values) {
            if let id = r["asset_id"]?.string, let v = try decode(T.self, r["payload"]) { out[AssetID(id)] = v }
        }
        return out
    }

    public func result<T: Decodable>(_ type: T.Type, kind: String, asset: AssetID) throws -> T? {
        try decode(T.self, db.query("SELECT payload FROM analysis_results WHERE kind = ? AND asset_id = ?", [.text(kind), .text(asset.rawValue)]).first?["payload"])
    }

    // MARK: - Recognized text (search)

    public func indexText(_ text: String, for asset: AssetID) throws {
        // The full-text index follows through triggers (see Migrations.ftsSQL).
        try db.execute("""
            INSERT INTO text_plain (asset_id, content) VALUES (?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET content = excluded.content
            """, [.text(asset.rawValue), .text(text)])
    }

    /// Full-text search over recognized text. Uses FTS5 when available, LIKE otherwise.
    public func searchText(_ query: String, limit: Int = 500) throws -> [AssetID] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        if hasFullTextSearch {
            let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }.joined(separator: " AND ")
            return try db.query("""
                SELECT p.asset_id FROM text_fts JOIN text_plain p ON p.id = text_fts.rowid
                WHERE text_fts MATCH ? LIMIT ?
                """, [.text(match), .integer(Int64(limit))])
                .compactMap { $0["asset_id"]?.string.map { AssetID($0) } }
        }
        let clause = terms.map { _ in "content LIKE ?" }.joined(separator: " AND ")
        return try db.query("SELECT asset_id FROM text_plain WHERE \(clause) LIMIT ?", terms.map { .text("%\($0)%") } + [.integer(Int64(limit))])
            .compactMap { $0["asset_id"]?.string.map { AssetID($0) } }
    }

    /// Drops an asset's text from the search (its new text is empty or was withheld).
    public func removeText(for asset: AssetID) throws {
        try db.execute("DELETE FROM text_plain WHERE asset_id = ?", [.text(asset.rawValue)])
    }

    /// After stored text was removed or masked: the full-text index merges its segments
    /// ("optimize"), so the entries of the old wording are gone and not only marked deleted,
    /// and the write-ahead log is written back and emptied. Freed pages are overwritten with
    /// zeros (`secure_delete`, `SQLiteDatabase`). Privacy rule: such text is never stored.
    public func purgeDeletedText() throws {
        if hasFullTextSearch { try db.execute("INSERT INTO text_fts (text_fts) VALUES ('optimize')") }
        try db.checkpoint()
    }

    /// Whether the connection overwrites deleted content (`secure_delete`); for the tests.
    var securesDeletes: Bool { db.securesDeletes }

    public func recognizedText(for asset: AssetID) throws -> String? {
        try db.query("SELECT content FROM text_plain WHERE asset_id = ?", [.text(asset.rawValue)]).first?["content"]?.string
    }

    // MARK: - Progress (pause / resume)

    public func setProgress(stage: String, cursor: String?, version: Int, completed: Bool) throws {
        try db.execute("INSERT OR REPLACE INTO analysis_progress (stage, cursor, version, completed, updated_at) VALUES (?, ?, ?, ?, ?)", [
            .text(stage), Self.text(cursor), .integer(Int64(version)), .integer(completed ? 1 : 0), Self.date(Date()),
        ])
    }

    public struct StageProgress: Sendable, Hashable {
        public var cursor: String?
        public var version: Int
        public var completed: Bool
    }

    public func progress(stage: String) throws -> StageProgress? {
        guard let r = try db.query("SELECT * FROM analysis_progress WHERE stage = ?", [.text(stage)]).first else { return nil }
        return StageProgress(cursor: r["cursor"]?.string, version: r["version"]?.int ?? 0, completed: r["completed"]?.int == 1)
    }

    // MARK: - Overrides, rules, managed albums, plans, settings

    public func addOverride(_ o: UserOverride) throws {
        try db.durably { try insertOverride(o) }
    }

    private func insertOverride(_ o: UserOverride) throws {
        try db.execute("INSERT OR REPLACE INTO overrides (id, payload, created_at) VALUES (?, ?, ?)", [.text(o.id.rawValue), try json(o), Self.date(o.createdAt)])
    }

    /// Stores what a reconciliation found (the user's manual changes as overrides, and the
    /// new last-known state of Albumist's albums) in one transaction: either both are saved or
    /// neither, so a manual change is never marked as seen without its override.
    /// - Parameter expected: the records the reconciliation started from. When the stored ones
    ///   are different by now (a plan finished and stored its albums while the slow comparison
    ///   with Photos ran, plugin review N7), nothing is written: the older list would overwrite
    ///   the plan's fresh records. Nil writes in any case.
    /// - Returns: whether the reconciliation was stored.
    @discardableResult
    public func applyReconciliation(overrides: [UserOverride], managedAlbums: [ManagedAlbumState],
                                    expected: [ManagedAlbumState]? = nil) throws -> Bool {
        try db.durably {
            try db.transaction {
                if let expected, try self.managedAlbums() != expected { return false }
                for o in overrides { try insertOverride(o) }
                try replaceManagedAlbums(managedAlbums)
                return true
            }
        }
    }

    /// Everything that follows a finished plan, in one transaction: the plan (with its
    /// finalization time), Albumist's albums and further values (decisions, the list of plans
    /// still to finalize). A crash leaves either all of it or none.
    public func finalize(_ plan: ChangePlan, managedAlbums: [ManagedAlbumState], values: [String: any Encodable & Sendable]) throws {
        try journaling([plan.id]) {
            try db.durably {
                try db.transaction {
                    try insertPlan(plan)
                    try replaceManagedAlbums(managedAlbums)
                    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                        try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(key), try json(value)])
                    }
                }
            }
        }
    }

    /// "Ignorieren" for several photos in one transaction. A photo that is already ignored
    /// keeps its one override (no duplicates). Returns the photos that were newly ignored,
    /// so "Widerrufen" right after the action takes back exactly those and not a photo the
    /// user had ignored earlier.
    @discardableResult
    public func ignoreAssets(_ ids: [AssetID], at date: Date = Date()) throws -> [AssetID] {
        try db.durably {
            try db.transaction {
                var ignored = Set(try overrides().compactMap(\.ignoredAsset))
                var added: [AssetID] = []
                for id in ids where !ignored.contains(id) {
                    try insertOverride(UserOverride(scope: .asset(id), decision: .ignoreAsset, createdAt: date))
                    ignored.insert(id)
                    added.append(id)
                }
                return added
            }
        }
    }

    /// "Nicht mehr ignorieren": removes every "ignore" override of these photos (also
    /// duplicates written by older versions) in one transaction; other decisions about the
    /// same photos stay. Returns how many photos were ignored before.
    @discardableResult
    public func unignoreAssets(_ ids: [AssetID]) throws -> Int {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return 0 }
        return try db.durably {
            try db.transaction {
                var restored: Set<AssetID> = []
                for o in try overrides() {
                    guard let id = o.ignoredAsset, wanted.contains(id) else { continue }
                    try db.execute("DELETE FROM overrides WHERE id = ?", [.text(o.id.rawValue)])
                    restored.insert(id)
                }
                return restored.count
            }
        }
    }

    /// Photos the user ignored, for the "Ignoriert" area and its way back.
    public func ignoredAssets() throws -> Set<AssetID> {
        Set(try overrides().compactMap(\.ignoredAsset))
    }

    public func removeOverride(_ id: SortlyID) throws {
        try db.execute("DELETE FROM overrides WHERE id = ?", [.text(id.rawValue)])
    }

    public func overrides() throws -> [UserOverride] {
        counted("overrides")
        return try db.query("SELECT payload FROM overrides ORDER BY created_at").compactMap { try decode(UserOverride.self, $0["payload"]) }
    }

    /// Saves a rule as a new version. Older versions stay for traceability.
    public func saveRule(_ rule: OrganizationRule) throws {
        try db.execute("INSERT OR REPLACE INTO rules (id, version, payload, updated_at) VALUES (?, ?, ?, ?)", [
            .text(rule.id.rawValue), .integer(Int64(rule.version)), try json(rule), Self.date(rule.updatedAt),
        ])
    }

    public func currentRules() throws -> [OrganizationRule] {
        try db.query("""
            SELECT r.payload FROM rules r
            JOIN (SELECT id, MAX(version) AS v FROM rules GROUP BY id) latest ON latest.id = r.id AND latest.v = r.version
            ORDER BY r.id
            """).compactMap { try decode(OrganizationRule.self, $0["payload"]) }
    }

    public func ruleHistory(_ id: SortlyID) throws -> [OrganizationRule] {
        try db.query("SELECT payload FROM rules WHERE id = ? ORDER BY version", [.text(id.rawValue)]).compactMap { try decode(OrganizationRule.self, $0["payload"]) }
    }

    public func saveManagedAlbums(_ states: [ManagedAlbumState]) throws {
        try db.durably { try db.transaction { try replaceManagedAlbums(states) } }
    }

    private func replaceManagedAlbums(_ states: [ManagedAlbumState]) throws {
        try db.execute("DELETE FROM managed_albums")
        for s in states {
            try db.execute("INSERT INTO managed_albums (album_id, source_id, payload) VALUES (?, ?, ?)", [.text(s.albumID.rawValue), .text(s.sourceID.rawValue), try json(s)])
        }
    }

    public func managedAlbums() throws -> [ManagedAlbumState] {
        try db.query("SELECT payload FROM managed_albums ORDER BY album_id").compactMap { try decode(ManagedAlbumState.self, $0["payload"]) }
    }

    /// The execution journal: on disk before the library is touched (synchronous = FULL).
    public func save(_ plan: ChangePlan) throws {
        try journaling([plan.id]) { try db.durably { try db.transaction { try insertPlan(plan) } } }
    }

    /// Several plans in one transaction (an interrupted plan and the undo that replaces it).
    public func save(_ plans: [ChangePlan]) throws {
        try journaling(plans.map(\.id)) { try db.durably { try db.transaction { for plan in plans { try insertPlan(plan) } } } }
    }

    /// The id Photos gave a new album or folder of the plan, written down from inside the
    /// change that creates it, before Photos stores it (review P2-01): added to the plan as it
    /// is stored, in one durable transaction, so a run that stopped waiting meanwhile (Photos
    /// answered late) loses nothing it wrote since. `async` like the requirement, so this, not
    /// the protocol's fallback (which replaces the stored plan), is what the executor calls.
    /// Only the plan's header row is read and written (its steps and media stay as they are):
    /// one per new album or folder, so a plan of hundreds of albums stays quick (Linux load
    /// test 28 s instead of under 20 s when the whole plan was read and written here).
    public func noteCreated(_ id: CollectionID, key: String, in plan: ChangePlan) async throws {
        try journaling([plan.id]) {
            try db.durably {
                try db.transaction {
                    let row = SQLValue.text(plan.id.rawValue)
                    guard var header = try decode(ChangePlan.self, db.query("SELECT payload FROM plans WHERE id = ?", [row]).first?["payload"]) else {
                        // Not stored yet: the plan as the run knows it, with the id.
                        var noted = plan
                        if noted.record == nil { noted.record = ExecutionRecord() }
                        noted.record?.noteRequested(id, key: key)
                        try insertPlan(noted)
                        return
                    }
                    if header.record == nil { header.record = ExecutionRecord() }
                    guard header.record?.maybeCreated[key] != id else { return }
                    header.record?.noteRequested(id, key: key)
                    if header.steps.isEmpty && header.record?.media.isEmpty != false {
                        try db.execute("UPDATE plans SET payload = ? WHERE id = ?", [try json(header), row])
                    } else if var stored = try self.plan(plan.id) {
                        // Saved by a version before the step-by-step journal: written in full.
                        if stored.record == nil { stored.record = ExecutionRecord() }
                        stored.record?.noteRequested(id, key: key)
                        try insertPlan(stored)
                    }
                }
            }
        }
    }

    /// The ids written down for the new albums and folders of plan `id` as it is stored, read
    /// from its header row only (`plans.payload`: the record without media), so every save can
    /// afford it (second review of P2-01, S1).
    func storedNotedIDs(_ id: SortlyID) throws -> ExecutionRecord? {
        guard let payload = try db.query("SELECT payload FROM plans WHERE id = ?", [.text(id.rawValue)]).first?["payload"]?.data else { return nil }
        if let cached = headerCache[id], cached.payload == payload { return cached.noted }
        guard let record = try decoder.decode(NotedHeader.self, from: payload).record else { return nil }
        var result = ExecutionRecord()
        result.maybeCreated = record.maybeCreated ?? [:]
        result.maybeCreatedAt = record.maybeCreatedAt ?? [:]
        result.earlierMaybeCreated = record.earlierMaybeCreated ?? []
        return result
    }

    /// The part of `record` that `storedNotedIDs` reads.
    static func notedPart(_ record: ExecutionRecord?) -> ExecutionRecord {
        var noted = ExecutionRecord()
        noted.maybeCreated = record?.maybeCreated ?? [:]
        noted.maybeCreatedAt = record?.maybeCreatedAt ?? [:]
        noted.earlierMaybeCreated = record?.earlierMaybeCreated ?? []
        return noted
    }

    /// The part of a stored plan header `storedNotedIDs` reads.
    private struct NotedHeader: Decodable {
        struct Record: Decodable {
            var maybeCreated: [String: CollectionID]?
            var maybeCreatedAt: [String: Date]?
            var earlierMaybeCreated: [CollectionID]?
        }
        var record: Record?
    }

    /// `plan` with the ids written down for its new albums and folders as stored
    /// (`ChangePlanStoring.withNotedIDs`): an id written from inside a change Photos ran after the
    /// run stopped waiting is in the stored plan, not in the copy the app holds (S1).
    public func withNotedIDs(_ plan: ChangePlan) async throws -> ChangePlan {
        var merged = plan
        merged.takeNotedIDs(from: try storedNotedIDs(plan.id))
        return merged
    }

    /// If a write fails (and its transaction is rolled back), what is known to be on disk for
    /// these plans is forgotten: the next save writes them in full again.
    func journaling(_ ids: [SortlyID], _ write: () throws -> Void) throws {
        do {
            try write()
        } catch {
            for id in ids { journalCache[id] = nil; headerCache[id] = nil }
            throw error
        }
    }

    /// The plan without its steps and media, its steps one row each, and the media of each
    /// step one row each (audit 2, 5.3). Only what changed since the last save of this plan
    /// is written: after a step that is the plan header, that step and its media.
    ///
    /// The ids written down for new albums and folders in the plan as stored are kept (S1):
    /// they may have been written from inside a change after the copy being saved was taken
    /// (`noteCreated`), and are never lost by a save of that copy (`ChangePlan.takeNotedIDs`).
    func insertPlan(_ input: ChangePlan) throws {
        var plan = input
        plan.takeNotedIDs(from: try storedNotedIDs(plan.id))
        var header = plan
        header.steps = []
        header.record?.media = [:]
        let payload = try encoder.encode(header)
        try db.execute("INSERT OR REPLACE INTO plans (id, status, created_at, payload) VALUES (?, ?, ?, ?)", [
            .text(plan.id.rawValue), .text(plan.status.rawValue), Self.date(plan.createdAt), .blob(payload),
        ])
        headerCache[plan.id] = (payload, Self.notedPart(plan.record))
        let id = SQLValue.text(plan.id.rawValue)
        let known = journalCache[plan.id]
        if let known, known.steps.count == plan.steps.count {
            for (index, step) in plan.steps.enumerated() where step != known.steps[index] {
                try db.execute("INSERT OR REPLACE INTO plan_steps (plan_id, idx, payload) VALUES (?, ?, ?)", [id, .integer(Int64(index)), try json(step)])
            }
        } else {
            try db.execute("DELETE FROM plan_steps WHERE plan_id = ?", [id])
            for (index, step) in plan.steps.enumerated() {
                try db.execute("INSERT INTO plan_steps (plan_id, idx, payload) VALUES (?, ?, ?)", [id, .integer(Int64(index)), try json(step)])
            }
        }
        let media = plan.record?.media ?? [:]
        if let known {
            for (step, assets) in media where known.media[step] != assets {
                try db.execute("INSERT OR REPLACE INTO plan_media (plan_id, step_id, payload) VALUES (?, ?, ?)", [id, .text(step), try json(assets)])
            }
            for step in known.media.keys where media[step] == nil {
                try db.execute("DELETE FROM plan_media WHERE plan_id = ? AND step_id = ?", [id, .text(step)])
            }
        } else {
            try db.execute("DELETE FROM plan_media WHERE plan_id = ?", [id])
            for (step, assets) in media.sorted(by: { $0.key < $1.key }) {
                try db.execute("INSERT INTO plan_media (plan_id, step_id, payload) VALUES (?, ?, ?)", [id, .text(step), try json(assets)])
            }
        }
        journalCache[plan.id] = (plan.steps, media)
    }

    /// A plan from its row: the header with its steps and media put back. Plans saved by
    /// versions before the step-by-step journal carry everything in the payload.
    func loadPlan(_ payload: SQLValue?) throws -> ChangePlan? {
        guard var plan = try decode(ChangePlan.self, payload) else { return nil }
        let id = SQLValue.text(plan.id.rawValue)
        let steps = try db.query("SELECT payload FROM plan_steps WHERE plan_id = ? ORDER BY idx", [id])
        if !steps.isEmpty {
            plan.steps = try steps.compactMap { try decode(PlanStep.self, $0["payload"]) }
        }
        let media = try db.query("SELECT step_id, payload FROM plan_media WHERE plan_id = ?", [id])
        if !media.isEmpty {
            if plan.record == nil { plan.record = ExecutionRecord() }
            for row in media {
                if let step = row["step_id"]?.string, let assets = try decode([AssetID].self, row["payload"]) {
                    plan.record?.media[step] = assets
                }
            }
        }
        return plan
    }

    public func plan(_ id: SortlyID) throws -> ChangePlan? {
        try loadPlan(db.query("SELECT payload FROM plans WHERE id = ?", [.text(id.rawValue)]).first?["payload"])
    }

    /// Plans that were interrupted and must be resumed (Scenario J).
    public func unfinishedPlans() throws -> [ChangePlan] {
        try db.query("SELECT payload FROM plans WHERE status IN ('confirmed', 'running') ORDER BY created_at")
            .compactMap { try loadPlan($0["payload"]) }
    }

    /// The plan offered to continue, take back or keep: the latest unfinished one (one at a
    /// time, plugin review K2). The app reads it again after every run and every way out, so a
    /// plan that fails half way in the same session is offered too, and once one is settled
    /// the next one is (review of 6c6ef79).
    public func openInterruptedPlan() throws -> ChangePlan? {
        try unfinishedPlans().last
    }

    /// Plans that finished but whose results are not stored yet (on the app's list of plans to
    /// finalize). They are finalized at the next launch, and before an undo of them is planned.
    public func plansAwaitingFinalization() throws -> [ChangePlan] {
        let pending = try value([SortlyID].self, forKey: Self.pendingFinalizationKey) ?? []
        return try pending.compactMap { id in
            guard let plan = try plan(id), plan.finalizedAt == nil,
                  plan.status == .completed || plan.status == .completedWithErrors else { return nil }
            return plan
        }
    }

    /// Whether this plan finished but its results are not stored yet.
    public func awaitsFinalization(_ id: SortlyID) throws -> Bool {
        try plansAwaitingFinalization().contains { $0.id == id }
    }

    /// Albums and folders that Albumist's own plans may still be changing (plugin review W2):
    /// those of every plan that is unfinished (cut off, offered to continue or take back), and
    /// of every plan that finished but whose results are not stored yet. A difference there may
    /// be Albumist's own doing, not the user's: the album check leaves these albums alone until
    /// the plan is settled (see `ManagedAlbumTracker.reconcile`), so an undo cut off during its
    /// finalization never turns into "deleted by you", whichever runs first at launch.
    public func collectionsInFlight() throws -> Set<CollectionID> {
        var result = Set<CollectionID>()
        for plan in try unfinishedPlans() { result.formUnion(plan.touchedCollections) }
        for plan in try plansAwaitingFinalization() {
            result.formUnion(plan.touchedCollections)
        }
        return result
    }

    /// One page of finished plans, newest first.
    public func planHistory(limit: Int = 50, offset: Int = 0) throws -> [ChangePlan] {
        try db.query("SELECT payload FROM plans WHERE status IN ('completed', 'completedWithErrors') ORDER BY created_at DESC LIMIT ? OFFSET ?",
                     [.integer(Int64(limit)), .integer(Int64(offset))])
            .compactMap { try loadPlan($0["payload"]) }
    }

    /// Of the latest `limit` finished plans, the albums and folders each asked Photos for whose
    /// request got no answer and that may land next to the one the plan settled on
    /// (`ExecutionRecord.mayStillLand`): read from the plans' headers only, without their steps
    /// (round-3 review of the PhotoKit limits, L3).
    public func lateCreates(limit: Int = 50) throws -> [(plan: SortlyID, ids: [CollectionID])] {
        struct Header: Decodable {
            var id: SortlyID
            var resolvedKeys: [String: CollectionID]?
            var record: ExecutionRecord?
        }
        return try db.query("SELECT payload FROM plans WHERE status IN ('completed', 'completedWithErrors') ORDER BY created_at DESC LIMIT ?",
                            [.integer(Int64(limit))])
            .compactMap { row -> (plan: SortlyID, ids: [CollectionID])? in
                guard let header = try decode(Header.self, row["payload"]),
                      let ids = header.record?.mayStillLand(resolved: header.resolvedKeys ?? [:]), !ids.isEmpty else { return nil }
                return (header.id, ids)
            }
    }

    /// The finished undo plans that took back `id`, newest first (for the change receipt).
    public func reverts(of id: SortlyID) throws -> [ChangePlan] {
        struct Header: Decodable { var reverts: SortlyID? }
        return try db.query("SELECT payload FROM plans WHERE status IN ('completed', 'completedWithErrors') ORDER BY created_at DESC")
            .compactMap { row -> ChangePlan? in
                guard try decode(Header.self, row["payload"])?.reverts == id else { return nil }
                return try loadPlan(row["payload"])
            }
    }

    /// Plans that a completed undo took back, over the whole journal (not one page of it).
    public func undoneTargets() throws -> Set<SortlyID> {
        struct Header: Decodable { var reverts: SortlyID? }
        return Set(try db.query("SELECT payload FROM plans WHERE status = 'completed'")
            .compactMap { try decode(Header.self, $0["payload"])?.reverts })
    }

    /// Several values in one transaction: a crash or an error leaves all of them or none.
    /// `removing`: keys deleted in the same transaction. `afterEach` (tests only) runs inside
    /// the transaction after each value, in key order; throwing there rolls everything back,
    /// like the app being ended half way.
    public func setValues(_ values: [String: any Encodable & Sendable], removing: Set<String> = [],
                          afterEach: (@Sendable (String) throws -> Void)? = nil) throws {
        try db.durably {
            try db.transaction {
                for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                    try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(key), try json(value)])
                    try afterEach?(key)
                }
                for key in removing.sorted() where values[key] == nil {
                    try db.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
                }
            }
        }
    }

    public func setValue<T: Encodable>(_ value: T, forKey key: String) throws {
        try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(key), try json(value)])
    }

    public func removeValue(forKey key: String) throws {
        try db.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
    }

    public func value<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try decode(T.self, db.query("SELECT payload FROM settings WHERE key = ?", [.text(key)]).first?["payload"])
    }

    /// A value an earlier version may have stored without the fields added since: those come
    /// from `defaults` (see `StoredDefaults`). For the user's settings and decisions.
    public func value<T: Codable>(_ type: T.Type, forKey key: String, defaults: T) throws -> T? {
        guard let data = try db.query("SELECT payload FROM settings WHERE key = ?", [.text(key)]).first?["payload"]?.data else { return nil }
        return try StoredDefaults.decode(T.self, from: data, defaults: defaults, encoder: encoder, decoder: decoder)
    }

    // MARK: - Identity

    /// Not part of the safety copy (`keptValues`), not removed by a reset of the analysis.
    static let identityKey = "identity.database"

    /// A stamp made the first time this database is asked for it. What is kept outside the
    /// database belongs to it only with the same stamp: the analysis marker lives in
    /// UserDefaults, which a device backup restores, while the database folder is excluded
    /// from backup (review of 9f0bc40: after a restore or on a new iPhone an empty database met
    /// a stale "64 %"). `isNew`: the stamp was made just now.
    public func identity() throws -> (id: String, isNew: Bool) {
        if let id = try value(String.self, forKey: Self.identityKey) { return (id, false) }
        let id = UUID().uuidString
        try setValue(id, forKey: Self.identityKey)
        return (id, true)
    }

    // MARK: - Reset

    /// Deletes all local analysis data. Never touches the photo library (prompt §11).
    /// User decisions (overrides, rules, managed albums, plan history) are kept unless
    /// `includingDecisions` is true.
    public func resetAnalysis(includingDecisions: Bool = false) throws {
        placesRevision += 1
        try db.transaction {
            for table in ["analysis_results", "asset_places", "place_cache", "analysis_progress", "text_plain"] {
                try db.execute("DELETE FROM \(table)")
            }
            try db.execute("UPDATE assets SET analysis_version = 0, labels_version = 0")
            // Results computed from the analysis (trips, places, groups, suggestions) go too,
            // otherwise the app would keep showing them until the next run finished.
            try db.execute("DELETE FROM settings WHERE key LIKE 'analysis.%'")
            if includingDecisions {
                for table in ["overrides", "rules", "managed_albums", "plans", "plan_steps", "plan_media"] {
                    try db.execute("DELETE FROM \(table)")
                }
                // The database stays the same database: its stamp stays.
                try db.execute("DELETE FROM settings WHERE key NOT LIKE 'identity.%'")
                journalCache = [:]
                headerCache = [:]
            }
        }
    }
}

extension SortlyStore: PlaceCaching {}
