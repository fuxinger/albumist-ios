import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// A realistic library for search quality tests: daily life in Munich, trips to Italy,
/// Mallorca, Vienna and New York, holidays, pets, screenshots with text and documents.
/// Every asset carries "truth" tags set by hand, so expectations are computed from what
/// the photo shows, never from what the engine answers.
struct SearchLab: Sendable {
    static let now = Fixture.date("2026-11-15 12:00")   // a Sunday
    static let calendar = Fixture.calendar

    enum Spot {
        static let munich = GeoCoordinate(latitude: 48.1371, longitude: 11.5754)
        static let garmisch = GeoCoordinate(latitude: 47.4917, longitude: 11.0955)
        static let rome = GeoCoordinate(latitude: 41.8986, longitude: 12.4769)
        static let colosseum = GeoCoordinate(latitude: 41.8902, longitude: 12.4922)
        static let florence = GeoCoordinate(latitude: 43.7696, longitude: 11.2558)
        static let rimini = GeoCoordinate(latitude: 44.0678, longitude: 12.5695)
        static let garda = GeoCoordinate(latitude: 45.6389, longitude: 10.7203)
        static let palma = GeoCoordinate(latitude: 39.5696, longitude: 2.6502)
        static let newYork = GeoCoordinate(latitude: 40.7128, longitude: -74.0060)
        static let vienna = GeoCoordinate(latitude: 48.2082, longitude: 16.3738)
    }

