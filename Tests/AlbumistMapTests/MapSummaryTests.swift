import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// "Deine Welt" from end to end (concept §5, §8, §11): a small library as the analysis stores it,
/// through `MapSummary.build`, to what the app, the diagnostic report and the share images get.
@Suite("Map summary")
struct MapSummaryTests {
    /// Home in the Regensburg area since 2022. Iceland in June 2023, flown from Munich with three
    /// photos out of the plane window over Britain; Portugal in April 2024 (Lisbon, then Porto);
    /// a day in Passau (about 110 km away) and an afternoon in Straubing (under 50 km).
    struct World {
        static let home = MapFixture.Places.regensburg
        static let hamburg = MapFixture.at(53.5511, 9.9937)
        static let munichAirport = MapFixture.at(48.3538, 11.7861)
        static let keflavik = MapFixture.at(63.9850, -22.6056)
        static let passau = MapFixture.at(48.5667, 13.4319)
        static let straubing = MapFixture.at(48.8777, 12.5730)
        static let iceland = AlbumistID("iceland"), portugal = AlbumistID("portugal")
        static let passauTrip = AlbumistID("passau"), straubingTrip = AlbumistID("straubing")
        static let window: Set<AssetID> = ["window-1", "window-2", "window-3"]
        static let now = MapFixture.date("2025-07-01")

        var facts: [AssetFacts] = []
        var trips: [Trip] = []

