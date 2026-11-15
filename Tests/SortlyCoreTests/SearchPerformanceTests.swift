import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Search speed on a large library: 50,000 photos over ten years in 40 places, Vision
/// labels on every photo, recognized text on every tenth (screenshots and documents).
@Suite("Search performance")
struct SearchPerformanceTests {
    static func library(count: Int) -> [AssetFacts] {
        var generator = SplitMix(seed: 42)
        let places: [(String, String, String, String)] = [
            ("DE", "Deutschland", "Bayern", "München"), ("DE", "Deutschland", "Bayern", "Augsburg"), ("DE", "Deutschland", "Berlin", "Berlin"),
            ("DE", "Deutschland", "Hamburg", "Hamburg"), ("DE", "Deutschland", "Hessen", "Frankfurt am Main"), ("AT", "Österreich", "Wien", "Wien"),
            ("AT", "Österreich", "Tirol", "Innsbruck"), ("IT", "Italien", "Latium", "Rom"), ("IT", "Italien", "Toskana", "Florenz"),
            ("IT", "Italien", "Venetien", "Venedig"), ("IT", "Italien", "Lombardei", "Mailand"), ("ES", "Spanien", "Balearische Inseln", "Palma"),
            ("ES", "Spanien", "Katalonien", "Barcelona"), ("FR", "Frankreich", "Île-de-France", "Paris"), ("FR", "Frankreich", "Provence", "Nizza"),
            ("GR", "Griechenland", "Kreta", "Chania"), ("HR", "Kroatien", "Dalmatien", "Split"), ("US", "Vereinigte Staaten", "New York", "New York"),
            ("US", "Vereinigte Staaten", "Kalifornien", "San Francisco"), ("GB", "Vereinigtes Königreich", "England", "London"),
            ("NL", "Niederlande", "Nordholland", "Amsterdam"), ("CH", "Schweiz", "Zürich", "Zürich"), ("PT", "Portugal", "Lissabon", "Lissabon"),
            ("DK", "Dänemark", "Hovedstaden", "Kopenhagen"), ("TH", "Thailand", "Bangkok", "Bangkok"), ("JP", "Japan", "Tokio", "Tokio"),
        ]
        let labels = ["dog", "cat", "beach", "ocean", "shore", "sunset_sunrise", "mountain", "snow", "skiing", "pizza", "pasta", "coffee", "cake",
                      "birthday_cake", "wedding", "christmas_tree", "fireworks", "car", "bicycle", "train", "airplane", "flower", "tree", "forest",
                      "lake", "river", "building", "cityscape", "skyscraper", "museum", "statue", "ruins", "church_exterior", "castle", "bridge",
                      "food_other", "wine", "beer", "cocktail", "restaurant", "kitchen", "living_room", "sofa", "toy", "book", "laptop", "phone",
                      "concert", "stadium", "soccer", "hiking", "swimming", "pool", "boat", "sailboat", "horse", "bird", "squirrel", "garden", "park"]
        let words = ["Rechnung", "Bestellung", "Lieferung", "Termin", "Zahnarzt", "Gutschein", "Ticket", "Gleis", "Abflug", "Hotel", "Zimmer",
                     "Zutaten", "Backofen", "Nachricht", "gelesen", "online", "Amazon", "Zalando", "IKEA", "REWE", "Summe", "EUR", "Bestellnummer",
                     "Rechnungsnummer", "Betrag", "Kundennummer", "Vertrag", "Laufzeit", "Kündigung", "Garantie", "Seriennummer", "Einstellungen"]
        let start = Fixture.date("2016-01-01").timeIntervalSinceReferenceDate
        let span = Fixture.date("2026-11-01").timeIntervalSinceReferenceDate - start
        var facts: [AssetFacts] = []
        facts.reserveCapacity(count)
        for i in 0..<count {
            let date = Date(timeIntervalSinceReferenceDate: start + Double(generator.next() % UInt64(span)))
            let screenshot = i % 10 == 0
            let kind: MediaKind = i % 25 == 0 ? .video : .image
            var asset = AssetSnapshot(id: AssetID(String(format: "perf-%06d", i)), kind: kind, subtypes: screenshot ? .screenshot : [], creationDate: date,
                                      pixelWidth: 4032, pixelHeight: 3024, isFavorite: i % 97 == 0)
            var f = AssetFacts(asset: asset)
            if !screenshot {
                let place = places[Int(generator.next() % UInt64(places.count))]
                asset.location = GeoCoordinate(latitude: 48, longitude: 11)
                f.asset = asset
                f.place = PlaceComponents(isoCountryCode: place.0, country: place.1, administrativeArea: place.2, locality: place.3)
                f.placeSource = .gpsReverseGeocoded
                var observations: [(String, Double)] = []
                for _ in 0..<4 {
                    observations.append((labels[Int(generator.next() % UInt64(labels.count))], 0.4 + Double(generator.next() % 60) / 100))
                }
                f.categories = ImageTaxonomy.categories(from: observations)
                f.keywords = Set(observations.filter { $0.1 >= 0.5 }.map(\.0))
                if i % 7 == 0 { f.tripID = SortlyID("trip-\(i / 500)") }
            } else {
                let text = (0..<30).map { _ in words[Int(generator.next() % UInt64(words.count))] + String(generator.next() % 1000) }.joined(separator: " ")
                f.recognizedText = text + " " + words.joined(separator: " ")
                if i % 30 == 0 {
                    f.document = DocumentInfo(type: .invoice, typeReliability: .likely, documentDate: nil, merchant: "amazon", orderNumber: "302-\(i)",
                                              invoiceNumber: nil, totalAmount: nil, subject: nil, keywords: [], sensitivity: .normal)
                }
            }
            facts.append(f)
        }
        return facts
    }

    @Test func fiftyThousandPhotos() {
        let facts = Self.library(count: 50_000)
        let clock = ContinuousClock()
        var index: SearchIndex?
        let build = clock.measure { index = SearchIndex(facts: facts, calendar: Fixture.calendar) }
        let lab = SearchLab.build()
        let queries = SearchQuerySet.cases(lab).map(\.query) + ["Hund Strand Sonnenuntergang Italien 2019 Juli", "Zahnartz Rechnung", "xyzzy qwertz"]
        var timings: [(String, Duration)] = []
        for query in queries {
            var result = SearchResult()
            let time = clock.measure { result = index!.search(query, now: SearchLab.now) }
            timings.append((query, time))
            _ = result
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let sorted = timings.map { ms($0.1) }.sorted()
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let slowest = timings.max { $0.1 < $1.1 }!
        print(String(format: "SEARCH_PERF photos 50000 index %.0f ms | %d queries: average %.1f ms, median %.1f ms, slowest %.1f ms (%@)",
                     ms(build), sorted.count, average, sorted[sorted.count / 2], ms(slowest.1), slowest.0))
        // Debug builds on CI are several times slower than the app; the bound only catches
        // a search that scans the facts again.
        #expect(average < 100)
        #expect(ms(slowest.1) < 500)
        #expect(ms(build) < 20_000)
    }
}

/// Small deterministic random numbers for synthetic libraries.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
