import Foundation
import Testing
@testable import AlbumistCore

/// DS-08 after a first analysis too quick for "Analyse fertig" (verification review V6): only a
/// run of the library as a whole brings the 100 % within seven days, or, after a quick first
/// analysis of only the shared photos, the first run with every photo allowed (verification
/// review Y, Y4). Split from `FirstAnalysisMomentTests`, whose helpers it uses.
@Suite("First analysis moment after a quick first analysis (DS-08, V6)")
struct FirstAnalysisMomentAfterQuickTests {
    typealias Moment = FirstAnalysisMomentTests
    static let week = FirstAnalysisMoment.owedAfterQuickFinish

    /// After a first analysis too quick for "Analyse fertig" only a run that analyses the library
    /// as a whole brings the 100 % ("Analyse neu aufbauen", another part of the library taken in:
    /// no analysis completed since `AnalysisMarker.reset`), never a check for new photos or a
    /// catch-up of new imports, however long it ran (the lead's decision on V6). The wait counts
    /// from the first completion; nothing moves it.
    @Test func afterAQuickFirstAnalysisOnlyTheWholeLibraryBringsIt() {
        var moment = Moment.fresh()
        Moment.end(&moment, celebrates: false)
        #expect(moment.kept == .owed)
        #expect(moment.firstCompleted == Moment.start)
        // "Sucht neue Fotos", a catch-up of 3,000 new photos: long enough for "Analyse fertig",
        // but not the whole library.
        Moment.end(&moment, wholeLibrary: false, after: 3600)
        #expect(!moment.isDue(at: Moment.at(3601)))
        #expect(moment.kept == .owed)
        #expect(moment.firstCompleted == Moment.start, "a check moved the wait")
        // Another quick run of the whole library does not move it either.
        Moment.end(&moment, celebrates: false, after: 7200)
        #expect(moment.firstCompleted == Moment.start, "a quick run moved the wait")
        // "Analyse neu aufbauen", celebrated on screen: now, once.
        Moment.end(&moment, after: 10_800)
        #expect(moment.isDue(at: Moment.at(10_801)))
        #expect(moment.kept == .spent && moment.firstCompleted == nil)
        // A check in the background does not spend it either: it was not the whole library.
        var checked = Moment.fresh()
        Moment.end(&checked, celebrates: false)
        Moment.end(&checked, wholeLibrary: false, onScreen: false, after: 60)
        #expect(checked.kept == .owed)
    }

