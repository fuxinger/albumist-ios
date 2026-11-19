import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Preview photos")
struct PreviewPickerTests {
    let ids: [AssetID] = (0..<40).map { AssetID(String(format: "p%02d", $0)) }
    var dates: [AssetID: Date] {
        // Ids and dates run in opposite directions, so sorting by id would be wrong.
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Date(timeIntervalSince1970: Double(1000 - $0) * 3600)) })
    }

    @Test func spreadsOverTheWholeTimeSpanOldestFirst() {
        let picked = PreviewPicker.pick(Set(ids), dates: dates, cover: nil, count: 8)
        #expect(picked.count == 8)
        #expect(picked.first == "p39") // oldest
        #expect(picked.last == "p00")  // newest
        let times = picked.compactMap { dates[$0] }
        #expect(times == times.sorted())
    }

    @Test func coverIsAlwaysShown() {
        let picked = PreviewPicker.pick(Set(ids), dates: dates, cover: "p17", count: 8)
        #expect(picked.contains("p17"))
        #expect(picked.count == 8)
        #expect(Set(picked).count == 8)
        #expect(picked.compactMap { dates[$0] } == picked.compactMap { dates[$0] }.sorted())
    }

    @Test func smallSetsAndUndatedPhotos() {
        var d = dates
        d["p01"] = nil
        let few = PreviewPicker.pick(["p01", "p02", "p03"], dates: d, cover: nil, count: 8)
        #expect(few == ["p03", "p02", "p01"]) // undated last
        #expect(PreviewPicker.pick(Set(ids), dates: d, cover: nil, count: 1).count == 1)
    }
}

/// Owner's iPhone, build 36: "Häufiger Ort in Zwiesel" showed a photo of a bank card with its
/// number among its eight preview photos. Previews, covers and the glow prefer ordinary photos,
/// take documents and screenshots only for tiles that are left, and never a sensitive document;
/// the suggestion itself keeps every photo.
@Suite("Preview photos: sensitive documents")
struct PreviewSensitiveDocumentTests {
    static let start = Date(timeIntervalSince1970: 1_750_000_000)
    static func day(_ n: Int) -> Date { start.addingTimeInterval(Double(n) * 86_400) }

