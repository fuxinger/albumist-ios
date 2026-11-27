import Foundation
import Testing
@testable import AlbumistCore

/// A title when the date, the place or the clock is not known (`PhotoTitleTests`).
extension PhotoTitleTests {
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
}
