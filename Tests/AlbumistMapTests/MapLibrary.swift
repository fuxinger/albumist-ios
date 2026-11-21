import Foundation
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// A synthetic library for the map's end-to-end and speed tests: ten years of everyday photos at
/// home (Hamburg until the end of 2018, then the Regensburg area), and trips of every kind: day
/// trips and weekends nearby, holidays abroad (most of them flown, with photos at the gate, out of
/// the plane window and at the arrival airport), long road trips. Deterministic for a seed.
///
/// Flights as people take photos on them (`Flight`): gate photos 30 to 45 minutes before
/// take-off, window photos every 5 to 15 minutes from about 10 minutes after take-off to about
/// 10 minutes before landing (some of them bursts of 3 to 5 photos seconds apart, on long-haul
/// flights sometimes hours without one), arrival photos after landing. Long-haul flights of 6,000
/// to 12,000 km (some with a window photo only every 2.5 hours): Frankfurt to Tokyo (by train to
/// Frankfurt), Munich to New York and California, Munich to Bangkok with a layover of several
/// photos in Dubai, New Zealand and Fiji via Singapore. And the shapes the airborne filter cannot
/// see by design (`unseenWindowPhotos`).
struct MapLibrary {
    var facts: [AssetFacts] = []
    var trips: [Trip] = []
    var homeSettings = HomeSettings()
    /// Photos taken in flight, as the library was built.
    var windowPhotos: Set<AssetID> = []
    /// The window photos `AirborneFilter` cannot see by design (its doc comment lists them;
    /// `markUnseen` picks them): both window photos of a flight with only two, and the first or
    /// last window photo of a flight with one every 2.5 hours, each where its leg to the airport
    /// is slow.
    var unseenWindowPhotos: Set<AssetID> = []
    /// Photos at airports (gate, layover, arrival) and on the train to the airport: the ground
    /// around flights, which must never count as in flight.
    var travelPhotos: Set<AssetID> = []
    /// What the flights are like.
    var flights = Flights()
    /// The draws that build the library, in order: the same seed gives the same library.
    var random: MapRandom
    /// How many photo ids `nextID` has given out.
    var counter = 0

    struct Flights {
        var count = 0
        /// 6,000 km and more.
        var longHaul = 0
        /// A window photo every 2.5 hours.
        var sparse = 0
        /// Only one burst of window photos.
        var burstOnly = 0
        /// Only two window photos.
        var two = 0
        /// Layovers (with several photos at the hub).
        var layovers = 0
        /// Journeys to the airport by train.
        var byTrain = 0

        /// Counts the flight of `leg` along `path`.
        mutating func add(_ leg: Leg, along path: Flight) {
            count += 1
            if path.meters >= 6_000_000 { longHaul += 1 }
            if leg.hub != nil { layovers += 1 }
            switch leg.shape {
            case .sparse: sparse += 1
            case .burst: burstOnly += 1
            case .two: two += 1
            case .regular, .none: break
            }
        }
    }

    static let hamburg = MapFixture.at(53.5511, 9.9937)
    static let movedOn = MapFixture.date("2019-01-01")
    static let hamburgAirport = MapFixture.at(53.6304, 9.9882)
    static let munichAirport = MapFixture.at(48.3538, 11.7861)
    static let frankfurtAirport = MapFixture.at(50.0379, 8.5622)

    struct Hub {
        var name: String
        var country: String
        var zone: String
        var airport: GeoCoordinate
    }

    static let dubai = Hub(name: "Dubai", country: "AE", zone: "Asia/Dubai", airport: MapFixture.at(25.2532, 55.3657))
    static let singapore = Hub(name: "Singapur", country: "SG", zone: "Asia/Singapore", airport: MapFixture.at(1.3644, 103.9915))

    struct Destination {
        var name: String
        var country: String
        var zone: String
        var center: GeoCoordinate
        /// Where flights land, if it is flown to.
        var airport: GeoCoordinate?
        /// A layover on the way there and back.
        var via: Hub?
        /// Flights there leave from Frankfurt, reached by train.
        var fromFrankfurt = false
    }

