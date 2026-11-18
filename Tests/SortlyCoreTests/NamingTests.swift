import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Naming and dates")
struct NamingTests {
    let de = DateRangeFormatter(language: .german, timeZone: Fixture.utc)

    /// A blank name is no name; spaces around a name are dropped.
    @Test func blankUserTitleIsNoName() {
        #expect(UserTitle.stored("") == nil)
        #expect(UserTitle.stored("   ") == nil)
        #expect(UserTitle.stored("\n\t ") == nil)
        #expect(UserTitle.stored(" Dahoam ") == "Dahoam")
        #expect(UserTitle.stored("Bei Oma und Opa") == "Bei Oma und Opa")
    }

    @Test func rangeFormatsMatchProductSpec() {
        #expect(de.format(start: Fixture.date("2026-08-03"), end: Fixture.date("2026-08-14")) == "03.08.–14.08.2026")
        #expect(de.format(start: Fixture.date("2026-07-12 09:00"), end: Fixture.date("2026-07-12 18:00")) == "12.07.2026")
        #expect(de.format(start: Fixture.date("2025-12-28"), end: Fixture.date("2026-01-04")) == "28.12.2025–04.01.2026")
    }

    /// "Marokko, Mai 2025" since the first device test (15.11.); the exact days stay available.
    @Test func defaultTripTemplate() {
        let values = NamingTemplate.Values(place: "Gardasee", start: Fixture.date("2026-08-03"), end: Fixture.date("2026-08-14"))
        #expect(NamingTemplate.tripDefault.render(values, formatter: de) == "Gardasee, August 2026")
        #expect(NamingTemplate.tripDateRange.render(values, formatter: de) == "Gardasee · 03.08.–14.08.2026")
        var precise = values
        precise.preciseDates = true
        #expect(NamingTemplate.tripDefault.render(precise, formatter: de) == "Gardasee, 3.–14. August 2026")
    }

    @Test func periodsInWords() {
        let en = DateRangeFormatter(language: .english, timeZone: Fixture.utc)
        let day = (Fixture.date("2026-07-12 09:00"), Fixture.date("2026-07-12 18:00"))
        #expect(de.period(start: day.0, end: day.1) == "12. Juli 2026")
        #expect(en.period(start: day.0, end: day.1) == "12 July 2026")
        let may = (Fixture.date("2025-05-03"), Fixture.date("2025-05-12"))
        #expect(de.period(start: may.0, end: may.1) == "Mai 2025")
        #expect(en.period(start: may.0, end: may.1) == "May 2025")
        #expect(de.period(start: may.0, end: may.1, precise: true) == "3.–12. Mai 2025")
        #expect(en.period(start: may.0, end: may.1, precise: true) == "3–12 May 2025")
        let summer = (Fixture.date("2025-07-28"), Fixture.date("2025-08-09"))
        #expect(de.period(start: summer.0, end: summer.1) == "Juli–August 2025")
        #expect(de.period(start: summer.0, end: summer.1, precise: true) == "28. Juli – 9. August 2025")
        let newYear = (Fixture.date("2024-12-29"), Fixture.date("2025-01-04"))
        #expect(de.period(start: newYear.0, end: newYear.1) == "Dezember 2024 – Januar 2025")
        #expect(en.period(start: newYear.0, end: newYear.1) == "December 2024 – January 2025")
        #expect(de.period(start: newYear.0, end: newYear.1, precise: true) == "29. Dezember 2024 – 4. Januar 2025")
    }

    @Test func alternativeTemplates() {
        let values = NamingTemplate.Values(place: "Rom", country: "Italien", start: Fixture.date("2026-05-12"), end: Fixture.date("2026-05-19"))
        #expect(NamingTemplate.tripWithCountry.render(values, formatter: de) == "Italien – Rom · 12.05.–19.05.2026")
        #expect(NamingTemplate.tripMonth.render(values, formatter: de) == "Rom – Mai 2026")
        #expect(NamingTemplate.tripYearFirst.render(values, formatter: de) == "2026 – Rom")
        #expect(NamingTemplate.placeOnly.render(values, formatter: de) == "Rom")
        #expect(NamingTemplate("{place}-Roadtrip · {range}").render(.init(place: "Italien", start: Fixture.date("2026-08-03"), end: Fixture.date("2026-08-18")), formatter: de) == "Italien-Roadtrip · 03.08.–18.08.2026")
    }

    @Test func missingVariablesDropSeparators() {
        let title = NamingTemplate.tripWithCountry.render(.init(place: "Rom", start: Fixture.date("2026-05-12"), end: Fixture.date("2026-05-12")), formatter: de)
        #expect(title == "Rom · 12.05.2026")
        let noDate = NamingTemplate.tripDefault.render(.init(place: "Rom"), formatter: de)
        #expect(noDate == "Rom")
    }

    @Test func titleSanitizing() {
        #expect(AlbumTitle.sanitize("  Rom  ·  ") == "Rom")
        #expect(AlbumTitle.sanitize(String(repeating: "x", count: 300)).count == AlbumTitle.maxLength)
        #expect(AlbumTitle.tokens("Sommer-Urlaub 2026 Gardasee") == ["sommer", "urlaub", "2026", "gardasee"])
    }