    func photo(_ id: AssetID, _ day: Int) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: id, creationDate: Self.day(day)), contentKnown: true)
    }
    /// A photographed bank card: the image analysis took it for a utility picture, its text
    /// was read and stored with the card number masked; no document type was recognised.
    func card(_ id: AssetID, _ day: Int) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: id, creationDate: Self.day(day)),
                   recognizedText: TextMinimizer.storable("DKB\nVisa Debit\n4111 1111 1111 1111\nMAX MUSTERMANN"),
                   looksLikeDocument: true, contentKnown: true)
    }
    func screenshot(_ id: AssetID, _ day: Int) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: id, subtypes: .screenshot, creationDate: Self.day(day)), recognizedText: "Bestellung versandt",
                   contentKnown: true)
    }
    func statement(_ id: AssetID, _ day: Int, _ sensitivity: DocumentSensitivity) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: id, creationDate: Self.day(day)),
                   document: DocumentInfo(type: .letter, typeReliability: .likely, keywords: [], sensitivity: sensitivity),
                   contentKnown: true)
    }
    func dates(_ facts: [AssetFacts]) -> [AssetID: Date] {
        Dictionary(uniqueKeysWithValues: facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } })
    }

    @Test func whatTheAnalysisStoredSaysHowAPhotoSuitsAPreview() {
        #expect(PreviewRank(photo("p", 0)) == .photo)
        #expect(PreviewRank(card("card", 0)) == .sensitive)        // the masked card number
        #expect(PreviewRank(statement("iban", 0, .financial)) == .sensitive)
        #expect(PreviewRank(statement("id", 0, .identity)) == .sensitive)
        #expect(PreviewRank(statement("doctor", 0, .medical)) == .sensitive)
        #expect(PreviewRank(statement("letter", 0, .normal)) == .document)
        #expect(PreviewRank(screenshot("shot", 0)) == .document)
        var transfer = photo("transfer", 0)
        transfer.recognizedText = TextMinimizer.storable("Überweisung an DE89 3704 0044 0532 0130 00")
        #expect(PreviewRank(transfer) == .sensitive)               // the masked IBAN
        var whiteboard = photo("board", 0)
        whiteboard.looksLikeDocument = true
        // Taken for a document, but no text explains it (second review): hidden.
        #expect(PreviewRank(whiteboard) == .sensitive)
        whiteboard.document = DocumentInfo(type: .letter, typeReliability: .plausible, keywords: [], sensitivity: .normal)
        #expect(PreviewRank(whiteboard) == .document)
        #expect(PreviewRank(AssetFacts(asset: AssetSnapshot(id: "new"))) == .unknown)   // not analysed yet
        let ranks = PreviewRank.ranks(of: [photo("p", 0), card("card", 1), screenshot("shot", 2)])
        #expect(ranks == ["card": .sensitive, "shot": .document])  // ordinary photos are left out
    }

    /// The bug as it happened: a frequent place whose own cover photo is the bank card.
    @Test func theBankCardIsNeitherCoverNorPreviewOfAFrequentPlace() throws {
        let facts = (0..<12).map { photo(AssetID(String(format: "z%02d", $0)), $0) } + [card("card", 5)]
        let members = Set(facts.map(\.id))
        // A suggestion whose own (stable, per suggestion) cover choice is the card.
        let proposal = try #require((0..<200).lazy.map { i in
            AlbumProposal(id: .stable("frequent", "zwiesel-\(i)"), kind: .frequentPlace, title: "Häufiger Ort in Zwiesel", assetIDs: members)
        }.first { $0.coverAssetID == "card" })
        let ranks = PreviewRank.ranks(of: facts)

        let cover = try #require(PreviewPicker.cover(members, preferred: proposal.coverAssetID, proposal: proposal.id, ranks: ranks))
        #expect(cover != "card")
        #expect(ranks[cover] == nil)
        // The same cover in every run.
        #expect(PreviewPicker.cover(members, preferred: proposal.coverAssetID, proposal: proposal.id, ranks: ranks) == cover)

        let preview = PreviewPicker.pick(members, dates: dates(facts), cover: cover, count: 8, ranks: ranks)
        #expect(preview.count == 8)
        #expect(!preview.contains("card"))
        #expect(preview.contains(cover))
        // The glow behind the photos is the cover's.
        #expect(PreviewPicker.pick(members, dates: dates(facts), cover: cover, count: 1, ranks: ranks) == [cover])
        // The card stays in the suggestion: only what is shown for it changed.
        #expect(proposal.assetIDs.contains("card"))
        #expect(PreviewPicker.chronological(members, dates: dates(facts)).count == 13)
    }

    @Test func coverIsNeverASensitiveDocumentWhileAnotherPhotoExists() {
        let id = SortlyID.stable("test", "cover")
        let ranks: [AssetID: PreviewRank] = ["card": .sensitive, "id": .sensitive, "shot": .document, "receipt": .document]
        // A photo exists: the cover is a photo, also when the suggestion's own cover is a document.
        #expect(PreviewPicker.cover(["card", "shot", "p1"], preferred: "card", proposal: id, ranks: ranks) == "p1")
        #expect(PreviewPicker.cover(["card", "shot", "p1"], preferred: "shot", proposal: id, ranks: ranks) == "p1")
        #expect(PreviewPicker.cover(["card", "shot", "p1", "p2"], preferred: "p2", proposal: id, ranks: ranks) == "p2")
        // Only documents besides the card: a document.
        let document = PreviewPicker.cover(["card", "shot", "receipt"], preferred: "card", proposal: id, ranks: ranks)
        #expect(document == "shot" || document == "receipt")
        #expect(PreviewPicker.cover(["card", "shot", "receipt"], preferred: "receipt", proposal: id, ranks: ranks) == "receipt")
        // Nothing but sensitive documents: no cover at all rather than one of them.
        #expect(PreviewPicker.cover(["card", "id"], preferred: "card", proposal: id, ranks: ranks) == nil)
        // An album's cover is its newest photo that suits one.
        let dates: [AssetID: Date] = ["p1": Self.day(1), "shot": Self.day(2), "card": Self.day(3)]
        #expect(PreviewPicker.newest(["p1", "shot", "card"], dates: dates, ranks: ranks) == "p1")
        #expect(PreviewPicker.newest(["shot", "card"], dates: dates, ranks: ranks) == "shot")
        #expect(PreviewPicker.newest(["card"], dates: dates, ranks: ranks) == nil)
        #expect(PreviewPicker.newest(["p1", "shot", "card"], dates: dates) == "card")   // without ranks as before
    }

    @Test func theGridFillsWithOrdinaryPhotosFirstThenDocumentsNeverSensitiveOnes() {
        // 5 photos, 6 screenshots and 2 sensitive statements, mixed over 13 days.
        let facts: [AssetFacts] = [
            screenshot("s0", 0), photo("p1", 1), statement("x2", 2, .identity), screenshot("s3", 3), photo("p4", 4),
            photo("p5", 5), screenshot("s6", 6), photo("p7", 7), screenshot("s8", 8), screenshot("s9", 9), photo("p10", 10),
            screenshot("s11", 11), statement("x12", 12, .financial),
        ]
        let ranks = PreviewRank.ranks(of: facts)
        let photos = facts.filter { ranks[$0.id] == nil }.map(\.id)
        let sensitive = facts.filter { ranks[$0.id] == .sensitive }.map(\.id)
        #expect(photos.count == 5 && sensitive.count == 2)
        let all = Set(facts.map(\.id))
        let preview = PreviewPicker.pick(all, dates: dates(facts), cover: nil, count: 8, ranks: ranks)
        #expect(preview.count == 8)
        #expect(Set(photos).isSubset(of: Set(preview)))             // every ordinary photo
        #expect(preview.filter { ranks[$0] == .document }.count == 3) // documents only for the rest
        #expect(!preview.contains { sensitive.contains($0) })
        #expect(preview == PreviewPicker.chronological(preview, dates: dates(facts)))  // oldest first
    }

    @Test func tooFewOtherPhotosMeansFewerTilesWithTheSameTotal() {
        let facts = [photo("p1", 1), statement("x2", 2, .financial), photo("p3", 3), card("c4", 4), photo("p5", 5),
                     statement("x6", 6, .medical), card("c7", 7)]
        let ranks = PreviewRank.ranks(of: facts)
        let all = Set(facts.map(\.id))
        let preview = PreviewPicker.pick(all, dates: dates(facts), cover: nil, count: 8, ranks: ranks)
        #expect(preview == ["p1", "p3", "p5"])
        // The count of the suggestion is every photo: the last tile says "+5" (four hidden and
        // the one under the number).
        #expect(PreviewPicker.chronological(all, dates: dates(facts)).count == 7)
        #expect(PreviewPicker.moreCount(total: 7, shown: preview.count) == 5)
        #expect(PreviewPicker.moreCount(total: 3, shown: 3) == nil)
        #expect(PreviewPicker.moreCount(total: 4, shown: 0) == nil)
        // Only sensitive documents: no tile at all.
        #expect(PreviewPicker.pick(["x2", "c4"], dates: dates(facts), cover: nil, count: 8, ranks: ranks).isEmpty)
        // A cover that is a sensitive document is not shown either.
        #expect(!PreviewPicker.pick(all, dates: dates(facts), cover: "c4", count: 2, ranks: ranks).contains("c4"))
    }

    @Test func theOrderStaysDeterministic() {
        let facts = (0..<40).map { photo(AssetID(String(format: "q%02d", $0)), 40 - $0) } + [card("card", 7), screenshot("shot", 9)]
        let ranks = PreviewRank.ranks(of: facts)
        let all = facts.map(\.id)
        let photos = Set(all).subtracting(["card", "shot"])
        let d = dates(facts)
        let picked = PreviewPicker.pick(Set(all), dates: d, cover: "q17", count: 8, ranks: ranks)
        // Exactly what the photos alone gave before ranks existed, whatever order the ids come in.
        #expect(picked == PreviewPicker.pick(photos, dates: d, cover: "q17", count: 8))
        #expect(picked == PreviewPicker.pick(all.reversed(), dates: d, cover: "q17", count: 8, ranks: ranks))
        #expect(picked == PreviewPicker.pick(all.shuffled(), dates: d, cover: "q17", count: 8, ranks: ranks))
        // Ranks of other photos change nothing.
        #expect(PreviewPicker.pick(photos, dates: d, cover: nil, count: 8, ranks: ["elsewhere": .sensitive])
                == PreviewPicker.pick(photos, dates: d, cover: nil, count: 8))
    }

    @Test func listsTakeTheirFirstPhotoThatSuitsAndTheMosaicSkipsDocuments() {
        let ranks: [AssetID: PreviewRank] = ["card": .sensitive, "shot": .document, "receipt": .document]
        #expect(PreviewPicker.firstSuited(["card", "shot", "a", "b"], count: 1, ranks: ranks) == ["a"])
        #expect(PreviewPicker.firstSuited(["card", "shot", "receipt"], count: 1, ranks: ranks) == ["shot"])
        #expect(PreviewPicker.firstSuited(["card"], count: 1, ranks: ranks).isEmpty)
        #expect(PreviewPicker.firstSuited(["shot", "a", "card", "b", "receipt"], count: 3, ranks: ranks) == ["a", "b", "shot"])
        #expect(PreviewPicker.firstSuited(["x", "y"], count: 1, ranks: [:]) == ["x"])
        // The scan show's mosaic: evenly over the library, a photo from every stretch.
        let library: [AssetID] = (0..<30).map { AssetID("m\($0)") }
        let unranked = PreviewPicker.evenly(library, count: 6, ranks: [:]) { $0 }
        #expect(unranked == (0..<6).map { library[$0 * 29 / 5] })   // exactly as before
        let mosaicRanks = Dictionary(uniqueKeysWithValues: unranked.map { ($0, PreviewRank.sensitive) })
        let mosaic = PreviewPicker.evenly(library, count: 6, ranks: mosaicRanks) { $0 }
        #expect(mosaic.count == 6)
        #expect(!mosaic.contains { mosaicRanks[$0] != nil })
        #expect(PreviewPicker.evenly(["card", "a"], count: 6, ranks: ranks) { $0 } == ["a"])
    }

    @Test func plannedAlbumsAndTheSortingShowLeaveSensitiveDocumentsOut() throws {
        let planner = OrganizationPlanner(rootFolderTitle: "Albumist", chunkSize: 5)
        let zwiesel = AlbumProposal(id: SortlyID("z"), kind: .frequentPlace, title: "Zwiesel", assetIDs: ["a-0", "a-1", "a-2", "a-3"])
        let plan = planner.makePlan(from: [ConfirmedProposal(proposal: zwiesel, decision: .createNew(title: nil, folderPath: nil))],
                                    inventory: CollectionInventory([]))
        let filled = try #require(plan.filledAlbums(inventory: CollectionInventory([])).first)
        let first = try #require(filled.assets.first)
        let ranks: [AssetID: PreviewRank] = [first: .sensitive]
        let facts = PlanReviewFacts(plan: plan, inventory: CollectionInventory([]), ranks: ranks)
        let cover = try #require(facts.albums.first?.coverAssetID)
        #expect(cover != first)
        let show = try #require(facts.filledAlbums.first)
        #expect(show.assets.count == 4)          // every photo is counted …
        #expect(!show.shown.contains(first))     // … but the card does not fly
        #expect(show.shown.count == 3)
        // Without ranks as before.
        #expect(plan.albumPreview(inventory: CollectionInventory([])).first?.coverAssetID == first)
        #expect(filled.shown == filled.assets)
    }

    @Test func theReceiptsCoverIsNoSensitiveDocument() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["a", "b", "c"])
        let zwiesel = AlbumProposal(id: SortlyID("z"), kind: .frequentPlace, title: "Zwiesel", folderPath: [], assetIDs: ["a", "b", "c"])
        var plan = OrganizationPlanner(rootFolderTitle: "Albumist").makePlan(
            from: [ConfirmedProposal(proposal: zwiesel, decision: .createNew(title: nil, folderPath: nil))],
            inventory: try await lib.currentInventory())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let inventory = try await lib.currentInventory()
        let plain = try #require(PlanReceipt(plan: result, inventory: inventory).albums.first?.coverAssetID)
        let ranks: [AssetID: PreviewRank] = [plain: .sensitive]
        let album = try #require(PlanReceipt(plan: result, inventory: inventory, ranks: ranks).albums.first)
        let cover = try #require(album.coverAssetID)
        #expect(cover != plain)
        #expect(album.added == 3)                // the receipt still counts every photo
        // Only sensitive documents: the receipt shows its placeholder instead.
        let none = PlanReceipt(plan: result, inventory: inventory, ranks: ["a": .sensitive, "b": .sensitive, "c": .sensitive])
        #expect(none.albums.first?.coverAssetID == nil)
    }

    @Test func theAtlasShareCardAndTheCountryGlowShowNoDocument() {
        let rome = PlaceComponents(isoCountryCode: "IT", country: "Italien", locality: "Rom")
        func trip(_ id: AssetID, _ day: Int, pixels: Int) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: id, creationDate: Self.day(day), pixelWidth: pixels, pixelHeight: pixels),
                       place: rome, placeSource: .gpsReverseGeocoded, tripID: SortlyID("rom"), contentKnown: true)
        }
        var bigCard = trip("card", 3, pixels: 8000)  // the largest picture of the trip
        bigCard.recognizedText = TextMinimizer.storable("Visa 4111 1111 1111 1111")
        bigCard.looksLikeDocument = true
        var ticket = trip("ticket", 4, pixels: 6000)
        ticket.looksLikeDocument = true
        ticket.document = DocumentInfo(type: .ticket, typeReliability: .likely, keywords: [], sensitivity: .normal)
        let facts = [trip("r1", 1, pixels: 3000), trip("r2", 2, pixels: 4000), bigCard, ticket]
        #expect(TravelAtlas.compute(facts: facts, minimumPhotosPerCountry: 1).favoriteTripCover == "r2")
        #expect(TravelAtlas.compute(facts: [bigCard, ticket], minimumPhotosPerCountry: 1).favoriteTripCover == nil)
        // The country's glow: its newest photo that suits a cover.
        #expect(CountryPhotos.collect(countryCode: "IT", facts: facts).cover == "r2")
        #expect(CountryPhotos.collect(countryCode: "IT", facts: [trip("r1", 1, pixels: 1), ticket]).cover == "r1")
        #expect(CountryPhotos.collect(countryCode: "IT", facts: [bigCard, ticket]).cover == "ticket")
        #expect(CountryPhotos.collect(countryCode: "IT", facts: [bigCard]).cover == nil)
    }
}

