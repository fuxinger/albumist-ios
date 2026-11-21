import Foundation
import Testing
@testable import AlbumistCore

/// What the overview explains when there are no suggestions (plugin review K6: an App Review
/// device with a handful of photos saw "0 von 0 sortiert" and nothing else). Every case of the
/// list: empty library, one photo, photos without GPS, limited access, a huge library, the
/// second run, the trial year.
@Suite("Empty library and too few photos")
struct EmptyLibraryStateTests {
    func state(photos: Int, withPlace: Int = 0, proposals: Int = 0, running: Bool = false, paused: Bool = false,
               analysedOnce: Bool = true, recounting: Bool = false, limited: Bool = false, year: Int? = nil) -> EmptyLibraryState? {
        EmptyLibraryState.evaluate(.init(photos: photos, photosWithPlace: withPlace, proposals: proposals, analysisRunning: running,
                                         analysisPaused: paused, analysedOnce: analysedOnce, recounting: recounting,
                                         limitedAccess: limited, trialYear: year))
    }

    @Test func emptyLibraryIsExplainedOnlyOnceTheAnalysisLookedAtIt() {
        #expect(state(photos: 0) == .emptyLibrary)
        // First start: nothing analysed yet, the facts are still empty. Not "empty" yet.
        #expect(state(photos: 0, analysedOnce: false) == nil)
        #expect(state(photos: 0, running: true) == nil)
        #expect(state(photos: 0, paused: true) == nil)
    }

    @Test func onePhotoIsTooFew() {
        #expect(state(photos: 1, withPlace: 1) == .fewPhotos(1))
        #expect(state(photos: 1) == .fewPhotos(1))
        // Just below and at the smallest album.
        let minimum = EmptyLibraryState.defaultMinimumPhotos
        #expect(state(photos: minimum - 1, withPlace: minimum - 1) == .fewPhotos(minimum - 1))
        #expect(state(photos: minimum, withPlace: minimum) == .nothingFound(minimum))
    }

    @Test func photosWithoutGPSAreExplainedAsSuch() {
        #expect(state(photos: 40, withPlace: 0) == .noPlaces(40))
        // A few photos with a place are not "no places".
        #expect(state(photos: 40, withPlace: 3) == .nothingFound(40))
        // Few photos without a place: the count is the first thing to say.
        #expect(state(photos: 6, withPlace: 0) == .fewPhotos(6))
    }

    @Test func limitedAccessWithNothingSelected() {
        #expect(state(photos: 0, limited: true) == .nothingShared)
        #expect(state(photos: 3, withPlace: 3, limited: true) == .fewPhotos(3))
        #expect(state(photos: 300, withPlace: 200, proposals: 4, limited: true) == nil)
    }

    @Test func hugeLibrary() {
        #expect(state(photos: 50_000, withPlace: 30_000, proposals: 812) == nil)
        // Scanned photos only (no place, no suggestions).
        #expect(state(photos: 50_000, withPlace: 0) == .noPlaces(50_000))
        #expect(state(photos: 50_000, withPlace: 30_000) == .nothingFound(50_000))
        // Still analysing: nothing is said while the suggestions are being made.
        #expect(state(photos: 50_000, withPlace: 30_000, running: true) == nil)
    }

    @Test func secondRunNeverFlashesTheEmptyCard() {
        // "Neu prüfen" after a full analysis: running, the old suggestions stay.
        #expect(state(photos: 8, withPlace: 8, running: true) == nil)
        // "Analyse neu aufbauen": the suggestions are gone until the new ones come.
        #expect(state(photos: 900, withPlace: 900, recounting: true) == nil)
        #expect(state(photos: 900, withPlace: 900, running: true, recounting: true) == nil)
        // The library was emptied since the first run: said after the check.
        #expect(state(photos: 0, analysedOnce: true) == .emptyLibrary)
        // Suggestions all decided: nothing to explain.
        #expect(state(photos: 900, withPlace: 900, proposals: 12) == nil)
    }

    @Test func trialYearWithoutPhotos() {
        #expect(state(photos: 0, year: 2019) == .emptyTrialYear(2019))
        #expect(state(photos: 0, limited: true, year: 2019) == .emptyTrialYear(2019))
        #expect(state(photos: 4, withPlace: 4, year: 2019) == .fewPhotos(4))
    }

    @Test func minimumFollowsTheDefaultSettings() {
        #expect(EmptyLibraryState.defaultMinimumPhotos == min(PlaceSettings().minPhotos, TripSettings().minPhotos))
        #expect(EmptyLibraryState.needsPlaceCount(proposals: 0))
        #expect(!EmptyLibraryState.needsPlaceCount(proposals: 1))
    }
}
