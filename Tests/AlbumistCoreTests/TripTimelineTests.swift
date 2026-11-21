import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Design wave 3, DS-14: "Reise anpassen" shows the trip as a timeline of its days: each day
/// with its date, where it was (one town, or two when the second holds a good part of the day)
/// and a strip of larger photos spread over the day; the days without photos between them; the
/// days a new trip can start with (every day but the first, the split `TripWorkshop` makes);
/// and the days between this trip and its neighbours, which merging would bridge.
@Suite("Trip timeline")
struct TripTimelineTests {
    static let calendar = Fixture.calendar

    static func place(_ town: String) -> PlaceComponents {
        PlaceComponents(isoCountryCode: "IS", country: "Island", administrativeArea: "Suðurland", locality: town)
    }

    /// A trip as the analysis left it.
    struct Trip {
        var facts: [AssetFacts] = []

        @discardableResult
        mutating func add(_ date: String, _ town: String?, sensitive: Bool = false, screenshot: Bool = false) -> AssetID {
            let id = AssetID(String(format: "trip-%03d", facts.count + 1))
            let asset = AssetSnapshot(id: id, subtypes: screenshot ? [.screenshot] : [], creationDate: Fixture.date(date),
                                      pixelWidth: 4032, pixelHeight: 3024)
            var f = AssetFacts(asset: asset, recognizedText: screenshot ? "Bestellung Nr. 4711" : nil,
                               looksLikeDocument: sensitive, contentKnown: true)
            if screenshot { f.textCategories = ["order"] }
            if let town {
                f.place = TripTimelineTests.place(town)
                f.placeSource = .gpsReverseGeocoded
            }
            facts.append(f)
            return id
        }

