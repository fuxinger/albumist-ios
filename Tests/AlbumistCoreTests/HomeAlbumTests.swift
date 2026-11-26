import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Review P1-10: the user's own flat came as "Häufiger Ort in München". Decision 7 (Fuchs
/// 26.11.2026, "Alles wie empfohlen"): the home gets no album unless the user asks for it
/// ("Album fürs Zuhause" in "Dein Zuhause"), names it or already chose it. Other places the
/// user is often at in the home town (a park, the gym) are still suggested.
@Suite("Review P1-10: no album for the home unless asked")
struct HomeAlbumTests {
    static let flat = Fixture.Places.munichHome
    /// The English Garden, about 2 km from the flat: inside the home radius, not the home.
    static let park = GeoCoordinate(latitude: 48.1550, longitude: 11.5900)
    static let hamburgFlat = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let munich = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")
    static let hamburg = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Hamburg", locality: "Hamburg")

    /// Two photos on each day of `days` (counted from `start`, every `every` days) at `place`.
    static func facts(_ prefix: String, at place: GeoCoordinate, town: PlaceComponents = munich, days: Int, every: Int,
                      from start: String = "2025-01-01", hour: Int = 19, atHome: Bool = true) -> [AssetFacts] {
        (0..<days * 2).map { i in
            let date = Fixture.date(start).addingTimeInterval(Double(i / 2 * every) * 86_400 + Double(hour) * 3_600 + Double(i % 2) * 60)
            let asset = AssetSnapshot(id: AssetID("\(prefix)-\(i)"), creationDate: date, location: place)
            return AssetFacts(asset: asset, place: town, placeSource: .gpsReverseGeocoded, atHome: atHome)
        }
    }

    static func place(_ id: String, at center: GeoCoordinate, _ facts: [AssetFacts]) -> FrequentPlace {
        FrequentPlace(id: AlbumistID(id), centroid: center, radiusMeters: 60, assetIDs: facts.map(\.id).sorted(),
                      distinctDays: Set(facts.map { Fixture.calendar.startOfDay(for: $0.asset.creationDate!) }).count,
                      firstDate: facts.first!.asset.creationDate!, lastDate: facts.last!.asset.creationDate!)
    }

    func frequent(_ analysis: AnalysisSnapshot, suggestHome: Bool = false, names: [AlbumistID: String] = [:]) -> [AlbumProposal] {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.frequentPlaces.suggestHome = suggestHome
        settings.frequentPlaces.names = names
        return ProposalEngine(settings: settings, calendar: Fixture.calendar).proposals(for: analysis).filter { $0.kind == .frequentPlace }
    }

    /// A year at home: photos at the flat every second day, in the park every ninth.
    static func year() -> AnalysisSnapshot {
        let home = facts("flat", at: flat, days: 180, every: 2)
        let park = facts("park", at: park, days: 40, every: 9, from: "2025-01-05")
        return AnalysisSnapshot(facts: home + park, frequentPlaces: [place("fp-flat", at: flat, home), place("fp-park", at: Self.park, park)])
    }

    /// The finding: the flat came as "Häufiger Ort in München". Now only the park comes.
    @Test func theHomeIsNotSuggestedButAParkInTheHomeTownIs() {
        let found = frequent(Self.year())
        #expect(found.map(\.id) == [AlbumistID("fp-park")], "\(found.map(\.title))")
    }

    /// "Album fürs Zuhause" on: the home comes like any frequent place.
    @Test func onRequestTheHomeIsSuggested() {
        let found = frequent(Self.year(), suggestHome: true)
        #expect(Set(found.map(\.id)) == [AlbumistID("fp-flat"), AlbumistID("fp-park")])
        #expect(found.contains { $0.title == "Häufiger Ort in München" })
    }

    /// A name the user gave the home, a suggestion they chose or an album it already has: the
    /// home stays, nothing the user did disappears.
    @Test func aHomeTheUserNamedChoseOrKeptStays() {
        let analysis = Self.year()
        let named = frequent(analysis, names: [AlbumistID("fp-flat"): "Daheim"])
        #expect(named.contains { $0.id == AlbumistID("fp-flat") && $0.title == "Daheim" })
        var chosen = analysis
        chosen.chosen = [AlbumistID("fp-flat")]
        #expect(frequent(chosen).contains { $0.id == AlbumistID("fp-flat") })
        var applied = analysis
        applied.applied = [AlbumistID("fp-flat")]
        #expect(frequent(applied).contains { $0.id == AlbumistID("fp-flat") })
    }

