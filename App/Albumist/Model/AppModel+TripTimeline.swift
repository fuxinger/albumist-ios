import Foundation
import AlbumistCore

/// "Reise anpassen" as a timeline (design wave 3, DS-14): what it shows of a trip, made off the
/// main thread once for the trip, its neighbours and the facts (review G6: the sheet worked out
/// every day, the trip's span and each neighbour's in its body at every tap).
extension AppModel {
    /// The timeline of `trip` with the trips right `before` and `after` it
    /// (`TripTimeline.content`): its days as the split takes them, in the calendar the split
    /// uses, what each one shows, and the days without photos between it and them.
    func tripTimeline(of trip: AlbumProposal, before: AlbumProposal?, after: AlbumProposal?) async -> TripTimeline.Content {
        let photos = trip.assetIDs, earlier = before?.assetIDs, later = after?.assetIDs
        let facts = factsByID, ranks = previewRanks, dates = creationDates, calendar = Calendar.current
        return await Task.detached(priority: .userInitiated) {
            TripTimeline.content(of: photos, before: earlier, after: later, facts: facts, ranks: ranks, dates: dates, calendar: calendar)
        }.value
    }
}
