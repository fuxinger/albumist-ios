import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The texts of the plan preview say what really happens (review 18.11.2026):
/// P2-02: a new album named like an album already in its place got the note "Das neue bekommt
/// einen Zusatz", but Albumist makes it under the very same name, so there are two.
/// P3-15: the title said "Vorschau" during the sorting show and over the result too.
@Suite("Plan preview texts")
struct PlanPreviewTextTests {
    static let view = "App/Sortly/Views/PlanReviewView.swift"

    // MARK: P2-02 Same name in the same place

    /// What the note has to say: the planner keeps the title as it is, and the new album lands
    /// next to the old one under the same name.
    @Test func aNewAlbumNamedLikeAnExistingOneKeepsItsNameAndMakesASecondOne() async throws {
        let library = InMemoryPhotoLibrary(assets: ["a", "b", "c"], collections: [
            CollectionSnapshot(id: "old", title: "Paris", assetIDs: ["c"]),
        ])
        let item = ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("p"), kind: .trip, title: "Paris", assetIDs: ["a", "b"]),
                                     decision: .createNew(title: nil, folderPath: nil))
        var plan = OrganizationPlanner(rootFolderTitle: "").makePlan(from: [item], inventory: try await library.currentInventory())
        #expect(plan.conflicts == [.titleExistsInFolder(title: "Paris", existing: "old")])
        let titles = plan.steps.compactMap { step -> String? in
            if case .createAlbum(_, let title, _) = step.operation { title } else { nil }
        }
        #expect(titles == ["Paris"])
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let done = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        #expect(done.status == .completed)
        let paris = try await library.currentInventory().albums.filter { $0.title == "Paris" }
        #expect(paris.count == 2)
        #expect(Set(paris.map(\.parentID)) == [nil])
    }

    /// The note in the preview says that, and no longer promises a suffix.
    @Test func theNoteForAnExistingNameSaysThereWillBeTwo() throws {
        let source = AppSource.code(try AppSource.read(Self.view), keepStrings: true)
        let texts = try #require(AppSource.body(of: "enum ConflictText", in: source))
        let line = try #require(texts.split(separator: "\n").drop { !$0.contains("case .titleExistsInFolder") }.dropFirst()
            .first { !$0.allSatisfy(\.isWhitespace) })
        #expect(line.contains("String(localized: \"Es gibt schon ein anderes Album „\\(title)“. Danach hast du zwei Alben mit diesem Namen.\")"), "\(line)")
        #expect(!source.contains("Zusatz"))
    }

    // MARK: P3-15 The title follows the screen

    @Test func previewWhileNothingRunsAndNothingEnded() {
        #expect(PlanReviewPhase(running: false, runningPlan: nil, previewedPlan: SortlyID("p"), hasResult: false) == .preview)
        #expect(PlanReviewPhase(running: false, runningPlan: nil, previewedPlan: nil, hasResult: false) == .preview)
        // A plan that was refused before it ran (an interrupted plan first) is still the preview.
        #expect(PlanReviewPhase(running: false, runningPlan: SortlyID("p"), previewedPlan: SortlyID("p"), hasResult: false) == .preview)
    }

    @Test func creatingWhileThePreviewedPlanRuns() {
        #expect(PlanReviewPhase(running: true, runningPlan: SortlyID("p"), previewedPlan: SortlyID("p"), hasResult: false) == .creating)
        // Its result is written a moment before the run ends: still running.
        #expect(PlanReviewPhase(running: true, runningPlan: SortlyID("p"), previewedPlan: SortlyID("p"), hasResult: true) == .creating)
    }

    /// An undo of the result shown here, or a plan continued from the overview, also removes
    /// albums: never "Alben werden angelegt".
    @Test func changingWhileAnotherPlanRuns() {
        #expect(PlanReviewPhase(running: true, runningPlan: SortlyID("undo"), previewedPlan: nil, hasResult: false) == .changing)
        #expect(PlanReviewPhase(running: true, runningPlan: SortlyID("other"), previewedPlan: SortlyID("p"), hasResult: false) == .changing)
        #expect(PlanReviewPhase(running: true, runningPlan: nil, previewedPlan: nil, hasResult: false) == .changing)
    }

    @Test func resultOnceARunEnded() {
        #expect(PlanReviewPhase(running: false, runningPlan: SortlyID("p"), previewedPlan: nil, hasResult: true) == .result)
        #expect(PlanReviewPhase(running: false, runningPlan: SortlyID("undo"), previewedPlan: nil, hasResult: true) == .result)
    }

    /// The screen's title is the phase's, and each phase has its own words.
    @Test func theScreenTitleFollowsThePhase() throws {
        let code = AppSource.code(try AppSource.read(Self.view), keepStrings: true)
        let titles = AppSource.calls(of: "navigationTitle(", in: code)
        #expect(titles == ["phase.title"], "\(titles)")
        let phase = try #require(AppSource.body(of: "var phase: PlanReviewPhase", in: code))
        #expect(phase.contains("PlanReviewPhase("))
        let words = try #require(AppSource.body(of: "extension PlanReviewPhase", in: code))
        for expected in [
            "case .preview: LocalizedStringKey(\"Vorschau\")",
            "case .creating: LocalizedStringKey(\"Alben werden angelegt\")",
            "case .changing: LocalizedStringKey(\"Alben werden geändert\")",
            "case .result: LocalizedStringKey(\"Ergebnis\")",
        ] {
            #expect(words.contains(expected), "\(expected)")
        }
        // The card under the title says the same while a plan runs.
        let running = try #require(AppSource.body(of: "private var runningCard", in: code))
        #expect(running.contains("Text(phase.title)"), "\(running)")
    }
}
