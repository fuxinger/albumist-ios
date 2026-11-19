import Foundation
import Testing
import SortlyCore
import SortlyEngine

/// App-speed (18.11.2026): while Photos does not answer, the analysis card says so ("Fotos
/// antwortet gerade nicht") instead of a count standing still, and a run that ended on it is
/// never shown as finished.
@Suite("Card while Photos does not answer")
struct PhotosWaitCardTests {
    let position = AnalysisCardState.Position(step: AnalysisStep(.inventory), completed: 0, total: 50_000)

    @Test func runningRunWaitingForPhotosSaysSo() {
        var i = AnalysisCardState.Inputs()
        i.isRunning = true
        i.position = position
        #expect(AnalysisCardState.resolve(i) == .running(position, slower: nil, appleWait: false, catchingUp: nil))
        i.photosNotResponding = true
        #expect(AnalysisCardState.resolve(i) == .waiting(.photos, position))
        // A quick check that waits for Photos says so too.
        i.isQuickCheck = true
        #expect(AnalysisCardState.resolve(i) == .waiting(.photos, position))
        // Pause tapped meanwhile: the Pause is said.
        i.pausingFor = .seconds(1)
        #expect(AnalysisCardState.resolve(i) == .pausing(position, longer: false))
        #expect(AnalysisCardState.waiting(.photos, position).isWorking == false)
    }

    @Test func runThatEndedOnPhotosIsNotFinished() {
        var i = AnalysisCardState.Inputs()
        i.pausedAt = position
        i.photosNotResponding = true
        i.finished = (photos: 10, proposals: 2)
        #expect(AnalysisCardState.resolve(i) == .waiting(.photos, position))
        // The user's Pause stays a Pause.
        i.pausedByUser = true
        #expect(AnalysisCardState.resolve(i) == .paused(position))
    }

    /// A run that ended because a call into Photos never got a thread (Albumist's own work kept
    /// them all busy) says so and goes on by itself; before, it ended silently with the card of
    /// an earlier finished run, and after two more such ends it stopped for good (review of
    /// f7439fb, MF1).
    @Test func runThatEndedOnABusyAlbumistSaysSo() {
        var i = AnalysisCardState.Inputs()
        i.pausedAt = position
        i.albumistBusy = true
        i.finished = (photos: 10, proposals: 2)
        #expect(AnalysisCardState.resolve(i) == .waiting(.busy, position))
        #expect(AnalysisCardState.waiting(.busy, position).isWorking == false)
        // Photos not answering is said first; the user's Pause stays a Pause.
        i.photosNotResponding = true
        #expect(AnalysisCardState.resolve(i) == .waiting(.photos, position))
        i.pausedByUser = true
        #expect(AnalysisCardState.resolve(i) == .paused(position))
    }

    /// Such an end is tried again every minute without a cap, like Photos not answering:
    /// nothing was sent, and the tries of other early ends (Vision) are not used up.
    @Test func aBusyEndIsTriedAgainEveryMinute() {
        let start = ContinuousClock.now
        var retry = UnattendedRetry()
        #expect(retry.schedule(after: nil, now: start) == .seconds(30))
        retry.runStarted()
        #expect(retry.schedule(after: nil, now: start + .seconds(40)) == .seconds(60))
        retry.runStarted()
        #expect(retry.schedule(after: nil, now: start + .seconds(200)) == nil)
        for minute in 0..<5 {
            let now = start + .seconds(300 + 60 * minute)
            #expect(retry.schedule(after: .busy, now: now) == UnattendedRetry.photosDelay)
            #expect(!retry.startsOnRelease(now: now + .seconds(59)))
            retry.runStarted()
        }
        #expect(retry.tries == 2)
        #expect(retry.schedule(after: .photos, now: start + .seconds(900)) == UnattendedRetry.photosDelay)
    }
}
