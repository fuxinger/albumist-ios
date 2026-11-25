import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// What a row of the history ("Verlauf und Rückgängig") says a change did (design wave 3, H12):
/// a plan that made or extended albums as always ("25 neu, 236 Fotos"), with the albums it renamed
/// or moved ("1 umbenannt", "1 verschoben"); a removal of albums Albumist made ("Album entfernen")
/// and an undo what they did ("2 entfernt", "12 Fotos herausgenommen", each photo counted once).
/// "N Fotos" only when photos came; a change of nothing says so ("Nichts geändert", "Nichts
/// entfernt"), never "0 Fotos" (review M2). The rule is decided here (`HistoryLine`); the app maps
/// each part to a string of the catalog (`Counted.historyLine`). The history lists no undo today
/// (it marks the plan it took back); the rule covers it all the same.
@Suite("History line")
struct HistoryLineTests {
    static let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))
    static let new = ProposalDecision.createNew(title: nil, folderPath: nil)

    /// A plan of `operations`, each step done unless `states` says otherwise.
    static func plan(_ operations: [PlannedOperation], states: [Int: StepState] = [:], reverts: AlbumistID? = nil,
                     record: ExecutionRecord? = nil) -> ChangePlan {
        let steps = operations.enumerated().map { index, operation in
            PlanStep(id: "s\(index)", operation: operation, sourceID: AlbumistID("source"), state: states[index] ?? Self.done)
        }
        var plan = ChangePlan(id: AlbumistID("p"), createdAt: Date(timeIntervalSince1970: 0), confirmedAt: Date(timeIntervalSince1970: 0),
                              status: .completed, baseline: [:], baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [],
                              resolvedKeys: [:])
        plan.reverts = reverts
        plan.record = record
        return plan
    }

    /// A trip with `count` photos "<id>-1" … "<id>-<count>".
    static func trip(_ id: String, photos count: Int = 3) -> AlbumProposal {
        AlbumProposal(id: AlbumistID(id), kind: .trip, title: "Reise \(id)", folderPath: ["Reisen"],
                      assetIDs: Set((1...count).map { AssetID("\(id)-\($0)") }))
    }

    static func run(_ plan: ChangePlan, in library: some PhotoLibraryWriting) async throws -> ChangePlan {
        var confirmed = plan
        confirmed.confirmedAt = Date()
        confirmed.status = .confirmed
        return try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed)
    }

    /// The album Albumist made for `trip` in `library`, with its plan "Album entfernen"
    /// (`ManagedAlbumTracker.removalPlan`), made while it holds only Albumist's photos.
    static func removal(of trip: AlbumProposal, in library: InMemoryPhotoLibrary) async throws -> (album: CollectionID, plan: ChangePlan) {
        let made = try await run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: trip, decision: new)],
                                                                inventory: try await library.currentInventory()), in: library)
        let tracker = ManagedAlbumTracker()
        let state = try #require(tracker.record(made, into: [], inventory: try await library.currentInventory()).first)
        return (state.albumID, tracker.removalPlan(for: state, current: try await library.currentInventory()))
    }

    // MARK: Made or extended albums: as always

    /// "1 neu, 1 ergänzt, 5 Fotos": the albums it made, the user's it extended, the different
    /// photos it put into albums.
    @Test func aPlanThatMadeAlbumsSaysWhatItMadeAsAlways() {
        let made = Self.plan([.createAlbum(key: "rom", title: "Rom", parent: .topLevel),
                              .addAssets(album: .planned("rom"), assets: ["rom-1", "rom-2", "rom-3"]),
                              .addAssets(album: .existing("mine"), assets: ["rom-3", "kyoto-1", "kyoto-2"])])
        #expect(PlanReceipt.Kind(made) == .created)
        #expect(HistoryLine.parts(of: made) == [.created(1), .extended(1), .photos(5)])
        let extended = Self.plan([.addAssets(album: .existing("mine"), assets: ["kyoto-1"])])
        #expect(HistoryLine.parts(of: extended) == [.extended(1), .photos(1)])
    }

    /// "N Fotos" only when photos came (review M2): an album made whose photos did not come says
    /// "1 neu", not "1 neu, 0 Fotos".
    @Test func noPhotosAreNotSaidBesideAnotherPart() {
        let empty = Self.plan([.createAlbum(key: "rom", title: "Rom", parent: .topLevel),
                               .addAssets(album: .planned("rom"), assets: ["rom-1"])],
                              states: [1: .failed(reason: "Fotos hat nicht geantwortet.")])
        #expect(HistoryLine.parts(of: empty) == [.created(1)])
    }

    // MARK: Renamed, moved, nothing changed (review M2)

    /// A plan that only renamed or moved an album of the user's says so: "1 umbenannt", "1
    /// verschoben" (it said "0 Fotos"), counted as its receipt counts them. The folder made to
    /// move the album into is not counted, as "neu" counts albums only.
    @Test func aPlanThatRenamedOrMovedAnAlbumSaysSo() async throws {
        let rom = Self.trip("rom")
        let library = InMemoryPhotoLibrary(assets: rom.assetIDs.union(["own"]),
                                           collections: [CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])])
        func run(_ decision: ProposalDecision) async throws -> ChangePlan {
            try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: rom, decision: decision)],
                                                              inventory: try await library.currentInventory()), in: library)
        }
        let renamed = try await run(.renameExisting("mine", newTitle: "Rom", extend: false))
        #expect(try await library.currentInventory()["mine"]?.title == "Rom")
        #expect(PlanReceipt(plan: renamed, inventory: CollectionInventory()).renamed == 1)
        #expect(HistoryLine.parts(of: renamed) == [.renamed(1)])
        let moved = try await run(.moveExisting("mine", folderPath: ["Reisen"], extend: false))
        #expect(try await library.currentInventory()["mine"]?.parentID != nil)
        #expect(PlanReceipt(plan: moved, inventory: CollectionInventory()).moved == 1)
        #expect(HistoryLine.parts(of: moved) == [.moved(1)])
    }

    /// Beside what the plan made, in the order of the line: "1 neu, 1 ergänzt, 1 umbenannt, 6
    /// Fotos", as "25 neu, 1 umbenannt, 236 Fotos".
    @Test func aRenameStandsBesideWhatThePlanMade() async throws {
        let rom = Self.trip("rom"), kyoto = Self.trip("kyoto")
        let library = InMemoryPhotoLibrary(assets: rom.assetIDs.union(kyoto.assetIDs).union(["own"]),
                                           collections: [CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])])
        let plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                         ConfirmedProposal(proposal: rom, decision: .renameExisting("mine", newTitle: "Rom", extend: true))],
                                                  inventory: try await library.currentInventory())
        let ran = try await Self.run(plan, in: library)
        #expect(HistoryLine.parts(of: ran) == [.created(1), .extended(1), .renamed(1), .photos(6)])
    }

    /// Only what Photos confirmed, as the receipt counts it: a rename or a move whose outcome
    /// Photos did not confirm is not said.
    @Test func aRenameOrMovePhotosDidNotConfirmIsNotSaid() {
        var record = ExecutionRecord()
        record.unverified = ["s0", "s1"]
        let plan = Self.plan([.renameCollection("mine", from: "Italien", to: "Rom"), .moveCollection("mine", from: nil, to: .topLevel)],
                             record: record)
        let receipt = PlanReceipt(plan: plan, inventory: CollectionInventory())
        #expect(receipt.renamed == 0 && receipt.moved == 0)
        #expect(HistoryLine.parts(of: plan) == [.nothingChanged])
    }

    /// A plan that changed nothing at all says so, "Nichts geändert" (it said "0 Fotos"): every
    /// addition failed, or its photos were no longer in the library when it ran.
    @Test func aPlanThatChangedNothingSaysSo() async throws {
        let failed = Self.plan([.createAlbum(key: "rom", title: "Rom", parent: .topLevel), .addAssets(album: .planned("rom"), assets: ["rom-1"])],
                               states: [0: .failed(reason: "x"), 1: .failed(reason: "x")])
        #expect(HistoryLine.parts(of: failed) == [.nothingChanged])
        // The trip's photos were deleted before the plan ran: the user's album gets none.
        let library = InMemoryPhotoLibrary(assets: ["own"], collections: [CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])])
        let gone = try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: Self.trip("rom"), decision: .extendExisting("mine"))],
                                                                     inventory: try await library.currentInventory()), in: library)
        #expect(gone.record?.unavailable.values.reduce(0, +) == 3)
        #expect(HistoryLine.parts(of: gone) == [.nothingChanged])
    }

    /// A removal that removed nothing says so, "Nichts entfernt" ("0 Fotos" read as if a removal
    /// were about photos): the user declined in the iOS question, Photos did not carry it out, or
    /// Photos did not confirm what happened.
    @Test func aRemovalThatRemovedNothingSaysSo() async throws {
        for behavior in [InMemoryPhotoLibrary.DeletionBehavior.declined, .silentlyIgnored] {
            let library = InMemoryPhotoLibrary(assets: Self.trip("kyoto").assetIDs)
            let (album, plan) = try await Self.removal(of: Self.trip("kyoto"), in: library)
            await library.setDeletionBehavior(behavior)
            let ran = try await Self.run(plan, in: library)
            #expect(try await library.currentInventory()[album] != nil, "\(behavior): the album is there")
            #expect(PlanReceipt.Kind(ran) == .removed)
            #expect(HistoryLine.parts(of: ran) == [.nothingRemoved], "\(behavior)")
        }
        var record = ExecutionRecord()
        record.unverified = ["s0"]
        let unconfirmed = Self.plan([.removeAssets(album: "a", assets: ["rom-1"])], record: record)
        #expect(HistoryLine.parts(of: unconfirmed) == [.nothingRemoved])
    }

    // MARK: Undo and removal: what they did

    /// Taking back a trip album the run made removes the album (its folders are not counted, as
    /// "neu" counts albums only): "1 entfernt", never "0 Fotos".
    @Test func anUndoSaysWhichAlbumsItRemoved() async throws {
        let kyoto = Self.trip("kyoto")
        let library = InMemoryPhotoLibrary(assets: kyoto.assetIDs)
        let made = try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: kyoto, decision: Self.new)],
                                                                    inventory: try await library.currentInventory()), in: library)
        #expect(HistoryLine.parts(of: made) == [.created(1), .photos(3)])
        let inventory = try await library.currentInventory()
        let states = ManagedAlbumTracker().record(made, into: [], inventory: inventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: states, current: inventory, earlierUndos: []), in: library)
        #expect(PlanReceipt.Kind(undo) == .undone)
        #expect(PlanSummary(applied: undo).deletedContainers > 1, "the album and its folders")
        #expect(HistoryLine.parts(of: undo) == [.removed(1)])
    }

    /// Taking back photos added to an album of the user's takes them out of it: "3 Fotos
    /// herausgenommen"; the album and the user's own photo stay.
    @Test func anUndoSaysHowManyPhotosItTookOut() async throws {
        let rom = Self.trip("rom")
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = InMemoryPhotoLibrary(assets: rom.assetIDs.union(["own"]), collections: [mine])
        let made = try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: rom, decision: .extendExisting("mine"))],
                                                                    inventory: try await library.currentInventory()), in: library)
        #expect(HistoryLine.parts(of: made) == [.extended(1), .photos(3)])
        let inventory = try await library.currentInventory()
        let states = ManagedAlbumTracker().record(made, into: [], inventory: inventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: states, current: inventory, earlierUndos: []), in: library)
        #expect(HistoryLine.parts(of: undo) == [.takenOut(3)])
    }

    /// "Album entfernen" on an album Albumist made: an album of nothing but Albumist's photos is
    /// removed ("1 entfernt"); one the user put a photo into keeps it and loses Albumist's ("3
    /// Fotos herausgenommen").
    @Test func aRemovalSaysWhatItRemoved() async throws {
        let rom = Self.trip("rom"), kyoto = Self.trip("kyoto")
        let library = InMemoryPhotoLibrary(assets: rom.assetIDs.union(kyoto.assetIDs).union(["own"]))
        let made = try await Self.run(OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: rom, decision: Self.new),
                                                                           ConfirmedProposal(proposal: kyoto, decision: Self.new)],
                                                                    inventory: try await library.currentInventory()), in: library)
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(made, into: [], inventory: try await library.currentInventory())
        let romState = try #require(states.first { $0.sourceID == rom.id })
        let kyotoState = try #require(states.first { $0.sourceID == kyoto.id })
        let removal = try await Self.run(tracker.removalPlan(for: romState, current: try await library.currentInventory()), in: library)
        #expect(PlanReceipt.Kind(removal) == .removed)
        #expect(HistoryLine.parts(of: removal) == [.removed(1)])
        // The user puts a photo of their own into the other album first.
        try await library.addAssets(["own"], to: kyotoState.albumID)
        let kept = try await Self.run(tracker.removalPlan(for: kyotoState, current: try await library.currentInventory()), in: library)
        #expect(HistoryLine.parts(of: kept) == [.takenOut(3)])
    }

    /// "Album entfernen" on an album a photo came into after the plan was checked (the user,
    /// iCloud): the run keeps the album with that photo and takes Albumist's photos out, and the
    /// history says so (review M1: "0 Fotos"), from what the run wrote down once Photos showed
    /// them gone.
    @Test func aRemovalThatKeptItsAlbumSaysWhichPhotosItTookOut() async throws {
        let base = InMemoryPhotoLibrary(assets: Self.trip("kyoto").assetIDs.union(["own"]))
        let (album, plan) = try await Self.removal(of: Self.trip("kyoto"), in: base)
        #expect(plan.steps.allSatisfy { if case .deleteCollection = $0.operation { true } else { false } })
        let library = HookedLibrary(base)
        await library.afterAvailabilityCheck { try? await base.addAssets(["own"], to: album) }
        let ran = try await Self.run(plan, in: library)
        #expect(try await base.currentInventory()[album]?.assetIDs == ["own"], "kept, with the user's photo only")
        #expect(ran.steps.allSatisfy { if case .skipped = $0.state { true } else { false } })
        #expect(HistoryLine.parts(of: ran) == [.takenOut(3)])
    }

    /// Each photo counts once, as "Fotos" counts the photos a plan put into albums: a photo taken
    /// out of two albums is one photo; only what the library confirmed counts.
    @Test func eachPhotoTakenOutCountsOnce() {
        var record = ExecutionRecord()
        record.media["s1"] = ["rom-1"]
        let undo = Self.plan([.removeAssets(album: "a", assets: ["rom-1", "rom-2"]), .removeAssets(album: "b", assets: ["rom-1", "rom-2", "rom-3"]),
                              .removeAssets(album: "c", assets: ["rom-4"])],
                             states: [2: .failed(reason: "Fotos hat nicht geantwortet.")], reverts: AlbumistID("made"), record: record)
        // "a" took out both, "b" only rom-1 as the library says, "c" failed.
        #expect(HistoryLine.parts(of: undo) == [.takenOut(2)])
    }

    /// An undo of a removal brings the album back with its photos: "1 neu, 3 Fotos", after what it
    /// took back, if anything.
    @Test func anUndoOfARemovalSaysWhatItBroughtBack() {
        let undo = Self.plan([.createAlbum(key: "restore:a", title: "Rom", parent: .topLevel),
                              .addAssets(album: .planned("restore:a"), assets: ["rom-1", "rom-2", "rom-3"]),
                              .removeAssets(album: "b", assets: ["kyoto-1"])],
                             reverts: AlbumistID("removal"))
        #expect(HistoryLine.parts(of: undo) == [.takenOut(1), .created(1), .photos(3)])
    }

    /// Removed albums, not folders: the run writes down each album it deletes
    /// (`ExecutionRecord.deletedAlbums`); a plan from a version that wrote down none counts each
    /// collection it removed.
    @Test func removedCountsAlbumsNotFolders() {
        var record = ExecutionRecord()
        record.deletedAlbums["album"] = DeletedAlbumRecord(title: "Rom", parentID: "folder", members: ["rom-1"])
        let steps: [PlannedOperation] = [.deleteCollection("album", title: "Rom"), .deleteCollection("folder", title: "Reisen")]
        #expect(HistoryLine.parts(of: Self.plan(steps, reverts: AlbumistID("made"), record: record)) == [.removed(1)])
        #expect(HistoryLine.parts(of: Self.plan(steps, reverts: AlbumistID("made"))) == [.removed(2)])
        // A deletion that did not happen is not counted.
        let failed = Self.plan(steps, states: [0: .failed(reason: "x"), 1: .failed(reason: "x")], reverts: AlbumistID("made"), record: record)
        #expect(HistoryLine.parts(of: failed) == [.nothingChanged])
    }

    /// Every removed collection counts only for a plan of a version that wrote down no record at
    /// all; a record that lists no album counts none (review M3): an album the user deleted right
    /// before the run is gone all the same, but Albumist removed nothing.
    @Test func aRecordThatListsNoAlbumCountsNoAlbum() async throws {
        let base = InMemoryPhotoLibrary(assets: Self.trip("kyoto").assetIDs)
        let (album, plan) = try await Self.removal(of: Self.trip("kyoto"), in: base)
        let library = HookedLibrary(base)
        await library.afterAvailabilityCheck { try? await base.deleteCollection(album) }
        let ran = try await Self.run(plan, in: library)
        #expect(ran.steps.allSatisfy { if case .succeeded = $0.state { true } else { false } }, "gone, as it was to be")
        #expect(ran.record?.deletedAlbums.isEmpty == true)
        #expect(HistoryLine.parts(of: ran) == [.nothingRemoved])
        // The same plan without a record (a version before the record): each removal counts.
        var old = ran
        old.record = nil
        #expect(HistoryLine.parts(of: old) == [.removed(1)])
    }

    /// An undo of nothing says "Nichts geändert": its steps all failed, or it had nothing left to
    /// do. No line ever says "0 Fotos", and every line says something.
    @Test func noLineSaysZeroPhotos() {
        let failed = Self.plan([.removeAssets(album: "a", assets: ["rom-1"])], states: [0: .failed(reason: "x")], reverts: AlbumistID("made"))
        #expect(HistoryLine.parts(of: failed) == [.nothingChanged])
        let nothing = Self.plan([], reverts: AlbumistID("made"))
        #expect(HistoryLine.parts(of: nothing) == [.nothingChanged])
        let failedAdd = [0: StepState.failed(reason: "x")]
        for plan in [Self.plan([]), Self.plan([.addAssets(album: .existing("a"), assets: ["rom-1"])], states: failedAdd),
                     Self.plan([.removeAssets(album: "a", assets: ["rom-1"])], states: failedAdd),
                     Self.plan([.removeAssets(album: "a", assets: ["rom-1"])], reverts: AlbumistID("made")),
                     Self.plan([.deleteCollection("a", title: "Rom")], reverts: AlbumistID("made")),
                     Self.plan([.createAlbum(key: "rom", title: "Rom", parent: .topLevel)])] {
            let parts = HistoryLine.parts(of: plan)
            #expect(!parts.isEmpty && !parts.contains(.photos(0)), "\(parts)")
        }
    }
}
