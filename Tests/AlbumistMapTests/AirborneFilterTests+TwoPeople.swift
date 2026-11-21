import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Two people's photos and wrong locations stay on the ground: two places in turn in a shared
/// library, someone at home while the other flies, Munich, Florence and Rome on a line, and a
/// wrong location that comes back.
extension AirborneFilterTests {
    // MARK: Two people, wrong locations, trains, cars and jumping fixes stay on the ground

    /// Photos alternating between two places every `minutes` (an iCloud Shared Library).
    static func alternating(start: String, count: Int, a: GeoCoordinate, b: GeoCoordinate, minutes: Double, series: Int = 1) -> [AssetSnapshot] {
        let t0 = MapFixture.date(start)
        var photos: [AssetSnapshot] = []
        for i in 0..<count {
            for s in 0..<series {
                let at = t0.addingTimeInterval(Double(i) * minutes * 60 + Double(s) * 2)
                photos.append(shot("\(start)-\(minutes)-\(i)-\(s)", at, Fixture.jitter(i % 2 == 0 ? a : b, seed: i * 7 + s, meters: 400)))
            }
        }
        return photos
    }

    @Test func twoPeoplesPhotosInOneLibraryStayOnTheGround() {
        var photos: [AssetSnapshot] = []
        var day = 0
        for km in [30.0, 80, 150, 300] {
            let other = Self.offset(Places.regensburg, km: km, bearing: 200)
            for minutes in [2.0, 5, 10, 20, 30] {
                day += 1
                let start = String(format: "2024-05-%02d 08:00", day)
                photos += Self.alternating(start: start, count: 16, a: Places.regensburg, b: other, minutes: minutes)
                // Series of three to five photos each, and a third person driving from one to the
                // other at 130 km/h with a photo every four minutes.
                photos += Self.alternating(start: String(format: "2024-05-%02d 14:00", day), count: 12, a: Places.regensburg, b: other,
                                           minutes: minutes, series: 3 + day % 3)
                let drive = km / 130 * 60
                photos += stride(from: 0.0, through: drive, by: 4).map { m in
                    Self.shot("drive-\(day)-\(m)", Self.minutes(MapFixture.date(String(format: "2024-05-%02d 14:00", day)), m),
                              Self.along(Places.regensburg, other, m / drive))
                }
            }
        }
        #expect(AirborneFilter.airborne(photos).isEmpty)
    }

    /// Finding 2.3 of the third review: someone at home takes photos while the other flies (an
    /// iCloud Shared Library). A window photo's nearest photos were those at home: its legs were
    /// no flight (faster than a plane, or there and back), and a series of three did not head on
    /// towards a photo at home behind the plane. A photo out of reach is someone else's now and
    /// nobody's neighbour (`AirborneFilter.jumpMeters`). Munich → Lisbon → Rome → Munich with a
    /// window photo every 20 minutes and a series of three per flight, 20 libraries of 580 window
    /// photos: with a photo at home every hour 515 are found (319 before), every half hour 507
    /// (190); with nobody at home 520. Those within reach of a photo at home (near Munich) can
    /// still zig-zag and count: 23 and 44 (244 and 387 before). The photos at home all count.
    @Test(arguments: [60.0, 30.0])
    func someoneAtHomeInASharedLibraryHidesNoWindowPhotos(minutesBetweenPhotosAtHome: Double) {
        var found = 0, alone = 0, counted = 0, total = 0
        for seed in 1...20 as ClosedRange<UInt64> {
            var random = MapRandom(seed: seed)
            var photos: [AssetSnapshot] = [], window = Set<AssetID>()
            for (name, from, to, takeoff) in [("out", Self.munichAirport, Self.lisbonAirport, "2024-04-02 09:00"),
                                              ("on", Self.lisbonAirport, Self.romeAirport, "2024-04-05 11:00"),
                                              ("back", Self.romeAirport, Self.munichAirport, "2024-04-08 15:00")] {
                let journey = Self.flight(name, from: from, to: to, takeoff: MapFixture.date(takeoff)) { total in
                    Self.every(20, of: total) + Self.series(at: total / 2 + 3, count: 3, seconds: 4)
                }
                photos += journey.photos
                window.formUnion(journey.window)
            }
            // Nobody at home: all but the first or last window photo of a flight (documented).
            let travellerAlone = AirborneFilter.airborne(photos).intersection(window).count
            #expect(travellerAlone >= window.count - 6)
            var home: [AssetSnapshot] = []
            for day in ["2024-04-02", "2024-04-05", "2024-04-08"] {
                var minute = 7 * 60 + minutesBetweenPhotosAtHome * random.unit(), k = 0
                while minute < 21 * 60 {
                    home.append(Self.shot("home-\(day)-\(k)", MapFixture.date(day).addingTimeInterval(minute * 60),
                                          Fixture.jitter(Places.regensburg, seed: k, meters: 300)))
                    minute += minutesBetweenPhotosAtHome * (0.5 + random.unit())
                    k += 1
                }
            }
            let judged = AirborneFilter.judge(photos + home)
            #expect(home.allSatisfy { judged.isOnTheGround($0.id) })
            found += judged.airborne.intersection(window).count
            counted += window.filter(judged.isOnTheGround).count
            alone += travellerAlone
            total += window.count
        }
        let line = "a photo at home every \(Int(minutesBetweenPhotosAtHome)) min: \(found) of \(total) window photos found (\(alone) alone), \(counted) count"
        #expect(found * 100 >= alone * 97, "\(line)")
        #expect(counted * 10 <= total, "\(line)")
    }