/// Second review of the build 36 fix: what the text step makes of a card, an ID or a medical
/// paper that names no document type, and that previews and covers stay the same from launch
/// to launch.
@Suite("Preview photos: second review")
struct PreviewSecondReviewTests {
    @Test func aCardOrIDWithoutADocumentTypeIsAnOtherSensitiveDocument() throws {
        let analyzer = DocumentAnalyzer()
        let card = try #require(analyzer.analyze(text: "DKB\nVisa Debit\nMAX MUSTERMANN\nVALID THRU 12/28"))
        #expect(card.type == .other && card.sensitivity == .financial)
        let passport = try #require(analyzer.analyze(text: "REISEPASS PASSPORT\nName/Surname MUSTERMANN\nGeburtsdatum/Date of birth 01.01.1980"))
        #expect(passport.type == .other && passport.sensitivity == .identity)
        // Nothing more is kept of them than the kind: no subject, sender, number or amount.
        #expect(card.subject == nil && card.merchant == nil && card.totalAmount == nil && card.keywords.isEmpty)
        // Never an album of their own: "Sonstige Dokumente" is never suggested, and the type is uncertain.
        #expect(card.typeReliability == .uncertain)
        // A plain text without document or card words is still no document.
        #expect(analyzer.analyze(text: "Schöner Sonnenuntergang am Großen Arber") == nil)
        // A receipt paid by girocard stays a receipt of normal sensitivity (its album is unchanged).
        let receipt = try #require(analyzer.analyze(text: "Kassenbon\nSumme EUR 12,40\ngirocard\nMwSt 7%"))
        #expect(receipt.type == .receipt && receipt.sensitivity == .normal)
        // What is stored of the text does not change: masked as before.
        #expect(TextMinimizer.storable("DKB Visa Debit 4111 1111 1111 1111") == "DKB Visa Debit •••• ••••")
    }

