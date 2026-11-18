import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore

/// What the pipeline stores is enough to keep a photographed bank card out of a suggestion's
/// preview (owner's iPhone, build 36): the image analysis's utility flag reaches the facts, and
/// so does the stored text with the card number masked.
@Suite("Preview ranks from stored results")
struct PreviewRankFactsTests {
    @Test func storedResultsSayWhichPhotosSuitAPreview() {
        let card = AssetSnapshot(id: "card", creationDate: Date(timeIntervalSince1970: 1_750_000_000))
        let board = AssetSnapshot(id: "board", creationDate: Date(timeIntervalSince1970: 1_750_000_100))
        let lake = AssetSnapshot(id: "lake", creationDate: Date(timeIntervalSince1970: 1_750_000_200))
        let raw = "DKB\nVisa Debit\n4111 1111 1111 1111\nMAX MUSTERMANN"
        var read = TextAnalysis(text: raw, source: .original)
        read.text = TextMinimizer.storable(raw)
        let facts = FactsAssembler.assemble(
            assets: [card, board, lake], places: [:],
            contents: ["card": ContentAnalysis(isUtility: true), "board": ContentAnalysis(isUtility: true),
                       "lake": ContentAnalysis(labels: [LabelScore("lake", 0.9)], isUtility: false)],
            texts: ["card": TextResult(text: read, document: DocumentAnalyzer().analyze(text: raw))],
            trips: [], frequentPlaces: [], groups: [], inventory: CollectionInventory([]))
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        #expect(byID["card"]?.looksLikeDocument == true)
        #expect(byID["board"]?.looksLikeDocument == true)
        #expect(byID["lake"]?.looksLikeDocument == false)
        #expect(byID["card"]?.recognizedText?.contains("4111") == false)
        #expect(PreviewRank.ranks(of: facts) == ["card": .sensitive, "board": .document])
        // The text step reads exactly the photos the facts call document-like.
        #expect(ContentAnalysis(isUtility: true).needsTextRecognition(for: board))
        #expect(!ContentAnalysis(labels: [LabelScore("lake", 0.9)]).needsTextRecognition(for: lake))
    }
}
