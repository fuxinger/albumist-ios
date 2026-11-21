import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Series of window photos and altitudes: a series over Siberia hours after the gate photo, three
/// quick window photos and quick series of them, a series without a flown leg and a burst that
/// does not head on; altitudes above 6,000 m, the climb out, the final approach and right after
/// take-off, and summits, cable cars and mountain railways that keep their photos.
extension AirborneFilterTests {
    /// Finding 1: a gate photo in Frankfurt, five hours later four window photos three seconds
    /// apart over Russia, then Tokyo. Unfiltered they make Russia a country, a place "Wolke" and
    /// the northernmost place.
    @Test func aSeriesOverSiberiaFiveHoursAfterTheGatePhotoIsFound() throws {
        let trip = AlbumistID("tokyo")
        let takeoff = MapFixture.date("2024-10-05 12:40")
        let path = Flight(from: Self.frankfurtAirport, to: Self.naritaAirport, takeoff: takeoff, cruiseKmh: 880)
        var facts = [MapFixture.photo("gate", at: Self.minutes(takeoff, -40), Self.frankfurtAirport, country: "DE", town: "Frankfurt am Main",
                                      timeZone: "Europe/Berlin", trip: trip)]
        let window = Self.series(at: 260, count: 4, seconds: 3).enumerated().map { k, minutes in
            MapFixture.photo("cloud-\(k)", at: path.date(minutes: minutes), path.position(minutes: minutes), country: "RU", town: "Wolke",
                             timeZone: "Asia/Yekaterinburg", trip: trip)
        }
        facts += window
        facts.append(MapFixture.photo("narita", at: Self.minutes(path.landing, 30), Self.naritaAirport, country: "JP", town: "Narita",
                                      timeZone: "Asia/Tokyo", trip: trip))
        for day in 6...9 {
            facts += MapFixture.members(MapFixture.burst("tokyo-\(day)", count: 8, at: Places.tokyo, day: "2024-10-0\(day)", hour: 2, country: "JP",
                                                         town: "Tokio", timeZone: "Asia/Tokyo"), of: trip)
        }
        let all = MapFixture.everyday("home", from: "2024-09-01", to: "2024-10-04", at: Places.regensburg, country: "DE") + facts
        #expect(window.allSatisfy { $0.asset.location!.latitude > 55 && $0.asset.location!.longitude > 45 })

        #expect(AirborneFilter.airborne(all.map(\.asset)) == Set(window.map(\.id)))
        let summary = MapSummary.build(MapInput(facts: all, trips: [MapFixture.trip(trip, facts)],
                                                detectedHome: DetectedHome(center: Places.regensburg, since: nil, photoDays: 30),
                                                calendar: MapFixture.calendar, now: MapFixture.date("2024-11-01")))
        #expect(summary.countries.map(\.code).sorted() == ["DE", "JP"])
        #expect(!summary.trips.contains { $0.geometry.places.contains { $0.name == "Wolke" } })
        let north = try #require(summary.numbers.record(.northernmost))
        #expect(north.coordinate.latitude < 40)
        // Without the filter Russia would count (four photos, three are enough).
        #expect(MapCountries.compute(facts: all, airborne: [], tripStarts: [:]).contains { $0.code == "RU" })
    }

    /// Finding 1 of the second review: three quick window photos with no photo near enough in time
    /// for a leg (none at all before them, or the gate photo 2 h 45 min before) were no burst.
    /// They made France a country, a place "Wolken" and the northernmost place. Now they head on,
    /// towards Lisbon (and away from the gate photo).
    @Test(arguments: [nil, 9_900] as [TimeInterval?])
    func threeQuickWindowPhotosMakeNoCountryAndNoPlace(gate: TimeInterval?) {
        let input = Self.lisbonLibrary(gateSecondsBefore: gate)
        #expect(AirborneFilter.airborne(input.facts.map(\.asset)) == ["window-0", "window-1", "window-2"])
        let summary = MapSummary.build(input)
        #expect(!summary.countries.map(\.code).contains("FR"))
        #expect(!summary.trips.contains { $0.geometry.places.contains { $0.name == "Wolken" } })
        #expect(summary.numbers.record(.northernmost)?.placeName != "Wolken")
        #expect(summary.trips.map(\.geometry.airborneCount) == [3])
    }