    /// Reverse geocoding as an iPhone set to German answers it.
    static let places: [(GeoCoordinate, PlaceComponents)] = [
        (Spot.munich, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", subAdministrativeArea: "Oberbayern", locality: "München", subLocality: "Altstadt-Lehel")),
        (Spot.garmisch, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "Garmisch-Partenkirchen")),
        (Spot.rome, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom")),
        (Spot.colosseum, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", areaOfInterest: "Kolosseum")),
        (Spot.florence, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Toskana", locality: "Florenz")),
        (Spot.rimini, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Emilia-Romagna", locality: "Rimini", ocean: "Adriatisches Meer")),
        (Spot.garda, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Venetien", locality: "Malcesine", inlandWater: "Gardasee")),
        (Spot.palma, .init(isoCountryCode: "ES", country: "Spanien", administrativeArea: "Balearische Inseln", subAdministrativeArea: "Mallorca", locality: "Palma")),
        (Spot.newYork, .init(isoCountryCode: "US", country: "Vereinigte Staaten", administrativeArea: "New York", locality: "New York")),
        (Spot.vienna, .init(isoCountryCode: "AT", country: "Österreich", administrativeArea: "Wien", locality: "Wien")),
    ]

    private(set) var facts: [AssetFacts] = []
    private(set) var tags: [AssetID: Set<String>] = [:]
    private(set) var statuses: [AssetID: OverallStatus] = [:]

    var byID: [AssetID: AssetFacts] { Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) }) }

    @discardableResult
    mutating func add(_ date: String, _ spot: GeoCoordinate?, kind: MediaKind = .image, subtypes: MediaSubtypes = [],
                      labels: [(String, Double)] = [], tags extra: Set<String> = [], text: String? = nil,
                      document: DocumentInfo? = nil, textCategories: Set<String> = [], trip: String? = nil,
                      favorite: Bool = false, status: OverallStatus = .fullyOrganized) -> AssetID {
        let id = AssetID(String(format: "lab-%05d", facts.count + 1))
        let asset = AssetSnapshot(id: id, kind: kind, subtypes: subtypes, creationDate: Fixture.date(date),
                                  location: spot.map { Fixture.jitter($0, seed: facts.count, meters: 40) },
                                  pixelWidth: 4032, pixelHeight: 3024, isFavorite: favorite)
        var f = AssetFacts(asset: asset)
        if let location = asset.usableLocation {
            f.place = Self.places.min { GeoMath.distance(location, $0.0) < GeoMath.distance(location, $1.0) }!.1
            f.placeSource = .gpsReverseGeocoded
        }
        // Same mapping as FactsAssembler: categories from Vision labels, keywords at 0.5 and up.
        f.categories = ImageTaxonomy.categories(from: labels.map { ($0.0, $0.1) })
        f.keywords = Set(labels.filter { $0.1 >= 0.5 }.map(\.0))
        f.recognizedText = text
        f.document = document
        f.textCategories = textCategories
        f.tripID = trip.map { SortlyID($0) }
        facts.append(f)
        tags[id] = extra.union(labels.map(\.0))
        statuses[id] = status
        return id
    }

    static func document(_ type: DocumentType, merchant: String?, order: String? = nil, invoice: String? = nil) -> DocumentInfo {
        DocumentInfo(type: type, typeReliability: .likely, documentDate: nil, merchant: merchant, orderNumber: order, invoiceNumber: invoice,
                     totalAmount: nil, subject: nil, keywords: [], sensitivity: .normal)
    }

    static func build() -> SearchLab {
        var lab = SearchLab()
        // Daily life at home: every 4th day at noon, from January 2025 to the day before today.
        var day = Fixture.date("2025-01-02")
        while day < Fixture.date("2026-11-15") {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = Fixture.utc; f.dateFormat = "yyyy-MM-dd"
            lab.add(f.string(from: day) + " 12:00", Spot.munich, status: lab.facts.count % 9 == 0 ? .unorganized : .fullyOrganized)
            day = calendar.date(byAdding: .day, value: 4, to: day)!
        }
        lab.add("2026-11-15 10:00", Spot.munich, labels: [("coffee", 0.8)])                       // today
        lab.add("2026-11-07 15:00", Spot.munich)                                                    // last weekend

        // Pets at home.
        for d in ["2025-03-02 18:00", "2025-09-14 18:00", "2026-05-03 18:00", "2026-10-18 18:00"] {
            lab.add(d, Spot.munich, labels: [("cat", 0.92), ("kitten", 0.6)])
        }
        for d in ["2025-06-01 09:00", "2026-04-12 09:00"] {
            lab.add(d, Spot.munich, labels: [("dog", 0.9), ("canine", 0.85), ("retriever", 0.6)])
        }
        lab.add("2025-08-17 10:00", Spot.munich, labels: [("bicycle", 0.88), ("cycling", 0.6)])
        lab.add("2025-05-05 17:00", Spot.munich, kind: .video)
        lab.add("2026-09-20 17:00", Spot.munich, kind: .video)

        // Holidays and celebrations.
        lab.add("2024-12-24 18:00", Spot.munich, labels: [("christmas_tree", 0.93), ("christmas_decoration", 0.7)], favorite: true)
        lab.add("2024-12-24 18:30", Spot.munich, labels: [("christmas_tree", 0.85)])
        lab.add("2024-12-25 12:00", Spot.munich)
        lab.add("2025-12-10 17:00", Spot.vienna, labels: [("christmas_decoration", 0.8)])       // Christmas market
        lab.add("2025-12-24 19:00", Spot.munich, labels: [("christmas_tree", 0.9)])
        lab.add("2025-12-31 23:40", Spot.munich, labels: [("fireworks", 0.95)])
        lab.add("2026-01-01 00:20", Spot.munich, labels: [("fireworks", 0.9)])
        lab.add("2026-01-01 14:00", Spot.munich)
        lab.add("2025-04-20 11:00", Spot.munich, labels: [("easter_egg", 0.88)])
        lab.add("2025-04-21 15:00", Spot.munich)
        lab.add("2025-03-14 16:00", Spot.munich, labels: [("birthday_cake", 0.9), ("candle", 0.6)])
        lab.add("2026-03-14 16:00", Spot.munich, labels: [("birthday_cake", 0.87), ("balloon", 0.7)])
        lab.add("2025-10-31 19:00", Spot.munich, labels: [("jack_o_lantern", 0.9), ("pumpkin", 0.7)])
        lab.add("2026-03-01 11:00", nil)                                                       // camera without GPS
        lab.add("2026-03-01 11:05", nil)

        // Wedding in Vienna, June 2024.
        lab.add("2024-06-15 14:00", Spot.vienna, labels: [("wedding", 0.9), ("wedding_dress", 0.8), ("bride", 0.7)], favorite: true)
        lab.add("2024-06-15 14:30", Spot.vienna, labels: [("wedding", 0.86), ("groom", 0.6)])
        lab.add("2024-06-15 21:00", Spot.vienna, labels: [("wedding_cake", 0.82)])

        // Garda lake, June 2023 (Saturday and Sunday).
        for d in ["2023-06-10 10:00", "2023-06-10 16:00", "2023-06-11 10:00"] {
            lab.add(d, Spot.garda, labels: [("lake", 0.9), ("mountain", 0.6)], trip: "trip-garda")
        }
        lab.add("2023-06-11 11:00", Spot.garda, subtypes: .panorama, labels: [("lake", 0.88)], trip: "trip-garda")
        lab.add("2023-06-11 12:00", Spot.garda, kind: .video, trip: "trip-garda")

        // Rimini beach, August 2023: the dog came along.
        for (i, d) in ["2023-08-05", "2023-08-06", "2023-08-07", "2023-08-08", "2023-08-09"].enumerated() {
            lab.add(d + " 10:00", Spot.rimini, labels: [("beach", 0.9), ("shore", 0.8), ("ocean", 0.7)], trip: "trip-rimini")
            if i < 3 { lab.add(d + " 11:00", Spot.rimini, labels: [("dog", 0.88), ("beach", 0.84), ("sand", 0.6)], trip: "trip-rimini") }
            if i % 2 == 0 { lab.add(d + " 20:30", Spot.rimini, labels: [("sunset_sunrise", 0.93), ("ocean", 0.8), ("beach", 0.6)], trip: "trip-rimini") }
        }
        lab.add("2023-08-07 13:00", Spot.rimini, labels: [("pizza", 0.91)], trip: "trip-rimini")

        // New York, October 2023.
        for d in ["2023-10-02 15:00", "2023-10-03 15:00", "2023-10-04 15:00", "2023-10-05 15:00"] {
            lab.add(d, Spot.newYork, labels: [("skyscraper", 0.9), ("cityscape", 0.8)], trip: "trip-newyork")
        }

        // Florence, May 2024: museums.
        for d in ["2024-05-18 11:00", "2024-05-19 11:00"] {
            lab.add(d, Spot.florence, labels: [("museum", 0.85), ("statue", 0.7)], trip: "trip-florence")
        }
        lab.add("2024-05-19 19:00", Spot.florence, labels: [("pasta", 0.9)], trip: "trip-florence")

        // Rome, July 2025, with Live Photos and the Colosseum.
        for d in ["2025-07-10", "2025-07-11", "2025-07-12", "2025-07-13"] {
            lab.add(d + " 10:00", Spot.rome, subtypes: .livePhoto, trip: "trip-rome")
            lab.add(d + " 14:00", Spot.colosseum, labels: [("ruins", 0.9), ("monument", 0.6)], trip: "trip-rome")
        }
        lab.add("2025-07-12 20:00", Spot.rome, labels: [("pizza", 0.93), ("restaurant", 0.6)], trip: "trip-rome")

        // Skiing at the Zugspitze, February 2026.
        for d in ["2026-02-07 10:00", "2026-02-07 14:00", "2026-02-08 11:00"] {
            lab.add(d, Spot.garmisch, labels: [("snow", 0.95), ("skiing", 0.85), ("mountain", 0.8)])
        }

        // Mallorca, August 2026.
        for d in ["2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13"] {
            lab.add(d + " 11:00", Spot.palma, labels: [("beach", 0.92), ("palm_tree", 0.7)], trip: "trip-mallorca")
        }
        lab.add("2026-08-12 20:45", Spot.palma, labels: [("sunset_sunrise", 0.9), ("ocean", 0.75)], trip: "trip-mallorca", favorite: true)
        lab.add("2026-08-13 18:00", Spot.palma, kind: .video, trip: "trip-mallorca")

        // A supermarket receipt photographed at home.
        lab.add("2026-10-10 18:00", Spot.munich, labels: [("receipt", 0.8)], text: "REWE Markt GmbH Summe EUR 23,45 Kassenbon Bar",
                document: document(.receipt, merchant: "rewe"))

        // Screenshots (no location).
        lab.add("2026-11-14 09:12", nil, subtypes: .screenshot, text: "Anna: Bis morgen! zuletzt online heute um 09:10 gelesen", textCategories: ["chat"])
        lab.add("2026-11-14 20:30", nil, subtypes: .screenshot, text: "Ihre Bestellung bei Amazon Bestellnummer 302-1234567 versandt",
                document: document(.order, merchant: "amazon", order: "302-1234567"), textCategories: ["order"])
        lab.add("2026-10-02 08:00", nil, subtypes: .screenshot, text: "Rechnung Amazon EU Rechnungsnummer DE1234 Gesamtbetrag 49,99 €",
                document: document(.invoice, merchant: "amazon", invoice: "DE1234"), textCategories: ["invoice"])
        lab.add("2026-11-04 07:15", nil, subtypes: .screenshot, text: "Deutsche Bahn Fahrkarte ICE 599 München Hbf → Berlin Hbf Gleis 14",
                document: document(.ticket, merchant: "deutsche bahn"), textCategories: ["ticket"])
        lab.add("2026-07-01 06:00", nil, subtypes: .screenshot, text: "Boarding Pass Lufthansa LH 1840 MUC → PMI Gate G12 Seat 21C",
                textCategories: ["flight", "ticket"])
        lab.add("2025-11-20 19:00", nil, subtypes: .screenshot, text: "Apfelkuchen Zutaten 200 g Mehl Zubereitung Backofen vorheizen", textCategories: ["recipe"])
        lab.add("2026-09-15 12:00", nil, subtypes: .screenshot, text: "Termin bei Zahnarzt Dr. Müller am 3. Oktober um 10 Uhr")
        lab.add("2026-06-20 12:00", nil, subtypes: .screenshot, text: "Dein Gutscheincode SOMMER20 jetzt einlösen", textCategories: ["coupon"])
        return lab
    }

    // MARK: Truth helpers

    func ids(_ predicate: (AssetFacts, Set<String>) -> Bool) -> Set<AssetID> {
        Set(facts.filter { predicate($0, tags[$0.id] ?? []) }.map(\.id))
    }
    func tagged(_ any: String...) -> Set<AssetID> { ids { _, t in !t.isDisjoint(with: any) } }
    func date(_ f: AssetFacts) -> Date? { f.asset.creationDate }
    func comp(_ c: Calendar.Component, _ f: AssetFacts) -> Int? { date(f).map { Self.calendar.component(c, from: $0) } }
    func between(_ from: String, _ to: String) -> Set<AssetID> {
        let a = Fixture.date(from), b = Fixture.date(to)
        return ids { f, _ in date(f).map { $0 >= a && $0 < b } ?? false }
    }
    func locality(_ name: String) -> Set<AssetID> { ids { f, _ in f.gpsPlace?.locality == name } }
    func country(_ code: String) -> Set<AssetID> { ids { f, _ in f.gpsPlace?.isoCountryCode == code } }
}

/// What a query should return.
struct QueryCase: CustomStringConvertible {
    var query: String
    var expected: Set<AssetID>
    /// The query cannot be met in full; the engine should say so and show these instead.
    var relaxed = false
    /// Words the engine should report as not understood.
    var ignored: [String] = []
    var description: String { query }
}

/// The outcome of one query, independent of the engine version.
struct QueryOutcome {
    var ids: [AssetID]
    var relaxed: Bool
    var ignored: [String]
}

enum SearchQuerySet {
    static func cases(_ lab: SearchLab) -> [QueryCase] {
        let dogs = lab.tagged("dog"), beach = lab.tagged("beach"), sunset = lab.tagged("sunset_sunrise")
        let cats = lab.tagged("cat"), screenshots = lab.ids { f, _ in f.asset.subtypes.contains(.screenshot) }
        let videos = lab.ids { f, _ in f.asset.kind == .video }
        let munich = lab.locality("München"), rome = lab.locality("Rom"), italy = lab.country("IT")
        let christmasLabels = lab.tagged("christmas_tree", "christmas_decoration")
        let christmasDays = lab.ids { f, _ in lab.comp(.month, f) == 12 && (24...26).contains(lab.comp(.day, f) ?? 0) }
        let easter = lab.between("2025-04-18", "2025-04-22").union(lab.between("2024-03-29", "2024-04-02"))
            .union(lab.between("2026-04-03", "2026-04-07")).union(lab.between("2023-04-07", "2023-04-11")).union(lab.tagged("easter_egg"))
        let doc = { (type: DocumentType) in lab.ids { f, _ in f.document?.type == type } }
        let text = { (word: String) in lab.ids { f, _ in f.recognizedText?.contains(word) == true } }
        let year = { (y: Int) in lab.ids { f, _ in lab.comp(.year, f) == y } }
        let summer2026 = lab.between("2026-06-01", "2026-09-01")
        let europe: Set<String> = ["DE", "IT", "ES", "AT"]
        return [
            // Content, German and English, singular and plural, lower case.
            QueryCase(query: "Hund am Strand", expected: dogs.intersection(beach)),
            QueryCase(query: "hunde", expected: dogs),
            QueryCase(query: "Katze", expected: cats),
            QueryCase(query: "Katzen 2026", expected: cats.intersection(year(2026))),
            QueryCase(query: "cats", expected: cats),
            QueryCase(query: "dog beach 2023", expected: dogs.intersection(beach).intersection(year(2023))),
            QueryCase(query: "Strand", expected: beach),
            QueryCase(query: "Sonnenuntergang", expected: sunset),
            QueryCase(query: "Sonnenuntergang am Meer", expected: sunset.intersection(lab.tagged("ocean", "beach", "shore"))),
            QueryCase(query: "beach sunset", expected: beach.intersection(sunset)),
            QueryCase(query: "Geburtstag", expected: lab.tagged("birthday_cake")),
            QueryCase(query: "Hochzeit", expected: lab.tagged("wedding", "wedding_dress", "wedding_cake", "bride", "groom")),
            QueryCase(query: "Schnee", expected: lab.tagged("snow")),
            QueryCase(query: "Skifahren", expected: lab.tagged("skiing")),
            QueryCase(query: "Berge", expected: lab.tagged("mountain")),
            QueryCase(query: "Essen", expected: lab.tagged("pizza", "pasta")),
            QueryCase(query: "Pizza", expected: lab.tagged("pizza")),
            QueryCase(query: "Fahrrad", expected: lab.tagged("bicycle")),
            QueryCase(query: "Museum", expected: lab.tagged("museum")),
            QueryCase(query: "Feuerwerk", expected: lab.tagged("fireworks")),
            // Places: city, country, region, island, lake, landmark, exonyms, umlauts, typos.
            QueryCase(query: "Italien 2024", expected: italy.intersection(year(2024))),
            QueryCase(query: "Rom Juli 2025", expected: rome.intersection(lab.between("2025-07-01", "2025-08-01"))),
            QueryCase(query: "Muenchen", expected: munich),
            QueryCase(query: "munich", expected: munich),
            QueryCase(query: "Rome", expected: rome),
            QueryCase(query: "Vienna", expected: lab.locality("Wien")),
            QueryCase(query: "Itallien", expected: italy),
            QueryCase(query: "Spanien", expected: lab.country("ES")),
            QueryCase(query: "Mallorka", expected: lab.locality("Palma")),
            QueryCase(query: "Bayern", expected: lab.ids { f, _ in f.gpsPlace?.administrativeArea == "Bayern" }),
            QueryCase(query: "Europa", expected: lab.ids { f, _ in f.gpsPlace?.isoCountryCode.map(europe.contains) ?? false }),
            QueryCase(query: "USA", expected: lab.country("US")),
            QueryCase(query: "New York", expected: lab.country("US")),
            QueryCase(query: "Kolosseum", expected: lab.ids { f, _ in f.gpsPlace?.areaOfInterest == "Kolosseum" }),
            QueryCase(query: "Gardasee", expected: lab.locality("Malcesine")),
            QueryCase(query: "Fotos ohne Ort", expected: lab.ids { f, _ in f.asset.usableLocation == nil }),
            // Dates: relative, named, holidays, seasons, months, weekdays.
            QueryCase(query: "letzten Sommer", expected: summer2026),
            QueryCase(query: "photos from last summer", expected: summer2026),
            QueryCase(query: "Weihnachten", expected: christmasDays.union(christmasLabels)),
            QueryCase(query: "Weihnachten 2024", expected: christmasDays.union(christmasLabels).intersection(year(2024))),
            QueryCase(query: "christmas 2024", expected: christmasDays.union(christmasLabels).intersection(year(2024))),
            QueryCase(query: "Silvester", expected: lab.between("2025-12-31 00:00", "2026-01-01 06:00").union(lab.between("2024-12-31 00:00", "2025-01-01 06:00"))),
            QueryCase(query: "Ostern", expected: easter),
            QueryCase(query: "Halloween", expected: lab.ids { f, _ in lab.comp(.month, f) == 10 && lab.comp(.day, f) == 31 }.union(lab.tagged("jack_o_lantern"))),
            QueryCase(query: "gestern", expected: lab.between("2026-11-14", "2026-11-15")),
            QueryCase(query: "heute", expected: lab.between("2026-11-15", "2026-11-16")),
            QueryCase(query: "letzte Woche", expected: lab.between("2026-11-02", "2026-11-09")),
            QueryCase(query: "vor 2 Jahren", expected: year(2024)),
            QueryCase(query: "Juli", expected: lab.ids { f, _ in lab.comp(.month, f) == 7 }),
            QueryCase(query: "Dezember 2024", expected: lab.between("2024-12-01", "2025-01-01")),
            QueryCase(query: "Sommer 2023", expected: lab.between("2023-06-01", "2023-09-01")),
            QueryCase(query: "Herbst", expected: lab.ids { f, _ in (9...11).contains(lab.comp(.month, f) ?? 0) }),
            QueryCase(query: "Wochenende", expected: lab.ids { f, _ in [1, 7].contains(lab.comp(.weekday, f) ?? 0) }),
            // Media types and library state.
            QueryCase(query: "Screenshots von gestern", expected: screenshots.intersection(lab.between("2026-11-14", "2026-11-15"))),
            QueryCase(query: "screenshots yesterday", expected: screenshots.intersection(lab.between("2026-11-14", "2026-11-15"))),
            QueryCase(query: "Videos München", expected: videos.intersection(munich)),
            QueryCase(query: "Videos", expected: videos),
            QueryCase(query: "Panorama", expected: lab.ids { f, _ in f.asset.subtypes.contains(.panorama) }),
            QueryCase(query: "Live Photos", expected: lab.ids { f, _ in f.asset.subtypes.contains(.livePhoto) }),
            QueryCase(query: "Favoriten", expected: lab.ids { f, _ in f.asset.isFavorite }),
            QueryCase(query: "Urlaub 2023", expected: lab.ids { f, _ in f.tripID != nil }.intersection(year(2023))),
            QueryCase(query: "nicht sortiert", expected: Set(lab.statuses.filter { $0.value == .unorganized }.keys)),
            // Documents, merchants and text on screenshots.
            QueryCase(query: "Rechnung Amazon", expected: doc(.invoice)),
            QueryCase(query: "Bestellung", expected: doc(.order)),
            QueryCase(query: "Bahnticket", expected: text("Deutsche Bahn")),
            QueryCase(query: "Deutsche Bahn", expected: text("Deutsche Bahn")),
            QueryCase(query: "Kassenbon", expected: doc(.receipt)),
            QueryCase(query: "REWE", expected: text("REWE")),
            QueryCase(query: "Bordkarte", expected: text("Boarding Pass")),
            QueryCase(query: "Rezept", expected: text("Zutaten")),
            QueryCase(query: "Zahnarzt", expected: text("Zahnarzt")),
            QueryCase(query: "Gutschein", expected: text("Gutscheincode")),
            QueryCase(query: "302-1234567", expected: text("302-1234567")),
            // Words that are not understood and queries that cannot be met in full.
            QueryCase(query: "Sonnenuntergnag", expected: sunset),
            QueryCase(query: "Hund Xyzzy", expected: dogs, ignored: ["xyzzy"]),
            QueryCase(query: "Strand 2019", expected: beach, relaxed: true),
            // Harder cases: negation, compounds, ranges, alternatives and refinement.
            QueryCase(query: "Strand ohne Hund", expected: beach.subtracting(dogs)),
            QueryCase(query: "beach without dogs", expected: beach.subtracting(dogs)),
            QueryCase(query: "Hundestrand", expected: dogs.intersection(beach)),
            QueryCase(query: "Hochzeitsfotos", expected: lab.tagged("wedding", "wedding_dress", "wedding_cake", "bride", "groom")),
            QueryCase(query: "Strände", expected: beach),
            QueryCase(query: "Sonnenuntergänge auf Mallorca", expected: sunset.intersection(lab.locality("Palma"))),
            QueryCase(query: "Rom Florenz", expected: rome.union(lab.locality("Florenz"))),
            QueryCase(query: "Bayern München", expected: munich),
            QueryCase(query: "2023 bis 2024", expected: year(2023).union(year(2024))),
            QueryCase(query: "2023-2024", expected: year(2023).union(year(2024))),
            QueryCase(query: "24.12.2024", expected: lab.between("2024-12-24", "2024-12-25")),
            QueryCase(query: "Weihnachten Silvester", expected: christmasDays.union(christmasLabels)
                .union(lab.between("2025-12-31 00:00", "2026-01-01 06:00")).union(lab.between("2024-12-31 00:00", "2025-01-01 06:00"))),
            QueryCase(query: "letztes Wochenende", expected: lab.between("2026-11-07", "2026-11-09")),
            QueryCase(query: "Ostern 2025", expected: lab.between("2025-04-18", "2025-04-22").union(lab.tagged("easter_egg"))),
            QueryCase(query: "letzten Dezember", expected: lab.between("2025-12-01", "2026-01-01")),
            QueryCase(query: "im Ausland", expected: lab.ids { f, _ in f.gpsPlace.map { $0.isoCountryCode != "DE" } ?? false }),
            QueryCase(query: "Hochzeit in Wien", expected: lab.tagged("wedding", "wedding_dress", "wedding_cake", "bride", "groom")),
            QueryCase(query: "skiing 2026", expected: lab.tagged("skiing")),
            QueryCase(query: "Tickets", expected: text("Deutsche Bahn").union(text("Boarding Pass"))),
            QueryCase(query: "Amazon", expected: text("Amazon")),
            QueryCase(query: "Videos vom Urlaub", expected: videos.intersection(lab.ids { f, _ in f.tripID != nil })),
            QueryCase(query: "Katzen im Herbst 2025", expected: cats.intersection(lab.between("2025-09-01", "2025-12-01"))),
            QueryCase(query: "SONNENUNTERGANG RIMINI", expected: sunset.intersection(lab.locality("Rimini"))),
            QueryCase(query: "Fotos von der Zugspitze im Schnee", expected: lab.tagged("snow"), ignored: ["zugspitze"]),
        ]
    }
}

@Suite("Search query set")
struct SearchQuerySetTests {
    static let lab = SearchLab.build()

    static let index = SearchIndex(facts: lab.facts, calendar: SearchLab.calendar)

    /// Runs one query the way the app does.
    static func run(_ query: String) -> QueryOutcome {
        let result = index.search(query, now: SearchLab.now, statuses: lab.statuses)
        return QueryOutcome(ids: result.ids, relaxed: result.isRelaxed, ignored: result.tokens.filter { $0.kind == .ignored }.map { $0.label.lowercased() })
    }

    static func passes(_ c: QueryCase) -> (ok: Bool, detail: String) {
        let outcome = run(c.query)
        let got = Set(outcome.ids)
        var problems: [String] = []
        if got != c.expected {
            problems.append("got \(got.count), expected \(c.expected.count) (missing \(c.expected.subtracting(got).count), extra \(got.subtracting(c.expected).count))")
        }
        if c.expected.isEmpty { problems.append("empty expectation") }
        if outcome.relaxed != c.relaxed { problems.append("relaxed \(outcome.relaxed)") }
        if !c.ignored.allSatisfy(outcome.ignored.contains) { problems.append("ignored \(outcome.ignored)") }
        return (problems.isEmpty, problems.joined(separator: "; "))
    }

    @Test func querySet() {
        let cases = SearchQuerySet.cases(Self.lab)
        var failed: [String] = []
        for c in cases {
            let result = Self.passes(c)
            if !result.ok { failed.append("\(c.query): \(result.detail)") }
        }
        for c in cases {
            let result = Self.index.search(c.query, now: SearchLab.now, statuses: Self.lab.statuses)
            let chips = result.tokens.map { t in
                var s = "\(t.kind.rawValue):\(t.label)"
                if let d = t.detail { s += " [\(d)]" }
                if let typed = t.typed { s += " (typed \(typed))" }
                if let n = t.count { s += " #\(n)" }
                return s
            }
            let dropped = result.dropped.isEmpty ? "" : " dropped: " + result.dropped.map(\.label).joined(separator: ", ")
            print("QUERYSET \(c.query) → \(chips.joined(separator: " | ")) = \(result.ids.count)\(dropped) top \(result.top.count)")
        }
        print("QUERYSET passed \(cases.count - failed.count) of \(cases.count)")
        for f in failed { print("QUERYSET FAIL \(f)") }
    }
}
