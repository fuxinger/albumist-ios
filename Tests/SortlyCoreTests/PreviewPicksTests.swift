import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The picks of previews opened straight from a button (`PreviewPicks`): a preview plans
/// exactly what it picked (second review of design wave 1, 20.11.: the preview of three ticked
/// suggestions showed a fourth, chosen under "Anpassen" before), and leaving it without
/// creating gives every pick back (Fuchs, 14.11.: "Ich hatte aber noch nichts ausgewählt").
@Suite("Preview picks")
struct PreviewPicksTests {
    static let a = SortlyID("a"), b = SortlyID("b"), c = SortlyID("c"), d = SortlyID("d")
    static let create = ProposalDecision.createNew(title: nil, folderPath: nil)
    static let extendX = ProposalDecision.extendExisting(CollectionID("x"))
    static let extendY = ProposalDecision.extendExisting(CollectionID("y"))

    /// The decisions the suggestions show, as the model holds them, with the changes applied.
    struct Shown {
        var decisions: [SortlyID: ProposalDecision] = [:]

        mutating func apply(_ changes: [PreviewPicks.Change]) {
            for change in changes { decisions[change.proposal] = change.decision }
        }
    }

    @Test func aPreviewPlansExactlyItsPicks() {
        var picks = PreviewPicks()
        // "D" was chosen under "Anpassen" days ago and never created.
        var shown = Shown(decisions: [Self.d: Self.extendX])
        let (ticked, changes) = picks.select([.init(Self.a, Self.create), .init(Self.b, Self.create), .init(Self.c, Self.extendY)],
                                             shown: shown.decisions)
        shown.apply(changes)
        #expect(changes.map(\.proposal) == [Self.a, Self.b, Self.c])
        #expect(picks.planned(in: ticked, shown: shown.decisions) == [Self.a: Self.create, Self.b: Self.create, Self.c: Self.extendY])
        // Its own button still has the choice; the starter set's preview knows nothing of it.
        let (starter, more) = picks.select([.init(Self.b, Self.create)], shown: shown.decisions)
        shown.apply(more)
        #expect(picks.planned(in: starter, shown: shown.decisions) == [Self.b: Self.create])
        #expect(shown.decisions[Self.d] == Self.extendX)
    }

    @Test func backWithoutCreatingGivesEveryPickBackAndKeepsAnAdjustedChoice() {
        var picks = PreviewPicks()
        var shown = Shown(decisions: [Self.c: Self.extendX])
        // The card offers what "Anpassen" chose: the preview picks the same for "C".
        let (selection, changes) = picks.select([.init(Self.a, Self.create), .init(Self.c, Self.extendX)], shown: shown.decisions)
        shown.apply(changes)
        // Written to disk meanwhile: as before the preview.
        #expect(picks.stored(shown.decisions) == [Self.c: Self.extendX])
        shown.apply(picks.giveBack(selection, shown: shown.decisions))
        #expect(shown.decisions == [Self.c: Self.extendX])
        #expect(picks.planned(in: selection, shown: shown.decisions).isEmpty)
        // A second end (the screen that pushed went along) changes nothing.
        #expect(picks.giveBack(selection, shown: shown.decisions).isEmpty)
        #expect(picks.stored(shown.decisions) == shown.decisions)
    }

    @Test func twoPreviewsOfTheSameSuggestionEndInAnyOrder() {
        for firstEnds in [true, false] {
            var picks = PreviewPicks()
            var shown = Shown()
            let (first, one) = picks.select([.init(Self.a, Self.create)], shown: shown.decisions)
            shown.apply(one)
            let (second, two) = picks.select([.init(Self.a, Self.extendX)], shown: shown.decisions)
            shown.apply(two)
            // Each plans its own pick; the suggestion shows the latest.
            #expect(picks.planned(in: first, shown: shown.decisions) == [Self.a: Self.create])
            #expect(picks.planned(in: second, shown: shown.decisions) == [Self.a: Self.extendX])
            #expect(shown.decisions[Self.a] == Self.extendX)
            #expect(picks.stored(shown.decisions).isEmpty)
            if firstEnds {
                shown.apply(picks.giveBack(first, shown: shown.decisions))
                #expect(shown.decisions[Self.a] == Self.extendX)
                #expect(picks.planned(in: second, shown: shown.decisions) == [Self.a: Self.extendX])
                shown.apply(picks.giveBack(second, shown: shown.decisions))
            } else {
                shown.apply(picks.giveBack(second, shown: shown.decisions))
                #expect(shown.decisions[Self.a] == Self.create)
                #expect(picks.planned(in: first, shown: shown.decisions) == [Self.a: Self.create])
                shown.apply(picks.giveBack(first, shown: shown.decisions))
            }
            #expect(shown.decisions.isEmpty)
            #expect(picks.stored(shown.decisions).isEmpty)
        }
    }

