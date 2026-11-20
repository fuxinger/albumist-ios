import Testing
@testable import SortlyCore
import SortlyTestSupport

/// A preview's plan goes stale once another run ended (`PlanFreshness`): a preview of picks
/// left open on "Vorschläge" still offered an album that "Album anlegen" had made on "Start"
/// meanwhile, and "Jetzt anlegen" made it a second time (second review of design wave 1,
/// 20.11.).
@Suite("Plan freshness")
struct PlanFreshnessTests {
    @Test func aPlanMadeBeforeAnotherRunEndedIsStale() {
        var freshness = PlanFreshness()
        #expect(!freshness.isStale(runsEnded: 3), "no plan yet, nothing to be stale")
        freshness.made(after: 3)
        #expect(!freshness.isStale(runsEnded: 3))
        #expect(freshness.isStale(runsEnded: 4))
        // Made again: fresh until the next run ends.
        freshness.made(after: 4)
        #expect(!freshness.isStale(runsEnded: 4))
    }

    /// The count is read before the plan is made: a run that ended while it was made counts.
    @Test func aRunThatEndedWhileThePlanWasMadeCounts() {
        var freshness = PlanFreshness()
        let before = 7
        // ... the plan is made, and meanwhile a run ends (8) ...
        freshness.made(after: before)
        #expect(freshness.isStale(runsEnded: 8))
    }

    /// Its own run does not make the plan stale: its result takes its place. A run that did
    /// not take it leaves it as it was, so a run that ended meanwhile does.
    @Test func itsOwnRunDoesNotMakeThePlanStale() {
        var freshness = PlanFreshness()
        freshness.made(after: 2)
        freshness.handOver()
        #expect(!freshness.isStale(runsEnded: 3))
        freshness.notTaken()
        #expect(freshness.isStale(runsEnded: 3))
        #expect(!freshness.isStale(runsEnded: 2))
    }
}

/// The preview takes a stale plan away before it can run: a preview of picks makes its plan
/// again, a plan built elsewhere is dropped with a word why (`PlanReviewView`), and
/// "Passt nicht zu diesem Album" settles the picks of that suggestion.
@Suite("Previews never offer a stale plan")
struct PlanFreshnessAppTests {
    static let model = "App/Sortly/Model/AppModel.swift"
    static let preview = "App/Sortly/Views/PlanReviewView.swift"

    static func body(_ declaration: String, in file: String) throws -> String {
        let source = try AppSource.read(file)
        let body = try #require(AppSource.body(of: declaration, in: source), "\(declaration) is not in \(file)")
        return AppSource.code(body, keepStrings: true)
    }

    /// Every run that started counts once it ended, also an undo and a quick create: all of
    /// them end in `run(_:)`.
    @Test func theModelCountsTheRunsThatEnded() throws {
        let model = AppSource.code(try AppSource.read(Self.model))
        #expect(model.contains("private(set) var runsEnded = 0"))
        let run = try Self.body("private func run(_ plan: ChangePlan", in: Self.model)
        let end = try #require(run.range(of: "execution.isRunning = false"))
        #expect(run[end.upperBound...].contains("runsEnded += 1"))
        #expect(run.components(separatedBy: "runsEnded += 1").count == 2, "counted once")
    }

    @Test func thePreviewMakesItsPlanAgainOrDropsIt() throws {
        let view = AppSource.code(try AppSource.read(Self.preview), keepStrings: true)
        #expect(view.contains("@State private var freshness = PlanFreshness()"))
        // Noted where a plan is made: on opening and for "Die ersten N jetzt anlegen".
        #expect(view.components(separatedBy: "freshness.made(after: runs)").count >= 3)
        // Never on screen or run while stale.
        let previewed = try Self.body("private var previewed:", in: Self.preview)
        #expect(previewed.contains("!freshness.isStale(runsEnded: model.runsEnded)"))
        let again = try Self.body("private func makeAgainIfStale()", in: Self.preview)
        #expect(again.contains("model.buildPlan(for: selection)"))
        #expect(again.contains("droppedAsStale = true"))
        #expect(again.contains("Task.isCancelled"))
        #expect(view.contains("Inzwischen hat sich etwas geändert"))
        // Its own run does not make it stale; a run that did not take it leaves it as it was.
        #expect(view.contains("freshness.handOver()"))
        #expect(view.contains("freshness.notTaken()"))
    }

    @Test func rejectingAnAlbumSettlesThePicksOfTheSuggestion() throws {
        let reject = try Self.body("func rejectMatch(", in: Self.model)
        #expect(reject.contains("previewPicks.unmark(proposal.id)"))
    }
}
