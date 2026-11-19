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
    /// One refresh of the overview that reads the store and assigns its result
    /// (`AppModel.refreshDerived`: begun, shown as the newest call, ended).
    static func refresh(_ ledger: inout TripChangeLedger, call: Int) {
        ledger.refreshBegan(call)
        ledger.refreshShown(call)
        ledger.refreshEnded(call)
    }

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
        Self.refresh(&ledger, call: 1)
        #expect(ledger.state == .applied)
        ledger.runSettled(1)
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// A run that started before the change was stored read the old trips: its end does not make
    /// the change, the run after it does (`AnalysisStartCause.asksForARunAfter`).
    @Test func aRunThatReadTheOldTripsDoesNotMakeTheChange() {
        var calls = 100
        func next() -> Int { calls += 1; return calls }
        var ledger = TripChangeLedger()
        ledger.runStarted(1)          // a check for new photos, or the refinement, slipped in
        ledger.changeStored()         // the split is stored while it runs
        ledger.runEnded(1, madeSuggestions: true)
        // In the app the follow-up starts before the end waits (`end.next == .followUp`).
        ledger.runStarted(2)
        Self.refresh(&ledger, call: next())
        ledger.runSettled(1)
        #expect(ledger.state == .waiting, "the old trips were taken for the change")
        #expect(ledger.settling)
        ledger.runEnded(2, madeSuggestions: true)
        Self.refresh(&ledger, call: next())
        ledger.runSettled(2)
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// The refinement's passes: the first one read the old trips, its end shows them, the next
    /// pass makes the change. Between the two the sheet says the change is saved, never done.
    @Test func theRefinementShowsTheOldTripsAndSaysSaved() {
        var calls = 100
        func next() -> Int { calls += 1; return calls }
        var ledger = TripChangeLedger()
        ledger.runStarted(1)
        ledger.changeStored()
        ledger.runEnded(1, madeSuggestions: true)
        Self.refresh(&ledger, call: next())
        ledger.runSettled(1)
        #expect(ledger.state == .savedForLater, "the sheet said the change was made after a pass that read the old trips")
        #expect(!ledger.settling)
        ledger.runStarted(2)
        #expect(ledger.state == .waiting)
        ledger.runEnded(2, madeSuggestions: true)
        Self.refresh(&ledger, call: next())
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
        ledger.refreshBegan(1)                   // an early look during the run
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshShown(1)                   // lands after the end
        ledger.refreshEnded(1)
        #expect(ledger.state == .waiting, "a refresh that read before the run's end counted as showing it")
        Self.refresh(&ledger, call: 2)           // e.g. an ignore tap's refresh replaces the end's own
        ledger.runSettled(1)
        #expect(ledger.state == .applied)
        // An older refresh landing late never takes it back.
        ledger.refreshBegan(3)
        ledger.refreshShown(3)
        ledger.refreshEnded(3)
        #expect(ledger.state == .applied)
    }

    /// A run that made no suggestions (it threw, was stopped or paused before them) did not
    /// make the change: once its end is done, the change is saved for the run that comes, and
    /// the controls are free (a new change starts that run).
    @Test func aRunWithoutSuggestionsLeavesTheChangeSaved() {
        var calls = 100
        func next() -> Int { calls += 1; return calls }
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: false)
        Self.refresh(&ledger, call: next())
        #expect(ledger.state == .waiting)
        ledger.runSettled(1)
        #expect(ledger.state == .savedForLater)
        #expect(!ledger.settling, "the trip controls stayed grey with no run to wait for")
        // A second change starts the run that makes both.
        ledger.changeStored()
        ledger.runStarted(2)
        ledger.runEnded(2, madeSuggestions: true)
        Self.refresh(&ledger, call: next())
        ledger.runSettled(2)
        #expect(ledger.state == .applied)
    }

    /// Unknown runs (ended twice, or never started here) change nothing, and runs without a trip
    /// change leave it applied.
    @Test func runsWithoutAChangeLeaveItApplied() {
        var calls = 100
        func next() -> Int { calls += 1; return calls }
        var ledger = TripChangeLedger()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        Self.refresh(&ledger, call: next())
        ledger.runSettled(1)
        ledger.runSettled(1)
        ledger.runEnded(7, madeSuggestions: true)
        ledger.runSettled(7)
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// While a change waits for the overview, the trip controls wait with the run's reason.
    @Test func theControlsWaitWhileTheTripsAreWorkedOutAgain() {
        var calls = 100
        func next() -> Int { calls += 1; return calls }
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        // `AppModel.tripChangeWait`: while the end of the run is going.
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false, settling: ledger.settling, check: true) == .tripsAgain)
        Self.refresh(&ledger, call: next())
        ledger.runSettled(1)
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false, settling: ledger.settling, check: true) == nil)
    }

    /// The end of a first analysis, or of one that went on, refreshes the overview for a moment
    /// after the card says it ended; the run's kind is still the first or the resumed one. The
    /// note says "Gleich wieder möglich" then, never "Danach wieder möglich" as for a long run
    /// (second review of 194971b, S2).
    @Test func theEndOfAnyRunSaysSoon() {
        for check in [false, true] {
            #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false, settling: true, check: check) == .tripsAgain,
                    "the end of a long run said it can take a while (check \(check))")
            #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false, settling: false, check: check) == nil)
        }
        // A run going says what it is; albums being made come first.
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: true, settling: true, check: false) == .analysis)
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: true, settling: true, check: true) == .tripsAgain)
        #expect(TripWorkshop.wait(creatingAlbums: true, analysing: false, settling: true, check: false) == .creatingAlbums)
    }

    /// The end's own refresh is replaced by a newer one (pull to refresh, an ignore tap, a
    /// settings save) and assigns nothing; the end is settled before the newer one lands. The
    /// change waits for the newer refresh (second review of 194971b, M1: it read "Gespeichert"
    /// and the controls were free while the newer refresh ran, by estimate 1–3 s with a large
    /// library, so the merge that drops the
    /// split was possible again).
    @Test func aNewerRefreshThatLandsAfterTheEndKeepsItWaiting() {
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshBegan(10)          // the end's own refresh
        ledger.refreshBegan(11)          // a newer one: the end's own assigns nothing
        ledger.refreshEnded(10)
        ledger.runSettled(1)
        #expect(ledger.state == .waiting, "said saved while a refresh with the change was still coming")
        #expect(ledger.settling, "the trip controls were free before the trips were shown")
        ledger.refreshShown(11)
        ledger.refreshEnded(11)
        #expect(ledger.state == .applied, "the sheet never reached done")
        #expect(!ledger.settling)
    }

    /// The newer refresh fails (third review of 194971b, SHOULD-1): the end's own assigned
    /// nothing, so the change is written but not on screen and no analysis is coming. Before, it
    /// read "Gespeichert … sobald die Analyse fertig ist" with the controls free over the old
    /// trips, and a merge there could drop the split. Now one more refresh comes, and the
    /// controls wait for it; the sheet reaches done when it lands.
    @Test func aNewerRefreshThatFailsIsTriedOnceMore() {
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshBegan(10)          // the end's own refresh: it reads the change
        ledger.refreshBegan(11)          // pull to refresh or an ignore tap: the end's own assigns nothing
        ledger.refreshEnded(10)
        ledger.runSettled(1)
        let again = ledger.refreshFailed(11, newest: true, retry: false)
        ledger.refreshEnded(11)          // the defer after the catch
        #expect(again, "no refresh came after the failed one: the change stayed off screen")
        #expect(ledger.state == .waiting, "said Gespeichert although no analysis is coming")
        #expect(ledger.settling, "the trip controls were free over the old trips")
        Self.refresh(&ledger, call: 12)  // the one more refresh lands
        #expect(ledger.state == .applied)
        #expect(!ledger.settling)
    }

    /// Exactly one more per failure chain: a store that keeps throwing does not loop. After the
    /// second failure the change is saved and the controls are free; the next refresh shows it.
    @Test func aStoreThatKeepsThrowingIsNotAskedForEver() {
        var ledger = TripChangeLedger()
        ledger.changeStored()
        ledger.runStarted(1)
        ledger.runEnded(1, madeSuggestions: true)
        ledger.refreshBegan(10)
        let first = ledger.refreshFailed(10, newest: true, retry: false)
        ledger.refreshEnded(10)
        ledger.runSettled(1)
        #expect(first)
        ledger.refreshBegan(11)          // the one more
        let second = ledger.refreshFailed(11, newest: true, retry: true)
        ledger.refreshEnded(11)
        #expect(!second, "a failing store was asked again and again")
        #expect(ledger.state == .savedForLater)
        #expect(!ledger.settling, "the trip controls stayed grey with nothing coming")
        Self.refresh(&ledger, call: 12)
        #expect(ledger.state == .applied)
    }

    /// No extra refresh where none is needed: an older call failed (the newest one is still
    /// going and shows the change), or nothing written waits to be shown.
    @Test func onlyTheNewestFailureWithAChangeLeftAsksAgain() {
        var ledger = TripChangeLedger()
        ledger.refreshBegan(1)
        let nothingLeft = ledger.refreshFailed(1, newest: true, retry: false)
        ledger.refreshEnded(1)
        #expect(!nothingLeft, "a failed refresh with nothing to show asked for one more")
        #expect(!ledger.settling)
        ledger.changeStored()
        ledger.runStarted(2)
        ledger.runEnded(2, madeSuggestions: true)
        ledger.refreshBegan(10)
        ledger.refreshBegan(11)
        let older = ledger.refreshFailed(10, newest: false, retry: false)
        ledger.refreshEnded(10)
        ledger.runSettled(2)
        #expect(!older, "an older call's failure asked for one more")
        #expect(ledger.settling, "the newest refresh still shows the change")
        ledger.refreshShown(11)
        ledger.refreshEnded(11)
        #expect(ledger.state == .applied)
    }

    /// A run paused in the image step after it saved its early suggestions (trips and places
    /// from the trips it worked out) made the change (third review, NIT-1).
    @Test func earlySuggestionsCountAsMadeSuggestions() throws {
        let model = AppSource.code(try AppSource.read("App/Sortly/Model/AppModel.swift"))
        let app = model.contains("madeSuggestions: finished.map { $0.earlyProposals || $0.completedStages.contains(.proposals) } == true")
        let refinement = model.contains("madeSuggestions: report.map { $0.earlyProposals || $0.completedStages.contains(.proposals) } == true")
        #expect(app, "a run in the app paused after its early suggestions never shows the change as made")
        #expect(refinement, "a refinement pass paused after its early suggestions never shows the change as made")
    }

    /// Refreshes that read nothing new keep nothing waiting (they run every few seconds during
    /// an analysis).
    @Test func refreshesWithoutAChangeDoNotHoldTheControls() {
        var ledger = TripChangeLedger()
        ledger.refreshBegan(1)
        #expect(!ledger.settling)
        ledger.changeStored()
        ledger.refreshBegan(2)           // the store has no suggestions with it yet
        #expect(!ledger.settling)
        ledger.refreshEnded(1)
        ledger.refreshEnded(2)
        #expect(ledger.state == .savedForLater)
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
        let waitsForTheEnd = wait.contains("analysing: analysis.isRunning, settling: tripChangeLedger.settling, check: runIsShortCheck")
        #expect(waitsForTheEnd, "tripChangeWait is free again before the overview shows the trips, or says a long wait at a run's end")
        // The change is counted before its run starts.
        let change = try code("func changeTrips(")
        let counted = order("tripChangeLedger.changeStored()", "startAnalysis(cause: .userChange)", in: change)
        #expect(counted, "changeTrips does not count the change before its run starts")
        // Runs in the app and the refinement passes: started, ended before they show as ended,
        // and settled after their refresh.
        let start = try code("func startAnalysisNow(")
        let startRead = start.contains("tripChangeLedger.runStarted(generation)")
        #expect(startRead, "a run in the app does not say which trip changes it read")
        let appEnd = order("tripChangeLedger.runEnded(generation, madeSuggestions: finished.map { $0.earlyProposals || $0.completedStages.contains(.proposals) } == true)",
                           "analysis.isRunning = false", in: start)
        #expect(appEnd, "the end of a run in the app is not told before it shows as ended")
        let appSettled = order("await refreshDerived()", "tripChangeLedger.runSettled(generation)", in: start)
        #expect(appSettled, "the end of a run in the app is settled before its refresh")
        let refine = try code("func refinePass(")
        let refineRead = refine.contains("tripChangeLedger.runStarted(generation)")
        #expect(refineRead, "a refinement pass does not say which trip changes it read")
        let refineEnd = order("tripChangeLedger.runEnded(generation, madeSuggestions: report.map { $0.earlyProposals || $0.completedStages.contains(.proposals) } == true)",
                              "analysis.isRunning = false", in: refine)
        #expect(refineEnd, "the end of a refinement pass is not told before it shows as ended")
        // Both ways out of the pass settle it: cut off (no report) and after the refresh.
        let settles = refine.components(separatedBy: "tripChangeLedger.runSettled(generation)").count - 1
        #expect(settles == 2, "a refinement pass leaves the trip controls waiting (\(settles) settles)")
        let refineSettled = order("await refreshDerived()", "tripChangeLedger.runSettled(generation)", in: refine)
        #expect(refineSettled, "the refinement pass is settled before its refresh")
        // The overview says which changes it shows only when it assigns its result.
        let refresh = try code("func refreshDerived(")
        let reads = order("let call = derivedCalls.begin()", "tripChangeLedger.refreshBegan(call)", in: refresh)
        #expect(reads, "refreshDerived does not note which trip changes the store holds when it reads")
        // Every way out ends it (the guards, a throw): else the controls wait for ever.
        let endsAlways = order("tripChangeLedger.refreshBegan(call)", "defer { tripChangeLedger.refreshEnded(call) }", in: refresh)
            && refresh.components(separatedBy: "tripChangeLedger.refreshEnded(call)").count == 2
        #expect(endsAlways, "a refresh that returns early or throws is not ended")
        let shown = order("guard derivedCalls.isNewest(call)", "tripChangeLedger.refreshShown(call)", in: refresh)
        #expect(shown, "refreshDerived counts trips as shown that an older call read")
        // A failed newest refresh with a change left asks for exactly one more (SHOULD-1).
        let catchPart = refresh.components(separatedBy: "} catch {").dropFirst().joined()
        let asksAgain = catchPart.contains("if tripChangeLedger.refreshFailed(call, newest: derivedCalls.isNewest(call), retry: afterFailure) {")
            && catchPart.contains("await refreshDerived(afterFailure: true)")
        #expect(asksAgain, "a failed refresh leaves the change off screen with the controls free")
        let declared = AppSource.code(model).contains("func refreshDerived(afterFailure: Bool = false) async {")
        #expect(declared, "refreshDerived does not know whether it is the one more after a failure")
        // The sheet is done when the trips shown include the change, not when no run runs.
        let doneByTheLedger = workshop.contains(".onChange(of: model.tripChangeState)")
        #expect(doneByTheLedger, "the workshop says done when the run ends, before the trips are shown")
        let doneByTheRun = workshop.contains(".onChange(of: model.analysis.isRunning)")
        #expect(!doneByTheRun, "the workshop still says done when the run ends")
        let savedWhenNotMade = workshop.contains("saved = state == .savedForLater")
        #expect(savedWhenNotMade, "the workshop says the change was made after a run that read the old trips")
        // Saved, and later shown (a refresh landed after all, the run that applies it ended): the
        // sheet says it is made (second review of 194971b, M1: it stayed on "Gespeichert").
        let madeLater = workshop.contains("if state == .applied, saved, done != nil {") && workshop.contains("saved = false")
        #expect(madeLater, "the workshop stays on Gespeichert once the change is shown")
        // Swiped away while the change is stored: the trip view still closes when it is told.
        let closesLate = proposals.contains(".onChange(of: reshaped) { _, now in if now && !showWorkshop { dismiss() } }")
        #expect(closesLate, "the trip view stays on the old trip when the sheet was swiped away before the change was stored")
    }
}
