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
        all(analysis, names: names).open.filter { $0.kind == .frequentPlace }
    }

    func all(_ analysis: AnalysisSnapshot, names: [SortlyID: String] = [:], rejected: [SortlyID] = []) -> Suggestions {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.frequentPlaces.names = names
        let overrides = OverrideSet(rejected.map { UserOverride(scope: .source($0), decision: .rejectProposal) })
        return ProposalEngine(settings: settings, calendar: Fixture.calendar).suggestions(for: analysis, overrides: overrides)
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
        // The frequent place's photos are not lost: the recurring place's album stands for them.
        let standIn = all(analysis).standIns.first { $0.dropped == SortlyID("frequent-zwiesel") }
        #expect(standIn?.suggestion == Self.recurringID)
        #expect(standIn?.reason == .samePhotos)
        #expect(standIn?.assetIDs == Set(shared.map(\.id)))
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
    /// unnamed frequent place without an album is not offered for the same photos. A frequent
    /// place the user named is theirs too: both stay (second review of build 36).
    @Test func aRecurringPlaceWithItsAlbumStays() throws {
        let shared = Self.facts("z", count: 422)
        let around = Self.facts("y", count: 87, from: "2026-01-03")
        var analysis = AnalysisSnapshot(facts: shared + around, frequentPlaces: [Self.frequent(shared)],
                                        recurringPlaces: [Self.recurring(shared + around)])
        analysis.applied = [Self.recurringID]
        #expect(suggestions(analysis).map(\.id) == [Self.recurringID])
        #expect(Set(suggestions(analysis, names: [SortlyID("frequent-zwiesel"): "Waldhaus"]).map(\.id))
                == [SortlyID("frequent-zwiesel"), Self.recurringID])
    }

    /// Second review of build 36: a name typed in the app is stored under the suggestion
    /// (`user.titles`), not in the settings; a suggestion the user chose ("Erstellen" ticked) is
    /// as good as named. The pipeline puts both into `chosen`: the frequent place stays.
    @Test func aFrequentPlaceTheUserChoseOrTitledStays() {
        let shared = Self.facts("z", count: 422)
        let around = Self.facts("y", count: 87, from: "2026-01-03")
        var analysis = AnalysisSnapshot(facts: shared + around, frequentPlaces: [Self.frequent(shared)],
                                        recurringPlaces: [Self.recurring(shared + around)])
        analysis.chosen = [SortlyID("frequent-zwiesel")]
        #expect(suggestions(analysis).map(\.id) == [SortlyID("frequent-zwiesel")])
        // The user chose the recurring place too: neither choice is taken away.
        analysis.chosen = [SortlyID("frequent-zwiesel"), Self.recurringID]
        #expect(Set(suggestions(analysis).map(\.id)) == [SortlyID("frequent-zwiesel"), Self.recurringID])
        // A recurring place the user chose is not hidden by a frequent place they named.
        analysis.chosen = [Self.recurringID]
        #expect(Set(suggestions(analysis, names: [SortlyID("frequent-zwiesel"): "Waldhaus"]).map(\.id))
                == [SortlyID("frequent-zwiesel"), Self.recurringID])
    }

    /// "Nicht jetzt" on the recurring place ("Bayern"): the frequent place for the same photos
    /// comes back, it is not hidden by a suggestion the user said no to. The other way round
    /// too: a named frequent place the user said no to does not hide the recurring place.
    @Test func aRejectedPlaceHidesNoOther() {
        let shared = Self.facts("z", count: 422)
        let around = Self.facts("y", count: 87, from: "2026-01-03")
        let analysis = AnalysisSnapshot(facts: shared + around, frequentPlaces: [Self.frequent(shared)],
                                        recurringPlaces: [Self.recurring(shared + around)])
        let noToBayern = all(analysis, rejected: [Self.recurringID])
        #expect(noToBayern.open.filter { $0.kind == .frequentPlace }.map(\.id) == [SortlyID("frequent-zwiesel")])
        #expect(noToBayern.dismissed.map(\.id) == [Self.recurringID])
        let noToWaldhaus = all(analysis, names: [SortlyID("frequent-zwiesel"): "Waldhaus"], rejected: [SortlyID("frequent-zwiesel")])
        #expect(noToWaldhaus.open.filter { $0.kind == .frequentPlace }.map(\.id) == [Self.recurringID])
        #expect(noToWaldhaus.dismissed.map(\.id) == [SortlyID("frequent-zwiesel")])
    }

    /// Two recurring places over one named frequent place ("Waldhaus", 100 photos): one of 60
    /// photos without an album, one of 40 with its album. The named place and the album stay;
    /// before, both the name and the 60 photos went (only the album of 40 was left).
    @Test func twoRecurringPlacesOverOneNamedPlaceLoseNoPhotos() {
        let first = Self.facts("a", count: 60), second = Self.facts("b", count: 40, from: "2026-01-03")
        let second50 = Self.facts("c", count: 50, from: "2026-01-03"), first50 = Self.facts("d", count: 50)
        let r1 = SortlyID("answer-1"), r2 = SortlyID("answer-2")
        for (one, two) in [(first, second), (first50, second50)] {
            var analysis = AnalysisSnapshot(facts: one + two, frequentPlaces: [Self.frequent(one + two)],
                                            recurringPlaces: [Self.recurring(one, id: r1.rawValue), Self.recurring(two, id: r2.rawValue)])
            analysis.applied = [RecurringPlaces.proposalID(for: r2)]
            let found = suggestions(analysis, names: [SortlyID("frequent-zwiesel"): "Waldhaus"])
            #expect(Set(found.map(\.id)) == [SortlyID("frequent-zwiesel"), RecurringPlaces.proposalID(for: r2)])
            #expect(found.reduce(into: Set<AssetID>()) { $0.formUnion($1.assetIDs) } == Set((one + two).map(\.id)))
        }
    }

    /// A favourite spot (30 photos) inside a large place the user is often at (a holiday area,
    /// 509 photos): a place of its own. The same place needs at least half of the larger one's
    /// photos in common, as Fuchs' 422 of 509 have.
    @Test func aSmallSpotInsideABigPlaceStays() {
        let spot = Self.facts("s", count: 30)
        let area = Self.facts("y", count: 479, from: "2026-01-03")
        let analysis = AnalysisSnapshot(facts: spot + area, frequentPlaces: [Self.frequent(spot)],
                                        recurringPlaces: [Self.recurring(spot + area)])
        #expect(Set(suggestions(analysis).map(\.id)) == [SortlyID("frequent-zwiesel"), Self.recurringID])
    }

    /// At most five unnamed frequent places are offered. One of them is the same place as a
    /// recurring place and goes: the sixth comes in its place, so five are still offered.
    @Test func theCapCountsThePlacesThatAreShown() {
        let covered = Self.facts("z", count: 100)
        var places = [Self.frequent(covered, id: "frequent-0")]
        var facts = covered
        for n in 1...5 {
            let own = Self.facts("p\(n)", count: 90 - n, from: "2026-01-0\(n + 2)")
            facts += own
            places.append(Self.frequent(own, id: "frequent-\(n)"))
        }
        let analysis = AnalysisSnapshot(facts: facts, frequentPlaces: places, recurringPlaces: [Self.recurring(covered)])
        let found = suggestions(analysis)
        #expect(Set(found.map(\.id)) == Set((1...5).map { SortlyID("frequent-\($0)") } + [Self.recurringID]))
    }
}
