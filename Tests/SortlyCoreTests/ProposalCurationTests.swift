import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

func germanEngine(_ configure: (inout OrganizationSettings) -> Void = { _ in }) -> ProposalEngine {
    var s = OrganizationSettings()
    s.titleLanguage = .german
    configure(&s)
    return ProposalEngine(settings: s, calendar: Fixture.calendar)
}

/// Two suggestions holding (nearly) the same photos: the duplicates curation removes.
func nearDuplicates(_ proposals: [AlbumProposal]) -> [(String, String)] {
    let compared = proposals.filter { p in
        switch p.kind {
        case .trip, .placeCollection, .frequentPlace, .documentCategory, .screenshotCategory, .imageCategory: true
        default: false
        }
    }
    var pairs: [(String, String)] = []
    for (i, a) in compared.enumerated() {
        for b in compared[(i + 1)...] {
            let shared = a.assetIDs.intersection(b.assetIDs).count
            if Double(shared) >= Double(max(a.assetIDs.count, b.assetIDs.count)) * ProposalEngine.sameAlbumShare {
                pairs.append((a.title, b.title))
            }
        }
    }
    return pairs
}

// MARK: - The realistic library (first iPhone test, 15.11.)

@Suite("Proposal curation on a realistic library")
struct SimulatedLibraryProposalTests {
    static let library = SimulatedLibrary.fuchs()
    static let analysis = library.analysis()
    static let defaults = germanEngine().proposals(for: analysis)
    static let withCities = germanEngine { $0.places.includesCities = true }.proposals(for: analysis)

