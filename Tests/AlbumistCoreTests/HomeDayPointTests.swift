import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Review of 18.11.2026 (Prüfer A, G1-02; Fable blind second review, claim 5): the home
/// detection and the main place of a stay read only the first 15 photos of each day.
@Suite("Review 18.11.: the whole day decides where the day was")
struct HomeDayPointTests {

    // MARK: G1-02 the whole day, not its first 15 photos, decides where the day was

    /// 45 days: `morning` photos at 8:00 at one place, `evening` photos at 17:00 at the other.
    private func dayLibrary(morningAtHome: Bool, morning: Int = 15, evening: Int = 25) -> [AssetSnapshot] {
        var lib = LibraryBuilder()
        let cal = Fixture.calendar
        for d in 0..<45 {
            let day = cal.date(byAdding: .day, value: d, to: Fixture.date("2026-01-01"))!
            for p in 0..<morning {
                _ = lib.photo(at: cal.date(byAdding: .minute, value: 8 * 60 + p, to: day)!,
                              morningAtHome ? Fixture.Places.munichHome : Fixture.Places.tegernsee, jitterMeters: 0)
            }
            for p in 0..<evening {
                _ = lib.photo(at: cal.date(byAdding: .minute, value: 17 * 60 + p, to: day)!,
                              morningAtHome ? Fixture.Places.tegernsee : Fixture.Places.munichHome, jitterMeters: 0)
            }
        }
        return lib.assets
    }