        var ids: [AssetID] { facts.map(\.id) }
        var dates: [AssetID: Date] { Dictionary(uniqueKeysWithValues: facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } }) }
        var ranks: [AssetID: PreviewRank] { PreviewRank.ranks(of: facts) }
        var workshopDays: [TripWorkshop.Day] { TripWorkshop.days(of: ids, dates: dates, calendar: TripTimelineTests.calendar) }

        func timeline() -> [TripTimeline.Day] {
            TripTimeline.days(workshopDays, facts: FactsByID(facts), ranks: ranks, dates: dates, calendar: TripTimelineTests.calendar)
        }
    }

    /// Iceland in August 2023: Reykjavík from the 1st (nothing on the 2nd), a day trip to
    /// Selfoss on the 4th, Vík from the 5th with Skógar on the way, a bank card photographed.
    struct Iceland {
        var trip = Trip()
        var bankCard: AssetID!
        var first: [AssetID] = []
        var sixth: [AssetID] = []

        init() {
            for hour in ["09:00", "11:00", "13:00", "15:00", "17:00", "19:00"] {
                first.append(trip.add("2023-08-01 " + hour, "Reykjavík"))
            }
            trip.add("2023-08-03 10:00", "Reykjavík")
            bankCard = trip.add("2023-08-03 12:00", "Reykjavík", sensitive: true)
            trip.add("2023-08-03 18:00", "Reykjavík")
            trip.add("2023-08-04 09:00", "Reykjavík")
            trip.add("2023-08-04 12:00", "Selfoss")
            trip.add("2023-08-04 14:00", "Selfoss")
            trip.add("2023-08-04 20:00", "Reykjavík")
            trip.add("2023-08-05 10:00", "Vík")
            trip.add("2023-08-05 16:00", nil)
            for (hour, town) in [("09:00", "Skógar"), ("11:00", "Vík"), ("13:00", "Vík"), ("15:00", "Vík"), ("17:00", "Vík"), ("19:00", "Vík")] {
                sixth.append(trip.add("2023-08-06 " + hour, town))
            }
            trip.add("2023-08-07 08:00", "Vík", sensitive: true)
        }
    }

    static let iceland = Iceland()

    @Test func theDaysOfTheTripInOrderWithTheirPhotos() {
        let days = Self.iceland.trip.timeline()
        #expect(days.map(\.day.start) == ["2023-08-01", "2023-08-03", "2023-08-04", "2023-08-05", "2023-08-06", "2023-08-07"].map(Fixture.date))
        #expect(days.map(\.day.count) == [6, 3, 4, 2, 6, 1])
        #expect(days.map(\.id) == days.map(\.day.start))
        // The same days the split works with.
        #expect(days.map(\.day) == Self.iceland.trip.workshopDays)
    }

    /// The town where the day was, as Photos names a photo's place; a second one when it holds at
    /// least a third of the day's photos with a place (Selfoss on the 4th, not Skógar on the 6th).
    @Test func eachDaySaysWhereItWas() {
        let days = Self.iceland.trip.timeline()
        #expect(days.map(\.places) == [["Reykjavík"], ["Reykjavík"], ["Reykjavík", "Selfoss"], ["Vík"], ["Vík"], ["Vík"]])
    }

    @Test func aDayWithoutPlacesSaysNone() {
        var trip = Trip()
        trip.add("2023-08-01 10:00", nil)
        trip.add("2023-08-01 11:00", nil)
        #expect(trip.timeline().map(\.places) == [[]])
    }

    /// Larger photos than one thumbnail: up to three, spread over the day (morning, midday,
    /// evening), oldest first; a sensitive photo never, a screenshot only to fill.
    @Test func eachDayShowsUpToThreePhotosSpreadOverIt() {
        let days = Self.iceland.trip.timeline()
        let first = Self.iceland.first
        #expect(days[0].photos == [first[0], first[2], first[5]])
        #expect(days.allSatisfy { $0.photos.count <= TripTimeline.photosPerDay })
        #expect(TripTimeline.photosPerDay == 3)
        // The 3rd: the bank card is left out, the two photos around it stay.
        #expect(days[1].photos.count == 2)
        #expect(!days[1].photos.contains(Self.iceland.bankCard))
        #expect(days.allSatisfy { !$0.photos.contains(Self.iceland.bankCard) })
        // A day of two photos shows both.
        #expect(days[3].photos.count == 2)
    }

    @Test func screenshotsOnlyFillADay() {
        var trip = Trip()
        let morning = trip.add("2023-08-01 10:00", "Vík")
        let shot = trip.add("2023-08-01 11:00", nil, screenshot: true)
        trip.add("2023-08-01 12:00", nil, screenshot: true)
        let evening = trip.add("2023-08-01 13:00", "Vík")
        // Both photos, and one screenshot for the third place.
        #expect(trip.timeline()[0].photos == [morning, shot, evening])
    }

    /// A day of nothing but a sensitive photo shows "Vorschau ausgeblendet", never the photo.
    @Test func aDayOfOnlySensitivePhotosHidesItsPreview() {
        let days = Self.iceland.trip.timeline()
        #expect(days.last?.photos == [])
        #expect(days.last?.hidesPreview == true)
        #expect(days.dropLast().allSatisfy { !$0.hidesPreview })
    }

    /// The days without photos between two days of the trip (nothing on the 2nd).
    @Test func theQuietDaysBetweenTwoDays() {
        let days = Self.iceland.trip.timeline()
        #expect(days.map(\.quietDaysBefore) == [0, 1, 0, 0, 0, 0])
    }

    /// Every day but the first can start a new trip, and the split before it makes the two
    /// trips the workshop shows: the first ends before that day, the second starts with it.
    @Test func everyDayButTheFirstCanStartANewTrip() throws {
        let trip = Self.iceland.trip
        let days = trip.timeline()
        #expect(days.map(\.canStartNewTrip) == [false, true, true, true, true, true])
        let workshopDays = trip.workshopDays
        for (index, day) in days.enumerated() where day.canStartNewTrip {
            let split = try #require(TripWorkshop.split(workshopDays, before: index, dates: trip.dates))
            #expect(split.first.end < day.day.start)
            #expect(split.second.start >= day.day.start)
            #expect(split.first.count + split.second.count == trip.facts.count)
            #expect(TripWorkshop.splitInstant(before: day.day) == day.day.start)
        }
        #expect(TripWorkshop.split(workshopDays, before: 0, dates: trip.dates) == nil)
    }

    /// A trip of one day cannot be split.
    @Test func aTripOfOneDayHasNoSplitPoint() {
        var trip = Trip()
        trip.add("2023-08-01 10:00", "Vík")
        trip.add("2023-08-01 12:00", "Vík")
        #expect(trip.timeline().map(\.canStartNewTrip) == [false])
    }

    /// Between this trip and a neighbour: the days without photos that a merge would bridge
    /// ("3 Tage dazwischen"); none when one ends the day before the other starts.
    @Test func theQuietDaysBetweenTwoTrips() {
        let calendar = Self.calendar
        #expect(TripTimeline.quietDays(from: Fixture.date("2023-07-28 18:00"), to: Fixture.date("2023-08-01 09:00"), calendar: calendar) == 3)
        #expect(TripTimeline.quietDays(from: Fixture.date("2023-07-31 23:00"), to: Fixture.date("2023-08-01 01:00"), calendar: calendar) == 0)
        #expect(TripTimeline.quietDays(from: Fixture.date("2023-08-01 08:00"), to: Fixture.date("2023-08-01 20:00"), calendar: calendar) == 0)
        #expect(TripTimeline.quietDays(from: Fixture.date("2023-08-09 08:00"), to: Fixture.date("2023-08-01 20:00"), calendar: calendar) == 0)
    }

    /// A neighbour's span from its photos: first to last.
    @Test func aTripsSpanFromItsPhotos() throws {
        let trip = Self.iceland.trip
        let span = try #require(TripTimeline.span(of: trip.ids, dates: trip.dates))
        #expect(span.start == Fixture.date("2023-08-01 09:00"))
        #expect(span.end == Fixture.date("2023-08-07 08:00"))
        #expect(TripTimeline.span(of: [AssetID("none")], dates: trip.dates) == nil)
    }
}