    static let nearby: [Destination] = [
        Destination(name: "Bayerischer Wald", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(48.95, 13.40)),
        Destination(name: "München", country: "DE", zone: "Europe/Berlin", center: MapFixture.Places.munich),
        Destination(name: "Nürnberg", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(49.4521, 11.0767)),
        Destination(name: "Salzburg", country: "AT", zone: "Europe/Vienna", center: MapFixture.at(47.8095, 13.0550)),
        Destination(name: "Prag", country: "CZ", zone: "Europe/Prague", center: MapFixture.at(50.0755, 14.4378)),
        Destination(name: "Passau", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(48.5667, 13.4319)),
        Destination(name: "Bodensee", country: "DE", zone: "Europe/Berlin", center: MapFixture.at(47.6600, 9.4500)),
        Destination(name: "Wien", country: "AT", zone: "Europe/Vienna", center: MapFixture.at(48.2082, 16.3738)),
    ]

    static let abroad: [Destination] = [
        Destination(name: "Island", country: "IS", zone: "Atlantic/Reykjavik", center: MapFixture.at(64.10, -20.50), airport: MapFixture.at(63.9850, -22.6056)),
        Destination(name: "Lissabon", country: "PT", zone: "Europe/Lisbon", center: MapFixture.Places.lisbon, airport: MapFixture.at(38.7742, -9.1342)),
        Destination(name: "Rom", country: "IT", zone: "Europe/Rome", center: MapFixture.Places.rome, airport: MapFixture.at(41.8003, 12.2389)),
        Destination(name: "Toskana", country: "IT", zone: "Europe/Rome", center: MapFixture.Places.florence, airport: MapFixture.at(43.8100, 11.2051)),
        Destination(name: "Kreta", country: "GR", zone: "Europe/Athens", center: MapFixture.at(35.24, 24.81), airport: MapFixture.at(35.3397, 25.1803)),
        Destination(name: "Mallorca", country: "ES", zone: "Europe/Madrid", center: MapFixture.at(39.6953, 3.0176), airport: MapFixture.at(39.5517, 2.7388)),
        Destination(name: "Dalmatien", country: "HR", zone: "Europe/Zagreb", center: MapFixture.at(43.5081, 16.4402), airport: MapFixture.at(43.5389, 16.2980)),
        Destination(name: "Provence", country: "FR", zone: "Europe/Paris", center: MapFixture.at(43.9493, 4.8055), airport: MapFixture.at(43.4393, 5.2214)),
        Destination(name: "Lofoten", country: "NO", zone: "Europe/Oslo", center: MapFixture.at(68.2, 13.9), airport: MapFixture.at(67.2692, 14.3653)),
        Destination(name: "Schottland", country: "GB", zone: "Europe/London", center: MapFixture.at(57.12, -4.71), airport: MapFixture.at(57.5425, -4.0475)),
        Destination(name: "New York", country: "US", zone: "America/New_York", center: MapFixture.at(40.7128, -74.0060),
                    airport: MapFixture.at(40.6413, -73.7781)),
        Destination(name: "Kalifornien", country: "US", zone: "America/Los_Angeles", center: MapFixture.at(36.7783, -119.4179),
                    airport: MapFixture.at(33.9416, -118.4085)),
        Destination(name: "Tokio", country: "JP", zone: "Asia/Tokyo", center: MapFixture.Places.tokyo, airport: MapFixture.at(35.7720, 140.3929),
                    fromFrankfurt: true),
        Destination(name: "Bangkok", country: "TH", zone: "Asia/Bangkok", center: MapFixture.at(13.7563, 100.5018), airport: MapFixture.at(13.6900, 100.7501),
                    via: dubai),
        Destination(name: "Kapstadt", country: "ZA", zone: "Africa/Johannesburg", center: MapFixture.at(-33.9249, 18.4241),
                    airport: MapFixture.at(-33.9715, 18.6021)),
        Destination(name: "Neuseeland", country: "NZ", zone: "Pacific/Auckland", center: MapFixture.Places.auckland, airport: MapFixture.at(-37.0082, 174.7850),
                    via: singapore),
        Destination(name: "Fidschi", country: "FJ", zone: "Pacific/Fiji", center: MapFixture.Places.suva, airport: MapFixture.at(-17.7554, 177.4433),
                    via: singapore),
        Destination(name: "Marrakesch", country: "MA", zone: "Africa/Casablanca", center: MapFixture.at(31.6295, -7.9811),
                    airport: MapFixture.at(31.6069, -8.0363)),
        Destination(name: "Kopenhagen", country: "DK", zone: "Europe/Copenhagen", center: MapFixture.at(55.6761, 12.5683),
                    airport: MapFixture.at(55.6180, 12.6508)),
        Destination(name: "Amsterdam", country: "NL", zone: "Europe/Amsterdam", center: MapFixture.at(52.3676, 4.9041),
                    airport: MapFixture.at(52.3105, 4.7683)),
    ]

