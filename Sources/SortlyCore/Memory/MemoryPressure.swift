import Foundation

/// Caches Albumist keeps in memory only to be faster, emptied when iOS warns that memory runs low
/// (review 18.11., P4-06): with 50,000 to 100,000 photos the copies made for the search, the
/// atlas and the photo lists add up, and iOS ends an app that keeps them while memory is short,
/// during the analysis too.
///
/// Only what is made again on its next use, from what stays, registers here. The photos' facts
/// and states, the suggestions, the user's decisions, and whatever a running analysis or a search
/// waits for never do.
@MainActor
public final class MemoryPressure {
    public static let shared = MemoryPressure()

    private struct Cache {
        let name: String
        /// Empties the cache; false once its owner is gone (the entry is then forgotten).
        let purge: @MainActor () -> Bool
    }

    private var caches: [Cache] = []

    public init() {}

    /// `purge` empties the cache; the cache is made again at its next use. The owner is held
    /// weakly: a cache whose owner went away is forgotten at the next warning.
    public func register<Owner: AnyObject>(_ name: String, owner: Owner, purge: @escaping @MainActor (Owner) -> Void) {
        caches.append(Cache(name: name) { [weak owner] in
            guard let owner else { return false }
            purge(owner)
            return true
        })
    }

    /// iOS warned that memory runs low: every registered cache is emptied. The names of the
    /// emptied caches, in the order they registered, for the diagnostic report.
    @discardableResult
    public func warning() -> [String] {
        var emptied: [String] = []
        var alive: [Cache] = []
        for cache in caches where cache.purge() {
            emptied.append(cache.name)
            alive.append(cache)
        }
        caches = alive
        return emptied
    }

    /// One line of the diagnostic report: when, whether an analysis ran, the memory iOS still
    /// allowed and the caches emptied. No photos, places or names (I16).
    public static func line(at date: Date, analysisRunning: Bool, onScreen: Bool, availableMB: Int?, emptied: [String]) -> String {
        let iso = ISO8601DateFormatter()
        let caches = emptied.isEmpty ? "nothing" : emptied.joined(separator: ", ")
        return "\(iso.string(from: date)), analysis running \(analysisRunning), on screen \(onScreen), "
            + "available \(availableMB.map(String.init) ?? "?") MB, emptied \(caches)"
    }
}
