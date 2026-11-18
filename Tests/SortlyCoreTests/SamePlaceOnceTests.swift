import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Fuchs' iPhone test of build 36 (18.11.2026): one place near Zwiesel came twice, as the
/// place the user is often at ("Bayern", 509 photos) and as the frequent place "Häufiger Ort in
/// Zwiesel" (422 photos). `suggestions` added both kinds without comparing them. The same place
/// is suggested once: as the place the user said they are often at (its album replaces the
/// trips there, `RecurringPlacePipelineTests`), unless the user already named the frequent place
/// or it already has its album.
@Suite("Fuchs 18.11.: a place the user is often at and a frequent place, the same place once")
struct SamePlaceOnceTests {
    static let zwiesel = GeoCoordinate(latitude: 49.0167, longitude: 13.2333)
    static let town = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "Zwiesel")

    /// `count` photos on `days` days, one place; `prefix` names them.
    static func facts(_ prefix: String, count: Int, from start: String = "2026-01-02") -> [AssetFacts] {
        (0..<count).map { i in
            let asset = AssetSnapshot(id: AssetID("\(prefix)-\(i)"),
                                      creationDate: Fixture.date(start).addingTimeInterval(Double(i / 4) * 7 * 86_400 + Double(i % 4) * 60),
                                      location: zwiesel)
            return AssetFacts(asset: asset, place: town, placeSource: .gpsReverseGeocoded)
        }
    }

    static func frequent(_ facts: [AssetFacts], id: String = "frequent-zwiesel") -> FrequentPlace {
        FrequentPlace(id: SortlyID(id), centroid: zwiesel, radiusMeters: 60, assetIDs: facts.map(\.id).sorted(),
                      distinctDays: Set(facts.map { Fixture.calendar.startOfDay(for: $0.asset.creationDate!) }).count,
                      firstDate: facts.first!.asset.creationDate!, lastDate: facts.last!.asset.creationDate!)
    }

    static func recurring(_ facts: [AssetFacts], id: String = "answer-zwiesel") -> RecurringPlace {
        RecurringPlace(id: SortlyID(id), center: zwiesel, name: nil, assetIDs: facts.map(\.id),
                       distinctDays: 10, firstDate: facts.first!.asset.creationDate!, lastDate: facts.last!.asset.creationDate!)
    }

    func suggestions(_ analysis: AnalysisSnapshot, names: [SortlyID: String] = [:]) -> [AlbumProposal] {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.frequentPlaces.names = names
        return ProposalEngine(settings: settings, calendar: Fixture.calendar).suggestions(for: analysis).open
            .filter { $0.kind == .frequentPlace }
    }

    static let recurringID = RecurringPlaces.proposalID(for: SortlyID("answer-zwiesel"))

    /// 422 photos of the frequent place, all of them among the 509 of the recurring place
    /// ("Bayern" and "Häufiger Ort in Zwiesel" on Fuchs' iPhone): one suggestion, the place the
    /// user said they are often at, named after its town.
    @Test func theSamePlaceIsSuggestedOnce() throws {
        let shared = Self.facts("z", count: 422)
        let around = Self.facts("y", count: 87, from: "2026-01-03")
        let analysis = AnalysisSnapshot(facts: shared + around, frequentPlaces: [Self.frequent(shared)],
                                        recurringPlaces: [Self.recurring(shared + around)])
        let found = suggestions(analysis)
        #expect(found.count == 1, "\(found.map(\.title))")
        #expect(found.first?.id == Self.recurringID)
        #expect(found.first?.title == "Zwiesel")
    }

    /// The user already named the frequent place, or it already has its album: it stays, with
    /// the user's name, and the recurring place is not suggested a second time.
    @Test func aNamedFrequentPlaceOrOneWithItsAlbumStays() throws {
        let shared = Self.facts("z", count: 422)
        let around = Self.facts("y", count: 87, from: "2026-01-03")
        var analysis = AnalysisSnapshot(facts: shared + around, frequentPlaces: [Self.frequent(shared)],
                                        recurringPlaces: [Self.recurring(shared + around)])
        let named = suggestions(analysis, names: [SortlyID("frequent-zwiesel"): "Waldhaus"])
        #expect(named.map(\.title) == ["Waldhaus"])
        analysis.applied = [SortlyID("frequent-zwiesel")]
        #expect(suggestions(analysis).map(\.id) == [SortlyID("frequent-zwiesel")])
    }

    /// Different places (no shared photo, or less than half of the smaller one): both stay.
    @Test func differentPlacesStayBoth() {
        let garden = Self.facts("g", count: 40)
        let flat = Self.facts("f", count: 60, from: "2026-01-03")
        let both = AnalysisSnapshot(facts: garden + flat, frequentPlaces: [Self.frequent(garden)], recurringPlaces: [Self.recurring(flat)])
        #expect(suggestions(both).count == 2)
        // The frequent place shares 15 of its 40 photos with the recurring one: not the same place.
        let partly = AnalysisSnapshot(facts: garden + flat, frequentPlaces: [Self.frequent(garden)],
                                      recurringPlaces: [Self.recurring(Array(garden.prefix(15)) + flat)])
        #expect(suggestions(partly).count == 2)
    }

    /// The recurring place's album was already made: it stays that place's suggestion, and an
    /// unnamed frequent place without an album is not offered for the same photos.
    @Test func aRecurringPlaceWithItsAlbumStays() throws {
        let shared = Self.facts("z", count: 422)
        let around = Self.facts("y", count: 87, from: "2026-01-03")
        var analysis = AnalysisSnapshot(facts: shared + around, frequentPlaces: [Self.frequent(shared)],
                                        recurringPlaces: [Self.recurring(shared + around)])
        analysis.applied = [Self.recurringID]
        #expect(suggestions(analysis, names: [SortlyID("frequent-zwiesel"): "Waldhaus"]).map(\.id) == [Self.recurringID])
    }
}
