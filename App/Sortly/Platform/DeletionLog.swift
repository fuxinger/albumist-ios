import Foundation

/// The outcome of the last batch deletion, for the diagnostic report: counts only, no names.
/// Written because the first iPhone test (15.11.) showed an undo that Photos neither carried
/// out nor reported as failed.
enum DeletionLog {
    struct Entry {
        var requested: Int
        var albums = 0
        var folders = 0
        var foldersKept = 0
        var missing = 0
        var notDeletable = 0
        var attempts = 0
        /// How long each request took in Photos. Well under a second means iOS showed no
        /// question (nobody reads and answers it that fast).
        var seconds: [Double] = []
        /// Requests sent although Albumist was not on screen (waited for it in vain).
        var notOnScreen = 0
        var stillThere = 0
        var outcome = "?"

        var line: String {
            let took = seconds.map { String(format: "%.2f s", $0) }.joined(separator: ", ")
            return "requested \(requested), albums \(albums), folders \(folders) (kept \(foldersKept)), missing \(missing), "
                + "not deletable \(notDeletable), attempts \(attempts) (\(took)), not on screen \(notOnScreen), "
                + "still there \(stillThere), \(outcome)"
        }
    }

    private static let key = "diagnostics.lastDeletion"

    static func record(_ entry: Entry) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set("\(stamp) · \(entry.line)", forKey: key)
    }

    static var last: String? { UserDefaults.standard.string(forKey: key) }
}
