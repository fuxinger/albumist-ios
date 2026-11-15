import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Fake reverse geocoder for tests: maps fixture coordinates to address components.
enum FixtureGeocoder {
    static let table: [(GeoCoordinate, PlaceComponents)] = [
        (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München", timeZoneIdentifier: "Europe/Berlin")),
        (Fixture.Places.munichWork, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München", timeZoneIdentifier: "Europe/Berlin")),
        (Fixture.Places.rome, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", timeZoneIdentifier: "Europe/Rome")),
        (Fixture.Places.florence, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Toskana", locality: "Florenz", timeZoneIdentifier: "Europe/Rome")),
        (Fixture.Places.naples, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Kampanien", locality: "Neapel", timeZoneIdentifier: "Europe/Rome")),
        (Fixture.Places.gardaLake, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Venetien", locality: "Malcesine", inlandWater: "Gardasee", timeZoneIdentifier: "Europe/Rome")),
    ]

    static func facts(for assets: [AssetSnapshot]) -> [AssetFacts] {
        assets.map { a in
            guard let loc = a.usableLocation else { return AssetFacts(asset: a) }
            let nearest = table.min { GeoMath.distance(loc, $0.0) < GeoMath.distance(loc, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
    }
}

@Suite("Proposal engine")
struct ProposalEngineTests {
    func romeAnalysis() -> AnalysisSnapshot {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        lib.daily(from: "2025-09-03", to: "2025-09-08", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        return AnalysisSnapshot(facts: FixtureGeocoder.facts(for: lib.assets), trips: trips)
    }

    func engine(_ configure: (inout OrganizationSettings) -> Void = { _ in }) -> ProposalEngine {
        var s = OrganizationSettings()
        s.titleLanguage = .german
        configure(&s)
        return ProposalEngine(settings: s, calendar: Fixture.calendar)
    }

    @Test func tripsAreNamedAfterDominantCityAndFiledByYear() {
        let proposals = engine().proposals(for: romeAnalysis()).filter { $0.kind == .trip }
        #expect(proposals.count == 2)
        #expect(proposals.first?.title == "Rom · 12.05.–19.05.2024")
        #expect(proposals.first?.folderPath == ["Reisen", "2024"])
        #expect(proposals.allSatisfy { $0.reliability == .likely })
    }

    @Test func repeatedTripsGetPermanentPlaceCollection() {
        let analysis = romeAnalysis()
        let all = engine().proposals(for: analysis)
        let collection = all.first { if case .placeCollection = $0.kind, $0.folderPath == ["Reisen"] { return true } else { return false } }
        #expect(collection?.title == "Rom")
        let tripAssets = all.filter { $0.kind == .trip }.reduce(into: Set<AssetID>()) { $0.formUnion($1.assetIDs) }
        #expect(collection?.assetIDs == tripAssets)

        let without = engine { $0.trips.placeCollectionForRepeatedTrips = false }.proposals(for: analysis)
        #expect(!without.contains { $0.folderPath == ["Reisen"] })
    }

    /// Default: countries only, so a trip does not turn into four albums (usability test 14.11.2026).
    @Test func citiesAreOptInByDefault() {
        let places = engine().proposals(for: romeAnalysis()).filter { $0.kind.area == .places }
        #expect(places.contains { $0.title == "Italien" && $0.folderPath == ["Länder"] })
        #expect(!places.contains { $0.title == "München" })
        #expect(!places.contains { $0.folderPath == ["Länder", "Italien"] })
    }

    @Test func placeCollectionsAreHierarchical() {
        let places = engine { $0.places.levels = PlaceSettings.Preset.countriesAndCities.levels }
            .proposals(for: romeAnalysis()).filter { $0.kind.area == .places }
        let rome = places.first { $0.title == "Rom" }
        #expect(rome?.folderPath == ["Länder", "Italien"])
        #expect(places.contains { $0.title == "Italien" && $0.folderPath == ["Länder"] })
        #expect(places.contains { $0.title == "München" })
    }

    @Test func idsAreStableAcrossRuns() {
        let a = engine().proposals(for: romeAnalysis()).map(\.id)
        let b = engine().proposals(for: romeAnalysis()).map(\.id)
        #expect(a == b)
        #expect(Set(a).count == a.count)
    }

    @Test func disabledAreasAndRejectedProposalsProduceNothing() {
        let analysis = romeAnalysis()
        let onlyTrips = engine { $0.enabledAreas = [.trips] }.proposals(for: analysis)
        #expect(onlyTrips.allSatisfy { $0.kind.area == .trips || $0.folderPath.first == "Reisen" })
        let rejected = onlyTrips[0].id
        let filtered = engine { $0.enabledAreas = [.trips] }.proposals(
            for: analysis,
            overrides: OverrideSet([UserOverride(scope: .source(rejected), decision: .rejectProposal)])
        )
        #expect(!filtered.contains { $0.id == rejected })
    }

    @Test func peopleNeedOptInAndUnnamedGroupsNeedAName() {
        let person = ObservationGroup(id: .stable("g", "p"), kind: .person, observationIDs: ["a", "b", "c"], assetIDs: ["1", "2", "3"], confirmedName: nil, isConfirmed: false)
        let dog = ObservationGroup(id: .stable("g", "d"), kind: .dog, observationIDs: ["d", "e", "f"], assetIDs: ["4", "5", "6"], confirmedName: "Bello", isConfirmed: true)
        let analysis = AnalysisSnapshot(facts: [], groups: [person, dog])
        let defaults = engine { $0.enabledAreas = [.peopleAndPets] }.proposals(for: analysis)
        #expect(defaults.map(\.title) == ["Bello"])
        #expect(defaults[0].isSensitive && !defaults[0].requiresUserName)

        let optedIn = engine { $0.enabledAreas = [.peopleAndPets]; $0.people.faceGroupingEnabled = true }.proposals(for: analysis)
        let p = optedIn.first { $0.id == person.id }
        #expect(p?.title == "Person 1")
        #expect(p?.requiresUserName == true)
        #expect(p?.reliability == .uncertain)
    }

    @Test func frequentPlacesAreNeverNamedAutomatically() {
        let place = FrequentPlace(id: .stable("fp", "1"), centroid: Fixture.Places.munichHome, radiusMeters: 50, assetIDs: ["1", "2", "3"], distinctDays: 6, firstDate: Fixture.date("2026-01-01"), lastDate: Fixture.date("2026-03-01"), userName: nil)
        let proposals = engine { $0.enabledAreas = [.frequentPlaces] }.proposals(for: AnalysisSnapshot(facts: [], frequentPlaces: [place]))
        #expect(proposals.first?.title == "Häufiger Ort 1")
        #expect(proposals.first?.requiresUserName == true)
        #expect(proposals.first?.isSensitive == true)
    }

    @Test func englishTitles() {
        let proposals = engine { $0.titleLanguage = .english }.proposals(for: romeAnalysis())
        #expect(proposals.contains { $0.folderPath.first == "Trips" })
        #expect(proposals.contains { $0.folderPath == ["Countries"] })
    }
}

@Suite("Search")
struct SearchTests {
    func library() -> (facts: [AssetFacts], index: SearchIndex, dog: SortlyID) {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-12-01", to: "2025-12-03", at: Fixture.Places.munichHome, perDay: 2)
        lib.daily(from: "2026-05-12", to: "2026-05-14", at: Fixture.Places.rome, perDay: 3)
        _ = lib.photo(at: Fixture.date("2026-06-01 09:00"), nil, subtypes: .screenshot)
        _ = lib.photo(at: Fixture.date("2026-06-02 09:00"), Fixture.Places.gardaLake, kind: .video)
        var facts = FixtureGeocoder.facts(for: lib.assets)
        let dogID = SortlyID.stable("group", "dog")
        // A dog in two Rome photos; one invoice screenshot from Amazon.
        facts[6].categories = ["animal.dog": .likely]
        facts[6].groupIDs = [dogID]
        facts[7].categories = ["animal.dog": .plausible]
        facts[12].document = DocumentInfo(type: .invoice, typeReliability: .likely, documentDate: nil, merchant: "Amazon", orderNumber: "302-1234567", invoiceNumber: nil, totalAmount: nil, subject: nil, keywords: [], sensitivity: .normal)
        facts[12].recognizedText = "Rechnung Amazon Bestellnummer 302-1234567"
        let groups = [ObservationGroup(id: dogID, kind: .dog, observationIDs: ["o1", "o2", "o3"], assetIDs: [facts[6].id], confirmedName: "Bello", isConfirmed: true)]
        return (facts, SearchIndex(facts: facts, groups: groups, calendar: Fixture.calendar), dogID)
    }

    let now = Fixture.date("2026-11-15 12:00")

    @Test func countryAndYear() {
        let (_, index, _) = library()
        let query = index.parse("Alle Fotos aus Italien 2026", now: now)
        #expect(query.clauses.map(\.criterion) == [.country("IT"), .year(2026)])
        #expect(query.tokens.map(\.kind) == [.country, .year])
        #expect(index.search("Alle Fotos aus Italien 2026", now: now).ids.count == 10) // 9 Rome photos + Garda video
    }

    @Test func cityMonthAndMediaType() {
        let (_, index, _) = library()
        #expect(index.search("Rom Mai", now: now).ids.count == 9)
        #expect(index.search("Videos vom Gardasee", now: now).ids.count == 1)
        #expect(index.search("Screenshots", now: now).ids.count == 1)
    }

    @Test func namedGroupAndCategory() {
        let (_, index, dog) = library()
        let named = index.parse("Fotos von Bello", now: now)
        #expect(named.clauses.map(\.criterion) == [.group(dog)])
        #expect(index.search("Fotos von Bello", now: now).ids.count == 1)
        #expect(index.search("Hunde in Rom", now: now).ids.count == 2)
        #expect(index.parse("Hunde in Rom", now: now).tokens.first?.kind == .category)
    }

    @Test func documentsMerchantsAndFields() {
        let (facts, index, _) = library()
        let result = index.search("Amazon Rechnungen mit Bestellnummer", now: now)
        #expect(result.tokens.map(\.kind) == [.merchant, .document, .field])
        #expect(result.ids == [facts[12].id])
    }

    @Test func freeTextAndLocationAndStatus() {
        let (facts, index, _) = library()
        #expect(index.search("302-1234567", now: now).ids == [facts[12].id])
        let noLocation = index.parse("Fotos ohne Standort", now: now)
        #expect(noLocation.clauses.map(\.criterion) == [.hasLocation(false)])
        #expect(index.search("Fotos ohne Standort", now: now).ids.count == 1)
        let unorganized = index.parse("nicht organisiert", now: now)
        #expect(unorganized.usesStatus)
        let statuses = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, OverallStatus.fullyOrganized) })
            .merging([facts[0].id: OverallStatus.unorganized]) { $1 }
        #expect(index.search("nicht organisiert", now: now, statuses: statuses).ids == [facts[0].id])
    }

    @Test func unknownValuesNeverMatch() {
        var facts = library().facts
        facts[0].asset.creationDate = nil
        let index = SearchIndex(facts: facts, calendar: Fixture.calendar)
        #expect(!index.search("2025", now: now).ids.contains(facts[0].id))
        #expect(!index.search("Dezember", now: now).ids.contains(facts[0].id))
        #expect(index.search("", now: now).ids.isEmpty)
        #expect(index.parse("Fotos", now: now).isEmpty)
    }
}

@Suite("Cities switch")
struct CitiesSwitchTests {
    @Test func switchTurnsCityAlbumsOnAndOff() {
        var places = PlaceSettings()
        #expect(!places.includesCities)
        places.includesCities = true
        #expect(places.levels == [.country, .locality])
        places.includesCities = false
        #expect(places.levels == [.country])
    }
}
