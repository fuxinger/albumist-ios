import Foundation
import Testing
@testable import AlbumistCore

/// The photo's info, "Aufgenommen": the day and the time on the clock where the photo was taken,
/// as the photo view's title says them (decision of 19.11.2026, "Ortszeit am Aufnahmeort wie
/// Apple Fotos"). The design run of 25.11. (UI run 45567033486, shots 15 and 15a) showed a photo
/// from Rome as "14. Mai 2024 · 09:18" in the title and "14. Mai 2024 um 7:18" in its info: the
/// info told the time on the iPhone's clock (UTC on the test Mac), not on the photo's.
extension PhotoTitleTests {
    static let rome = TimeZone(identifier: "Europe/Rome")!

    /// A photo taken in Rome at 09:18 says 09:18 in its info on an iPhone set to any other zone,
    /// the same time its title says.
    @Test func theInfoTellsTheTimeOnThePhotosClock() {
        let taken = Self.date(2024, 5, 14, 9, 18, in: Self.rome)
        #expect(PhotoTitle.takenAt(taken, zone: Self.rome, currentZone: Self.utc) == "14. Mai 2024 um 09:18")
        #expect(PhotoTitle.takenAt(taken, zone: Self.rome, currentZone: Self.newYork) == "14. Mai 2024 um 09:18")
        let title = Self.title(taken, zone: Self.rome, now: Self.now, current: Self.utc)
        #expect(title.subtitle == "14. Mai 2024 · 09:18")
    }

    /// Late at night in New York is the next day in Germany: the info keeps New York's day and
    /// time, as Photos does.
    @Test func theInfoKeepsThePhotosDay() {
        let taken = Self.date(2019, 11, 2, 23, 0, in: Self.newYork)
        #expect(PhotoTitle.takenAt(taken, zone: Self.newYork, currentZone: Self.berlin) == "2. November 2019 um 23:00")
        #expect(PhotoTitle.takenAt(taken, zone: Self.newYork, currentZone: Self.berlin, words: .english)
            == "November 2, 2019 at 11:00\u{202F}PM")
    }

    /// The year is always said (the info names the whole date, also this year's, and never
    /// "Heute" or a weekday); without a zone of its own the iPhone's clock counts, as in the
    /// title; the iPhone's 12- or 24-hour setting counts in both languages.
    @Test func theInfoSaysTheWholeDateOnTheChosenClock() {
        let today = Self.date(2026, 11, 21, 9, 5, in: Self.berlin)
        #expect(PhotoTitle.takenAt(today, zone: Self.berlin, currentZone: Self.berlin) == "21. November 2026 um 09:05")
        #expect(PhotoTitle.takenAt(today, zone: nil, currentZone: Self.berlin) == "21. November 2026 um 09:05")
        #expect(PhotoTitle.takenAt(today, zone: nil, currentZone: Self.tokyo) == "21. November 2026 um 17:05")
        #expect(PhotoTitle.takenAt(today, zone: Self.berlin, currentZone: Self.berlin, clock: .twelveHour)
            == "21. November 2026 um 9:05\u{202F}AM")
        #expect(PhotoTitle.takenAt(today, zone: Self.berlin, currentZone: Self.berlin, words: .english, clock: .twentyFourHour)
            == "November 21, 2026 at 09:05")
    }
}
