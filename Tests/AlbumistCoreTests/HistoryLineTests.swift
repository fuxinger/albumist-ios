import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// What a row of the history ("Verlauf und Rückgängig") says a change did (design wave 3, H12):
/// a plan that made or extended albums as always ("25 neu, 236 Fotos"); a removal of albums
/// Albumist made ("Album entfernen") and an undo what they did ("2 entfernt", "12 Fotos
/// herausgenommen", each photo counted once), never "0 Fotos" beside it: they said "0 Fotos" for
/// everything they did. Only a change of nothing says "0 Fotos". The rule is decided here
/// (`HistoryLine`); the app maps each part to a plural string of the catalog
/// (`Counted.historyLine`). The history lists no undo today (it marks the plan it took back); the
/// rule covers it all the same.
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

    static func run(_ plan: ChangePlan, in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        var confirmed = plan
        confirmed.confirmedAt = Date()
        confirmed.status = .confirmed
        return try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed)
    }

    // MARK: Made or extended albums: as always

    /// "1 neu, 1 ergänzt, 5 Fotos": the albums it made, the user's it extended, the different
    /// photos it put into albums; "0 Fotos" too where none came, as before.
    @Test func aPlanThatMadeAlbumsSaysWhatItMadeAsAlways() {
        let made = Self.plan([.createAlbum(key: "rom", title: "Rom", parent: .topLevel),
                              .addAssets(album: .planned("rom"), assets: ["rom-1", "rom-2", "rom-3"]),
                              .addAssets(album: .existing("mine"), assets: ["rom-3", "kyoto-1", "kyoto-2"])])
        #expect(PlanReceipt.Kind(made) == .created)
        #expect(HistoryLine.parts(of: made) == [.created(1), .extended(1), .photos(5)])
        let extended = Self.plan([.addAssets(album: .existing("mine"), assets: ["kyoto-1"])])
        #expect(HistoryLine.parts(of: extended) == [.extended(1), .photos(1)])
        // The album was made, its photos did not come.
        let empty = Self.plan([.createAlbum(key: "rom", title: "Rom", parent: .topLevel),
                               .addAssets(album: .planned("rom"), assets: ["rom-1"])],
                              states: [1: .failed(reason: "Fotos hat nicht geantwortet.")])
        #expect(HistoryLine.parts(of: empty) == [.created(1), .photos(0)])
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
        #expect(HistoryLine.parts(of: failed) == [.photos(0)])
    }

    /// Only a change of nothing says "0 Fotos": an undo or a removal whose steps all failed, or
    /// that had nothing left to do.
    @Test func onlyAChangeOfNothingSaysZeroPhotos() {
        let failed = Self.plan([.removeAssets(album: "a", assets: ["rom-1"])], states: [0: .failed(reason: "x")], reverts: AlbumistID("made"))
        #expect(HistoryLine.parts(of: failed) == [.photos(0)])
        let nothing = Self.plan([], reverts: AlbumistID("made"))
        #expect(HistoryLine.parts(of: nothing) == [.photos(0)])
        // Whatever an undo or a removal did, never "0 Fotos" beside it.
        for parts in [HistoryLine.parts(of: Self.plan([.removeAssets(album: "a", assets: ["rom-1"])], reverts: AlbumistID("made"))),
                      HistoryLine.parts(of: Self.plan([.deleteCollection("a", title: "Rom")], reverts: AlbumistID("made")))] {
            #expect(!parts.contains(.photos(0)), "\(parts)")
        }
    }

    // MARK: In the app

    /// The app only maps each part to its words, a plural of the catalog with the number grouped
    /// ("1.234"), joined with ", " as before; the row shows the line of the plan.
    @Test func theAppMapsThePartsToTheCatalog() throws {
        let counted = AppSource.code(try AppSource.read("App/Albumist/DesignSystem/Counted.swift"), keepStrings: true)
        let body = try #require(AppSource.body(of: "static func historyLine(", in: counted))
        let line = String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        for mapping in ["case.created(letcount):String(localized:\"\\(count)neu\")",
                        "case.extended(letcount):String(localized:\"\\(count)ergänzt\")",
                        "case.photos(letcount):String(localized:\"\\(count)\\(count.formatted())Fotos\")",
                        "case.removed(letcount):String(localized:\"\\(count)\\(count.formatted())entfernt\")",
                        "case.takenOut(letcount):String(localized:\"\\(count)\\(count.formatted())Fotosherausgenommen\")"] {
            #expect(line.contains(mapping), "\(mapping)")
        }
        #expect(line.contains("join(HistoryLine.parts(of:plan).map{partin"), "the app decides the parts itself")
        #expect(line.hasSuffix(",separator:\",\")}"))
        let settings = AppSource.code(try AppSource.read("App/Albumist/Views/SettingsView.swift"), keepStrings: true)
        #expect(settings.contains("Text(Counted.historyLine(plan))"))
        #expect(!settings.contains("historyLine(plan.appliedSummary)"))
    }

    /// The new words, with English and their one and many forms, the number grouped (`%lld %@`:
    /// the integer picks the form, the text shows it).
    @Test(arguments: [("%lld %@ entfernt", "%2$@ entfernt", "%2$@ entfernt", "%2$@ removed", "%2$@ removed"),
                      ("%lld %@ Fotos herausgenommen", "%2$@ Foto herausgenommen", "%2$@ Fotos herausgenommen",
                       "%2$@ photo taken out", "%2$@ photos taken out")])
    func theNewWordsAreInTheCatalog(key: String, germanOne: String, germanOther: String, englishOne: String, englishOther: String) throws {
        let catalog = try StringCatalogTests.catalog()
        let entry = try #require(catalog[key], "\(key) is not in the catalog")
        func plural(_ language: String, _ form: String) -> String? {
            let localization = StringCatalogTests.localization(entry, language)
            let value = (localization?["stringUnit"] as? [String: Any])?["value"] as? String
            let name = value.flatMap { $0.hasPrefix("%#@") && $0.hasSuffix("@") ? String($0.dropFirst(3).dropLast()) : nil }
            let substitution = name.flatMap { (localization?["substitutions"] as? [String: Any])?[$0] as? [String: Any] }
            #expect(substitution?["argNum"] as? Int == 1 && substitution?["formatSpecifier"] as? String == "lld", "\(language)")
            let variations = (substitution?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            return ((variations?[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(plural("de", "one") == germanOne)
        #expect(plural("de", "other") == germanOther)
        #expect(plural("en", "one") == englishOne)
        #expect(plural("en", "other") == englishOther)
    }
}