    /// `ALBUMIST_PROPOSAL_REPORT=/path/report.txt swift test --filter SimulatedLibraryProposalTests`
    /// writes every suggestion to that file, for comparing before and after a change.
    @Test func report() throws {
        guard let path = ProcessInfo.processInfo.environment["ALBUMIST_PROPOSAL_REPORT"] else { return }
        let a = Self.analysis
        var text = "library: \(a.facts.count) items, \(a.facts.filter { $0.asset.isScreenshotLike }.count) screenshots, "
            + "\(a.trips.count) trips, \(a.frequentPlaces.count) frequent places\n"
        text += "=== defaults ===\n" + ProposalReport.render(Self.defaults) + "\n"
        text += "=== with cities ===\n" + ProposalReport.render(Self.withCities) + "\n"
        text += "=== english ===\n" + ProposalReport.render(germanEngine { $0.titleLanguage = .english }.proposals(for: a).filter { $0.kind == .trip }) + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func aFewDozenSuggestionsInsteadOfOneHundred() {
        // Before curation: 113 suggestions (145 with towns) for these 5,875 photos and screenshots.
        #expect((40...60).contains(Self.defaults.count))
        #expect((40...62).contains(Self.withCities.count))
        #expect(nearDuplicates(Self.defaults).isEmpty, "\(nearDuplicates(Self.defaults))")
        #expect(nearDuplicates(Self.withCities).isEmpty, "\(nearDuplicates(Self.withCities))")
    }

    @Test func tripsAreNamedLikePeopleTalkAboutThem() {
        let titles = Set(Self.defaults.filter { $0.kind == .trip }.map(\.title))
        for expected in ["Marokko, Mai 2025", "Kroatien, August 2025", "Portugal & Spanien, September 2024",
                         "Wien, Dezember 2024 – Januar 2025", "Gardasee, Juni 2024", "Rom, April 2026", "Paris, Oktober 2023"] {
            #expect(titles.contains(expected), "\(expected) missing in \(titles.sorted())")
        }
        // Composite regions abroad read like a form; the country is what people say.
        #expect(!titles.contains { $0.hasPrefix("Split-Dalmatien") || $0.hasPrefix("Marrakesch-Safi") })
        // Never the home region: "Bayern" says nothing to someone living in Munich.
        #expect(!titles.contains { $0.hasPrefix("Bayern") })
        // Two trips with the same title in one folder would block the plan.
        let byFolder = Dictionary(grouping: Self.defaults) { $0.folderPath + [$0.title] }
        #expect(byFolder.values.allSatisfy { $0.count == 1 })
        // The trip's reason names the towns it went to.
        let croatia = Self.defaults.first { $0.title == "Kroatien, August 2025" }
        if case .photosInPlaceDuringPeriod(_, let place, _, _)? = croatia?.reasons.first {
            #expect(place == "Split, Hvar und Dubrovnik")
        } else {
            Issue.record("Croatia trip without its towns")
        }
    }

    @Test func routineVisitsBecomeOneAlbumPerPlace() {
        let trips = Self.defaults.filter { $0.kind == .trip }
        // Summer Sundays at the Tegernsee and the parents in Augsburg are no trips of their own …
        #expect(!trips.contains { $0.title.hasPrefix("Tegernsee") || $0.title.hasPrefix("Augsburg") })
        // … but one album each, with every visit.
        let tegernsee = Self.defaults.first { $0.title == "Tegernsee" && $0.folderPath == ["Reisen"] }
        #expect((tegernsee?.assetIDs.count ?? 0) > 100)
        #expect(tegernsee?.reasons.contains { if case .recurringPlace = $0 { true } else { false } } == true)
        #expect(Self.defaults.contains { $0.title == "Augsburg" && $0.folderPath == ["Reisen"] })
        // The unnamed frequent place at the parents' house is the same photos: it gives way.
        #expect(!Self.defaults.contains { $0.title == "Häufiger Ort in Augsburg" })
    }

    @Test func placesAreTheCountriesVisitedMoreThanOnce() {
        let countries = Set(Self.defaults.filter { $0.kind == .placeCollection(.country) }.map(\.title))
        #expect(countries == ["Italien", "Österreich"])
        // Towns, when switched on: only those that are more than one trip, never the home town.
        let towns = Self.withCities.filter { $0.kind == .placeCollection(.locality) && $0.folderPath.first == "Länder" }.map(\.title)
        #expect(!towns.contains("München"))
        #expect(!towns.contains("Rom") && !towns.contains("Marrakesch") && !towns.contains("Lissabon"))
        #expect(towns.contains("Sölden") && towns.contains("Augsburg"))
    }

    @Test func themesScreenshotsAndDocumentsAreTheUsefulOnes() {
        let themes = Self.defaults.filter { if case .imageCategory = $0.kind { true } else { false } }
        #expect(themes.count <= ProposalEngine.maximumThemes)
        #expect(themes.allSatisfy { $0.folderPath == ["Themen"] })
        #expect(!themes.contains { ["Kleidung", "Möbel", "Immobilien", "Einrichtung", "Technik", "Getränke"].contains($0.title) })
        #expect(themes.contains { $0.title == "Gerichte" } && themes.contains { $0.title == "Meer" })

        let screenshots = Set(Self.defaults.filter { if case .screenshotCategory = $0.kind { true } else { false } }.map(\.title))
        #expect(screenshots.contains("Chats") && screenshots.contains("Rezepte"))
        #expect(screenshots.isDisjoint(with: ["Technische Informationen", "Nachrichtenartikel", "Angebote", "Notizen", "Anleitungen", "Karten und Navigation"]))
        // Orders and tickets are with the documents, once.
        #expect(Self.defaults.filter { $0.title == "Bestellungen" }.count == 1)
        #expect(Self.defaults.filter { $0.title == "Tickets" }.count == 1)

        let documents = Self.defaults.filter { if case .documentCategory = $0.kind { true } else { false } }
        #expect(documents.allSatisfy { $0.assetIDs.count >= 4 })
    }

    @Test func noAlbumForWhereTheUserLives() {
        #expect(!Self.defaults.contains { $0.title == "Deutschland" })
        #expect(!Self.withCities.contains { $0.title == "Deutschland" || $0.title == "München" })
    }

    @Test func englishTitles() {
        let titles = Set(germanEngine { $0.titleLanguage = .english }.proposals(for: Self.analysis).map(\.title))
        #expect(titles.contains("Wien, December 2024 – January 2025"))
        #expect(titles.contains("Marokko, May 2025"))
    }
}

// MARK: - Rules one by one

@Suite("Proposal curation rules")
struct ProposalCurationRuleTests {
    static let munich = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")
    static let home = LibraryProfile(everydayPlaces: [
        PlaceKey(level: .country, path: "de"), PlaceKey(level: .administrativeArea, path: "de/bayern"), PlaceKey(level: .locality, path: "de/bayern/munchen"),
    ])
    let labels = Labels(.german)

    func place(_ code: String, _ country: String, _ region: String?, _ town: String?, water: String? = nil) -> PlaceComponents {
        PlaceComponents(isoCountryCode: code, country: country, administrativeArea: region, locality: town, inlandWater: water)
    }

    func name(_ places: [PlaceComponents], kind: TripKind = .vacation) -> String? {
        ProposalEngine.primaryPlaceName(places, kind: kind, labels: labels, profile: Self.home).0
    }