    /// The same on the map: one flight Munich → Lisbon with a window photo every ten minutes, and
    /// a photo at home in Regensburg every half hour all day. France, flown over, was a visited
    /// country with 9 photos; now none of them but the first counts. That one, ten minutes after
    /// take-off, is within reach of the photos at home before and after it (a zig-zag) and counts.
    @Test func someoneAtHomeInASharedLibraryMakesNoCountryFlownOver() {
        let trip = AlbumistID("lisbon")
        let journey = Self.flight("out", from: Self.munichAirport, to: Self.lisbonAirport, takeoff: MapFixture.date("2024-04-02 09:00")) {
            Self.every(10, of: $0)
        }
        var facts = journey.photos.map { photo -> AssetFacts in
            let window = journey.window.contains(photo.id), gate = photo.id.rawValue.contains("gate")
            var fact = MapFixture.photo(photo.id.rawValue, at: photo.creationDate!, photo.location, country: window ? "FR" : gate ? "DE" : "PT",
                                        town: window ? "Wolken" : gate ? "Freising" : "Lissabon", trip: trip)
            fact.asset = photo
            return fact
        }
        facts += MapFixture.burst("lis", count: 8, at: Places.lisbon, day: "2024-04-03", country: "PT", town: "Lissabon", trip: trip)
        // The traveller alone: every window photo is found.
        #expect(AirborneFilter.airborne(facts.map(\.asset)) == journey.window)
        let home = (0..<28).map { k in
            MapFixture.photo("home-\(k)", at: MapFixture.date("2024-04-02 07:17").addingTimeInterval(Double(k) * 1_800),
                             Fixture.jitter(Places.regensburg, seed: k, meters: 300), country: "DE", town: "Regensburg", atHome: true)
        }
        let input = MapInput(facts: home + facts, trips: [MapFixture.trip(trip, facts)],
                             detectedHome: DetectedHome(center: Places.regensburg, since: nil, photoDays: 400), calendar: MapFixture.calendar,
                             now: MapFixture.date("2024-07-01"))
        let judged = AirborneFilter.judge(input.facts.map(\.asset))
        #expect(judged.airborne == journey.window.subtracting(["out-w-0"]))
        #expect(judged.isOnTheGround("out-w-0") && home.allSatisfy { judged.isOnTheGround($0.id) })
        let summary = MapSummary.build(input)
        #expect(!summary.countries.map(\.code).contains("FR"), "countries \(summary.countries.map { "\($0.code) (\($0.photoCount))" })")
    }