    /// A quick first analysis of only the photos shared with Albumist ("Ausgewählte Fotos", K7's
    /// case): the first run to end once Albumist may read every photo analyses the rest of the
    /// library, the library as a whole, and brings it when celebrated (the lead's "first full
    /// analysis after more photos were allowed"). A check among the shared photos before it does
    /// not; one with every photo too quick for "Analyse fertig" uses up the chance all the same
    /// (`theFirstRunWithEveryPhotoUsesUpItsChance`).
    @Test func afterAQuickAnalysisOfSharedPhotosEveryPhotoBringsIt() {
        var moment = Moment.fresh()
        Moment.end(&moment, celebrates: false, fullAccess: false)
        #expect(moment.kept == .owed && moment.sharedOnly)
        // "Sucht neue Fotos" among the shared photos, long enough for "Analyse fertig": not yet.
        Moment.end(&moment, wholeLibrary: false, fullAccess: false, after: 600)
        #expect(!moment.isDue(at: Moment.at(601)))
        #expect(moment.kept == .owed && moment.sharedOnly)
        // Every photo allowed: the run that analyses the rest of the library, celebrated on screen.
        Moment.end(&moment, wholeLibrary: false, fullAccess: true, after: 3600)
        #expect(moment.isDue(at: Moment.at(3601)))
        #expect(moment.kept == .spent && moment.firstCompleted == nil && !moment.sharedOnly)
        // A quick first analysis with every photo readable leaves nothing of the kind.
        var full = Moment.fresh()
        Moment.end(&full, celebrates: false)
        #expect(!full.sharedOnly)
        Moment.end(&full, wholeLibrary: false, after: 600)
        #expect(!full.isDue(at: Moment.at(601)))
        // Kept across launches with the wait, and gone with it.
        let kept = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Moment.start, sharedOnly: true)
        #expect(kept.sharedOnly)
        #expect(!FirstAnalysisMoment(kept: .spent, completedBefore: true, firstCompleted: Moment.start, sharedOnly: true).sharedOnly)
        #expect(!FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: nil, sharedOnly: true).sharedOnly)
        var lapsed = kept
        lapsed.lapse(at: Moment.at(Self.week + 1))
        #expect(lapsed.kept == .spent && !lapsed.sharedOnly)
        var away = kept
        away.completedAway(first: true, fullAccess: true)
        #expect(away.kept == .spent && !away.sharedOnly)
    }

    /// After a quick first analysis of only the shared photos, the first finished run with every
    /// photo allowed uses up that chance, celebrated or not (the lead's decision on verification
    /// review Y, Y4, which brings back the rule before round 5): it analysed the rest of the
    /// library, and its legs count together (`FirstAnalysisLegs`), so a short last leg no longer
    /// loses the 100 %. Too quick for "Analyse fertig" all the same, the moment stays owed for a
    /// run of the whole library within the seven days; a check for new photos or a catch-up of new
    /// imports never brings it, however long it runs. Never twice, never after the seven days,
    /// never from a run that still sees only the shared photos.
    @Test func theFirstRunWithEveryPhotoUsesUpItsChance() {
        let day = 24.0 * 60 * 60
        var moment = Moment.fresh()
        Moment.end(&moment, celebrates: false, fullAccess: false)
        // Every photo allowed: the rest of the library, too quick for "Analyse fertig".
        Moment.end(&moment, celebrates: false, wholeLibrary: false, fullAccess: true, after: 600)
        #expect(moment.kept == .owed && !moment.sharedOnly, "the run with every photo left its chance to the next")
        #expect(moment.firstCompleted == Moment.start, "the run moved the wait")
        #expect(!moment.isDue(at: Moment.at(601)))
        // Two days later a catch-up of 400 new photos, celebrated on screen: not the whole library.
        Moment.end(&moment, wholeLibrary: false, fullAccess: true, after: 2 * day)
        #expect(!moment.isDue(at: Moment.at(2 * day + 1)) && moment.kept == .owed, "a catch-up brought it")
        // "Analyse neu aufbauen" within the week, celebrated on screen: now, once.
        Moment.end(&moment, after: 3 * day)
        #expect(moment.isDue(at: Moment.at(3 * day + 1)))
        #expect(moment.kept == .spent && moment.firstCompleted == nil)
        let plays = moment.claim(at: Moment.at(3 * day + 2), onScreen: true)
        #expect(plays)
        moment.ended()
        Moment.end(&moment, after: 4 * day)
        let twice = moment.claim(at: Moment.at(4 * day + 1), onScreen: true)
        #expect(!twice && !moment.isDue(at: Moment.at(4 * day + 1)))
        // After the seven days: spent, whatever the run.
        var late = Moment.fresh()
        Moment.end(&late, celebrates: false, fullAccess: false)
        Moment.end(&late, wholeLibrary: false, fullAccess: true, after: Self.week + 1)
        #expect(!late.isDue(at: Moment.at(Self.week + 2)) && late.kept == .spent)
        // Still only the shared photos: a celebrated check among them saw no more of the library,
        // and leaves the chance.
        var limited = Moment.fresh()
        Moment.end(&limited, celebrates: false, fullAccess: false)
        Moment.end(&limited, wholeLibrary: false, fullAccess: false, after: 600)
        #expect(!limited.isDue(at: Moment.at(601)) && limited.kept == .owed && limited.sharedOnly)
    }

    /// Seven days from that first completion: a run of the whole library just inside brings it,
    /// just after it the moment is spent, also when the wait ends between two launches. A clock
    /// set back does not end the wait early.
    @Test func afterAQuickFirstAnalysisItWaitsSevenDays() {
        #expect(Self.week == 7 * 24 * 60 * 60)
        var inside = Moment.fresh()
        Moment.end(&inside, celebrates: false)
        Moment.end(&inside, after: Self.week - 1)
        #expect(inside.isDue(at: Moment.at(Self.week)))
        var after = Moment.fresh()
        Moment.end(&after, celebrates: false)
        Moment.end(&after, after: Self.week + 1)
        #expect(!after.isDue(at: Moment.at(Self.week + 2)))
        #expect(after.kept == .spent && after.firstCompleted == nil)
        // At launch: what was kept, and the wait over or not.
        var launched = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Moment.start)
        launched.lapse(at: Moment.at(Self.week - 1))
        #expect(launched.kept == .owed && launched.firstCompleted == Moment.start)
        launched.lapse(at: Moment.at(Self.week + 1))
        #expect(launched.kept == .spent && launched.firstCompleted == nil)
        var back = FirstAnalysisMoment(kept: .owed, completedBefore: true, firstCompleted: Moment.start)
        back.lapse(at: Moment.at(-3600))
        #expect(back.kept == .owed)
        // Nothing to wait for once spent, and none before a first completion.
        #expect(FirstAnalysisMoment(kept: .spent, completedBefore: true, firstCompleted: Moment.start).firstCompleted == nil)
        #expect(Moment.fresh().firstCompleted == nil)
    }
}
