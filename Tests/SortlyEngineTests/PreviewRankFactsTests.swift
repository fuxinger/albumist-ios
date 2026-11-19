import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyTestSupport

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
        // The board's text is not read yet: taken for a document that nothing explains, hidden.
        #expect(PreviewRank.ranks(of: facts) == ["card": .sensitive, "board": .sensitive])
        // The text step reads exactly the photos the facts call document-like.
        #expect(ContentAnalysis(isUtility: true).needsTextRecognition(for: board))
        #expect(!ContentAnalysis(labels: [LabelScore("lake", 0.9)]).needsTextRecognition(for: lake))
    }
}

/// Second review of the build 36 fix: a bank card is sensitive also when its number was not
/// read (glare, an angle, the number on the back, one digit misread), and a picture the image
/// analysis took for a document is hidden unless its text explains it as a harmless one. Each
/// case runs through what the pipeline stores (`FactsAssembler`), as on the device.
@Suite("Preview ranks: pictures whose text does not explain them")
struct PreviewRankUnexplainedTests {
    static let date = Date(timeIntervalSince1970: 1_750_000_000)

    /// The facts of one picture: `utility` is what the image analysis said (nil: not analysed
    /// yet), `raw` the text the text step read (nil: not read yet), stored as the pipeline does.
    func facts(_ raw: String?, utility: Bool? = true, screenshot: Bool = false, document: DocumentInfo?? = nil) -> AssetFacts {
        let asset = AssetSnapshot(id: "x", subtypes: screenshot ? .screenshot : [], creationDate: Self.date)
        var texts: [AssetID: TextResult] = [:]
        if let raw {
            var read = TextAnalysis(text: raw, source: .original)
            read.text = TextMinimizer.storable(raw)
            texts["x"] = TextResult(text: read, document: document ?? DocumentAnalyzer().analyze(text: raw))
        }
        let contents: [AssetID: ContentAnalysis] = utility.map { ["x": ContentAnalysis(isUtility: $0)] } ?? [:]
        return FactsAssembler.assemble(assets: [asset], places: [:], contents: contents, texts: texts,
                                       trips: [], frequentPlaces: [], groups: [], inventory: CollectionInventory([]))[0]
    }

    @Test func aBankCardWithoutAReadableNumberIsSensitive() {
        // The number on the back, or not readable: "Visa Debit" and the name.
        #expect(PreviewRank(facts("DKB\nVisa Debit\nMAX MUSTERMANN\nVALID THRU 12/28")) == .sensitive)
        // Glare: one digit misread, so the Luhn check fails and nothing is masked.
        #expect(PreviewRank(facts("DKB\nVisa Debit\n4111 1111 1111 1112\nMAX MUSTERMANN")) == .sensitive)
        // An angle: only twelve digits readable.
        #expect(PreviewRank(facts("DKB\nVisa\n4111 1111 1111\nMAX MUSTERMANN")) == .sensitive)
        // No readable text at all.
        #expect(PreviewRank(facts("")) == .sensitive)
        // A girocard without an IBAN: "girocard" makes it a receipt, the card words sensitive.
        #expect(PreviewRank(facts("Deutsche Kreditbank\ngirocard\nMaestro\nMAX MUSTERMANN")) == .sensitive)
    }

    @Test func idsAndMedicalPapersWithoutADocumentTypeAreSensitive() {
        let passport = "REISEPASS PASSPORT\nName/Surname MUSTERMANN\nVornamen/Given names MAX\nGeburtsdatum/Date of birth 01.01.1980\nStaatsangehörigkeit DEUTSCH"
        let idBack = "IDD<<T220001293<<<<<<<<<<<<<<<\n6408125<2010315D<<<<<<<<<<<<<4\nMUSTERMANN<<ERIKA<<<<<<<<<<<<<"
        let prescription = "Rezept\nPatient: Max Mustermann\nIbuprofen 600 mg\nDr. med. Muster"
        for raw in [passport, idBack, prescription] {
            #expect(PreviewRank(facts(raw)) == .sensitive)
            // As older versions stored them: no document facts and no text.
            #expect(PreviewRank(facts(raw, document: .some(nil))) == .sensitive)
        }
        #expect(PreviewRank(facts("Kontoauszug Nr. 5/2025\nKontostand 1.234,56 EUR\nDKB")) == .sensitive)
    }

