import Foundation
import Testing
@testable import AlbumistMap

/// The words of "Reise abspielen", exactly as shown.
@Suite("Playback text")
struct PlaybackTextTests {
    @Test func theDayTitleCountsFromOneAndNamesThePlace() {
        #expect(PlaybackText.dayTitle(index: 2, of: 9, place: "Skógafoss") == "Tag 3 von 9 · Skógafoss")
        #expect(PlaybackText.dayTitle(index: 0, of: 9, place: nil) == "Tag 1 von 9")
        #expect(PlaybackText.dayTitle(index: 8, of: 9, place: "  ") == "Tag 9 von 9")
        #expect(PlaybackText.dayTitle(index: 4, of: 9, place: " Höfn\n") == "Tag 5 von 9 · Höfn")
        // Out of range: the first or last day; no days: one.
        #expect(PlaybackText.dayTitle(index: -1, of: 9, place: nil) == "Tag 1 von 9")
        #expect(PlaybackText.dayTitle(index: 12, of: 9, place: nil) == "Tag 9 von 9")
        #expect(PlaybackText.dayTitle(index: 0, of: 0, place: nil) == "Tag 1 von 1")
    }

    @Test func theDateIsTheLocalCalendarDayInGerman() {
        #expect(PlaybackText.date(LocalDay(year: 2023, month: 6, day: 14)) == "Mittwoch, 14. Juni 2023")
        #expect(PlaybackText.date(LocalDay(year: 2023, month: 6, day: 10)) == "Samstag, 10. Juni 2023")
        #expect(PlaybackText.date(LocalDay(year: 2023, month: 6, day: 18)) == "Sonntag, 18. Juni 2023")
        #expect(PlaybackText.date(LocalDay(year: 1970, month: 1, day: 1)) == "Donnerstag, 1. Januar 1970")
        #expect(PlaybackText.date(LocalDay(year: 1969, month: 12, day: 31)) == "Mittwoch, 31. Dezember 1969")
        #expect(PlaybackText.date(LocalDay(year: 2024, month: 2, day: 29)) == "Donnerstag, 29. Februar 2024")
        #expect(PlaybackText.date(LocalDay(year: 2026, month: 3, day: 2)) == "Montag, 2. März 2026")
        #expect(PlaybackText.date(LocalDay(year: 1900, month: 1, day: 1)) == "Montag, 1. Januar 1900")
        // A day out of range is the calendar's day it carries over to.
        #expect(PlaybackText.date(LocalDay(year: 2023, month: 6, day: 31)) == "Samstag, 1. Juli 2023")
    }

    @Test func theDatesWeekdayMatchesFoundationsCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "de_DE")
        let names = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
        for dayNumber in stride(from: -800, through: 25_000, by: 37) {
            let day = LocalDay(dayNumber: dayNumber)
            let date = try #require(calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)))
            let weekday = names[calendar.component(.weekday, from: date) - 1]
            #expect(PlaybackText.date(day).hasPrefix(weekday + ", "))
        }
    }

    @Test func morePhotosThanShown() {
        #expect(PlaybackText.more(dayPhotos: 49, shown: 3) == "+46")
        #expect(PlaybackText.more(dayPhotos: 4, shown: 3) == "+1")
        #expect(PlaybackText.more(dayPhotos: 3, shown: 3) == nil)
        #expect(PlaybackText.more(dayPhotos: 2, shown: 3) == nil)
        #expect(PlaybackText.more(dayPhotos: 0, shown: 0) == nil)
        #expect(PlaybackText.more(dayPhotos: 1_500, shown: 3) == "+1.497")
        #expect(PlaybackText.more(dayPhotos: 5, shown: -2) == "+5")
    }

    @Test func kilometresAreRoundedNeverMetres() {
        #expect(PlaybackText.kilometers(0) == "unter 10 km")
        #expect(PlaybackText.kilometers(850) == "unter 10 km")
        #expect(PlaybackText.kilometers(9_999) == "unter 10 km")
        #expect(PlaybackText.kilometers(10_000) == "ca. 10 km")
        #expect(PlaybackText.kilometers(14_999) == "ca. 10 km")
        #expect(PlaybackText.kilometers(15_000) == "ca. 20 km")
        #expect(PlaybackText.kilometers(31_400) == "ca. 30 km")
        #expect(PlaybackText.kilometers(99_000) == "ca. 100 km")
        #expect(PlaybackText.kilometers(100_000) == "ca. 100 km")
        #expect(PlaybackText.kilometers(149_999) == "ca. 100 km")
        #expect(PlaybackText.kilometers(150_000) == "ca. 200 km")
        #expect(PlaybackText.kilometers(1_023_319) == "ca. 1.000 km")
        #expect(PlaybackText.kilometers(12_345_678) == "ca. 12.300 km")
        #expect(PlaybackText.kilometers(-5_000) == "unter 10 km")
        #expect(PlaybackText.kilometers(.nan) == "unter 10 km")
        // No text has a metre in it.
        for meters in [0.0, 1, 999, 5_000, 25_000, 250_000, 2_500_000] {
            #expect(!PlaybackText.kilometers(meters).contains(" m"))
        }
    }

    @Test func theEndCardsLine() {
        #expect(PlaybackText.summary(days: 9, photos: 412, metersOnSite: 1_023_319) == "9 Tage · 412 Fotos · ca. 1.000 km vor Ort")
        #expect(PlaybackText.summary(days: 1, photos: 1, metersOnSite: 0) == "1 Tag · 1 Foto · unter 10 km vor Ort")
        #expect(PlaybackText.summary(days: 21, photos: 12_300, metersOnSite: 42_000) == "21 Tage · 12.300 Fotos · ca. 40 km vor Ort")
        #expect(PlaybackText.summary(of: DemoTrip.iceland()) == "9 Tage · 412 Fotos · ca. 1.000 km vor Ort")
    }

    @Test func numbersHaveGermanThousandsPoints() {
        #expect(PlaybackText.grouped(0) == "0")
        #expect(PlaybackText.grouped(7) == "7")
        #expect(PlaybackText.grouped(999) == "999")
        #expect(PlaybackText.grouped(1_000) == "1.000")
        #expect(PlaybackText.grouped(12_300) == "12.300")
        #expect(PlaybackText.grouped(123_456) == "123.456")
        #expect(PlaybackText.grouped(1_234_567) == "1.234.567")
        #expect(PlaybackText.grouped(-4_500) == "-4.500")
        #expect(PlaybackText.grouped(-999) == "-999")
        #expect(PlaybackText.grouped(Int.min) == "-9.223.372.036.854.775.808")
    }
}
