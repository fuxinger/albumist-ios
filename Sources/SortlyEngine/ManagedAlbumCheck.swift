import Foundation
import SortlyCore
import SortlyStore

/// The album check: what the user changed in Photos on Albumist's albums (renamed, moved,
/// photos taken out, deleted) becomes overrides, so Albumist never undoes a manual decision
/// (Scenarios E and F). The app runs it before every plan and when the overview refreshes.
///
/// What may not be the user's doing is left alone: the albums of every plan that is still
/// unfinished or whose results are not stored yet (plugin review W2; the check then gives the
/// same answer before and after those results are stored, so the order at launch does not
/// matter, review of 6c6ef79), and an album only the album list lacks (looked up on its own
/// first, W3).
public struct ManagedAlbumCheck: Sendable {
    public struct Outcome: Sendable {
        /// Albumist's albums as they are recorded now.
        public var managedAlbums: [ManagedAlbumState]
        /// The album list planning works with: exactly what was compared (audit 2, 1.5), with
        /// the albums found on their own.
        public var inventory: CollectionInventory
        /// The user changed something: the overrides and records were stored.
        public var foundChanges: Bool
    }

    let store: SortlyStore
    let library: any PhotoLibraryWriting
    let pause: Duration

    public init(store: SortlyStore, library: any PhotoLibraryWriting, pause: Duration = .milliseconds(300)) {
        self.store = store
        self.library = library
        self.pause = pause
    }

    /// - Parameter access: the photo access now. Only full access is compared: a limited
    ///   library would look like deleted albums and photos.
    /// - Throws: when the albums or the records cannot be read or stored. Nothing is recorded
    ///   then, and planning waits (fails closed, audit 2, 1.5).
    public func run(access: LibraryAccess, now: Date = Date()) async throws -> Outcome {
        let stored = try await store.managedAlbums()
        let listed = try await library.currentInventory()
        guard !stored.isEmpty, access == .full else {
            return Outcome(managedAlbums: stored, inventory: listed, foundChanges: false)
        }
        let changing = try await store.collectionsInFlight()
        let checked = try await ManagedAlbumTracker().reconcile(stored, listed: listed, in: library, changing: changing, pause: pause, now: now)
        let result = checked.reconciliation
        if !result.changes.isEmpty {
            // Overrides and the new last-known state in one transaction: a manual change is
            // never marked as seen without its override.
            try await store.applyReconciliation(overrides: result.newOverrides, managedAlbums: result.updatedStates)
        }
        return Outcome(managedAlbums: result.updatedStates, inventory: checked.inventory, foundChanges: !result.changes.isEmpty)
    }
}
