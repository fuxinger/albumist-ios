import Foundation
import Testing
@testable import AlbumistUITestLogic

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

    /// Stress run 44777843545: XCTest's tap took 19.47 s (it waits for the app to go idle on a
    /// Mac at load 360–500), the card said "Analyse pausiert" 0.09 s before the tap returned,
    /// and a 3.16 s main-thread stall (text layout of the progress line) ended about 1.5 s
    /// before that. The stall came before the touch and did not hold the Pause.
    @Test func aStallInXCTestsWaitBeforeTheTouchIsNotThePauses() throws {
        let tapStarted = t(-19.47)
        let lines: [(at: Date, line: String?)] = [
            (t(-19.0), "Bildinhalte werden erkannt 205 von 10.246 Fotos, Schritt 4 von 6"),
            (t(-0.09), "Analyse pausiert 237 von 10.246 Fotos, Schritt 4 von 6"),
        ]
        let reacted = try #require(PauseCountCheck.reactedInRecord(lines))
        #expect(reacted == t(-0.09))
        let window = PauseCountCheck.stallWindow(tapStarted: tapStarted, tapped: tapped, reacted: reacted)
        let stallEnd = reacted.addingTimeInterval(-1.5)
        // The old window (the tap's start to a second after it returned) counted it.
        #expect(PauseCountCheck.overlaps(stallEnd: stallEnd, ms: 3160, from: tapStarted, to: tapped.addingTimeInterval(1)))
        #expect(!PauseCountCheck.overlaps(stallEnd: stallEnd, ms: 3160, from: window.from, to: window.to))
    }

    /// A touch that waited for a stall is taken right after it: such a stall ends at the
    /// reaction and still counts, as does one in the second after it.
    @Test func aStallThatHeldTheTouchStillCounts() {
        let reacted = t(-0.2)
        let window = PauseCountCheck.stallWindow(tapStarted: t(-8), tapped: tapped, reacted: reacted)
        #expect(PauseCountCheck.overlaps(stallEnd: reacted.addingTimeInterval(-0.01), ms: 1390, from: window.from, to: window.to))
        #expect(PauseCountCheck.overlaps(stallEnd: reacted.addingTimeInterval(1.8), ms: 1300, from: window.from, to: window.to))
        #expect(window.to == tapped.addingTimeInterval(1))
    }

    /// "Wird angehalten" is the reaction when it comes first; without any reacting line in the
    /// record the window is the tap itself, as before.
    @Test func theFirstReactingLineDatesTheTouch() {
        let lines: [(at: Date, line: String?)] = [
            (t(-3), "Bildinhalte werden erkannt 205 von 10.246 Fotos"),
            (t(-0.5), "Wird angehalten"),
            (t(2), "Analyse pausiert 210 von 10.246 Fotos"),
        ]
        #expect(PauseCountCheck.reactedInRecord(lines) == t(-0.5))
        #expect(PauseCountCheck.reactedInRecord([(t(1), nil), (t(2), "Bildinhalte werden erkannt 1 von 2 Fotos")]) == nil)
        let window = PauseCountCheck.stallWindow(tapStarted: t(-7), tapped: tapped, reacted: nil)
        #expect(window.from == t(-7) && window.to == t(1))
        // Never before the tap's start.
        #expect(PauseCountCheck.stallWindow(tapStarted: t(-0.3), tapped: tapped, reacted: t(-0.2)).from == t(-0.3))
    }

    /// A hold the Pause causes after the card reacted keeps XCTest's tap waiting: the window
    /// still ends a second after the tap returned, so such a hold counts (second review).
    @Test func aHoldAfterTheReactionStillCountsUntilTheTapReturned() {
        let reacted = t(-4.2)
        let window = PauseCountCheck.stallWindow(tapStarted: t(-5), tapped: tapped, reacted: reacted)
        #expect(window.to == t(1))
        // Starts 1.2 s after the reaction, lasts 3 s, ends just before the tap returned.
        #expect(PauseCountCheck.overlaps(stallEnd: t(-0.01), ms: 3000, from: window.from, to: window.to))
        // A record line later than the tap's return (the card's render after it) moves the end.
        #expect(PauseCountCheck.stallWindow(tapStarted: t(-5), tapped: tapped, reacted: t(0.3)).to == t(1.3))
    }
}