    /// A quick series of window photos of `quickSeriesOfWindowPhotosMakeNoCountry`: its photos'
    /// seconds after 09:15, the fix each photo gets for its seconds, and whether the rules find it.
    struct QuickSeries {
        var name: String
        var seconds: [Double]
        var fix: (Double) -> Double
        var found: Bool

        init(_ name: String, _ seconds: [Double], _ fix: @escaping (Double) -> Double, _ found: Bool) {
            self.name = name
            self.seconds = seconds
            self.fix = fix
            self.found = found
        }
    }

    /// Finding 2.2 of the third review: a quick series was a burst only when every step from one
    /// photo to the next was 200 m and more and the steps were within a factor of 1.5. Two photos
    /// of one moment (HDR with "Keep Normal Photo", a duplicate) broke the chain, and a photo half
    /// a second after a found series stayed on the ground and added its town. Photos within a
    /// second of each other, or on the fix of the photo before, are one moment now
    /// (`AirborneFilter.sampleDuration`): the series is judged moment to moment, and all its
    /// photos go with it.
    ///
    /// Documented: a series of fewer than three moments (three photos 0.8 or 0.3 seconds apart, a
    /// pair half a second apart and a third four seconds later), or on fixes of a one-second clock
    /// that make its steps uneven (1.5 seconds apart: steps of one and two seconds of flight), is
    /// no burst. With a flown leg (here to the arrival photo) it is maybe in flight and counts
    /// for nothing (`FlightJudgement`): no country, no place, no town.
    @Test func quickSeriesOfWindowPhotosMakeNoCountry() {
        let lastFullSecond: (Double) -> Double = { $0.rounded(.down) }
        let cases = [
            QuickSeries("three 4 s apart, each kept twice", [0, 0, 4, 4, 8, 8], { $0 }, true),
            QuickSeries("three 4 s apart and a fourth half a second after the third", [0, 4, 8, 8.5], { $0 }, true),
            QuickSeries("three 0.8 s apart", [0, 0.8, 1.6], { $0 }, false),
            QuickSeries("three kept of a burst, 0.3 s apart", [0, 0.3, 0.6], { $0 }, false),
            QuickSeries("three 1.5 s apart, each with the fix of the last full second", [0, 1.5, 3], lastFullSecond, false),
            QuickSeries("a pair half a second apart and a third 4 s later", [0, 0.5, 4.5], { $0 }, false),
        ]
        for quick in cases {
            let (name, seconds, fix, found) = (quick.name, quick.seconds, quick.fix, quick.found)
            let input = Self.lisbonLibrary(gateSecondsBefore: 9_900, windowAt: seconds, fix: fix)
            let window = Set(seconds.indices.map { AssetID("window-\($0)") })
            let judged = AirborneFilter.judge(input.facts.map(\.asset))
            #expect(found ? judged.airborne == window : judged.maybeInFlight.isSuperset(of: window),
                    "\(name): in flight \(judged.airborne.sorted()), maybe \(judged.maybeInFlight.sorted())")
            let summary = MapSummary.build(input)
            #expect(!summary.countries.map(\.code).contains("FR"), "\(name): countries \(summary.countries.map(\.code))")
            #expect(!summary.trips.contains { $0.geometry.places.contains { $0.name == "Wolken" } }, "\(name): a place in the clouds")
            #expect(summary.numbers.cities == 2, "\(name): \(summary.numbers.cities) towns")
        }
    }

    /// Rule 3: a short flight whose only window photos are one series, both legs to the airports
    /// slow (gate 40 minutes before take-off, arrival 40 minutes after landing). Four photos are a
    /// burst on their own; three head on, away from Munich and towards Rome (they were missed).
    @Test func aSeriesWithoutAFlownLegIsFound() {
        let takeoff = MapFixture.date("2024-06-01 07:00")
        for count in [4, 3] {
            let journey = Self.flight("fco-\(count)", from: Self.munichAirport, to: Self.romeAirport, takeoff: takeoff, cruiseKmh: 800,
                                      arrival: [40]) { _ in Self.series(at: 30, count: count, seconds: 3) }
            #expect(AirborneFilter.airborne(journey.photos) == journey.window, "\(count)")
            // Without the gate photo, or without the arrival photo: one leg is enough.
            for side in ["gate", "arr"] {
                let photos = journey.photos.filter { !$0.id.rawValue.contains("-\(side)-") }
                #expect(AirborneFilter.airborne(photos) == journey.window, "\(count) without \(side)")
            }
        }
    }

    /// Documented misses of rule 3: a burst of three that does not head on. Alone, with no photo
    /// within `maximumLongLegDuration` on either side; or in a turn, here flying east at 600 km/h
    /// 40 km south of Munich, across the way from the gate photo to the arrival photo in Rome.
    @Test func aBurstOfThreeThatDoesNotHeadOnIsMissed() {
        let takeoff = MapFixture.date("2024-06-01 07:00")
        let journey = Self.flight("alone", from: Self.munichAirport, to: Self.romeAirport, takeoff: takeoff, cruiseKmh: 800, arrival: [40]) { _ in
            Self.series(at: 30, count: 3, seconds: 4)
        }
        #expect(AirborneFilter.airborne(journey.photos) == journey.window)
        #expect(AirborneFilter.airborne(journey.windowPhotos).isEmpty)
        let start = Self.offset(Self.munichAirport, km: 40, bearing: 180)
        let turn = (0..<3).map { k in
            Self.shot("turn-\(k)", Self.minutes(takeoff, 6).addingTimeInterval(Double(k) * 4),
                      Self.offset(start, km: Double(k) * 0.667, bearing: 90))
        }
        #expect(AirborneFilter.airborne(journey.photos.filter { !journey.window.contains($0.id) } + turn).isEmpty)
    }

    @Test func altitudeAboveSixThousandMetresIsAFlight() {
        // Slow photos on the ground, one with a cruising altitude, one on a mountain.
        let t0 = MapFixture.date("2023-08-01 10:00")
        let zugspitze = MapFixture.at(47.4211, 10.9853)
        let photos = (0..<6).map { i in Self.shot("alt-\(i)", t0.addingTimeInterval(Double(i) * 1_800), Fixture.jitter(zugspitze, seed: i, meters: 300)) }
        let altitudes: [AssetID: Double] = ["alt-0": 10_500, "alt-1": 2_900, "alt-2": 6_000, "alt-3": .nan, "alt-4": -400]
        #expect(AirborneFilter.airborne(photos, altitudes: altitudes) == ["alt-0"])
        #expect(AirborneFilter.airborne(photos).isEmpty)
    }

    /// Finding 1 of the second review, with altitudes (as the analysis will store them): three
    /// photos five seconds apart in the climb out of Munich at 350 km/h, 3,500 to 3,580 m up. Too
    /// slow for a burst at sea level (`burstSpeed`); they made "Höchstes Foto: Wolken 3540 m".
    @Test func climbOutPhotosMakeNoHighestPhoto() {
        let trip = AlbumistID("lisbon"), t = MapFixture.date("2024-04-02 08:00")
        let way = GeoMath.distance(Self.munichAirport, Self.lisbonAirport)
        var photos = [MapFixture.photo("gate", at: t.addingTimeInterval(-3_000), Self.munichAirport, country: "DE", town: "Freising")]
        var altitudes: [AssetID: Double] = ["gate": 450]
        for k in 0..<3 {
            photos.append(MapFixture.photo("climb-\(k)", at: t.addingTimeInterval(Double(k) * 5),
                                           Self.along(Self.munichAirport, Self.lisbonAirport, (35_000 + Double(k) * 5 * 97) / way), country: "DE",
                                           town: "Wolken"))
            altitudes[AssetID("climb-\(k)")] = 3_500 + Double(k) * 40
        }
        photos.append(MapFixture.photo("landing", at: t.addingTimeInterval(3 * 3_600 + 600), Self.lisbonAirport, country: "PT", town: "Lissabon"))
        photos += MapFixture.burst("lis", count: 8, at: Places.lisbon, day: "2024-04-03", country: "PT", town: "Lissabon")
        for photo in photos where altitudes[photo.id] == nil { altitudes[photo.id] = 60 }
        let members = MapFixture.members(photos, of: trip)
        #expect(AirborneFilter.airborne(members.map(\.asset), altitudes: altitudes) == ["climb-0", "climb-1", "climb-2"])
        // Without altitudes they are missed (documented).
        #expect(AirborneFilter.airborne(members.map(\.asset)).isEmpty)
        let summary = MapSummary.build(MapInput(facts: members, trips: [MapFixture.trip(trip, members)], altitudes: altitudes,
                                                calendar: MapFixture.calendar, now: MapFixture.date("2024-07-01")))
        #expect(summary.numbers.record(.highest)?.placeName != "Wolken")
    }

    static let genevaAirport = MapFixture.at(46.2381, 6.1090)
    static let geneva = MapFixture.at(46.2044, 6.1432)

    /// A flight of `photosOnFinalApproachAndRightAfterTakeOffCountForNothing`: from and to which
    /// airport, the town at its end, the minutes after take-off of its series (negative: before
    /// landing), the country and town of its gate photo, of its series and at its end, and the
    /// airports' altitude.
    struct SeriesFlight {
        var from: GeoCoordinate
        var to: GeoCoordinate
        var town: GeoCoordinate
        var seriesAt: Double
        var origin: (String, String)
        var below: (String, String)
        var destination: (String, String)
        var field: Double
    }

    /// Finding 2.1 of the third review: the series people take out of the window on final
    /// approach and right after take-off. Lisbon → Geneva comes in over France: three photos four
    /// seconds apart three minutes before landing (380 km/h, 16 km out) moved on slower than
    /// `maximumGroundSpeed`, a "stay", so rule 4 refused them right next to the confirmed window
    /// photos. They made France a visited country, a town, a place and two records, and with
    /// stored altitudes "Höchstes Foto" (1,291 m). Munich → Lisbon: three photos three minutes
    /// after take-off made a place near the airport and "Höchstes Foto" (1,366 m). Next to a
    /// confirmed run a row shows a stay only when it moved on slower than
    /// `AirborneFilter.stayMovingSpeed`.
    @Test(arguments: [false, true])
    func photosOnFinalApproachAndRightAfterTakeOffCountForNothing(storedAltitudes: Bool) {
        /// A gate photo 40 minutes before take-off, window photos every ten minutes from ten
        /// minutes after take-off to ten before landing, three photos 4 s apart `minutes` after
        /// take-off (negative: before landing), the arrival photo 25 minutes after landing, four
        /// days in town. Altitudes: the airports' own, 10,500 m at cruise, three degrees up from
        /// the nearer airport.
        func library(_ flight: SeriesFlight) -> MapInput {
            let (from, to, town, minutes) = (flight.from, flight.to, flight.town, flight.seriesAt)
            let (origin, below, destination, field) = (flight.origin, flight.below, flight.destination, flight.field)
            let trip = AlbumistID("trip"), takeoff = MapFixture.date("2024-04-02 08:00")
            let path = Flight(from: from, to: to, takeoff: takeoff)
            var photos = [MapFixture.photo("gate", at: Self.minutes(takeoff, -40), from, country: origin.0, town: origin.1)]
            var altitudes: [AssetID: Double] = [:]
            for (k, m) in Self.every(10, of: path.minutes).enumerated() {
                photos.append(MapFixture.photo("cruise-\(k)", at: path.date(minutes: m), path.position(minutes: m), country: "ES", town: "Wolken"))
                altitudes[AssetID("cruise-\(k)")] = 10_500
            }
            for k in 0..<3 {
                let m = (minutes >= 0 ? minutes : path.minutes + minutes) + Double(k) * 4 / 60
                let position = path.position(minutes: m)
                photos.append(MapFixture.photo("series-\(k)", at: path.date(minutes: m), position, country: below.0, town: below.1))
                altitudes[AssetID("series-\(k)")] = field + 0.0524 * min(GeoMath.distance(from, position), GeoMath.distance(position, to))
            }
            photos.append(MapFixture.photo("arrival", at: Self.minutes(path.landing, 25), to, country: destination.0, town: destination.1))
            for day in 3...6 {
                photos += MapFixture.burst("town-\(day)", count: 8, at: town, day: "2024-04-0\(day)", country: destination.0, town: destination.1)
            }
            for photo in photos where altitudes[photo.id] == nil { altitudes[photo.id] = field }
            let members = MapFixture.members(photos, of: trip)
            return MapInput(facts: members, trips: [MapFixture.trip(trip, members)], altitudes: storedAltitudes ? altitudes : [:],
                            calendar: MapFixture.calendar, now: MapFixture.date("2024-07-01"))
        }
        let approach = library(SeriesFlight(from: Self.lisbonAirport, to: Self.genevaAirport, town: Self.geneva, seriesAt: -3,
                                            origin: ("PT", "Lissabon"), below: ("FR", "Saint-Julien"), destination: ("CH", "Genf"), field: 420))
        let climb = library(SeriesFlight(from: Self.munichAirport, to: Self.lisbonAirport, town: Places.lisbon, seriesAt: 3,
                                         origin: ("DE", "Freising"), below: ("DE", "Erding"), destination: ("PT", "Lissabon"), field: 450))
        for (name, input, town) in [("approach to Geneva", approach, "Saint-Julien"), ("climb out of Munich", climb, "Erding")] {
            let airborne = AirborneFilter.airborne(input.facts.map(\.asset), altitudes: input.altitudes)
            #expect(airborne.isSuperset(of: ["series-0", "series-1", "series-2"]),
                    "\(name): in flight \(airborne.filter { $0.rawValue.hasPrefix("series") }.sorted())")
            let summary = MapSummary.build(input)
            #expect(!summary.trips.contains { $0.geometry.places.contains { $0.name == town } }, "\(name)")
            let records = summary.numbers.records.filter { $0.placeName == town }.map { "\($0.kind.rawValue) \(Int($0.value))" }
            #expect(records.isEmpty, "\(name): records \(records)")
        }
        let summary = MapSummary.build(approach)
        #expect(!summary.countries.map(\.code).contains("FR"), "countries \(summary.countries.map(\.code))")
        #expect(summary.numbers.cities == 2, "\(summary.numbers.cities) towns")
    }

    /// A ride of `summitsCableCarsAndMountainRailwaysKeepTheirPhotos`: where it starts, which way
    /// (degrees clockwise from north) and how fast it goes, when it starts and how many minutes it
    /// takes.
    struct Ride {
        var from: GeoCoordinate
        var bearing: Double
        var kmh: Double
        var start: String
        var minutes: Double
    }

    /// What moves on the ground up there keeps its photos when altitudes are stored: nothing above
    /// `aloftAltitude` comes near `aloftBurstSpeed`. The summit day on Kilimanjaro (Uhuru Peak,
    /// 5,895 m) with series of photos at the top, the cable car up the Aiguille du Midi (43 km/h,
    /// 3,777 m at the top), the Qinghai–Tibet railway over the Tanggula pass (120 km/h, 5,072 m)
    /// and the Lanzhou–Xinjiang high-speed line in the Qilian mountains (250 km/h, 3,600 m):
    /// series of six photos one to four seconds apart, every half minute to two minutes, each fix
    /// up to 25 m off in either direction.
    @Test func summitsCableCarsAndMountainRailwaysKeepTheirPhotos() {
        var random = MapRandom(seed: 17)
        var photos: [AssetSnapshot] = [], altitudes: [AssetID: Double] = [:]
        func ride(_ name: String, _ way: Ride, altitude: (Double) -> Double) {
            let t0 = MapFixture.date(way.start)
            var t = 0.0
            while t <= way.minutes * 60 {
                for k in 0..<6 {
                    if k > 0 { t += 1 + 3 * random.unit() }
                    let id = "\(name)-\(photos.count)"
                    let truth = Self.offset(way.from, km: way.kmh * t / 3_600, bearing: way.bearing)
                    photos.append(Self.shot(id, t0.addingTimeInterval(t), Fixture.jitter(truth, seed: photos.count, meters: 50)))
                    altitudes[AssetID(id)] = altitude(min(1, t / (way.minutes * 60)))
                }
                t += 30 + 90 * random.unit()
            }
        }
        let uhuru = MapFixture.at(-3.0758, 37.3533)
        ride("kibo-up", Ride(from: Self.offset(uhuru, km: 1.2, bearing: 60), bearing: 240, kmh: 1.6, start: "2024-02-10 06:00",
                             minutes: 45)) { 5_756 + 139 * $0 }
        ride("kibo-top", Ride(from: uhuru, bearing: 0, kmh: 0, start: "2024-02-10 06:46", minutes: 20)) { _ in 5_895 }
        ride("midi", Ride(from: MapFixture.at(45.9046, 6.8869), bearing: 179, kmh: 43, start: "2024-07-20 09:00", minutes: 4)) { 2_317 + 1_460 * $0 }
        ride("qingzang", Ride(from: MapFixture.at(33.0700, 91.9800), bearing: 200, kmh: 120, start: "2024-08-03 11:00", minutes: 30)) { 5_072 - 200 * $0 }
        ride("lanxin", Ride(from: MapFixture.at(37.7000, 101.3000), bearing: 330, kmh: 250, start: "2024-09-14 15:00", minutes: 30)) { 3_400 + 200 * $0 }
        #expect(altitudes.values.filter { $0 > AirborneFilter.aloftAltitude }.count > 300)
        #expect(AirborneFilter.airborne(photos, altitudes: altitudes).isEmpty)
    }
}
