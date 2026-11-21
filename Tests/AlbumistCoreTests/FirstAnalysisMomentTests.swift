import Foundation
import Testing
@testable import AlbumistCore

/// DS-08: the one quiet moment when the first full analysis reaches 100 % on screen. Exactly
/// once per installation: not again after a relaunch, a later full re-analysis ("Analyse neu
/// aufbauen", another part of the library), a restored backup or an undo, and never when the
/// analysis ended while Albumist was not on screen (the notification "Analyse fertig" says it
/// then, as before).
@Suite("First analysis moment (DS-08)")
struct FirstAnalysisMomentTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A new installation, before its first analysis.
    static func fresh() -> FirstAnalysisMoment {
        FirstAnalysisMoment(kept: nil, completedBefore: false)
    }

    /// The end of a run in the app, by default the first full analysis finishing on screen
    /// after a wait (`AnalysisCardState.celebratesFinish`).
    static func end(_ moment: inout FirstAnalysisMoment, finished: Bool = true, celebrates: Bool = true,
                    completedBefore: Bool = false, onScreen: Bool = true, after seconds: TimeInterval = 0) {
        moment.runEnded(finished: finished, celebrates: celebrates, completedBefore: completedBefore,
                        onScreen: onScreen, at: start.addingTimeInterval(seconds))
    }

    static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: Once

    @Test func aNewInstallationOwesIt() {
        let moment = Self.fresh()
        #expect(moment.kept == .owed)
        #expect(!moment.shows(at: Self.start))
        #expect(!moment.playing)
    }

    @Test func theFirstFullAnalysisFinishingOnScreenBringsItOnce() {
        var moment = Self.fresh()
        Self.end(&moment)
        // Spent the moment it is due: kept so at once, so a relaunch never brings it back.
        #expect(moment.kept == .spent)
        #expect(moment.isDue(at: Self.at(1)))
        #expect(moment.shows(at: Self.at(1)))
        var claimed = moment
        let plays = claimed.claim(at: Self.at(2), onScreen: true)
        #expect(plays)
        #expect(claimed.playing && claimed.shows(at: Self.at(2)))
        // The card appears again (another tab and back, a redraw): not a second time.
        let twice = claimed.claim(at: Self.at(3), onScreen: true)
        #expect(!twice)
        claimed.ended()
        #expect(!claimed.shows(at: Self.at(4)) && !claimed.playing)
        let afterwards = claimed.claim(at: Self.at(5), onScreen: true)
        #expect(!afterwards)
        // The next run that finishes (a check for new photos, "Neu prüfen") brings nothing.
        Self.end(&claimed, after: 60)
        #expect(!claimed.isDue(at: Self.at(61)))
        let nextRun = claimed.claim(at: Self.at(62), onScreen: true)
        #expect(!nextRun)
    }

    @Test func aRelaunchNeverBringsItAgain() {
        var moment = Self.fresh()
        Self.end(&moment)
        let plays = moment.claim(at: Self.at(1), onScreen: true)
        #expect(plays)
        moment.ended()
        // Relaunched: what was kept, and the analysis is complete.
        var relaunched = FirstAnalysisMoment(kept: moment.kept, completedBefore: true)
        #expect(relaunched.kept == .spent)
        Self.end(&relaunched, completedBefore: true, after: 3600)
        #expect(!relaunched.shows(at: Self.at(3601)))
        // Ended by iOS or force-quit after the run ended, before the card was on screen: the
        // next launch does not catch up on it ("reaches 100 %" was then).
        var cut = Self.fresh()
        Self.end(&cut)
        var next = FirstAnalysisMoment(kept: cut.kept, completedBefore: true)
        #expect(!next.shows(at: Self.at(30)))
        let caughtUp = next.claim(at: Self.at(30), onScreen: true)
        #expect(!caughtUp)
    }

    /// "Analyse neu aufbauen" and another part of the library ("Ganze Mediathek dazunehmen")
    /// reset where the analysis got to (`AnalysisMarker.reset`): their analysis counts as a
    /// first one again for the progress, never for this moment.
    @Test func aLaterFullReanalysisNeverBringsIt() {
        var moment = Self.fresh()
        Self.end(&moment)
        let plays = moment.claim(at: Self.at(1), onScreen: true)
        #expect(plays)
        moment.ended()
        // Rebuilt in the same launch: the marker says "not completed" again.
        Self.end(&moment, completedBefore: false, after: 7200)
        #expect(!moment.isDue(at: Self.at(7201)))
        // Rebuilt and relaunched before it finished.
        var later = FirstAnalysisMoment(kept: moment.kept, completedBefore: false)
        Self.end(&later, completedBefore: false, after: 9000)
        #expect(!later.isDue(at: Self.at(9001)))
        let rebuilt = later.claim(at: Self.at(9002), onScreen: true)
        #expect(!rebuilt)
    }

    /// An undo ("Rückgängig machen") and every other later run that finishes the analysis: the
    /// moment was the first time only.
    @Test func anUndoOrAnyLaterRunNeverBringsIt() {
        var moment = Self.fresh()
        Self.end(&moment)
        let plays = moment.claim(at: Self.at(1), onScreen: true)
        #expect(plays)
        moment.ended()
        for (index, completedBefore) in [true, false].enumerated() {
            for celebrates in [true, false] {
                Self.end(&moment, celebrates: celebrates, completedBefore: completedBefore, after: Double(100 + index))
                #expect(!moment.isDue(at: Self.at(Double(101 + index))))
            }
        }
    }

    // MARK: Seen reaching 100 %

    /// Finished while Albumist was not on screen (in the background, the screen locked): the user
    /// comes back minutes or hours later to "Analyse fertig" (and found the notification), not to
    /// a 100 % that happened without them. The chance is gone for good.
    @Test func finishedInTheBackgroundItNeverComes() {
        var moment = Self.fresh()
        Self.end(&moment, onScreen: false)
        #expect(moment.kept == .spent)
        #expect(!moment.isDue(at: Self.at(1)))
        // Back hours later.
        moment.cameToFront(completed: true)
        #expect(!moment.shows(at: Self.at(4 * 3600)))
        let back = moment.claim(at: Self.at(4 * 3600), onScreen: true)
        #expect(!back)
        // Relaunched instead.
        let relaunched = FirstAnalysisMoment(kept: moment.kept, completedBefore: true)
        #expect(relaunched.kept == .spent)
    }

    /// The analysis was completed where no run of the app ended (the overnight refinement, which
    /// iOS runs without the screen): spent as Albumist comes to the front again, so a rebuild in
    /// that launch cannot bring it either.
    @Test func completedWhileAwayItNeverComes() {
        var moment = Self.fresh()
        moment.cameToFront(completed: true)
        #expect(moment.kept == .spent)
        Self.end(&moment, completedBefore: false, after: 60)
        #expect(!moment.isDue(at: Self.at(61)))
        // The same when a run in the app ends after it: the marker said "completed" before it.
        var other = Self.fresh()
        Self.end(&other, completedBefore: true)
        #expect(other.kept == .spent)
        #expect(!other.isDue(at: Self.at(1)))
        // Nothing completed meanwhile: still owed.
        var waiting = Self.fresh()
        waiting.cameToFront(completed: false)
        #expect(waiting.kept == .owed)
    }

    /// Due, but Albumist left the screen before the card showed it (the wait for the overview, or
    /// the user left at once): not later.
    @Test func leavingBeforeItShowsSpendsIt() {
        var moment = Self.fresh()
        Self.end(&moment)
        moment.leftScreen()
        #expect(!moment.isDue(at: Self.at(1)))
        moment.cameToFront(completed: true)
        let back = moment.claim(at: Self.at(30), onScreen: true)
        #expect(!back)
        #expect(moment.kept == .spent)
    }

    /// Playing as Albumist leaves: it ends there and does not show on return.
    @Test func leavingWhileItPlaysEndsIt() {
        var moment = Self.fresh()
        Self.end(&moment)
        let plays = moment.claim(at: Self.at(1), onScreen: true)
        #expect(plays)
        moment.leftScreen()
        #expect(!moment.playing && !moment.shows(at: Self.at(2)))
        let back = moment.claim(at: Self.at(3), onScreen: true)
        #expect(!back)
    }

    /// On another tab when it finished: the card shows it when the user comes back to
    /// "Vorschläge" soon, not after `window` (then it was not "just now").
    @Test func itWaitsAShortWhileForTheCard() {
        var soon = Self.fresh()
        Self.end(&soon)
        let plays = soon.claim(at: Self.at(FirstAnalysisMoment.window - 1), onScreen: true)
        #expect(plays)
        var late = Self.fresh()
        Self.end(&late)
        #expect(late.shows(at: Self.at(FirstAnalysisMoment.window - 1)))
        #expect(!late.shows(at: Self.at(FirstAnalysisMoment.window + 1)))
        let lapsed = late.claim(at: Self.at(FirstAnalysisMoment.window + 1), onScreen: true)
        #expect(!lapsed)
        // Lapsed for good, also if the clock is set back.
        #expect(!late.isDue(at: Self.at(10)))
        #expect(late.kept == .spent)
        // A clock set back before the end of the run does not keep it waiting either.
        var back = Self.fresh()
        Self.end(&back, after: 100)
        #expect(!back.isDue(at: Self.at(50)))
        #expect(FirstAnalysisMoment.window >= 60 && FirstAnalysisMoment.window <= 10 * 60)
    }

    /// The card is there but Albumist is not on screen (Control Center, a call): it waits and
    /// plays once it is.
    @Test func offScreenTheCardWaits() {
        var moment = Self.fresh()
        Self.end(&moment)
        let offScreen = moment.claim(at: Self.at(1), onScreen: false)
        #expect(!offScreen)
        #expect(moment.isDue(at: Self.at(2)))
        let onScreen = moment.claim(at: Self.at(3), onScreen: true)
        #expect(onScreen)
    }

    /// The card went before the moment played (a run started meanwhile, off screen): it stays
    /// due, and the next "Analyse fertig" within the window brings it. Once it played, a card
    /// that goes ends it.
    @Test func aCardThatGoesBeforeItPlaysLeavesItDue() {
        var moment = Self.fresh()
        Self.end(&moment)
        moment.ended()
        #expect(moment.isDue(at: Self.at(60)))
        let plays = moment.claim(at: Self.at(90), onScreen: true)
        #expect(plays)
        moment.ended()
        #expect(!moment.playing && !moment.shows(at: Self.at(91)))
        let again = moment.claim(at: Self.at(92), onScreen: true)
        #expect(!again)
    }

    // MARK: What finishes the first analysis

    /// Paused, cut off by iOS or the device, ended by an error, a change of the settings left: the
    /// first analysis is not finished, and the moment stays owed for the run that finishes it
    /// (also after a relaunch: a resumed first analysis).
    @Test func unfinishedRunsKeepItOwed() {
        var moment = Self.fresh()
        for onScreen in [true, false] {
            for celebrates in [true, false] {
                Self.end(&moment, finished: false, celebrates: celebrates, onScreen: onScreen)
                #expect(moment.kept == .owed)
                #expect(!moment.isDue(at: Self.at(1)))
            }
        }
        var resumed = FirstAnalysisMoment(kept: moment.kept, completedBefore: false)
        Self.end(&resumed, after: 86_400)
        #expect(resumed.isDue(at: Self.at(86_401)))
    }

    /// A tiny library whose first analysis takes less than half a minute: no "Analyse fertig"
    /// card (`AnalysisCardState.celebratesFinish`), so no moment on it, and none later.
    @Test func aQuickFirstAnalysisHasNoMoment() {
        var moment = Self.fresh()
        Self.end(&moment, celebrates: false)
        #expect(moment.kept == .spent)
        #expect(!moment.isDue(at: Self.at(1)))
    }

    // MARK: Updates and backups

    /// Updated from a version without the moment, the analysis completed long ago: nothing to
    /// celebrate, also not after a rebuild.
    @Test func anUpdateAfterTheAnalysisNeverBringsIt() {
        var moment = FirstAnalysisMoment(kept: nil, completedBefore: true)
        #expect(moment.kept == .spent)
        Self.end(&moment, completedBefore: false)
        #expect(!moment.isDue(at: Self.at(1)))
        // Updated before the first analysis finished: still owed.
        #expect(FirstAnalysisMoment(kept: nil, completedBefore: false).kept == .owed)
    }

    /// A device backup brings `UserDefaults` back, but not the database: Albumist analyses the
    /// restored library from the start (`AnalysisMarker.reset`, read after this). The moment kept
    /// in the backup stands; a backup of a version without it that had completed the analysis
    /// spends it.
    @Test func aRestoredBackupKeepsWhatItSaid() {
        let restored: [(FirstAnalysisMoment.Kept?, Bool, FirstAnalysisMoment.Kept)] = [
            (.spent, true, .spent), (.spent, false, .spent), (nil, true, .spent), (.owed, true, .spent),
            // The phone it came from never finished its first analysis: this one may.
            (.owed, false, .owed), (nil, false, .owed),
        ]
        for (kept, completed, expected) in restored {
            var moment = FirstAnalysisMoment(kept: kept, completedBefore: completed)
            #expect(moment.kept == expected, "\(String(describing: kept)), completed \(completed)")
            Self.end(&moment, completedBefore: false)
            #expect(moment.isDue(at: Self.at(1)) == (expected == .owed), "\(String(describing: kept)), completed \(completed)")
        }
    }

    /// Spent stays spent, whatever comes.
    @Test func nothingTurnsSpentBackToOwed() {
        var moment = FirstAnalysisMoment(kept: .spent, completedBefore: false)
        for finished in [true, false] {
            for celebrates in [true, false] {
                for completedBefore in [true, false] {
                    for onScreen in [true, false] {
                        Self.end(&moment, finished: finished, celebrates: celebrates, completedBefore: completedBefore,
                                 onScreen: onScreen)
                        #expect(moment.kept == .spent)
                        let claimed = moment.claim(at: Self.at(1), onScreen: true)
                        #expect(!claimed)
                    }
                }
            }
        }
        moment.cameToFront(completed: false)
        moment.leftScreen()
        moment.ended()
        #expect(moment.kept == .spent && !moment.shows(at: Self.at(2)))
    }

    /// What is kept in `UserDefaults`: its names never change, or an update would lose it.
    @Test func theKeptNamesStay() {
        #expect(FirstAnalysisMoment.Kept.owed.rawValue == "owed")
        #expect(FirstAnalysisMoment.Kept.spent.rawValue == "spent")
        #expect(FirstAnalysisMoment.Kept(rawValue: "spent") == .spent)
        #expect(FirstAnalysisMoment.Kept(rawValue: "") == nil)
    }

    // MARK: How it plays

    /// Short and calm: the bar joins after the card settled, the whole is gone within four
    /// seconds, before the UI runs' usual wait for an idle start page (three checks two seconds
    /// apart) is over; with Reduce Motion it only fades. A UI test that asks for it finds it
    /// with those checks.
    @Test func itIsShort() {
        typealias T = FirstAnalysisMoment.Timing
        #expect(T.joinDelay > 0 && T.joinDelay + T.join < T.hold)
        #expect(T.hold + T.fold <= 4)
        #expect(T.fade > 0 && T.fade <= 0.35)
        #expect(T.heldForUITest >= 10 && T.heldForUITest <= 20)
    }

    // MARK: The bar joining

    static let shares = [0.05, 0.03, 0.12, 0.60, 0.12, 0.08]

    /// Before it joins, the bar is the analysis bar the user watched: six parts with 3 pt between
    /// them, each as wide as its step's share of what is left (`SegmentRow`), all round.
    @Test func theBarStartsAsTheAnalysisBar() throws {
        let width = 343.0
        let parts = FirstAnalysisMoment.segments(shares: Self.shares, width: width, joined: 0)
        #expect(parts.count == 6)
        let usable = width - 3 * 5
        var x = 0.0
        for (index, part) in parts.enumerated() {
            #expect(abs(part.x - x) < 0.0001, "\(index)")
            #expect(abs(part.width - usable * Self.shares[index]) < 0.0001, "\(index)")
            #expect(part.leadingRound == 1 && part.trailingRound == 1, "\(index)")
            x += part.width + 3
        }
        let last = try #require(parts.last)
        #expect(abs(last.x + last.width - width) < 0.0001)
    }

    /// Joined, it is one bar over the whole width, round at its two ends only.
    @Test func joinedItIsOneBar() throws {
        let parts = FirstAnalysisMoment.segments(shares: Self.shares, width: 343, joined: 1)
        let bar = try #require(parts.first)
        #expect(parts.count == 1)
        #expect(bar.x == 0 && bar.width == 343 && bar.leadingRound == 1 && bar.trailingRound == 1)
        // Past the end (a spring overshooting) it stays one bar.
        #expect(FirstAnalysisMoment.segments(shares: Self.shares, width: 343, joined: 1.2) == parts)
    }

    /// On the way the gaps close and the inner ends square off together; the outer ends stay
    /// round, nothing leaves the width.
    @Test func halfwayTheGapsClose() throws {
        let width = 343.0
        let half = FirstAnalysisMoment.segments(shares: Self.shares, width: width, joined: 0.5)
        #expect(half.count == 6)
        for index in 1..<half.count {
            let gap = half[index].x - (half[index - 1].x + half[index - 1].width)
            #expect(abs(gap - 1.5) < 0.0001, "\(index)")
        }
        #expect(half.first?.leadingRound == 1 && half.last?.trailingRound == 1)
        #expect(half.dropFirst().allSatisfy { $0.leadingRound == 0.5 })
        #expect(half.dropLast().allSatisfy { $0.trailingRound == 0.5 })
        let last = try #require(half.last)
        #expect(abs(last.x + last.width - width) < 0.0001)
        // Before the start (a spring undershooting) it is the analysis bar.
        #expect(FirstAnalysisMoment.segments(shares: Self.shares, width: width, joined: -0.1)
                == FirstAnalysisMoment.segments(shares: Self.shares, width: width, joined: 0))
    }

    /// Shares that do not add up to 1 fill the width all the same; nothing to draw without
    /// shares or width.
    @Test func oddSharesStillFillTheWidth() throws {
        let parts = FirstAnalysisMoment.segments(shares: [1, 1, 2], width: 200, joined: 0)
        #expect(parts.count == 3)
        let last = try #require(parts.last)
        #expect(abs(last.x + last.width - 200) < 0.0001)
        #expect(abs(parts[2].width - 2 * parts[0].width) < 0.0001)
        #expect(FirstAnalysisMoment.segments(shares: [], width: 200, joined: 0).isEmpty)
        #expect(FirstAnalysisMoment.segments(shares: Self.shares, width: 0, joined: 0).isEmpty)
        #expect(FirstAnalysisMoment.segments(shares: [0, 0], width: 200, joined: 0).isEmpty)
        // A narrow bar: never a negative width.
        #expect(FirstAnalysisMoment.segments(shares: Self.shares, width: 10, joined: 0).allSatisfy { $0.width >= 0 })
    }
}
