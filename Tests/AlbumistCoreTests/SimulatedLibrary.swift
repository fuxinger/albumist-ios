import Foundation
@testable import AlbumistCore
import AlbumistTestSupport

/// A realistic library like the one on the first iPhone test (Fuchs, 15.11.: 5,683 photos,
/// about 250 suggestions): four years of daily life in München with 1 to 6 photos a day,
/// regular places (work, gym, parents in Augsburg, a lake), weekend city trips, summer
/// holidays abroad, a multi-country road trip, two ski trips, a New Year's trip across the
/// year boundary, many screenshots and some photographed documents.
///
/// Deterministic (seeded), so a test can pin what the suggestions look like. Text on
/// screenshots and documents goes through the real classifiers, image labels through the
/// real taxonomy, trips and frequent places through the real detectors: the multi-label
/// noise is the one the app sees.
struct SimulatedLibrary {
    var assets: [AssetSnapshot] = []
    var places: [AssetID: PlaceComponents] = [:]
    var labels: [AssetID: [LabelScore]] = [:]
    var texts: [AssetID: (text: String, barcodes: [String])] = [:]
    private var rng = SeededRandom(seed: 15_11_2026)
    private var counter = 0

    // MARK: Places

    struct Spot {
        var coordinate: GeoCoordinate
        var place: PlaceComponents
        /// Typical scene, decides the image labels.
        var scene: Scene
    }

    enum Scene { case home, city, work, gym, lake, beach, cityTrip, ski, desert, stadium, wedding, countryside }

