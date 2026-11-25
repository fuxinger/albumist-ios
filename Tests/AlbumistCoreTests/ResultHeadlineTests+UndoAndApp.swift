import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The result's headline of an undo, with nothing to count, and in the App (`ResultHeadlineTests`).
extension ResultHeadlineTests {
    // MARK: Undo

    /// The undo of new albums says it removed them again; the undo of a removal says that what
    /// was removed is back. An undo has no "Rückgängig machen" of its own.
    @Test func anUndoSaysWhatItDid() async throws {
        let library = InMemoryPhotoLibrary(assets: Self.assets)
        let tracker = ManagedAlbumTracker()
        let made = try await Self.make([ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)], in: library)
        let madeInventory = try await library.currentInventory()
        let madeStates = tracker.record(made, into: [], inventory: madeInventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: madeStates, current: madeInventory, earlierUndos: []),
                                      in: library)
        let removedAgain = ResultHeadline(plan: undo, inventory: try await library.currentInventory())
        #expect(removedAgain.kind == .undone)
        #expect(removedAgain.lead == .undone)
        #expect(removedAgain.detail == .undoRemoved)
        #expect(!removedAgain.showsWhereNewAlbumsAre)
        #expect(removedAgain.undoNote == nil)

        // "Entfernen" on another album, then "Rückgängig machen" on that removal.
        let rom = try await Self.make([ConfirmedProposal(proposal: Self.rom, decision: Self.new)], in: library)
        var states = tracker.record(rom, into: [], inventory: try await library.currentInventory())
        let state = try #require(states.first)
        let removal = try await Self.run(tracker.removalPlan(for: state, current: try await library.currentInventory()), in: library)
        let removedInventory = try await library.currentInventory()
        states = tracker.record(removal, into: states, inventory: removedInventory)
        let back = try await Self.run(UndoPlanner().undoPlan(for: removal, albums: states, current: removedInventory, earlierUndos: []),
                                      in: library)
        let after = try await library.currentInventory()
        #expect(after.albums.contains { $0.title == Self.rom.title && Set($0.assetIDs) == ["r1", "r2"] })
        let restored = ResultHeadline(plan: back, inventory: after)
        #expect(restored.kind == .undone)
        #expect(restored.lead == .undone)
        #expect(restored.detail == .undoRestored)
        #expect(restored.undoNote == nil)
    }

    // MARK: Nothing to count

    /// Steps the library never confirmed count nothing: no count at all, never "0 Fotos
    /// einsortiert", and no way to new albums that are not there.
    @Test func nothingConfirmedIsNotCountedAsZero() {
        var plan = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: Self.kyoto, decision: Self.new)],
                                                  inventory: CollectionInventory())
        for index in plan.steps.indices { plan.steps[index].state = .failed(reason: "Fotos hat nicht geantwortet.") }
        let headline = ResultHeadline(plan: plan)
        #expect(headline.kind == .created)
        #expect(headline.lead == .plain)
        #expect(headline.detail == nil)
        #expect(!headline.showsWhereNewAlbumsAre)
    }

    // MARK: The App says it (the App does not build on Linux: its code is read)

    static let view = "App/Albumist/Views/PlanReviewView.swift"

    static func resultCard() throws -> (body: String, file: String) {
        let file = AppSource.code(try AppSource.read(Self.view), keepStrings: true)
        let body = try #require(AppSource.body(of: ["struct ResultCard", "var body: some View"], in: file))
        return (body, file)
    }

    /// The result card counts with the receipt and the headline, not with the summary that said
    /// "0 Fotos einsortiert" after a removal.
    @Test func theResultCardCountsAsTheReceipt() throws {
        let (body, _) = try Self.resultCard()
        #expect(body.contains("ResultHeadline("), "the result card does not use ResultHeadline")
        #expect(body.contains("PlanReceipt(plan:"), "the result card does not count with the receipt")
        for old in ["Counted.resultLine(", "appliedSummary"] {
            #expect(!body.contains(old), "the result card still uses \(old)")
        }
    }

    /// The way to the new albums comes only with new albums: its sentences are in one function,
    /// which says nothing unless the headline says so, and the card's old sentence is gone.
    @Test func theWayToNewAlbumsOnlyWithNewAlbums() throws {
        let (body, file) = try Self.resultCard()
        #expect(!file.contains("Deine neuen Alben findest du"), "the old sentence about new albums is still there")
        let words = try #require(AppSource.body(of: "static func whereNewAlbums(", in: file), "no ResultText.whereNewAlbums")
        #expect(words.contains("showsWhereNewAlbumsAre"), "whereNewAlbums does not ask the headline")
        #expect(words.contains("Sammlungen › Alben"))
        // Every sentence with the way to the albums is in that function.
        let ways = file.components(separatedBy: "Sammlungen › Alben").count - 1
        let inWords = words.components(separatedBy: "Sammlungen › Alben").count - 1
        #expect(ways == inWords, "a sentence about where new albums are outside whereNewAlbums")
        #expect(AppSource.calls(of: "ResultText.whereNewAlbums(", in: body).count == 1)
    }

    /// A removal is called one on the card, and "Rückgängig machen" says what it does for each
    /// kind of plan; its question too.
    @Test func theCardNamesARemovalAndWhatUndoDoes() throws {
        let (body, file) = try Self.resultCard()
        for words in ["Album entfernt", "Alben entfernt", "Fotos herausgenommen", "Die Fotos bleiben in deiner Mediathek.",
                      "Legt die %lld Alben mit denselben Fotos wieder an.", "Legt die herausgenommenen Fotos wieder zurück.",
                      "Entfernt die %lld neuen Alben. Deine Fotos bleiben."] {
            let literal = words.replacingOccurrences(of: "%lld", with: #"\(count)"#)
            #expect(file.contains("\"\(words)\"") || file.contains("\"\(literal)\""), "PlanReviewView.swift does not say \(words)")
        }
        #expect(body.contains("ResultText.undoNote("), "the result card does not say what Rückgängig machen does")
        #expect(body.contains("ResultText.undoQuestion("), "the undo question does not follow the kind of plan")
    }

    /// Draft E3, "nur ergänzt": the card reads "12 Fotos in 3 deiner Alben ergänzt" ("12" big,
    /// "Fotos" below it, the rest in the small line), in German and English, one album as "in
    /// einem deiner Alben".
    @Test func theCardSaysPhotosInTheUsersAlbums() throws {
        let (_, file) = try Self.resultCard()
        let detail = try #require(AppSource.body(of: "static func detail(", in: file))
        #expect(detail.contains(#"case .inYourAlbums(let albums):"#), "\(detail)")
        #expect(detail.contains(#""in \(albums) deiner Alben ergänzt""#), "\(detail)")
        let noun = try #require(AppSource.body(of: "static func noun(", in: file))
        #expect(noun.contains(#"case .addedPhotos(let count): count == 1 ? String(localized: "Foto") : String(localized: "Fotos")"#),
                "\(noun)")
        // Albums Albumist made, or a retry, keep the neutral words (review E, finding 12): the
        // card names them by the records' albums Albumist created.
        #expect(noun.contains(#"case .extendedAlbums(let count): count == 1 ? String(localized: "Album ergänzt") : String(localized: "Alben ergänzt")"#),
                "\(noun)")
        let card = try #require(AppSource.body(of: ["struct ResultCard", "var body: some View"], in: file))
        #expect(card.contains("ResultHeadline(receipt, plan: plan, albumistAlbums: model.albumistAlbums)"), "\(card)")

        let url = AppSource.root.appendingPathComponent("App/Albumist/Resources/Localizable.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try #require((catalog["strings"] as? [String: Any])?["in %lld deiner Alben ergänzt"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        func plural(_ language: String) -> [String: String] {
            let variations = (localizations[language] as? [String: Any])?["variations"] as? [String: Any]
            let forms = variations?["plural"] as? [String: Any] ?? [:]
            return forms.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        #expect(plural("de") == ["one": "in einem deiner Alben ergänzt", "other": "in %lld deiner Alben ergänzt"])
        #expect(plural("en") == ["one": "added to one of your albums", "other": "added to %lld of your albums"])
        let strings = try #require(catalog["strings"] as? [String: Any])
        func english(_ key: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let en = (entry?["localizations"] as? [String: Any])?["en"] as? [String: Any]
            return (en?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(english("Album ergänzt") == "Album extended" && english("Alben ergänzt") == "Albums extended")
    }
}