        /// `homeUntil2024`: the everyday photos before 2024 are in Hamburg (a move).
        init(homeUntil2024: GeoCoordinate = World.home) {
            var tripFacts: [AssetFacts] = []
            func add(_ id: AlbumistID, _ photos: [AssetFacts]) {
                let members = MapFixture.members(photos, of: id)
                tripFacts += members
                trips.append(MapFixture.trip(id, members))
            }

            // Iceland: gate in Munich at 06:00, take-off 06:30, 800 km/h over the ground, window
            // photos a third, half and two thirds of the way, a photo at Keflavík after landing.
            let rvk = "Atlantic/Reykjavik"
            let flight = GeoMath.distance(Self.munichAirport, Self.keflavik), speed = 800_000.0 / 3_600
            let gate = MapFixture.date("2023-06-14 06:00")
            var iceland = [MapFixture.photo("gate", at: gate, Self.munichAirport, country: "DE", town: "Freising", timeZone: "Europe/Berlin")]
            for (k, f) in [0.35, 0.5, 0.65].enumerated() {
                iceland.append(MapFixture.photo("window-\(k + 1)", at: gate.addingTimeInterval(1_800 + f * flight / speed),
                                                MapLibrary.along(Self.munichAirport, Self.keflavik, f), country: "GB", town: "Wolken",
                                                timeZone: "Europe/London"))
            }
            iceland.append(MapFixture.photo("landing", at: gate.addingTimeInterval(1_800 + flight / speed + 1_200), Self.keflavik,
                                            country: "IS", town: "Keflavík", timeZone: rvk))
            let p = MapFixture.Places.self
            iceland += MapFixture.burst("rvk-1", count: 12, at: p.reykjavik, day: "2023-06-14", hour: 13, country: "IS", town: "Reykjavík", timeZone: rvk)
            iceland += MapFixture.burst("thing", count: 6, at: p.thingvellir, day: "2023-06-15", hour: 9, country: "IS", town: "Þingvellir", timeZone: rvk)
            iceland += MapFixture.burst("geysir", count: 5, at: p.geysir, day: "2023-06-15", hour: 12, country: "IS", town: "Geysir", timeZone: rvk)
            iceland += MapFixture.burst("gullfoss", count: 4, at: p.gullfoss, day: "2023-06-15", hour: 14, country: "IS", town: "Gullfoss", timeZone: rvk)
            iceland += MapFixture.burst("selja", count: 8, at: p.seljalandsfoss, day: "2023-06-16", hour: 10, country: "IS", town: "Seljalandsfoss",
                                        timeZone: rvk)
            iceland += MapFixture.burst("skoga", count: 6, at: p.skogafoss, day: "2023-06-16", hour: 13, country: "IS", town: "Skógafoss", timeZone: rvk)
            iceland += MapFixture.burst("vik-1", count: 10, at: p.vik, day: "2023-06-17", hour: 10, country: "IS", town: "Vík", timeZone: rvk)
            iceland += MapFixture.burst("vik-2", count: 5, at: p.vik, day: "2023-06-18", hour: 10, country: "IS", town: "Vík", timeZone: rvk)
            iceland += MapFixture.burst("rvk-2", count: 10, at: p.reykjavik, day: "2023-06-21", hour: 12, country: "IS", town: "Reykjavík", timeZone: rvk)
            iceland += MapFixture.burst("rvk-3", count: 3, at: p.reykjavik, day: "2023-06-22", hour: 8, country: "IS", town: "Reykjavík", timeZone: rvk)
            add(Self.iceland, iceland)

            var portugal: [AssetFacts] = []
            for day in 2...5 {
                portugal += MapFixture.burst("lis-\(day)", count: 8, at: p.lisbon, day: "2024-04-0\(day)", country: "PT", town: "Lissabon",
                                             timeZone: "Europe/Lisbon")
            }
            for day in 7...9 {
                portugal += MapFixture.burst("opo-\(day)", count: 8, at: p.porto, day: "2024-04-0\(day)", country: "PT", town: "Porto",
                                             timeZone: "Europe/Lisbon")
            }
            add(Self.portugal, portugal)
            add(Self.passauTrip, MapFixture.burst("passau", count: 10, at: Self.passau, day: "2024-07-13", country: "DE", town: "Passau",
                                                  timeZone: "Europe/Berlin"))
            add(Self.straubingTrip, MapFixture.burst("straubing", count: 8, at: Self.straubing, day: "2024-08-03", hour: 14, country: "DE",
                                                     town: "Straubing", timeZone: "Europe/Berlin"))

            // Everyday photos at home every third day, none on the days of a trip.
            let tripDays = trips.map { $0.start.addingTimeInterval(-86_400)...$0.end.addingTimeInterval(86_400) }
            let before = MapFixture.everyday("home-a", from: "2022-01-01", to: "2023-12-31", at: homeUntil2024, country: "DE", everyNthDay: 3)
            let after = MapFixture.everyday("home-b", from: "2024-01-01", to: "2025-06-30", at: Self.home, country: "DE", everyNthDay: 3)
            facts = (before + after).filter { fact in !tripDays.contains { $0.contains(fact.asset.creationDate!) } } + tripFacts
        }

        func input(settings: HomeSettings = HomeSettings(), detected: DetectedHome? = DetectedHome(center: World.home, since: nil, photoDays: 400),
                   titles: [AlbumistID: String] = [:], running: Bool = false) -> MapInput {
            MapInput(facts: facts, trips: trips, tripTitles: titles, homeSettings: settings, detectedHome: detected,
                     calendar: MapFixture.calendar, now: Self.now, analysisRunning: running)
        }
    }

    static let world = World()
    static let summary = MapSummary.build(world.input(titles: [World.iceland: "Island, Ringstraße"]))

    @Test func tripsInTheirOrderWithTheirNamesAndPlaces() throws {
        let summary = Self.summary
        #expect(summary.trips.map(\.id) == [World.iceland, World.portugal, World.passauTrip, World.straubingTrip])
        // The app's name where it gave one, else the place with the most photos.
        #expect(summary.trips.map(\.title) == ["Island, Ringstraße", "Lissabon", "Passau", "Straubing"])
        let iceland = try #require(summary.trip(World.iceland)).geometry
        #expect(iceland.destinationName == "Reykjavík")
        #expect(iceland.places.count >= 7)
        #expect(iceland.route.count <= TripGeometry.maxRoutePoints)
        #expect(iceland.mainCountryKey == "IS")
        #expect(iceland.days == 9)
        let portugal = try #require(summary.trip(World.portugal)).geometry
        #expect(portugal.places.compactMap(\.name) == ["Lissabon", "Porto"])
        #expect(portugal.days == 8)
    }

