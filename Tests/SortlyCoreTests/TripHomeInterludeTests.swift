import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review finding P1-14 (core logic, 18.11.2026): three photos with the location of home in
/// the middle of a week in Rome (sent from home and saved, or a family member's photos in a
/// shared library) cut the trip in two albums. A photo from home only means the user came
/// home when they could have got there since the trip's last photo.
@Suite("Trips: photos from home in the middle of a trip (P1-14)")
struct TripHomeInterludeTests {
    let detector = TripDetector(calendar: Fixture.calendar)
    static let airportMunich = GeoCoordinate(latitude: 48.3538, longitude: 11.7861)   // within the home radius
    static let newYork = GeoCoordinate(latitude: 40.7128, longitude: -74.0060)

    /// The reviewer's library: daily life in Munich, Rome from 12 to 19 May 2026 with four
    /// photos a day (10:00, 10:37, 11:14, 11:51), and `homePhotos` photos with the location of
    /// home on 15 May at 10:30, 11:30 and 12:30.
    static func rome(homePhotos: Int) -> (assets: [AssetSnapshot], rome: [AssetID]) {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for n in 0..<homePhotos { _ = lib.photo(at: Fixture.date("2026-05-15 1\(n):30"), Fixture.Places.munichHome) }
        return (lib.assets, rome)
    }

    func tripsTouching(_ ids: [AssetID], in assets: [AssetSnapshot]) -> [Set<AssetID>] {
        let wanted = Set(ids)
        return detector.detect(in: assets).map { Set($0.geotaggedAssetIDs) }.filter { !$0.isDisjoint(with: wanted) }
    }

    @Test func photosFromHomeTheUserCannotHaveTakenDoNotCutTheTrip() {
        for count in 0...3 {
            let (assets, rome) = Self.rome(homePhotos: count)
            let trips = tripsTouching(rome, in: assets)
            #expect(trips == [Set(rome)], "\(count) photos from home: \(trips.map(\.count))")
        }
    }

    /// The same in the evening: the last photo in Rome at 11:51, one from home 40 minutes later
    /// and one at 13:00. Rome is 700 km away.
    @Test func aPhotoFromHomeSoonAfterTheTripsLastPhotoOfTheDayDoesNotCutIt() {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        _ = lib.photo(at: Fixture.date("2026-05-15 12:31"), Fixture.Places.munichHome)
        _ = lib.photo(at: Fixture.date("2026-05-15 13:00"), Fixture.Places.munichHome)
        #expect(tripsTouching(rome, in: lib.assets) == [Set(rome)])
    }

    /// Coming home for two days still makes two trips (the rule of `homeInterludeTolerance`).
    @Test func comingHomeForTwoDaysStillEndsTheTrip() {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-21")])
        let first = lib.daily(from: "2026-05-12", to: "2026-05-15", at: Fixture.Places.rome, perDay: 4, hour: 10)
        _ = lib.daily(from: "2026-05-16", to: "2026-05-17", at: Fixture.Places.munichHome, perDay: 3, hour: 9)
        let second = lib.daily(from: "2026-05-18", to: "2026-05-21", at: Fixture.Places.rome, perDay: 4, hour: 10)
        #expect(tripsTouching(first + second, in: lib.assets) == [Set(first), Set(second)])
    }

    /// A flight home: the last photo at the gate in Rome, the next at Munich airport 1 h 40 min
    /// later, a night at home, and off to Naples the next morning. The airport photo is a real
    /// way home, so the two trips stay two.
    @Test func aFlightHomeIsAWayHome() {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-20")])
        var rome = lib.daily(from: "2026-05-12", to: "2026-05-14", at: Fixture.Places.rome, perDay: 4, hour: 10)
        rome.append(lib.photo(at: Fixture.date("2026-05-15 09:00"), Fixture.Places.rome))
        _ = lib.photo(at: Fixture.date("2026-05-15 10:40"), Self.airportMunich)
        let naples = lib.daily(from: "2026-05-16", to: "2026-05-20", at: Fixture.Places.naples, perDay: 4, hour: 8)
        #expect(tripsTouching(rome + naples, in: lib.assets) == [Set(rome), Set(naples)])
    }

