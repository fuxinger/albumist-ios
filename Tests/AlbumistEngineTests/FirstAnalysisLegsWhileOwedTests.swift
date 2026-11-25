import Foundation
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore

/// The legs count together for every run that may bring the first 100 % while it is owed, not
/// only before the first completion (verification review Y, Y2 and Y4, the lead's decision that
/// completes X9): the first analysis; after a first analysis too quick for "Analyse fertig", a run
/// of the library as a whole (another part of the library, "Analyse neu aufbauen"); after a quick
/// first analysis of only the shared photos, the run with every photo allowed that analyses the
/// rest, whose legs go on also where a check that missed a change dropped its resume position
/// (verification review Z, Z3). A check for new photos or a catch-up of new imports is decided
/// alone and never brings the moment; it never shows twice; the seven days are as they were.
@Suite("First analysis in legs while the moment is owed (Y2, Y4, Z3)")
struct FirstAnalysisLegsWhileOwedTests {
    typealias Leg = FirstAnalysisLegs.Leg
    typealias Run = FirstAnalysisMoment.Run
    static let start = FirstAnalysisLegsTests.start
    static let day: TimeInterval = 24 * 60 * 60
    static let week = FirstAnalysisMoment.owedAfterQuickFinish
    /// The first analysis, one of another part of the library, "Analyse neu aufbauen": no analysis
    /// completed since the marker was reset, every photo allowed.
    static let whole = Run(wholeLibrary: true, fullAccess: true)
    /// The first analysis of only the shared photos ("Ausgewählte Fotos").
    static let sharedPhotos = Run(wholeLibrary: true, fullAccess: false)
    /// A run with every photo allowed once the analysis was completed: the rest of the library
    /// after only the shared photos, or a check for new photos, a catch-up of new imports.
    static let everyPhoto = Run(wholeLibrary: false, fullAccess: true)

    static func celebrates(_ counted: Leg) -> Bool { FirstAnalysisLegsTests.celebrates(counted) }

    /// An installation as the store keeps it: the moment and the legs, told of each run as
    /// `AppModel` tells them.
    struct Installation {
        var moment = FirstAnalysisMoment(kept: nil, completedBefore: false)
        var legs = FirstAnalysisLegs()

        /// A run of `seconds` with the bar shown that ends `time` seconds after `start`, from the
        /// resume position (`goesOn`) or not. As it starts, the wait may be over, its legs count
        /// when it may bring the moment, and the moment says whether the legs before it go on
        /// (`legsGoOn`); as it ends, the moment hears it on screen with what "Analyse fertig" was
        /// decided on, which it returns.
        @discardableResult
        mutating func run(_ run: Run, _ seconds: Double, finished: Bool, goesOn: Bool = true,
                          endingAt time: TimeInterval) -> Leg {
            moment.lapse(at: FirstAnalysisLegsWhileOwedTests.start.addingTimeInterval(time - seconds))
            legs.started(mayBringMoment: moment.mayBeBrought(by: run), goesOn: moment.legsGoOn(with: run, fromPosition: goesOn))
            let counted = legs.ended(Leg(seconds: seconds, showedBar: true), finished: finished)
            let celebrates = FirstAnalysisLegsTests.celebrates(counted, finished: finished)
            moment.runEnded(run, finished: finished, celebrates: celebrates, onScreen: true,
                            at: FirstAnalysisLegsWhileOwedTests.start.addingTimeInterval(time))
            return counted
        }

        func isDue(at time: TimeInterval) -> Bool {
            moment.isDue(at: FirstAnalysisLegsWhileOwedTests.start.addingTimeInterval(time))
        }

        mutating func claim(at time: TimeInterval) -> Bool {
            moment.claim(at: FirstAnalysisLegsWhileOwedTests.start.addingTimeInterval(time), onScreen: true)
        }
    }

    /// Y2's scenario: "Nur 2026", 40 photos, done in 10 s: a quick first analysis, no "Analyse
    /// fertig". Then all years: 30,000 photos, left at 99 % after an hour, the rest a day later in
    /// 20 s. The legs of the whole library count together: "Analyse fertig", and on screen its
    /// 100 %.
    @Test func afterAQuickFirstAnalysisTheWholeLibraryInLegsIsCelebrated() {
        var phone = Installation()
        let first = phone.run(Self.whole, 10, finished: true, goesOn: false, endingAt: 10)
        #expect(!Self.celebrates(first) && phone.moment.kept == .owed && phone.moment.firstCompleted != nil)
        phone.run(Self.whole, 3600, finished: false, goesOn: false, endingAt: 4000)
        #expect(phone.legs.kept == Leg(seconds: 3600, showedBar: true), "the hour of the whole library is not kept")
        let last = phone.run(Self.whole, 20, finished: true, endingAt: Self.day)
        #expect(last == Leg(seconds: 3620, showedBar: true))
        #expect(Self.celebrates(last))
        #expect(phone.isDue(at: Self.day) && phone.moment.kept == .spent)
        #expect(phone.legs.kept == .none && !phone.legs.counting)
    }

