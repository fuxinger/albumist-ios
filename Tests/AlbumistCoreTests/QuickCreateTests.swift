import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// "Anlegen" on a suggestion's card makes its album at once, then a banner „„Name“ angelegt ·
/// Widerrufen“ (design decision 7B, design wave 1). It must be the preview's own plan and run, never
/// a second way into Photos: the planner, the executor with its journal, the free albums, the
/// history and its undo. A card that adds to an album of the user's opens the preview (Punkt 5),
/// the name on the card is the album's name in Photos, and „Widerrufen“ takes back everything.
@Suite("Quick create")
struct QuickCreateTests {
    static let kyoto = AlbumProposal(id: AlbumistID("kyoto"), kind: .trip, title: "Kyoto, Oktober 2024", folderPath: ["Reisen"],
                                     assetIDs: ["k1", "k2", "k3"])

    static func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    static func plan(_ proposal: AlbumProposal, _ decision: ProposalDecision, inventory: CollectionInventory = CollectionInventory(),
                     overrides: OverrideSet = OverrideSet()) -> ChangePlan {
        OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: inventory,
                                       overrides: overrides)
    }

    // MARK: Which suggestions are made at once

    /// Only an album of its own is made at once. Everything that touches an album of the user's,
    /// or still needs a choice, opens the suggestion first.
    @Test func onlyAnAlbumOfItsOwnIsMadeAtOnce() {
        let p = Self.kyoto
        #expect(QuickCreate.mayCreateAtOnce(p, decision: .createNew(title: nil, folderPath: nil)))
        #expect(QuickCreate.mayCreateAtOnce(p, decision: .createNew(title: "Kyoto", folderPath: ["Japan"])))
        let preview: [ProposalDecision] = [
            .extendExisting("mine"),
            .keepExisting("mine"),
            .renameExisting("mine", newTitle: "Kyoto", extend: true),
            .moveExisting("mine", folderPath: ["Reisen"], extend: false),
            .merge(target: "mine", sources: ["other"], title: nil, folderPath: nil),
            .undecided,
            .reject,
        ]
        for decision in preview {
            #expect(!QuickCreate.mayCreateAtOnce(p, decision: decision), "\(decision)")
        }
        // Personal content ("Ansehen …") is looked at first.
        var personal = p
        personal.isSensitive = true
        #expect(!QuickCreate.mayCreateAtOnce(personal, decision: .createNew(title: nil, folderPath: nil)))
    }

    /// Personal content is looked at first, as its card treats it (`ProposalCardText`): a
    /// sensitive suggestion, and one whose preview is hidden because every photo is a sensitive
    /// document. Its card shows no photo, so the user has never seen what would go into Photos
    /// (second review of the cards). Both open the suggestion, then the preview.
    @Test func whatTheUserHasNotSeenIsLookedAtFirst() {
        let new = ProposalDecision.createNew(title: nil, folderPath: nil)
        #expect(QuickCreate.mayCreateAtOnce(Self.kyoto, decision: new, hidesPreview: false))
        #expect(!QuickCreate.mayCreateAtOnce(Self.kyoto, decision: new, hidesPreview: true))
        #expect(!QuickCreate.mayCreateAtOnce(Self.kyoto, decision: .createNew(title: "Kyoto", folderPath: ["Japan"]), hidesPreview: true))
        var sensitive = Self.kyoto
        sensitive.isSensitive = true
        #expect(!QuickCreate.mayCreateAtOnce(sensitive, decision: new, hidesPreview: false))
        #expect(!QuickCreate.mayCreateAtOnce(sensitive, decision: new, hidesPreview: true))
    }

    /// What „Anlegen“ chooses is what the suggestion recommends: a certain match of the user's
    /// album is extended, so its card goes through the preview („Ergänzen …“); a place without
    /// a name stays undecided („Benennen …“).
    @Test func theRecommendationDecidesTheWay() {
        let p = Self.kyoto
        #expect(QuickCreate.mayCreateAtOnce(p, decision: ProposalDecision.recommended(for: p, match: nil)))
        let candidate = MatchCandidate(albumID: "mine", albumTitle: "Japan", metrics: OverlapMetrics(proposalCount: 3, albumCount: 3, intersection: 2),
                                       relation: .equivalent, nameSimilarity: 0, score: 0.9, isEditable: true)
        let extendable = MatchResult(proposalID: p.id, status: .extendable, best: candidate, alternatives: [], sameNameAlbums: [], reasons: [])
        #expect(!QuickCreate.mayCreateAtOnce(p, decision: ProposalDecision.recommended(for: p, match: extendable)))
        var unnamed = p
        unnamed.requiresUserName = true
        #expect(!QuickCreate.mayCreateAtOnce(unnamed, decision: ProposalDecision.recommended(for: unnamed, match: nil)))
        #expect(QuickCreate.mayCreateAtOnce(unnamed, decision: ProposalDecision.recommended(for: unnamed, match: nil, userTitle: "Oma")))
    }

    // MARK: Which plans run without the preview

    @Test func thePlanOfANewAlbumRunsWithoutThePreview() {
        let plan = Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil))
        // The folders it needs are made too ("Albumist", "Reisen").
        #expect(plan.summary.newFolders == 2)
        #expect(QuickCreate.mayRunWithoutPreview(plan))
    }

    /// A plan that adds to, renames, moves, empties or deletes an album of the user's, makes
    /// two albums, makes an empty album, or has something to point out goes through the preview.
    @Test func everyOtherPlanGoesThroughThePreview() {
        let mine = CollectionSnapshot(id: "mine", title: "Japan", assetIDs: ["k1"])
        let inventory = CollectionInventory([mine])
        #expect(!QuickCreate.mayRunWithoutPreview(Self.plan(Self.kyoto, .extendExisting("mine"), inventory: inventory)))
        #expect(!QuickCreate.mayRunWithoutPreview(Self.plan(Self.kyoto, .renameExisting("mine", newTitle: "Kyoto", extend: false), inventory: inventory)))
        // An album of the same name in the same folder: said in the preview, never made beside it unseen.
        let root = CollectionSnapshot(id: "root", title: "Albumist", kind: .folder)
        let trips = CollectionSnapshot(id: "trips", title: "Reisen", kind: .folder, parentID: "root")
        let same = CollectionSnapshot(id: "same", title: "Kyoto, Oktober 2024", parentID: "trips", assetIDs: ["x"])
        let twin = Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil), inventory: CollectionInventory([root, trips, same]))
        #expect(!twin.conflicts.isEmpty)
        #expect(!QuickCreate.mayRunWithoutPreview(twin))
        // Every photo ignored: an empty album is no album.
        let overrides = OverrideSet(Self.kyoto.assetIDs.map { UserOverride(scope: .asset($0), decision: .ignoreAsset) })
        let empty = Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil), overrides: overrides)
        #expect(!QuickCreate.mayRunWithoutPreview(empty))
        // Two albums are the preview's.
        let rome = AlbumProposal(id: AlbumistID("rome"), kind: .trip, title: "Rom", folderPath: ["Reisen"], assetIDs: ["r1"])
        let two = OrganizationPlanner().makePlan(from: [
            ConfirmedProposal(proposal: Self.kyoto, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: rome, decision: .createNew(title: nil, folderPath: nil)),
        ], inventory: CollectionInventory())
        #expect(!QuickCreate.mayRunWithoutPreview(two))
        #expect(QuickCreate.albumTitle(of: two) == nil)
        // An undo or a retry is never "Anlegen".
        var undo = Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil))
        undo.reverts = AlbumistID("earlier")
        #expect(!QuickCreate.mayRunWithoutPreview(undo))
        var retry = Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil))
        retry.retries = AlbumistID("earlier")
        #expect(!QuickCreate.mayRunWithoutPreview(retry))
    }

    // MARK: The banner

    /// The banner says the album's name exactly as the plan writes it to Photos, also the name
    /// the user gave it, cleaned the way Photos gets it.
    @Test func theBannerSaysTheNameAsInPhotos() throws {
        let plan = Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil))
        let banner = try #require(QuickCreateBanner(plan: plan, proposalID: Self.kyoto.id))
        #expect(banner.title == "Kyoto, Oktober 2024")
        #expect(banner.id == plan.id && banner.proposalID == Self.kyoto.id && banner.canUndo)
        let named = Self.plan(Self.kyoto, .createNew(title: "  Kyoto mit Oma\n", folderPath: nil))
        let written = named.steps.compactMap { step -> String? in
            if case .createAlbum(_, let title, _) = step.operation { return title }
            return nil
        }
        #expect(QuickCreate.albumTitle(of: named) == written.first)
        #expect(QuickCreate.albumTitle(of: named) == AlbumTitle.sanitize("  Kyoto mit Oma\n"))
        // No banner for a plan without exactly one new album.
        let none = Self.plan(Self.kyoto, .reject)
        #expect(QuickCreateBanner(plan: none, proposalID: Self.kyoto.id) == nil)
    }

    /// While it is taken back, „Widerrufen“ cannot be tapped again.
    @Test func widerrufenOnlyOnce() throws {
        var banner = try #require(QuickCreateBanner(plan: Self.plan(Self.kyoto, .createNew(title: nil, folderPath: nil)), proposalID: Self.kyoto.id))
        banner.phase = .checking
        #expect(!banner.canUndo)
        banner.phase = .undoing(deletesAlbum: true)
        #expect(!banner.canUndo)
        banner.phase = .shown
        #expect(banner.canUndo)
    }

    /// Long enough to read the name and reach „Widerrufen“, and much longer with VoiceOver.
    @Test func theBannerStaysLongEnough() {
        #expect(QuickCreate.bannerDuration(assistive: false) == .seconds(8))
        #expect(QuickCreate.bannerDuration(assistive: true) == .seconds(20))
        // Longer than the note after "Ignorieren" (6 s): a name takes longer to read than a number.
        #expect(QuickCreate.bannerDuration(assistive: false) > .seconds(6))
    }

    // MARK: How the run ended

    static let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))

    static func ran(_ album: StepState, _ photos: StepState, unverified: Set<String> = []) -> ChangePlan {
        var plan = ChangePlan(id: AlbumistID("made"), createdAt: Date(), confirmedAt: Date(), status: .completed, baseline: [:],
                              baselineCollectionIDs: [], steps: [
                                PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Kyoto", parent: .topLevel), sourceID: AlbumistID("kyoto"), state: album),
                                PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["k1", "k2"]), sourceID: AlbumistID("kyoto"), state: photos),
                              ], conflicts: [], notes: [], resolvedKeys: ["A": "a1"])
        var record = ExecutionRecord()
        record.unverified = unverified
        plan.record = record
        return plan
    }

    /// By what Photos confirmed, as the receipt counts it.
    @Test func theEndingFollowsWhatPhotosConfirmed() {
        #expect(QuickCreate.ending(of: Self.ran(Self.done, Self.done)) == .created)
        #expect(QuickCreate.ending(of: Self.ran(Self.done, .failed(reason: "Fotos antwortet nicht"))) == .createdWithGaps(failedSteps: 1))
        #expect(QuickCreate.ending(of: Self.ran(.failed(reason: "x"), .skipped(reason: "x"))) == .notCreated)
        #expect(QuickCreate.ending(of: Self.ran(.pending, .pending)) == .notCreated)
        // Photos did not confirm the album: not said as made.
        #expect(QuickCreate.ending(of: Self.ran(Self.done, Self.done, unverified: ["0"])) == .notCreated)
    }

    // MARK: End to end: the same plan and run as the preview, and „Widerrufen“

    /// The plan made from the card runs through the executor like the preview's, the album in
    /// Photos has the banner's name and the suggestion's photos, and „Widerrufen“ (the history's
    /// undo of exactly that plan) deletes it again, which iOS asks about first, while the user's
    /// own album and every photo stay.
    @Test func widerrufenTakesBackExactlyThatAlbum() async throws {
        let mine = CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "k1"])
        let library = InMemoryPhotoLibrary(assets: ["k1", "k2", "k3", "own"], collections: [mine])
        let before = try await library.currentInventory()
        let decision = ProposalDecision.recommended(for: Self.kyoto, match: nil)
        #expect(QuickCreate.mayCreateAtOnce(Self.kyoto, decision: decision))
        let plan = Self.plan(Self.kyoto, decision, inventory: before)
        #expect(QuickCreate.mayRunWithoutPreview(plan))
        let banner = try #require(QuickCreateBanner(plan: plan, proposalID: Self.kyoto.id))

        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let made = try await executor.execute(Self.confirmed(plan))
        #expect(QuickCreate.ending(of: made) == .created)
        let after = try await library.currentInventory()
        let album = try #require(after.albums.first { $0.title == banner.title }, "the album in Photos has another name")
        #expect(Set(album.assetIDs) == ["k1", "k2", "k3"])
        #expect(after.path(of: album.id) == ["Albumist", "Reisen"])
        #expect(PlanReceipt(plan: made, inventory: after).albumsCreated == 1)

        let records = ManagedAlbumTracker().record(made, into: [], inventory: after)
        let undo = UndoPlanner().undoPlan(for: made, albums: records, current: after, earlierUndos: [])
        // iOS asks before the album goes: the banner says so while it is taken back.
        #expect(undo.deletesCollections)
        let undone = try await executor.execute(Self.confirmed(undo))
        #expect(undone.status == .completed)
        let restored = try await library.currentInventory()
        #expect(restored.albums.first { $0.title == banner.title } == nil)
        #expect(restored["mine"] == mine)
        #expect(await library.assets == ["k1", "k2", "k3", "own"])
    }

    // MARK: The App goes the same way (the App does not build on Linux: its code is read)

    static let model = "App/Albumist/Model/AppModel+QuickCreate.swift"
    static let banner = "App/Albumist/Views/Frame/QuickCreateBar.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    /// One way into Photos: the preview's `execute` and the history's `undo`, never an executor,
    /// a library call or a run of its own.
    @Test func theAppHasNoSecondWayIntoPhotos() throws {
        let code = AppSource.code(try AppSource.read(Self.model))
        #expect(AppSource.calls(of: "execute(", in: code).count == 1, "make the album only through AppModel.execute")
        #expect(AppSource.calls(of: "undo(", in: code).count == 1, "take it back only through AppModel.undo")
        for forbidden in ["ChangeExecutor(", "performChanges(", "library.", "run(", "UndoPlanner("] {
            #expect(AppSource.calls(of: forbidden, in: code).isEmpty && !code.contains(forbidden), "\(forbidden) in \(Self.model)")
        }
    }

    /// Before it makes anything, „Anlegen“ asks what the preview asks, in the preview's order:
    /// the suggestion and its plan may skip the preview, nothing interrupted is open, the free
    /// albums suffice (else the purchase sheet). The suggestion is selected only for this plan
    /// and given back afterwards, whatever happened.
    @Test func theAppAsksWhatThePreviewAsksFirst() throws {
        let code = AppSource.code(try AppSource.read(Self.model))
        let create = try #require(AppSource.body(of: "func createNow(", in: code))
        let order = ["QuickCreate.mayCreateAtOnce(", "selectForPreview(", "singlePlan(for:", "QuickCreate.mayRunWithoutPreview(",
                     "PlanGate.refusal(for:", ".allows(albums:", "execute("]
        let positions = order.map { create.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil), "missing: \(zip(order, positions).filter { $0.1 == nil }.map(\.0))")
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), "asked in another order than \(order)")
        #expect(create.contains("endPreview("), "the selection of the suggestion is never given back")
        #expect(create.contains("purchase ="), "used-up free albums do not open the purchase sheet")
    }

    /// Every card's „Anlegen“ and the suggestion's own „Album anlegen“ end in `createNow`: it asks
    /// whether the suggestion's photos are hidden, exactly as its card decides it
    /// (`previewHidden(for:)`, `ProposalCardText.hidesPreview`), so such a suggestion opens first.
    @Test func theAppAsksWhetherThePhotosWereShown() throws {
        let code = AppSource.code(try AppSource.read(Self.model))
        let create = try #require(AppSource.body(of: "func createNow(", in: code))
        let asks = AppSource.calls(of: "QuickCreate.mayCreateAtOnce(", in: create)
        #expect(asks.count == 1)
        #expect(asks.allSatisfy { $0.contains("hidesPreview: previewHidden(for: proposal)") }, "\(asks)")
    }

    /// „Widerrufen“ finds out first whether the undo deletes the album (iOS asks then), as every
    /// undo of the app does (P3-07), and takes back exactly the banner's plan.
    @Test func widerrufenAnnouncesTheIOSQuestion() throws {
        let code = AppSource.code(try AppSource.read(Self.model))
        let undo = try #require(AppSource.body(of: "func undoQuickCreate(", in: code))
        let asks = try #require(undo.range(of: "undoDeletesCollections(banner.plan)"))
        let runs = try #require(undo.range(of: "await undo(banner.plan)"))
        #expect(asks.lowerBound < runs.lowerBound)
        let view = try Self.code(Self.banner)
        #expect(view.contains(/if\s+case\s+\.undoing\(\s*deletesAlbum:\s*true\s*\)\s*=\s*banner\.phase\s*\{\s*DeleteQuestionNote\.text/),
                "the banner does not announce the iOS question while the album is taken back")
    }

    /// The banner's button says „Widerrufen“ (the word for the short note right after an action,
    /// P3-09) and has a fixed identifier for the UI tests.
    @Test func theBannerHasOneButtonWithAFixedName() throws {
        let view = try Self.code(Self.banner)
        #expect(view.contains("Text(\"Widerrufen\")"))
        #expect(view.contains(".accessibilityIdentifier(\"quickCreate.undo\")"))
        #expect(view.contains(".accessibilityIdentifier(\"quickCreate.banner\")"))
        #expect(AppSource.calls(of: "undoQuickCreate(", in: AppSource.code(view)).count == 1)
    }
}