    /// Concept §5: photos out of the plane window make no place, no country and no record.
    @Test func photosTakenInFlightCountForNothing() throws {
        let summary = Self.summary
        let iceland = try #require(summary.trip(World.iceland)).geometry
        #expect(iceland.airborneCount == World.window.count)
        #expect(iceland.countryPhotos["GB"] == nil)
        #expect(!iceland.places.contains { $0.countryKey == "GB" || $0.name == "Wolken" })
        #expect(summary.countries.map(\.code) == ["DE", "IS", "PT"])
        #expect(summary.numbers.countries == 3)
        // Three photos are enough for a country: without the filter Britain would be one.
        let unfiltered = MapCountries.compute(facts: Self.world.facts, airborne: [], tripStarts: [:])
        #expect(unfiltered.contains { $0.code == "GB" })
    }

    @Test func recordsComeFromTheTripsPlaces() throws {
        let numbers = Self.summary.numbers
        #expect(numbers.record(.northernmost)?.tripID == World.iceland)
        #expect(numbers.record(.westernmost)?.tripID == World.iceland)
        #expect(numbers.record(.farthest)?.tripID == World.iceland)
        #expect(numbers.record(.southernmost)?.tripID == World.portugal)
        #expect(numbers.record(.easternmost)?.tripID == World.passauTrip)
        // No altitude stored: no "Höchstes Foto".
        #expect(numbers.record(.highest) == nil)
        #expect(numbers.trips == 4)
        #expect(numbers.longestTripID == World.iceland)
        #expect(numbers.favoriteCountry?.code == "IS")
        #expect(numbers.firstTripYear == 2023)
        #expect(!numbers.isPreliminary)
        let traveled = Self.summary.trips.reduce(0) { $0 + $1.stats.metersTraveled }
        #expect(abs(numbers.metersTraveled - traveled) < 1)
    }

    /// Concept §5 and §8: home everyday photos are on no record, even where they would win.
    @Test func everydayPhotosAtHomeMakeNoRecord() throws {
        // Home in Hamburg, north of every trip: the northernmost place is still a trip's.
        var facts = MapFixture.everyday("hh", from: "2024-01-01", to: "2024-12-31", at: World.hamburg, country: "DE", everyNthDay: 2)
        let trip = AlbumistID("munich")
        let munich = MapFixture.members(MapFixture.burst("muc", count: 6, at: MapFixture.Places.munich, day: "2024-05-04", country: "DE",
                                                         town: "München"), of: trip)
        facts.removeAll { MapFixture.calendar.isDate($0.asset.creationDate!, inSameDayAs: MapFixture.date("2024-05-04")) }
        facts += munich
        let summary = MapSummary.build(MapInput(facts: facts, trips: [MapFixture.trip(trip, munich)],
                                                detectedHome: DetectedHome(center: World.hamburg, since: nil, photoDays: 180),
                                                calendar: MapFixture.calendar, now: World.now))
        let north = try #require(summary.numbers.record(.northernmost))
        #expect(north.tripID == trip)
        #expect(north.coordinate.latitude < 48.2)
        // No pin and no arc stand at home.
        #expect(summary.pins.allSatisfy { GeoMath.distance($0.coordinate, World.hamburg) > 100_000 })
    }