    @Test func tripNames() {
        let split = place("HR", "Kroatien", "Split-Dalmatien", "Split")
        let hvar = place("HR", "Kroatien", "Split-Dalmatien", "Hvar")
        let dubrovnik = place("HR", "Kroatien", "Dubrovnik-Neretva", "Dubrovnik")
        #expect(name(Array(repeating: split, count: 4) + Array(repeating: hvar, count: 3) + Array(repeating: dubrovnik, count: 3)) == "Kroatien")
        let cagliari = place("IT", "Italien", "Sardinien", "Cagliari")
        let alghero = place("IT", "Italien", "Sardinien", "Alghero")
        #expect(name([cagliari, cagliari, alghero, alghero]) == "Sardinien")
        // A region at home is fine (Germans know "Schleswig-Holstein"), the home region is not.
        let kiel = place("DE", "Deutschland", "Schleswig-Holstein", "Kiel")
        let luebeck = place("DE", "Deutschland", "Schleswig-Holstein", "Lübeck")
        #expect(name([kiel, kiel, luebeck, luebeck]) == "Schleswig-Holstein")
        let augsburg = place("DE", "Deutschland", "Bayern", "Augsburg")
        let tegernsee = place("DE", "Deutschland", "Bayern", "Tegernsee")
        #expect(name([augsburg, augsburg, tegernsee, tegernsee], kind: .weekendTrip) == "Augsburg & Tegernsee")
        // Across a border: the towns; across countries far apart: the countries in visiting order.
        let salzburg = place("AT", "Österreich", "Salzburg", "Salzburg")
        let berchtesgaden = place("DE", "Deutschland", "Bayern", "Berchtesgaden")
        #expect(name([salzburg, salzburg, berchtesgaden, berchtesgaden], kind: .weekendTrip) == "Salzburg & Berchtesgaden")
        let towns = ["Lissabon", "Porto", "Sevilla", "Granada", "Córdoba"]
        let roadTrip = towns.enumerated().flatMap { i, town in
            Array(repeating: place(i < 2 ? "PT" : "ES", i < 2 ? "Portugal" : "Spanien", i < 2 ? "Lissabon" : "Andalusien", town), count: 2)
        }
        #expect(name(roadTrip, kind: .roadTrip) == "Portugal & Spanien")
        // On the lake itself: the lake.
        let garda = place("IT", "Italien", "Venetien", "Malcesine", water: "Gardasee")
        #expect(name([garda, garda, garda]) == "Gardasee")
    }

    /// Builds facts for a trip at one place, `perDay` photos on each day.
    func trip(_ lib: inout LibraryBuilder, _ coordinate: GeoCoordinate, from: String, to: String, perDay: Int) -> [AssetID] {
        lib.daily(from: from, to: to, at: coordinate, perDay: perDay, hour: 10)
    }

