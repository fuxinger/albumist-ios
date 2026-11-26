import Foundation
import Testing
@testable import AlbumistStore
import AlbumistCore
import AlbumistTestSupport

/// Test access to the file underneath the store.
extension AlbumistStore {
    /// A full disk: the database file may not grow by more than `pages` pages from now on
    /// (SQLite then fails exactly like on a full disk, with SQLITE_FULL).
    func limitFileGrowth(pages: Int = 0) throws {
        let used = try db.query("PRAGMA page_count").first?["page_count"]?.int ?? 0
        try db.execute("PRAGMA max_page_count = \(used + pages)")
    }

    func liftFileGrowthLimit() throws {
        try db.execute("PRAGMA max_page_count = 1073741823")
    }

    /// "ok" for a consistent file.
    func integrityReport() throws -> String {
        try db.query("PRAGMA integrity_check").map { $0.values.first?.string ?? "?" }.joined(separator: "; ")
    }

    func rowCount(_ table: String, where condition: String = "1") throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM \(table) WHERE \(condition)").first?["n"]?.int ?? 0
    }
}

@Suite("Data safety: damaged files, migrations, full disk, backup, reset")
struct DataSafetyTests {
    // MARK: Helpers

    /// A fresh folder for one test (removed by the caller with `defer`).
    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    func blob<T: Encodable>(_ value: T) throws -> SQLValue { .blob(try encoder.encode(value)) }

    /// The contents written into every old database, and read back after the migration.
    struct Contents {
        var asset: AssetSnapshot
        var place: PlaceComponents
        var cell: GeoCell
        var inventory: CollectionInventory
        var override: UserOverride
        var rule: OrganizationRule
        var managed: ManagedAlbumState
        var plan: ChangePlan
    }