    /// After a move each flat is the home of its own months: neither is suggested.
    @Test func bothHomesOfAMoveAreLeftOut() {
        let hamburg = Self.facts("hh", at: Self.hamburgFlat, town: Self.hamburg, days: 90, every: 2, from: "2024-01-01")
        let munich = Self.facts("flat", at: Self.flat, days: 90, every: 2, from: "2024-07-01")
        let park = Self.facts("park", at: Self.park, days: 20, every: 9, from: "2024-07-05")
        let analysis = AnalysisSnapshot(facts: hamburg + munich + park,
                                        frequentPlaces: [Self.place("fp-hh", at: Self.hamburgFlat, hamburg),
                                                         Self.place("fp-flat", at: Self.flat, munich),
                                                         Self.place("fp-park", at: Self.park, park)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-park")])
    }

    /// A garden photographed almost daily all summer, in the afternoons: the flat is where the
    /// evenings are, so only the flat is taken for the home.
    @Test func aGardenFullOfSummerDaysIsNotTheHome() {
        let home = Self.facts("flat", at: Self.flat, days: 120, every: 3)
        let garden = Self.facts("garden", at: Self.park, days: 100, every: 1, from: "2025-05-01", hour: 14)
        let analysis = AnalysisSnapshot(facts: home + garden,
                                        frequentPlaces: [Self.place("fp-flat", at: Self.flat, home), Self.place("fp-garden", at: Self.park, garden)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-garden")])
    }

    /// Second review: the office on more days than the flat, in the daytime. Before, the place
    /// with the most days was taken (the office), and the flat came as "Häufiger Ort in München".
    @Test func theOfficeOnMoreDaysIsNotTheHome() {
        let home = Self.facts("flat", at: Self.flat, days: 60, every: 5)
        let office = Self.facts("office", at: Self.park, days: 200, every: 1, hour: 10)
        let analysis = AnalysisSnapshot(facts: home + office,
                                        frequentPlaces: [Self.place("fp-office", at: Self.park, office), Self.place("fp-flat", at: Self.flat, home)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-office")])
    }

    /// Second review: the own flat on 60 evenings, the partner's flat in the same town on 100.
    /// Which one is home is not clear: nothing is left out rather than the wrong place.
    @Test func whenTheHomeIsNotClearNothingIsLeftOut() {
        let home = Self.facts("flat", at: Self.flat, days: 60, every: 5)
        let partner = Self.facts("partner", at: Self.park, days: 100, every: 3)
        let analysis = AnalysisSnapshot(facts: home + partner,
                                        frequentPlaces: [Self.place("fp-partner", at: Self.park, partner), Self.place("fp-flat", at: Self.flat, home)])
        #expect(Set(frequent(analysis).map(\.id)) == [AlbumistID("fp-flat"), AlbumistID("fp-partner")])
        // With a clear lead (twice the evenings) the place of most evenings is home.
        let clear = Self.facts("partner", at: Self.park, days: 30, every: 10)
        let leading = AnalysisSnapshot(facts: home + clear,
                                       frequentPlaces: [Self.place("fp-flat", at: Self.flat, home), Self.place("fp-partner", at: Self.park, clear)])
        #expect(frequent(leading).map(\.id) == [AlbumistID("fp-partner")])
    }

    /// Second review: the chosen home is the town centre, the flat 9 km east and the office 24 km
    /// west (33 km apart, both at home). They are of the same home and time: one group, one home.
    @Test func placesOnBothSidesOfTheHomeAreOneGroup() {
        let east = GeoCoordinate(latitude: 48.1371, longitude: 11.5754 + 0.121)
        let west = GeoCoordinate(latitude: 48.1371, longitude: 11.5754 - 0.323)
        let home = Self.facts("flat", at: east, days: 120, every: 3)
        let office = Self.facts("office", at: west, days: 200, every: 1, hour: 10)
        // A few evenings at the office (late shifts): far behind the flat.
        let late = Self.facts("late", at: west, days: 10, every: 30, hour: 20)
        let analysis = AnalysisSnapshot(facts: home + office + late,
                                        frequentPlaces: [Self.place("fp-office", at: west, office + late), Self.place("fp-flat", at: east, home)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-office")])
    }

    /// Third review: a move within the town, and a park visited in the afternoons for all those
    /// years. Each flat is judged in its own years: both are left out, the park stays; also
    /// when the user goes back to the old flat once later.
    @Test func aMoveWithinTheTownLeavesOutBothFlats() {
        let newFlat = GeoCoordinate(latitude: 48.1650, longitude: 11.5754)
        let old = Self.facts("old", at: Self.flat, days: 365, every: 4, from: "2019-01-01")
        let new = Self.facts("new", at: newFlat, days: 300, every: 4, from: "2023-01-03")
        let park = Self.facts("park", at: Self.park, days: 280, every: 9, from: "2019-01-05", hour: 14)
        let places = [Self.place("fp-old", at: Self.flat, old), Self.place("fp-new", at: newFlat, new), Self.place("fp-park", at: Self.park, park)]
        #expect(frequent(AnalysisSnapshot(facts: old + new + park, frequentPlaces: places)).map(\.id) == [AlbumistID("fp-park")])
        let revisit = Self.facts("visit", at: Self.flat, days: 1, every: 1, from: "2025-06-01")
        let withVisit = [Self.place("fp-old", at: Self.flat, old + revisit), places[1], places[2]]
        #expect(frequent(AnalysisSnapshot(facts: old + revisit + new + park, frequentPlaces: withVisit)).map(\.id) == [AlbumistID("fp-park")])
    }

    /// Third review: a former home in New York is judged on New York's clock, not the
    /// calendar's (Berlin): lunch at the office there is no evening.
    @Test func eveningsAreOnTheClockOfThePlace() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let nyFlat = GeoCoordinate(latitude: 40.7300, longitude: -73.9900)
        let nyOffice = GeoCoordinate(latitude: 40.7500, longitude: -73.9800)
        func there(_ facts: [AssetFacts]) -> [AssetFacts] { facts.map { var f = $0; f.timeZone = newYork; return f } }
        // 12:00 and 19:00 in New York (the helper's hours are UTC in the fixture calendar).
        let office = there(Self.facts("office", at: nyOffice, days: 200, every: 1, hour: 17))
        let home = there(Self.facts("flat", at: nyFlat, days: 60, every: 5, hour: 24))
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        var berlin = Fixture.calendar
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let analysis = AnalysisSnapshot(facts: office + home,
                                        frequentPlaces: [Self.place("fp-office", at: nyOffice, office), Self.place("fp-flat", at: nyFlat, home)])
        let found = ProposalEngine(settings: settings, calendar: berlin).proposals(for: analysis).filter { $0.kind == .frequentPlace }
        #expect(found.map(\.id) == [AlbumistID("fp-office")])
    }

    /// Third review: a home split in two clusters 170 m apart: both parts are left out.
    @Test func aHomeSplitInTwoClustersIsLeftOutWhole() {
        let part = GeoCoordinate(latitude: 48.1386, longitude: 11.5754)
        let a = Self.facts("a", at: Self.flat, days: 180, every: 2)
        let b = Self.facts("b", at: part, days: 60, every: 6)
        let park = Self.facts("park", at: Self.park, days: 40, every: 9, hour: 14)
        let analysis = AnalysisSnapshot(facts: a + b + park, frequentPlaces: [Self.place("fp-a", at: Self.flat, a), Self.place("fp-b", at: part, b),
                                                                              Self.place("fp-park", at: Self.park, park)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-park")])
    }

    /// Fourth review: places next door with evenings of their own (a café, a partner's flat
    /// 250 m away) are no part of the home; nor does a place with one evening make a café
    /// easier to take for the home.
    @Test func neighboursWithEveningsOfTheirOwnStay() {
        let nextDoor = GeoCoordinate(latitude: 48.1394, longitude: 11.5754)
        let home = Self.facts("flat", at: Self.flat, days: 180, every: 2)
        let cafe = Self.facts("cafe", at: nextDoor, days: 30, every: 7, from: "2025-01-02")
        let partner = Self.facts("partner", at: nextDoor, days: 80, every: 3, from: "2025-01-02")
        for (name, other) in [("fp-cafe", cafe), ("fp-partner", partner)] {
            let analysis = AnalysisSnapshot(facts: home + other,
                                            frequentPlaces: [Self.place("fp-flat", at: Self.flat, home), Self.place(name, at: nextDoor, other)])
            #expect(frequent(analysis).map(\.id) == [AlbumistID(name)])
        }
        // A café with a third of the evenings at home, the flat no frequent place: shown, also
        // with a place far off in town that has one evening in its time.
        let alone = Self.facts("cafe", at: Self.park, days: 40, every: 9)
        let town = (0..<80).map { i -> AssetFacts in
            let spot = GeoCoordinate(latitude: 48.10 + Double(i % 40) * 0.002, longitude: 11.50 + Double(i / 40) * 0.01)
            let date = Fixture.date("2025-01-01").addingTimeInterval(Double(i) * 4 * 86_400 + 20 * 3_600)
            let asset = AssetSnapshot(id: AssetID("town-\(i)"), creationDate: date, location: spot)
            return AssetFacts(asset: asset, place: Self.munich, placeSource: .gpsReverseGeocoded, atHome: true)
        }
        let far = GeoCoordinate(latitude: 48.30, longitude: 11.70)
        let weak = Self.facts("weak", at: far, days: 5, every: 1, from: "2024-03-01") + Self.facts("weak-b", at: far, days: 1, every: 1, from: "2025-06-01")
        let analysis = AnalysisSnapshot(facts: alone + town + weak,
                                        frequentPlaces: [Self.place("fp-cafe", at: Self.park, alone), Self.place("fp-weak", at: far, weak)])
        #expect(frequent(analysis).contains { $0.id == AlbumistID("fp-cafe") })
    }

    /// "Kein Zuhause" (no photo is at home) or a place away from home: nothing is left out.
    @Test func withoutAHomeNothingIsLeftOut() {
        let home = Self.facts("flat", at: Self.flat, days: 180, every: 2, atHome: false)
        let analysis = AnalysisSnapshot(facts: home, frequentPlaces: [Self.place("fp-flat", at: Self.flat, home)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-flat")])
    }

    /// The only place at home with few evenings among many evenings at home elsewhere in town
    /// (a favourite café, the flat itself never a frequent place): not taken for the home. At
    /// the boundary: a quarter of the evenings at home in its time is enough.
    @Test func aPlaceWithFewOfTheDaysAtHomeIsNotTheHome() {
        let cafe = Self.facts("cafe", at: Self.park, days: 30, every: 12)
        // Photos all over town on most days, never twice at the same spot.
        let town = (0..<300).map { i -> AssetFacts in
            let spot = GeoCoordinate(latitude: 48.10 + Double(i % 50) * 0.002, longitude: 11.50 + Double(i / 50) * 0.01)
            let date = Fixture.date("2025-01-01").addingTimeInterval(Double(i) * 86_400 + 20 * 3_600)
            let asset = AssetSnapshot(id: AssetID("town-\(i)"), creationDate: date, location: spot)
            return AssetFacts(asset: asset, place: Self.munich, placeSource: .gpsReverseGeocoded, atHome: true)
        }
        let analysis = AnalysisSnapshot(facts: cafe + town, frequentPlaces: [Self.place("fp-cafe", at: Self.park, cafe)])
        #expect(frequent(analysis).map(\.id) == [AlbumistID("fp-cafe")])
        // Few evenings elsewhere: the café, the only place, holds over half of them and is taken
        // for the home.
        let fewer = AnalysisSnapshot(facts: cafe + town.prefix(20), frequentPlaces: [Self.place("fp-cafe", at: Self.park, cafe)])
        #expect(frequent(fewer).isEmpty)
    }

    /// The homes left out are named in the suggestions: their photos do not count as unsorted.
    @Test func theHomesLeftOutAreNamed() {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let found = ProposalEngine(settings: settings, calendar: Fixture.calendar).suggestions(for: Self.year())
        #expect(found.homePlaces == [AlbumistID("fp-flat")])
        settings.frequentPlaces.suggestHome = true
        #expect(ProposalEngine(settings: settings, calendar: Fixture.calendar).suggestions(for: Self.year()).homePlaces.isEmpty)
    }
}
