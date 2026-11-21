import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// The visited countries and towns: as the atlas counts them, from GPS places only, without
/// photos in flight, without disputed areas.
@Suite("Map countries")
struct MapCountriesTests {
    typealias Places = MapFixture.Places

    /// One photo with a place as `source` gives it (a GPS place unless stated).
    static func fact(_ id: String, _ date: String?, _ code: String?, town: String? = nil, disputed: String? = nil,
                     source: PlaceSource = .gpsReverseGeocoded, trip: String? = nil, at coordinate: GeoCoordinate = Places.rome) -> AssetFacts {
        let place = PlaceComponents(isoCountryCode: code, country: code ?? disputed, locality: town, disputedArea: disputed)
        return AssetFacts(asset: AssetSnapshot(id: AssetID(id), kind: .image, creationDate: date.map(MapFixture.date), location: coordinate),
                          place: place, placeSource: source, tripID: trip.map(AlbumistID.init), contentKnown: true)
    }

    static func facts(_ prefix: String, _ count: Int, _ date: String, _ code: String?, town: String? = nil, disputed: String? = nil,
                      source: PlaceSource = .gpsReverseGeocoded, trip: String? = nil) -> [AssetFacts] {
        (0..<count).map { fact("\(prefix)-\($0)", date, code, town: town, disputed: disputed, source: source, trip: trip) }
    }

    /// A small library: everyday photos at home in Germany, a trip to Iceland, one to Portugal,
    /// two photos in Rome (too few for a country).
    static var library: (facts: [AssetFacts], starts: [AlbumistID: Date]) {
        let iceland = AlbumistID("iceland"), portugal = AlbumistID("portugal")
        let facts = MapFixture.everyday("home", from: "2023-01-01", to: "2023-01-10", at: Places.regensburg, country: "DE")
            + MapFixture.burst("rvk", count: 5, at: Places.reykjavik, day: "2023-06-14", country: "IS", town: "Reykjavík", trip: iceland)
            + MapFixture.burst("vik", count: 4, at: Places.vik, day: "2023-06-16", country: "IS", town: "Vík", trip: iceland)
            + MapFixture.burst("lis", count: 6, at: Places.lisbon, day: "2024-04-02", country: "PT", town: "Lissabon", trip: portugal)
            + MapFixture.burst("rom", count: 2, at: Places.rome, day: "2024-09-01", country: "IT", town: "Rom")
        return (facts, [iceland: MapFixture.date("2023-06-14 10:00"), portugal: MapFixture.date("2024-04-02 10:00")])
    }

