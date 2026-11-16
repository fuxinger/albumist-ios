import Foundation

/// Why the overview has no suggestions to show, once the analysis is done (plugin review K6).
///
/// App Review devices often hold only a handful of photos without a place. Before, the
/// overview then said "0 von 0 sortiert", "Analyse aktuell" and "Noch keine Vorschläge" in
/// every area, and nothing explained that Albumist needs photos with a date and a place
/// (from trips, for example). This decides which explanation the overview shows, and when it
/// shows none: while an analysis runs, is paused or is rebuilt, nothing is said yet, so a
/// library is never called empty before Albumist has looked at it.
public enum EmptyLibraryState: Hashable, Sendable {
    /// Albumist sees no photo at all (full access).
    case emptyLibrary
    /// Only selected photos are shared, and none is selected.
    case nothingShared
    /// The trial year chosen at the start has no photos.
    case emptyTrialYear(Int)
    /// Fewer photos than the smallest album needs.
    case fewPhotos(Int)
    /// Enough photos, but none has a place (the camera did not save locations).
    case noPlaces(Int)
    /// Photos with places, but no group big enough for an album yet.
    case nothingFound(Int)

    public struct Input: Hashable, Sendable {
        /// Photos and videos Albumist sees in the part of the library it works on.
        public var photos: Int
        /// Of those, the ones with a location.
        public var photosWithPlace: Int
        /// All suggestions of the last analysis, decided or not.
        public var proposals: Int
        public var analysisRunning: Bool
        /// Paused by the user or the device, or ended early and going on at the next start.
        public var analysisPaused: Bool
        /// The analysis went through the whole library at least once.
        public var analysedOnce: Bool
        /// "Analyse neu aufbauen": the suggestions are being made again.
        public var recounting: Bool
        public var limitedAccess: Bool
        /// The trial year chosen at the start, nil for the whole library.
        public var trialYear: Int?
        /// The fewest photos a place or a trip needs for an album (the settings' minimum).
        public var minimumPhotos: Int

        public init(photos: Int, photosWithPlace: Int, proposals: Int, analysisRunning: Bool, analysisPaused: Bool = false,
                    analysedOnce: Bool, recounting: Bool = false, limitedAccess: Bool = false, trialYear: Int? = nil,
                    minimumPhotos: Int = EmptyLibraryState.defaultMinimumPhotos) {
            self.photos = photos
            self.photosWithPlace = photosWithPlace
            self.proposals = proposals
            self.analysisRunning = analysisRunning
            self.analysisPaused = analysisPaused
            self.analysedOnce = analysedOnce
            self.recounting = recounting
            self.limitedAccess = limitedAccess
            self.trialYear = trialYear
            self.minimumPhotos = minimumPhotos
        }
    }

    /// The smallest place and trip albums with the default settings.
    public static let defaultMinimumPhotos = min(PlaceSettings().minPhotos, TripSettings().minPhotos)

    /// Nil when there is nothing to explain: suggestions exist, or the analysis is not done.
    public static func evaluate(_ input: Input) -> EmptyLibraryState? {
        guard !input.analysisRunning, !input.analysisPaused, !input.recounting, input.analysedOnce else { return nil }
        if input.photos <= 0 {
            if let year = input.trialYear { return .emptyTrialYear(year) }
            return input.limitedAccess ? .nothingShared : .emptyLibrary
        }
        guard input.proposals == 0 else { return nil }
        if input.photos < max(1, input.minimumPhotos) { return .fewPhotos(input.photos) }
        if input.photosWithPlace == 0 { return .noPlaces(input.photos) }
        return .nothingFound(input.photos)
    }

    /// Whether the photo count is needed: only when no suggestion exists. Counting the
    /// photos with a place goes through every photo, so the overview skips it otherwise.
    public static func needsPlaceCount(proposals: Int) -> Bool { proposals == 0 }
}
