import Foundation

extension SortlyStore {
    /// "Neu aufbauen" after a start error: moves the database together with its write-ahead
    /// log and shared memory file into a dated folder `Quarantine/<time>` next to it. The log
    /// can hold the last saved changes, so it is never just deleted; the two newest
    /// quarantines are kept for support, older ones go. Photos and albums are not involved.
    ///
    /// Returns the folder the files went to, or nil when nothing was moved: no database
    /// there, or a file could not be moved. Then the caller starts with what is there (and
    /// shows the error again) instead of losing data.
    @discardableResult
    public static func quarantineDatabase(at url: URL, now: Date = Date(), keep: Int = 2) -> URL? {
        let fm = FileManager.default
        let files = ["", "-wal", "-shm"].map { url.path + $0 }.filter { fm.fileExists(atPath: $0) }
        guard !files.isEmpty else { return nil }
        let folder = url.deletingLastPathComponent().appendingPathComponent("Quarantine", isDirectory: true)
        // Milliseconds and a running number: two rebuilds within a second never meet in one
        // folder (a file already there would stop the move).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        var target = folder.appendingPathComponent(stamp, isDirectory: true)
        var attempt = 1
        while fm.fileExists(atPath: target.path) {
            attempt += 1
            target = folder.appendingPathComponent("\(stamp)-\(attempt)", isDirectory: true)
        }
        // Files already moved, so a failure half way can put them back: a database left behind
        // without its log would open silently without the last saved changes.
        var moved: [(from: String, to: String)] = []
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            // The database file last: if the log cannot be moved, the database stays usable
            // together with its log.
            for path in files.reversed() {
                let destination = target.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
                try fm.moveItem(atPath: path, toPath: destination)
                moved.append((from: path, to: destination))
            }
        } catch {
            for file in moved.reversed() { try? fm.moveItem(atPath: file.to, toPath: file.from) }
            if (try? fm.contentsOfDirectory(atPath: target.path).isEmpty) == true { try? fm.removeItem(at: target) }
            return nil
        }
        let old = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in old.dropFirst(max(1, keep)) { try? fm.removeItem(at: stale) }
        return target
    }
}