    @Test func countsCountriesAsTheAtlasDoes() throws {
        let (facts, starts) = Self.library
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: starts)
        #expect(countries.map(\.code) == ["DE", "IS", "PT"])
        let germany = try #require(countries.first)
        #expect(germany.firstVisit == MapFixture.date("2023-01-01 12:00"))
        #expect(germany.photoCount == 20)
        #expect(germany.tripIDs.isEmpty)
        #expect(germany.isState && germany.continent == .europe && germany.region == .westernEurope)
        let iceland = countries[1]
        #expect(iceland.firstVisit == MapFixture.date("2023-06-14 10:00"))
        #expect(iceland.photoCount == 9)
        #expect(iceland.tripIDs == [AlbumistID("iceland")])
        #expect(iceland.region == .northernEurope)
        #expect(countries[2].photoCount == 6 && countries[2].region == .southernEurope && countries[2].tripIDs == [AlbumistID("portugal")])
        // The same countries and first visits as today's atlas, for photos that all have a GPS place.
        let atlas = TravelAtlas.compute(facts: facts, calendar: MapFixture.calendar)
        #expect(Set(countries.map(\.code)) == atlas.countryCodes)
        #expect(Dictionary(uniqueKeysWithValues: countries.map { ($0.code, $0.firstVisit) }) == atlas.firstVisits)
        #expect(countries.map(\.code) == atlas.countriesByFirstVisit)
        // Towns: Reykjavík, Vík, Lissabon and Rom (the everyday photos have no town).
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 4)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == atlas.cityCount)
    }

    /// The year of the first visit is that of the clock where the photo was taken
    /// (`AssetFacts.timeZone`, as the app's albums count it), worked out once; the numbers, the
    /// time travel and the passport all take it from there. The device's zone counts only for a
    /// photo whose clock is not known.
    @Test func theFirstVisitsYearIsThatOfThePhotosClock() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let utc = MapFixture.utc
        // 16:30 UTC on New Year's Eve: 01:30 on 1 January 2020 in Tokyo.
        let unknownClock = Self.facts("tokyo", 3, "2019-12-31 16:30", "JP", town: "Tokio")
        #expect(MapCountries.compute(facts: unknownClock, airborne: [], tripStarts: [:], timeZone: tokyo).first?.firstVisitYear == 2020)
        #expect(MapCountries.compute(facts: unknownClock, airborne: [], tripStarts: [:], timeZone: utc).first?.firstVisitYear == 2019)
        let tokyoClock = unknownClock.map { fact in
            var fact = fact
            fact.timeZone = tokyo
            return fact
        }
        let countries = MapCountries.compute(facts: tokyoClock, airborne: [], tripStarts: [:], timeZone: utc)
        #expect(countries.first?.firstVisitYear == 2020)
        let numbers = WorldNumbers.compute(trips: [], countries: countries, cities: 1, timeZone: utc, now: MapFixture.date("2020-06-01"),
                                           analysisRunning: false)
        #expect(numbers.firstCountryYear == 2020)
        #expect(numbers.newThisYear == ["JP"])
    }

    @Test func onlyPlacesFromGPSCount() {
        let facts = Self.facts("guess", 5, "2023-05-01 10:00", "FR", town: "Paris", source: .contentInferred)
            + Self.facts("unresolved", 5, "2023-05-01 10:00", "BE", town: "Brügge", source: .gpsUnresolved)
            + Self.facts("chosen", 3, "2023-05-02 10:00", "ES", town: "Sevilla", source: .userAssigned)
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["ES"])
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 1)
    }

    @Test func photosInFlightCountForNothing() throws {
        // Three photos over Greece, one of them from the plane: two are too few.
        var facts = Self.facts("gr", 3, "2023-07-01 10:00", "GR", town: "Athen")
        // Iceland: the photo from the plane on approach is the earliest and the only one of Keflavík.
        let approach = Self.fact("approach", "2023-06-14 08:00", "IS", town: "Keflavík")
        facts += Self.facts("is", 3, "2023-06-14 10:00", "IS", town: "Reykjavík") + [approach]
        let airborne: Set<AssetID> = [AssetID("gr-0"), AssetID("approach")]
        let countries = MapCountries.compute(facts: facts, airborne: airborne, tripStarts: [:])
        #expect(countries.map(\.code) == ["IS"])
        let iceland = try #require(countries.first)
        #expect(iceland.firstVisit == MapFixture.date("2023-06-14 10:00"))
        #expect(iceland.photoCount == 3)
        #expect(MapCountries.cityCount(facts: facts, airborne: airborne) == 2)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 3)
    }

    @Test func aDisputedAreaIsNoCountryButItsTownsCount() {
        let facts = Self.facts("yalta", 6, "2021-08-01 10:00", nil, town: "Jalta", disputed: "crimea")
            + Self.facts("prizren", 4, "2021-09-01 10:00", nil, town: "Prizren", disputed: "kosovo")
            + Self.facts("kyiv", 3, "2021-07-01 10:00", "UA", town: "Kyjiw")
            + Self.facts("nowhere", 3, "2021-07-02 10:00", nil, town: "Atlantis")
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["UA"])
        // Jalta, Prizren and Kyjiw; a place with neither a code nor a disputed area has no country key.
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 3)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == TravelAtlas.compute(facts: facts).cityCount)
    }

    /// A country whose photos all lack a date is left out (no first visit); one dated photo is
    /// enough to date it.
    @Test func aCountryWithoutAnyDateIsLeftOut() throws {
        let facts = Self.facts("no", 4, "2023-01-01", "NO").map { f -> AssetFacts in var f = f; f.asset.creationDate = nil; return f }
            + Self.facts("se", 2, "2023-01-01", "SE").map { f -> AssetFacts in var f = f; f.asset.creationDate = nil; return f }
            + [Self.fact("se-dated", "2023-02-03 09:15", "SE")]
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["SE"])
        let sweden = try #require(countries.first)
        #expect(sweden.photoCount == 3)
        #expect(sweden.firstVisit == MapFixture.date("2023-02-03 09:15"))
        // The atlas counts Norway without a first visit; the map has no year for it.
        #expect(TravelAtlas.compute(facts: facts).countryCodes == ["NO", "SE"])
    }

    @Test func aPhotoListedTwiceCountsOnce() throws {
        let one = Self.fact("same", "2023-03-01 10:00", "FI", town: "Helsinki")
        let estonia = Self.facts("ee", 3, "2023-03-02 10:00", "EE", town: "Tallinn")
        let facts = [one, one, one] + estonia + [estonia[0]]
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["EE"])
        #expect(try #require(countries.first).photoCount == 3)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 2)
    }

    @Test func tripsAreOrderedByStartThenID() throws {
        let facts = Self.facts("b", 1, "2022-05-01 10:00", "IT", trip: "trip-b") + Self.facts("a", 1, "2022-05-01 11:00", "IT", trip: "trip-a")
            + Self.facts("c", 1, "2020-05-01 10:00", "IT", trip: "trip-c") + Self.facts("x", 1, "2019-05-01 10:00", "IT", trip: "trip-x")
            + Self.facts("none", 2, "2018-05-01 10:00", "IT")
        let starts = [AlbumistID("trip-a"): MapFixture.date("2022-05-01"), AlbumistID("trip-b"): MapFixture.date("2022-05-01"),
                      AlbumistID("trip-c"): MapFixture.date("2020-05-01")]
        let italy = try #require(MapCountries.compute(facts: facts, airborne: [], tripStarts: starts).first)
        // Same start: by id; a trip whose start is not known comes last.
        #expect(italy.tripIDs == ["trip-c", "trip-a", "trip-b", "trip-x"].map(AlbumistID.init))
        #expect(italy.photoCount == 6)
        #expect(italy.firstVisit == MapFixture.date("2018-05-01 10:00"))
    }

    @Test func orderIsFirstVisitThenCode() {
        let facts = Self.facts("ch", 3, "2023-08-01 10:00", "CH") + Self.facts("at", 3, "2023-08-01 10:00", "AT")
            + Self.facts("li", 3, "2023-07-31 10:00", "LI")
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["LI", "AT", "CH"])
    }

    @Test func territoriesAreCountriesButNoStates() throws {
        let facts = Self.facts("pr", 3, "2024-02-01 10:00", "PR", town: "San Juan") + Self.facts("gl", 3, "2024-03-01 10:00", "GL", town: "Nuuk")
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["PR", "GL"])
        #expect(countries.allSatisfy { !$0.isState && $0.continent == .northAmerica })
        #expect(countries.map(\.region) == [.caribbean, .northernAmerica])
    }

    @Test func theSameInputInAnyOrderGivesTheSameCountries() {
        let (facts, starts) = Self.library
        let more = facts + Self.facts("ch", 3, "2023-08-01 10:00", "CH", trip: "x") + Self.facts("at", 3, "2023-08-01 10:00", "AT", trip: "y")
            + Self.facts("at2", 1, "2023-08-01 10:00", "AT", trip: "x")
        let airborne: Set<AssetID> = [AssetID("rvk-0"), AssetID("lis-3")]
        let reference = MapCountries.compute(facts: more, airborne: airborne, tripStarts: starts)
        let cities = MapCountries.cityCount(facts: more, airborne: airborne)
        for seed in UInt64(1)...5 {
            let shuffled = HandBuilt.shuffled(more, seed: seed)
            #expect(MapCountries.compute(facts: shuffled, airborne: airborne, tripStarts: starts) == reference)
            #expect(MapCountries.cityCount(facts: shuffled, airborne: airborne) == cities)
        }
    }

    @Test func townsAreCountedPerCountryAsTheAtlasDoes() {
        let facts = Self.facts("ffm", 2, "2023-01-01 10:00", "DE", town: "Frankfurt") + Self.facts("ffm-us", 1, "2023-02-01 10:00", "US", town: "Frankfurt")
            + Self.facts("again", 3, "2023-03-01 10:00", "DE", town: "Frankfurt") + Self.facts("plain", 3, "2023-03-01 10:00", "DE")
            + Self.facts("empty", 1, "2023-03-01 10:00", "DE", town: "")
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 2)
    }

    @Test func minimumPhotosIsAParameter() {
        let facts = Self.facts("one", 1, "2023-01-01 10:00", "MT") + Self.facts("three", 3, "2023-02-01 10:00", "CY")
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:]).map(\.code) == ["CY"])
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:], minimumPhotos: 1).map(\.code) == ["MT", "CY"])
        #expect(MapCountries.compute(facts: facts, airborne: [], tripStarts: [:], minimumPhotos: 4).isEmpty)
    }

    /// `PlaceComponents.init` makes codes upper case; a place decoded from storage might not be.
    @Test func aLowerCaseCodeIsTheSameCountry() throws {
        var lower = Self.facts("lower", 2, "2023-01-01 10:00", "NL", town: "Utrecht")
        for i in lower.indices { lower[i].place?.isoCountryCode = "nl" }
        let facts = lower + [Self.fact("upper", "2023-01-02 10:00", "NL", town: "Utrecht")]
        let countries = MapCountries.compute(facts: facts, airborne: [], tripStarts: [:])
        #expect(countries.map(\.code) == ["NL"])
        #expect(try #require(countries.first).isState)
        #expect(MapCountries.cityCount(facts: facts, airborne: []) == 1)
    }

    @Test func emptyInputAndASinglePhoto() {
        #expect(MapCountries.compute(facts: [], airborne: [], tripStarts: [:]).isEmpty)
        #expect(MapCountries.cityCount(facts: [], airborne: []) == 0)
        let one = [Self.fact("one", "2023-01-01 10:00", "DK", town: "Kopenhagen")]
        #expect(MapCountries.compute(facts: one, airborne: [], tripStarts: [:]).isEmpty)
        #expect(MapCountries.cityCount(facts: one, airborne: []) == 1)
        #expect(MapCountries.cityCount(facts: one, airborne: [AssetID("one")]) == 0)
    }

    // MARK: Short visits on the ground count

    /// `photos` as one stored trip in a library with everyday photos at home in the Regensburg
    /// area (no town) every third day of 2023, through `MapSummary.build`.
    static func summary(of photos: [AssetFacts]) -> MapSummary {
        let trip = AlbumistID("trip")
        let members = MapFixture.members(photos, of: trip)
        let everyday = MapFixture.everyday("home", from: "2023-01-01", to: "2023-12-31", at: Places.regensburg, country: "DE", everyNthDay: 3)
        return MapSummary.build(MapInput(facts: everyday + members, trips: [MapFixture.trip(trip, members)],
                                         detectedHome: DetectedHome(center: Places.regensburg, since: nil, photoDays: 400),
                                         calendar: MapFixture.calendar, now: MapFixture.date("2024-12-01")))
    }

    /// One photo at `time` ("2024-05-10 13:00", UTC).
    static func shot(_ id: String, _ time: String, _ coordinate: GeoCoordinate, _ country: String, town: String? = nil) -> AssetFacts {
        MapFixture.photo(id, at: MapFixture.date(time), coordinate, country: country, town: town)
    }

    /// A road trip by car, 35 to 50 km/h from stop to stop: three photos in Saarbrücken, then one
    /// each in Luxembourg City, Mersch and Clervaux, three in Bastogne and three days in Brussels.
    /// Each photo in Luxembourg is alone at its place and none of its legs is faster than a car:
    /// Luxembourg counts as a country (three photos) and each of its photos counts its town. With
    /// only the photo in Luxembourg City, its town counts and Luxembourg is no country (three
    /// photos make one, as the atlas counts).
    @Test func singlePhotosOnARoadTripCountTheirTownsAndTheirCountry() {
        let luxembourg = [Self.shot("lux", "2024-05-10 13:00", Places.luxembourg, "LU", town: "Luxemburg"),
                          Self.shot("mersch", "2024-05-10 13:25", MapFixture.at(49.7489, 6.1061), "LU", town: "Mersch"),
                          Self.shot("clervaux", "2024-05-10 14:10", MapFixture.at(50.0547, 6.0313), "LU", town: "Clerf")]
        var photos = MapFixture.burst("saar", count: 3, at: MapFixture.at(49.2402, 6.9969), day: "2024-05-10", hour: 11, country: "DE",
                                      town: "Saarbrücken")
        photos += MapFixture.burst("bastogne", count: 3, at: MapFixture.at(50.0033, 5.7189), day: "2024-05-10", hour: 15, country: "BE",
                                   town: "Bastogne")
        for day in 11...13 {
            photos += MapFixture.burst("bru-\(day)", count: 8, at: MapFixture.at(50.8503, 4.3517), day: "2024-05-\(day)", country: "BE",
                                       town: "Brüssel")
        }
        let all = Self.summary(of: photos + luxembourg)
        #expect(all.countries.map(\.code) == ["DE", "LU", "BE"])
        #expect(all.numbers.cities == 6)
        let one = Self.summary(of: photos + [luxembourg[0]])
        #expect(one.countries.map(\.code) == ["DE", "BE"])
        #expect(one.numbers.cities == 4)
    }

    /// A day trip from Passau over the Inn to Schärding and back: three photos in Passau in the
    /// morning, photos in Schärding at lunch 25 minutes apart, one in Passau in the afternoon.
    /// Three photos in Schärding make Austria a country and Schärding a town; two make the town
    /// and no country, as the atlas counts.
    @Test func aDayTripAcrossTheBorderCounts() {
        let passau = MapFixture.at(48.5667, 13.4319), schaerding = MapFixture.at(48.4569, 13.4317)
        let morning = MapFixture.burst("passau", count: 3, at: passau, day: "2024-06-08", hour: 9, country: "DE", town: "Passau")
        let afternoon = [Self.shot("passau-later", "2024-06-08 16:00", passau, "DE", town: "Passau")]
        for (count, countries) in [(3, ["DE", "AT"]), (2, ["DE"])] {
            let lunch = MapFixture.burst("schaerding", count: count, at: schaerding, day: "2024-06-08", hour: 12, minutes: 25, country: "AT",
                                         town: "Schärding")
            let summary = Self.summary(of: morning + lunch + afternoon)
            #expect(summary.countries.map(\.code) == countries, "\(count) photos in Schärding")
            #expect(summary.numbers.cities == 2, "\(count) photos in Schärding")
        }
    }

    /// The high-speed train from Paris to Amsterdam at 300 km/h: a photo out of its window every
    /// twenty minutes, one of them over Belgium (Mons), and twenty minutes later a series of three
    /// two seconds apart near Antwerp; a day in Paris before, an afternoon in Amsterdam after. No
    /// leg is faster than ground transport: Belgium counts as a country (four photos), and every
    /// town of the train counts.
    @Test func photosFromAFastTrainCount() {
        let paris = MapFixture.at(48.8809, 2.3553), amsterdam = MapFixture.at(52.3791, 4.9003)
        let departure = MapFixture.date("2024-06-12 10:00"), way = GeoMath.distance(paris, amsterdam), speed = 300_000.0 / 3_600
        func onBoard(_ id: String, _ seconds: Double, _ country: String, _ town: String) -> AssetFacts {
            MapFixture.photo(id, at: departure.addingTimeInterval(seconds), AirborneFilterTests.along(paris, amsterdam, seconds * speed / way),
                             country: country, town: town)
        }
        var photos = MapFixture.burst("paris", count: 8, at: paris, day: "2024-06-11", country: "FR", town: "Paris")
        photos += [onBoard("train-0", 1_200, "FR", "Compiègne"), onBoard("train-1", 2_400, "FR", "Cambrai"), onBoard("train-2", 3_600, "BE", "Mons")]
        photos += (0..<3).map { onBoard("series-\($0)", 4_800 + Double($0) * 2, "BE", "Antwerpen") }
        photos += MapFixture.burst("ams", count: 8, at: amsterdam, day: "2024-06-12", hour: 14, country: "NL", town: "Amsterdam")
        let summary = Self.summary(of: photos)
        #expect(summary.countries.map(\.code) == ["DE", "FR", "BE", "NL"])
        #expect(summary.numbers.cities == 6)
    }

    /// A hike from Oberstdorf into the Kleinwalsertal, at 3 to 4 km/h: three photos in Oberstdorf
    /// in the morning, one at Riezlern before noon, two at Mittelberg at lunch, back by bus in the
    /// afternoon. Three photos in Austria make it a country; with the photo at Riezlern alone, its
    /// town counts and Austria is no country.
    @Test func aWalkOverTheBorderCounts() {
        let oberstdorf = MapFixture.at(47.4097, 10.2790), riezlern = MapFixture.at(47.3561, 10.1897), mittelberg = MapFixture.at(47.3236, 10.1531)
        let base = MapFixture.burst("oberstdorf", count: 3, at: oberstdorf, day: "2024-08-03", hour: 8, country: "DE", town: "Oberstdorf")
            + [Self.shot("oberstdorf-later", "2024-08-03 17:00", oberstdorf, "DE", town: "Oberstdorf")]
        let riezlernPhoto = Self.shot("riezlern", "2024-08-03 11:00", riezlern, "AT", town: "Riezlern")
        let lunch = [Self.shot("mittelberg-0", "2024-08-03 12:30", mittelberg, "AT", town: "Mittelberg"),
                     Self.shot("mittelberg-1", "2024-08-03 12:45", mittelberg, "AT", town: "Mittelberg")]
        let walk = Self.summary(of: base + [riezlernPhoto] + lunch)
        #expect(walk.countries.map(\.code) == ["DE", "AT"])
        #expect(walk.numbers.cities == 3)
        let short = Self.summary(of: base + [riezlernPhoto])
        #expect(short.countries.map(\.code) == ["DE"])
        #expect(short.numbers.cities == 2)
    }

    /// Layovers count as the airborne filter has them (`AirborneFilterTests`): three photos over
    /// half an hour at Dubai airport between Munich and Bangkok, or a series of three over five
    /// seconds at Vienna airport between Berlin and Athens, are on the ground, and the country and
    /// the town count. A single photo at Dubai counts as in flight and costs its town. (The
    /// airports of departure and arrival carry no town here: the towns are the layovers' and the
    /// destinations'.)
    @Test func aLayoverCountsAsTheFilterHasIt() {
        func destination(_ prefix: String, _ days: [String], at coordinate: GeoCoordinate, _ country: String, _ town: String) -> [AssetFacts] {
            days.flatMap { MapFixture.burst("\(prefix)-\($0)", count: 8, at: coordinate, day: $0, country: country, town: town) }
        }
        let bangkok = destination("bkk", ["2024-01-17", "2024-01-18"], at: MapFixture.at(13.7563, 100.5018), "TH", "Bangkok")
        for (shape, countries, cities) in [([1_200.0, 2_100, 3_000], ["DE", "AE", "TH"], 2), ([1_800.0], ["DE", "TH"], 1)] {
            let (journey, layover) = AirborneFilterTests.layover("dxb-\(shape.count)", dubai: shape, window: false)
            let flights = journey.photos.map { photo -> AssetFacts in
                let gate = photo.id.rawValue.contains("gate")
                var fact = MapFixture.photo(photo.id.rawValue, at: photo.creationDate!, photo.location,
                                            country: layover.contains(photo.id) ? "AE" : gate ? "DE" : "TH",
                                            town: layover.contains(photo.id) ? "Dubai" : nil)
                fact.asset = photo
                return fact
            }
            let summary = Self.summary(of: flights + bangkok)
            #expect(summary.countries.map(\.code) == countries, "\(shape.count) photos at Dubai")
            #expect(summary.numbers.cities == cities, "\(shape.count) photos at Dubai")
        }
        let berlin = MapFixture.at(52.3667, 13.5033), vienna = MapFixture.at(48.1103, 16.5697), athens = MapFixture.at(37.9364, 23.9445)
        let t = MapFixture.date("2024-05-10 10:00")
        var photos = [MapFixture.photo("ber", at: t, berlin, country: "DE"), MapFixture.photo("ath", at: t.addingTimeInterval(11_400), athens, country: "GR")]
        photos += [0, 2.5, 5].enumerated().map { k, s in
            MapFixture.photo("vie-\(k)", at: t.addingTimeInterval(4_320 + s), k == 0 ? vienna : Fixture.jitter(vienna, seed: k, meters: 40),
                             country: "AT", town: "Schwechat")
        }
        let summary = Self.summary(of: photos + destination("ath", ["2024-05-11", "2024-05-12"], at: MapFixture.at(37.9838, 23.7275), "GR", "Athen"))
        #expect(summary.countries.map(\.code) == ["DE", "AT", "GR"])
        #expect(summary.numbers.cities == 2)
    }
}
