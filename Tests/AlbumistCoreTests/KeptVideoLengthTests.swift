import Testing
@testable import AlbumistCore

/// The thumbnails keep each video's length (`ThumbnailCache`, design wave 3, DS-16) from the
/// asset their lookup fetched; a change in Photos corrects it (review F, F14 c), and the cells on
/// screen follow at once (review V4): a video trimmed in Photos showed its old length on its
/// badge and to VoiceOver until its cell was built anew.
@Suite("Kept video lengths follow a change in Photos (V4)")
struct KeptVideoLengthTests {
    /// A video trimmed in Photos takes its new length, and the cells on screen read theirs again:
    /// its badge and VoiceOver's "Video, 20 Sekunden" follow at once.
    @Test func aTrimmedVideoTakesItsNewLengthAndTheCellsReadItAgain() {
        let step = KeptVideoLength.step(kept: 45, inMemory: true, found: .changed(seconds: 20))
        #expect(step == .update(seconds: 20, shown: true))
        #expect(step.readsAgain)
    }

    /// A video the change did not touch, or touched without a new length (a favourite, a colour
    /// edit), keeps its record, and nothing on screen reads again. A length that moved by less
    /// than the badge shows is kept, without a read.
    @Test func anUntouchedVideoKeepsItsRecord() {
        #expect(KeptVideoLength.step(kept: 45, inMemory: true, found: nil) == .keep)
        #expect(KeptVideoLength.step(kept: 45, inMemory: true, found: .changed(seconds: 45)) == .keep)
        #expect(!KeptVideoLength.Step.keep.readsAgain)
        let close = KeptVideoLength.step(kept: 45.2, inMemory: true, found: .changed(seconds: 45.4))
        #expect(close == .update(seconds: 45.4, shown: false))
        #expect(!close.readsAgain)
    }

    /// A deleted video's record goes, and the cells on screen read again.
    @Test func aDeletedVideosRecordGoes() {
        let step = KeptVideoLength.step(kept: 45, inMemory: true, found: .deleted)
        #expect(step == .drop(checked: true))
        #expect(step.readsAgain)
    }

    /// A record whose asset is no longer in memory cannot be checked against the change: it goes
    /// with the thumbnail kept for it, so the next look asks Photos again and writes it anew; an
    /// old length never stays on unchecked. A cell on screen keeps what it shows meanwhile.
    @Test func aRecordWithoutItsAssetGoesUnchecked() {
        let answers: [KeptVideoLength.Found?] = [nil, .changed(seconds: 20), .deleted]
        for found in answers {
            #expect(KeptVideoLength.step(kept: 45, inMemory: false, found: found) == .drop(checked: false),
                    "\(String(describing: found))")
        }
        #expect(!KeptVideoLength.Step.drop(checked: false).readsAgain)
    }
}