    func analysis(_ lib: LibraryBuilder, places: [(GeoCoordinate, PlaceComponents)]) -> AnalysisSnapshot {
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        let facts = lib.assets.map { a -> AssetFacts in
            guard let c = a.usableLocation else { return AssetFacts(asset: a) }
            let nearest = places.min { GeoMath.distance(c, $0.0) < GeoMath.distance(c, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
        return AnalysisSnapshot(facts: facts, trips: trips)
    }

    static let tegernseeSpot = GeoCoordinate(latitude: 47.7128, longitude: 11.7584)
    static let innsbruckSpot = GeoCoordinate(latitude: 47.2692, longitude: 11.4041)
    static let marrakeshSpot = GeoCoordinate(latitude: 31.6295, longitude: -7.9811)
    static let lisbonSpot = GeoCoordinate(latitude: 38.7223, longitude: -9.1393)
    static let sevilleSpot = GeoCoordinate(latitude: 37.3891, longitude: -5.9845)
    var places: [(GeoCoordinate, PlaceComponents)] {
        [(Fixture.Places.munichHome, Self.munich),
         (Self.tegernseeSpot, place("DE", "Deutschland", "Bayern", "Tegernsee")),
         (Self.innsbruckSpot, place("AT", "Österreich", "Tirol", "Innsbruck")),
         (Self.marrakeshSpot, place("MA", "Marokko", "Marrakesch-Safi", "Marrakesch")),
         (Self.lisbonSpot, place("PT", "Portugal", "Lissabon", "Lissabon")),
         (Self.sevilleSpot, place("ES", "Spanien", "Andalusien", "Sevilla")),
         (Fixture.Places.rome, place("IT", "Italien", "Latium", "Rom"))]
    }

    /// Two photos a day at home, except on the days of the trips (`away`): day trips come home
    /// in the evening, longer trips do not.
    func everydayLibrary(away: [(String, String)] = []) -> LibraryBuilder {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 2, hour: 18, skipping: away)
        return lib
    }

    @Test func countriesSeenOnOneTripAreThatTripsAlbum() {
        var lib = everydayLibrary(away: [("2025-05-03", "2025-05-12"), ("2025-09-06", "2025-09-15"), ("2026-03-01", "2026-03-05")])
        _ = trip(&lib, Self.marrakeshSpot, from: "2025-05-03", to: "2025-05-12", perDay: 8)
        _ = trip(&lib, Self.lisbonSpot, from: "2025-09-06", to: "2025-09-10", perDay: 8)
        _ = trip(&lib, Self.sevilleSpot, from: "2025-09-11", to: "2025-09-15", perDay: 8)
        let proposals = germanEngine().proposals(for: analysis(lib, places: places))
        let titles = Set(proposals.map(\.title))
        // Ten days in one town are named after the town, five and five days in two towns after both.
        #expect(titles == ["Marrakesch, Mai 2025", "Lissabon & Sevilla, September 2025"], "\(titles)")
        // No country or town album beside them (not even with towns switched on), nothing for home.
        let withCities = germanEngine { $0.places.includesCities = true }.proposals(for: analysis(lib, places: places))
        #expect(Set(withCities.map(\.title)) == titles)
        // A second trip to Morocco: now the country is more than one trip.
        _ = trip(&lib, Self.marrakeshSpot, from: "2026-03-01", to: "2026-03-05", perDay: 8)
        let later = germanEngine().proposals(for: analysis(lib, places: places))
        #expect(later.contains { $0.title == "Marokko" && $0.folderPath == ["Länder"] })
    }

    @Test func aRejectedTripStillStandsForItsCountry() throws {
        var lib = everydayLibrary(away: [("2025-05-03", "2025-05-12")])
        _ = trip(&lib, Self.marrakeshSpot, from: "2025-05-03", to: "2025-05-12", perDay: 8)
        let a = analysis(lib, places: places)
        let trip = try #require(germanEngine().proposals(for: a).first { $0.kind == .trip })
        let rejected = germanEngine().proposals(for: a, overrides: OverrideSet([UserOverride(scope: .source(trip.id), decision: .rejectProposal)]))
        #expect(!rejected.contains { $0.title.hasPrefix("Marokko") })
    }

    @Test func routineDayTripsBecomeOneAlbum() throws {
        var lib = everydayLibrary()
        for day in ["2025-05-04", "2025-06-08", "2025-07-13", "2025-08-17"] {
            _ = trip(&lib, Self.tegernseeSpot, from: day, to: day, perDay: 12)
        }
        let a = analysis(lib, places: places)
        let proposals = germanEngine().proposals(for: a)
        #expect(!proposals.contains { $0.kind == .trip })
        let album = try #require(proposals.first { $0.title == "Tegernsee" })
        #expect(album.assetIDs.count == 48)
        #expect(album.folderPath == ["Reisen"])
        #expect(album.reasons.contains(.recurringPlace(count: 48, days: 4)))
        // Without place albums for repeated trips, they stay trips.
        let plain = germanEngine { $0.trips.placeCollectionForRepeatedTrips = false }.proposals(for: a)
        #expect(plain.filter { $0.kind == .trip }.count == 4)
    }

    /// Lived in Hamburg until June 2024, in Munich since, back in Hamburg every two months: the
    /// Hamburg album holds the visits, not a year and a half of everyday life there.
    @Test func aFormerHomeTownHoldsTheVisitsNotTheYearsThere() throws {
        let hamburgSpot = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
        let weekends = [("2024-11-09", "2024-11-10"), ("2025-01-11", "2025-01-12"), ("2025-03-08", "2025-03-09"),
                        ("2025-05-10", "2025-05-11"), ("2025-07-12", "2025-07-13"), ("2025-09-13", "2025-09-14")]
        var lib = LibraryBuilder()
        lib.daily(from: "2023-01-01", to: "2024-06-30", at: hamburgSpot, perDay: 2, hour: 18)
        lib.daily(from: "2024-07-01", to: "2025-10-31", at: Fixture.Places.munichHome, perDay: 2, hour: 18, skipping: weekends)
        var visits: [AssetID] = []
        for (from, to) in weekends { visits += lib.daily(from: from, to: to, at: hamburgSpot, perDay: 6, hour: 10) }
        let a = analysis(lib, places: places + [(hamburgSpot, place("DE", "Deutschland", "Hamburg", "Hamburg"))])
        let proposals = germanEngine().proposals(for: a)
        let album = try #require(proposals.first { $0.title == "Hamburg" && $0.folderPath == ["Reisen"] }, "\(proposals.map(\.title))")
        // Before 15.11.: 1,166 photos, the visits and every photo from the years in Hamburg.
        #expect(album.assetIDs.subtracting(visits).isEmpty, "\(album.assetIDs.subtracting(visits).count) photos from the years there")
        #expect(album.assetIDs.count == visits.count)
    }

    /// New York, then Tokyo: the last photo, at 8 in the morning in Tokyo on 1 June, was still
    /// 31 May in New York. The trip ended in June.
    @Test func aTripEndsOnTheDateWhereItEnded() throws {
        let newYork = GeoCoordinate(latitude: 40.7128, longitude: -74.0060)
        let tokyo = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)
        let stops: [(GeoCoordinate, PlaceComponents, [String])] = [
            (newYork, PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten", administrativeArea: "New York", locality: "New York",
                                      timeZoneIdentifier: "America/New_York"),
             ["2025-05-26 14:00", "2025-05-27 14:00", "2025-05-28 14:00"]),
            (tokyo, PlaceComponents(isoCountryCode: "JP", country: "Japan", administrativeArea: "Tokio", locality: "Tokio",
                                    timeZoneIdentifier: "Asia/Tokyo"),
             ["2025-05-30 01:00", "2025-05-31 01:00", "2025-05-31 21:40"]), // the last at 8:00 on 1 June in Tokyo
        ]
        var facts: [AssetFacts] = []
        for (coordinate, place, mornings) in stops {
            for morning in mornings {
                for i in 0..<5 {
                    let asset = AssetSnapshot(id: AssetID(String(format: "t-%03d", facts.count)),
                                              creationDate: Fixture.date(morning).addingTimeInterval(Double(i) * 1_200), location: coordinate)
                    facts.append(AssetFacts(asset: asset, place: place, placeSource: .gpsReverseGeocoded))
                }
            }
        }
        let start = try #require(facts.first?.asset.creationDate)
        let end = try #require(facts.last?.asset.creationDate)
        let trip = Trip(id: SortlyID("ny-tokyo"), start: start, end: end, geotaggedAssetIDs: facts.map(\.id), inferredAssetIDs: [],
                        centroid: tokyo, maxDistanceFromHomeMeters: 9_000_000, distinctStops: 2, kind: .vacation)
        let proposals = germanEngine { $0.enabledAreas = [.trips] }.proposals(for: AnalysisSnapshot(facts: facts, trips: [trip]))
        #expect(proposals.map(\.title) == ["New York & Tokio, Mai–Juni 2025"])
    }