    /// Y4's first scenario: a quick first analysis of 30 shared photos; "Alle Fotos" allowed; the
    /// analysis of the rest, cut off after five minutes, ends a day later in a leg of 12 s. Its
    /// legs count together: "Analyse fertig" and the 100 %.
    @Test func theRestWithEveryPhotoInLegsIsCelebrated() {
        var phone = Installation()
        phone.run(Self.sharedPhotos, 8, finished: true, goesOn: false, endingAt: 8)
        #expect(phone.moment.kept == .owed && phone.moment.sharedOnly)
        phone.run(Self.everyPhoto, 300, finished: false, goesOn: false, endingAt: 600)
        let last = phone.run(Self.everyPhoto, 12, finished: true, endingAt: Self.day)
        #expect(last == Leg(seconds: 312, showedBar: true))
        #expect(Self.celebrates(last))
        #expect(phone.isDue(at: Self.day) && phone.moment.kept == .spent && !phone.moment.sharedOnly)
    }

    /// Z3 (verification review Z, `m2`'s case C against D): 30 shared photos analysed in 8 s; "Alle
    /// Fotos" allowed; the rest runs an hour in one go while Albumist is open, and the user splits a
    /// trip meanwhile. It ends complete but with a change it missed (`AnalysisRunEnd.followUp`):
    /// not finished, and as a check (an analysis was completed before) it drops its resume
    /// position, so the follow-up starts without it. The rest's legs go on all the same: the
    /// follow-up of 6 s ends with "Analyse fertig" and the 100 %, as the same sequence does for a
    /// first analysis and for the whole library after a quick trial year, which keep their position
    /// there and go on from it (case D: 3,606 s).
    @Test func theRestThatMissedAChangeGoesOnWithItsLegs() {
        var first = Installation()
        first.run(Self.whole, 3600, finished: false, goesOn: false, endingAt: 3600)
        let fromPosition = first.run(Self.whole, 6, finished: true, endingAt: 3606)
        #expect(fromPosition == Leg(seconds: 3606, showedBar: true) && Self.celebrates(fromPosition))
        #expect(first.isDue(at: 3606) && first.moment.kept == .spent)
        var trialYear = Installation()
        trialYear.run(Self.whole, 10, finished: true, goesOn: false, endingAt: 10)
        trialYear.run(Self.whole, 3600, finished: false, goesOn: false, endingAt: 3700)
        let allYears = trialYear.run(Self.whole, 6, finished: true, endingAt: 3706)
        #expect(allYears == fromPosition && trialYear.isDue(at: 3706) && trialYear.moment.kept == .spent)
        var rest = Installation()
        rest.run(Self.sharedPhotos, 8, finished: true, goesOn: false, endingAt: 8)
        rest.run(Self.everyPhoto, 3600, finished: false, goesOn: false, endingAt: 3700)
        #expect(rest.legs.kept == Leg(seconds: 3600, showedBar: true) && rest.moment.sharedOnly)
        let followUp = rest.run(Self.everyPhoto, 6, finished: true, goesOn: false, endingAt: 3706)
        #expect(followUp == fromPosition, "the follow-up of the rest is decided alone")
        #expect(rest.isDue(at: 3706) && rest.moment.kept == .spent && !rest.moment.sharedOnly)
        #expect(rest.legs.kept == .none && !rest.legs.counting)
    }

    /// The rest keeps its legs until a run with every photo finishes it, also when its follow-up
    /// cannot start at once (a plan being written: the end leaves the work to a catch-up or to the
    /// next run, here a day later after a relaunch). A run that starts the analysis anew drops them:
    /// "Analyse neu aufbauen" or another part of the library, the library as a whole without a
    /// resume position.
    @Test func theRestKeepsItsLegsUntilARunFinishesIt() {
        var later = Installation()
        later.run(Self.sharedPhotos, 8, finished: true, goesOn: false, endingAt: 8)
        later.run(Self.everyPhoto, 3600, finished: false, goesOn: false, endingAt: 3700)
        // Relaunched: the legs as the store reads them.
        later.legs = FirstAnalysisLegs(kept: later.legs.kept, owed: later.moment.kept == .owed)
        let nextDay = later.run(Self.everyPhoto, 20, finished: true, goesOn: false, endingAt: Self.day)
        #expect(nextDay == Leg(seconds: 3620, showedBar: true), "the rest's next run is decided alone")
        #expect(later.isDue(at: Self.day) && later.moment.kept == .spent)
        var rebuilt = Installation()
        rebuilt.run(Self.sharedPhotos, 8, finished: true, goesOn: false, endingAt: 8)
        rebuilt.run(Self.everyPhoto, 3600, finished: false, goesOn: false, endingAt: 3700)
        let anew = rebuilt.run(Self.whole, 40, finished: false, goesOn: false, endingAt: 3800)
        #expect(anew == Leg(seconds: 40, showedBar: true), "a new analysis goes on with the rest's legs")
        #expect(rebuilt.legs.kept == anew && rebuilt.moment.kept == .owed)
    }

