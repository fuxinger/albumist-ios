import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Design wave 3, DS-21 "Unsortiert nach Tagen wie in Fotos": the tab's photos under day
/// headers, each on the day of the clock where it was taken, read as the photo view reads it;
/// the newest day first, a day's photos in the order they were taken, "Ohne Datum" last; page by
/// page from the top, a day larger than a page cut where the page ends.
@Suite("Unsorted by day")
struct InboxDaysTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// Saturday, 21 November 2026, 13:00 in Berlin.
    static let now = Fixture.date("2026-11-21 12:00")

    static func item(_ id: String, _ date: String?) -> LibraryBuckets.Item {
        LibraryBuckets.Item(id: AssetID(id), date: date.map(Fixture.date))
    }

    static func facts(_ id: String, _ date: String?, zone: TimeZone?) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: date.map(Fixture.date)), timeZone: zone)
    }

    /// Items newest first, as `LibraryBuckets` gives them, with facts on Berlin's clock.
    static func inBerlin(_ photos: [(String, String?)]) -> (items: [LibraryBuckets.Item], facts: FactsByID) {
        let items = photos.map { item($0.0, $0.1) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return (items, FactsByID(photos.map { facts($0.0, $0.1, zone: berlin) }))
    }

    static func days(_ items: [LibraryBuckets.Item], _ facts: FactsByID, home: TimeZone? = berlin,
                     words: ProposalWords = .german) throws -> InboxDays {
        try #require(InboxDays.make(items, facts: facts, homeZone: home, now: now, currentZone: berlin, words: words))
    }

    static func ids(_ section: PhotoGridSection) -> [String] {
        section.entries.map(\.id.rawValue)
    }

    // MARK: Order

    /// The newest day at the top (an inbox opens at its newest), the photos of a day in the
    /// order they were taken (as Photos and the suggestion's days show a day), "Ohne Datum"
    /// last.
    @Test func newestDayFirstEachDayInTheOrderTakenUndatedLast() throws {
        let library = Self.inBerlin([
            ("a", "2026-11-21 07:00"), ("b", "2026-11-21 09:30"), ("c", "2026-11-20 18:00"),
            ("d", "2026-10-12 10:00"), ("e", "2026-10-12 08:00"), ("f", nil), ("g", "2024-10-12 10:00"),
        ])
        let days = try Self.days(library.items, library.facts)
        #expect(days.sections.map(Self.ids) == [["a", "b"], ["c"], ["e", "d"], ["g"], ["f"]])
        #expect(days.sections.map(\.title) == ["Heute", "Gestern", "Montag, 12. Oktober", "Samstag, 12. Oktober 2024", "Ohne Datum"])
        #expect(days.sections.map(\.countText) == ["2 Fotos", "1 Foto", "2 Fotos", "1 Foto", "1 Foto"])
        #expect(days.sections.last?.id == .max)
        #expect(days.photoCount == 7)
        // Every photo once, none lost.
        #expect(Set(days.sections.flatMap(Self.ids)) == Set(library.items.map(\.id.rawValue)))
        // Each photo knows its place in the grid's order, across the days (drag to select).
        #expect(days.sections.flatMap(\.entries).map(\.position) == Array(0..<7))
    }

    @Test func theHeadersInEnglish() throws {
        let library = Self.inBerlin([("a", "2026-11-21 07:00"), ("b", "2026-11-20 18:00"), ("c", "2026-10-12 10:00"),
                                     ("d", "2024-10-12 10:00"), ("e", nil)])
        let days = try Self.days(library.items, library.facts, words: .english)
        #expect(days.sections.map(\.title) == ["Today", "Yesterday", "Monday, October 12", "Saturday, October 12, 2024", "No date"])
        #expect(days.sections.map(\.countText) == ["1 photo", "1 photo", "1 photo", "1 photo", "1 photo"])
    }

    /// A day after today (a camera clock set wrong) says its date, never "Morgen", and comes
    /// first as the newest.
    @Test func aDayAfterTodaySaysItsDate() throws {
        let library = Self.inBerlin([("late", "2026-11-22 10:00"), ("now", "2026-11-21 10:00")])
        let days = try Self.days(library.items, library.facts)
        #expect(days.sections.map(\.title) == ["Sonntag, 22. November", "Heute"])
    }

    @Test func nothingToShow() throws {
        let days = try Self.days([], FactsByID())
        #expect(days.sections.isEmpty && days.photoCount == 0)
        #expect(days.shown(forPhotos: 3_000).days == 0 && days.shown(forPhotos: 3_000).photos == 0)
        #expect(InboxDays() == days)
    }

    // MARK: The clock

    /// Each photo on the day of the clock where it was taken: 23:00 in New York on 31 January
    /// is that day, also on an iPhone set to Berlin's time (where it is 1 February already).
    @Test func aPhotoIsOnTheDayOfItsOwnClock() throws {
        let instant = "2026-02-01 04:00" // 23:00 in New York, 05:00 in Berlin
        let items = [Self.item("ny", instant), Self.item("berlin", instant)]
        let facts = FactsByID([Self.facts("ny", instant, zone: Self.newYork), Self.facts("berlin", instant, zone: Self.berlin)])
        let days = try Self.days(items, facts)
        #expect(days.sections.map(\.title) == ["Sonntag, 1. Februar", "Samstag, 31. Januar"])
        #expect(days.sections.map(Self.ids) == [["berlin"], ["ny"]])
        // Its name says the hour of that clock (read in UTC, as wall clocks are kept).
        let ny = try #require(days.sections.last?.entries.first?.wallClock)
        #expect(ny == Fixture.date("2026-01-31 23:00"))
    }

    /// A photo Albumist has no facts of yet is on its day all the same (never all under "Ohne
    /// Datum"): the date Photos keeps, on the clock its facts will get, the home clock
    /// (`PhotoTitle.zoneWithoutFacts`). When the analysis reaches it without finding a place, its
    /// facts get that clock: it stays on its day.
    @Test func aPhotoWithoutFactsIsOnItsDayAndStaysThere() throws {
        let instant = "2026-03-14 23:30" // 00:30 on 15 March in Berlin, 19:30 on 14 March in New York
        let before = try Self.days([Self.item("p", instant)], FactsByID(), home: Self.newYork)
        #expect(before.sections.map(\.title) == ["Samstag, 14. März"])
        let analysed = FactsByID([Self.facts("p", instant, zone: Self.newYork)])
        let after = try Self.days([Self.item("p", instant)], analysed, home: Self.newYork)
        #expect(after.sections.map(\.id) == before.sections.map(\.id))
        #expect(after.sections.first?.entries == before.sections.first?.entries)
        // Before an analysis kept a home clock: the iPhone's, which the first analysis keeps.
        let first = try Self.days([Self.item("p", instant)], FactsByID(), home: nil)
        #expect(first.sections.map(\.title) == ["Sonntag, 15. März"])
        let firstAnalysed = try Self.days([Self.item("p", instant)], FactsByID([Self.facts("p", instant, zone: Self.berlin)]), home: nil)
        #expect(firstAnalysed.sections.map(\.id) == first.sections.map(\.id))
    }

    /// Facts made without a zone are read on the iPhone's clock, as the photo view reads them.
    @Test func factsWithoutAZoneUseTheIPhonesClock() throws {
        let instant = "2026-03-14 23:30"
        let days = try Self.days([Self.item("p", instant)], FactsByID([Self.facts("p", instant, zone: nil)]), home: Self.newYork)
        #expect(days.sections.map(\.title) == ["Sonntag, 15. März"])
        #expect(InboxDays.clock(of: Self.facts("p", instant, zone: nil), homeZone: Self.newYork, currentZone: Self.berlin) == Self.berlin)
        #expect(InboxDays.clock(of: Self.facts("p", instant, zone: Self.tokyo), homeZone: Self.newYork, currentZone: Self.berlin) == Self.tokyo)
        #expect(InboxDays.clock(of: nil, homeZone: Self.newYork, currentZone: Self.berlin) == Self.newYork)
        #expect(InboxDays.clock(of: nil, homeZone: nil, currentZone: Self.berlin) == Self.berlin)
    }

    /// The header says the day the photo view's title says for the same photo (`PhotoTitle`,
    /// without a place its first line is the day): with facts in any zone, and without facts.
    @Test func theHeaderSaysTheDayThePhotoViewSays() throws {
        let zones = [Self.berlin, Self.newYork, Self.tokyo, TimeZone(identifier: "Pacific/Kiritimati")!]
        var generator = SplitMix(seed: 7)
        for words in [ProposalWords.german, .english] {
            for round in 0..<200 {
                // Within the last two years, a few on the latest days.
                let back = round % 10 == 0 ? Double(generator.next() % 200_000) : Double(generator.next() % 63_000_000)
                let date = Self.now.addingTimeInterval(-back)
                let zone = zones[Int(generator.next() % UInt64(zones.count))]
                let analysed = round % 3 != 0
                let home = zones[Int(generator.next() % UInt64(zones.count))]
                let facts = analysed ? AssetFacts(asset: AssetSnapshot(id: "p", creationDate: date), timeZone: zone) : nil
                let days = try #require(InboxDays.make([LibraryBuckets.Item(id: "p", date: date)], facts: FactsByID(facts.map { [$0] } ?? []),
                                                       homeZone: home, now: Self.now, currentZone: Self.berlin, words: words))
                let header = try #require(days.sections.first?.title)
                let title = PhotoTitle(facts: facts, photoDate: date, photoLocated: false, homeZone: home, now: Self.now,
                                       currentZone: Self.berlin, words: words).title
                // "Heute" and "Gestern" are read on the photo's clock in the photo view and on the
                // iPhone's here: compare the day itself near today.
                let wall = LocalTime.wallClock(date, in: InboxDays.clock(of: facts, homeZone: home, currentZone: Self.berlin))
                #expect(days.sections.first?.id == LocalTime.day(wall))
                if back > 8 * 86_400 {
                    #expect(header.hasSuffix(title), "\(header) / \(title)")
                }
            }
        }
    }

    // MARK: Paging

    /// Page by page from the top: the days up to the one that holds the last photo asked for,
    /// that one cut there (its header still counts the whole day), so a page never shows more
    /// photos than asked for, whatever one day holds (review L2). At least one photo.
    @Test func aPageShowsTheFirstPhotosAskedFor() throws {
        let photos: [(String, String?)] = [
            ("a1", "2026-11-21 07:00"), ("a2", "2026-11-21 08:00"), ("a3", "2026-11-21 09:00"),
            ("b1", "2026-11-20 07:00"), ("b2", "2026-11-20 08:00"),
            ("c1", "2026-11-19 07:00"), ("c2", "2026-11-19 08:00"), ("c3", "2026-11-19 09:00"), ("c4", "2026-11-19 10:00"),
            ("d1", nil),
        ]
        let library = Self.inBerlin(photos)
        let days = try Self.days(library.items, library.facts)
        #expect(days.sections.map(\.entries.count) == [3, 2, 4, 1])
        let expected = [0: [1, 1], 1: [1, 1], 3: [1, 3], 4: [2, 4], 5: [2, 5], 6: [3, 6], 7: [3, 7], 9: [3, 9], 10: [4, 10],
                        3_000: [4, 10]]
        for (asked, shown) in expected {
            let page = days.shown(forPhotos: asked)
            #expect([page.days, page.photos] == shown, "\(asked) photos")
        }
        // The photos shown are the first positions, without a gap, the last day cut.
        for asked in 0...11 {
            let page = days.shown(forPhotos: asked)
            let positions = days.sections.prefix(page.days).flatMap { $0.entries(below: page.photos) }.map(\.position)
            #expect(positions == Array(0..<page.photos), "\(asked) photos")
        }
        // A cut day: two of its four photos, its header counts all four.
        let page = days.shown(forPhotos: 7)
        let cut = days.sections[page.days - 1]
        #expect(cut.countText == "4 Fotos" && cut.entries(below: page.photos).map(\.id.rawValue) == ["c1", "c2"])
        #expect(PhotoGridSection.ids(of: days.sections.prefix(page.days), below: page.photos).map(\.rawValue)
                == ["a1", "a2", "a3", "b1", "b2", "c1", "c2"])
        #expect(PhotoGridSection.ids(of: days.sections).count == 10, "without a limit, all")
        #expect(InboxDays().shown(forPhotos: 3_000).days == 0 && InboxDays().shown(forPhotos: 3_000).photos == 0)
    }

    /// One day larger than a page is cut where the page ends; the next page shows more of it,
    /// and its header counts the whole day from the first page on.
    @Test func aDayLargerThanAPageIsCut() throws {
        let photos = (0..<50).map { ("p\($0)", "2026-11-21 0\($0 % 9):\(10 + $0)") as (String, String?) }
        let library = Self.inBerlin(photos)
        let days = try Self.days(library.items, library.facts)
        #expect(days.sections.count == 1)
        let first = days.shown(forPhotos: 10)
        #expect(first.days == 1 && first.photos == 10)
        #expect(days.sections[0].entries(below: first.photos).count == 10)
        #expect(days.sections[0].countText == "50 Fotos")
        #expect(days.shown(forPhotos: 20).photos == 20)
        #expect(days.shown(forPhotos: 60).photos == 50)
    }

    /// 40,000 photos of one day (an import with one wrong camera date) and 40,000 without any
    /// date: one header counting all of them, the photos 3,000 a page, page after page.
    @Test func fortyThousandPhotosOfOneDayComePageByPage() throws {
        for dated in [true, false] {
            let date = dated ? Fixture.date("2000-01-01 12:00") : nil
            let items = (0..<40_000).map { LibraryBuckets.Item(id: AssetID("p\($0)"), date: date) }
            let days = try #require(InboxDays.make(items, facts: FactsByID(), homeZone: Self.berlin, now: Self.now,
                                                   currentZone: Self.berlin))
            #expect(days.sections.count == 1)
            #expect(days.sections[0].title == (dated ? "Samstag, 1. Januar 2000" : "Ohne Datum"))
            #expect(days.sections[0].countText == "40.000 Fotos")
            var asked = 3_000
            let first = days.shown(forPhotos: asked)
            #expect(first.days == 1 && first.photos == 3_000, "dated: \(dated)")
            #expect(days.sections[0].entries(below: first.photos).count == 3_000)
            #expect(PhotoGridSection.ids(of: days.sections.prefix(first.days), below: first.photos).count == 3_000)
            var pages = 1
            while days.shown(forPhotos: asked).photos < days.photoCount {
                asked += 3_000
                pages += 1
            }
            #expect(pages == 14, "dated: \(dated)")
        }
    }

    // MARK: Scale

    /// 100,000 photos (the stress run's size and more): every photo on one day, none lost, in
    /// the order of the days; the work stops early when asked to.
    @Test func aHundredThousandPhotos() throws {
        let zones = [Self.berlin, Self.newYork, Self.tokyo]
        var generator = SplitMix(seed: 11)
        // Ten years of photos, every 500th without a date.
        let facts = (0..<100_000).map { index -> AssetFacts in
            let date = index % 500 == 0 ? nil : Self.now.addingTimeInterval(-Double(generator.next() % 315_000_000))
            return AssetFacts(asset: AssetSnapshot(id: AssetID("p\(index)"), creationDate: date), timeZone: zones[index % zones.count])
        }
        let items = facts.sorted { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
            .map { LibraryBuckets.Item(id: $0.id, date: $0.asset.creationDate) }
        let index = FactsByID(facts)
        let days = try #require(InboxDays.make(items, facts: index, homeZone: Self.berlin, now: Self.now, currentZone: Self.berlin))
        #expect(days.photoCount == 100_000)
        #expect(Set(days.sections.flatMap { $0.entries.map(\.id) }).count == 100_000)
        let numbers = days.sections.dropLast().map(\.id)
        #expect(numbers == numbers.sorted(by: >), "newest day first")
        #expect(days.sections.last?.id == .max && days.sections.last?.entries.count == 200, "„Ohne Datum“ last")
        #expect(days.sections.flatMap(\.entries).map(\.position) == Array(0..<100_000))
        #expect(days.sections.allSatisfy { section in
            let walls = section.entries.compactMap(\.wallClock).map(LocalTime.day)
            return walls.allSatisfy { $0 == section.id }
        })
        var asked = 0
        let stopped = InboxDays.make(items, facts: index, homeZone: Self.berlin, now: Self.now, currentZone: Self.berlin) {
            asked += 1
            return asked > 3
        }
        #expect(stopped == nil)
    }

    // MARK: The suggestion's days

    /// A suggestion's days keep their order, headers and photos; each photo gets its wall clock.
    @Test func aSuggestionsDaysBecomeSections() {
        let days = PhotoDays.group(["b", "a"], facts: ["a": Self.facts("a", "2026-10-12 08:00", zone: Self.berlin),
                                                       "b": Self.facts("b", "2026-10-11 08:00", zone: Self.newYork)],
                                   fallback: Self.berlin)
        let sections = PhotoGridSection.sections(days) { id in id == "a" ? Fixture.date("2026-10-12 10:00") : nil }
        #expect(sections.map(\.id) == days.map(\.id))
        #expect(sections.map(\.title) == days.map(\.title))
        #expect(sections.map(\.countText) == days.map(\.countText))
        #expect(sections.map { $0.entries.map(\.id) } == days.map(\.ids))
        #expect(sections.flatMap(\.entries).map(\.wallClock) == [nil, Fixture.date("2026-10-12 10:00")])
        #expect(sections.flatMap(\.entries).map(\.position) == [0, 1])
    }
}
