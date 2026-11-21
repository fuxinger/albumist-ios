import Foundation
import AlbumistCore

/// What the sorting show needs from the model (DS-17, design wave 3): its albums with the photos
/// that may fly and the covers they show, by the same care as the result's stack that follows it
/// (`resultCoverSources`: the cover each card showed, and the personal suggestions, whose photos
/// never show). Kept apart from `AppModel.swift`.
extension AppModel {
    /// The albums of the show for `filled` (`PlanReviewFacts.filledAlbums`) of `plan`, taken as
    /// the plan starts: `sources`, what the result's stack takes of the suggestions at the same
    /// time (`resultCoverSources`, taken once for both); the photos' ranks (never a sensitive
    /// document), dates and favourites pick each album's cover (`SortingShowAlbum.cast`). The
    /// walk over every photo of the plan runs off the main thread, on copies of what the model
    /// keeps (second review, K10: on the main actor it held the tap on "Anlegen" for a large plan).
    func sortingShowAlbums(_ filled: [FilledAlbum], plan: ChangePlan, sources: ResultCoverSources) async -> [SortingShowAlbum] {
        guard !filled.isEmpty else { return [] }
        let facts = factsByID
        let ranks = previewRanks
        let dates = creationDates
        let covers = sources.covers
        let personal = sources.personal
        return await Task.detached(priority: .userInitiated) {
            var favorites = Set<AssetID>()
            for album in filled {
                for id in album.assets where facts[id]?.asset.isFavorite == true { favorites.insert(id) }
            }
            return SortingShowAlbum.cast(filled, plan: plan, cardCovers: covers, personal: personal,
                                         ranks: ranks, dates: dates, favorites: favorites)
        }.value
    }
}
