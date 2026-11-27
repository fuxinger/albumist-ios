import Foundation
import Testing
@testable import AlbumistCore

/// The place's name, the short form for a narrow bar, and English (`PhotoTitleTests`).
extension PhotoTitleTests {
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

    // MARK: A short form for a narrow bar (review D, L1)

    /// On a narrow iPhone the line below the place was cut, and what was cut was the time. The
    /// short form says the day in numbers (German) or with the month's short name (English), so
    /// the time always shows; today, yesterday and the weekdays are short already and stay.
    /// VoiceOver reads the long form.
    @Test func theShortFormKeepsTheTime() {
        let older = Self.title(Self.date(2024, 9, 30, 14, 32, in: Self.berlin))
        #expect(older.shortTitle == "München")
        #expect(older.shortSubtitle == "30.09.2024 · 14:32")
        #expect(older.spoken() == "München, 30. September 2024, 14:32")
        #expect(Self.title(Self.date(2026, 1, 1, 12, 0, in: Self.berlin)).shortSubtitle == "01.01. · 12:00")
        let day = Self.title(Self.date(2024, 9, 30, 14, 32, in: Self.berlin), place: nil)
        #expect(day.shortTitle == "30.09.2024")
        #expect(day.shortSubtitle == "14:32")
        #expect(Self.title(Self.date(2026, 11, 21, 9, 5, in: Self.berlin)).shortSubtitle == "Heute · 09:05")
        #expect(Self.title(Self.date(2026, 11, 20, 9, 5, in: Self.berlin), place: nil).shortTitle == "Gestern")
        #expect(Self.title(Self.date(2026, 11, 19, 12, 0, in: Self.berlin)).shortSubtitle == "Donnerstag · 12:00")
        let munich = PlaceComponents(isoCountryCode: "DE", country: "Germany", locality: "Munich")
        let english = Self.title(Self.date(2024, 9, 30, 14, 32, in: Self.berlin), place: munich, words: .english)
        #expect(english.shortSubtitle == "Sep 30, 2024 · 2:32\u{202F}PM")
        #expect(Self.title(Self.date(2026, 3, 12, 9, 5, in: Self.berlin), place: nil, words: .english).shortTitle == "Mar 12")
        // Nothing to shorten without a date.
        #expect(Self.title(nil).shortTitle == "München")
        #expect(Self.title(nil).shortSubtitle == nil)
        #expect(PhotoTitle(facts: nil, now: Self.now, currentZone: Self.berlin).shortTitle == "Foto")
        // Never longer than the long form, in any month and both languages.
        for words in [ProposalWords.german, .english] {
            for month in 1...12 {
                let shown = Self.title(Self.date(2024, month, 28, 23, 59, in: Self.berlin), words: words)
                #expect((shown.shortSubtitle ?? "").count <= (shown.subtitle ?? "").count, "\(month)")
            }
        }
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

    /// The clock follows the iPhone's hour cycle (Settings › General › Date & Time, else the
    /// region's own; review D, L2): 0–11 and 1–12 are the 12-hour clock, 0–23 and 1–24 the
    /// 24-hour clock, and the user's choice wins over the region's.
    @Test func theClockFollowsTheHourCycle() {
        #expect(PhotoTitle.Clock(hourCycle: .zeroToEleven) == .twelveHour)
        #expect(PhotoTitle.Clock(hourCycle: .oneToTwelve) == .twelveHour)
        #expect(PhotoTitle.Clock(hourCycle: .zeroToTwentyThree) == .twentyFourHour)
        #expect(PhotoTitle.Clock(hourCycle: .oneToTwentyFour) == .twentyFourHour)
        #expect(PhotoTitle.Clock(hourCycle: Locale(identifier: "en_US").hourCycle) == .twelveHour)
        #expect(PhotoTitle.Clock(hourCycle: Locale(identifier: "de_DE").hourCycle) == .twentyFourHour)
        #expect(PhotoTitle.Clock(hourCycle: Locale(identifier: "en_GB").hourCycle) == .twentyFourHour)
        #expect(PhotoTitle.Clock(hourCycle: Locale(identifier: "en_US@hours=h23").hourCycle) == .twentyFourHour)
        #expect(PhotoTitle.Clock(hourCycle: Locale(identifier: "de_DE@hours=h12").hourCycle) == .twelveHour)
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
