import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Suggestions seen on the first real iPhone (Fuchs, 15.11.): two "Deutschland", 44
/// "Häufiger Ort N" without a name, and the same cover picture on many suggestions.
@Suite("First device test: suggestions")
struct FirstDeviceTestCoreTests {
    func engine(_ configure: (inout OrganizationSettings) -> Void = { _ in }) -> ProposalEngine {
        var s = OrganizationSettings()
        s.titleLanguage = .german
        configure(&s)
        return ProposalEngine(settings: s, calendar: Fixture.calendar)
    }

    func facts(_ count: Int, from start: Int, _ place: PlaceComponents) -> [AssetFacts] {
        (0..<count).map { i in
            let asset = AssetSnapshot(id: AssetID(String(format: "a-%05d", start + i)), kind: .image,
                                      creationDate: Fixture.date("2026-03-01").addingTimeInterval(Double(start + i) * 3600),
                                      location: Fixture.Places.munichHome)
            return AssetFacts(asset: asset, place: place, placeSource: .gpsReverseGeocoded)
        }
    }

    /// Everyday photos in Austria: Germany is a country visited, not where the user lives
    /// (that country gets no album of its own).
    var livingInAustria: [AssetFacts] {
        facts(250, from: 1_000, PlaceComponents(isoCountryCode: "AT", country: "Österreich", administrativeArea: "Wien", locality: "Wien"))
    }

    @Test func aCountryWithAndWithoutItsCodeIsOneSuggestion() {
        let withCode = facts(40, from: 0, PlaceComponents(isoCountryCode: "DE", country: "Deutschland"))
        let withoutCode = facts(12, from: 100, PlaceComponents(country: "Deutschland"))
        let proposals = engine { $0.enabledAreas = [.places] }.proposals(for: AnalysisSnapshot(facts: withCode + withoutCode + livingInAustria))
        let germany = proposals.filter { $0.title == "Deutschland" }
        #expect(germany.count == 1)
        #expect(germany.first?.assetIDs.count == 52)
        // The larger group keeps its id, so a decision made before stays with it.
        #expect(germany.first?.id == .stable("place", "country:de"))
        #expect(germany.first?.placeKeys.first == PlaceKey(level: .country, path: "de"))
    }

    @Test func townsOfTheSameNameStaySeparate() {
        let a = facts(20, from: 0, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "Neustadt"))
        let b = facts(20, from: 100, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Hessen", locality: "Neustadt"))
        let proposals = engine { $0.enabledAreas = [.places]; $0.places.levels = [.country, .locality] }
            .proposals(for: AnalysisSnapshot(facts: a + b + livingInAustria))
        #expect(proposals.filter { $0.title == "Neustadt" }.count == 2)
    }

    @Test func onlyTheMostVisitedUnnamedPlacesAreOfferedAndNamedByTown() {
        var places: [FrequentPlace] = []
        var all: [AssetFacts] = []
        for i in 0..<12 {
            let town = i < 3 ? "München" : "Augsburg"
            let members = facts(6, from: i * 10, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", locality: town))
            all += members
            places.append(FrequentPlace(id: .stable("fp", "\(i)"), centroid: Fixture.Places.munichHome, radiusMeters: 50,
                                        assetIDs: members.map(\.id), distinctDays: 20 - i,
                                        firstDate: Fixture.date("2026-01-01"), lastDate: Fixture.date("2026-03-01"), userName: nil))
        }
        // A place the user named is always kept, even far down the list.
        places[11].userName = "Garten"
        let proposals = engine { $0.enabledAreas = [.frequentPlaces] }
            .proposals(for: AnalysisSnapshot(facts: all, frequentPlaces: places))
        #expect(proposals.count == ProposalEngine.maxUnnamedFrequentPlaces + 1)
        #expect(proposals.contains { $0.title == "Garten" && !$0.requiresUserName })
        let titles = Set(proposals.map(\.title))
        #expect(titles.isSuperset(of: ["Häufiger Ort in München", "Häufiger Ort in München 2", "Häufiger Ort in München 3",
                                       "Häufiger Ort in Augsburg", "Häufiger Ort in Augsburg 2"]))
        #expect(proposals.filter { $0.title != "Garten" }.allSatisfy { $0.requiresUserName && $0.isSensitive })
    }

    @Test func overlappingSuggestionsGetTheirOwnCover() {
        let ids = Set((0..<200).map { AssetID(String(format: "a-%05d", $0)) })
        let covers = (0..<20).compactMap { i in
            AlbumProposal(id: .stable("p", "\(i)"), kind: .frequentPlace, title: "\(i)", assetIDs: ids).coverAssetID
        }
        #expect(covers.count == 20)
        #expect(Set(covers).count >= 15)
        // The same in every run.
        let again = AlbumProposal(id: .stable("p", "3"), kind: .frequentPlace, title: "3", assetIDs: ids).coverAssetID
        #expect(again == covers[3])
        #expect(covers.allSatisfy { ids.contains($0) })
    }
}

