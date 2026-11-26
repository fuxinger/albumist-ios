import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Boundary values for every list and every filter, without the UI (rebuild stage 3, decided by
/// the owner 26.11.2026, "alles wie empfohlen").
///
/// Why: on the iPhone (Build 41, 26.11.) "Nicht sortiert" held 3,348 photos and the viewer said
/// "1 von 3.000": the last 348 could not be reached. No test found it, because the demo library has
/// 246 photos and the stress run looks at times, not counts. Here each list the app shows is made
/// from libraries of 0, 1, 2,999, 3,000, 3,001, 10,000 and 50,000 photos (the grid's page is
/// 3,000, the stress pass 10,000, the weekly one 50,000), and each must hold every photo it should,
/// up to the last one: no hidden cap, no page lost at a page's edge.
///
/// What a list should hold is counted here by hand from the facts (one plain filter per list), not
/// taken from the code under test.
@Suite("Lists at boundary sizes")
struct ListBoundaryTests {
    /// 0 and 1, both sides of the grid's page of 3,000, the stress pass and the weekly pass.
    static let sizes = [0, 1, 2_999, 3_000, 3_001, 10_000, 50_000]
    static let resolver = OrganizationStatusResolver(primaryAreas: [.places, .trips])
    static let calendar = Fixture.calendar

    /// `count` photos, newest first by id order reversed, all in 2020 in Munich, every one a dog
    /// photo; one in ten has no state yet, the rest a state of every kind the areas tell apart.
    static func library(_ count: Int) -> [AssetFacts] {
        let start = Fixture.date("2020-01-01").timeIntervalSinceReferenceDate
        let categories = ImageTaxonomy.categories(from: [("dog", 0.95)])
        return (0..<count).map { i in
            // Spread over the year 2020 (about 10 min apart at 50,000), every date different.
            let date = Date(timeIntervalSinceReferenceDate: start + Double(i) * 600)
            var asset = AssetSnapshot(id: AssetID(String(format: "edge-%06d", i)), creationDate: date)
            asset.location = GeoCoordinate(latitude: 48.137, longitude: 11.575)
            var f = AssetFacts(asset: asset)
            f.place = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")
            f.placeSource = .gpsReverseGeocoded
            f.categories = categories
            f.keywords = ["dog"]
            return f
        }
    }

    static let statuses: [AreaStatus] = [.organized, .preExisting, .proposed, .unorganized, .notApplicable, .analysisPending]

    static func states(for facts: [AssetFacts]) -> [AssetID: AssetOrganizationState] {
        var states: [AssetID: AssetOrganizationState] = [:]
        for (i, f) in facts.enumerated() where i % 10 != 9 {
            var areas: [OrganizationArea: AreaStatus] = [.places: statuses[i % statuses.count], .trips: statuses[(i / 7) % statuses.count]]
            if i % 13 == 0 { areas = areas.mapValues { _ in .ignored } }
            if i % 29 == 0 { areas = areas.mapValues { _ in .excluded } }
            states[f.id] = AssetOrganizationState(assetID: f.id, areas: areas, isUncertain: i % 11 == 0)
        }
        return states
    }

    /// Every area of the library tab holds every photo it should, newest first, the oldest last;
    /// "Alle" holds all of them. The scope filter ("Nur 2026" and the like) leaves the photos
    /// outside it out of "Sortiert" and "Nicht sortiert" only.
    @Test(arguments: sizes)
    func everyLibraryAreaHoldsEveryPhoto(count: Int) throws {
        let facts = Self.library(count)
        let states = Self.states(for: facts)
        let newestFirst = facts.sorted { $0.asset.creationDate! > $1.asset.creationDate! }
        for scoped in [false, true] {
            // In scope: the first half of the year (an "only this part" filter at a boundary too).
            let middle = Fixture.date("2020-07-01")
            let inScope: (AssetFacts) -> Bool = { scoped ? $0.asset.creationDate! < middle : true }
            let buckets = try #require(LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver, inScope: inScope))
            #expect(buckets[.all].count == count, "Alle, \(count) photos")
            #expect(buckets[.all].last?.id == newestFirst.last?.id, "Alle reaches the oldest photo")
            for bucket in InboxBucket.allCases {
                let expected = newestFirst.filter { f in
                    guard let state = states[f.id] else { return bucket == .all }
                    return Self.resolver.buckets(state, inScope: inScope(f)).contains(bucket)
                }.map(\.id)
                let got = buckets[bucket].map(\.id)
                #expect(got.count == expected.count, "\(bucket), \(count) photos, scoped \(scoped)")
                #expect(got.elementsEqual(expected), "\(bucket), \(count) photos, scoped \(scoped): same photos in the same order")
            }
            if count >= 3_000 {
                #expect(buckets[.unorganized].count > 0 && buckets[.ignored].count > 0 && buckets[.organized].count > 0,
                        "the large libraries fill the areas, so the counts above are not vacuous")
            }
        }
    }

    /// Ignoring every photo of a full area at once, and bringing them back, moves all of them,
    /// including the ones beyond the first 3,000.
    @Test(arguments: sizes)
    func ignoringAWholeAreaMovesEveryPhoto(count: Int) throws {
        let facts = Self.library(count)
        let old = Self.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: old, resolver: Self.resolver))
        let area = buckets[.unorganized].map(\.id)
        var new = old
        for id in area { new[id]?.areas = (old[id]?.areas ?? [:]).mapValues { _ in .ignored } }
        let ignored = buckets.updating(area, to: new, resolver: Self.resolver)
        #expect(ignored[.unorganized].isEmpty, "\(count) photos: nothing left in Nicht sortiert")
        #expect(ignored[.ignored].count == buckets[.ignored].count + area.count)
        let back = ignored.updating(area, to: old, resolver: Self.resolver)
        #expect(Bool(back == buckets), "\(count) photos: bringing them back restores every area")
    }

    /// The full-screen viewer reaches every photo of a list by swiping, from the first to the last
    /// and back, and opens on the last one directly; the window stays small.
    @Test(arguments: sizes)
    func viewerReachesEveryPhoto(count: Int) {
        var window = PageWindow(around: 0, count: count)
        guard count > 0 else {
            #expect(window.range.isEmpty)
            return
        }
        var reached = 0
        for index in 0..<count {
            window = window.following(index, count: count)
            #expect(window.range.contains(index))
            #expect(window.range.count <= 2 * PageWindow.radius + 1)
            reached += 1
        }
        #expect(reached == count)
        #expect(window.range.upperBound == count, "the last photo's window ends at the end of the list")
        for index in stride(from: count - 1, through: 0, by: -1) {
            window = window.following(index, count: count)
            if !window.range.contains(index) { Issue.record("swiping back, photo \(index) of \(count) not in the window"); break }
        }
        #expect(PageWindow(around: count - 1, count: count).range.contains(count - 1))
        #expect(PageWindow(around: count + 5, count: count).range.contains(count - 1), "an index past the end opens on the last photo")
    }

    /// The search gives every hit, not a first page: a place, a subject and a year each match
    /// every photo, and "Als Album anlegen" and the count use all of them (`SearchResult.ids`).
    /// The best hits above the grid stay a few.
    @Test(arguments: sizes)
    func searchGivesEveryHit(count: Int) {
        let facts = Self.library(count)
        let index = SearchIndex(facts: facts, calendar: Self.calendar)
        for query in ["München", "Hund", "2020", "Hund München 2020"] {
            let result = index.search(query, now: SearchLab.now)
            #expect(result.ids.count == count, "\"\(query)\", \(count) photos")
            #expect(Set(result.ids).count == result.ids.count, "\"\(query)\": every hit once")
            if count > 0 { #expect(result.ids.last == facts.first?.id, "\"\(query)\": the oldest photo is the last hit") }
            #expect(result.top.count <= 6)
        }
        #expect(index.search("Paris", now: SearchLab.now).ids.isEmpty, "a place with no photo matches none")
    }

    /// A country's photos on the map: every photo, all in the one year, none lost.
    @Test(arguments: sizes)
    func countryPhotosHoldEveryPhoto(count: Int) {
        let facts = Self.library(count)
        let germany = CountryPhotos.collect(countryCode: "DE", facts: facts, calendar: Self.calendar)
        #expect(germany.photoCount == count)
        #expect(germany.years.reduce(0) { $0 + $1.photos.count } == count)
        #expect(germany.years.map(\.year) == (count > 0 ? [2020] : []))
        #expect(CountryPhotos.collect(countryCode: "IT", facts: facts, calendar: Self.calendar).photoCount == 0)
    }

    /// The tab "Alben": every album in its list, Albumist's and the user's, and an album of
    /// `count` photos keeps all of them.
    @Test(arguments: sizes)
    func albumListsHoldEveryAlbum(count: Int) {
        let photos = Set(Self.library(min(count, 3_001)).map(\.id))
        let albums = (0..<count).map { CollectionSnapshot(id: CollectionID("album-\($0)"), title: "Album \($0)", assetIDs: $0 == 0 ? photos : []) }
        let own = albums.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let managed = own.map {
            ManagedAlbumState(albumID: $0.id, sourceID: AlbumistID("s-\($0.id.rawValue)"), lastKnownTitle: $0.title,
                              lastKnownParentID: nil, lastKnownMembers: $0.assetIDs, addedByAlbumist: $0.assetIDs, createdByAlbumist: true)
        }
        let sections = AlbumTabSections(inventory: CollectionInventory(albums), managed: managed)
        #expect(sections.fromAlbumist.count == own.count)
        #expect(sections.yours.count == count - own.count)
        #expect(Set((sections.fromAlbumist + sections.yours).map(\.id)).count == count, "every album once")
        if count > 0 {
            #expect(sections.fromAlbumist.first(where: { $0.id == "album-0" })?.assetIDs.count == photos.count)
            // Titles sort as Finder does ("Album 10" after "Album 9"): the user's last album is
            // the highest number not divisible by 3.
            let last = (0..<count).last { $0 % 3 != 0 }
            #expect(sections.yours.last?.title == last.map { "Album \($0)" }, "the list reaches the last album")
        }
    }
}