    @Test func twoDayTripsAreTwoTripsNotThreeAlbums() {
        var lib = everydayLibrary()
        _ = trip(&lib, Self.innsbruckSpot, from: "2025-05-04", to: "2025-05-04", perDay: 15)
        _ = trip(&lib, Self.innsbruckSpot, from: "2026-08-02", to: "2026-08-02", perDay: 15)
        let proposals = germanEngine().proposals(for: analysis(lib, places: places))
        // Two visits are no routine yet: no "Innsbruck" album beside the trips. Austria now
        // stands for two trips, so it is a country album (holding both).
        #expect(Set(proposals.map(\.title)) == ["Innsbruck, 4. Mai 2025", "Innsbruck, 2. August 2026", "Österreich"])
    }

    @Test func tripsWithTheSameTitleNameTheirDays() {
        var lib = everydayLibrary(away: [("2025-05-02", "2025-05-05"), ("2025-05-20", "2025-05-24")])
        _ = trip(&lib, Fixture.Places.rome, from: "2025-05-02", to: "2025-05-05", perDay: 8)
        _ = trip(&lib, Fixture.Places.rome, from: "2025-05-20", to: "2025-05-24", perDay: 8)
        let titles = Set(germanEngine().proposals(for: analysis(lib, places: places)).filter { $0.kind == .trip }.map(\.title))
        #expect(titles == ["Rom, 2.–5. Mai 2025", "Rom, 20.–24. Mai 2025"])
    }

    @Test func theOldDefaultTemplateFollowsTheNewOne() {
        var lib = everydayLibrary(away: [("2025-05-02", "2025-05-05")])
        _ = trip(&lib, Fixture.Places.rome, from: "2025-05-02", to: "2025-05-05", perDay: 8)
        let a = analysis(lib, places: places)
        let stored = germanEngine { $0.trips.template = .tripDateRange }.proposals(for: a)
        #expect(stored.contains { $0.title == "Rom, Mai 2025" })
        let chosen = germanEngine { $0.trips.template = .tripYearFirst }.proposals(for: a)
        #expect(chosen.contains { $0.title == "2025 – Rom" })
    }