    @Test func englishRange() {
        let en = DateRangeFormatter(language: .english, timeZone: Fixture.utc)
        #expect(en.format(start: Fixture.date("2026-05-12"), end: Fixture.date("2026-05-19")) == "2026-05-12–19")
    }
}

@Suite("Chronology")
struct ChronologyTests {
    let grouper = ChronologyGrouper(calendar: Fixture.calendar)
    let de = DateRangeFormatter(language: .german, timeZone: Fixture.utc)

    @Test func keysForAllGranularities() throws {
        let d = Fixture.date("2026-03-15 10:00")
        #expect(grouper.key(for: d, granularity: .decade)?.components == [2020])
        #expect(grouper.key(for: d, granularity: .year)?.components == [2026])
        #expect(grouper.key(for: d, granularity: .halfYear)?.components == [2026, 1])
        #expect(grouper.key(for: d, granularity: .quarter)?.components == [2026, 1])
        #expect(grouper.key(for: d, granularity: .month)?.components == [2026, 3])
        #expect(grouper.key(for: d, granularity: .isoWeek)?.components == [2026, 11])
        #expect(grouper.key(for: d, granularity: .day)?.components == [2026, 3, 15])
        #expect(grouper.key(for: nil, granularity: .year) == nil)
    }

    @Test func isoWeekAtYearBoundary() {
        // 2027-01-01 is a Friday → ISO week 53 of 2026.
        #expect(grouper.key(for: Fixture.date("2027-01-01"), granularity: .isoWeek)?.components == [2026, 53])
    }

    @Test func seasonsAreHemisphereAware() throws {
        let jan = Fixture.date("2026-01-10")
        let north = try #require(grouper.key(for: jan, granularity: .season, latitude: 48))
        let south = try #require(grouper.key(for: jan, granularity: .season, latitude: -33))
        #expect(de.label(for: north) == "Winter 2025/26")
        // The southern summer runs over the turn of the year, as the northern winter does (P1-04).
        #expect(de.label(for: south) == "Sommer 2025/26")
        let december = try #require(grouper.key(for: Fixture.date("2025-12-20"), granularity: .season, latitude: 48))
        #expect(december == north) // December belongs to the same winter
    }

    /// Review finding P1-04 (18.11.2026): the winter in Sydney (July 2026) was labelled
    /// "Winter 2025/26" and had the same key as the winter in Munich (January 2026).
    @Test func southernSeasonsHaveTheirOwnKeyAndLabel() throws {
        func key(_ date: String, _ latitude: Double) throws -> ChronologyKey {
            try #require(grouper.key(for: Fixture.date(date), granularity: .season, latitude: latitude))
        }
        let en = DateRangeFormatter(language: .english, timeZone: Fixture.utc)
        let sydneyWinter = try key("2026-07-15 12:00", -33.87)
        let munichWinter = try key("2026-01-15 12:00", 48.14)
        #expect(de.label(for: sydneyWinter) == "Winter 2026")
        #expect(en.label(for: sydneyWinter) == "Winter 2026")
        #expect(sydneyWinter != munichWinter)
        // The southern summer: December to February is one season, named over both years.
        let summer = try key("2025-12-20 12:00", -33.87)
        #expect(try key("2026-01-10 12:00", -33.87) == summer)
        #expect(try key("2026-02-27 12:00", -33.87) == summer)
        #expect(de.label(for: summer) == "Sommer 2025/26")
        #expect(en.label(for: summer) == "Summer 2025/26")
        // Same months, other hemisphere, other season: never the same key.
        #expect(summer != munichWinter)
        #expect(summer != (try key("2026-07-15 12:00", 48.14)))
        #expect(try key("2026-04-10 12:00", -33.87) != (try key("2026-10-10 12:00", 48.14)))
        #expect(de.label(for: try key("2026-04-10 12:00", -33.87)) == "Herbst 2026")
        // Northern keys are as before, so the ids of northern season suggestions stay.
        #expect(munichWinter == ChronologyKey(.season, [2026, 3]))
        #expect(try key("2026-07-15 12:00", 48.14) == ChronologyKey(.season, [2026, 1]))
        // No location: northern, as before.
        #expect(grouper.key(for: Fixture.date("2026-07-15 12:00"), granularity: .season) == ChronologyKey(.season, [2026, 1]))
    }

    @Test func nestedGroupingKeepsUndatedSeparate() {
        let assets = [
            AssetSnapshot(id: "a", creationDate: Fixture.date("2026-01-05")),
            AssetSnapshot(id: "b", creationDate: Fixture.date("2026-02-05")),
            AssetSnapshot(id: "c", creationDate: nil),
        ]
        let result = grouper.group(assets, levels: [.year, .month])
        #expect(result.buckets.count == 2)
        #expect(result.undated == ["c"])
        #expect(de.label(for: ChronologyKey(.month, [2026, 2])) == "Februar 2026")
    }
}