    /// Finding 10: Munich, Florence and Rome lie on a line.
    @Test func munichFlorenceAndRomeStayOnTheGround() {
        let t0 = MapFixture.date("2024-06-01 09:00")
        // Three people's photos in the same minutes.
        var same: [AssetSnapshot] = []
        for k in 0..<40 { same.append(Self.shot("m-\(k)", Self.minutes(t0, Double(k) * 3), Fixture.jitter(Places.munich, seed: k, meters: 800))) }
        for k in 0..<30 { same.append(Self.shot("f-\(k)", Self.minutes(t0, Double(k) * 4 + 0.5), Fixture.jitter(Places.florence, seed: k, meters: 800))) }
        for k in 0..<24 { same.append(Self.shot("r-\(k)", Self.minutes(t0, Double(k) * 5 + 0.8), Fixture.jitter(Places.rome, seed: k, meters: 800))) }
        #expect(AirborneFilter.airborne(same).isEmpty)
        // One after another, round and round every 20 to 35 minutes: Florence lies on the way from
        // Munich to Rome, but then the "flight" turns back to Munich.
        for minutes in [20.0, 25, 30, 35] {
            let cities = [Places.munich, Places.florence, Places.rome]
            let round = (0..<18).map { k in
                Self.shot("round-\(minutes)-\(k)", Self.minutes(t0, Double(k) * minutes), Fixture.jitter(cities[k % 3], seed: k, meters: 800))
            }
            #expect(AirborneFilter.airborne(round).isEmpty, "\(minutes)")
        }
        // The same with several photos at Munich and at Rome each time.
        var stays: [AssetSnapshot] = []
        var time = t0
        for k in 0..<18 {
            let count = k % 3 == 1 ? 1 : 3
            for s in 0..<count {
                stays.append(Self.shot("stay-\(k)-\(s)", time.addingTimeInterval(Double(s) * 180), Fixture.jitter([Places.munich, Places.florence, Places.rome][k % 3], seed: s, meters: 800)))
            }
            time = Self.minutes(time, 25 + Double(count - 1) * 3)
        }
        #expect(AirborneFilter.airborne(stays).isEmpty)
    }

    /// The limit of finding 10 (documented): once, and never back, a single photo at Florence
    /// half an hour after Munich and half an hour before Rome is just what a window photo over
    /// Florence on a flight from Munich to Rome looks like.
    @Test func aSinglePhotoOnTheWayFromMunichToRomeOnceLooksLikeAFlight() {
        let t0 = MapFixture.date("2024-06-01 09:00")
        let photos = (0..<3).map { Self.shot("m-\($0)", Self.minutes(t0, Double($0) * 3), Fixture.jitter(Places.munich, seed: $0, meters: 500)) }
            + [Self.shot("f", Self.minutes(t0, 36), Places.florence)]
            + (0..<3).map { Self.shot("r-\($0)", Self.minutes(t0, 66 + Double($0) * 3), Fixture.jitter(Places.rome, seed: $0, meters: 500)) }
        #expect(AirborneFilter.airborne(photos) == ["f"])
        // Two photos at Florence a minute apart are a stay.
        let two = photos + [Self.shot("f-2", Self.minutes(t0, 37), Fixture.jitter(Places.florence, seed: 9, meters: 300))]
        #expect(AirborneFilter.airborne(two).isEmpty)
    }

    @Test func aWrongLocationComesBack() {
        // A day in Munich with a photo every 15 minutes, and wrong locations: Rome, 40 km, 8 km, and
        // two in a row 60 km away.
        func day(_ name: String, wrong: [Int: GeoCoordinate]) -> [AssetSnapshot] {
            (0..<24).map { i in
                Self.shot("\(name)-\(i)", Self.minutes(MapFixture.date("2023-06-18 08:00"), Double(i) * 15),
                          wrong[i] ?? Fixture.jitter(Places.munich, seed: i, meters: 2_000))
            }
        }
        let far = Self.offset(Places.munich, km: 60, bearing: 90)
        for wrong in [[10: Places.rome], [10: Self.offset(Places.munich, km: 40, bearing: 300)], [10: Self.offset(Places.munich, km: 8, bearing: 10)],
                      [10: far, 11: Self.offset(far, km: 1, bearing: 0)]] {
            #expect(AirborneFilter.airborne(day("wrong", wrong: wrong)).isEmpty, "\(wrong)")
        }
        // A wrong location 30 km away a minute after a photo, in a burst: one fast leg, no run.
        var burst = (0..<10).map { i in Self.shot("b-\(i)", MapFixture.date("2023-06-19 12:00").addingTimeInterval(Double(i) * 20),
                                                  Fixture.jitter(Places.munich, seed: i, meters: 300)) }
        burst[5].location = Self.offset(Places.munich, km: 30, bearing: 45)
        #expect(AirborneFilter.airborne(burst).isEmpty)
    }
}