    @Test func aChoiceMadeOnPurposeMeanwhileStaysAndIsPlanned() {
        var picks = PreviewPicks()
        var shown = Shown()
        let (selection, changes) = picks.select([.init(Self.a, Self.create), .init(Self.b, Self.create)], shown: shown.decisions)
        shown.apply(changes)
        // On another tab: "A" into album Y under "Anpassen", "B" set aside with "Nicht jetzt".
        shown.decisions[Self.a] = Self.extendY
        picks.unmark(Self.a)
        shown.decisions[Self.b] = .reject
        picks.unmark(Self.b)
        #expect(picks.planned(in: selection, shown: shown.decisions) == [Self.a: Self.extendY])
        #expect(picks.stored(shown.decisions) == [Self.a: Self.extendY, Self.b: .reject])
        #expect(picks.giveBack(selection, shown: shown.decisions).isEmpty)
        #expect(shown.decisions == [Self.a: Self.extendY, Self.b: .reject])
    }

    @Test func theEarlierPreviewKeepsWhatWasChosenOnPurposeWhenALaterOnePicksItAgain() {
        var picks = PreviewPicks()
        var shown = Shown()
        let (earlier, one) = picks.select([.init(Self.a, Self.create)], shown: shown.decisions)
        shown.apply(one)
        shown.decisions[Self.a] = Self.extendY
        picks.unmark(Self.a)
        // A card's preview picks "A" again, with another choice.
        let (later, two) = picks.select([.init(Self.a, Self.extendX)], shown: shown.decisions)
        shown.apply(two)
        #expect(picks.planned(in: earlier, shown: shown.decisions) == [Self.a: Self.extendY])
        #expect(picks.planned(in: later, shown: shown.decisions) == [Self.a: Self.extendX])
        #expect(picks.stored(shown.decisions) == [Self.a: Self.extendY])
        shown.apply(picks.giveBack(later, shown: shown.decisions))
        #expect(shown.decisions[Self.a] == Self.extendY)
        #expect(picks.giveBack(earlier, shown: shown.decisions).isEmpty)
    }

    @Test func appliedSuggestionsLeaveThePlan() {
        var picks = PreviewPicks()
        var shown = Shown()
        let (selection, changes) = picks.select([.init(Self.a, Self.create), .init(Self.b, Self.create)], shown: shown.decisions)
        shown.apply(changes)
        // The plan made "A"; "B"'s steps never ran.
        shown.decisions[Self.a] = nil
        picks.unmark(Self.a)
        #expect(picks.planned(in: selection, shown: shown.decisions) == [Self.b: Self.create])
        shown.apply(picks.giveBack(selection, shown: shown.decisions))
        #expect(shown.decisions.isEmpty)
    }

    @Test func keepingTheFirstGivesBackOnlyTheOthers() {
        var picks = PreviewPicks()
        var shown = Shown(decisions: [Self.c: Self.extendX])
        let (selection, changes) = picks.select([.init(Self.a, Self.create), .init(Self.b, Self.create), .init(Self.c, Self.extendX)],
                                                shown: shown.decisions)
        shown.apply(changes)
        // "Die ersten 1 jetzt anlegen": B and C go back.
        shown.apply(picks.giveBack(selection, only: [Self.b, Self.c], shown: shown.decisions))
        #expect(picks.planned(in: selection, shown: shown.decisions) == [Self.a: Self.create])
        #expect(shown.decisions == [Self.a: Self.create, Self.c: Self.extendX])
        #expect(picks.stored(shown.decisions) == [Self.c: Self.extendX])
        // Back: A goes back too, nothing twice.
        shown.apply(picks.giveBack(selection, shown: shown.decisions))
        #expect(shown.decisions == [Self.c: Self.extendX])
    }

