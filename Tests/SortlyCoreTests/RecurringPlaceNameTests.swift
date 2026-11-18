import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Fuchs' iPhone test of build 36 (18.11.2026): a place the user is often at ("Bist du hier
/// öfter?") was named "Bayern": the vacation rule names after a town only when 60 % of the
/// photos are in it, else after the state. "Bayern ist aber ein Bundesland in Deutschland und
/// nenne Stadt." A recurring place is one place: it is named after a town.
@Suite("Fuchs 18.11.: a recurring place is named after a town, not the state")
struct RecurringPlaceNameTests {
    static func town(_ name: String) -> PlaceComponents {
        PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: name)
    }

    /// Reviewer test (50/30/20 % in three neighbouring towns gave "Bayern"), calling the naming
    /// that `recurringPlaceProposals` uses.
    @Test func recurringPlaceSpreadOverNeighbourTownsGetsATownNotTheState() {
        let places = Array(repeating: Self.town("Dorfen"), count: 50) + Array(repeating: Self.town("Taufkirchen"), count: 30)
            + Array(repeating: Self.town("Isen"), count: 20)
        let (name, key) = ProposalEngine.recurringPlaceName(places, labels: Labels(.german))
        #expect(name == "Dorfen", "got \(name ?? "nil")")
        #expect(key?.level == .locality)
    }

    /// The same through the suggestion: title and place key are the main town's.
    @Test func recurringPlaceSuggestionIsNamedAfterItsMainTown() throws {
        var facts: [AssetFacts] = []
        for (i, name) in (Array(repeating: "Taufkirchen", count: 4) + Array(repeating: "Dorfen", count: 5) + Array(repeating: "Isen", count: 3)).enumerated() {
            let asset = AssetSnapshot(id: AssetID("r\(i)"), creationDate: Fixture.date("2026-05-01").addingTimeInterval(Double(i) * 86_400),
                                      location: Fixture.Places.munichHome)
            facts.append(AssetFacts(asset: asset, place: Self.town(name), placeSource: .gpsReverseGeocoded))
        }
        let place = RecurringPlace(id: SortlyID("answer"), center: Fixture.Places.munichHome, name: nil, assetIDs: facts.map(\.id),
                                   distinctDays: 12, firstDate: Fixture.date("2026-05-01"), lastDate: Fixture.date("2026-05-12"))
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let proposal = try #require(ProposalEngine(settings: settings, calendar: Fixture.calendar).recurringPlaceProposals([place], facts: facts).first)
        #expect(proposal.title == "Dorfen")
        #expect(proposal.placeKeys.map(\.level) == [.locality])
    }

    /// What stays as it was: a lake names the place ("Gardasee"), and without any town the
    /// region or country is the name (better than "Unbekannter Ort").
    @Test func aLakeOrNoTownAtAllKeepsTheOtherNames() {
        let lake = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Venetien", locality: "Malcesine", inlandWater: "Gardasee")
        #expect(ProposalEngine.recurringPlaceName(Array(repeating: lake, count: 5), labels: Labels(.german)).0 == "Gardasee")
        let noTown = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern")
        #expect(ProposalEngine.recurringPlaceName(Array(repeating: noTown, count: 5), labels: Labels(.german)).0 == "Bayern")
        #expect(ProposalEngine.recurringPlaceName([], labels: Labels(.german)).0 == nil)
    }

    /// Trips keep their naming (not the same case: a trip through several towns of a state
    /// away from home is a trip "Bayern"; checked 18.11.).
    @Test func tripsThroughSeveralTownsOfAStateKeepTheStateName() {
        let places = Array(repeating: Self.town("Dorfen"), count: 50) + Array(repeating: Self.town("Taufkirchen"), count: 30)
            + Array(repeating: Self.town("Isen"), count: 20)
        let (name, _, _) = ProposalEngine.primaryPlaceName(places, kind: .vacation, labels: Labels(.german))
        #expect(name == "Bayern")
    }
}