    @Test func aBurstIsOneMoment() {
        var lib = everydayLibrary()
        let burst = (0..<25).map { i in
            lib.photo(at: Fixture.date("2025-05-04 12:00").addingTimeInterval(Double(i) * 0.3), Self.innsbruckSpot)
        }
        _ = trip(&lib, Self.innsbruckSpot, from: "2025-05-04", to: "2025-05-04", perDay: 4)
        let assets = lib.assets.map { a -> AssetSnapshot in
            var a = a
            if burst.contains(a.id) { a.burstIdentifier = "jump"; a.subtypes.insert(.burst) }
            return a
        }
        let a = analysis(lib, places: places)
        let facts = a.facts.map { f -> AssetFacts in
            var f = f
            f.asset = assets.first { $0.id == f.id } ?? f.asset
            return f
        }
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: facts, trips: a.trips))
        // 29 photos, but 5 moments: no trip of its own.
        #expect(!proposals.contains { $0.kind == .trip })
    }

    @Test func screenshotsAndDocumentsAreNotTwoAlbumsOfTheSameThing() {
        let texts = (0..<12).map { _ in "Amazon\nBestellung aufgegeben\nBestellnummer 302-1234567\nLieferung Donnerstag\nSendungsverfolgung" }
            + (0..<3).map { _ in "Einstellungen\nWLAN\nBluetooth\nFehler\nError 503" }
        let facts = texts.enumerated().map { i, text -> AssetFacts in
            let asset = AssetSnapshot(id: AssetID(String(format: "s-%03d", i)), kind: .image, subtypes: .screenshot,
                                      creationDate: Fixture.date("2026-01-01").addingTimeInterval(Double(i) * 86_400))
            var f = AssetFacts(asset: asset)
            f.textCategories = Set(ScreenshotClassifier().classify(text: text).categories.filter { $0.value >= .plausible }.map(\.key.rawValue))
            f.document = DocumentAnalyzer().analyze(text: text)
            return f
        }
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: facts))
        #expect(proposals.map(\.title) == ["Bestellungen"])
        #expect(proposals.first?.kind == .documentCategory("order"))
        // Without the documents area, the screenshots keep them.
        let screenshotsOnly = germanEngine { $0.enabledAreas = [.screenshots] }.proposals(for: AnalysisSnapshot(facts: facts))
        #expect(screenshotsOnly.map(\.kind) == [.screenshotCategory("order")])
    }

    @Test func shortKeywordsCountAsWholeWords() {
        let classifier = ScreenshotClassifier()
        // "ust" in "Zustellung" and "August" made this an invoice.
        let order = classifier.classify(text: "Deine Bestellung\nZustellung am 3. August\nSendungsverfolgung")
        #expect(order.categories[.invoice] == nil)
        #expect(order.categories[.order] != nil)
        #expect(classifier.classify(text: "Rechnung Nr. 17\nUSt-ID DE123\nzahlbar bis 1.3.").categories[.invoice] != nil)
        // "eta" in "Details", "min" in "Admin", "km" in nothing.
        #expect(classifier.classify(text: "Produktdetails\nAdmin\nDetails ansehen").categories[.mapNavigation] == nil)
    }

    @Test func themesMustComeBack() {
        // 30 horse photos on one afternoon: an event, not a theme.
        var facts = (0..<30).map { i -> AssetFacts in
            var f = AssetFacts(asset: AssetSnapshot(id: AssetID(String(format: "h-%03d", i)), kind: .image,
                                                    creationDate: Fixture.date("2026-05-01 14:00").addingTimeInterval(Double(i) * 60)))
            f.categories = ["animal.horse": .likely]
            return f
        }
        #expect(germanEngine { $0.enabledAreas = [.imageCategories] }.proposals(for: AnalysisSnapshot(facts: facts)).isEmpty)
        // A dog on 20 days is one.
        facts += (0..<20).map { i -> AssetFacts in
            var f = AssetFacts(asset: AssetSnapshot(id: AssetID(String(format: "d-%03d", i)), kind: .image,
                                                    creationDate: Fixture.date("2026-01-01").addingTimeInterval(Double(i) * 86_400 * 3)))
            f.categories = ["animal.dog": .likely, "misc.clothing": .likely]
            return f
        }
        let themes = germanEngine { $0.enabledAreas = [.imageCategories] }.proposals(for: AnalysisSnapshot(facts: facts))
        #expect(themes.map(\.title) == ["Hunde"])
        #expect(themes.first?.folderPath == ["Themen"])
    }

    @Test func aNamedPlaceWinsOverTheSameTownAlbum() {
        var lib = everydayLibrary()
        for day in ["2025-05-04", "2025-06-08", "2025-07-13", "2025-08-17"] {
            _ = trip(&lib, Self.tegernseeSpot, from: day, to: day, perDay: 12)
        }
        let a = analysis(lib, places: places)
        let atLake = a.facts.filter { $0.place?.locality == "Tegernsee" }.map(\.id)
        let named = FrequentPlace(id: .stable("fp", "lake"), centroid: Self.tegernseeSpot, radiusMeters: 100, assetIDs: atLake.sorted(),
                                  distinctDays: 4, firstDate: Fixture.date("2025-05-04"), lastDate: Fixture.date("2025-08-17"), userName: "Unser See")
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: a.facts, trips: a.trips, frequentPlaces: [named]))
        #expect(proposals.map(\.title) == ["Unser See"])
        var unnamed = named
        unnamed.userName = nil
        let other = germanEngine().proposals(for: AnalysisSnapshot(facts: a.facts, trips: a.trips, frequentPlaces: [unnamed]))
        #expect(other.map(\.title) == ["Tegernsee"])
    }
}

