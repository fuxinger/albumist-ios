import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The preview's button says what it does (design W1, Punkt 2): "Jetzt anlegen" for new albums,
/// "Jetzt ergänzen" for photos going into albums that are there already, "Jetzt entfernen" for
/// a removal. It replaces "Alben jetzt anlegen", "Fotos jetzt einsortieren" and "Änderungen
/// jetzt ausführen"; a later "später anlegen" does not exist.
@Suite("Preview button word")
struct PreviewButtonWordTests {
    typealias Fixture = ResultHeadlineTests

    static func plan(_ items: [ConfirmedProposal], _ inventory: CollectionInventory = CollectionInventory()) -> ChangePlan {
        OrganizationPlanner().makePlan(from: items, inventory: inventory)
    }

    @Test func newAlbumsAreCreated() {
        let plan = Self.plan([ConfirmedProposal(proposal: Fixture.kyoto, decision: Fixture.new)])
        #expect(PreviewButtonWord(plan) == .create)
        #expect(PreviewButtonWord(plan.summary, kind: .created) == .create)
    }

    /// "Zu Album hinzufügen" with a new name plans like a suggestion: a new album.
    @Test func aNewAlbumOfTheUsersOwnIsCreated() {
        let proposal = AlbumProposal(id: AlbumistID("manual"), kind: .rule, title: "Lieblingsfotos", assetIDs: ["k1", "r1"],
                                     reliability: .certain)
        let word = PreviewButtonWord(Self.plan([ConfirmedProposal(proposal: proposal,
                                                                  decision: .createNew(title: "Lieblingsfotos", folderPath: nil))]))
        #expect(word == .create)
    }

    @Test func photosForAnAlbumOfTheUsersAreAdded() {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let plan = Self.plan([ConfirmedProposal(proposal: Fixture.rom, decision: .extendExisting("mine"))], CollectionInventory([mine]))
        #expect(plan.summary.newAlbums == 0 && plan.summary.totalAssignments == 2)
        #expect(PreviewButtonWord(plan) == .extend)
    }

    /// New albums and photos for an album of the user's in one plan: new albums are what the
    /// button names.
    @Test func newAndExtendedSaysCreate() {
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let plan = Self.plan([ConfirmedProposal(proposal: Fixture.kyoto, decision: Fixture.new),
                              ConfirmedProposal(proposal: Fixture.rom, decision: .extendExisting("mine"))], CollectionInventory([mine]))
        #expect(PreviewButtonWord(plan) == .create)
    }

    /// "Entfernen" on an album of Albumist's: the album goes, or only Albumist's photos leave it.
    @Test func aRemovalSaysRemove() async throws {
        let library = InMemoryPhotoLibrary(assets: Fixture.assets)
        let made = try await Fixture.make([ConfirmedProposal(proposal: Fixture.kyoto, decision: Fixture.new)], in: library)
        let tracker = ManagedAlbumTracker()
        let state = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first)
        let deletes = tracker.removalPlan(for: state, current: try await library.currentInventory())
        #expect(deletes.summary.deletedContainers == 1)
        #expect(PreviewButtonWord(deletes) == .remove)

        try await library.addAssets(["own"], to: state.albumID)
        let takesOut = tracker.removalPlan(for: state, current: try await library.currentInventory())
        #expect(takesOut.summary.deletedContainers == 0 && takesOut.summary.removedMemberships == 3)
        #expect(PreviewButtonWord(takesOut) == .remove)
    }

    /// A plan without new albums, photos or removals (only renames or moves, as a retry may
    /// hold) says it changes something, nothing more.
    @Test func anythingElseIsAChange() {
        var plan = Self.plan([ConfirmedProposal(proposal: Fixture.kyoto, decision: Fixture.new)])
        plan.steps = [PlanStep(id: "rename", operation: .renameCollection("mine", from: "Italien", to: "Italien 2022"), sourceID: nil)]
        #expect(PreviewButtonWord(plan) == .change)
        plan.steps = []
        #expect(PreviewButtonWord(plan) == .change)
    }

    /// The preview's button takes its words from here, in the bar that holds "plan.apply" (the
    /// app does not build on Linux, so this reads its code).
    @Test func thePreviewSaysTheWord() throws {
        let file = try AppSource.read("App/Albumist/Views/PlanReviewView.swift")
        let title = try #require(AppSource.body(of: "private func applyTitle(", in: file))
        #expect(AppSource.code(title).contains("PreviewButtonWord("))
        for words in ["\"Jetzt anlegen\"", "\"Jetzt ergänzen\"", "\"Jetzt entfernen\"", "\"Jetzt ändern\""] {
            #expect(title.contains(words), "\(words)")
        }
        for old in ["Alben jetzt anlegen", "Fotos jetzt einsortieren", "Änderungen jetzt ausführen", "später anlegen"] {
            #expect(!AppSource.code(file, keepStrings: true).contains("\"\(old)"), "\(old)")
        }
        // From the facts the preview made once, not from the plan's photos at every redraw.
        #expect(AppSource.code(title).contains("PreviewButtonWord(summary, kind: PlanReceipt.Kind(plan))"))
        let button = try #require(AppSource.body(of: "private func applyButton(", in: file))
        #expect(AppSource.code(button).contains("applyTitle(plan, facts.summary)"))
    }
}
