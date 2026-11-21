import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// A preview's plan goes stale once another run ended (`PlanFreshness`): a preview of picks
/// left open on "Vorschläge" still offered an album that "Album anlegen" had made on "Start"
/// meanwhile, and "Jetzt anlegen" made it a second time (second review of design wave 1,
/// 20.11.). Choices made elsewhere meanwhile count as well (review B of wave 1, finding 2), so
/// the preview counts changes: runs that ended plus choices made.
@Suite("Plan freshness")
struct PlanFreshnessTests {
    @Test func aPlanMadeBeforeAnotherChangeIsStale() {
        var freshness = PlanFreshness()
        #expect(!freshness.isStale(changes: 3), "no plan yet, nothing to be stale")
        freshness.made(after: 3)
        #expect(!freshness.isStale(changes: 3))
        #expect(freshness.isStale(changes: 4))
        // Made again: fresh until the next change.
        freshness.made(after: 4)
        #expect(!freshness.isStale(changes: 4))
    }

    /// The count is read before the plan is made: a change while it is made counts.
    @Test func aChangeWhileThePlanWasMadeCounts() {
        var freshness = PlanFreshness()
        let before = 7
        // ... the plan is made, and meanwhile a run ends or a choice is made (8) ...
        freshness.made(after: before)
        #expect(freshness.isStale(changes: 8))
    }

    /// Its own run does not make the plan stale: its result takes its place. A run that did
    /// not take it leaves it as it was, so a change meanwhile does.
    @Test func itsOwnRunDoesNotMakeThePlanStale() {
        var freshness = PlanFreshness()
        freshness.made(after: 2)
        freshness.handOver()
        #expect(!freshness.isStale(changes: 3))
        freshness.notTaken()
        #expect(freshness.isStale(changes: 3))
        #expect(!freshness.isStale(changes: 2))
    }

    /// A preview opened while another run was on makes no plan then: it still has to make one
    /// once that run ended (review B of wave 1, finding 3: it stayed on "Nichts zu tun").
    @Test func aPreviewThatMadeNoPlanYetStillHasToMakeOne() {
        var freshness = PlanFreshness()
        #expect(!freshness.wasMade)
        #expect(!freshness.isStale(changes: 5), "nothing made, nothing stale: made, not made again")
        freshness.made(after: 5)
        #expect(freshness.wasMade)
        freshness.handOver()
        #expect(freshness.wasMade)
    }
}

/// The preview takes a stale plan away before it can run: a preview of picks makes its plan
/// again, a plan built elsewhere is dropped with a word why (`PlanReviewView`), and
/// "Passt nicht zu diesem Album" settles the picks of that suggestion.
@Suite("Previews never offer a stale plan")
struct PlanFreshnessAppTests {
    static let model = "App/Albumist/Model/AppModel.swift"
    static let preview = "App/Albumist/Views/PlanReviewView.swift"

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

    /// Review B of wave 1, finding 2: "3 Alben anlegen" left open, suggestion B set aside on
    /// another tab (or photos taken out of it, another album chosen under "Anpassen", a name
    /// typed), and "Jetzt anlegen" still made B as planned before. Every choice that changes
    /// what a plan holds is counted, so an open preview makes its plan again.
    @Test func theModelCountsTheChoicesThatChangeAPlan() throws {
        let model = AppSource.code(try AppSource.read(Self.model))
        #expect(model.contains("private(set) var choicesMade = 0"))
        for declaration in ["func setDecision(_ decision: ProposalDecision", "func setUserTitle(",
                            "func removeFromProposal(", "func rejectMatch(", "private func reopenAfterRecheck("] {
            let body = try Self.body(declaration, in: Self.model)
            #expect(body.contains("choicesMade += 1"), "\(declaration) changes what a plan holds without saying so")
        }
    }

    @Test func thePreviewMakesItsPlanAgainOrDropsIt() throws {
        let view = AppSource.code(try AppSource.read(Self.preview), keepStrings: true)
        #expect(view.contains("@State private var freshness = PlanFreshness()"))
        // What counts as a change: runs that ended and choices made.
        let changes = try Self.body("private var changes: Int", in: Self.preview)
        #expect(changes.contains("model.runsEnded") && changes.contains("model.choicesMade"))
        // Noted where a plan is made: on opening, again, and for "Die ersten N jetzt anlegen".
        #expect(view.components(separatedBy: "freshness.made(after: seen)").count >= 4)
        // Never on screen or run while stale.
        let previewed = try Self.body("private var previewed:", in: Self.preview)
        #expect(previewed.contains("!freshness.isStale(changes: changes)"))
        // Checked after each change, and once the screen has loaded.
        #expect(view.contains("StaleCheck(changes: changes, freshness: freshness, loading: loading)"))
        let again = try Self.body("private func makePlanIfNeeded()", in: Self.preview)
        #expect(again.contains("!loading") && again.contains("!model.execution.isRunning"))
        #expect(again.contains("isStale || needsFirstPlan"))
        #expect(again.contains("model.buildPlan(for: selection)"))
        #expect(again.contains("dropped = .changed"))
        #expect(again.contains("Task.isCancelled"))
        #expect(view.contains("Inzwischen hat sich etwas geändert"))
        #expect(view.contains("Öffne die Vorschau noch einmal, dann zeigt sie den neuen Stand."))
        // Its own run does not make it stale; a run that did not take it leaves it as it was.
        #expect(view.contains("freshness.handOver()"))
        #expect(view.contains("freshness.notTaken()"))
    }

    /// Review B of wave 1, finding 3: a preview opened while a quick create or its "Widerrufen"
    /// still ran made no plan, and nothing made one afterwards ("Nichts zu tun" for good).
    @Test func aPreviewOpenedDuringARunMakesItsPlanAfterwards() throws {
        let first = try Self.body("private var needsFirstPlan: Bool", in: Self.preview)
        #expect(first.contains("didLoad") && first.contains("!freshness.wasMade") && first.contains("dropped == nil"))
        let view = AppSource.code(try AppSource.read(Self.preview), keepStrings: true)
        #expect(view.contains("loading || isStale || needsFirstPlan"), "the plan being made shows as such")
    }

    /// Review B of wave 1, finding 8: a preview of picks made again after all of them were made
    /// on another tab showed a plan of zeros and a grey button. It says why there is nothing.
    @Test func aPlanWithNothingLeftSaysSo() throws {
        let take = try Self.body("private func take(_ made: ChangePlan?)", in: Self.preview)
        #expect(take.contains("made.steps.isEmpty") && take.contains("made.conflicts.isEmpty"))
        #expect(take.contains("dropped = .nothingLeft"))
        let view = AppSource.code(try AppSource.read(Self.preview), keepStrings: true)
        #expect(view.contains("Die Vorschläge dieser Vorschau sind inzwischen erledigt oder nicht mehr aktuell."))
        // On opening and when made again (after the check that the screen is still there).
        #expect(view.contains("take(await model.buildPlan(for: selection))"))
        let again = try Self.body("private func makePlanIfNeeded()", in: Self.preview)
        #expect(again.contains("take(made)"))
    }

    @Test func rejectingAnAlbumSettlesThePicksOfTheSuggestion() throws {
        let reject = try Self.body("func rejectMatch(", in: Self.model)
        #expect(reject.contains("previewPicks.unmark(proposal.id)"))
    }
}
