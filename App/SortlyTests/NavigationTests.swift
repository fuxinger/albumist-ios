import Testing
import SortlyCore
@testable import Sortly

/// `Navigator`: what moves a stack's mark, and what becomes of a screen pushed at the end of work.
/// From the second review of 6a1969b (Navigation.swift).
@MainActor
struct NavigatorTests {
    @Test func pushAndPopMoveTheMark() {
        let navigator = Navigator()
        let start = navigator.mark
        #expect(navigator.push(.atlas))
        #expect(navigator.path == [.atlas])
        #expect(navigator.mark != start)
        navigator.path.removeLast()
        // The path is the same as at the start, but Back happened in between.
        #expect(navigator.path.isEmpty)
        #expect(navigator.mark != start)
    }

    @Test func anEqualWriteKeepsTheMark() {
        let navigator = Navigator()
        navigator.push(.history)
        let mark = navigator.mark
        // What NavigationStack writes back without a change.
        navigator.path = [.history]
        #expect(navigator.mark == mark)
    }

    @Test func theScreenOnTopAskedForAgainPushesNothingButMovesTheMark() {
        let navigator = Navigator()
        navigator.push(.history)
        let mark = navigator.mark
        #expect(!navigator.push(.history))
        #expect(navigator.path == [.history])
        #expect(navigator.mark != mark)
    }

    @Test func workEndsPushedWaitingOrDropped() {
        let navigator = Navigator()
        let mark = navigator.mark
        // The stack is not on screen (another tab is chosen): the result waits.
        #expect(Navigator.push(.atlas, on: navigator, ifStill: mark) == .waiting)
        #expect(navigator.path.isEmpty)
        #expect(navigator.mark == mark)
        navigator.appeared()
        #expect(navigator.isShowing(mark))
        #expect(navigator.appearances == 1)
        #expect(Navigator.push(.atlas, on: navigator, ifStill: mark) == .pushed)
        #expect(navigator.path == [.atlas])
        // The stack changed since `mark` was read: dropped.
        #expect(!navigator.isShowing(mark))
        #expect(Navigator.push(.history, on: navigator, ifStill: mark) == .dropped)
        #expect(Navigator.push(.history, on: navigator, ifStill: nil) == .dropped)
        #expect(Navigator.push(.history, on: nil, ifStill: navigator.mark) == .dropped)
        #expect(navigator.path == [.atlas])
    }

    @Test func marksOfTwoStacksNeverMatch() {
        let first = Navigator()
        let second = Navigator()
        second.appeared()
        #expect(first.mark != second.mark)
        #expect(Navigator.push(.atlas, on: second, ifStill: first.mark) == .dropped)
        #expect(second.path.isEmpty)
    }
}

/// `AppModel.selectForPreview` and `endPreview`: nothing stays selected that the user never
/// chose, also when one preview opens while another one has the suggestion selected, and
/// whichever of them ends first.
@MainActor
struct PreviewSelectionTests {
    private let newAlbum = ProposalDecision.createNew(title: nil, folderPath: nil)

    private func suggestion(_ id: String) -> AlbumProposal {
        AlbumProposal(id: SortlyID(id), kind: .trip, title: id, assetIDs: [])
    }

    /// The starter set's preview, then "Album anlegen" of one of its suggestions (Mediathek,
    /// photo info), back from that, then out of the starter set: the suggestion stayed
    /// "Ausgewählt" and was saved.
    @Test func nestedPreviewsGiveEverythingBack() {
        let model = AppModel()
        let a = suggestion("a")
        let b = suggestion("b")
        let starter = model.selectForPreview([(a, newAlbum), (b, newAlbum)])
        let direct = model.selectForPreview([(a, newAlbum)])
        model.endPreview(direct)
        #expect(model.decisions[a.id] == newAlbum)
        model.endPreview(starter)
        #expect(model.decisions[a.id] == nil)
        #expect(model.decisions[b.id] == nil)
    }

    @Test func anInnerPreviewGivesBackTheOuterPick() {
        let model = AppModel()
        let a = suggestion("a")
        let extend = ProposalDecision.extendExisting(CollectionID("album"))
        model.decisions[a.id] = .reject
        let outer = model.selectForPreview([(a, newAlbum)])
        let inner = model.selectForPreview([(a, extend)])
        #expect(model.decisions[a.id] == extend)
        model.endPreview(inner)
        #expect(model.decisions[a.id] == newAlbum)
        model.endPreview(outer)
        #expect(model.decisions[a.id] == .reject)
    }

