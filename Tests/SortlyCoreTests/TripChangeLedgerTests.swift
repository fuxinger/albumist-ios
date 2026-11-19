import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Trip workshop, swiped away while the trips are worked out again (`TripChangeLedger`).
///
/// The workshop and the trip controls took "no analysis runs" for "the trips shown include the
/// change". They are not the same:
/// - A run ends (`analysis.isRunning = false`) and only then waits for the overview to be
///   refreshed (`refreshDerived`, seconds with a large library). Meanwhile the trip list still
///   shows the trips from before the change, the controls were free again, and the sheet said
///   "Die Vorschläge sind schon angepasst".
/// - A run that slipped in before the change was stored (a change in Photos, a retry, the
///   overnight refinement) read the old trips. Its end showed the old trips again, and the sheet
///   said the change was made.
/// The sheet can be swiped away while it waits (owner decision 19.11.2026), so the user is back
/// at the trips at once and could open, merge or make an album of a trip that is about to go. A
/// merge made on such a stale trip spans it and drops the split just made
/// (`TripCorrections.merging`): the old state came back.
@Suite("Trip changes: done only once the trips shown include them")
struct TripChangeLedgerTests {
    /// A trip change and the run it starts, as `AppModel.changeTrips` and `startAnalysisNow` do.
    @Test func theChangeIsDoneOnlyOnceTheOverviewShowsIt() {
        var ledger = TripChangeLedger()
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
        ledger.changeStored()
        ledger.runStarted(1)
        #expect(ledger.state == .waiting)
        #expect(ledger.settling, "the trip controls were free while the run ran")
        // The run ends; its end now waits for the overview.
        ledger.runEnded(1, madeSuggestions: true)
        #expect(ledger.state == .waiting, "the sheet said done while the trip list still showed the old trips")
        #expect(ledger.settling, "the trip controls were free while the old trips were still shown")
        // The overview is refreshed from the store and shows the run's trips.
        let reads = ledger.refreshReads
        ledger.refreshShown(reads)
        #expect(ledger.state == .applied)
        ledger.runSettled(1)
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// A run that started before the change was stored read the old trips: its end does not make
    /// the change, the run after it does (`AnalysisStartCause.asksForARunAfter`).
    @Test func aRunThatReadTheOldTripsDoesNotMakeTheChange() {
        var ledger = TripChangeLedger()
        ledger.runStarted(1)          // a check for new photos, or the refinement, slipped in
        ledger.changeStored()         // the split is stored while it runs
        ledger.runEnded(1, madeSuggestions: true)
        // In the app the follow-up starts before the end waits (`end.next == .followUp`).
        ledger.runStarted(2)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(1)
        #expect(ledger.state == .waiting, "the old trips were taken for the change")
        #expect(ledger.settling)
        ledger.runEnded(2, madeSuggestions: true)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(2)
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// The refinement's passes: the first one read the old trips, its end shows them, the next
    /// pass makes the change. Between the two the sheet says the change is saved, never done.
    @Test func theRefinementShowsTheOldTripsAndSaysSaved() {
        var ledger = TripChangeLedger()
        ledger.runStarted(1)
        ledger.changeStored()
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(1)
        #expect(ledger.state == .savedForLater, "the sheet said the change was made after a pass that read the old trips")
        #expect(!ledger.settling)
        ledger.runStarted(2)
        #expect(ledger.state == .waiting)
        ledger.runEnded(2, madeSuggestions: true)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(2)
        #expect(ledger.state == .applied)
    }

    /// A refresh that read the store before the run ended shows the trips from before; only a
    /// refresh that read after the end counts, also when it is not the end's own (a newer call
    /// replaced it, `LatestCall`).
    @Test func onlyARefreshThatReadAfterTheEndCounts() {
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        let early = ledger.refreshReads          // an early look during the run
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshShown(early)               // lands after the end
        #expect(ledger.state == .waiting, "a refresh that read before the run's end counted as showing it")
        let late = ledger.refreshReads           // e.g. an ignore tap's refresh replaces the end's own
        ledger.refreshShown(late)
        ledger.runSettled(1)
        #expect(ledger.state == .applied)
        // An older refresh landing late never takes it back.
        ledger.refreshShown(early)
        #expect(ledger.state == .applied)
    }

    /// A run that made no suggestions (it threw, was stopped or paused before them) did not
    /// make the change: once its end is done, the change is saved for the run that comes, and
    /// the controls are free (a new change starts that run).
    @Test func aRunWithoutSuggestionsLeavesTheChangeSaved() {
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: false)
        ledger.refreshShown(ledger.refreshReads)
        #expect(ledger.state == .waiting)
        ledger.runSettled(1)
        #expect(ledger.state == .savedForLater)
        #expect(!ledger.settling, "the trip controls stayed grey with no run to wait for")
        // A second change starts the run that makes both.
        ledger.changeStored()
        ledger.runStarted(2)
        ledger.runEnded(2, madeSuggestions: true)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(2)
        #expect(ledger.state == .applied)
    }

    /// Unknown runs (ended twice, or never started here) change nothing, and runs without a trip
    /// change leave it applied.
    @Test func runsWithoutAChangeLeaveItApplied() {
        var ledger = TripChangeLedger()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(1)
        ledger.runSettled(1)
        ledger.runEnded(7, madeSuggestions: true)
        ledger.runSettled(7)
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// While a change waits for the overview, the trip controls wait with the run's reason.
    @Test func theControlsWaitWhileTheTripsAreWorkedOutAgain() {
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        // `AppModel.tripChangeWait`: analysing while a run or its end is going.
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false || ledger.settling, check: true) == .tripsAgain)
        ledger.refreshShown(ledger.refreshReads)
        ledger.runSettled(1)
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false || ledger.settling, check: true) == nil)
    }

    /// The App uses the ledger at each point (it does not build on Linux, so its code is read
    /// without comments and strings, `AppSource.code`). Each check goes red when its part is
    /// taken back.
    @Test func theAppKeepsTheLedgerAtEachPoint() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        let workshop = AppSource.code(try AppSource.read("App/Sortly/Views/TripWorkshopView.swift"))
        let proposals = AppSource.code(try AppSource.read("App/Sortly/Views/ProposalViews.swift"))
        func code(_ declaration: String) throws -> String {
            AppSource.code(try #require(AppSource.body(of: declaration, in: model), "AppModel.swift: no \(declaration)"))
        }
        func order(_ first: String, _ second: String, in text: String) -> Bool {
            guard let a = text.range(of: first), let b = text.range(of: second, range: a.upperBound..<text.endIndex) else { return false }
            return a.lowerBound < b.lowerBound
        }
        // The controls wait while a run or its end is going.
        let wait = try code("var tripChangeWait:")
        let waitsForTheEnd = wait.contains("analysing: analysis.isRunning || tripChangeLedger.settling")
        #expect(waitsForTheEnd, "tripChangeWait is free again before the overview shows the trips")
        // The change is counted before its run starts.
        let change = try code("func changeTrips(")
        let counted = order("tripChangeLedger.changeStored()", "startAnalysis(cause: .userChange)", in: change)
        #expect(counted, "changeTrips does not count the change before its run starts")
        // Runs in the app and the refinement passes: started, ended before they show as ended,
        // and settled after their refresh.
        let start = try code("func startAnalysisNow(")
        let startRead = start.contains("tripChangeLedger.runStarted(generation)")
        #expect(startRead, "a run in the app does not say which trip changes it read")
        let appEnd = order("tripChangeLedger.runEnded(generation, madeSuggestions: finished?.completedStages.contains(.proposals) == true)",
                           "analysis.isRunning = false", in: start)
        #expect(appEnd, "the end of a run in the app is not told before it shows as ended")
        let appSettled = order("await refreshDerived()", "tripChangeLedger.runSettled(generation)", in: start)
        #expect(appSettled, "the end of a run in the app is settled before its refresh")
        let refine = try code("func refinePass(")
        let refineRead = refine.contains("tripChangeLedger.runStarted(generation)")
        #expect(refineRead, "a refinement pass does not say which trip changes it read")
        let refineEnd = order("tripChangeLedger.runEnded(generation, madeSuggestions: report?.completedStages.contains(.proposals) == true)",
                              "analysis.isRunning = false", in: refine)
        #expect(refineEnd, "the end of a refinement pass is not told before it shows as ended")
        // Both ways out of the pass settle it: cut off (no report) and after the refresh.
        let settles = refine.components(separatedBy: "tripChangeLedger.runSettled(generation)").count - 1
        #expect(settles == 2, "a refinement pass leaves the trip controls waiting (\(settles) settles)")
        let refineSettled = order("await refreshDerived()", "tripChangeLedger.runSettled(generation)", in: refine)
        #expect(refineSettled, "the refinement pass is settled before its refresh")
        // The overview says which changes it shows only when it assigns its result.
        let refresh = try code("func refreshDerived(")
        let reads = order("let call = derivedCalls.begin()", "let tripsRead = tripChangeLedger.refreshReads", in: refresh)
        #expect(reads, "refreshDerived does not note which trip changes the store holds when it reads")
        let shown = order("guard derivedCalls.isNewest(call)", "tripChangeLedger.refreshShown(tripsRead)", in: refresh)
        #expect(shown, "refreshDerived counts trips as shown that an older call read")
        // The sheet is done when the trips shown include the change, not when no run runs.
        let doneByTheLedger = workshop.contains(".onChange(of: model.tripChangeState)")
        #expect(doneByTheLedger, "the workshop says done when the run ends, before the trips are shown")
        let doneByTheRun = workshop.contains(".onChange(of: model.analysis.isRunning)")
        #expect(!doneByTheRun, "the workshop still says done when the run ends")
        let savedWhenNotMade = workshop.contains("saved = state == .savedForLater")
        #expect(savedWhenNotMade, "the workshop says the change was made after a run that read the old trips")
        // Swiped away while the change is stored: the trip view still closes when it is told.
        let closesLate = proposals.contains(".onChange(of: reshaped) { _, now in if now && !showWorkshop { dismiss() } }")
        #expect(closesLate, "the trip view stays on the old trip when the sheet was swiped away before the change was stored")
    }
}
