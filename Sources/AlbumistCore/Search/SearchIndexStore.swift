import Foundation

/// The search index of the current library state (`AppModel.searchIndex()`): built once per
/// change and off the caller's thread (a large library takes a moment); every search then only
/// combines prepared sets. A change while an index is being built (`invalidate()`) makes every
/// request, also one already waiting, get the index of the new state.
@MainActor
public final class SearchIndexStore {
    private var cache: SearchIndex?
    private var task: Task<SearchIndex, Never>?
    private var generation = 0

    public init() {}

    /// The library, its albums or the names of places changed: the next request builds anew.
    public func invalidate() {
        cache = nil
        task = nil
        generation += 1
    }

    /// Lets go of a finished index (memory warning); one still being built is left to finish.
    /// Returns the index let go of, so the caller can free it off the main thread.
    public func dropCache() -> SearchIndex? {
        defer { cache = nil }
        return cache
    }

    /// The index of the current state. `prepare` is called on the caller's actor and takes the
    /// inputs as they are now; the build it returns runs off it.
    /// A change while it waits (review G4-05) never hands out the index of the old state: the
    /// request waits for the index of the new one, built once for every request waiting.
    public func index(_ prepare: () -> @Sendable () async -> SearchIndex) async -> SearchIndex {
        while true {
            if let cache { return cache }
            let generation = generation
            let task: Task<SearchIndex, Never>
            if let running = self.task {
                task = running
            } else {
                task = Task.detached(priority: .userInitiated, operation: prepare())
                self.task = task
            }
            let index = await task.value
            // The library or the names changed meanwhile: the index of the new state, built by
            // the next pass or already started by another request.
            guard generation == self.generation else { continue }
            cache = index
            self.task = nil
            return index
        }
    }
}