    @Test func aDecisionChangedMeanwhileStays() {
        let model = AppModel()
        let a = suggestion("a")
        let selection = model.selectForPreview([(a, newAlbum)])
        model.decisions[a.id] = .reject
        model.endPreview(selection)
        #expect(model.decisions[a.id] == .reject)
    }

    /// The starter set's preview (Übersicht), "Album anlegen" of the same suggestion with
    /// another pick (Mediathek), and the starter set left first: the open "Album anlegen" keeps
    /// its pick, and when it ends, what was there before both comes back. Nothing the user
    /// never picked is left to be saved.
    @Test func previewsEndingOutOfOrderGiveBackWhatWasThere() {
        let model = AppModel()
        let a = suggestion("a")
        let extend = ProposalDecision.extendExisting(CollectionID("album"))
        model.decisions[a.id] = .reject
        let starter = model.selectForPreview([(a, newAlbum)])
        let direct = model.selectForPreview([(a, extend)])
        model.endPreview(starter)
        #expect(model.decisions[a.id] == extend)
        model.endPreview(direct)
        #expect(model.decisions[a.id] == .reject)
    }

    /// Chosen on purpose while the starter set's preview is open ("Auswählen und später
    /// anlegen" on another tab), then "Album anlegen" of the same suggestion: neither preview
    /// takes the choice away, whichever ends first.
    @Test(arguments: [true, false])
    func aChoiceMadeWhileAPreviewIsOpenStays(starterEndsFirst: Bool) {
        let model = AppModel()
        let a = suggestion("a")
        let extend = ProposalDecision.extendExisting(CollectionID("album"))
        let starter = model.selectForPreview([(a, newAlbum)])
        model.setDecision(extend, for: a)
        let direct = model.selectForPreview([(a, newAlbum)])
        for selection in starterEndsFirst ? [starter, direct] : [direct, starter] {
            model.endPreview(selection)
        }
        #expect(model.decisions[a.id] == extend)
    }
}

/// `PlanRequest.verdict` (Navigation.swift): what becomes of a plan made after a tap, with the
/// album list compared by content (second review of 6a1969b).
@MainActor
struct PlanRequestTests {
    private func album(_ id: String, photos: Set<AssetID> = []) -> CollectionSnapshot {
        CollectionSnapshot(id: CollectionID(id), title: id, assetIDs: photos)
    }

    /// A tap on a stack that shows, with one album in the list.
    private func tap() -> (model: AppModel, navigator: Navigator, request: PlanRequest) {
        let model = AppModel()
        model.inventory = CollectionInventory([album("rom")])
        let navigator = Navigator()
        navigator.appeared()
        return (model, navigator, PlanRequest(model: model, navigator: navigator))
    }

    /// The check after every plan reads the same albums again: `inventoryVersion` goes up, and
    /// the plan still shows (it was dropped without a word before).
    @Test func theSameAlbumsReadAgainShow() {
        let (model, navigator, request) = tap()
        let version = model.inventoryVersion
        model.inventory = CollectionInventory([album("rom")])
        #expect(model.inventoryVersion != version)
        #expect(request.verdict(model: model, navigator: navigator) == .show)
    }

    @Test func changedAlbumsMakeThePlanAgain() {
        let (model, navigator, request) = tap()
        model.inventory = CollectionInventory([album("rom", photos: [AssetID("1")])])
        #expect(request.verdict(model: model, navigator: navigator) == .stale)
    }

    /// A running plan comes first: nothing is made again while it runs.
    @Test func aRunningPlanIsBusy() {
        let (model, navigator, request) = tap()
        model.execution.isRunning = true
        #expect(request.verdict(model: model, navigator: navigator) == .busy)
        model.inventory = CollectionInventory([album("rom"), album("paris")])
        #expect(request.verdict(model: model, navigator: navigator) == .busy)
    }

    @Test func aHiddenStackWaitsAndAnotherScreenIsGone() {
        let (model, navigator, request) = tap()
        navigator.disappeared()
        #expect(request.verdict(model: model, navigator: navigator) == .wait)
        navigator.appeared()
        #expect(request.verdict(model: model, navigator: navigator) == .show)
        navigator.push(.history)
        #expect(request.verdict(model: model, navigator: navigator) == .gone)
        #expect(request.verdict(model: model, navigator: nil) == .gone)
    }
}