@Suite("First device test: flight bookings")
struct FlightDetectionTests {
    let classifier = ScreenshotClassifier()

    @Test func realBookingsAndBoardingPassesAreFlights() {
        let pass = classifier.classify(text: "Lufthansa Boarding Pass\nFlight LH 1234\nGate B12 Seat 14A\nDeparture 10:35\nTerminal 2")
        #expect(pass.categories[.flight] == .likely)
        let booking = classifier.classify(text: "Ihre Flugbuchung\nBuchungscode X7K2LM\nMUC → BCN\nAbflug 06:15 Ankunft 08:20")
        #expect(booking.categories[.flight] != nil)
        let ryanair = classifier.classify(text: "Ryanair\nFR 8471 Memmingen – London Stansted\nSitzplatz 17C")
        #expect(ryanair.categories[.flight] != nil)
    }

    @Test func everydayScreenshotsAreNotFlights() {
        let samples = [
            "Einstellungen\nFlugmodus\nWLAN\nBluetooth\nMobilfunk",          // Settings
            "Flugmodus  WLAN  Bluetooth  Taschenlampe  Timer",               // Control Center
            "Unser Ausflug an den Tegernsee war super! Ankunft gegen 18 Uhr", // chat
            "Navigate to the main gate, then turn left",                      // directions
            "Snowboarding Kurs ab 89 € – jetzt buchen",                       // offer
            "Onboarding abgeschlossen. Willkommen!",                          // app
            "Terminal\n$ git status\nOn branch main",                         // Mac terminal
            "Abfahrt 10:35 Gleis 7 ICE 523 Ankunft 12:10",                    // train
        ]
        for text in samples {
            #expect(classifier.classify(text: text).categories[.flight] == nil, "\(text)")
        }
    }
}

@Suite("First device test: atlas")
struct LongestTripCountryTests {
    @Test func longestTripKnowsItsCountry() {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 3)
        lib.daily(from: "2025-05-10", to: "2025-05-13", at: Fixture.Places.rome, perDay: 5, hour: 10)
        let sydney = Set(lib.daily(from: "2025-08-01", to: "2025-08-12", at: Fixture.Places.sydney, perDay: 5, hour: 10))
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        var tripOf: [AssetID: AlbumistID] = [:]
        for trip in trips { for id in trip.geotaggedAssetIDs { tripOf[id] = trip.id } }
        let facts = FixtureGeocoder.facts(for: lib.assets).map { f -> AssetFacts in
            var f = f
            f.tripID = tripOf[f.id]
            if sydney.contains(f.id) {
                f.place = PlaceComponents(isoCountryCode: "AU", country: "Australien", locality: "Sydney")
                f.placeSource = .gpsReverseGeocoded
            }
            return f
        }
        let atlas = TravelAtlas.compute(facts: facts, calendar: Fixture.calendar)
        #expect(atlas.longestTrip?.countryCode == "AU")
        #expect(atlas.longestTrip?.days == atlas.longestTripDays)
    }
}