    /// Y4's second scenario: the rest is genuinely short, 12 s in one run: not celebrated, and the
    /// first finished run with every photo used up the shared photos' chance. Two days later a
    /// catch-up of 400 imported photos runs 45 s: "Analyse fertig" for it alone, never the 100 %.
    /// Within the week only a run of the library as a whole can still bring it.
    @Test func aShortRestUsesUpTheChanceAndACheckNeverBringsIt() {
        var phone = Installation()
        phone.run(Self.sharedPhotos, 8, finished: true, goesOn: false, endingAt: 8)
        let rest = phone.run(Self.everyPhoto, 12, finished: true, goesOn: false, endingAt: 600)
        #expect(!Self.celebrates(rest))
        #expect(phone.moment.kept == .owed && !phone.moment.sharedOnly)
        let check = phone.run(Self.everyPhoto, 45, finished: true, goesOn: false, endingAt: 2 * Self.day)
        #expect(check == Leg(seconds: 45, showedBar: true) && Self.celebrates(check))
        #expect(!phone.isDue(at: 2 * Self.day) && phone.moment.kept == .owed, "a catch-up brought the 100 %")
        // A catch-up that runs in legs counts alone too: it cannot bring the moment.
        phone.run(Self.everyPhoto, 40, finished: false, goesOn: false, endingAt: 3 * Self.day)
        #expect(phone.legs.kept == .none && !phone.legs.counting)
        // "Analyse neu aufbauen" within the week, celebrated on screen: now.
        phone.run(Self.whole, 60, finished: true, goesOn: false, endingAt: 4 * Self.day)
        #expect(phone.isDue(at: 4 * Self.day) && phone.moment.kept == .spent)
    }

    /// Never twice: once it was due and played, no later run brings it, in legs or not, and no
    /// legs count any more.
    @Test func itNeverComesTwice() {
        var phone = Installation()
        phone.run(Self.whole, 10, finished: true, goesOn: false, endingAt: 10)
        phone.run(Self.whole, 600, finished: false, goesOn: false, endingAt: 700)
        phone.run(Self.whole, 20, finished: true, endingAt: 800)
        #expect(phone.isDue(at: 800))
        let plays = phone.claim(at: 801)
        #expect(plays)
        phone.moment.ended()
        phone.run(Self.whole, 600, finished: false, goesOn: false, endingAt: 2000)
        #expect(phone.legs.kept == .none && !phone.legs.counting)
        phone.run(Self.whole, 20, finished: true, endingAt: 3000)
        let again = phone.claim(at: 3001)
        #expect(!again && !phone.isDue(at: 3001))
    }

    /// The seven days are as they were. Legs whose last one starts inside the week and ends after
    /// it count together, and "Analyse fertig" is celebrated, but the 100 % is too late; a run that
    /// starts after the week counts alone.
    @Test func afterTheSevenDaysTheLegsBringNothing() {
        var inside = Installation()
        inside.run(Self.whole, 10, finished: true, goesOn: false, endingAt: 10)
        inside.run(Self.whole, 3600, finished: false, goesOn: false, endingAt: Self.day)
        let late = inside.run(Self.whole, 40, finished: true, endingAt: Self.week + 20)
        #expect(late == Leg(seconds: 3640, showedBar: true) && Self.celebrates(late))
        #expect(!inside.isDue(at: Self.week + 20) && inside.moment.kept == .spent)
        var after = Installation()
        after.run(Self.whole, 10, finished: true, goesOn: false, endingAt: 10)
        after.run(Self.whole, 3600, finished: false, goesOn: false, endingAt: Self.day)
        let alone = after.run(Self.whole, 20, finished: true, endingAt: Self.week + 3600)
        #expect(alone == Leg(seconds: 20, showedBar: true))
        #expect(!after.isDue(at: Self.week + 3600) && after.moment.kept == .spent)
    }
}
