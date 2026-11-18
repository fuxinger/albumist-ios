import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review of 18.11.2026 (Prüfer A, G1-04; Fable P1-01 and blind second review, claim 6): two
/// frequent places whose centres rounded to the same three decimals shared one ID.
@Suite("Review 18.11.: every frequent place has its own ID")
struct FrequentPlaceIDTests {

    // MARK: G1-04 / P1-01 two frequent places, one ID

    /// One day a week (`weeks`), four photos at each centre (no jitter).
    private func frequentLibrary(_ centers: [GeoCoordinate], weeks: Range<Int> = 0..<5) -> [AssetSnapshot] {
        var lib = LibraryBuilder()
        for week in weeks {
            let date = Fixture.calendar.date(byAdding: .day, value: week * 7, to: Fixture.date("2026-01-01"))!
            for c in centers { for k in 0..<4 { _ = lib.photo(at: date.addingTimeInterval(Double(k) * 60), c, jitterMeters: 0) } }
        }
        return lib.assets
    }

    private func detect(_ assets: [AssetSnapshot]) -> [FrequentPlace] {
        FrequentPlaceDetector(calendar: Fixture.calendar).detect(in: assets)
    }

    /// The identity before 18.11.: the centre rounded to three decimals.
    private func roundedID(_ c: GeoCoordinate) -> SortlyID {
        .stable("frequent", String(format: "%.3f,%.3f", c.latitude, c.longitude))
    }

    /// Prüfer A, g104_twoPlacesInMunichShareAnID: two places 131 m apart in Munich. Before: both
    /// had the ID f799d598…, two suggestions with one ID.
    @Test func twoPlacesInMunichGetTwoIDs() {
        let a = GeoCoordinate(latitude: 48.13751, longitude: 11.57551)
        let b = GeoCoordinate(latitude: 48.13849, longitude: 11.57649)
        #expect(GeoMath.distance(a, b) > 120 && GeoMath.distance(a, b) < 140)
        let places = detect(frequentLibrary([a, b]))
        #expect(places.count == 2)
        #expect(Set(places.map(\.id)).count == 2, "ids \(places.map(\.id.rawValue))")
        let proposals = ProposalEngine(settings: OrganizationSettings(), calendar: Fixture.calendar).frequentPlaceProposals(places)
        #expect(proposals.count == 2)
        #expect(Set(proposals.map(\.id)).count == proposals.count)
    }

    /// Fable blind review, claim 6: naming one of two places 131 m apart "Garten" named both.
    @Test func aNameGivenToOnePlaceStaysWithIt() throws {
        let p1 = GeoCoordinate(latitude: 48.00051, longitude: 11.00051)
        let p2 = GeoCoordinate(latitude: 48.00149, longitude: 11.00149)
        var b = LibraryBuilder()
        for d in 0..<8 {
            let day = Fixture.date("2025-03-01").addingTimeInterval(Double(d * 5) * 86_400)
            _ = b.photo(at: day.addingTimeInterval(10 * 3600), p1, jitterMeters: 0)
            _ = b.photo(at: day.addingTimeInterval(15 * 3600), p2, jitterMeters: 0)
        }
        let places = detect(b.assets)
        #expect(places.count == 2)
        #expect(Set(places.map(\.id)).count == 2)
        var settings = OrganizationSettings()
        let garden = try #require(places.first)
        settings.frequentPlaces.names[garden.id] = "Garten"
        let proposals = ProposalEngine(settings: settings, calendar: Fixture.calendar).frequentPlaceProposals(places)
        #expect(proposals.filter { $0.title == "Garten" }.map(\.id) == [garden.id])
    }

    /// Stored names and decisions are keyed by these IDs, so a new analysis of the same library
    /// (in any order) and an analysis with more photos later give the same IDs; a place that does
    /// not share its rounded centre keeps the ID it had before this fix (no migration needed).
    @Test func idsAreStableAndUnchangedWhereTheyDidNotCollide() throws {
        let a = GeoCoordinate(latitude: 48.13751, longitude: 11.57551)
        let b = GeoCoordinate(latitude: 48.13849, longitude: 11.57649)
        let alone = GeoCoordinate(latitude: 48.1500, longitude: 11.5600)
        let assets = frequentLibrary([a, b, alone])
        let first = detect(assets)
        #expect(first.count == 3)
        let ids = Dictionary(uniqueKeysWithValues: first.map { ($0.assetIDs[0], $0.id) })
        for order in [assets.reversed(), assets.sorted { $0.id.rawValue.hashValue < $1.id.rawValue.hashValue }] {
            let again = detect(Array(order))
            #expect(Dictionary(uniqueKeysWithValues: again.map { ($0.assetIDs[0], $0.id) }) == ids)
        }
        // More weeks of photos at the same places: same IDs.
        let later = detect(frequentLibrary([a, b, alone], weeks: 0..<9))
        #expect(Dictionary(uniqueKeysWithValues: later.map { ($0.assetIDs[0], $0.id) }) == ids)

        // A place alone in its cell keeps the old ID.
        let lone = try #require(first.first { GeoMath.distance($0.centroid, alone) < 10 })
        #expect(lone.id == roundedID(lone.centroid))
        // Of the two in one cell, one keeps the old ID: decisions stored under it stay with one place.
        #expect(first.filter { $0.id == roundedID($0.centroid) }.count == 2)
    }

    /// Of two places in one cell, the one photographed first keeps the cell's old ID (the ID
    /// existed for it before the second place came), whichever has more photos now.
    @Test func thePlacePhotographedFirstKeepsTheOldID() throws {
        let older = GeoCoordinate(latitude: 48.13751, longitude: 11.57551)
        let newer = GeoCoordinate(latitude: 48.13849, longitude: 11.57649)
        var lib = LibraryBuilder()
        for week in 0..<5 {
            let date = Fixture.date("2026-01-01").addingTimeInterval(Double(week * 7) * 86_400)
            for k in 0..<4 { _ = lib.photo(at: date.addingTimeInterval(Double(k) * 60), older, jitterMeters: 0) }
        }
        for week in 0..<10 {
            let date = Fixture.date("2026-01-03").addingTimeInterval(Double(week * 7) * 86_400)
            for k in 0..<8 { _ = lib.photo(at: date.addingTimeInterval(Double(k) * 60), newer, jitterMeters: 0) }
        }
        let places = detect(lib.assets)
        let first = try #require(places.first { GeoMath.distance($0.centroid, older) < 10 })
        let second = try #require(places.first { GeoMath.distance($0.centroid, newer) < 10 })
        #expect(roundedID(first.centroid) == roundedID(second.centroid))
        #expect(first.id == roundedID(first.centroid))
        #expect(second.id != first.id)
    }
}