    /// Trips with nothing to draw are left out; one whose places are not named yet is not.
    @Test func tripsWithNothingToDrawAreLeftOut() throws {
        var world = Self.world
        // Its photos deleted since the analysis.
        world.trips.append(Trip(id: AlbumistID("gone"), start: MapFixture.date("2024-09-01"), end: MapFixture.date("2024-09-03"),
                                geotaggedAssetIDs: ["gone-1"], inferredAssetIDs: [], centroid: MapFixture.Places.rome,
                                maxDistanceFromHomeMeters: 0, distinctStops: 1, kind: .vacation))
        // Only screenshots.
        let shots = AlbumistID("shots"), unnamedTrip = AlbumistID("unnamed")
        let screenshots = MapFixture.members(MapFixture.burst("shot", count: 4, at: MapFixture.Places.rome, day: "2024-10-01"), of: shots)
            .map { fact -> AssetFacts in var fact = fact; fact.asset.subtypes = [.screenshot]; return fact }
        world.facts += screenshots
        world.trips.append(MapFixture.trip(shots, screenshots))
        // Two photos in Florence, their places not named yet.
        let unnamed = MapFixture.members(MapFixture.burst("flo", count: 2, at: MapFixture.Places.florence, day: "2024-11-02"), of: unnamedTrip)
        world.facts += unnamed
        world.trips.append(MapFixture.trip(unnamedTrip, unnamed))
        // A trip stored twice.
        world.trips.append(world.trips[1])

        let summary = MapSummary.build(world.input())
        #expect(summary.trips.map(\.id) == [World.iceland, World.portugal, World.passauTrip, World.straubingTrip, unnamedTrip])
        let florence = try #require(summary.trip(unnamedTrip))
        #expect(GeoMath.distance(florence.geometry.destination, MapFixture.Places.florence) < 1_000)
        #expect(summary.arcs.contains { $0.tripIDs.contains(unnamedTrip) })
        #expect(summary.numbers.trips == 5)
    }

    @Test func theSameLibraryInAnyOrderGivesTheSameSummary() throws {
        var random = MapRandom(seed: 3)
        var facts = Self.world.facts, trips = Self.world.trips
        for i in facts.indices.reversed() { facts.swapAt(i, random.int(0..<(i + 1))) }
        trips.reverse()
        let shuffled = MapSummary.build(MapInput(facts: facts, trips: trips, tripTitles: [World.iceland: "Island, Ringstraße"],
                                                 detectedHome: DetectedHome(center: World.home, since: nil, photoDays: 400),
                                                 calendar: MapFixture.calendar, now: World.now))
        #expect(shuffled == Self.summary)
    }