    @Test func aCompletedUndoGivesThePicksBackTheirMarks() {
        var picks = PreviewPicks()
        var shown = Shown()
        let (selection, changes) = picks.select([.init(Self.a, Self.create)], shown: shown.decisions)
        shown.apply(changes)
        let earlier = picks
        let selectionBefore = shown.decisions
        // Applied, then undone: the suggestion is picked for the open preview again.
        shown.decisions[Self.a] = nil
        picks.unmark(Self.a)
        shown.decisions[Self.a] = selectionBefore[Self.a]
        picks.restore(Self.a, from: earlier)
        #expect(picks.planned(in: selection, shown: shown.decisions) == [Self.a: Self.create])
        #expect(picks.stored(shown.decisions).isEmpty)
        shown.apply(picks.giveBack(selection, shown: shown.decisions))
        #expect(shown.decisions.isEmpty)
    }

    @Test func aSelectionIsOnlyEqualToItself() {
        var picks = PreviewPicks()
        let (one, _) = picks.select([.init(Self.a, Self.create)], shown: [:])
        let (two, _) = picks.select([.init(Self.a, Self.create)], shown: [:])
        #expect(one != two)
        #expect(one == one)
        #expect(Set([one, two, one]).count == 2)
    }
}

/// The App plans a preview from its own picks only. The App does not build on Linux, so these
/// read its code (`AppSource`). Red before the change: `buildPlan()` planned every accepted
/// suggestion, the preview listed them all, and "Auswahl aufheben" set every one of them back.
@Suite("Previews plan their picks in the App")
struct PreviewPicksAppTests {
    static let model = "App/Sortly/Model/AppModel.swift"
    static let preview = "App/Sortly/Views/PlanReviewView.swift"
    static let routes = "App/Sortly/Views/Navigation.swift"

    /// The body of `declaration` in `file`, without its comments.
    static func body(_ declaration: String, in file: String) throws -> String {
        let source = try AppSource.read(file)
        let body = try #require(AppSource.body(of: declaration, in: source), "\(declaration) is not in \(file)")
        return AppSource.code(body, keepStrings: true)
    }

    @Test func thePlanOfAPreviewIsMadeFromItsPicksOnly() throws {
        let build = try Self.body("func buildPlan(for selection: PreviewSelection)", in: Self.model)
        #expect(build.contains("previewPicks.planned(in: selection"))
        #expect(!build.contains("acceptedProposals"))
        let code = AppSource.code(try AppSource.read(Self.model))
        #expect(!code.contains("func buildPlan()"), "a plan of every accepted suggestion is still there")
        #expect(!code.contains("func clearSelection("))
        let keep = try Self.body("func keepFirst(", in: Self.model)
        #expect(keep.contains("previewPicks.giveBack(selection, only:"))
        #expect(keep.contains("buildPlan(for: selection)"))
    }

    @Test func thePreviewIsOpenedWithItsPicksAndShowsOnlyThem() throws {
        let view = AppSource.code(try AppSource.read(Self.preview))
        #expect(view.contains("model.buildPlan(for: selection)"))
        #expect(view.contains("model.keepFirst(free, in: selection)"))
        #expect(!view.contains("acceptedProposals"), "the preview lists suggestions it does not plan")
        #expect(!view.contains("clearSelection"))
        let routes = AppSource.code(try AppSource.read(Self.routes))
        #expect(routes.contains("case plan(AppModel.PreviewSelection)"))
        #expect(routes.contains("case starterPlan(AppModel.PreviewSelection)"))
        #expect(routes.contains("PlanReviewView(selection: selection)"))
    }

    /// Each preview keeps its own plan: a removal previewed under "Alben" replaced the shared
    /// `model.plan`, and the preview of picks left open on "Vorschläge" then showed and offered
    /// that removal. A plan that ran is never offered again. Red before: the preview read
    /// `model.plan`, and the model held it for every preview.
    @Test func eachPreviewKeepsItsOwnPlan() throws {
        let view = AppSource.code(try AppSource.read(Self.preview))
        #expect(view.firstMatch(of: /model\.plan\b/) == nil, "the preview shows a plan another preview can replace")
        #expect(view.contains("@State private var plan: ChangePlan?"))
        #expect(view.contains("if await model.execute(plan) { self.plan = nil }"))
        let model = AppSource.code(try AppSource.read(Self.model))
        #expect(!model.contains("var plan: ChangePlan?"))
        #expect(model.contains("func execute(_ plan: ChangePlan) async -> Bool"))
        let quick = AppSource.code(try AppSource.read("App/Sortly/Model/AppModel+QuickCreate.swift"))
        #expect(!quick.contains("previewed"), "quick create still puts back a shared plan")
    }
}