    /// A long-haul flight: the last photo in New York, the first one at home 9 hours later, a
    /// day at home, and a weekend in Rome after it.
    @Test func aLongFlightHomeIsAWayHome() {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-02", "2026-05-17")])
        var newYork = lib.daily(from: "2026-05-02", to: "2026-05-10", at: Self.newYork, perDay: 4, hour: 14)
        newYork.append(lib.photo(at: Fixture.date("2026-05-10 22:00"), Self.newYork))
        _ = lib.photo(at: Fixture.date("2026-05-11 07:00"), Self.airportMunich)
        _ = lib.photo(at: Fixture.date("2026-05-11 19:00"), Fixture.Places.munichHome)
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-14", at: Fixture.Places.rome, perDay: 4, hour: 10)
        #expect(tripsTouching(newYork + rome, in: lib.assets) == [Set(newYork), Set(rome)])
    }

    // MARK: Second review: photos from home later on the day, the trip going on next morning

    /// The reviewer's second library: Rome as above (last photo of 15 May at 11:51, the next one
    /// at 10:00 on 16 May) and photos with the location of home on 15 May at `times`.
    static func rome(homeAt times: [String]) -> (assets: [AssetSnapshot], rome: [AssetID]) {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for time in times { _ = lib.photo(at: Fixture.date("2026-05-15 \(time)"), Fixture.Places.munichHome) }
        return (lib.assets, rome)
    }

    /// Home photos in the afternoon and evening, Rome again the next morning: the user would have
    /// had to fly home and back overnight to the same place; one trip (was 16 + 16).
    @Test func photosFromHomeLaterOnTheDayDoNotCutTheTrip() {
        for times in [["13:20"], ["21:00"], ["18:00"], ["13:20", "14:00", "18:00", "21:00"]] {
            let (assets, rome) = Self.rome(homeAt: times)
            let trips = tripsTouching(rome, in: assets)
            #expect(trips == [Set(rome)], "home at \(times): \(trips.map(\.count))")
        }
    }

    /// A night at home that the photos show (evening and next morning at home), with time to get
    /// back to Rome before its next photo: two trips.
    @Test func aNightAtHomeShownByThePhotosEndsTheTrip() {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-21")])
        let first = lib.daily(from: "2026-05-12", to: "2026-05-15", at: Fixture.Places.rome, perDay: 4, hour: 10)
        _ = lib.photo(at: Fixture.date("2026-05-15 20:00"), Fixture.Places.munichHome)
        _ = lib.photo(at: Fixture.date("2026-05-16 08:00"), Fixture.Places.munichHome)
        var second = [lib.photo(at: Fixture.date("2026-05-16 18:00"), Fixture.Places.rome)]
        second += lib.daily(from: "2026-05-17", to: "2026-05-21", at: Fixture.Places.rome, perDay: 4, hour: 10)
        #expect(tripsTouching(first + second, in: lib.assets) == [Set(first), Set(second)])
    }

    /// A weekend at home between two trips, with a photo at home only on the Friday evening:
    /// two trips, whether the next one goes elsewhere or back to Rome.
    @Test func aWeekendAtHomeBetweenTwoTripsEndsTheFirst() {
        for next in [Fixture.Places.naples, Fixture.Places.rome] {
            var lib = LibraryBuilder()
            _ = lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-21")])
            let rome = lib.daily(from: "2026-05-12", to: "2026-05-15", at: Fixture.Places.rome, perDay: 4, hour: 10)
            _ = lib.photo(at: Fixture.date("2026-05-15 21:00"), Fixture.Places.munichHome)
            let second = lib.daily(from: "2026-05-18", to: "2026-05-21", at: next, perDay: 4, hour: 10)
            #expect(tripsTouching(rome + second, in: lib.assets) == [Set(rome), Set(second)], "\(next)")
        }
    }

    @Test func theFastestWayHome() {
        // 700 km: not in 40 minutes, but in an hour and a half by plane.
        #expect(TripDetector.minimumTravelTime(meters: 700_000) > 40 * 60)
        #expect(TripDetector.minimumTravelTime(meters: 700_000) < 90 * 60)
        // 50 km on the ground: a quarter of an hour.
        #expect(TripDetector.minimumTravelTime(meters: 50_000) < 15 * 60)
        #expect(TripDetector.minimumTravelTime(meters: 0) == 0)
    }
}
