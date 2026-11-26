import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Countries and towns around flights (`FlightJudgement`): window photos the filter misses make no
/// country, and short visits on the ground still count: single photos on a road trip, a day trip
/// across the border, a fast train, a walk over the border, a layover.
extension MapCountriesTests {
    // MARK: Photos maybe taken in flight count for nothing

    /// Finding 2.4 of the third review: the airborne filter's misses were said to cost "at most a
    /// town" each, but a country needs three photos in the whole library, not per flight. A round
    /// trip Munich → Lisbon in April 2022 with two window photos over France on the way out (the
    /// gate photo 2 h 45 min before, rule 3 needs three photos) and one on the way back (no photo
    /// within 20 hours before it, the next at home the day after) made France a country, first
    /// visit 2022; so did single window photos on three flights in two years. Each photo out has
    /// one flown leg, to the arrival photo in Lisbon, and no stay: maybe in flight, it counts for
    /// nothing (`FlightJudgement`). The photo back has no flown leg and counts: one photo makes no
    /// country.
    @Test func missedWindowPhotosOfSeveralFlightsMakeNoCountry() {
        typealias Airborne = AirborneFilterTests
        /// A round trip Munich → Lisbon → Munich in April of `year`: window photos over France `out`
        /// seconds after 09:15 on the way out (the gate photo 2 h 45 min before) and `back` seconds
        /// after 17:00 four days later (the last photo in Lisbon the day before).
        func roundTrip(_ year: Int, out: [Double], back: [Double]) -> (facts: [AssetFacts], trip: Trip) {
            let trip = AlbumistID("lisbon-\(year)"), overFrance = MapFixture.date("\(year)-04-02 09:15")
            let wayBack = MapFixture.date("\(year)-04-06 17:00")
            let speed = 830_000.0 / 3_600, way = GeoMath.distance(Airborne.munichAirport, Airborne.lisbonAirport)
            var photos = [MapFixture.photo("gate-\(year)", at: overFrance.addingTimeInterval(-9_900), Airborne.munichAirport, country: "DE",
                                           town: "Freising")]
            for (k, s) in out.enumerated() {
                photos.append(MapFixture.photo("out-\(year)-\(k)", at: overFrance.addingTimeInterval(s),
                                               Airborne.along(Airborne.munichAirport, Airborne.lisbonAirport, 0.4 + s * speed / way), country: "FR",
                                               town: "Clermont-Ferrand"))
            }
            photos.append(MapFixture.photo("landing-\(year)", at: overFrance.addingTimeInterval(0.6 * way / speed + 1_500), Airborne.lisbonAirport,
                                           country: "PT", town: "Lissabon"))
            for day in 3...5 {
                photos += MapFixture.burst("lis-\(year)-\(day)", count: 8, at: Places.lisbon, day: "\(year)-04-0\(day)", country: "PT", town: "Lissabon")
            }
            for (k, s) in back.enumerated() {
                photos.append(MapFixture.photo("back-\(year)-\(k)", at: wayBack.addingTimeInterval(s),
                                               Airborne.along(Airborne.lisbonAirport, Airborne.munichAirport, 0.55 + s * speed / way), country: "FR",
                                               town: "Limoges"))
            }
            let members = MapFixture.members(photos, of: trip)
            return (members, MapFixture.trip(trip, members))
        }
        let everyday = MapFixture.everyday("home", from: "2022-01-01", to: "2022-03-30", at: Places.regensburg, country: "DE", everyNthDay: 3)
            + MapFixture.everyday("home-2022", from: "2022-04-07", to: "2022-04-30", at: Places.regensburg, country: "DE")
            + MapFixture.everyday("home-2023", from: "2023-04-07", to: "2023-04-30", at: Places.regensburg, country: "DE")
        for (name, trips) in [("one round trip, two photos out and one back", [roundTrip(2022, out: [0, 2], back: [0])]),
                              ("two round trips, one photo each way and one more",
                               [roundTrip(2022, out: [0], back: [0]), roundTrip(2023, out: [0], back: [])])] {
            let facts = everyday + trips.flatMap(\.facts)
            // The filter misses them all: without the counting of `FlightJudgement`, France is a country.
            #expect(MapCountries.compute(facts: facts, airborne: AirborneFilter.airborne(facts.map(\.asset)), tripStarts: [:]).contains { $0.code == "FR" })
            let summary = MapSummary.build(MapInput(facts: facts, trips: trips.map(\.trip),
                                                    detectedHome: DetectedHome(center: Places.regensburg, since: nil, photoDays: 400),
                                                    calendar: MapFixture.calendar, now: MapFixture.date("2025-07-01")))
            let france = summary.countries.filter { $0.code == "FR" }.map { "\($0.photoCount) photos, first visit \($0.firstVisitYear)" }
            #expect(france.isEmpty, "\(name): France \(france)")
        }
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
