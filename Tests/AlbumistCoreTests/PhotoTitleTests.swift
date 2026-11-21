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

    /// Today and yesterday are counted on the photo's own clock, the clock its day and time are
    /// told on (review D, M1): taken in New York at 23:30 on 20 November, seen in Berlin on the
    /// morning of the 21st, when it is 04:00 of the 21st in New York, it was yesterday at 23:30.
    @Test func todayAndYesterdayAreCountedOnThePhotosClock() {
        let instant = Self.date(2026, 11, 20, 23, 30, in: Self.newYork)
        let shown = Self.title(instant, zone: Self.newYork, place: nil)
        #expect(shown.title == "Gestern")
        #expect(shown.subtitle == "23:30")
        // On the iPhone's own clock it was the 21st at 05:30: today.
        #expect(Self.title(instant, zone: nil, place: nil).title == "Heute")
    }

    // MARK: Today on the photo's clock (review D, M1)

    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
    static let utc = TimeZone(identifier: "UTC")!

    /// Travelling: home is Berlin, the iPhone is in New York at 20:00 on 21 November. A photo
    /// without a place (a screenshot, location off) is told on the home clock (P1-15), where it
    /// is 02:00 of the 22nd: taken a minute ago, it is "Heute · 01:59", not "22. November". One
    /// taken that morning in New York (14:00 at home) was yesterday on that clock, as its time says.
    @Test func aPhotoOnTheHomeClockWhileTravellingIsToday() {
        let now = Self.date(2026, 11, 21, 20, 0, in: Self.newYork)
        let justTaken = Self.title(Self.date(2026, 11, 21, 19, 59, in: Self.newYork), place: nil, now: now, current: Self.newYork)
        #expect(justTaken.title == "Heute")
        #expect(justTaken.subtitle == "01:59")
        let morning = Self.title(Self.date(2026, 11, 21, 8, 0, in: Self.newYork), place: nil, now: now, current: Self.newYork)
        #expect(morning.title == "Gestern")
        #expect(morning.subtitle == "14:00")
    }

    /// A photo received from Tokyo, taken there at 01:00 on 22 November and seen in Berlin an
    /// hour later (18:00 of the 21st): today on its own clock. The other way round, a photo
    /// taken in New York at 20:00 and seen in Berlin at 02:30 the next morning: today, not
    /// "Gestern".
    @Test func aPhotoFromAnotherZoneIsTodayOnItsClock() {
        let tokyo = Self.title(Self.date(2026, 11, 22, 1, 0, in: Self.tokyo), zone: Self.tokyo, place: nil,
                               now: Self.date(2026, 11, 21, 18, 0, in: Self.berlin))
        #expect(tokyo.title == "Heute")
        #expect(tokyo.subtitle == "01:00")
        let newYork = Self.title(Self.date(2026, 11, 21, 20, 0, in: Self.newYork), zone: Self.newYork, place: nil,
                                 now: Self.date(2026, 11, 22, 2, 30, in: Self.berlin))
        #expect(newYork.title == "Heute")
        #expect(newYork.subtitle == "20:00")
    }

    /// The days the clocks change (last Sunday of March and of October in Berlin): both sides
    /// of the change are today, each with its own time; 02:30 in October happens twice and says
    /// 02:30 both times; the evening before is yesterday.
    @Test func theDaysTheClocksChange() {
        let march = Self.date(2026, 3, 29, 12, 0, in: Self.berlin)
        for (instant, time) in [(Self.date(2026, 3, 29, 1, 30, in: Self.berlin), "01:30"), (Self.date(2026, 3, 29, 3, 30, in: Self.berlin), "03:30")] {
            let shown = Self.title(instant, place: nil, now: march)
            #expect(shown.title == "Heute")
            #expect(shown.subtitle == time)
        }
        #expect(Self.title(Self.date(2026, 3, 28, 23, 30, in: Self.berlin), place: nil, now: march).title == "Gestern")
        let october = Self.date(2026, 10, 25, 12, 0, in: Self.berlin)
        let first = Self.date(2026, 10, 25, 0, 30, in: Self.utc), second = Self.date(2026, 10, 25, 1, 30, in: Self.utc)
        for instant in [first, second] {
            let shown = Self.title(instant, place: nil, now: october)
            #expect(shown.title == "Heute")
            #expect(shown.subtitle == "02:30")
        }
        #expect(Self.title(Self.date(2026, 10, 24, 23, 30, in: Self.berlin), place: nil, now: october).title == "Gestern")
        #expect(Self.title(Self.date(2026, 10, 25, 23, 59, in: Self.berlin), place: nil,
                           now: Self.date(2026, 10, 26, 0, 30, in: Self.berlin)).title == "Gestern")
    }

    /// Zones half or three quarters of an hour off: the time is told to the minute, and today
    /// is that clock's today (in Kolkata it is already 00:30 of the 22nd while Berlin has 20:00).
    @Test func halfHourZonesKeepTheirMinutesAndTheirDay() {
        let kolkata = Self.title(Self.date(2026, 11, 22, 0, 10, in: Self.kolkata), zone: Self.kolkata, place: nil,
                                 now: Self.date(2026, 11, 21, 20, 0, in: Self.berlin))
        #expect(kolkata.title == "Heute")
        #expect(kolkata.subtitle == "00:10")
        let kathmandu = Self.title(Self.date(2025, 6, 1, 23, 50, in: Self.kathmandu), zone: Self.kathmandu, place: nil)
        #expect(kathmandu.title == "1. Juni 2025")
        #expect(kathmandu.subtitle == "23:50")
        #expect(Self.title(Self.date(2025, 6, 1, 23, 50, in: Self.kathmandu), zone: Self.kathmandu).subtitle == "1. Juni 2025 · 23:50")
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

    /// Without a capture date: the place alone, or "Ohne Datum"; without anything known of the
    /// photo (not analyzed yet, and no date from Photos): "Foto". The words are the catalog's.
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

    /// Without facts (Albumist has not analysed the photo yet, as right after an import) the
    /// date Photos keeps for it counts, here on the iPhone's clock (no home clock known yet, see
    /// `aPhotoWithoutFactsKeepsItsClockOnceAnalysed`): the day as the title and the time below,
    /// never just "Foto" while a date exists (review D, M7). Facts win where there are some.
    @Test func withoutFactsPhotosOwnDateCounts() {
        let instant = Self.date(2024, 10, 12, 14, 32, in: Self.berlin)
        let fromPhotos = PhotoTitle(facts: nil, photoDate: instant, now: Self.now, currentZone: Self.berlin)
        #expect(fromPhotos.title == "12. Oktober 2024")
        #expect(fromPhotos.subtitle == "14:32")
        #expect(fromPhotos.spoken() == "12. Oktober 2024, 14:32")
        // On the iPhone's clock, wherever it is.
        #expect(PhotoTitle(facts: nil, photoDate: instant, now: Self.now, currentZone: Self.newYork).subtitle == "08:32")
        let today = PhotoTitle(facts: nil, photoDate: Self.date(2026, 11, 21, 9, 5, in: Self.berlin), now: Self.now,
                               currentZone: Self.berlin, words: .english)
        #expect(today.title == "Today")
        #expect(today.subtitle == "9:05\u{202F}AM")
        // Facts win: their place and their clock.
        let place = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", locality: "München")
        let facts = AssetFacts(asset: AssetSnapshot(id: AssetID("a"), creationDate: instant), place: place,
                               placeSource: .gpsReverseGeocoded, timeZone: Self.berlin)
        let known = PhotoTitle(facts: facts, photoDate: Self.now, now: Self.now, currentZone: Self.newYork)
        #expect(known.title == "München")
        #expect(known.subtitle == "12. Oktober 2024 · 14:32")
        // Neither facts nor a date: "Foto".
        #expect(PhotoTitle(facts: nil, photoDate: nil, now: Self.now, currentZone: Self.berlin).title == "Foto")
    }

    /// A photo Albumist has no facts of yet is told on the clock its facts will have, so its
    /// title does not change clock once it is analysed (review D2, N10). Home Berlin, iPhone in
    /// New York at 20:00: a screenshot taken at 19:59 has no location, and the analysis tells
    /// every photo without a place on the home clock (P1-15): "Heute · 01:59" before and after.
    /// A photo with a location gets its place's clock from the analysis; for a photo just taken
    /// that is the iPhone's, so it says 19:59 before and after. Before the first analysis no
    /// home clock is known: the iPhone's, which the first analysis keeps as the home clock.
    @Test func aPhotoWithoutFactsKeepsItsClockOnceAnalysed() {
        let now = Self.date(2026, 11, 21, 20, 0, in: Self.newYork)
        let instant = Self.date(2026, 11, 21, 19, 59, in: Self.newYork)
        let screenshot = PhotoTitle(facts: nil, photoDate: instant, photoLocated: false, homeZone: Self.berlin,
                                    now: now, currentZone: Self.newYork)
        #expect(screenshot.title == "Heute")
        #expect(screenshot.subtitle == "01:59")
        let analysed = AssetFacts(asset: AssetSnapshot(id: AssetID("s"), creationDate: instant), timeZone: Self.berlin)
        #expect(screenshot == PhotoTitle(facts: analysed, now: now, currentZone: Self.newYork))

        let located = PhotoTitle(facts: nil, photoDate: instant, photoLocated: true, homeZone: Self.berlin,
                                 now: now, currentZone: Self.newYork)
        #expect(located.title == "Heute")
        #expect(located.subtitle == "19:59")
        let place = PlaceComponents(isoCountryCode: "US", country: "Vereinigte Staaten", locality: "New York",
                                    timeZoneIdentifier: "America/New_York")
        let placed = AssetFacts(asset: AssetSnapshot(id: AssetID("p"), creationDate: instant), place: place,
                                placeSource: .gpsReverseGeocoded, timeZone: Self.newYork)
        #expect(PhotoTitle(facts: placed, now: now, currentZone: Self.newYork).subtitle == "Heute · 19:59")

        let beforeTheFirstAnalysis = PhotoTitle(facts: nil, photoDate: instant, photoLocated: false, homeZone: nil,
                                                now: now, currentZone: Self.newYork)
        #expect(beforeTheFirstAnalysis.subtitle == "19:59")
        // Facts win over all of it.
        #expect(PhotoTitle(facts: placed, photoDate: instant, photoLocated: false, homeZone: Self.berlin,
                           now: now, currentZone: Self.newYork).title == "New York")
    }

    /// The clock of a photo without facts, by itself: the home clock without a location, the
    /// iPhone's with one, the iPhone's while no home clock is known.
    @Test func theClockWithoutFacts() {
        #expect(PhotoTitle.zoneWithoutFacts(located: false, homeZone: Self.berlin, currentZone: Self.newYork) == Self.berlin)
        #expect(PhotoTitle.zoneWithoutFacts(located: true, homeZone: Self.berlin, currentZone: Self.newYork) == Self.newYork)
        #expect(PhotoTitle.zoneWithoutFacts(located: false, homeZone: nil, currentZone: Self.newYork) == Self.newYork)
        #expect(PhotoTitle.zoneWithoutFacts(located: true, homeZone: nil, currentZone: Self.tokyo) == Self.tokyo)
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