    static func de(_ region: String, _ town: String, water: String? = nil) -> PlaceComponents {
        PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: region, locality: town, inlandWater: water, timeZoneIdentifier: "Europe/Berlin")
    }

    static let home = Spot(coordinate: .init(latitude: 48.1371, longitude: 11.5754), place: de("Bayern", "München"), scene: .home)
    static let work = Spot(coordinate: .init(latitude: 48.1500, longitude: 11.5600), place: de("Bayern", "München"), scene: .work)
    static let gym = Spot(coordinate: .init(latitude: 48.1200, longitude: 11.6000), place: de("Bayern", "München"), scene: .gym)
    static let park = Spot(coordinate: .init(latitude: 48.1642, longitude: 11.6056), place: de("Bayern", "München"), scene: .city)
    static let cityCentre = Spot(coordinate: .init(latitude: 48.1374, longitude: 11.5755), place: de("Bayern", "München"), scene: .city)
    static let arena = Spot(coordinate: .init(latitude: 48.2188, longitude: 11.6247), place: de("Bayern", "München"), scene: .stadium)
    static let parents = Spot(coordinate: .init(latitude: 48.3705, longitude: 10.8978), place: de("Bayern", "Augsburg"), scene: .home)
    static let starnberg = Spot(coordinate: .init(latitude: 47.9990, longitude: 11.3400), place: de("Bayern", "Starnberg", water: "Starnberger See"), scene: .lake)
    static let tegernsee = Spot(coordinate: .init(latitude: 47.7128, longitude: 11.7584), place: de("Bayern", "Tegernsee", water: "Tegernsee"), scene: .lake)
    static let berlin = Spot(coordinate: .init(latitude: 52.5200, longitude: 13.4050), place: de("Berlin", "Berlin"), scene: .cityTrip)
    static let hamburg = Spot(coordinate: .init(latitude: 53.5511, longitude: 9.9937), place: de("Hamburg", "Hamburg"), scene: .cityTrip)
    static let cologne = Spot(coordinate: .init(latitude: 50.9375, longitude: 6.9603), place: de("Nordrhein-Westfalen", "Köln"), scene: .wedding)
    static let nuremberg = Spot(coordinate: .init(latitude: 49.4521, longitude: 11.0767), place: de("Bayern", "Nürnberg"), scene: .cityTrip)
    /// One-off day trips into the mountains, to lakes and towns around München.
    static let excursions: [Spot] = [
        Spot(coordinate: .init(latitude: 47.4917, longitude: 11.0955), place: de("Bayern", "Garmisch-Partenkirchen"), scene: .lake),
        Spot(coordinate: .init(latitude: 47.5958, longitude: 11.3402), place: de("Bayern", "Kochel am See", water: "Walchensee"), scene: .lake),
        spot(47.8095, 13.0550, "AT", "Österreich", "Salzburg", "Salzburg", "Europe/Vienna", .cityTrip),
        Spot(coordinate: .init(latitude: 49.0134, longitude: 12.1016), place: de("Bayern", "Regensburg"), scene: .cityTrip),
        Spot(coordinate: .init(latitude: 47.8567, longitude: 12.3772), place: de("Bayern", "Prien am Chiemsee", water: "Chiemsee"), scene: .lake),
        Spot(coordinate: .init(latitude: 47.6309, longitude: 13.0040), place: de("Bayern", "Berchtesgaden"), scene: .lake),
        Spot(coordinate: .init(latitude: 47.5576, longitude: 10.7498), place: de("Bayern", "Schwangau"), scene: .cityTrip),
        spot(47.2692, 11.4041, "AT", "Österreich", "Tirol", "Innsbruck", "Europe/Vienna", .cityTrip),
        Spot(coordinate: .init(latitude: 48.5372, longitude: 12.1522), place: de("Bayern", "Landshut"), scene: .cityTrip),
        Spot(coordinate: .init(latitude: 47.4428, longitude: 11.2617), place: de("Bayern", "Mittenwald"), scene: .lake),
        Spot(coordinate: .init(latitude: 47.7370, longitude: 11.8800), place: de("Bayern", "Schliersee", water: "Schliersee"), scene: .lake),
        Spot(coordinate: .init(latitude: 48.7665, longitude: 11.4258), place: de("Bayern", "Ingolstadt"), scene: .cityTrip),
    ]
    static let frankfurt = Spot(coordinate: .init(latitude: 50.1109, longitude: 8.6821), place: de("Hessen", "Frankfurt am Main"), scene: .work)

    static func spot(_ lat: Double, _ lon: Double, _ code: String, _ country: String, _ region: String, _ town: String, _ zone: String, _ scene: Scene, water: String? = nil) -> Spot {
        Spot(coordinate: .init(latitude: lat, longitude: lon),
             place: PlaceComponents(isoCountryCode: code, country: country, administrativeArea: region, locality: town, inlandWater: water, timeZoneIdentifier: zone),
             scene: scene)
    }

    static let paris = spot(48.8566, 2.3522, "FR", "Frankreich", "Île-de-France", "Paris", "Europe/Paris", .cityTrip)
    static let cagliari = spot(39.2238, 9.1217, "IT", "Italien", "Sardinien", "Cagliari", "Europe/Rome", .beach)
    static let villasimius = spot(39.1400, 9.5200, "IT", "Italien", "Sardinien", "Villasimius", "Europe/Rome", .beach)
    static let alghero = spot(40.5580, 8.3190, "IT", "Italien", "Sardinien", "Alghero", "Europe/Rome", .beach)
    static let soelden = spot(46.9655, 11.0076, "AT", "Österreich", "Tirol", "Sölden", "Europe/Vienna", .ski)
    static let vienna = spot(48.2082, 16.3738, "AT", "Österreich", "Wien", "Wien", "Europe/Vienna", .cityTrip)
    static let lisbon = spot(38.7223, -9.1393, "PT", "Portugal", "Lissabon", "Lissabon", "Europe/Lisbon", .cityTrip)
    static let porto = spot(41.1579, -8.6291, "PT", "Portugal", "Porto", "Porto", "Europe/Lisbon", .cityTrip)
    static let seville = spot(37.3891, -5.9845, "ES", "Spanien", "Andalusien", "Sevilla", "Europe/Madrid", .cityTrip)
    static let granada = spot(37.1773, -3.5986, "ES", "Spanien", "Andalusien", "Granada", "Europe/Madrid", .cityTrip)
    static let marrakesh = spot(31.6295, -7.9811, "MA", "Marokko", "Marrakesch-Safi", "Marrakesch", "Africa/Casablanca", .desert)
    static let essaouira = spot(31.5085, -9.7595, "MA", "Marokko", "Marrakesch-Safi", "Essaouira", "Africa/Casablanca", .beach)
    static let split = spot(43.5081, 16.4402, "HR", "Kroatien", "Split-Dalmatien", "Split", "Europe/Zagreb", .beach)
    static let hvar = spot(43.1729, 16.4411, "HR", "Kroatien", "Split-Dalmatien", "Hvar", "Europe/Zagreb", .beach)
    static let dubrovnik = spot(42.6507, 18.0944, "HR", "Kroatien", "Dubrovnik-Neretva", "Dubrovnik", "Europe/Zagreb", .beach)
    static let rome = spot(41.8986, 12.4769, "IT", "Italien", "Latium", "Rom", "Europe/Rome", .cityTrip)
    static let malcesine = spot(45.7636, 10.8085, "IT", "Italien", "Venetien", "Malcesine", "Europe/Rome", .lake, water: "Gardasee")

    // MARK: Building blocks

    static func day(_ s: String) -> Date { Fixture.date(s) }

    private mutating func nextID() -> AssetID {
        counter += 1
        return AssetID(String(format: "sim-%06d", counter))
    }

    /// One camera photo (or video) at a spot; about one in ten has no location (other
    /// cameras, edited copies).
    @discardableResult
    mutating func photo(_ spot: Spot, at date: Date, spread: Double = 300, gpsRate: Double = 0.9) -> AssetID {
        let id = nextID()
        let isVideo = rng.chance(0.07)
        let hasGPS = rng.chance(gpsRate)
        let coordinate = Fixture.jitter(spot.coordinate, seed: counter, meters: spread)
        assets.append(AssetSnapshot(id: id, kind: isVideo ? .video : .image, creationDate: date,
                                    location: hasGPS ? coordinate : nil, pixelWidth: 4032, pixelHeight: 3024,
                                    duration: isVideo ? 12 : 0))
        if hasGPS { places[id] = spot.place }
        labels[id] = sceneLabels(spot.scene)
        return id
    }

    mutating func screenshot(at date: Date, text: String, barcodes: [String] = []) {
        let id = nextID()
        assets.append(AssetSnapshot(id: id, kind: .image, subtypes: .screenshot, creationDate: date, pixelWidth: 1179, pixelHeight: 2556))
        texts[id] = (text, barcodes)
        labels[id] = text.contains("Route") ? [LabelScore("map", 0.9)] : []
    }

    mutating func documentPhoto(_ spot: Spot, at date: Date, text: String) {
        let id = nextID()
        assets.append(AssetSnapshot(id: id, kind: .image, creationDate: date, location: spot.coordinate, pixelWidth: 4032, pixelHeight: 3024))
        places[id] = spot.place
        texts[id] = (text, [])
        labels[id] = [LabelScore("document", 0.92)]
    }

    /// `count` photos on one day between `from` and `to` o'clock.
    mutating func burst(_ spot: Spot, on day: Date, count: Int, from: Int = 9, to: Int = 22, spread: Double = 800) {
        for _ in 0..<count {
            let minute = rng.int(from * 60, to * 60)
            photo(spot, at: day.addingTimeInterval(Double(minute) * 60), spread: spread)
        }
    }

    /// A trip: per stop a number of days with `perDay` photos on average.
    mutating func trip(_ stops: [(Spot, Int)], from start: String, perDay: ClosedRange<Int>) {
        var day = Self.day(start)
        for (spot, days) in stops {
            for _ in 0..<days {
                burst(spot, on: day, count: rng.int(perDay.lowerBound, perDay.upperBound), from: 8, to: 23, spread: 3_000)
                day = day.addingTimeInterval(86_400)
            }
        }
    }

    // MARK: Labels

    private mutating func label(_ identifiers: [String], _ probability: Double, into list: inout [LabelScore]) {
        guard rng.chance(probability), let id = identifiers.randomElement(using: &rng) else { return }
        list.append(LabelScore(id, rng.double(0.45, 0.98)))
    }

    /// Vision-like labels for a scene: what a classifier finds in everyday photos, with the
    /// generic labels (building, table, clothing) far more common than the interesting ones.
    private mutating func sceneLabels(_ scene: Scene) -> [LabelScore] {
        var l: [LabelScore] = []
        label(["clothing", "jacket", "shoes"], 0.25, into: &l)
        switch scene {
        case .home:
            label(["interior_room", "living_room", "kitchen"], 0.35, into: &l)
            label(["furniture", "table", "chair", "sofa"], 0.3, into: &l)
            label(["pizza", "pasta", "cake", "salad", "soup"], 0.14, into: &l)
            label(["coffee", "wine", "drink", "tea_drink"], 0.1, into: &l)
            label(["plant", "decorative_plant"], 0.12, into: &l)
            label(["phone", "computer", "television"], 0.06, into: &l)
            label(["cat"], 0.015, into: &l)
            label(["toy", "figurine"], 0.03, into: &l)
        case .city, .countryside:
            label(["building", "house_single", "apartment"], 0.35, into: &l)
            label(["bridge", "tower", "fountain"], 0.06, into: &l)
            label(["car", "automobile"], 0.06, into: &l)
            label(["bicycle"], 0.04, into: &l)
            label(["flower", "blossom", "tulip"], 0.07, into: &l)
            label(["dog"], 0.03, into: &l)
            label(["grass"], 0.1, into: &l)
            label(["coffee", "beer", "drink"], 0.08, into: &l)
            label(["storefront"], 0.04, into: &l)
        case .work:
            label(["computer", "laptop"], 0.35, into: &l)
            label(["whiteboard", "diagram"], 0.12, into: &l)
            label(["table", "chair"], 0.2, into: &l)
        case .gym:
            label(["dumbbell", "treadmill"], 0.6, into: &l)
        case .lake:
            label(["lake"], 0.6, into: &l)
            label(["sailboat", "boat", "rowboat"], 0.2, into: &l)
            label(["mountain", "hill"], 0.25, into: &l)
            label(["sunset_sunrise"], 0.12, into: &l)
            label(["beer", "drink"], 0.1, into: &l)
        case .beach:
            label(["beach", "ocean", "shore"], 0.5, into: &l)
            label(["boat", "sailboat", "yacht"], 0.1, into: &l)
            label(["sunset_sunrise"], 0.08, into: &l)
            label(["pasta", "pizza", "salad", "dessert"], 0.12, into: &l)
            label(["restaurant"], 0.06, into: &l)
            label(["building", "house_single"], 0.15, into: &l)
            label(["cocktail", "wine", "drink"], 0.08, into: &l)
        case .cityTrip:
            label(["building", "apartment"], 0.4, into: &l)
            label(["monument", "statue", "ruins"], 0.12, into: &l)
            label(["tower", "bridge", "fountain", "castle"], 0.12, into: &l)
            label(["museum", "painting", "art"], 0.07, into: &l)
            label(["pasta", "pizza", "dessert", "sandwich"], 0.12, into: &l)
            label(["restaurant"], 0.06, into: &l)
            label(["wine", "beer", "coffee"], 0.1, into: &l)
            label(["storefront"], 0.05, into: &l)
        case .ski:
            label(["snow", "skiing", "ski_equipment"], 0.6, into: &l)
            label(["mountain", "glacier"], 0.5, into: &l)
            label(["beer", "drink"], 0.06, into: &l)
        case .desert:
            label(["building"], 0.3, into: &l)
            label(["desert"], 0.18, into: &l)
            label(["storefront", "interior_shop"], 0.12, into: &l)
            label(["soup", "salad", "dessert"], 0.12, into: &l)
        case .stadium:
            label(["soccer", "football"], 0.65, into: &l)
        case .wedding:
            label(["wedding", "celebration", "wedding_dress"], 0.55, into: &l)
            label(["cake", "wine"], 0.15, into: &l)
        }
        return l
    }

    // MARK: Screenshots and documents

    static let screenshotTexts: [(weight: Int, texts: [String], barcode: Bool)] = [
        (300, ["Mama\nzuletzt online heute um 18:02\nHast du morgen Zeit?\nJa klar, gegen 15 Uhr\nGelesen",
               "WhatsApp\nLisa tippt …\nSchickst du mir die Fotos von gestern?\nNachricht",
               "Jonas\nheute 09:14\nBin gleich da\nZugestellt\niMessage",
               "Familie\nPapa: Wir sind gestern gut angekommen\nNachricht schreiben"], false),
        (90, ["instagram\n1.234 Gefällt mir\n56 Kommentare\nFolgen\nStory ansehen",
              "TikTok\nFollower 12,3 Tsd.\nGefällt 4.501\nTeilen\nKommentare"], false),
        (70, ["Route\n24 min\n12 km\nFahrt starten\nAnkunft 18:42",
              "Navigation\nIn 300 m rechts abbiegen\n8 min\n3,2 km\nAnkunft 09:10"], false),
        (60, ["Einstellungen\nFlugmodus\nWLAN\nBluetooth\nMobilfunk\nBatterie",
              "Fehler\nVerbindung fehlgeschlagen\nError 503\nhttp://192.168.0.1\nFirmware Version 2.4"], false),
        (45, ["Amazon\nBestellung aufgegeben\nBestellnummer 302-1234567-1234567\nLieferung Donnerstag\nSendungsverfolgung",
              "Zalando\nDeine Bestellung wurde versandt\nBestellnummer 10203040\nZustellung morgen\nTracking"], false),
        (40, ["In den Warenkorb\nAuf Lager – lieferbar\n4,5 Sterne 1.203 Bewertungen\nProduktdetails",
              "Add to cart\nIn stock\nReviews 2,341\nProduktdetails"], false),
        (35, ["DB Navigator\nTicket\nICE 523 München Hbf – Berlin Hbf\nGleis 18\nSitzplatz 54\nFahrkarte",
              "Konzert Olympiahalle\nEintrittskarte\nEinlass 18:30\nTicket\nSitzplatz Block C"], true),
        (30, ["Black Friday Sale\n-30% Rabatt\nNur heute\nstatt 89,99 €",
              "Angebot der Woche\nDeal\nRabatt 20 %\nstatt 49,99"], false),
        (25, ["Zutaten\n200 g Mehl\n2 Esslöffel Zucker\nZubereitung\nBackofen auf 180 Grad vorheizen",
              "Rezept Lasagne\nZutaten\n1 Teelöffel Salz\nZubereitung 45 Minuten"], false),
        (25, ["Eilmeldung\nAktualisiert 14:32 Uhr\n3 Minuten Lesezeit\nRedaktion",
              "Artikel\nUpdated 2 hours ago\n5 min read\nBreaking"], false),
        (20, ["Einkaufsliste\nMilch\nBrot\nEier", "Notiz\nTodo: Steuer, Auto, Geschenk für Mama"], false),
        (18, ["Rechnung\nRechnungsnummer 2024-0815\nZahlbar bis 15.03.2024\nUSt-ID DE123456789\nGesamt 119,00 EUR"], false),
        (15, ["Scan me"], true),
        (12, ["Booking.com\nIhre Buchungsbestätigung\nHotel Alfama\nCheck-in 12. Sep\nCheck-out 15. Sep\n3 Übernachtungen"], false),
        (10, ["Lufthansa Boarding Pass\nLH 1234 MUC → LIS\nGate G24 Seat 14A\nBoarding 06:15\nTerminal 2",
              "Ryanair\nFR 8471 Memmingen – London Stansted\nSitzplatz 17C\nBordkarte"], true),
        (10, ["Gutscheincode SOMMER20\nJetzt einlösen\n20 % Rabatt"], false),
        (10, ["So geht’s\nSchritt 1: Tippe auf Einstellungen\nSchritt 2: Wähle Allgemein\nAnleitung"], false),
        (8, ["2-Zimmer-Wohnung\nKaltmiete 1.150 €\nWarmmiete 1.380 €\nWohnfläche 58 m²\nKaution 3 Monatsmieten"], false),
        (5, ["Stellenangebot\nSenior iOS Developer (m/w/d)\nVollzeit\nJetzt bewerben\nGehalt"], false),
        (140, ["", "Level 12 complete!", "😂😂😂", "Screen Time 3h 12m"], false),
    ]

    static let documentTexts: [(weight: Int, text: String)] = [
        (25, "REWE Markt\nSumme EUR 23,45\nGirocard\nMwSt 7%\nBon-Nr 1234\nKassierer 3"),
        (12, "Rechnung\nRechnungsnummer 4711\nZahlbar bis 30.04.2025\nUmsatzsteuer 19%\nGesamtbetrag 349,00 EUR"),
        (8, "Sehr geehrte Damen und Herren,\nbezüglich Ihres Schreibens vom 12.03.\nMit freundlichen Grüßen"),
        (6, "Mietvertrag\nVertragspartner\nLaufzeit unbefristet\nKündigungsfrist drei Monate\nUnterschrift"),
        (6, "Bedienungsanleitung\nSicherheitshinweise\nInstallation\nUser Manual"),
        (4, "Garantieschein\nGarantie 2 Jahre\nGewährleistung\nKaufdatum"),
        (4, "TÜV Hauptuntersuchung\nKennzeichen M-AB 1234\nFahrzeugschein\nKfz"),
        (3, "Arztbrief\nDiagnose\nBefund\nPatient\nKrankenkasse"),
        (3, "Kontoauszug\nIBAN DE89 3704 0044 0532 0130 00\nKontostand 1.234,56 EUR"),
        (2, "Kostenvoranschlag\nAngebot Nr. 2025-17\nGültig bis 31.05.2025\nMaterial\nArbeitszeit\nAnfahrt"),
    ]

    mutating func randomScreenshot(at date: Date) {
        let total = Self.screenshotTexts.reduce(0) { $0 + $1.weight }
        var pick = rng.int(0, total - 1)
        for entry in Self.screenshotTexts {
            if pick < entry.weight {
                let text = entry.texts.randomElement(using: &rng) ?? ""
                screenshot(at: date, text: text, barcodes: entry.barcode && rng.chance(0.7) ? ["payload"] : [])
                return
            }
            pick -= entry.weight
        }
    }

    mutating func randomDocument(at date: Date) {
        let total = Self.documentTexts.reduce(0) { $0 + $1.weight }
        var pick = rng.int(0, total - 1)
        for entry in Self.documentTexts {
            if pick < entry.weight {
                documentPhoto(Self.home, at: date, text: entry.text)
                return
            }
            pick -= entry.weight
        }
    }

    // MARK: The library

    /// About 5,700 photos and videos from September 2022 to October 2026.
    static func fuchs() -> SimulatedLibrary {
        var lib = SimulatedLibrary()
        let trips: [(stops: [(Spot, Int)], start: String, perDay: ClosedRange<Int>)] = [
            ([(berlin, 3)], "2023-03-17", 12...25),
            ([(paris, 4)], "2023-10-05", 15...30),
            ([(cagliari, 4), (villasimius, 6), (alghero, 4)], "2023-08-05", 15...35),
            ([(soelden, 6)], "2024-02-10", 10...25),
            ([(malcesine, 4)], "2024-06-06", 12...25),
            ([(lisbon, 4), (porto, 3), (seville, 4), (granada, 3)], "2024-09-07", 12...28),
            ([(vienna, 5)], "2024-12-29", 12...25),
            ([(marrakesh, 6), (essaouira, 4)], "2025-05-03", 15...35),
            ([(hamburg, 2)], "2025-06-21", 15...30),
            ([(split, 4), (hvar, 5), (dubrovnik, 5)], "2025-08-02", 15...32),
            ([(soelden, 5)], "2026-02-14", 10...25),
            ([(rome, 4)], "2026-04-09", 18...35),
            ([(frankfurt, 2)], "2025-11-12", 3...7),      // business trip, few photos
            ([(cologne, 1)], "2024-07-13", 35...45),      // a friend's wedding
        ]
        var away: [ClosedRange<Date>] = []
        for t in trips {
            lib.trip(t.stops, from: t.start, perDay: t.perDay)
            let days = t.stops.reduce(0) { $0 + $1.1 }
            away.append(day(t.start)...day(t.start).addingTimeInterval(Double(days) * 86_400))
        }

        let cal = Fixture.calendar
        var date = day("2022-09-01")
        let end = day("2026-10-31")
        var weekendIndex = 0
        while date <= end {
            defer { date = date.addingTimeInterval(86_400) }
            if away.contains(where: { $0.contains(date) }) { continue }
            let weekday = cal.component(.weekday, from: date) // 1 = Sunday
            let isWeekend = weekday == 1 || weekday == 7
            if weekday == 7 { weekendIndex += 1 }

            // Parents in Augsburg about once a month, on a Saturday.
            if weekday == 7 && weekendIndex % 4 == 0 {
                lib.burst(parents, on: date, count: lib.rng.int(2, 9), from: 12, to: 20, spread: 150)
                continue
            }
            // Summer Sundays at the Tegernsee now and then (day trips).
            let month = cal.component(.month, from: date)
            if weekday == 1 && (5...9).contains(month) && lib.rng.chance(0.18) {
                lib.burst(tegernsee, on: date, count: lib.rng.int(6, 16), from: 10, to: 19, spread: 1_500)
                continue
            }
            // Friends in Nürnberg, a few weekends over the years.
            if weekday == 7 && weekendIndex % 23 == 11 {
                lib.burst(nuremberg, on: date, count: lib.rng.int(8, 18), from: 11, to: 23, spread: 2_000)
                lib.burst(nuremberg, on: date.addingTimeInterval(86_400), count: lib.rng.int(4, 10), from: 9, to: 15, spread: 2_000)
                date = date.addingTimeInterval(86_400)
                continue
            }
            // Day trips to somewhere new, mostly on weekends from spring to autumn.
            if isWeekend && (4...10).contains(month) && lib.rng.chance(0.07) {
                let place = excursions[lib.rng.int(0, excursions.count - 1)]
                lib.burst(place, on: date, count: lib.rng.int(8, 30), from: 9, to: 19, spread: 2_500)
                continue
            }
            // The lake close to town (inside the home area) on summer evenings.
            if (5...9).contains(month) && lib.rng.chance(0.06) {
                lib.burst(starnberg, on: date, count: lib.rng.int(2, 6), from: 17, to: 21, spread: 200)
            }
            // Football: a few home games a year.
            if weekday == 7 && lib.rng.chance(0.05) {
                lib.burst(arena, on: date, count: lib.rng.int(4, 10), from: 15, to: 18, spread: 100)
            }
            // Everyday photos: 0 to 6 a day.
            let weights = [32, 24, 18, 12, 7, 4, 3]
            var pick = lib.rng.int(0, weights.reduce(0, +) - 1)
            var n = 0
            while pick >= weights[n] { pick -= weights[n]; n += 1 }
            for _ in 0..<n {
                let r = lib.rng.double(0, 1)
                let spot: Spot
                if !isWeekend && r < 0.15 { spot = work }
                else if r < 0.2 { spot = gym }
                else if r < 0.7 { spot = home }
                else if r < 0.82 { spot = park }
                else { spot = cityCentre }
                let minute = lib.rng.int(8 * 60, 22 * 60)
                lib.photo(spot, at: date.addingTimeInterval(Double(minute) * 60), spread: spot.scene == .city ? 2_500 : 80, gpsRate: 0.88)
            }
            // Screenshots: about 0.55 a day.
            let shots = lib.rng.chance(0.37) ? lib.rng.int(1, 2) : 0
            for _ in 0..<shots { lib.randomScreenshot(at: date.addingTimeInterval(Double(lib.rng.int(7 * 60, 23 * 60)) * 60)) }
            // Photographed documents: about 75 in four years.
            if lib.rng.chance(0.05) { lib.randomDocument(at: date.addingTimeInterval(19 * 3_600)) }
        }
        return lib
    }

    // MARK: Analysis

    /// Runs the real detectors and classifiers, like the pipeline does, and returns what the
    /// proposal engine gets.
    func analysis(calendar: Calendar = Fixture.calendar) -> AnalysisSnapshot {
        let trips = TripDetector(calendar: calendar).detect(in: assets)
        let frequent = FrequentPlaceDetector(calendar: calendar).detect(in: assets)
        var tripOf: [AssetID: AlbumistID] = [:]
        for trip in trips { for id in trip.geotaggedAssetIDs { tripOf[id] = trip.id } }
        var frequentOf: [AssetID: AlbumistID] = [:]
        for place in frequent { for id in place.assetIDs { frequentOf[id] = place.id } }
        let screenshots = ScreenshotClassifier()
        let documents = DocumentAnalyzer()
        let facts = assets.map { asset -> AssetFacts in
            var f = AssetFacts(asset: asset)
            if let place = places[asset.id] {
                f.place = place
                f.placeSource = .gpsReverseGeocoded
            }
            f.tripID = tripOf[asset.id]
            f.frequentPlaceID = frequentOf[asset.id]
            let scores = labels[asset.id] ?? []
            f.categories = ImageTaxonomy.categories(from: scores.map { ($0.identifier, $0.confidence) })
            if let text = texts[asset.id] {
                f.document = documents.analyze(text: text.text)
                if asset.isScreenshotLike {
                    let classified = screenshots.classify(text: text.text, barcodePayloads: text.barcodes, imageLabels: Set(scores.map(\.identifier)))
                    f.textCategories = Set(classified.categories.filter { $0.value >= .plausible }.map(\.key.rawValue))
                }
                f.recognizedText = text.text
            }
            return f
        }
        return AnalysisSnapshot(facts: facts, trips: trips, frequentPlaces: frequent)
    }
}

