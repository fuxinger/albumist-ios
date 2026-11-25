import Testing
@testable import AlbumistCore

/// The thumbnails keep each video's length (`ThumbnailCache`, design wave 3, DS-16) from the
/// asset their lookup fetched; a change in Photos corrects it (review F, F14 c), and the cells on
/// screen follow once the change was walked, some seconds after it (review V4): a video trimmed in
/// Photos showed its old length on its badge and to VoiceOver until its cell was built anew.
@Suite("Kept video lengths follow a change in Photos (V4)")
struct KeptVideoLengthTests {
    /// A video trimmed in Photos takes its new length, and the cells on screen read theirs again:
    /// its badge and VoiceOver's "Video, 20 Sekunden" follow without the cell being made anew.
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
    /// old length never stays on unchecked. The cells on screen read again (review X1): a cell
    /// that shows the video's length asks Photos again (`reading`). Before, it was told nothing,
    /// and a video trimmed while its asset was out of memory (after a trip to Photos) kept its old
    /// length on screen until its cell was made anew.
    @Test func aRecordWithoutItsAssetGoesUnchecked() {
        let answers: [KeptVideoLength.Found?] = [nil, .changed(seconds: 20), .deleted]
        for found in answers {
            #expect(KeptVideoLength.step(kept: 45, inMemory: false, found: found) == .drop(checked: false),
                    "\(String(describing: found))")
        }
        #expect(KeptVideoLength.Step.drop(checked: false).readsAgain)
    }

    /// When the cells read again, a cell on screen shows the length the thumbnails know, the new
    /// one or the same. Knowing none is not "no video" (review X2): the cell keeps what it shows,
    /// and when it shows a length it asks Photos again (review X1), as its record went unchecked
    /// or a memory warning took it. A cell that shows no length has nothing to ask.
    @Test func aCellOnScreenAsksAgainForALengthTheThumbnailsNoLongerKnow() throws {
        let shown = try #require(VideoDuration(seconds: 45))
        let trimmed = try #require(VideoDuration(seconds: 20))
        #expect(KeptVideoLength.reading(shown: shown, known: trimmed) == .show(trimmed))
        #expect(KeptVideoLength.reading(shown: shown, known: shown) == .show(shown))
        #expect(KeptVideoLength.reading(shown: nil, known: trimmed) == .show(trimmed))
        #expect(KeptVideoLength.reading(shown: shown, known: nil) == .askAgain)
        #expect(KeptVideoLength.reading(shown: nil, known: nil) == .keep)
    }

    /// Once Photos answered, the cell shows the length it said, a trimmed video's new one; none
    /// when Photos no longer knows the video (deleted) or it has no length; what it showed when
    /// Photos did not answer in time (it asks again after the next change).
    @Test func aCellThatAskedAgainTakesWhatPhotosSaid() throws {
        let shown = try #require(VideoDuration(seconds: 45))
        #expect(KeptVideoLength.afterAsking(shown: shown, answer: .length(seconds: 20)) == VideoDuration(seconds: 20))
        #expect(KeptVideoLength.afterAsking(shown: shown, answer: .length(seconds: 45.2)) == shown)
        #expect(KeptVideoLength.afterAsking(shown: shown, answer: .noLength) == nil)
        #expect(KeptVideoLength.afterAsking(shown: shown, answer: .noAnswer) == shown)
        #expect(KeptVideoLength.afterAsking(shown: nil, answer: .noAnswer) == nil)
    }
}

/// The walk over the kept records of videos' lengths for changes in Photos (review V11): an
/// iCloud sync tells many changes in a row, and each one walked up to 20,000 records on the main
/// actor and asked Photos about every kept video; two walks in flight could end in the wrong
/// order. Now the changes wait in the order Photos told them, and one walk at a time takes all of
/// them: from the photo library watcher's debounced task, or at once when many wait.
@Suite("Changes in Photos wait for one walk over the records (V11)")
struct ChangeBacklogTests {
    /// The changes wait in the order Photos told them; one walk takes all of them at once, never
    /// one walk per change.
    @Test func oneWalkTakesAllTheChangesInTheirOrder() {
        var backlog = ChangeBacklog<Int>(limit: 32)
        for change in 1...5 {
            let now = backlog.arrived(change)
            #expect(!now, "\(change)")
        }
        let walk = backlog.take(recordsKept: true)
        #expect(walk == [1, 2, 3, 4, 5])
        let second = backlog.take(recordsKept: true)
        #expect(second == nil, "a second walk while one runs")
        let next = backlog.walked()
        #expect(!next)
        let empty = backlog.take(recordsKept: true)
        #expect(empty == nil, "a walk with nothing to walk")
    }

    /// Two walks never run at once, so they cannot end in the wrong order: the changes that come
    /// during a walk wait for the next one. It follows at once when the watcher asked meanwhile;
    /// otherwise they wait for the watcher's pause.
    @Test func changesDuringAWalkWaitForTheNextOne() {
        var backlog = ChangeBacklog<Int>(limit: 32)
        _ = backlog.arrived(1)
        let first = backlog.take(recordsKept: true)
        #expect(first == [1])
        _ = backlog.arrived(2)
        _ = backlog.arrived(3)
        let asked = backlog.take(recordsKept: true)
        #expect(asked == nil, "the watcher asks while the walk runs")
        let followsAtOnce = backlog.walked()
        #expect(followsAtOnce, "the next walk follows at once")
        let second = backlog.take(recordsKept: true)
        #expect(second == [2, 3])
        _ = backlog.arrived(4)
        let followsLater = backlog.walked()
        #expect(!followsLater, "not asked meanwhile")
        #expect(backlog.count == 1)
        let third = backlog.take(recordsKept: true)
        #expect(third == [4])
    }

    /// Without a kept video record there is nothing to correct: the changes go unwalked (a record
    /// made later is read from Photos as it is then), and none is walked later.
    @Test func withoutARecordNothingIsWalked() {
        var backlog = ChangeBacklog<Int>(limit: 32)
        _ = backlog.arrived(1)
        let none = backlog.take(recordsKept: false)
        #expect(none == nil)
        #expect(backlog.count == 0)
        _ = backlog.arrived(2)
        let walk = backlog.take(recordsKept: true)
        #expect(walk == [2])
    }

    /// The watcher's pause starts anew with each change, and a long sync tells one every few
    /// seconds: at the limit the walk starts at once, so neither the waiting changes nor one walk
    /// grow without end. During a walk the limit waits for its end.
    @Test func atTheLimitTheWalkStartsAtOnce() {
        var backlog = ChangeBacklog<Int>(limit: 3)
        let first = backlog.arrived(1)
        let second = backlog.arrived(2)
        let third = backlog.arrived(3)
        #expect(!first)
        #expect(!second)
        #expect(third)
        let walk = backlog.take(recordsKept: true)
        #expect(walk == [1, 2, 3])
        for change in 4...6 {
            let now = backlog.arrived(change)
            #expect(!now, "\(change)")
        }
        let followsAtOnce = backlog.walked()
        #expect(followsAtOnce, "as many came meanwhile")
        let next = backlog.take(recordsKept: true)
        #expect(next == [4, 5, 6])
        let after = backlog.walked()
        #expect(!after)
    }
}
