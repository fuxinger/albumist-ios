import Foundation
import Testing
@testable import AlbumistCore

/// The photo view's title (design wave 2, DS-10: "Datum und Ort als Titel", as in Apple's Photos
/// app; before: "1 von 176"). The place where the photo was taken is the title when Albumist
/// knows it, with the day and the time on the line below; without a place the day is the title
/// and the time the line below. Day and time are those of the clock where the photo was taken
/// (decision of 19.11.2026, "Ortszeit am Aufnahmeort wie Apple Fotos", `LocalTime`), the days
/// of the last week say "Heute", "Gestern" or their weekday as Photos does, and the year is left
/// out only for this year.
@Suite("Photo view: date and place as the title (DS-10)")
struct PhotoTitleTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// The instant a clock in `zone` shows as this date and time.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Saturday, 21 November 2026, 10:00 on an iPhone set to German time.
    static let now = date(2026, 11, 21, 10, 0, in: berlin)
    static let munich = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern",
                                        locality: "München", timeZoneIdentifier: "Europe/Berlin")

    static func title(_ date: Date?, zone: TimeZone? = berlin, place: PlaceComponents? = munich,
                      words: ProposalWords = .german, clock: PhotoTitle.Clock? = nil,
                      now: Date = now, current: TimeZone = berlin) -> PhotoTitle {
        PhotoTitle(date: date, zone: zone, place: place, now: now, currentZone: current, words: words, clock: clock)
    }

    // MARK: Place and day

    /// With a place: the place in the bar, the day and the time below it.
    @Test func aPlaceIsTheTitleWithTheDayAndTimeBelow() {
        let shown = Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin))
        #expect(shown.title == "München")
        #expect(shown.subtitle == "12. Oktober 2024 · 14:32")
        #expect(shown.spoken() == "München, 12. Oktober 2024, 14:32")
    }

    /// Without a place: the day is the title, the time the line below.
    @Test func withoutAPlaceTheDayIsTheTitle() {
        let shown = Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin), place: nil)
        #expect(shown.title == "12. Oktober 2024")
        #expect(shown.subtitle == "14:32")
        #expect(shown.spoken() == "12. Oktober 2024, 14:32")
    }

    /// The days of the last week as Photos says them: today, yesterday, then the weekday; a
    /// week ago and before, the date, without the year in this year.
    @Test func recentDaysSayTodayYesterdayOrTheirWeekday() {
        let cases: [(Date, String)] = [
            (Self.date(2026, 11, 21, 9, 5, in: Self.berlin), "Heute"),
            (Self.date(2026, 11, 21, 0, 0, in: Self.berlin), "Heute"),
            (Self.date(2026, 11, 20, 23, 59, in: Self.berlin), "Gestern"),
            (Self.date(2026, 11, 20, 0, 1, in: Self.berlin), "Gestern"),
            (Self.date(2026, 11, 19, 12, 0, in: Self.berlin), "Donnerstag"),
            (Self.date(2026, 11, 15, 12, 0, in: Self.berlin), "Sonntag"),
            (Self.date(2026, 11, 14, 12, 0, in: Self.berlin), "14. November"),
            (Self.date(2026, 1, 1, 12, 0, in: Self.berlin), "1. Januar"),
            (Self.date(2025, 12, 31, 12, 0, in: Self.berlin), "31. Dezember 2025"),
            (Self.date(1998, 7, 4, 12, 0, in: Self.berlin), "4. Juli 1998"),
        ]
        for (date, day) in cases {
            #expect(Self.title(date, place: nil).title == day, "\(date)")
            #expect(Self.title(date).subtitle?.hasPrefix(day + " · ") == true, "\(date)")
        }
        #expect(Self.title(Self.date(2026, 11, 21, 9, 5, in: Self.berlin)).subtitle == "Heute · 09:05")
        #expect(Self.title(Self.date(2026, 11, 20, 23, 59, in: Self.berlin), place: nil).subtitle == "23:59")
    }

    /// "Gestern" also over the turn of the year, before the year would be named.
    @Test func yesterdayWinsOverTheYear() {
        let newYear = Self.date(2027, 1, 1, 8, 0, in: Self.berlin)
        let shown = Self.title(Self.date(2026, 12, 31, 23, 30, in: Self.berlin), place: nil, now: newYear)
        #expect(shown.title == "Gestern")
        #expect(Self.title(Self.date(2026, 12, 24, 18, 0, in: Self.berlin), place: nil, now: newYear).title == "24. Dezember 2026")
        #expect(Self.title(Self.date(2026, 12, 27, 18, 0, in: Self.berlin), place: nil, now: newYear).title == "Sonntag")
    }

    /// A photo whose clock is ahead of the iPhone's (taken in Tokyo "tomorrow" by the iPhone's
    /// date, or a camera clock set wrong) gets its date, never "Morgen".
    @Test func aLaterDayGetsItsDate() {
        let shown = Self.title(Self.date(2026, 11, 22, 1, 0, in: Self.tokyo), zone: Self.tokyo, place: nil)
        #expect(shown.title == "22. November")
        #expect(shown.subtitle == "01:00")
    }

    // MARK: The clock where the photo was taken

    /// Taken in New York at 23:00 on 31 January: that day and that time on an iPhone set to
    /// German time, where it was already 05:00 on 1 February.
    @Test func dayAndTimeAreThoseOfThePlace() {
        let instant = Self.date(2025, 1, 31, 23, 0, in: Self.newYork)
        let place = PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten", administrativeArea: "New York",
                                    locality: "New York", timeZoneIdentifier: "America/New_York")
        let shown = Self.title(instant, zone: Self.newYork, place: place)
        #expect(shown.title == "New York")
        #expect(shown.subtitle == "31. Januar 2025 · 23:00")
        // Without the photo's zone (facts made without zones) the iPhone's clock counts.
        #expect(Self.title(instant, zone: nil, place: place).subtitle == "1. Februar 2025 · 05:00")
    }

    /// Today and yesterday are counted on the photo's own day against the iPhone's day: taken in
    /// New York at 23:30 on 20 November, seen in Berlin on the morning of the 21st, when it is
    /// 04:00 of the 21st in New York, it was yesterday at 23:30.
    @Test func todayAndYesterdayCompareThePhotosDayWithTheIPhonesDay() {
        let instant = Self.date(2026, 11, 20, 23, 30, in: Self.newYork)
        let shown = Self.title(instant, zone: Self.newYork, place: nil)
        #expect(shown.title == "Gestern")
        #expect(shown.subtitle == "23:30")
        // On the iPhone's own clock it was the 21st at 05:30: today.
        #expect(Self.title(instant, zone: nil, place: nil).title == "Heute")
    }

    /// Facts: the place from the photo's location or chosen by the user, never one guessed from
    /// the picture; the photo's zone from the analysis.
    @Test func factsGiveDatePlaceAndZone() {
        let instant = Self.date(2025, 1, 31, 23, 0, in: Self.newYork)
        let asset = AssetSnapshot(id: AssetID("a"), creationDate: instant)
        let place = PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten", locality: "New York")
        let located = AssetFacts(asset: asset, place: place, placeSource: .gpsReverseGeocoded, timeZone: Self.newYork)
        let shown = PhotoTitle(facts: located, now: Self.now, currentZone: Self.berlin)
        #expect(shown.title == "New York")
        #expect(shown.subtitle == "31. Januar 2025 · 23:00")
        let chosen = AssetFacts(asset: asset, place: place, placeSource: .userAssigned, timeZone: Self.newYork)
        #expect(PhotoTitle(facts: chosen, now: Self.now, currentZone: Self.berlin).title == "New York")
        let guessed = AssetFacts(asset: asset, place: place, placeSource: .contentInferred, timeZone: Self.newYork)
        #expect(PhotoTitle(facts: guessed, now: Self.now, currentZone: Self.berlin).title == "31. Januar 2025")
        let unresolved = AssetFacts(asset: asset, place: place, placeSource: .gpsUnresolved)
        #expect(PhotoTitle(facts: unresolved, now: Self.now, currentZone: Self.berlin).subtitle == "05:00")
    }

    // MARK: What is not known

    /// Without a capture date: the place alone, or "Ohne Datum"; without anything Albumist
    /// knows of the photo (not analyzed yet): "Foto". The words are the catalog's.
    @Test func whatIsNotKnownIsLeftOut() {
        let placeOnly = Self.title(nil)
        #expect(placeOnly.title == "München")
        #expect(placeOnly.subtitle == nil)
        #expect(placeOnly.spoken() == "München")
        let nothing = Self.title(nil, place: nil)
        #expect(nothing.title == "Ohne Datum")
        #expect(nothing.subtitle == nil)
        #expect(Self.title(nil, place: nil, words: .english).title == "No date")
        let unknown = PhotoTitle(facts: nil, now: Self.now, currentZone: Self.berlin)
        #expect(unknown.title == "Foto")
        #expect(unknown.subtitle == nil)
        #expect(PhotoTitle(facts: nil, now: Self.now, currentZone: Self.berlin, words: .english).title == "Photo")
        let undated = AssetFacts(asset: AssetSnapshot(id: AssetID("b")))
        #expect(PhotoTitle(facts: undated, now: Self.now, currentZone: Self.berlin).title == "Ohne Datum")
    }

    @Test func theWordsAreTheCatalogs() throws {
        let catalog = try StringCatalogTests.catalog()
        for german in ["Foto", "Ohne Datum"] {
            let entry = try #require(catalog[german], "\(german) is not in the catalog")
            let english = (StringCatalogTests.localization(entry, "en")?["stringUnit"] as? [String: Any])?["value"] as? String
            let ours = german == "Foto" ? PhotoTitle(facts: nil, now: Self.now, currentZone: Self.berlin, words: .english).title
                : Self.title(nil, place: nil, words: .english).title
            #expect(english == ours, "\(german): the catalog says \(english ?? "nothing")")
        }
    }

    // MARK: The place's name

    /// The town; on the water the lake or sea; else the region; else the country. Neither a
    /// district nor a street, and never an empty name.
    @Test func thePlaceIsTheTownElseTheWaterRegionOrCountry() {
        #expect(PhotoTitle.placeName(Self.munich) == "München")
        let lake = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Lombardei", inlandWater: "Gardasee")
        #expect(PhotoTitle.placeName(lake) == "Gardasee")
        let sea = PlaceComponents(ocean: "Nordsee")
        #expect(PhotoTitle.placeName(sea) == "Nordsee")
        let offline = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Toskana")
        #expect(PhotoTitle.placeName(offline) == "Toskana")
        let country = PlaceComponents(isoCountryCode: "IS", country: "Island")
        #expect(PhotoTitle.placeName(country) == "Island")
        let blank = PlaceComponents(isoCountryCode: "IS", country: "Island", locality: "  ")
        #expect(PhotoTitle.placeName(blank) == "Island")
        let district = PlaceComponents(country: "Deutschland", administrativeArea: "Bayern", subAdministrativeArea: "Landkreis Miesbach",
                                       subLocality: "Altstadt", thoroughfare: "Marienplatz")
        #expect(PhotoTitle.placeName(district) == "Bayern")
        #expect(PhotoTitle.placeName(PlaceComponents(isoCountryCode: "DE")) == nil)
        #expect(PhotoTitle.placeName(nil) == nil)
        // A place without a name is no place: the day is the title.
        #expect(Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin), place: PlaceComponents(isoCountryCode: "DE")).title
            == "12. Oktober 2024")
    }

    /// Long names stay whole in the model (the bar shortens them on screen, VoiceOver reads them
    /// whole), also as a country ("Vereinigte Staaten") and in English.
    @Test func longPlaceNamesStayWhole() {
        let long = "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch"
        let welsh = PlaceComponents(isoCountryCode: "GB", country: "Vereinigtes Königreich", administrativeArea: "Wales", locality: long)
        let shown = Self.title(Self.date(2023, 8, 14, 16, 5, in: Self.berlin), place: welsh)
        #expect(shown.title == long)
        #expect(shown.spoken() == "\(long), 14. August 2023, 16:05")
        let states = PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten")
        let american = Self.title(Self.date(2023, 8, 14, 16, 5, in: Self.berlin), place: states, words: .english)
        #expect(american.title == "Vereinigte Staaten")
        #expect(american.subtitle == "August 14, 2023 · 4:05\u{202F}PM")
        let named = "Sankt Wolfgang im Salzkammergut"
        let austria = PlaceComponents(isoCountryCode: "AT", country: "Österreich", locality: named)
        #expect(Self.title(Self.date(2023, 8, 14, 16, 5, in: Self.berlin), place: austria).title == named)
    }

    // MARK: English and the clock

    /// English as the app's English says dates ("October 12, 2024", `ProposalWords`), with the
    /// iPhone's 12-hour clock by default and the 24-hour clock when the iPhone uses it.
    @Test func englishSaysTheDayInItsOwnWords() {
        let place = PlaceComponents(isoCountryCode: "DE", country: "Germany", locality: "Munich")
        let older = Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin), place: place, words: .english)
        #expect(older.title == "Munich")
        #expect(older.subtitle == "October 12, 2024 · 2:32\u{202F}PM")
        #expect(older.spoken() == "Munich, October 12, 2024, 2:32\u{202F}PM")
        let words = ProposalWords.english
        #expect(Self.title(Self.date(2026, 11, 21, 9, 5, in: Self.berlin), place: nil, words: words).title == "Today")
        #expect(Self.title(Self.date(2026, 11, 20, 9, 5, in: Self.berlin), place: nil, words: words).title == "Yesterday")
        #expect(Self.title(Self.date(2026, 11, 18, 9, 5, in: Self.berlin), place: nil, words: words).title == "Wednesday")
        #expect(Self.title(Self.date(2026, 3, 12, 9, 5, in: Self.berlin), place: nil, words: words).title == "March 12")
        #expect(Self.title(Self.date(2026, 3, 12, 9, 5, in: Self.berlin), place: nil, words: words).subtitle == "9:05\u{202F}AM")
        let british = Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin), place: place,
                                 words: ProposalWords(language: .english, region: "GB"), clock: .twentyFourHour)
        #expect(british.subtitle == "October 12, 2024 · 14:32")
    }

    /// Midnight and noon on the 12-hour clock, and the 12-hour clock in German when the iPhone
    /// is set to it.
    @Test func theTwelveHourClock() {
        #expect(Self.title(Self.date(2024, 10, 12, 0, 5, in: Self.berlin), place: nil, words: .english).subtitle == "12:05\u{202F}AM")
        #expect(Self.title(Self.date(2024, 10, 12, 12, 0, in: Self.berlin), place: nil, words: .english).subtitle == "12:00\u{202F}PM")
        #expect(Self.title(Self.date(2024, 10, 12, 23, 59, in: Self.berlin), place: nil, words: .english).subtitle == "11:59\u{202F}PM")
        #expect(Self.title(Self.date(2024, 10, 12, 0, 5, in: Self.berlin), place: nil).subtitle == "00:05")
        #expect(Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin), place: nil, clock: .twelveHour).subtitle == "2:32\u{202F}PM")
    }

    /// Photos taken before 2001 (the reference date of the wall clocks) keep their day and time.
    @Test func oldPhotosKeepTheirDayAndTime() {
        let shown = Self.title(Self.date(1987, 3, 2, 7, 45, in: Self.berlin), place: nil)
        #expect(shown.title == "2. März 1987")
        #expect(shown.subtitle == "07:45")
    }

    /// A Live Photo says so after the title and the line (VoiceOver reads it with the photo).
    @Test func aLivePhotoSaysSo() {
        let shown = Self.title(Self.date(2024, 10, 12, 14, 32, in: Self.berlin))
        #expect(shown.spoken(live: true) == "München, 12. Oktober 2024, 14:32, Live Photo")
    }
}
