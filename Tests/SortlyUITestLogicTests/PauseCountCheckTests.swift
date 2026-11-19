import Foundation
import Testing
@testable import SortlyUITestLogic

/// test12's pause check (`PauseCountCheck`), with the numbers of TestFlight run 44461253154.
@Suite("Stress test pause check")
struct PauseCountCheckTests {
    let tapped = Date(timeIntervalSince1970: 1_000_000)
    func t(_ seconds: Double) -> Date { tapped.addingTimeInterval(seconds) }

    @Test func readsTheDoneCountWithThousands() {
        #expect(PauseCountCheck.done(in: "Bildinhalte werden erkannt 1.075 von 10.246 Fotos, Schritt 4 von 6") == 1075)
        #expect(PauseCountCheck.done(in: "Analyse pausiert 224 von 10.246 Fotos, Schritt 4 von 6, Analyse zu 42 % fertig") == 224)
        #expect(PauseCountCheck.done(in: "Wird angehalten") == nil)
    }

    /// Run 44461253154: `before` 208 was read before the tap (6.62 s), the first count read
    /// after it came 1.1841 s after the tap and said 224, Fortsetzen showed at 0.6823 s. The 16
    /// photos were finished during the tap, so the move is no later than the tap's start.
    @Test func aMoveDuringTheTapIsNotAMoveAfterFortsetzen() throws {
        let readBefore = t(-6.62)
        let lastMove = try #require(PauseCountCheck.lastMoveFromLooks(before: 208, readBefore: readBefore, looks: [(t(1.1841), 224), (t(2.4), 224), (t(3.6), 224)]))
        let resumeShown = 0.6823
        #expect(max(0, lastMove.timeIntervalSince(tapped)) <= resumeShown + 0.5)
    }

    /// A count that moves between two looks that both came after Fortsetzen is a real move
    /// after the pause, dated to the earlier of the two looks.
    @Test func aMoveBetweenLooksAfterFortsetzenIsFound() throws {
        let lastMove = try #require(PauseCountCheck.lastMoveFromLooks(before: 208, readBefore: t(-1), looks: [(t(0), 224), (t(0.7), 224), (t(2.0), 224), (t(3.0), 230), (t(4.0), 230)]))
        #expect(lastMove == t(2.0))
        #expect(lastMove.timeIntervalSince(tapped) > 0.68 + 0.5)
        #expect(PauseCountCheck.lastMoveFromLooks(before: 224, readBefore: t(-1), looks: [(t(0), 224), (t(1), nil), (t(2), 224)]) == nil)
    }

    @Test func theRecordFindsCountingAfterPaused() throws {
        let lines: [(at: Date, line: String?)] = [
            (t(0), "Wird angehalten 216 von 10.246 Fotos, Schritt 4 von 6"),
            (t(0.3), "Analyse pausiert 224 von 10.246 Fotos, Schritt 4 von 6"),
            (t(2.5), "Analyse pausiert 226 von 10.246 Fotos, Schritt 4 von 6"),
            // Running again without Fortsetzen still counts.
            (t(4.0), "Bildinhalte werden erkannt 230 von 10.246 Fotos, Schritt 4 von 6"),
            (t(5.0), nil),
            (t(6.0), "Bildinhalte werden erkannt 300 von 10.246 Fotos, Schritt 4 von 6"),
        ]
        let found = try #require(PauseCountCheck.afterPausedInRecord(lines))
        #expect(found.paused == t(0.3))
        #expect(found.count == 224)
        #expect(found.lastMove == t(4.0))
        #expect(found.more == 6)
    }

    @Test func theRecordWithAHeldPause() throws {
        let lines: [(at: Date, line: String?)] = [
            (t(0), "Bildinhalte werden erkannt 216 von 10.246 Fotos, Schritt 4 von 6"),
            (t(0.4), "Analyse pausiert 224 von 10.246 Fotos, Schritt 4 von 6"),
            (t(0.6), "Analyse pausiert 224 von 10.246 Fotos, Schritt 4 von 6, Analyse zu 42 % fertig"),
        ]
        let found = try #require(PauseCountCheck.afterPausedInRecord(lines))
        #expect(found.lastMove == nil)
        #expect(found.more == 0)
        #expect(PauseCountCheck.afterPausedInRecord(Array(lines.prefix(1))) == nil)
    }
}
