import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Review of 18.11.2026 (Prüfer A, G1-04; Fable P1-01 and blind second review, claim 6): two
/// frequent places whose centres rounded to the same three decimals shared one ID. Second
/// review of the fix: a place must never take over the ID of another one (with its name,
/// "Nicht jetzt", decision and album), so a place keeps its ID by its photos, carried over from
/// the places of the previous analysis (`FrequentPlaceDetector.detect(in:previous:)`).
@Suite("Review 18.11.: every frequent place has its own ID, kept by its photos")
struct FrequentPlaceIDTests {
    /// Two places 131 m apart whose centres round to the same cell (48.138, 11.576).
    static let a = GeoCoordinate(latitude: 48.13751, longitude: 11.57551)
    static let b = GeoCoordinate(latitude: 48.13849, longitude: 11.57649)
    static let cell = "48.138,11.576"

    /// A library being built: visits of `perVisit` photos (no jitter) at a place, one a week.
    struct Library {
        var builder = LibraryBuilder()
        var assets: [AssetSnapshot] { builder.assets }
        @discardableResult
        mutating func visits(_ c: GeoCoordinate, from start: String, weeks: Range<Int>, perVisit: Int = 4, hour: Int = 10) -> [AssetID] {
            var ids: [AssetID] = []
            for week in weeks {
                let day = Fixture.date(start).addingTimeInterval(Double(week * 7) * 86_400 + Double(hour) * 3_600)
                for k in 0..<perVisit { ids.append(builder.photo(at: day.addingTimeInterval(Double(k) * 60), c, jitterMeters: 0)) }
            }
            return ids
        }
    }

    private func detect(_ assets: [AssetSnapshot], previous: [FrequentPlace] = [], radius: Double? = nil) -> [FrequentPlace] {
        var configuration = FrequentPlaceDetector.Configuration()
        if let radius { configuration.clusterRadiusMeters = radius }
        return FrequentPlaceDetector(configuration: configuration, calendar: Fixture.calendar).detect(in: assets, previous: previous)
    }

    /// The identity before 18.11.: the centre rounded to three decimals.
    private func roundedID(_ c: GeoCoordinate) -> AlbumistID {
        .stable("frequent", String(format: "%.3f,%.3f", c.latitude, c.longitude))
    }

    private func place(near c: GeoCoordinate, in places: [FrequentPlace]) -> FrequentPlace? {
        places.first { GeoMath.distance($0.centroid, c) < 10 }
    }

    // MARK: Two places, two IDs

