import Foundation
import AlbumistCore

/// The photo grids of design wave 3 (DS-21 "Unsortiert nach Tagen wie in Fotos", DS-06b): what
/// the model makes for them off the main thread.
extension AppModel {
    /// The photos of an area of "Unsortiert" (`items`, newest first) by day, as Photos shows
    /// its days (`InboxDays`): each photo on the day of the clock it was taken on, as the photo
    /// view reads it, the photos Albumist has no facts of yet on the home clock the analysis
    /// keeps (`homeTimeZone`), so they do not change their day when the analysis reaches them.
    ///
    /// Made off the main thread, as the areas themselves (`libraryBuckets`): it reads the facts
    /// of every photo of the area, 100,000 and more in a large library. The work stops early and
    /// gives nil when the caller is cancelled (the tab asks again for a newer area, or went).
    func inboxDays(_ items: [LibraryBuckets.Item]) async -> InboxDays? {
        let facts = factsByID, words = proposalWords
        let homeZone = await homeTimeZone()
        guard !Task.isCancelled else { return nil }
        let now = Date(), zone = TimeZone.current
        let work = Task.detached(priority: .userInitiated) {
            InboxDays.make(items, facts: facts, homeZone: homeZone, now: now, currentZone: zone, words: words) { Task.isCancelled }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}
