import Foundation

/// When the photo count last moved after Pause (test12, `measurePauseAndResume`). Plain
/// Foundation, so SwiftPM also builds it on Linux (target `SortlyUITestLogic`, tests in
/// `PauseCountCheckTests`).
///
/// TestFlight run 44461253154 (19.11.) failed here although the analysis had paused in time:
/// the count `before` was read before the tap, the tap took 6.62 s, the first look after it
/// already read "Analyse pausiert 224 …" (16 photos more, finished during the tap), but the
/// count was read again only after that look and the Fortsetzen check, 1.18 s after the tap,
/// and that read was taken as the time the count moved (limit: Fortsetzen 0.68 s + 0.5 s).
/// A move is now dated to the earliest moment it can have happened: the start of the look
/// before the one that saw it. The app's own record of the line, with the app's clock, is the
/// first measure; the looks are the fallback when the record cannot be read.
enum PauseCountCheck {
    /// The photos done in a progress line ("Bildinhalte werden erkannt 1.075 von 10.246 Fotos,
    /// …" gives 1075); nil when the line has no count.
    static func done(in line: String) -> Int? {
        let digits = line.replacingOccurrences(of: ".", with: "")
        guard let m = digits.firstMatch(of: #/(\d+) von (\d+) /#) else { return nil }
        return Int(m.1)
    }

    /// When the app took the Pause touch, from its record: the first line after the tap's start
    /// that says "Wird angehalten" or "Analyse pausiert" (Pause changes the card in the touch's
    /// own call). Nil when no line says either.
    static func reactedInRecord(_ lines: [(at: Date, line: String?)]) -> Date? {
        lines.first { row in
            guard let line = row.line else { return false }
            return line.hasPrefix("Wird angehalten") || line.hasPrefix("Analyse pausiert")
        }?.at
    }

    /// Where a main-thread stall counts as holding the Pause (test12: under 1 s). It ends, as
    /// before, a second after the tap returned (or after the card reacted, if that was later):
    /// a hold the Pause causes after its reaction keeps XCTest's tap waiting and still counts.
    /// With the app's record it starts a second before the card reacted: a touch that waited
    /// for a stall is taken right after it ends, so a stall that ended earlier did not hold it.
    /// XCTest's tap first waits for the app to go idle (19.47 s in stress run 44777843545 on a
    /// Mac at load 360–500, where a 3.2 s stall ended about 1.5 s before the card reacted and
    /// was counted although the Pause itself reacted at once); a stall in that wait comes before
    /// the touch. Without the record it starts at the tap's start, as before.
    static func stallWindow(tapStarted: Date, tapped: Date, reacted: Date?) -> (from: Date, to: Date) {
        let to = max(tapped, reacted ?? tapped).addingTimeInterval(1)
        guard let reacted else { return (tapStarted, to) }
        return (max(tapStarted, reacted.addingTimeInterval(-1)), to)
    }

    /// Whether a stall (its end and length) overlaps a window.
    static func overlaps(stallEnd: Date, ms: Int, from: Date, to: Date) -> Bool {
        let start = stallEnd.addingTimeInterval(-Double(ms) / 1000)
        return start <= to && stallEnd >= from
    }

    /// From the app's record (time, line; nil at a relaunch) between the Pause tap and the
    /// Fortsetzen tap: when the card first said "Analyse pausiert" (Fortsetzen shows from then
    /// on, `AnalysisProgressCard.control`), the count then, and the last time the count moved
    /// after it with the photos it moved by (`lastMove` nil: it did not move). Any line counts,
    /// also one that runs again without Fortsetzen. Nil when no line says paused.
    static func afterPausedInRecord(_ lines: [(at: Date, line: String?)]) -> (paused: Date, count: Int, lastMove: Date?, more: Int)? {
        guard let first = lines.firstIndex(where: { $0.line?.hasPrefix("Analyse pausiert") ?? false }),
              let line = lines[first].line, let count = done(in: line) else { return nil }
        var last = count
        var lastMove: Date?
        for row in lines[(first + 1)...] {
            // A relaunch or the line gone: the count after it is no longer this pause's.
            guard let line = row.line, line != "-" else { break }
            if let now = done(in: line), now != last { last = now; lastMove = row.at }
        }
        return (lines[first].at, count, lastMove, last - count)
    }

    /// From the test's own looks after the tap: `before` read at `readBefore` (before the tap),
    /// then each look's start and the count it read. Returns the earliest time the last move
    /// can have happened: a look that reads another count than the look before it saw a move
    /// that came after that earlier look began. Nil: the count never moved.
    static func lastMoveFromLooks(before: Int, readBefore: Date, looks: [(at: Date, count: Int?)]) -> Date? {
        var last = before
        var previous = readBefore
        var lastMove: Date?
        for look in looks {
            if let now = look.count, now != last { last = now; lastMove = previous }
            previous = look.at
        }
        return lastMove
    }
}