    /// Prüfer A, g104_twoPlacesInMunichShareAnID. Before: both had the ID f799d598…, two
    /// suggestions with one ID.
    @Test func twoPlacesInMunichGetTwoIDs() {
        #expect(GeoMath.distance(Self.a, Self.b) > 120 && GeoMath.distance(Self.a, Self.b) < 140)
        var lib = Library()
        for week in 0..<5 {
            lib.visits(Self.a, from: "2026-01-01", weeks: week..<(week + 1))
            lib.visits(Self.b, from: "2026-01-01", weeks: week..<(week + 1))
        }
        let places = detect(lib.assets)
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

    /// Without a previous analysis (first run, "Analyse neu aufbauen"): a place alone in its
    /// cell has the cell's ID as before 18.11.; of two in one cell, the one the app lists first
    /// (most days, then most photos) has it, the other an ID from the cell and its first photo.
    @Test func newPlacesGetTheCellIDOrTheCellAndTheirFirstPhoto() throws {
        var lib = Library()
        let alone = GeoCoordinate(latitude: 48.1500, longitude: 11.5600)
        lib.visits(alone, from: "2026-01-01", weeks: 0..<5)
        let first = lib.visits(Self.a, from: "2026-01-01", weeks: 0..<5, hour: 9)
        lib.visits(Self.b, from: "2026-01-02", weeks: 0..<7)
        let places = detect(lib.assets)
        #expect(places.count == 3)
        let lone = try #require(place(near: alone, in: places))
        #expect(lone.id == roundedID(lone.centroid))
        let busier = try #require(place(near: Self.b, in: places))
        let other = try #require(place(near: Self.a, in: places))
        #expect(busier.id == roundedID(busier.centroid))
        #expect(other.id == .stable("frequent", Self.cell, first.min()!.rawValue))
    }

    // MARK: Carried over by photos (second review of the fix)

    /// The place the app showed under a shared ID keeps it. Before this fix, every lookup of a
    /// shared ID found the first suggestion in the detector's order (most days, then most
    /// photos): its name, decisions and album are under that ID. Here that is the place
    /// photographed second, which the rank by first photo (868bc65) gave a new ID.
    @Test func migrationThePlaceTheAppShowedKeepsASharedID() throws {
        var lib = Library()
        lib.visits(Self.a, from: "2026-01-01", weeks: 0..<5)
        lib.visits(Self.b, from: "2026-01-02", weeks: 0..<10)
        // What the version before 18.11. stored: both with the cell ID, in the detector's order.
        var stored = detect(lib.assets)
        for i in stored.indices { stored[i].id = roundedID(stored[i].centroid) }
        #expect(Set(stored.map(\.id)).count == 1)
        #expect(GeoMath.distance(stored[0].centroid, Self.b) < 10)

        for assets in [lib.assets, lib.assets.reversed()] {
            let places = detect(assets, previous: stored)
            let shown = try #require(place(near: Self.b, in: places))
            let other = try #require(place(near: Self.a, in: places))
            #expect(shown.id == roundedID(shown.centroid))
            #expect(other.id != shown.id)
        }
    }

    /// The place that had the cell's ID drops below five days (photos deleted): the other place
    /// in the cell keeps its own ID and does not take over the cell's. When the first place
    /// comes back (photos synced again), it gets the cell's ID back.
    @Test func whenTheOldestPlaceDropsOutTheOtherKeepsItsID() throws {
        var lib = Library()
        let aIDs = lib.visits(Self.a, from: "2026-01-01", weeks: 0..<8)
        lib.visits(Self.b, from: "2026-01-03", weeks: 0..<5)
        let run1 = detect(lib.assets)
        let a1 = try #require(place(near: Self.a, in: run1)), b1 = try #require(place(near: Self.b, in: run1))
        #expect(a1.id == roundedID(a1.centroid))
        // Two places, two IDs: otherwise the checks below hold for one shared ID too.
        #expect(a1.id != b1.id)

        let gone = Set(aIDs.dropFirst(8))
        let run2 = detect(lib.assets.filter { !gone.contains($0.id) }, previous: run1)
        #expect(run2.count == 1)
        #expect(run2.first?.id == b1.id)

        let run3 = detect(lib.assets, previous: run2)
        #expect(place(near: Self.a, in: run3)?.id == a1.id)
        #expect(place(near: Self.b, in: run3)?.id == b1.id)
    }

    /// Three places in one cell (closer neighbours told apart, 40 m): the second disappears;
    /// the third keeps its ID and does not move up to the second's.
    @Test func whenTheSecondOfThreeDisappearsTheThirdKeepsItsID() throws {
        let p1 = GeoCoordinate(latitude: 48.13752, longitude: 11.57552)
        let p2 = GeoCoordinate(latitude: 48.13800, longitude: 11.57600)
        let p3 = GeoCoordinate(latitude: 48.13848, longitude: 11.57648)
        var lib = Library()
        lib.visits(p1, from: "2026-01-01", weeks: 0..<8)
        let second = Set(lib.visits(p2, from: "2026-01-02", weeks: 0..<6))
        lib.visits(p3, from: "2026-01-03", weeks: 0..<5)
        let run1 = detect(lib.assets, radius: 40)
        #expect(run1.count == 3)
        #expect(Set(run1.map(\.id)).count == 3)
        let id2 = try #require(place(near: p2, in: run1)).id
        let id3 = try #require(place(near: p3, in: run1)).id

        let run2 = detect(lib.assets.filter { !second.contains($0.id) }, previous: run1, radius: 40)
        #expect(run2.count == 2)
        #expect(place(near: p3, in: run2)?.id == id3)
        #expect(!run2.contains { $0.id == id2 })
    }

    /// Older photos of the second place sync or are imported later, or the first photos of the
    /// first place are deleted: the order by first photo changes, the IDs do not.
    @Test func olderPhotosOrADeletedFirstPhotoDoNotSwapIDs() throws {
        var lib = Library()
        let aIDs = lib.visits(Self.a, from: "2026-01-01", weeks: 0..<6, perVisit: 5)
        lib.visits(Self.b, from: "2026-01-03", weeks: 0..<6)
        let run1 = detect(lib.assets)
        let a1 = try #require(place(near: Self.a, in: run1)), b1 = try #require(place(near: Self.b, in: run1))
        // Two places, two IDs: otherwise "not swapped" holds for one shared ID too.
        #expect(a1.id != b1.id)

        var imported = lib
        imported.visits(Self.b, from: "2025-11-01", weeks: 0..<4)
        let withOlder = detect(imported.assets, previous: run1)
        #expect(place(near: Self.a, in: withOlder)?.id == a1.id)
        #expect(place(near: Self.b, in: withOlder)?.id == b1.id)

        let deleted = Set(aIDs.prefix(5))
        let withoutFirst = detect(lib.assets.filter { !deleted.contains($0.id) }, previous: run1)
        #expect(place(near: Self.a, in: withoutFirst)?.id == a1.id)
        #expect(place(near: Self.b, in: withoutFirst)?.id == b1.id)
    }

    /// Stored names and decisions are keyed by these IDs: a new analysis of the same library in
    /// any order, and one with more photos later, give the same IDs; so does a first run with
    /// the input in another order.
    @Test func idsAreStableAcrossRunsInputOrderAndNewPhotos() throws {
        var lib = Library()
        let alone = GeoCoordinate(latitude: 48.1500, longitude: 11.5600)
        lib.visits(Self.a, from: "2026-01-01", weeks: 0..<5)
        lib.visits(Self.b, from: "2026-01-02", weeks: 0..<5)
        lib.visits(alone, from: "2026-01-03", weeks: 0..<5)
        func ids(_ places: [FrequentPlace]) -> [AssetID: AlbumistID] {
            Dictionary(uniqueKeysWithValues: places.map { ($0.assetIDs[0], $0.id) })
        }
        let first = detect(lib.assets)
        #expect(Set(first.map(\.id)).count == 3)
        let shuffled = lib.assets.sorted { StableHash.hex($0.id.rawValue) < StableHash.hex($1.id.rawValue) }
        #expect(ids(detect(shuffled)) == ids(first))
        #expect(ids(detect(lib.assets.reversed())) == ids(first))
        let again = detect(shuffled, previous: first)
        #expect(ids(again) == ids(first))
        var more = lib
        more.visits(Self.a, from: "2026-03-01", weeks: 0..<4)
        more.visits(Self.b, from: "2026-03-02", weeks: 0..<6)
        let later = detect(more.assets.reversed(), previous: again)
        #expect(ids(later) == ids(first))
    }

    /// The pairing rule: a place keeps the ID of the previous place it shares at least half of
    /// the smaller one's photos with; the biggest overlap first, each previous ID once. After a
    /// split, the bigger part keeps the ID; a place too different gets a new one.
    @Test func carryOverPairsByTheBiggestSharedPart() throws {
        func place(_ id: String, _ assets: [String], days: Int = 5) -> FrequentPlace {
            FrequentPlace(id: AlbumistID(id), centroid: Self.a, radiusMeters: 25, assetIDs: assets.map { AssetID($0) },
                          distinctDays: days, firstDate: Fixture.date("2026-01-01"), lastDate: Fixture.date("2026-03-01"))
        }
        let previous = [place("old", (0..<10).map { "p\($0)" })]
        // Split: 6 + 4 of the old photos, plus new ones.
        let current = [place("new-small", (6..<10).map { "p\($0)" } + ["q1"]),
                       place("new-big", (0..<6).map { "p\($0)" } + ["q2", "q3"])]
        let carried = FrequentPlaceDetector.carryOver(current, from: previous)
        #expect(carried.first { $0.assetIDs.contains("q2") }?.id == AlbumistID("old"))
        #expect(carried.first { $0.assetIDs.contains("q1") }?.id != AlbumistID("old"))
        // Shares 3 of its 10 photos with a previous place of 10: a new place.
        let different = FrequentPlaceDetector.carryOver([place("x", (7..<17).map { "p\($0)" })], from: previous)
        #expect(different.first?.id != AlbumistID("old"))
    }
}

/// Second review of the place IDs (18.11.2026): an album Albumist made for a suggestion's ID
/// stayed that suggestion's album "however much it grew", also when the ID had passed to
/// another place that shares no photo with it: the matcher offered to add the new place's
/// photos to the old place's album.
@Suite("Review 18.11.: an album of the same ID that shares no photo is not extended")
struct AssignedAlbumSharesPhotosTests {
    let matcher = AlbumMatcher()
    let place = AlbumProposal(id: AlbumistID("frequent-x"), kind: .frequentPlace, title: "Häufiger Ort in München",
                              folderPath: ["Orte"], assetIDs: ids("new", 0..<12))