    @Test func aDocumentLikePictureWhoseTextIsNotReadYetIsHidden() {
        // The text step has not come to it yet, or its original is only in iCloud.
        #expect(PreviewRank(facts(nil)) == .sensitive)
    }

    @Test func documentsTheirTextExplainsStayDocuments() {
        let letter = "Sehr geehrte Frau Muster,\nanbei die Unterlagen.\nMit freundlichen Grüßen\nHans"
        #expect(PreviewRank(facts(letter)) == .document)
        let ticket = "Fahrkarte\nMünchen Hbf - Zwiesel\nGleis 12, Sitzplatz 45"
        #expect(PreviewRank(facts(ticket)) == .document)
        // A screenshot with text that explains nothing sensitive is a document.
        #expect(PreviewRank(facts("Bestellung versandt, Lieferung morgen", utility: false, screenshot: true)) == .document)
        // A receipt paid by card names the card: when in doubt, hidden.
        #expect(PreviewRank(facts("Kassenbon\nSumme EUR 12,40\nVISA\nMwSt 7%")) == .sensitive)
    }

    @Test func onlyAFinishedImageAnalysisMakesAPhotoKnown() {
        #expect(PreviewRank(facts(nil, utility: nil)) == .unknown)          // not looked at yet
        var failed = ContentAnalysis()
        failed.failedAttempts = 1                                          // could not be read
        let asset = AssetSnapshot(id: "x", creationDate: Self.date)
        let assembled = FactsAssembler.assemble(assets: [asset], places: [:], contents: ["x": failed], texts: [:],
                                                trips: [], frequentPlaces: [], groups: [], inventory: CollectionInventory([]))[0]
        #expect(!assembled.contentKnown && PreviewRank(assembled) == .unknown)
        #expect(facts(nil, utility: false).contentKnown)
    }

    /// Third review: an ID or medical screenshot read by an older version was stored with no
    /// document facts and an empty text; a screenshot whose text is not read yet (or never, with
    /// text reading off) says nothing either. Both are hidden, without reading anything again.
    @Test func aScreenshotWithoutTextOrDocumentFactsIsHidden() {
        let passport = "REISEPASS PASSPORT\nName/Surname MUSTERMANN\nGeburtsdatum/Date of birth 01.01.1980"
        // As the older version stored it: empty text, no document facts.
        #expect(PreviewRank(facts(passport, utility: false, screenshot: true, document: .some(nil))) == .sensitive)
        // Not read yet.
        #expect(PreviewRank(facts(nil, utility: false, screenshot: true)) == .sensitive)
        // Read now: `.other` with its sensitivity, and still an empty text.
        let current = facts(passport, utility: false, screenshot: true)
        #expect(current.document?.type == .other && current.recognizedText == "")
        #expect(PreviewRank(current) == .sensitive)
        // A new-style ID screenshot whose raw text also gave screenshot categories: explained as
        // a screenshot by its categories, hidden by the `.other` facts.
        var flight = current
        flight.textCategories = ["flight"]
        #expect(PreviewRank(flight) == .sensitive)
        // The probe of the third review: an all-screenshot suggestion.
        let date = Self.date
        func shot(_ id: AssetID, _ minutes: Int) -> AssetSnapshot {
            AssetSnapshot(id: id, subtypes: .screenshot, creationDate: date.addingTimeInterval(Double(minutes) * 60))
        }
        let assets = [shot("id", 0), shot("s1", 10), shot("s2", 20), shot("s3", 30)]
        var texts: [AssetID: TextResult] = ["id": TextResult(text: TextAnalysis(text: "", source: .original), document: nil)]
        for id: AssetID in ["s1", "s2", "s3"] {
            texts[id] = TextResult(text: TextAnalysis(text: "Bestellung versandt, Lieferung morgen", source: .original),
                                   document: nil, screenshotCategories: ["order"])
        }
        let all = FactsAssembler.assemble(
            assets: assets, places: [:],
            contents: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, ContentAnalysis(isUtility: true)) }),
            texts: texts, trips: [], frequentPlaces: [], groups: [], inventory: CollectionInventory([]))
        let dates = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.creationDate!) })
        #expect(PreviewPicker.pick(Set(assets.map(\.id)), dates: dates, cover: nil, count: 8, ranks: PreviewRank.ranks(of: all))
                == ["s1", "s2", "s3"])
    }

    @Test func aPictureTheImageAnalysisDidNotTakeForADocumentIsAPhoto() {
        // Its text is never read, so nothing can say it is a card (KNOWN_LIMITATIONS).
        #expect(PreviewRank(facts(nil, utility: false)) == .photo)
    }

    @Test func aSmallSuggestionNoLongerShowsTheCard() {
        func snap(_ id: AssetID, _ hours: Int) -> AssetSnapshot { AssetSnapshot(id: id, creationDate: Self.date.addingTimeInterval(Double(hours) * 3600)) }
        let assets = [snap("p1", 0), snap("p2", 5), snap("p3", 10), snap("card", 7)]
        var read = TextAnalysis(text: "DKB Visa Debit MAX MUSTERMANN", source: .original)
        read.text = TextMinimizer.storable(read.text)
        let facts = FactsAssembler.assemble(
            assets: assets, places: [:],
            contents: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, ContentAnalysis(isUtility: $0.id == "card")) }),
            texts: ["card": TextResult(text: read, document: DocumentAnalyzer().analyze(text: read.text))],
            trips: [], frequentPlaces: [], groups: [], inventory: CollectionInventory([]))
        let ranks = PreviewRank.ranks(of: facts)
        let dates = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.creationDate!) })
        #expect(PreviewPicker.pick(Set(assets.map(\.id)), dates: dates, cover: nil, count: 8, ranks: ranks) == ["p1", "p2", "p3"])
        #expect(PreviewPicker.cover(["card"], preferred: "card", proposal: SortlyID("s"), ranks: ranks) == nil)
    }
}