    /// Prüfer A, g102_majorityOfTheDayDecidesHome: 15 photos at the Tegernsee (49 km) every
    /// morning, 25 in Munich every evening. Before: home 49,110 m from Munich.
    @Test func fifteenMorningPhotosElsewhereDoNotMoveHome() throws {
        let a = TripDetector(calendar: Fixture.calendar).analyse(in: dayLibrary(morningAtHome: false))
        let home = try #require(a.detectedHome)
        #expect(GeoMath.distance(home.center, Fixture.Places.munichHome) < 5_000,
                "home \(Int(GeoMath.distance(home.center, Fixture.Places.munichHome))) m from Munich")
    }

    /// Controls that were green before: the majority in the morning (25 at home, 15 away), and
    /// days of fewer than 15 photos (where every photo was already looked at). Prüfer A's
    /// control with 15 at home in the morning and 25 away in the evening is not kept: it was
    /// green only because the first 15 decided; with both places on every day the place of
    /// most photos is where the days were.
    @Test func majorityInTheMorningOrSmallDaysStillDecide() throws {
        for (library, label) in [(dayLibrary(morningAtHome: true, morning: 25, evening: 15), "25 at home in the morning"),
                                 (dayLibrary(morningAtHome: false, morning: 7, evening: 10), "7 + 10")] {
            let a = TripDetector(calendar: Fixture.calendar).analyse(in: library)
            let home = try #require(a.detectedHome, "\(label)")
            #expect(GeoMath.distance(home.center, Fixture.Places.munichHome) < 5_000, "\(label)")
        }
    }

    /// Fable blind review, claim 5: 40 days, a few early photos at the Tegernsee, then many in
    /// Munich. Before: from 8 early photos on, the Tegernsee was home and the 1,600 (4,000)
    /// Munich photos became one trip.
    @Test func earlyPhotosAwayOnManyDaysDoNotTurnHomeIntoATrip() throws {
        for (away, home) in [(7, 40), (8, 40), (16, 100)] {
            var b = LibraryBuilder()
            var homeIDs: [AssetID] = []
            let start = Fixture.date("2025-01-01")
            for d in 0..<40 {
                let day = start.addingTimeInterval(Double(d * 3) * 86_400)
                for i in 0..<away { _ = b.photo(at: day.addingTimeInterval(8 * 3600 + Double(i) * 60), Fixture.Places.tegernsee) }
                for i in 0..<home { homeIDs.append(b.photo(at: day.addingTimeInterval(12 * 3600 + Double(i) * 60), Fixture.Places.munichHome)) }
            }
            let a = TripDetector(calendar: Fixture.calendar).analyse(in: b.assets)
            let detected = try #require(a.detectedHome, "\(away) + \(home)")
            #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 5_000, "\(away) + \(home)")
            let notAtHome = Set(homeIDs).subtracting(a.atHome).count
            #expect(notAtHome == 0, "\(away) + \(home): Munich photos not at home")
            let inTrips = Set(a.trips.flatMap(\.geotaggedAssetIDs)).intersection(homeIDs).count
            #expect(inTrips == 0, "\(away) + \(home): Munich photos in a trip")
        }
    }

    /// The same cap in `RecurringPlaces.mainPlace` (where a stay mostly was, for "Bist du hier
    /// öfter?"): a week at Lake Garda with 15 photos on an outing to Verona (40 km) every
    /// morning and 25 at the holiday flat every evening is a stay at the lake.
    @Test func mainPlaceOfAStayIsWhereMostPhotosOfEachDayWere() throws {
        let verona = GeoCoordinate(latitude: 45.4384, longitude: 10.9916)
        var photos: [(date: Date, coordinate: GeoCoordinate)] = []
        for d in 0..<7 {
            let day = Fixture.date("2026-07-04").addingTimeInterval(Double(d) * 86_400)
            for i in 0..<15 { photos.append((day.addingTimeInterval(9 * 3600 + Double(i) * 60), verona)) }
            for i in 0..<25 { photos.append((day.addingTimeInterval(18 * 3600 + Double(i) * 60), Fixture.Places.gardaLake)) }
        }
        let main = try #require(RecurringPlaces.mainPlace(of: photos, calendar: Fixture.calendar))
        #expect(GeoMath.distance(main, Fixture.Places.gardaLake) < 1_000,
                "main place \(Int(GeoMath.distance(main, Fixture.Places.gardaLake))) m from the flat")
        // The order the photos come in does not matter.
        let reversed = try #require(RecurringPlaces.mainPlace(of: photos.reversed(), calendar: Fixture.calendar))
        #expect(GeoMath.distance(reversed, Fixture.Places.gardaLake) < 1_000)
    }

    /// The day's point comes from at most `GeoMath.daySample` photos spread over the whole
    /// day: a day of 10,000 photos costs what a day of 15 costs, and every part of
    /// the day is in the sample in proportion to its photos.
    @Test func dayPointSamplesTheWholeDay() throws {
        let n = GeoMath.daySample
        // Up to the sample size every photo counts, as before.
        let few = Array(repeating: Fixture.Places.tegernsee, count: n / 2 + 1) + Array(repeating: Fixture.Places.munichHome, count: n / 2)
        #expect(GeoMath.dayPoint(few) == Fixture.Places.tegernsee)
        // 1 photo away, 10,000 at home, and the other way round.
        let large = [Fixture.Places.tegernsee] + Array(repeating: Fixture.Places.munichHome, count: 10_000)
        #expect(GeoMath.dayPoint(large) == Fixture.Places.munichHome)
        #expect(GeoMath.dayPoint(large.reversed()) == Fixture.Places.munichHome)
        // 45 % of a large day at one place, 55 % at the other: the 55 % win.
        let split = Array(repeating: Fixture.Places.tegernsee, count: 450) + Array(repeating: Fixture.Places.munichHome, count: 550)
        #expect(GeoMath.dayPoint(split) == Fixture.Places.munichHome)
        #expect(GeoMath.daySampleIndices(count: 10_000).count == n)
        #expect(GeoMath.dayPoint([]) == nil)
    }

    /// Second review: the medoid alone picks a minority place lying between two others. On a
    /// line west to east, 5 photos at 0 km, 4 at 20 km, 6 at 40 km: the medoid is the middle
    /// (4 photos); the day was where the 6 were. Photos all far apart keep the medoid.
    @Test func theDayIsWhereMostPhotosWereNotTheMiddle() {
        func east(_ km: Double) -> GeoCoordinate {
            GeoCoordinate(latitude: 48.0, longitude: 11.0 + km * 1_000 / (GeoMath.metersPerDegreeLatitude * cos(48.0 * .pi / 180)))
        }
        let day = Array(repeating: east(0), count: 5) + Array(repeating: east(20), count: 4) + Array(repeating: east(40), count: 6)
        #expect(GeoMath.dayPoint(day) == east(40))
        #expect(GeoMath.dayPoint(day.reversed()) == east(40))
        // Within 1 km counts as one place: 6 photos spread over 600 m beat 5 on one spot.
        let spread = (0..<6).map { east(40 + Double($0) * 0.12) }
        #expect(GeoMath.dayPoint(Array(repeating: east(0), count: 5) + spread).map { GeoMath.distance($0, east(40)) < 1_000 } == true)
        // A hike: every photo 3 km from the next; the most central one, as before.
        let hike = (0..<7).map { east(Double($0) * 3) }
        #expect(GeoMath.dayPoint(hike) == east(9))
    }
}