    @Test func equalDatesGiveTheSamePreviewWhateverTheOrder() {
        // Twenty photos in bursts of four with the very same second, plus a document and a card.
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        var dates: [AssetID: Date] = [:]
        for i in 0..<20 { dates[AssetID(String(format: "b%02d", i))] = base.addingTimeInterval(Double(i / 4) * 3600) }
        dates["doc"] = base.addingTimeInterval(3600)
        dates["card"] = base.addingTimeInterval(7200)
        let ranks: [AssetID: PreviewRank] = ["doc": .document, "card": .sensitive]
        let ids = Array(dates.keys)
        let first = PreviewPicker.pick(ids.sorted(), dates: dates, cover: nil, count: 8, ranks: ranks)
        #expect(first.count == 8 && !first.contains("card") && !first.contains("doc"))
        for _ in 0..<20 {
            #expect(PreviewPicker.pick(ids.shuffled(), dates: dates, cover: nil, count: 8, ranks: ranks) == first)
            #expect(PreviewPicker.pick(Set(ids.shuffled()), dates: dates, cover: nil, count: 3, ranks: ranks)
                    == PreviewPicker.pick(ids.sorted(), dates: dates, cover: nil, count: 3, ranks: ranks))
            #expect(PreviewPicker.firstSuited(PreviewPicker.chronological(ids.shuffled(), dates: dates), count: 2, ranks: ranks)
                    == ["b00", "b01"])
            #expect(PreviewPicker.newest(ids.shuffled(), dates: dates, ranks: ranks) == "b16")   // equal dates: the smallest id, as `newest` says
        }
    }

    /// The cover is the same in every launch, not only within one: Swift's sets iterate in
    /// another order in every process, so the choice must not depend on it.
    @Test func theCoverOfAFixedSuggestionIsPinned() {
        let members = Set((0..<12).map { AssetID(String(format: "z%02d", $0)) } + ["card", "shot"])
        let ranks: [AssetID: PreviewRank] = ["card": .sensitive, "shot": .document]
        let id = SortlyID.stable("frequent", "zwiesel")
        #expect(PreviewPicker.cover(members, preferred: "card", proposal: id, ranks: ranks) == "z05")
        #expect(PreviewPicker.cover(members, preferred: "shot", proposal: id, ranks: ranks) == "z05")
        #expect(PreviewPicker.cover(["card", "shot", "receipt"], preferred: "card", proposal: id,
                                    ranks: ["card": .sensitive, "shot": .document, "receipt": .document]) == "receipt")
    }

    @Test func analysedPhotosWinOverPhotosNotAnalysedYet() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let ids: [AssetID] = (0..<10).map { AssetID("u\($0)") } + ["p1", "p2", "doc"]
        var dates: [AssetID: Date] = [:]
        for (i, id) in ids.enumerated() { dates[id] = base.addingTimeInterval(Double(i) * 3600) }
        var ranks = Dictionary(uniqueKeysWithValues: (0..<10).map { (AssetID("u\($0)"), PreviewRank.unknown) })
        ranks["doc"] = .document
        let proposal = SortlyID("s")
        // Both analysed photos first, unknown ones for the rest, the document last of all.
        let preview = PreviewPicker.pick(ids, dates: dates, cover: nil, count: 4, ranks: ranks)
        #expect(preview.count == 4 && preview.contains("p1") && preview.contains("p2") && !preview.contains("doc"))
        #expect(preview == PreviewPicker.chronological(preview, dates: dates))
        #expect(PreviewPicker.pick(["u1", "doc", "u2"], dates: dates, cover: nil, count: 2, ranks: ranks) == ["u1", "u2"])
        // The cover: an analysed photo, also when the suggestion's own is not analysed yet.
        let cover = PreviewPicker.cover(Set(ids), preferred: "u3", proposal: proposal, ranks: ranks)
        #expect(cover == "p1" || cover == "p2")
        // Nothing analysed yet: the suggestion's own cover.
        #expect(PreviewPicker.cover(Set(ids.prefix(10)), preferred: "u3", proposal: proposal, ranks: ranks) == "u3")
        #expect(PreviewPicker.cover(["u1", "doc"], preferred: "doc", proposal: proposal, ranks: ranks) == "u1")
        #expect(PreviewPicker.newest(ids, dates: dates, ranks: ranks) == "p2")
        #expect(PreviewPicker.firstSuited(ids, count: 3, ranks: ranks) == ["p1", "p2", "u0"])
        #expect(PreviewPicker.firstSuited(["doc", "u5"], count: 1, ranks: ranks) == ["u5"])
        // The mosaic: from each stretch an analysed photo where it has one.
        let library: [AssetID] = (0..<60).map { AssetID("m\($0)") }
        var mosaicRanks = Dictionary(uniqueKeysWithValues: library.map { ($0, PreviewRank.unknown) })
        for i in [5, 35, 55] { mosaicRanks[library[i]] = nil }   // three analysed photos
        mosaicRanks[library[0]] = .document
        let mosaic = PreviewPicker.evenly(library, count: 3, ranks: mosaicRanks) { $0 }
        #expect(mosaic == ["m5", "m35", "m55"])
    }

    @Test func theSharedAtlasImageUsesOnlyAnalysedPhotos() {
        let rome = PlaceComponents(isoCountryCode: "IT", country: "Italien", locality: "Rom")
        func trip(_ id: AssetID, pixels: Int, analysed: Bool) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: id, creationDate: Date(timeIntervalSince1970: 1_750_000_000), pixelWidth: pixels, pixelHeight: pixels),
                       place: rome, placeSource: .gpsReverseGeocoded, tripID: SortlyID("rom"), contentKnown: analysed)
        }
        // The largest picture is not analysed yet: it could be the card.
        let facts = [trip("small", pixels: 1000, analysed: true), trip("big", pixels: 8000, analysed: false)]
        #expect(TravelAtlas.compute(facts: facts, minimumPhotosPerCountry: 1).favoriteTripCover == "small")
        #expect(TravelAtlas.compute(facts: [facts[1]], minimumPhotosPerCountry: 1).favoriteTripCover == nil)
    }

    @Test func storedTextsThatShowACardOrAStatement() {
        for text in ["IBAN ••••", "Visa Debit", "DKB girocard", "BIC: BYLADEM1001", "Kontostand 12,00 EUR", "VALID THRU 12/28",
                     "Kreditkartenabrechnung", "4111 •••• ••••"] {
            #expect(TextMinimizer.looksSensitive(text), "\(text)")
        }
        for text in ["", "Arabic script on a cubic stone", "Bicycle tour", "Urlaub im Libanon", "Revisaa", "Bestellung versandt"] {
            #expect(!TextMinimizer.looksSensitive(text), "\(text)")
        }
        // Worked out with the text, also when the text changes afterwards.
        var facts = AssetFacts(asset: AssetSnapshot(id: "x"), recognizedText: "Bestellung versandt", contentKnown: true)
        #expect(!facts.textLooksSensitive)
        facts.recognizedText = "Visa Debit"
        #expect(facts.textLooksSensitive && PreviewRank(facts) == .sensitive)
    }

    /// `.other` only keeps a picture out of previews: the search does not find a card or an ID
    /// as a document (it did not before either).
    @Test func anOtherDocumentIsNoDocumentForTheSearch() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let card = AssetFacts(asset: AssetSnapshot(id: "card", creationDate: now),
                              document: DocumentInfo(type: .other, typeReliability: .uncertain, keywords: [], sensitivity: .financial),
                              contentKnown: true)
        let letter = AssetFacts(asset: AssetSnapshot(id: "letter", creationDate: now),
                                document: DocumentInfo(type: .letter, typeReliability: .likely, keywords: [], sensitivity: .normal),
                                contentKnown: true)
        let hits = SearchIndex(facts: [card, letter], calendar: Fixture.calendar).search("Dokumente", now: now).ids
        #expect(Set(hits) == ["letter"])
    }

    /// Third review: card words across a line break or several spaces, more card words, and
    /// short words next to punctuation, symbols or a non-breaking space.
    @Test func cardWordsAcrossSpacesAndNextToPunctuation() {
        for text in ["VALID\nTHRU 12/28", "VALID  THRU 12/28", "GOOD THRU 12/28", "Card No. 1234", "Kartennr. 1234", "V PAY",
                     "UnionPay", "Diners Club International",
                     "„VISA“", "VISA®", "©VISA", "VISA–Karte", "»IBAN«", "BIC\u{00A0}BYLADEM1001", "💳VISA",
                     "VALID\u{00A0}THRU 12/28",
                     // Upper-case umlauts are lowered too: a driving licence prints them so.
                     "FÜHRERSCHEIN Klasse B", "NATIONALITÄT DEUTSCH"] {
            #expect(TextMinimizer.looksSensitive(text), "\(text)")
        }
        for text in ["Card not accepted", "Revisaa", "Visage", "Bicycle tour"] {
            #expect(!TextMinimizer.looksSensitive(text), "\(text)")
        }
    }

    /// Fourth review: the other spaces Vision and apps print (thin, narrow no-break, ideographic),
    /// CJK punctuation as a word boundary, and fullwidth letters ("ＶＩＳＡ") as plain ones.
    @Test func cardWordsAcrossUnicodeSpacesAndInFullwidthLetters() {
        for text in ["VALID\u{2009}THRU 12/28", "VALID\u{2000}THRU", "VALID\u{200A}THRU", "VALID\u{202F}THRU",
                     "VALID\u{3000}THRU", "VALID \u{2009} THRU", "Credit\u{202F}Card",
                     "「VISA」", "、VISA。", "BIC\u{3002}BYLADEM1001", "〔IBAN〕",
                     "ＶＩＳＡ", "ｖｉｓａ", "Ｖｉｓａ Ｄｅｂｉｔ", "ＩＢＡＮ ＤＥ", "ＶＡＬＩＤ ＴＨＲＵ", "「ＶＩＳＡ」"] {
            #expect(TextMinimizer.looksSensitive(text), "\(text)")
        }
        // Fullwidth letters are letters: no card word inside a longer word, as with ASCII ones.
        for text in ["ＶＩＳＡＧＥ", "ＲｅｖｉｓａＡ", "ＸＶＩＳＡ", "Ｂｉｃｙｃｌｅ"] {
            #expect(!TextMinimizer.looksSensitive(text), "\(text)")
        }
        // Japanese letters right next to a word still count as letters.
        #expect(!TextMinimizer.looksSensitive("あvisaい"))
    }

    /// Third review: "bic" inside "Arabic" or "cubic" made a plain text an `.other` document.
    @Test func aPlainTextWithAShortWordInsideALongerOneIsNoDocument() {
        #expect(DocumentAnalyzer().analyze(text: "Arabic script on a cubic stone in the old town") == nil)
        #expect(DocumentAnalyzer().analyze(text: "BIC BYLADEM1001 for the transfer, please") != nil)
    }

    @Test func theMosaicLooksAtNoMoreThanItsLimitPerStretch() {
        // 600 pictures not analysed yet, one analysed photo deep in the first stretch.
        let library: [AssetID] = (0..<600).map { AssetID(String(format: "m%03d", $0)) }
        var ranks = Dictionary(uniqueKeysWithValues: library.map { ($0, PreviewRank.unknown) })
        ranks["m300"] = nil
        #expect(PreviewPicker.evenly(library, count: 2, ranks: ranks) { $0 } == ["m000", "m599"])
        // Within the limit the analysed photo wins.
        ranks["m300"] = .unknown
        ranks["m200"] = nil
        #expect(PreviewPicker.evenly(library, count: 2, ranks: ranks) { $0 } == ["m200", "m599"])
    }

    @Test func theMosaicTakesAPhotoNotAnalysedYetBeforeADocument() {
        let ranks: [AssetID: PreviewRank] = ["d": .document, "u": .unknown, "v": .unknown]
        #expect(PreviewPicker.evenly(["d", "u", "v"], count: 1, ranks: ranks) { $0 } == ["u"])
    }
}