/// A card or ID reported as `.other` (only to keep it out of previews) counts for the
/// "Dokumente" area exactly like a picture without document facts, as before.
@Suite("Other documents in the sorting status")
struct OtherDocumentStatusTests {
    @Test func anOtherDocumentDoesNotCountAsADocumentToSort() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        func facts(_ id: AssetID, _ document: DocumentInfo?) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: id, creationDate: date), document: document, looksLikeDocument: true, contentKnown: true)
        }
        let all = [
            facts("card", DocumentInfo(type: .other, typeReliability: .uncertain, keywords: [], sensitivity: .financial)),
            facts("plain", nil),
            facts("letter", DocumentInfo(type: .letter, typeReliability: .likely, keywords: [], sensitivity: .normal)),
        ]
        let states = LibraryStatus.compute(facts: all, snapshot: nil, settings: OrganizationSettings(), contentAnalyzed: Set(all.map(\.id)))
        #expect(states["card"]?.areas[.documents] == states["plain"]?.areas[.documents])
        #expect(states["letter"]?.areas[.documents] != states["plain"]?.areas[.documents])
    }
}

/// "Gerade angesehen" on the analysis card shows the last pictures looked at: never a
/// document, receipt or card (second review of the build 36 fix).
@Suite("Analysis card thumbnails")
struct AnalysisRecentThumbnailTests {
    @Test func theRecentThumbnailsLeaveDocumentsOut() async throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let assets = (0..<12).map { i in
            AssetSnapshot(id: AssetID(i.isMultiple(of: 2) ? "doc\(i)" : "photo\(i)"), creationDate: start.addingTimeInterval(Double(i) * 60))
        }
        let analyzer = FakeContentAnalyzer(labels: { $0.id.rawValue.hasPrefix("doc") ? [LabelScore("document", 0.9)] : [] })
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: try SortlyStore(url: nil), reader: InMemoryLibraryReader(assets: assets), analyzer: analyzer,
            geocoder: FakeGeocoder(), map: EmptyLibraryPipelineTests.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source)
        let seen = Mutex<[AssetID]>([])
        _ = try await pipeline.run(onProgress: { progress in seen.withLock { $0 += progress.recent } })
        let recent = seen.withLock { $0 }
        #expect(!recent.isEmpty)
        #expect(recent.allSatisfy { $0.rawValue.hasPrefix("photo") }, "\(recent)")
    }
}
