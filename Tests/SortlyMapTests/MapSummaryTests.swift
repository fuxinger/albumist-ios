import Foundation
import Testing
@testable import SortlyCore
@testable import SortlyMap
import SortlyTestSupport

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
        static let iceland = SortlyID("iceland"), portugal = SortlyID("portugal")
        static let passauTrip = SortlyID("passau"), straubingTrip = SortlyID("straubing")
        static let window: Set<AssetID> = ["window-1", "window-2", "window-3"]
        static let now = MapFixture.date("2025-07-01")

        var facts: [AssetFacts] = []
        var trips: [Trip] = []

        /// `homeUntil2024`: the everyday photos before 2024 are in Hamburg (a move).
        init(homeUntil2024: GeoCoordinate = World.home) {
            var tripFacts: [AssetFacts] = []
            func add(_ id: SortlyID, _ photos: [AssetFacts]) {
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
            let P = MapFixture.Places.self
            iceland += MapFixture.burst("rvk-1", count: 12, at: P.reykjavik, day: "2023-06-14", hour: 13, country: "IS", town: "Reykjavík", timeZone: rvk)
            iceland += MapFixture.burst("thing", count: 6, at: P.thingvellir, day: "2023-06-15", hour: 9, country: "IS", town: "Þingvellir", timeZone: rvk)
            iceland += MapFixture.burst("geysir", count: 5, at: P.geysir, day: "2023-06-15", hour: 12, country: "IS", town: "Geysir", timeZone: rvk)
            iceland += MapFixture.burst("gullfoss", count: 4, at: P.gullfoss, day: "2023-06-15", hour: 14, country: "IS", town: "Gullfoss", timeZone: rvk)
            iceland += MapFixture.burst("selja", count: 8, at: P.seljalandsfoss, day: "2023-06-16", hour: 10, country: "IS", town: "Seljalandsfoss", timeZone: rvk)
            iceland += MapFixture.burst("skoga", count: 6, at: P.skogafoss, day: "2023-06-16", hour: 13, country: "IS", town: "Skógafoss", timeZone: rvk)
            iceland += MapFixture.burst("vik-1", count: 10, at: P.vik, day: "2023-06-17", hour: 10, country: "IS", town: "Vík", timeZone: rvk)
            iceland += MapFixture.burst("vik-2", count: 5, at: P.vik, day: "2023-06-18", hour: 10, country: "IS", town: "Vík", timeZone: rvk)
            iceland += MapFixture.burst("rvk-2", count: 10, at: P.reykjavik, day: "2023-06-21", hour: 12, country: "IS", town: "Reykjavík", timeZone: rvk)
            iceland += MapFixture.burst("rvk-3", count: 3, at: P.reykjavik, day: "2023-06-22", hour: 8, country: "IS", town: "Reykjavík", timeZone: rvk)
            add(Self.iceland, iceland)

            var portugal: [AssetFacts] = []
            for day in 2...5 {
                portugal += MapFixture.burst("lis-\(day)", count: 8, at: P.lisbon, day: "2024-04-0\(day)", country: "PT", town: "Lissabon",
                                             timeZone: "Europe/Lisbon")
            }
            for day in 7...9 {
                portugal += MapFixture.burst("opo-\(day)", count: 8, at: P.porto, day: "2024-04-0\(day)", country: "PT", town: "Porto",
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
                   titles: [SortlyID: String] = [:], running: Bool = false) -> MapInput {
            MapInput(facts: facts, trips: trips, tripTitles: titles, homeSettings: settings, detectedHome: detected,
                     calendar: MapFixture.calendar, now: Self.now, analysisRunning: running)
        }
    }

    static let world = World()
    static let summary = MapSummary.build(world.input(titles: [World.iceland: "Island, Ringstraße"]))

    @Test func homeIsOnlyEverRounded() throws {
        let home = try #require(Self.summary.home)
        #expect(home.countryCode == "DE")
        #expect(home.coordinate == MapHome.rounded(World.home))
        #expect(home.coordinate != World.home)
        #expect(GeoMath.distance(home.coordinate, World.home) <= 7_200)
        // Every trip starts at that same rounded point.
        #expect(Self.summary.trips.allSatisfy { $0.home == home })
        #expect(Self.summary.arcs.allSatisfy { $0.from == home.coordinate })
    }

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
        let trip = SortlyID("munich")
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

    @Test func oneArcPerDestinationFromTheHomeOfTheTripsTime() throws {
        let arcs = Self.summary.arcs
        #expect(arcs.count == 4)
        #expect(Set(arcs.flatMap(\.tripIDs)) == [World.iceland, World.portugal, World.passauTrip, World.straubingTrip])
        #expect(arcs.count <= MapSummary.maxArcs)
        // After a move the trips before it start at the old home, the house is the new one.
        let moved = World(homeUntil2024: World.hamburg)
        let settings = HomeSettings(former: [FormerHome(place: HomePlace(center: World.hamburg, components: PlaceComponents(isoCountryCode: "DE")),
                                                        until: MapFixture.date("2024-01-01"))])
        let summary = MapSummary.build(moved.input(settings: settings))
        #expect(summary.trip(World.iceland)?.home?.coordinate == MapHome.rounded(World.hamburg))
        #expect(summary.trip(World.portugal)?.home?.coordinate == MapHome.rounded(World.home))
        #expect(summary.home?.coordinate == MapHome.rounded(World.home))
        let iceland = try #require(summary.arcs.first { $0.tripIDs.contains(World.iceland) })
        #expect(iceland.from == MapHome.rounded(World.hamburg))
    }

    /// Concept §11, "Kein Zuhause bekannt": no arcs, only pins; kilometres only on site.
    @Test func withoutAHomeNoArcsAndOnlyKilometresOnSite() throws {
        let summary = MapSummary.build(Self.world.input(settings: HomeSettings(mode: .none)))
        #expect(summary.home == nil)
        #expect(summary.arcs.isEmpty)
        #expect(!summary.pins.isEmpty)
        #expect(summary.trips.allSatisfy { $0.home == nil && $0.stats.metersFromHome == nil })
        #expect(summary.trips.allSatisfy { abs($0.stats.metersTraveled - $0.stats.metersOnSite) < 1 })
        #expect(summary.numbers.record(.farthest) == nil)
    }

    /// Concept §11, "Nur Fotos zu Hause" and "Kleiner Anfang".
    @Test func onlyHomeThenASmallStart() throws {
        let homeOnly = Self.world.facts.filter { $0.tripID == nil }
        let empty = MapSummary.build(MapInput(facts: homeOnly, trips: [], detectedHome: DetectedHome(center: World.home, since: nil, photoDays: 400),
                                              calendar: MapFixture.calendar, now: World.now))
        #expect(empty.trips.isEmpty && empty.arcs.isEmpty && empty.pins.isEmpty && empty.years.isEmpty)
        #expect(empty.focus == nil)
        #expect(empty.numbers.trips == 0)
        // The home country counts, as in the travel atlas.
        #expect(empty.countries.map(\.code) == ["DE"])

        // A small start: the globe comes closer, every destination still in view.
        let focus = try #require(Self.summary.focus)
        #expect(focus.radiusMeters < 5_000_000)
        #expect(Self.summary.trips.allSatisfy { GeoMath.distance(focus.center, $0.geometry.destination) <= focus.radiusMeters + 1 })
        #expect(Self.summary.pins.count <= MapSummary.maxVisiblePins)
    }

    /// Trips with nothing to draw are left out; one whose places are not named yet is not.
    @Test func tripsWithNothingToDrawAreLeftOut() throws {
        var world = Self.world
        // Its photos deleted since the analysis.
        world.trips.append(Trip(id: SortlyID("gone"), start: MapFixture.date("2024-09-01"), end: MapFixture.date("2024-09-03"),
                                geotaggedAssetIDs: ["gone-1"], inferredAssetIDs: [], centroid: MapFixture.Places.rome,
                                maxDistanceFromHomeMeters: 0, distinctStops: 1, kind: .vacation))
        // Only screenshots.
        let shots = SortlyID("shots"), unnamedTrip = SortlyID("unnamed")
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
        let tripID = SortlyID("svalbard")
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

    /// Photos of a trip taken at home (packing the evening before) never put anything on the
    /// map: the exact home would be a place, a pin and the start of the route (review finding 2).
    @Test func aTripsPhotosAtHomeAreNeverDrawn() throws {
        var packing = Self.world
        let packed = MapFixture.members(MapFixture.burst("packing", count: 4, at: World.home, day: "2024-04-01", hour: 18, jitterMeters: 10,
                                                         country: "DE", town: "Regensburg", atHome: true), of: World.portugal)
        packing.facts += packed
        let index = try #require(packing.trips.firstIndex { $0.id == World.portugal })
        packing.trips[index] = MapFixture.trip(World.portugal, packing.facts.filter { $0.tripID == World.portugal })
        let summary = MapSummary.build(packing.input())
        let trip = try #require(summary.trip(World.portugal))
        let nearHome = { (coordinate: GeoCoordinate) in GeoMath.distance(coordinate, World.home) < 30_000 }
        #expect(!trip.geometry.places.contains { nearHome($0.coordinate) })
        #expect(!trip.geometry.dayPlaces.contains { nearHome($0.coordinate) })
        #expect(!nearHome(trip.geometry.destination))
        #expect(!summary.pins.contains { nearHome($0.coordinate) })
        #expect(trip.geometry.countryPhotos["DE"] == nil)
        // They are still photos of the trip, as its album shows them.
        #expect(trip.geometry.photoCount == (Self.summary.trip(World.portugal)?.geometry.photoCount ?? 0) + 4)
        // A trip of nothing but photos at home has nothing to draw.
        var onlyHome = Self.world
        let home = MapFixture.members(MapFixture.burst("garden", count: 6, at: World.home, day: "2025-05-10", jitterMeters: 10, country: "DE",
                                                       town: "Regensburg", atHome: true), of: SortlyID("garden"))
        onlyHome.facts += home
        onlyHome.trips.append(MapFixture.trip(SortlyID("garden"), home))
        #expect(MapSummary.build(onlyHome.input()).trip(SortlyID("garden")) == nil)
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
                                                           town: "Paris"), of: SortlyID("ghost"))
        let summary = MapSummary.build(ghost.input())
        let france = try #require(summary.countries.first { $0.code == "FR" })
        #expect(france.tripIDs.isEmpty)
        #expect(summary.countries.allSatisfy { $0.tripIDs.allSatisfy { summary.trip($0) != nil } })
        let event = try #require(MapYears.newCountries(since: [], countries: summary.countries).first { $0.code == "FR" })
        #expect(event.tripID == nil)
        #expect(!summary.pins.contains { $0.id == "country:FR" })
    }

    /// Concept §8: the stored summary knows home only rounded, the diagnostic report no
    /// coordinate at all.
    @Test func storedSummaryAndDiagnosticsGiveNoHomeAway() throws {
        let data = try JSONEncoder().encode(Self.summary)
        let json = try #require(String(data: data, encoding: .utf8))
        for exact in ["49.0134", "12.1016", "49.013", "12.101"] { #expect(!json.contains(exact), "\(exact)") }
        #expect(try JSONDecoder().decode(MapSummary.self, from: data) == Self.summary)

        let lines = MapDiagnostics.lines(for: Self.summary, buildMilliseconds: 42).joined(separator: "\n")
        let home = try #require(Self.summary.home).coordinate
        var coordinates = [home, World.home, World.passau, World.straubing]
        coordinates += Self.summary.trips.flatMap { $0.geometry.places.map(\.coordinate) }
        for c in coordinates {
            for text in [String(format: "%.1f", c.latitude), String(format: "%.1f", c.longitude)] where text.count > 3 {
                #expect(!lines.contains(text), "\(text)")
            }
        }
        for word in ["Regensburg", "Reykjavík", "Straubing", "IS", "PT", "DE"] { #expect(!lines.contains(word), "\(word)") }
    }

    /// Concept §8: the share images get no home, nothing from within 50 km of it, arcs only from
    /// the middle of the home country.
    @Test func shareImagesNeverShowHome() throws {
        let summary = Self.summary
        let geometry = CountryGeometry(squareKilometers: ["DE": 357_000, "IS": 103_000, "PT": 92_000],
                                       centers: ["DE": MapFixture.at(51.0, 10.4), "IS": MapFixture.at(64.9, -18.6), "PT": MapFixture.at(39.6, -8.0)])
        let world = MapShare.world(summary, geometry: geometry)
        #expect(world.arcs.allSatisfy { $0.from == MapFixture.at(51.0, 10.4) })
        #expect(!world.arcs.isEmpty)
        let passport = MapShare.passport(summary)
        #expect(passport.stamps.map(\.countryCode).sorted() == ["DE", "IS", "PT"])
        let year = try #require(MapShare.year(2024, of: summary))
        let postcards = summary.trips.compactMap { MapShare.postcard(for: $0.id, in: summary) }
        // Every trip but Straubing, under 50 km from home: its postcard would name a place near
        // home, and none of its photos may be shown.
        #expect(postcards.count == summary.trips.count - 1)
        #expect(MapShare.postcard(for: World.straubingTrip, in: summary) == nil)

        var points = world.arcs.flatMap { [$0.from, $0.to] } + world.destinations
        points += postcards.flatMap(\.route)
        for point in points { #expect(GeoMath.distance(point, World.home) >= MapShare.nearHomeMeters, "\(point)") }
        #expect(!points.isEmpty)
        let nearHome = Set(Self.world.facts.filter { $0.tripID == World.straubingTrip || $0.atHome }.map(\.id))
        let photos = year.photos + postcards.flatMap(\.photos)
        #expect(photos.allSatisfy { !nearHome.contains($0.asset) })
        // Nothing in the share data spells the rounded home either.
        let home = try #require(summary.home).coordinate
        let encoder = JSONEncoder()
        let parts = try [encoder.encode(world), encoder.encode(passport), encoder.encode(year)] + postcards.map { try encoder.encode($0) }
        let text = parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        #expect(!text.contains(String(format: "%.4f", home.latitude)) && !text.contains(String(format: "%.4f", home.longitude)))
    }

    // MARK: After the second re-check

    /// A record kept while the analysis runs leads to the place it was made at: the trip's places
    /// are numbered anew as photos arrive (Oslo, earlier, comes before the North Cape), so its
    /// old index would open Oslo.
    @Test func aHeldRecordStillPointsToItsPlace() throws {
        let trip = SortlyID("norway")
        let cape = MapFixture.at(71.1700, 25.7830), capeSouth = MapFixture.at(71.1690, 25.7830), oslo = MapFixture.at(59.9139, 10.7522)
        func input(_ photos: [AssetFacts]) -> MapInput {
            let members = MapFixture.members(photos, of: trip)
            return MapInput(facts: members, trips: [MapFixture.trip(trip, members)], calendar: MapFixture.calendar,
                            now: MapFixture.date("2024-09-01"), analysisRunning: true)
        }
        let first = MapFixture.burst("cape-a", count: 3, at: cape, day: "2024-07-05", jitterMeters: 0, country: "NO", town: "Nordkapp")
        let one = MapSummary.build(input(first))
        let more = MapFixture.burst("oslo", count: 6, at: oslo, day: "2024-07-01", country: "NO", town: "Oslo") + first
            + MapFixture.burst("cape-b", count: 6, at: capeSouth, day: "2024-07-05", hour: 12, jitterMeters: 0, country: "NO", town: "Nordkapp")
        let two = MapSummary.build(input(more), previous: one)
        let held = try #require(one.numbers.record(.northernmost))
        let record = try #require(two.numbers.record(.northernmost))
        let places = try #require(two.trip(trip)).geometry.places
        #expect(record.value == held.value)
        #expect(places[record.placeIndex].name == "Nordkapp")
        #expect(record.placeName == "Nordkapp")
        #expect(record.coordinate == places[record.placeIndex].coordinate)
    }

    /// While the analysis runs, the longest trip shown is one on the map with those days: a kept
    /// "14 Tage" would open the trip the analysis has since cut to 6.
    @Test func theLongestTripShownIsTrueOfItsTrip() throws {
        let norway = SortlyID("norway"), north = SortlyID("norway-north")
        let photos = (0..<14).flatMap { day in
            MapFixture.burst("d\(day)", count: 3, at: MapFixture.at(60.0 + Double(day) * 0.5, 10.0), day: String(format: "2024-07-%02d", day + 1),
                             country: "NO", town: "Ort \(day)")
        }
        func input(_ trips: [(SortlyID, [AssetFacts])]) -> MapInput {
            let members = trips.map { (id: $0.0, facts: MapFixture.members($0.1, of: $0.0)) }
            return MapInput(facts: members.flatMap(\.facts), trips: members.map { MapFixture.trip($0.id, $0.facts) },
                            calendar: MapFixture.calendar, now: MapFixture.date("2024-09-01"), analysisRunning: true)
        }
        let one = MapSummary.build(input([(norway, photos)]))
        #expect(one.numbers.longestTripID == norway && one.numbers.longestTripDays == 14)
        let split = MapSummary.build(input([(norway, Array(photos.prefix(18))), (north, Array(photos.dropFirst(18)))]), previous: one)
        #expect(split.numbers.trips == 2)
        let longest = try #require(split.numbers.longestTripID)
        #expect(longest == north)
        #expect(split.numbers.longestTripDays == split.trip(longest)?.geometry.days)
        #expect(split.numbers.longestTripDays == 8)
        if let day = split.numbers.mostPhotosInADay {
            #expect(split.trip(day.tripID)?.geometry.dayCounts.contains { $0.day == day.day && $0.photoCount == day.photoCount } == true)
        }
    }

    /// A visit to today's home before moving in (a viewing of the flat in 2023, a trip then)
    /// puts nothing on the map nearer to it than the house's rounding: no pin and no place on
    /// today's exact home. Its photos still count for the country.
    @Test func aVisitToTodaysHomeBeforeMovingInPutsNothingOnIt() throws {
        var world = World(homeUntil2024: World.hamburg)
        let viewing = SortlyID("viewing")
        let members = MapFixture.members(MapFixture.burst("flat", count: 6, at: World.home, day: "2023-10-14", jitterMeters: 30,
                                                          country: "DE", town: "Regensburg"), of: viewing)
        world.facts += members
        world.trips.append(MapFixture.trip(viewing, members))
        let summary = MapSummary.build(world.input())
        #expect(summary.trip(viewing) == nil)
        let points = summary.pins.map(\.coordinate) + summary.trips.flatMap { $0.geometry.places.map(\.coordinate) }
        #expect(!points.isEmpty)
        for point in points { #expect(GeoMath.distance(point, World.home) > MapHome.maximumRoundingMeters, "\(point)") }
        #expect(summary.countries.contains { $0.code == "DE" })
    }

    /// A trip a month after a move starts at the new home: the photos at home of the weeks before
    /// it were there, though the old home still has most of the months before it. Days after a
    /// move only the detection's date of it tells.
    @Test func aTripSoonAfterAMoveStartsAtTheNewHome() throws {
        var world = World(homeUntil2024: World.hamburg)
        let rome = SortlyID("rome"), early = SortlyID("rome-early")
        for (id, day) in [(rome, "2024-02-03"), (early, "2024-01-10")] {
            let members = MapFixture.members(MapFixture.burst(id.rawValue, count: 8, at: MapFixture.Places.rome, day: day, country: "IT",
                                                              town: "Rom"), of: id)
            world.facts += members
            world.trips.append(MapFixture.trip(id, members))
        }
        let summary = MapSummary.build(world.input())
        let home = try #require(summary.trip(rome)?.home)
        #expect(GeoMath.distance(home.coordinate, World.home) <= MapHome.maximumRoundingMeters)
        let beforeKnown = try #require(summary.trip(early)?.home)
        #expect(GeoMath.distance(beforeKnown.coordinate, World.hamburg) <= MapHome.maximumRoundingMeters)
        let moved = DetectedHome(center: World.home, since: MapFixture.date("2024-01-01"), photoDays: 400)
        let dated = MapSummary.build(world.input(detected: moved))
        for id in [rome, early] {
            let home = try #require(dated.trip(id)?.home)
            #expect(GeoMath.distance(home.coordinate, World.home) <= MapHome.maximumRoundingMeters, "\(id)")
        }
        // Iceland, in 2023, from the old home either way.
        let iceland = try #require(dated.trip(World.iceland)?.home)
        #expect(GeoMath.distance(iceland.coordinate, World.hamburg) <= MapHome.maximumRoundingMeters)
    }

    /// One photo listed twice in two states of the analysis gives one map in any order: the
    /// analysed copy wins over its twin not analysed yet, and a copy the analysis took for a
    /// document wins over an ordinary one, so it is never a cover.
    @Test func aPhotoListedTwiceInTwoAnalysisStatesGivesOneMapInAnyOrder() throws {
        let trip = SortlyID("lisbon")
        let others = MapFixture.members(MapFixture.burst("lis", count: 4, at: MapFixture.Places.lisbon, day: "2024-04-03", country: "PT",
                                                         town: "Lissabon"), of: trip)
        func copy(analysed: Bool, document: Bool = false) -> AssetFacts {
            var fact = MapFixture.photo("fav", at: MapFixture.date("2024-04-03 12:00"), MapFixture.Places.lisbon, country: "PT", town: "Lissabon",
                                        trip: trip, favorite: true, analysed: analysed)
            fact.looksLikeDocument = document
            return fact
        }
        func covers(_ copies: [AssetFacts]) -> [AssetID]? {
            let input = MapInput(facts: others + copies, trips: [MapFixture.trip(trip, others + [copies[0]])], calendar: MapFixture.calendar,
                                 now: MapFixture.date("2024-07-01"))
            return MapSummary.build(input).trip(trip)?.geometry.places.first?.coverCandidates
        }
        let analysed = copy(analysed: true), unread = copy(analysed: false), card = copy(analysed: true, document: true)
        #expect(covers([analysed, unread]) == covers([unread, analysed]))
        #expect(covers([unread, analysed])?.first == "fav")
        #expect(covers([card, analysed]) == covers([analysed, card]))
        #expect(covers([analysed, card])?.contains("fav") == false)
    }

    /// Without a clock of its own, a photo is dated on its place's zone for its country as for
    /// its trip: New Year's Eve in New York stays 2025 with the iPhone in Berlin.
    @Test func aCountrysYearFollowsItsPlaceLikeItsTripsYear() throws {
        let trip = SortlyID("nyc")
        let photos = MapFixture.members((0..<5).map {
            MapFixture.photo("nyc-\($0)", at: MapFixture.date("2026-01-01 02:00").addingTimeInterval(Double($0) * 300), MapFixture.at(40.7580, -73.9855),
                             country: "US", town: "New York", timeZone: "America/New_York")
        }, of: trip)
        var calendar = MapFixture.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let summary = MapSummary.build(MapInput(facts: photos, trips: [MapFixture.trip(trip, photos)], calendar: calendar,
                                                now: MapFixture.date("2026-03-01")))
        #expect(summary.trip(trip)?.geometry.firstDay.year == 2025)
        #expect(try #require(summary.countries.first { $0.code == "US" }).firstVisitYear == 2025)
    }
}