    /// The library's days: photos from `start` until before `end`.
    static let start = MapFixture.date("2016-01-01"), end = MapFixture.date("2026-10-31")

    /// About `count` photos (the last day may round it a little; with very few photos per day
    /// the ten years may end first).
    init(count: Int = 50_000, seed: UInt64 = 7) {
        random = MapRandom(seed: seed)
        homeSettings = HomeSettings(former: [FormerHome(place: HomePlace(center: Self.hamburg, components: PlaceComponents(isoCountryCode: "DE")),
                                                        until: Self.movedOn)])

        // Trips first: their days are kept free of everyday photos.
        let tripDays = addTrips(photos: count * 2 / 5)

        // Everyday photos at home on the other days, as many as fill up `count`.
        addEverydayPhotos(count: count, besides: tripDays)
    }

    /// The id of the next photo: the photos are numbered in the order they are made.
    mutating func nextID() -> String { counter += 1; return String(format: "p%06d", counter) }
}

/// A plane's way from take-off to landing, for photos out of its window: on the great circle,
/// climbing for `rampSeconds` from `liftOffSpeed` to its cruise speed, cruising, and descending
/// the last `rampSeconds` back to `liftOffSpeed`. So it covers some 70 km in its first ten
/// minutes in the air, as an airliner does (250 knots below 10,000 feet).
struct Flight {
    static let rampSeconds: TimeInterval = 20 * 60
    static let liftOffSpeed = 300.0 / 3.6
    var from: GeoCoordinate
    var to: GeoCoordinate
    var takeoff: Date
    /// Metres per second over the ground at cruise.
    var cruise: Double
    /// The great-circle distance, and the time from take-off to landing.
    let meters: Double
    let seconds: TimeInterval

    init(from: GeoCoordinate, to: GeoCoordinate, takeoff: Date, cruiseKmh: Double = 850) {
        self.from = from
        self.to = to
        self.takeoff = takeoff
        cruise = cruiseKmh / 3.6
        meters = GeoMath.distance(from, to)
        let ramps = 2 * Self.rampSeconds * (Self.liftOffSpeed + cruise) / 2
        precondition(meters >= ramps, "too short for a climb and a descent")
        seconds = 2 * Self.rampSeconds + (meters - ramps) / cruise
    }

    var minutes: Double { seconds / 60 }
    var landing: Date { takeoff.addingTimeInterval(seconds) }

    /// Metres flown `t` seconds after take-off.
    func flown(after t: TimeInterval) -> Double {
        func ramp(_ x: Double) -> Double { Self.liftOffSpeed * x + (cruise - Self.liftOffSpeed) * x * x / (2 * Self.rampSeconds) }
        if t <= Self.rampSeconds { return ramp(max(0, t)) }
        if t >= seconds - Self.rampSeconds { return meters - ramp(max(0, seconds - t)) }
        return ramp(Self.rampSeconds) + cruise * (t - Self.rampSeconds)
    }

    func position(minutes: Double) -> GeoCoordinate { MapLibrary.along(from, to, flown(after: minutes * 60) / meters) }
    func date(minutes: Double) -> Date { takeoff.addingTimeInterval(minutes * 60) }
}
