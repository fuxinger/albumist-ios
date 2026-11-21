import Foundation
import AlbumistCore

/// The search page's starting points with their pictures (design wave 3, DS-13).
extension AppModel {
    /// The starting points of the empty search field, each with a photo of its own from the
    /// library (`SearchStartingPoints`): the towns with the most photos, the trips, the newest
    /// year, a topic and a kind. Worked out off the main thread from the search index the
    /// search itself uses (each starting point is one search); in the language of the chips
    /// (`featuredSearches`). Empty before the analysis has facts: the page keeps its words then.
    func searchStartingPoints() async -> [SearchStartingPoint] {
        let index = await searchIndex()
        let facts = facts, ranks = previewRanks, dates = creationDates
        let english = !(Bundle.main.preferredLocalizations.first?.hasPrefix("de") ?? true)
        return await Task.detached(priority: .userInitiated) {
            SearchStartingPoints.make(index: index, facts: facts, ranks: ranks, dates: dates, english: english)
        }.value
    }
}