    /// Concept §5: while the analysis runs no number of "Deine Welt in Zahlen" goes down (a
    /// record, the longest trip, the busiest day and the favourite only while that stays true of
    /// what they lead to); once it is done they may. Lists (trips, countries, years, pins) are
    /// always the current state.
    @Test func whileTheAnalysisRunsNumbersHoldThenMayShrink() throws {
        var partial = Self.world
        partial.trips.removeAll { $0.id == World.portugal || $0.id == World.passauTrip }
        partial.facts.removeAll { $0.tripID == World.portugal || $0.tripID == World.passauTrip }
        let running = MapSummary.build(partial.input(running: true), previous: Self.summary)
        #expect(running.numbers.isPreliminary)
        #expect(running.numbers.trips == 4)
        #expect(running.numbers.countries == 3)
        #expect(running.numbers.metersTraveled >= Self.summary.numbers.metersTraveled)
        // What the map draws is always the current state.
        #expect(running.trips.count == 2)
        // A held record or trip must still lead somewhere: the southernmost (Lisbon) and the
        // easternmost (Passau) of the complete summary belong to trips the running analysis has
        // not found again, so the current ones stand (review finding 7).
        #expect(Self.summary.numbers.record(.southernmost)?.tripID == World.portugal)
        #expect(Self.summary.numbers.record(.easternmost)?.tripID == World.passauTrip)
        for record in running.numbers.records {
            let places = running.trip(record.tripID)?.geometry.places.count ?? 0
            #expect((0..<places).contains(record.placeIndex), "\(record.kind)")
        }
        #expect(running.numbers.record(.southernmost)?.tripID == World.straubingTrip)
        if let longest = running.numbers.longestTripID { #expect(running.trip(longest) != nil) }
        if let day = running.numbers.mostPhotosInADay { #expect(running.trip(day.tripID) != nil) }
        if let favorite = running.numbers.favoriteCountry { #expect(running.countries.contains { $0.code == favorite.code }) }
        let done = MapSummary.build(partial.input(running: false), previous: Self.summary)
        #expect(!done.numbers.isPreliminary)
        #expect(done.numbers.trips == 2)
        #expect(done.numbers.countries == 2)
    }

    /// A library listing photos twice gives the map of listing them once: one photo three times
    /// would otherwise make a place and a record (review finding 5).
    @Test func aPhotoListedTwiceCountsOnce() throws {
        var twice = Self.world
        twice.facts += Self.world.facts.reversed()
        #expect(MapSummary.build(twice.input(titles: [World.iceland: "Island, Ringstraße"])) == Self.summary)
        // One photo at Longyearbyen listed three times, on a trip with three photos in Tromsø: no
        // place at Longyearbyen, so no "Nördlichster Ort" there, and the trip has 4 photos.
        var svalbard = Self.world
        let tripID = AlbumistID("svalbard")
        let lone = MapFixture.photo("lyr", at: MapFixture.date("2025-03-02 12:00"), MapFixture.Places.longyearbyen, country: "NO",
                                    town: "Longyearbyen")
        let tromso = MapFixture.burst("tos", count: 3, at: MapFixture.at(69.6492, 18.9553), day: "2025-03-01", country: "NO", town: "Tromsø")
        let members = MapFixture.members([lone, lone, lone] + tromso, of: tripID)
        svalbard.facts += members
        svalbard.trips.append(MapFixture.trip(tripID, members))
        let summary = MapSummary.build(svalbard.input())
        let trip = try #require(summary.trip(tripID))
        #expect(trip.geometry.photoCount == 4)
        #expect(trip.geometry.places.map(\.name) == ["Tromsø"])
        #expect(summary.numbers.record(.northernmost)?.placeName == "Tromsø")
    }

    /// Every year on the map is the Gregorian year of a local day: a Japanese, Buddhist or Islamic
    /// calendar on the iPhone changes nothing (review finding 8).
    @Test func theDevicesCalendarChangesNoYear() throws {
        for identifier in [Calendar.Identifier.japanese, .buddhist, .islamicUmmAlQura, .hebrew] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = MapFixture.calendar.timeZone
            var input = Self.world.input(titles: [World.iceland: "Island, Ringstraße"])
            input.calendar = calendar
            #expect(MapSummary.build(input) == Self.summary, "\(identifier)")
        }
        #expect(Self.summary.years.map(\.year) == Array(2023...2025))
        #expect(Self.summary.numbers.year == 2025 && Self.summary.numbers.firstTripYear == 2023)
        #expect(Self.summary.countries.map(\.firstVisitYear).allSatisfy { (2022...2025).contains($0) })
    }

    /// A country lists only the trips the map shows: the photos of a trip that is not stored still
    /// count for the country, but neither "Neues Land" nor the country's pin leads to that trip
    /// (review finding 11).
    @Test func countriesLeadOnlyToTripsOnTheMap() throws {
        var ghost = Self.world
        ghost.facts += MapFixture.members(MapFixture.burst("paris", count: 4, at: MapFixture.at(48.8566, 2.3522), day: "2025-05-01", country: "FR",
                                                           town: "Paris"), of: AlbumistID("ghost"))
        let summary = MapSummary.build(ghost.input())
        let france = try #require(summary.countries.first { $0.code == "FR" })
        #expect(france.tripIDs.isEmpty)
        #expect(summary.countries.allSatisfy { $0.tripIDs.allSatisfy { summary.trip($0) != nil } })
        let event = try #require(MapYears.newCountries(since: [], countries: summary.countries).first { $0.code == "FR" })
        #expect(event.tripID == nil)
        #expect(!summary.pins.contains { $0.id == "country:FR" })
    }
}