// MARK: - Unusual libraries (coverage map B6–B17)

@Suite("Proposals for unusual libraries")
struct UnusualLibraryProposalTests {
    /// B6: a library of a dozen photos at home gives nothing to sort, not "Deutschland".
    @Test func tinyLibrary() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-11-01", to: "2026-11-04", at: Fixture.Places.munichHome, perDay: 3)
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: FixtureGeocoder.facts(for: lib.assets),
                                                                      trips: TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)))
        #expect(proposals.isEmpty, "\(proposals.map(\.title))")

        // Fifteen photos of one weekend in Rome and nothing else: that weekend.
        var rome = LibraryBuilder()
        rome.daily(from: "2026-05-15", to: "2026-05-17", at: Fixture.Places.rome, perDay: 5)
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: rome.assets)
        let romeProposals = germanEngine().proposals(for: AnalysisSnapshot(facts: FixtureGeocoder.facts(for: rome.assets), trips: trips))
        #expect(romeProposals.count <= 1)
        #expect(nearDuplicates(romeProposals).isEmpty)
    }

    /// B8: only screenshots: screenshot and document albums, nothing about places.
    @Test func screenshotsOnly() {
        let texts = SimulatedLibrary.screenshotTexts.flatMap { entry in
            (0..<(entry.weight / 5)).map { i in entry.texts[i % entry.texts.count] }
        }
        let facts = texts.enumerated().map { i, text -> AssetFacts in
            let asset = AssetSnapshot(id: AssetID(String(format: "s-%04d", i)), kind: .image, subtypes: .screenshot,
                                      creationDate: Fixture.date("2025-01-01").addingTimeInterval(Double(i) * 40_000))
            var f = AssetFacts(asset: asset)
            f.textCategories = Set(ScreenshotClassifier().classify(text: text).categories.filter { $0.value >= .plausible }.map(\.key.rawValue))
            f.document = DocumentAnalyzer().analyze(text: text)
            return f
        }
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: facts))
        #expect(!proposals.isEmpty)
        #expect(proposals.allSatisfy { p in
            switch p.kind { case .screenshotCategory, .documentCategory: true; default: false }
        })
        #expect(proposals.count <= 12, "\(proposals.map(\.title))")
        #expect(nearDuplicates(proposals).isEmpty)
        let minimum = max(5, facts.count / 100)
        #expect(proposals.allSatisfy { $0.assetIDs.count >= 4 && ($0.kind.area != .screenshots || $0.assetIDs.count >= minimum) })
    }

    /// B9: no location at all: no places, trips or frequent places, themes still work.
    @Test func noLocations() {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: nil, perDay: 3)
        let facts = lib.assets.enumerated().map { i, a -> AssetFacts in
            var f = AssetFacts(asset: a)
            if i % 10 == 0 { f.categories = ["nature.sunset": .likely] }
            if i % 3 == 0 { f.categories["misc.clothing"] = .likely }
            return f
        }
        let a = AnalysisSnapshot(facts: facts, trips: TripDetector(calendar: Fixture.calendar).detect(in: lib.assets),
                                 frequentPlaces: FrequentPlaceDetector(calendar: Fixture.calendar).detect(in: lib.assets))
        let proposals = germanEngine().proposals(for: a)
        #expect(proposals.map(\.title) == ["Sonnenuntergänge"])
    }

    /// B10: only videos: trips and places work the same, nothing else is made up.
    @Test func videosOnly() {
        var lib = LibraryBuilder()
        var day = Fixture.date("2025-01-01")
        while day < Fixture.date("2025-12-31") {
            _ = lib.photo(at: day.addingTimeInterval(18 * 3600), Fixture.Places.munichHome, kind: .video)
            day = day.addingTimeInterval(2 * 86_400)
        }
        for i in 0..<24 {
            _ = lib.photo(at: Fixture.date("2025-06-10 10:00").addingTimeInterval(Double(i) * 4 * 3600), Fixture.Places.rome, kind: .video)
        }
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: FixtureGeocoder.facts(for: lib.assets), trips: trips))
        #expect(proposals.map(\.title) == ["Rom, Juni 2025"])
    }

    /// B14: Live Photos and panoramas count like photos; a burst is one moment, in the counts
    /// and in the preview.
    @Test func burstsLivePhotosAndPanoramas() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: 1, hour: 18)
        for i in 0..<12 {
            _ = lib.photo(at: Fixture.date("2025-06-10 10:00").addingTimeInterval(Double(i) * 3 * 3600), Fixture.Places.rome,
                          subtypes: i % 2 == 0 ? .livePhoto : .panorama)
        }
        let burst = (0..<30).map { i in lib.photo(at: Fixture.date("2025-06-11 12:00").addingTimeInterval(Double(i) * 0.25), Fixture.Places.rome) }
        let assets = lib.assets.map { a -> AssetSnapshot in
            var a = a
            if burst.contains(a.id) { a.burstIdentifier = "b1"; a.subtypes.insert(.burst) }
            return a
        }
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: assets)
        let proposals = germanEngine().proposals(for: AnalysisSnapshot(facts: FixtureGeocoder.facts(for: assets), trips: trips))
        let trip = try #require(proposals.first { $0.kind == .trip })
        #expect(trip.assetIDs.count == 42) // the album holds every frame …
        let dates = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.creationDate!) })
        let preview = PreviewPicker.pick(trip.assetIDs, dates: dates, cover: nil, count: 8)
        #expect(preview.filter(burst.contains).count <= 1) // … the preview shows the burst once

        // Without the twelve photos, the burst alone is no trip.
        let onlyBurst = assets.filter { $0.creationDate! < Fixture.date("2025-06-10") || $0.creationDate! > Fixture.date("2025-06-12") || burst.contains($0.id) }
        let burstTrips = TripDetector(calendar: Fixture.calendar).detect(in: onlyBurst)
        let none = germanEngine().proposals(for: AnalysisSnapshot(facts: FixtureGeocoder.facts(for: onlyBurst), trips: burstTrips))
        #expect(!none.contains { $0.kind == .trip })
    }

    /// B17: the user already has an album of the trip's name with other photos. The plan
    /// makes a new album in the trip folder and leaves the user's album alone.
    @Test func titleTakenByAUserAlbumWithOtherContent() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: 1, hour: 18,
                  skipping: [("2025-05-12", "2025-05-16")])
        let rome = lib.daily(from: "2025-05-12", to: "2025-05-16", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        let proposals = germanEngine { $0.enabledAreas = [.trips] }
            .proposals(for: AnalysisSnapshot(facts: FixtureGeocoder.facts(for: lib.assets), trips: trips))
        let trip = try #require(proposals.first { $0.kind == .trip })
        #expect(trip.title == "Rom, Mai 2025")
        let others = Set(lib.assets.prefix(20).map(\.id)).subtracting(rome)
        let userAlbum = CollectionSnapshot(id: "mine", title: "Rom, Mai 2025", assetIDs: others)
        let inventory = CollectionInventory([userAlbum])
        let match = AlbumMatcher().match([trip], against: inventory)[trip.id]
        #expect(match?.status == .nameConflict)
        let decision = ProposalDecision.recommended(for: trip, match: match)
        #expect(decision == .createNew(title: nil, folderPath: nil))

        let plan = OrganizationPlanner(rootFolderTitle: "").makePlan(from: [ConfirmedProposal(proposal: trip, decision: decision)], inventory: inventory)
        let created = plan.steps.compactMap { step -> String? in
            switch step.operation {
            case .createFolder(_, let title, _): "folder \(title)"
            case .createAlbum(_, let title, _): "album \(title)"
            default: nil
            }
        }
        #expect(created == ["folder Reisen", "folder 2025", "album Rom, Mai 2025"])
        #expect(!plan.steps.contains { step in
            switch step.operation {
            case .addAssets(.existing("mine"), _), .renameCollection("mine", _, _), .moveCollection("mine", _, _), .deleteCollection("mine", _): true
            default: false
            }
        })
        #expect(plan.conflicts.isEmpty) // another folder: not even a hint
    }
}