    func contents() async throws -> Contents {
        let asset = AssetSnapshot(id: "a", kind: .image, creationDate: Fixture.date("2024-05-01 10:00"), modificationDate: Fixture.date("2024-05-02"),
                                  location: Fixture.Places.rome, locationAccuracy: 5, pixelWidth: 4032, pixelHeight: 3024,
                                  originalFilename: "IMG_0001.HEIC", uniformTypeIdentifier: "public.heic")
        let lib = InMemoryPhotoLibrary(assets: ["a"])
        let proposal = AlbumProposal(id: AlbumistID("trip-rom"), kind: .trip, title: "Rom", folderPath: [], assetIDs: ["a"])
        var plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))],
                                                  inventory: try await lib.currentInventory())
        plan.confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)
        plan.status = .confirmed
        let executed = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let album = try #require(executed.resolvedKeys.values.first)
        return Contents(
            asset: asset,
            place: PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", timeZoneIdentifier: "Europe/Rome"),
            cell: GeoCell(Fixture.Places.rome, sizeMeters: 1_000),
            inventory: try await lib.currentInventory(),
            override: UserOverride(id: AlbumistID("o1"), scope: .asset("b"), decision: .ignoreAsset, createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
            rule: OrganizationRule(name: "Rom", area: .places, condition: .predicate(.city("Rom")), target: .existingAlbum(album)),
            managed: ManagedAlbumState(albumID: album, sourceID: proposal.id, lastKnownTitle: "Rom", lastKnownParentID: nil,
                                       lastKnownMembers: ["a"], addedByAlbumist: ["a"], createdByAlbumist: true),
            plan: executed
        )
    }

    /// A database as app version `version` left it: that version's schema (its migration
    /// steps and its search index) with one row in every table, written as that version wrote it.
    func makeDatabase(version: Int, at path: String, _ c: Contents) throws {
        let old = try SQLiteDatabase(path: path)
        for step in Migrations.steps where step.version <= version { try old.execute(step.sql) }
        try old.setUserVersion(version)
        if version <= 2 {
            // The search index of versions 1 and 2: its own copy of the text, filled by the app.
            try old.execute("CREATE VIRTUAL TABLE text_fts USING fts5(asset_id UNINDEXED, content, tokenize = 'unicode61 remove_diacritics 2')")
        } else {
            try old.execute(Migrations.ftsSQL)
        }
        let a = c.asset
        try old.execute("""
            INSERT INTO assets (id, kind, subtypes, creation_date, modification_date, latitude, longitude, location_accuracy, pixel_width,
                pixel_height, duration, burst_id, is_favorite, original_filename, uti, fingerprint, analysis_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, ?, ?, ?, 3)
            """, [.text(a.id.rawValue), .text(a.kind.rawValue), .integer(Int64(a.subtypes.rawValue)), .real(a.creationDate!.timeIntervalSince1970),
                  .real(a.modificationDate!.timeIntervalSince1970), .real(a.location!.latitude), .real(a.location!.longitude), .real(a.locationAccuracy!),
                  .integer(Int64(a.pixelWidth)), .integer(Int64(a.pixelHeight)), .real(a.duration), .text(a.originalFilename!),
                  .text(a.uniformTypeIdentifier!), .text(AlbumistStore.fingerprint(a))])
        try old.execute("INSERT INTO place_cache (cell, components, resolved_at) VALUES (?, ?, ?)", [.text(c.cell.description), try blob(c.place), .real(1_700_000_000)])
        if version == 1 {
            try old.execute("INSERT INTO asset_places (asset_id, components, source, resolved_at) VALUES ('a', ?, ?, ?)",
                            [try blob(c.place), .text(PlaceSource.gpsReverseGeocoded.rawValue), .real(1_700_000_000)])
        } else {
            try old.execute("INSERT INTO asset_places (asset_id, components, source, resolved_at, precision_m) VALUES ('a', ?, ?, ?, 250)",
                            [try blob(c.place), .text(PlaceSource.gpsReverseGeocoded.rawValue), .real(1_700_000_000)])
        }
        try old.execute("INSERT INTO analysis_results (asset_id, kind, version, payload) VALUES ('a', 'vision', 3, ?)", [try blob(["beach": 0.9])])
        try old.execute("INSERT INTO analysis_progress (stage, cursor, version, completed, updated_at) VALUES ('content', 'a', 3, 1, 1700000000)")
        try old.execute("INSERT INTO text_plain (asset_id, content) VALUES ('a', 'Rechnung Hotel Rom')")
        if version <= 2 { try old.execute("INSERT INTO text_fts (asset_id, content) VALUES ('a', 'Rechnung Hotel Rom')") }
        for album in c.inventory.collections.values {
            try old.execute("INSERT INTO collections (id, title, kind, capabilities, parent_id, child_ids) VALUES (?, ?, ?, ?, ?, ?)",
                            [.text(album.id.rawValue), .text(album.title), .text(album.kind.rawValue), .integer(Int64(album.capabilities.rawValue)),
                             album.parentID.map { .text($0.rawValue) } ?? .null, try blob(album.childIDs)])
            for member in album.assetIDs {
                try old.execute("INSERT INTO collection_members (collection_id, asset_id) VALUES (?, ?)", [.text(album.id.rawValue), .text(member.rawValue)])
            }
        }
        try old.execute("INSERT INTO overrides (id, payload, created_at) VALUES (?, ?, ?)",
                        [.text(c.override.id.rawValue), try blob(c.override), .real(c.override.createdAt.timeIntervalSince1970)])
        try old.execute("INSERT INTO rules (id, version, payload, updated_at) VALUES (?, ?, ?, NULL)",
                        [.text(c.rule.id.rawValue), .integer(Int64(c.rule.version)), try blob(c.rule)])
        try old.execute("INSERT INTO managed_albums (album_id, source_id, payload) VALUES (?, ?, ?)",
                        [.text(c.managed.albumID.rawValue), .text(c.managed.sourceID.rawValue), try blob(c.managed)])
        // Before v4 a plan was one row with its steps and journal inside.
        try old.execute("INSERT INTO plans (id, status, created_at, payload) VALUES (?, ?, ?, ?)",
                        [.text(c.plan.id.rawValue), .text(c.plan.status.rawValue), .real(c.plan.createdAt.timeIntervalSince1970), try blob(c.plan)])
        try old.execute("INSERT INTO settings (key, payload) VALUES ('user.titles', ?)", [try blob(["trip-rom": "Rom im Mai"])])
        try old.execute("INSERT INTO settings (key, payload) VALUES ('analysis.trips', ?)", [try blob(["t1"])])
    }

    /// Everything of `makeDatabase` reads back through the store, unchanged.
    func expectIntact(_ s: AlbumistStore, _ c: Contents, version: Int) async throws {
        #expect(await s.schemaVersion == 6)
        #expect(try await s.integrityReport() == "ok")
        #expect(try await s.asset("a") == c.asset)
        // Every photo of an older version is in view (version 6, review P1-07).
        #expect(try await s.outOfViewCount() == 0)
        #expect(try await s.assetCount() == 1)
        // Same fingerprint: the photo is not taken as changed and analysed again.
        #expect(try await s.upsertAssets([c.asset]).isEmpty)
        #expect(try await s.assetsNeedingAnalysis(version: 3, limit: 10).isEmpty)
        #expect(try await s.results([String: Double].self, kind: "vision") == ["a": ["beach": 0.9]])
        #expect(try await s.progress(stage: "content") == AlbumistStore.StageProgress(cursor: "a", version: 3, completed: true))
        #expect(try await s.cachedPlace(cell: c.cell) == c.place)
        let place = try #require(try await s.places()["a"])
        #expect(place.components == c.place)
        #expect(place.precisionMeters == (version == 1 ? nil : 250))
        #expect(await s.hasFullTextSearch)
        #expect(try await s.searchText("Hotel") == ["a"])
        #expect(try await s.recognizedText(for: "a") == "Rechnung Hotel Rom")
        #expect(try await s.loadInventory() == c.inventory)
        #expect(try await s.overrides() == [c.override])
        #expect(try await s.currentRules() == [c.rule])
        #expect(try await s.managedAlbums() == [c.managed])
        #expect(try await s.plan(c.plan.id) == c.plan)
        #expect(try await s.planHistory() == [c.plan])
        #expect(try await s.value([String: String].self, forKey: "user.titles") == ["trip-rom": "Rom im Mai"])
        #expect(try await s.value([String].self, forKey: "analysis.trips") == ["t1"])
        // The migrated database is written to as usual afterwards: the old plan goes into
        // the step-by-step journal at its next save, the search follows new text.
        var finalized = c.plan
        finalized.finalizedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try await s.save(finalized)
        #expect(try await s.plan(c.plan.id) == finalized)
        try await s.indexText("Bordkarte Flug Rom", for: "a")
        #expect(try await s.searchText("Bordkarte") == ["a"])
        #expect(try await s.searchText("Hotel").isEmpty)
    }

    // MARK: Migrations from every older version

    @Test(arguments: [1, 2, 3, 4, 5])
    func everyOlderVersionMigratesWithItsDataIntact(version: Int) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let c = try await contents()
        try makeDatabase(version: version, at: url.path, c)
        do {
            let s = try AlbumistStore(url: url)
            try await expectIntact(s, c, version: version)
        }
        // Opened again: nothing runs twice, the data is still there.
        let reopened = try AlbumistStore(url: url)
        #expect(await reopened.schemaVersion == 6)
        #expect(try await reopened.overrides() == [c.override])
        #expect(try await reopened.searchText("Bordkarte") == ["a"])
        // A photo set aside (version 6) stays set aside in the file, with its results.
        #expect(try await reopened.setAside(notIn: []) == 1)
        let third = try AlbumistStore(url: url)
        #expect(try await third.outOfViewCount() == 1)
        #expect(try await third.assetCount() == 0)
        #expect(try await third.upsertAssets([c.asset]).isEmpty)
        #expect(try await third.results([String: Double].self, kind: "vision") == ["a": ["beach": 0.9]])
        #expect(try await third.searchText("Bordkarte") == ["a"])
    }

    /// A migration that cannot finish (here: the disk is full while version 3 copies the
    /// recognized text) leaves the database exactly at its old version; the next start
    /// migrates it completely.
    @Test func migrationThatFailsHalfWayLeavesTheOldVersion() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let c = try await contents()
        try makeDatabase(version: 2, at: url.path, c)
        do {
            let old = try SQLiteDatabase(path: url.path)
            for i in 0..<3_000 {
                try old.execute("INSERT INTO assets (id, kind, fingerprint) VALUES (?, 'image', 'x')", [.text("t\(i)")])
                try old.execute("INSERT INTO text_plain (asset_id, content) VALUES (?, ?)", [.text("t\(i)"), .text("Kassenbon Nummer \(i) Bäckerei am Markt")])
            }
            let pages = try old.query("PRAGMA page_count").first?["page_count"]?.int ?? 0
            try old.execute("PRAGMA max_page_count = \(pages)")
            #expect(throws: SQLiteError.self) { try Migrations.migrate(old) }
            #expect(old.userVersion == 2)
            #expect(try old.query("SELECT COUNT(*) AS n FROM text_plain").first?["n"]?.int == 3_001)
            #expect(try old.query("SELECT 1 FROM sqlite_master WHERE name = 'text_plain_v3' OR name = 'plan_steps'").isEmpty)
        }
        let s = try AlbumistStore(url: url)
        #expect(await s.schemaVersion == 6)
        #expect(try await s.integrityReport() == "ok")
        #expect(try await s.searchText("Bäckerei", limit: 10_000).count == 3_000)
        #expect(try await s.searchText("Hotel") == ["a"])
        #expect(try await s.overrides() == [c.override])
    }

    // MARK: Damaged database file at launch

    /// A database with real content, closed (its log written back into the file).
    func writtenDatabase(at url: URL) async throws {
        let s = try AlbumistStore(url: url)
        try await s.upsertAssets((0..<5_000).map { AssetSnapshot(id: AssetID("asset-\($0)"), creationDate: Date(timeIntervalSince1970: Double($0) * 600)) })
        try await s.addOverride(UserOverride(scope: .asset("asset-1"), decision: .ignoreAsset))
        try await s.setValue(["x": "y"], forKey: "user.titles")
    }

    func expectFailsToOpen(_ url: URL, _ what: String) {
        let before = try? Data(contentsOf: url)
        #expect(throws: SQLiteError.self, "\(what) must not open") { _ = try AlbumistStore(url: url) }
        // The damaged file stays as it was (it is set aside by "Neu aufbauen", never repaired
        // or overwritten in place).
        #expect((try? Data(contentsOf: url)) == before, "\(what) was changed")
    }

    @Test func garbageFileDoesNotOpen() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        try Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0 &* 7_919 &+ 13) }).write(to: url)
        expectFailsToOpen(url, "garbage")
        try Data("Das ist keine Datenbank, sondern Text.".utf8).write(to: url)
        expectFailsToOpen(url, "a text file")
    }

    @Test func wrongHeaderDoesNotOpen() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        try await writtenDatabase(at: url)
        var data = try Data(contentsOf: url)
        #expect(data.prefix(15) == Data("SQLite format 3".utf8))
        data.replaceSubrange(0..<16, with: Data("Albumist-copy!!\0".utf8))
        try data.write(to: url)
        expectFailsToOpen(url, "wrong header")
    }

    @Test(arguments: [0.5, 0.1, 0.01])
    func truncatedFileDoesNotOpen(keeping fraction: Double) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        try await writtenDatabase(at: url)
        let data = try Data(contentsOf: url)
        try data.prefix(max(512, Int(Double(data.count) * fraction))).write(to: url)
        expectFailsToOpen(url, "truncated to \(fraction)")
    }

    /// One damaged page inside an otherwise valid file (a table, an index or the schema)
    /// is found when the database opens, not later in the middle of an analysis or a plan.
    @Test func damagedPageIsFoundAtLaunch() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        try await writtenDatabase(at: url)
        let healthy = try Data(contentsOf: url)
        let pageSize = Int(healthy[16]) << 8 | Int(healthy[17])
        let pages = healthy.count / pageSize
        #expect(pages > 100)
        for page in [0, 1, 2, 5, 20, pages / 2, pages - 1] {
            var damaged = healthy
            let start = page * pageSize
            for i in start..<(start + pageSize) { damaged[i] = UInt8(truncatingIfNeeded: i &* 31 &+ page) }
            try damaged.write(to: url)
            expectFailsToOpen(url, "damaged page \(page)")
        }
        // The intact file still opens and holds everything.
        try healthy.write(to: url)
        let s = try AlbumistStore(url: url)
        #expect(try await s.assetCount() == 5_000)
        #expect(try await s.overrides().count == 1)
    }

    /// The check at the start reads the whole file once; it must stay cheap for a large
    /// library (measured: about 40 ms for 33 MB on the CI machine).
    @Test func integrityCheckAtLaunchStaysCheap() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        do {
            let s = try AlbumistStore(url: url)
            let ids = (0..<20_000).map { AssetID("photo-identifier-\($0)/L0/001") }
            try await s.upsertAssets(ids.enumerated().map { AssetSnapshot(id: $0.element, creationDate: Date(timeIntervalSince1970: Double($0.offset) * 600), location: Fixture.Places.rome) })
            for id in ids {
                try await s.saveResult(["labels": ["beach", "sea", "sky", "people"]], kind: "content", asset: id, version: 3)
            }
            for id in ids.prefix(2_000) { try await s.indexText("Bestellung Nummer 302-1234567 Lieferung Donnerstag Gesamtbetrag", for: id) }
        }
        let clock = ContinuousClock()
        var reopened: AlbumistStore?
        let elapsed = try clock.measure { reopened = try AlbumistStore(url: url) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("[measure] open with integrity check, \(size / 1_000_000) MB: \(elapsed)")
        #expect(try await reopened?.assetCount() == 20_000)
        #expect(TimingLimit.holds(elapsed, under: .seconds(5), "reopening the store"))
    }

    /// An empty file (a copy that never got its content) starts as a new database.
    @Test func emptyFileStartsAsNewDatabase() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let s = try AlbumistStore(url: url)
        #expect(await s.schemaVersion == 6)
        #expect(try await s.hasSafetyData() == false)
    }

    /// "Neu aufbauen" after a start error: the damaged file is set aside together with its
    /// log, a new database opens, and the decisions, Albumist's albums and the history come
    /// back from the backup copy.
    @Test func rebuildSetsTheDamagedFileAsideAndTheDecisionsComeBack() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let backupURL = dir.appendingPathComponent("Backup/decisions.json")
        let c = try await contents()
        try makeDatabase(version: 3, at: url.path, c)
        do {
            let s = try AlbumistStore(url: url)
            try await s.safetyBackup().write(to: backupURL)
        }
        // Damaged: the start fails.
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: url)
        let damaged = try Data(contentsOf: url)
        #expect(throws: SQLiteError.self) { _ = try AlbumistStore(url: url) }
        // A log and shared memory file next to it go along (the log can hold the last changes).
        try Data("log".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))

        let aside = try #require(AlbumistStore.quarantineDatabase(at: url, now: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(aside.deletingLastPathComponent().lastPathComponent == "Quarantine")
        #expect(try Data(contentsOf: aside.appendingPathComponent("albumist.sqlite")) == damaged)
        #expect(try Data(contentsOf: aside.appendingPathComponent("albumist.sqlite-wal")) == Data("log".utf8))
        #expect(try Data(contentsOf: aside.appendingPathComponent("albumist.sqlite-shm")) == Data("shm".utf8))
        for suffix in ["", "-wal", "-shm"] { #expect(!FileManager.default.fileExists(atPath: url.path + suffix)) }

        let rebuilt = try AlbumistStore(url: url)
        #expect(await rebuilt.schemaVersion == 6)
        let backup = try #require(try SafetyBackup.read(from: backupURL))
        #expect(try await rebuilt.restore(backup, includingLibraryState: backup.belongsToLibrary(access: .full, visibleAlbums: Set(c.inventory.collections.keys)) == true))
        #expect(try await rebuilt.overrides() == [c.override])
        #expect(try await rebuilt.currentRules() == [c.rule])
        #expect(try await rebuilt.managedAlbums() == [c.managed])
        #expect(try await rebuilt.plan(c.plan.id) == c.plan)
        #expect(try await rebuilt.value([String: String].self, forKey: "user.titles") == ["trip-rom": "Rom im Mai"])
        // The analysis is not in the copy: it is rebuilt from the library.
        #expect(try await rebuilt.assetCount() == 0)
    }

    @Test func quarantineKeepsTheTwoNewestAndNeverMeetsAnOlderOne() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        // Nothing there: nothing to set aside, no folder.
        #expect(AlbumistStore.quarantineDatabase(at: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Quarantine").path))

        var folders: [URL] = []
        for (i, time) in [1_700_000_000.0, 1_700_000_000.0, 1_700_000_100.0].enumerated() {
            try Data("db \(i)".utf8).write(to: url)
            folders.append(try #require(AlbumistStore.quarantineDatabase(at: url, now: Date(timeIntervalSince1970: time))))
        }
        // Two rebuilds in the same instant got separate folders, none lost its file.
        #expect(Set(folders).count == 3)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Quarantine").path).sorted()
        #expect(kept.count == 2)
        #expect(kept.contains(folders[2].lastPathComponent))
        #expect(try Data(contentsOf: folders[2].appendingPathComponent("albumist.sqlite")) == Data("db 2".utf8))
    }

    /// "Neu aufbauen" takes stray logs of the other name too (no database of that name): a
    /// stale log must not be replayed into the database built next (second review of prep/rename).
    @Test func theQuarantineTakesAStrayLogOfTheOtherNameButNotItsDatabase() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.sqlite")
        for name in ["old.sqlite", "old.sqlite-wal", "new.sqlite-wal", "new.sqlite-shm"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }
        let aside = try #require(AlbumistStore.quarantineDatabase(at: url, otherName: "new.sqlite"))
        let moved = try FileManager.default.contentsOfDirectory(atPath: aside.path).sorted()
        #expect(moved == ["new.sqlite-shm", "new.sqlite-wal", "old.sqlite", "old.sqlite-wal"])
        // A database file of the other name is the user's data: it stays, with its log.
        for name in ["new.sqlite", "new.sqlite-wal"] { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
        try Data("db".utf8).write(to: url)
        let second = try #require(AlbumistStore.quarantineDatabase(at: url, otherName: "new.sqlite"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path) == ["old.sqlite"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.sqlite-wal").path))
    }

    /// Stray logs set aside by the database move (`Quarantine/<time>-stray`) never push out a
    /// quarantined database: each kind keeps its two newest folders (re-check of prep/rename).
    @Test func strayFoldersDoNotCountAgainstTheQuarantinedDatabases() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.sqlite")
        func quarantine(_ time: Double) throws -> String {
            try Data("db \(time)".utf8).write(to: url)
            return try #require(AlbumistStore.quarantineDatabase(at: url, now: Date(timeIntervalSince1970: time))).lastPathComponent
        }
        func stray(_ time: Double) throws -> String {
            let aside = DatabaseFile.strayFolder(in: dir, now: Date(timeIntervalSince1970: time))
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            try Data("stale log".utf8).write(to: aside.appendingPathComponent("new.sqlite-wal"))
            return aside.lastPathComponent
        }
        func kept() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Quarantine").path))
        }
        let first = try quarantine(1_700_000_000)
        let strays = [try stray(1_700_000_100), try stray(1_700_000_200)]
        let second = try quarantine(1_700_000_300)
        #expect(try kept() == Set([first, second] + strays))
        let third = [try stray(1_700_000_400)]
        let last = try quarantine(1_700_000_500)
        #expect(try kept() == Set([second, last, strays[1]] + third))
    }

    /// "Neu aufbauen" after a start that failed with the store already open (AppModel.load):
    /// the old connection is still open while its files go to the quarantine and a new database
    /// starts under the same name. When the old connection closes, it must not touch the new
    /// database's files: SQLite deletes the log and shared memory of a closing connection by
    /// name, which is now the new database's (second review of prep/rename).
    @Test func anOldConnectionClosingAfterTheQuarantineLeavesTheNewDatabasesLog() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        var earlier: AlbumistStore? = try AlbumistStore(url: url)
        try await earlier?.setValue("earlier", forKey: "user.marker")
        #expect(AlbumistStore.quarantineDatabase(at: url) != nil)
        let rebuilt = try AlbumistStore(url: url)
        try await rebuilt.setValue("rebuilt", forKey: "user.marker")
        #if os(Linux)
        // The old connection really is open on the quarantined files, and really closes below.
        func openInQuarantine() -> Int {
            let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
            return fds.filter { ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")) ?? "").contains(dir.lastPathComponent + "/Quarantine/") }.count
        }
        #expect(openInQuarantine() > 0)
        #endif
        earlier = nil
        #if os(Linux)
        #expect(openInQuarantine() == 0)
        #endif
        // The new database's committed row is still where the next start reads it.
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let next = try AlbumistStore(url: url)
        #expect(try await next.value(String.self, forKey: "user.marker") == "rebuilt")
        _ = rebuilt
    }

    /// A restore that did not happen (failed, full disk, copy from a newer version) leaves an
    /// empty database next to a full copy. The next save of the copy must not replace it with
    /// the empty state, or the decisions would be gone for good.
    @Test func emptyDatabaseNeverOverwritesAFullCopy() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Backup/decisions.json")
        let c = try await contents()
        let full = try AlbumistStore(url: nil)
        try await full.addOverride(c.override)
        try await full.save(c.plan)
        let copy = try await full.safetyBackup(now: Date(timeIntervalSince1970: 1))
        try copy.write(to: file)

        let empty = try AlbumistStore(url: nil)
        let snapshot = try await empty.safetyBackupSnapshot(now: Date(timeIntervalSince1970: 2))
        #expect(snapshot.backup.isEmpty)
        let writer = SafetyBackupWriter(url: file)
        #expect(try await !writer.write(snapshot.backup, sequence: snapshot.sequence))
        #expect(try SafetyBackup.read(from: file) == copy)

        // Same for a copy this version cannot read (a newer format, a damaged file).
        var newer = copy
        newer.formatVersion = SafetyBackup.formatVersion + 1
        try newer.write(to: file)
        #expect(try await !writer.write(snapshot.backup, sequence: snapshot.sequence + 1))
        try Data("{ damaged".utf8).write(to: file)
        #expect(try await !writer.write(snapshot.backup, sequence: snapshot.sequence + 2))
        #expect(try Data(contentsOf: file) == Data("{ damaged".utf8))

        // Once the database holds decisions again (restored, or new ones), the copy follows.
        #expect(try await empty.restore(copy, includingLibraryState: true))
        let restored = try await empty.safetyBackupSnapshot(now: Date(timeIntervalSince1970: 3))
        #expect(try await writer.write(restored.backup, sequence: restored.sequence))
        #expect(try SafetyBackup.read(from: file)?.overrides == copy.overrides)
        // An empty copy may replace an empty one.
        try SafetyBackup(formatVersion: 1, createdAt: Date(), schemaVersion: 4, overrides: [], rules: [], managedAlbums: [], plans: [], values: []).write(to: file)
        let fresh = SafetyBackupWriter(url: file)
        #expect(try await fresh.write(snapshot.backup, sequence: snapshot.sequence))
    }

    // MARK: Full disk in the middle of a write

    func fileStore(_ dir: URL) throws -> AlbumistStore { try AlbumistStore(url: dir.appendingPathComponent("albumist.sqlite")) }

    func expectFull(_ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("\(what) did not fail on a full disk")
        } catch let error as SQLiteError {
            #expect(error.code == 13, "\(what): \(error)") // SQLITE_FULL
        } catch {
            Issue.record("\(what): unexpected \(error)")
        }
    }

    @Test func fullDiskDuringAnalysisWriteLeavesNothingHalfWritten() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try fileStore(dir)
        let first = (0..<100).map { AssetSnapshot(id: AssetID("a\($0)"), creationDate: Date(timeIntervalSince1970: Double($0))) }
        try await s.upsertAssets(first)
        let more = (100..<5_100).map { AssetSnapshot(id: AssetID("a\($0)"), creationDate: Date(timeIntervalSince1970: Double($0))) }
        try await s.limitFileGrowth()
        await expectFull("upsert") { try await s.upsertAssets(more) }
        #expect(try await s.assetCount() == 100)
        #expect(try await s.integrityReport() == "ok")
        // Space again: the whole batch is still new, nothing of it was kept.
        try await s.liftFileGrowthLimit()
        #expect(try await s.upsertAssets(more).count == 5_000)
        #expect(try await s.assetCount() == 5_100)
    }

    /// The journal is written before the library is touched. A save that fails on a full disk
    /// keeps the previous state of the plan exactly; the next save writes the plan in full
    /// (what the store remembers of the plan was dropped with the failed write).
    @Test func fullDiskDuringJournalWriteKeepsThePreviousPlan() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try fileStore(dir)
        let assets = (0..<5_000).map { AssetID("photo-identifier-\($0)/L0/001") }
        let proposal = AlbumProposal(id: AlbumistID("big"), kind: .trip, title: "Rom", folderPath: [], assetIDs: Set(assets))
        var plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))],
                                                  inventory: CollectionInventory())
        plan.status = .running
        plan.record = ExecutionRecord()
        try await s.save(plan)

        var progressed = plan
        for i in progressed.steps.indices { progressed.steps[i].state = .succeeded(createdID: "album", verifiedAt: Date(timeIntervalSince1970: 5)) }
        for step in progressed.steps { progressed.record?.media[step.id] = assets }
        try await s.limitFileGrowth()
        await expectFull("journal save") { try await s.save(progressed) }
        #expect(try await s.plan(plan.id) == plan)
        #expect(try await s.integrityReport() == "ok")

        try await s.liftFileGrowthLimit()
        try await s.save(progressed)
        #expect(try await s.plan(plan.id) == progressed)
        let reopened = try fileStore(dir)
        #expect(try await reopened.plan(plan.id) == progressed)
    }

    /// The finalization (plan, Albumist's albums, decisions) is one transaction: on a full
    /// disk none of it is stored, and the plan stays to be finalized at the next launch.
    @Test func fullDiskDuringFinalizationStoresNoneOfIt() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try fileStore(dir)
        let c = try await contents()
        try await s.save(c.plan)
        try await s.saveManagedAlbums([c.managed])
        try await s.setValue(["p": "accepted"], forKey: "user.decisions")
        var done = c.plan
        done.finalizedAt = Date(timeIntervalSince1970: 1_700_000_900)
        let many = (0..<400).map { i in
            ManagedAlbumState(albumID: CollectionID("album-\(i)"), sourceID: AlbumistID("source-\(i)"), lastKnownTitle: "Album \(i)", lastKnownParentID: nil,
                              lastKnownMembers: Set((0..<40).map { AssetID("photo-\(i)-\($0)") }), addedByAlbumist: [], createdByAlbumist: true)
        }
        try await s.limitFileGrowth()
        await expectFull("finalize") {
            try await s.finalize(done, managedAlbums: many, values: ["user.decisions": [String: String](), "execution.pendingFinalization": [String]()])
        }
        #expect(try await s.plan(c.plan.id)?.finalizedAt == nil)
        #expect(try await s.managedAlbums() == [c.managed])
        #expect(try await s.value([String: String].self, forKey: "user.decisions") == ["p": "accepted"])
        #expect(try await s.integrityReport() == "ok")
    }

    /// A restore that fails on a full disk leaves the database without decisions, so the
    /// next start restores again (a half restore would block it for good).
    @Test func fullDiskDuringRestoreCanBeRepeated() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try AlbumistStore(url: nil)
        for i in 0..<2_000 {
            try await source.addOverride(UserOverride(id: AlbumistID("o\(i)"), scope: .asset(AssetID("photo-\(i)")), decision: .ignoreAsset, createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        let backup = try await source.safetyBackup()
        let s = try fileStore(dir)
        try await s.limitFileGrowth()
        await expectFull("restore") { try await s.restore(backup, includingLibraryState: true) }
        #expect(try await s.hasSafetyData() == false)
        #expect(try await s.rowCount("overrides") == 0)
        try await s.liftFileGrowthLimit()
        #expect(try await s.restore(backup, includingLibraryState: true))
        #expect(try await s.overrides().count == 2_000)
    }

    // MARK: Backup restore with full, limited and no photo access

    /// The rule `AppModel` applies at launch and whenever the photo access changes.
    @Test func libraryStateOfTheCopyFollowsThePhotoAccess() async throws {
        let c = try await contents()
        let source = try AlbumistStore(url: nil)
        try await source.addOverride(c.override)
        try await source.saveManagedAlbums([c.managed])
        try await source.save(c.plan)
        let backup = try await source.safetyBackup()
        let own: Set<CollectionID> = [c.managed.albumID, "other"]
        let foreign: Set<CollectionID> = ["new-iphone-album"]

        // No access (not asked yet, denied, restricted): cannot be told, wait.
        for access in [LibraryAccess.notDetermined, .denied, .restricted] {
            #expect(backup.belongsToLibrary(access: access, visibleAlbums: nil) == nil)
            #expect(backup.belongsToLibrary(access: access, visibleAlbums: own) == nil)
        }
        // Limited: a match restores; albums that are not visible may only be hidden: wait.
        #expect(backup.belongsToLibrary(access: .limited, visibleAlbums: own) == true)
        #expect(backup.belongsToLibrary(access: .limited, visibleAlbums: foreign) == nil)
        #expect(backup.belongsToLibrary(access: .limited, visibleAlbums: nil) == nil)
        // Full: a match restores, anything else is another library.
        #expect(backup.belongsToLibrary(access: .full, visibleAlbums: own) == true)
        #expect(backup.belongsToLibrary(access: .full, visibleAlbums: foreign) == false)
        #expect(backup.belongsToLibrary(access: .full, visibleAlbums: nil) == nil)
        // A copy without album records needs no check.
        var decisionsOnly = backup
        decisionsOnly.managedAlbums = []
        #expect(decisionsOnly.belongsToLibrary(access: .denied, visibleAlbums: nil) == true)

        /// What the app does at launch with this access.
        func launch(_ store: AlbumistStore, _ access: LibraryAccess, _ visible: Set<CollectionID>?) async throws -> Bool? {
            if try await !store.hasSafetyData() { try await store.restore(backup, includingLibraryState: false) }
            let verdict = backup.belongsToLibrary(access: access, visibleAlbums: visible)
            if verdict == true { try await store.restoreLibraryState(backup) }
            return verdict
        }

        // New iPhone, before the photo access: decisions at once, albums and history wait;
        // limited access that hides the album: still waiting; full access: they come back.
        let waiting = try AlbumistStore(url: nil)
        #expect(try await launch(waiting, .notDetermined, nil) == nil)
        #expect(try await waiting.overrides() == [c.override])
        #expect(try await waiting.managedAlbums().isEmpty)
        #expect(try await launch(waiting, .limited, foreign) == nil)
        #expect(try await waiting.planHistory().isEmpty)
        #expect(try await launch(waiting, .full, own) == true)
        #expect(try await waiting.managedAlbums() == [c.managed])
        #expect(try await waiting.planHistory().map(\.id) == [c.plan.id])
        #expect(try await waiting.overrides() == [c.override]) // not twice

        // Limited access that shows the album: everything at once.
        let limited = try AlbumistStore(url: nil)
        #expect(try await launch(limited, .limited, own) == true)
        #expect(try await limited.managedAlbums() == [c.managed])

        // Another library with full access: only the decisions, never the album records
        // (they would read as "deleted by you").
        let other = try AlbumistStore(url: nil)
        #expect(try await launch(other, .full, foreign) == false)
        #expect(try await other.overrides() == [c.override])
        #expect(try await other.managedAlbums().isEmpty)
        #expect(try await other.planHistory().isEmpty)
    }

    // MARK: "Analyse neu aufbauen"

    /// Settings: "Löscht nur Albumists eigene Analyse. Deine Fotos und Alben bleiben, wie sie
    /// sind." Every table is checked: the analysis goes, everything else stays, the photo
    /// library is not touched, and an earlier plan can still be taken back afterwards.
    @Test func resetClearsTheAnalysisAndNothingElse() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let c = try await contents()
        try makeDatabase(version: 3, at: url.path, c)
        let s = try AlbumistStore(url: url)
        let lib = InMemoryPhotoLibrary(assets: ["a"])
        let proposal = AlbumProposal(id: AlbumistID("trip-rom"), kind: .trip, title: "Rom", folderPath: [], assetIDs: ["a"])
        var plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .createNew(title: nil, folderPath: nil))],
                                                  inventory: try await lib.currentInventory())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let executed = try await ChangeExecutor(library: lib, store: s).execute(plan)
        try await s.setValue(["x"], forKey: "execution.pendingFinalization")
        try await s.setValue(TripCorrections(forcedBreaks: [Fixture.date("2024-05-03")]), forKey: "user.tripCorrections")
        try await s.setValue(["t"], forKey: "analysis.proposals")
        let libraryBefore = try await lib.currentInventory()

        let kept = ["assets", "collections", "collection_members", "overrides", "rules", "managed_albums", "plans", "plan_steps", "plan_media"]
        var before: [String: Int] = [:]
        for table in kept { before[table] = try await s.rowCount(table) }
        let userSettings = try await s.rowCount("settings", where: "key NOT LIKE 'analysis.%'")
        #expect(before.values.allSatisfy { $0 > 0 })
        #expect(userSettings == 3)

        try await s.resetAnalysis()

        for table in ["analysis_results", "asset_places", "place_cache", "analysis_progress", "text_plain"] {
            #expect(try await s.rowCount(table) == 0, "\(table) not cleared")
        }
        #expect(try await s.rowCount("settings", where: "key LIKE 'analysis.%'") == 0)
        #expect(try await s.searchText("Hotel").isEmpty) // the search index follows
        #expect(try await s.assetsNeedingAnalysis(version: 1, limit: 10).map(\.id) == ["a"]) // analysed again
        for table in kept { #expect(try await s.rowCount(table) == before[table], "\(table) changed") }
        #expect(try await s.rowCount("settings", where: "key NOT LIKE 'analysis.%'") == userSettings)
        #expect(try await s.overrides() == [c.override])
        #expect(try await s.currentRules() == [c.rule])
        #expect(try await s.value(TripCorrections.self, forKey: "user.tripCorrections")?.forcedBreaks.count == 1)
        #expect(try await s.plan(executed.id) == executed)
        #expect(try await s.integrityReport() == "ok")

        // The photo library is exactly as before, and the plan can still be taken back.
        #expect(try await lib.currentInventory() == libraryBefore)
        var undo = UndoPlanner().undoPlan(for: executed, current: try await lib.currentInventory())
        undo.status = .confirmed
        undo.confirmedAt = Date()
        #expect(try await ChangeExecutor(library: lib, store: s).execute(undo).status == .completed)
        #expect(try await lib.currentInventory().collections.values.contains { $0.title == "Rom" } == false)
    }

    /// The full reset (not offered in the app; used by tests and support) clears the
    /// decisions and the journal too, but still never the photo metadata or albums known.
    @Test func resetIncludingDecisionsLeavesNoJournalBehind() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let c = try await contents()
        try makeDatabase(version: 3, at: url.path, c)
        let s = try AlbumistStore(url: url)
        var saved = c.plan
        saved.finalizedAt = Date(timeIntervalSince1970: 1)
        try await s.save(saved)
        #expect(try await s.rowCount("plan_steps") > 0)
        try await s.resetAnalysis(includingDecisions: true)
        for table in ["overrides", "rules", "managed_albums", "plans", "plan_steps", "plan_media", "settings", "analysis_results", "text_plain"] {
            #expect(try await s.rowCount(table) == 0, "\(table) not cleared")
        }
        #expect(try await s.hasSafetyData() == false)
        #expect(try await s.rowCount("assets") == 1)
        #expect(try await s.loadInventory() == c.inventory)
        // A plan with the same id saved afterwards is written in full, not as a difference.
        try await s.save(saved)
        #expect(try await s.plan(saved.id) == saved)
    }

    /// Second review of G2-03: text that is removed (a medical letter found by a stricter mask)
    /// must not stay readable in the database file: not in the deleted row, not in the old
    /// entries of the search index, not in the write-ahead log.
    @Test func removedTextIsNotLeftInTheFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let s = try AlbumistStore(url: url)
        #expect(await s.securesDeletes)
        try await s.upsertAssets([AssetSnapshot(id: "a", creationDate: Fixture.date("2026-01-01")),
                                  AssetSnapshot(id: "b", creationDate: Fixture.date("2026-01-02"))])
        try await s.indexText("Diagnosis: zebracornflower syndrome, Metformin", for: "a")
        try await s.indexText("Garden party on Friday", for: "b")
        try await s.removeText(for: "a")
        try await s.indexText("Kontoauszug IBAN ••••", for: "b")
        try await s.purgeDeletedText()
        #expect(try await s.searchText("zebracornflower").isEmpty)
        #expect(try await s.searchText("Kontoauszug") == ["b"])
        for name in ["albumist.sqlite", "albumist.sqlite-wal"] {
            let data = (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
            for word in ["zebracornflower", "Garden party"] {
                #expect(data.range(of: Data(word.utf8)) == nil, "\(word) still in \(name)")
            }
        }
    }
}
