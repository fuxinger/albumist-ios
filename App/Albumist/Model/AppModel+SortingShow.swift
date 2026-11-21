import Foundation
import AlbumistCore

/// What the sorting show needs from the model (DS-17, design wave 3): its albums with the photos
/// that may fly and the covers they show, by the same care as the result's stack that follows it
/// (`resultCoverSources`: the cover each card showed, and the personal suggestions, whose photos
/// never show). Kept apart from `AppModel.swift`.
extension AppModel {
    /// The albums of the show for `filled` (`PlanReviewFacts.filledAlbums`) of `plan`, taken as
    /// the plan starts: the photos' ranks (never a sensitive document), dates and favourites
    /// pick each album's cover (`SortingShowAlbum.cast`).
    func sortingShowAlbums(_ filled: [FilledAlbum], plan: ChangePlan) -> [SortingShowAlbum] {
        guard !filled.isEmpty else { return [] }
        let sources = resultCoverSources(for: plan)
        let facts = factsByID
        var favorites = Set<AssetID>()
        for album in filled {
            for id in album.assets where facts[id]?.asset.isFavorite == true { favorites.insert(id) }
        }
        return SortingShowAlbum.cast(filled, plan: plan, cardCovers: sources.covers, personal: sources.personal,
                                     ranks: previewRanks, dates: creationDates, favorites: favorites)
    }
}