    @Test func anAlbumOfTheSameIDThatSharesNoPhotoIsNotExtended() throws {
        let inventory = CollectionInventory([CollectionSnapshot(id: "a-garden", title: "Garten", assetIDs: ids("old", 0..<10))])
        let result = try #require(matcher.match([place], against: inventory, assignments: [place.id: "a-garden"])[place.id])
        #expect(result.status == .newAlbumRequired)
        #expect(result.best == nil)
    }

    /// Controls: the album the user emptied (each photo taken out by hand) stays the
    /// suggestion's album and nothing is added again; an album sharing photos grows.
    @Test func anEmptiedOrSharingAlbumStaysTheSuggestionsAlbum() throws {
        let emptied = CollectionInventory([CollectionSnapshot(id: "a-garden", title: "Garten", assetIDs: [])])
        let tookOut = OverrideSet(place.assetIDs.map { UserOverride(scope: .assetInAlbum($0, "a-garden"), decision: .neverAdd) })
        let kept = try #require(matcher.match([place], against: emptied, overrides: tookOut, assignments: [place.id: "a-garden"])[place.id])
        #expect(kept.status == .alreadyComplete)
        #expect(kept.best?.albumID == "a-garden")

        let sharing = CollectionInventory([CollectionSnapshot(id: "a-garden", title: "Garten", assetIDs: ids("new", 0..<2))])
        let grows = try #require(matcher.match([place], against: sharing, assignments: [place.id: "a-garden"])[place.id])
        #expect(grows.status == .extendable)
        #expect(grows.best?.albumID == "a-garden")
    }

    /// Second review: a plan stopped after it created the album and before it added photos
    /// leaves an empty album recorded for the suggestion. It stays the suggestion's album and
    /// the next plan fills it, instead of a second album of the same name.
    @Test func anEmptyAlbumOfAStoppedPlanIsFilled() throws {
        let empty = CollectionInventory([CollectionSnapshot(id: "a-garden", title: "Häufiger Ort in München", assetIDs: [])])
        let result = try #require(matcher.match([place], against: empty, assignments: [place.id: "a-garden"])[place.id])
        #expect(result.status == .extendable)
        #expect(result.best?.albumID == "a-garden")
    }
}
