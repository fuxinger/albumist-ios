import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Design wave 3, DS-13: the search without input offers starting points with photos, as Photos
/// does in spirit: the user's places, a trip, a year, a topic and a kind such as screenshots,
/// each with a real photo of its own from the device. Every starting point is a chip the search
/// knows today (a tap searches its words); a place is a town as Photos names a photo's place;
/// its picture is never a sensitive one, a screenshot or a paper, and never one another tile
/// tries: a kind of nothing but screenshots and papers shows its symbol on the calm placeholder.
@Suite("Search starting points with photos")
struct SearchStartingPointsTests {
    static let now = Fixture.date("2026-11-15 12:00")

    static let munich = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern",
                                        subAdministrativeArea: "Oberbayern", locality: "München", subLocality: "Altstadt-Lehel")
    static let garmisch = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern",
                                          subAdministrativeArea: "Oberbayern", locality: "Garmisch-Partenkirchen")
    static let rome = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom")
    static let florence = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Toskana", locality: "Florenz")

    /// A library as the analysis left it: places from GPS, categories, trips, documents.
    struct Library {
        var facts: [AssetFacts] = []

        @discardableResult
        mutating func add(_ date: String, _ place: PlaceComponents? = nil, kind: MediaKind = .image, subtypes: MediaSubtypes = [],
                          categories: [String: Reliability] = [:], trip: String? = nil, favorite: Bool = false,
                          analysed: Bool = true, text: String? = nil, textCategories: Set<String> = [],
                          document: DocumentInfo? = nil, looksLikeDocument: Bool = false) -> AssetID {
            let id = AssetID(String(format: "start-%04d", facts.count + 1))
            let asset = AssetSnapshot(id: id, kind: kind, subtypes: subtypes, creationDate: Fixture.date(date),
                                      pixelWidth: 4032, pixelHeight: 3024, isFavorite: favorite)
            var f = AssetFacts(asset: asset, categories: categories, textCategories: textCategories, document: document,
                               recognizedText: text, looksLikeDocument: looksLikeDocument, contentKnown: analysed)
            if let place {
                f.place = place
                f.placeSource = .gpsReverseGeocoded
            }
            f.tripID = trip.map { AlbumistID($0) }
            facts.append(f)
            return id
        }

        var index: SearchIndex { SearchIndex(facts: facts, calendar: Fixture.calendar) }
        var ranks: [AssetID: PreviewRank] { PreviewRank.ranks(of: facts) }
        var dates: [AssetID: Date] {
            Dictionary(uniqueKeysWithValues: facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } })
        }

        func starts(english: Bool = false, limit: Int = SearchStartingPoints.limit) -> [SearchStartingPoint] {
            SearchStartingPoints.make(index: index, facts: facts, ranks: ranks, dates: dates, english: english,
                                      now: SearchStartingPointsTests.now, limit: limit)
        }
    }

    static func invoice(sensitivity: DocumentSensitivity = .normal) -> DocumentInfo {
        DocumentInfo(type: .invoice, typeReliability: .likely, documentDate: nil, merchant: nil, orderNumber: nil,
                     invoiceNumber: "R-1", totalAmount: nil, subject: nil, keywords: [], sensitivity: sensitivity)
    }

    /// Two years of life at home, a few trips, mountains, videos, screenshots and papers, a
    /// bank card among the photos (the newest one at home, even a favourite), and Live Photos
    /// and HDR on most photos, as on a current iPhone.
    struct Large {
        var library = Library()
        var romeFavourite: AssetID!
        var bankCard: AssetID!
        var sensitiveScreenshot: AssetID!
        var sureMountains: [AssetID] = []
        var newestHarmlessScreenshot: AssetID!

        init() {
            // München: every 17 days from January 2025, Live Photos, every other one HDR.
            var day = Fixture.date("2025-01-03")
            var n = 0
            while day < Fixture.date("2026-11-01") {
                let stamp = Self.format(day) + " 12:00"
                library.add(stamp, SearchStartingPointsTests.munich, subtypes: n % 2 == 0 ? [.livePhoto, .hdr] : [.livePhoto])
                day = Fixture.calendar.date(byAdding: .day, value: 17, to: day)!
                n += 1
            }
            bankCard = library.add("2026-11-10 09:00", SearchStartingPointsTests.munich, favorite: true, looksLikeDocument: true)
            // Garmisch: mountains, four the classifier is sure about (older), ten it finds plausible (newer).
            for d in 1...4 {
                sureMountains.append(library.add("2025-08-0\(d) 10:00", SearchStartingPointsTests.garmisch, subtypes: [.livePhoto],
                                                 categories: ["nature.mountain": .likely]))
            }
            for d in 10...19 {
                library.add("2025-08-\(d) 10:00", SearchStartingPointsTests.garmisch, subtypes: [.livePhoto],
                            categories: ["nature.mountain": .plausible])
            }
            // Rom, May 2024: a trip of 15 photos, one an older favourite.
            for d in 10...24 {
                let id = library.add("2024-05-\(d) 11:00", SearchStartingPointsTests.rome, subtypes: [.livePhoto], trip: "trip-rome",
                                     favorite: d == 12)
                if d == 12 { romeFavourite = id }
            }
            // Florenz, September 2023: a trip of 6 photos.
            for d in 1...6 {
                library.add("2023-09-0\(d) 11:00", SearchStartingPointsTests.florence, trip: "trip-florence")
            }
            // Videos without a place.
            for d in 1...5 { library.add("2026-02-0\(d) 18:00", kind: .video) }
            // Screenshots the text explains (orders), and the newest one a bank statement.
            for d in 1...8 {
                let id = library.add("2026-10-0\(d) 20:00", subtypes: [.screenshot], text: "Bestellung Nr. 4711", textCategories: ["order"])
                newestHarmlessScreenshot = id
            }
            sensitiveScreenshot = library.add("2026-10-20 20:00", subtypes: [.screenshot], text: "Kontoauszug",
                                              document: SearchStartingPointsTests.invoice(sensitivity: .financial))
            // Invoices photographed: harmless papers, but papers.
            for d in 1...3 {
                library.add("2026-03-0\(d) 09:00", text: "Rechnung R-1", document: SearchStartingPointsTests.invoice(), looksLikeDocument: true)
            }
        }

        static func format(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Fixture.utc
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }
    }

    static let large = Large()

    // MARK: Which starting points

    @Test func anEmptyLibraryOffersNone() {
        let library = Library()
        #expect(library.starts().isEmpty)
        #expect(library.starts(english: true).isEmpty)
    }

    @Test func aLargeLibraryOffersPlacesATripTheNewestYearATopicAndAKind() {
        let starts = Self.large.library.starts()
        #expect(starts.map(\.suggestion.label) == ["München", "Rom", "Reisen", "2026", "Berge", "Screenshots"])
        #expect(starts.map(\.suggestion.kind) == [.place, .place, .trip, .year, .category, .mediaType])
        // The search runs the words of the chip: the completion is the label.
        #expect(starts.allSatisfy { $0.suggestion.completion == $0.suggestion.label })
    }

    @Test func inEnglishTheWordsAreEnglishAndFindTheSamePhotos() {
        let index = Self.large.library.index
        let german = Self.large.library.starts()
        let english = Self.large.library.starts(english: true)
        #expect(english.map(\.suggestion.label) == ["München", "Rom", "Trips", "2026", "Mountains", "Screenshots"])
        for (de, en) in zip(german, english) {
            let a = index.search(de.suggestion.completion, now: Self.now), b = index.search(en.suggestion.completion, now: Self.now)
            #expect(Set(a.ids) == Set(b.ids), "\(de.suggestion.label) / \(en.suggestion.label)")
            #expect(de.coverIDs == en.coverIDs, "\(de.suggestion.label): another picture in English")
        }
    }

    /// Places as Photos names a photo's place: the towns with the most photos, never the
    /// region or district that holds them all ("Bayern", "Oberbayern").
    @Test func placesAreTheTownsWithTheMostPhotos() {
        let places = Self.large.library.starts().filter { $0.suggestion.kind == .place }.map(\.suggestion.label)
        #expect(places == ["München", "Rom"])
        let regions: Set<String> = ["Bayern", "Oberbayern", "Altstadt-Lehel", "Latium", "Deutschland", "Italien"]
        #expect(Self.large.library.starts(limit: 20).allSatisfy { !regions.contains($0.suggestion.label) })
        // With room for more, the next town follows the first two.
        let more = Self.large.library.starts(limit: 20).filter { $0.suggestion.kind == .place }.map(\.suggestion.label)
        #expect(more.prefix(3) == ["München", "Rom", "Garmisch-Partenkirchen"])
    }

    /// A tap runs the chip's search: every word understood, the count is the search's, and the
    /// picture is one of the photos it finds.
    @Test(arguments: [false, true])
    func eachStartingPointIsTheSearchOfItsWords(english: Bool) {
        let index = Self.large.library.index
        let ranks = Self.large.library.ranks
        for start in Self.large.library.starts(english: english) {
            let found = index.search(start.suggestion.completion, now: Self.now)
            #expect(!found.tokens.contains { $0.kind == .ignored }, "\(start.suggestion.label): a word not understood")
            #expect(!found.isRelaxed)
            #expect(start.suggestion.count == found.ids.count, "\(start.suggestion.label)")
            // A picture, except for a kind of nothing but screenshots and papers (its symbol).
            let hasPhotos = found.ids.contains { (ranks[$0] ?? .photo) <= .unknown }
            #expect(start.coverIDs.isEmpty == (start.suggestion.kind == .mediaType && !hasPhotos),
                    "\(start.suggestion.label): a picture where there should be none, or none where there should be one")
            #expect(start.coverIDs.allSatisfy(Set(found.ids).contains), "\(start.suggestion.label): a picture it does not find")
            #expect(start.coverIDs.count <= 4)
        }
    }

    /// Live Photos and HDR say how the camera took a photo and hold most photos of a current
    /// iPhone; papers are personal: none of them is a starting point.
    @Test func neitherLivePhotosNorHDRNorPapersAreStartingPoints() {
        let labels = Self.large.library.starts(limit: 20).map(\.suggestion.label)
        #expect(!labels.contains("Live Photos"))
        #expect(!labels.contains("HDR"))
        #expect(!Self.large.library.starts(limit: 20).contains { $0.suggestion.kind == .document })
        #expect(!labels.contains("Rechnungen"))
        // The kinds that are there still follow, most photos first.
        #expect(labels.filter { ["Screenshots", "Videos"].contains($0) } == ["Screenshots", "Videos"])
    }

    @Test func atMostTheLimit() {
        #expect(Self.large.library.starts().count == SearchStartingPoints.limit)
        #expect(SearchStartingPoints.limit == 6)
        #expect(Self.large.library.starts(limit: 3).map(\.suggestion.label) == ["München", "Rom", "Reisen"])
        #expect(Self.large.library.starts(limit: 0).isEmpty)
    }

    // MARK: Which photo

    @Test func neverASensitivePicture() {
        let ranks = Self.large.library.ranks
        #expect(ranks[Self.large.bankCard] == .sensitive)
        #expect(ranks[Self.large.sensitiveScreenshot] == .sensitive)
        for start in Self.large.library.starts(limit: 20) {
            #expect(start.coverIDs.allSatisfy { ranks[$0] != .sensitive }, "\(start.suggestion.label)")
        }
    }

    /// Never a screenshot or a paper, as a big cover never is one (design rule 9): a chat or an
    /// order read at tile size is as personal as the papers the page keeps as words. "2026" has
    /// photos, so it shows one, although its newest pictures are screenshots; the kind
    /// "Screenshots" has none and keeps its tile on the calm placeholder with its symbol, as an
    /// album of only screenshots shows in the tab "Alben" (review G5).
    @Test func neverAScreenshotOrAPaperTheScreenshotsShowTheirSymbol() {
        let ranks = Self.large.library.ranks
        for start in Self.large.library.starts(limit: 20) {
            #expect(start.coverIDs.allSatisfy { (ranks[$0] ?? .photo) <= .unknown }, "\(start.suggestion.label) shows a screenshot or paper")
        }
        let screenshots = try! #require(Self.large.library.starts().first { $0.suggestion.label == "Screenshots" })
        #expect(screenshots.coverIDs.isEmpty)
        #expect(!screenshots.coverIDs.contains(Self.large.newestHarmlessScreenshot))
        #expect(screenshots.suggestion.count == 9)
    }

    /// Each starting point has a picture of its own: no tile tries a photo another one tries.
    /// `CoverPhoto` shows the first candidate that is sharp on the device, so a tile whose first
    /// photo is only a small preview there ("iPhone-Speicher optimieren") shows its next one,
    /// which must not be another tile's (review G1).
    @Test func everyStartingPointHasAPictureOfItsOwn() {
        for limit in [6, 20] {
            let tried = Self.large.library.starts(limit: limit).flatMap(\.coverIDs)
            #expect(Set(tried).count == tried.count, "a photo two tiles try")
        }
    }

    /// A tile whose photos are all tried by the tiles before it is left out: fewer tiles rather
    /// than one photo on two (review G1). München tries all three photos of 2026.
    @Test func aTileWhosePhotosTheTilesBeforeItTryIsLeftOut() {
        var library = Library()
        let first = library.add("2026-03-01 10:00", Self.munich)
        let second = library.add("2026-04-01 10:00", Self.munich)
        let third = library.add("2026-05-01 10:00", Self.munich)
        let starts = library.starts()
        #expect(starts.map(\.suggestion.label) == ["München"])
        #expect(starts.first?.coverIDs == [third, second, first])
    }

    /// As the albums tab picks a cover: the user's favourite first, then the newest.
    @Test func aFavouriteLeads() {
        let rome = try! #require(Self.large.library.starts().first { $0.suggestion.label == "Rom" })
        #expect(rome.coverIDs.first == Self.large.romeFavourite)
        // The trip has the same favourite, already Rom's: its own picture is another one.
        let trips = try! #require(Self.large.library.starts().first { $0.suggestion.kind == .trip })
        #expect(trips.coverIDs.first != Self.large.romeFavourite)
        #expect(!trips.coverIDs.contains(Self.large.romeFavourite))
    }

    /// A topic shows a photo the analysis is sure about, not just its newest one.
    @Test func aTopicShowsAPhotoTheAnalysisIsSureAbout() {
        let topic = try! #require(Self.large.library.starts().first { $0.suggestion.kind == .category })
        let first = try! #require(topic.coverIDs.first)
        #expect(Self.large.sureMountains.contains(first))
    }

    // MARK: Small libraries and before the analysis

    /// Fewer starting points, never an empty one: "2026" would only repeat München's photo, so
    /// it is left out; the bank card is never shown, nor the screenshot: "Screenshots" shows its
    /// symbol.
    @Test func aSmallLibraryOffersFewerNeverAnEmptyOne() {
        var library = Library()
        let photo = library.add("2026-05-01 10:00", Self.munich)
        let screenshot = library.add("2026-06-01 10:00", subtypes: [.screenshot], text: "Bestellung Nr. 4711", textCategories: ["order"])
        let card = library.add("2026-07-01 10:00", Self.munich, looksLikeDocument: true)
        for english in [false, true] {
            let starts = library.starts(english: english)
            #expect(starts.map(\.suggestion.label) == ["München", "Screenshots"])
            #expect(starts.map(\.coverIDs) == [[photo], []])
            #expect(starts.allSatisfy { !$0.coverIDs.contains(card) && !$0.coverIDs.contains(screenshot) })
        }
    }

    /// Before the image analysis (nothing known about the photos' content) the places and the
    /// year still show photos; topics come with the analysis. The year shows a photo of its own,
    /// none München tries (review G1): the one at home without a place.
    @Test func beforeTheImageAnalysisPlacesAndYearsShowPhotos() {
        var library = Library()
        let munichOld = library.add("2026-03-01 10:00", Self.munich, analysed: false)
        let munichNew = library.add("2026-04-01 10:00", Self.munich, analysed: false)
        let romeNew = library.add("2025-06-02 10:00", Self.rome, analysed: false)
        library.add("2025-06-01 10:00", Self.rome, analysed: false)
        let atHome = library.add("2026-02-01 10:00", analysed: false)
        #expect(library.ranks.values.allSatisfy { $0 == .unknown })
        let starts = library.starts()
        #expect(starts.map(\.suggestion.label) == ["München", "Rom", "2026"])
        #expect(starts.map { $0.coverIDs.first } == [munichNew, romeNew, atHome])
        #expect(starts.last?.coverIDs == [atHome], "the year tries München's photos too")
        #expect(starts.first?.coverIDs == [munichNew, munichOld])
    }

    /// A kind whose pictures may all not be shown (screenshots whose text was never read) shows
    /// its symbol like any kind of nothing but screenshots: never one of them, never "Vorschau
    /// ausgeblendet". A year of only them has no photo of its own and is left out.
    @Test func aKindOfPicturesThatMayNotBeShownShowsItsSymbol() {
        var library = Library()
        let photo = library.add("2025-05-01 10:00", Self.munich)
        library.add("2026-05-02 10:00", subtypes: [.screenshot])
        library.add("2026-05-03 10:00", subtypes: [.screenshot])
        #expect(library.ranks.filter { $0.key != photo }.values.allSatisfy { $0 == .sensitive })
        let starts = library.starts()
        #expect(starts.map(\.suggestion.label) == ["München", "Screenshots"])
        #expect(starts.map(\.coverIDs) == [[photo], []])
    }
}
