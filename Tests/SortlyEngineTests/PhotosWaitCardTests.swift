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
}