/// SplitMix64: small, fast and the same on every platform.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(_ low: Int, _ high: Int) -> Int {
        guard high > low else { return low }
        return low + Int(next() % UInt64(high - low + 1))
    }

    mutating func chance(_ p: Double) -> Bool { double(0, 1) < p }
}

/// A readable summary of suggestions: counts by kind and all titles, for the report and
/// for comparing before and after a change.
enum ProposalReport {
    static func kindName(_ kind: ProposalKind) -> String {
        switch kind {
        case .trip: "trip"
        case .placeCollection(let level): "place.\(level)"
        default: kind.familyKey
        }
    }

    static func reason(_ r: ProposalReason) -> String {
        switch r {
        case .photosInPlaceDuringPeriod(let count, let place, _, _): "\(count) in \(place)"
        case .photosInPlace(let count, let place): "\(count) in \(place)"
        case .recurringPlace(let count, let days): "\(count) on \(days) days"
        case .inferredWithoutLocation(let count): "+\(count) without place"
        default: "\(r)"
        }
    }

    static func render(_ proposals: [AlbumProposal]) -> String {
        var lines: [String] = ["total \(proposals.count)"]
        let byKind = Dictionary(grouping: proposals) { kindName($0.kind) + ($0.folderPath.first.map { " [\($0)]" } ?? "") }
        for key in byKind.keys.sorted() {
            let items = byKind[key]!.sorted { $0.assetIDs.count > $1.assetIDs.count }
            lines.append("\(key): \(items.count)")
            for p in items {
                lines.append("    \(p.title)  (\(p.assetIDs.count))  \(p.folderPath.joined(separator: "/"))  — \(p.reasons.map(reason).joined(separator: " / "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
