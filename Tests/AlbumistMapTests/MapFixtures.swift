import Foundation
@testable import AlbumistCore
import AlbumistMap
import AlbumistTestSupport

/// Building blocks for the map's tests: photos with a place, bursts of photos at one place, trips
/// over them. Everything in UTC unless a test passes a time zone, and deterministic.
enum MapFixture {
    static let utc = TimeZone(identifier: "UTC")!
    static var calendar: Calendar { Fixture.calendar }

    /// `"2023-06-14 10:30"` or `"2023-06-14"`, in UTC.
    static func date(_ string: String) -> Date { Fixture.date(string) }

    static func at(_ latitude: Double, _ longitude: Double) -> GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    /// Real places, for readable tests. The sample home is in the Regensburg area (as the drafts).
    enum Places {
        static let regensburg = at(49.0134, 12.1016)
        static let munich = at(48.1371, 11.5754)
        static let reykjavik = at(64.1466, -21.9426)
        static let thingvellir = at(64.2559, -21.1299)
        static let geysir = at(64.3104, -20.3024)
        static let gullfoss = at(64.3271, -20.1199)
        static let seljalandsfoss = at(63.6156, -19.9886)
        static let skogafoss = at(63.5321, -19.5114)
        static let vik = at(63.4186, -19.0060)
        static let lisbon = at(38.7223, -9.1393)
        static let porto = at(41.1579, -8.6291)
        static let rome = at(41.8986, 12.4769)
        static let florence = at(43.7696, 11.2558)
        static let tokyo = at(35.6762, 139.6503)
        static let auckland = at(-36.8485, 174.7633)
        static let suva = at(-18.1248, 178.4501)
        static let apia = at(-13.8333, -171.7667)
        static let honolulu = at(21.3069, -157.8583)
        static let longyearbyen = at(78.2232, 15.6267)
        static let ushuaia = at(-54.8019, -68.3030)
        static let luxembourg = at(49.6116, 6.1319)
    }

    /// One photo with its facts. `country` and the names make its place (a GPS place, as the
    /// analysis stores it); `timeZone` is the place's IANA time zone.
    static func photo(_ id: String, at date: Date, _ coordinate: GeoCoordinate?, country: String? = nil, town: String? = nil,
                      pointOfInterest: String? = nil, timeZone: String? = nil, trip: AlbumistID? = nil, atHome: Bool = false,
                      favorite: Bool = false, analysed: Bool = true, kind: MediaKind = .image) -> AssetFacts {
        let asset = AssetSnapshot(id: AssetID(id), kind: kind, creationDate: date, location: coordinate, pixelWidth: 4032, pixelHeight: 3024,
                                  isFavorite: favorite)
        let place = country.map {
            PlaceComponents(isoCountryCode: $0, country: $0, locality: town, areaOfInterest: pointOfInterest, timeZoneIdentifier: timeZone)
        }
        return AssetFacts(asset: asset, place: place, placeSource: place == nil ? nil : .gpsReverseGeocoded, tripID: trip, atHome: atHome,
                          contentKnown: analysed)
    }

    /// `count` photos on `day` ("2023-06-14") at `coordinate`, from `hour` (UTC) one every `minutes`,
    /// each moved up to `jitterMeters` so they are not all on one spot.
    static func burst(_ prefix: String, count: Int, at coordinate: GeoCoordinate, day: String, hour: Int = 10, minutes: Int = 10,
                      jitterMeters: Double = 80, country: String? = nil, town: String? = nil, pointOfInterest: String? = nil,
                      timeZone: String? = nil, trip: AlbumistID? = nil, atHome: Bool = false) -> [AssetFacts] {
        let start = date(day).addingTimeInterval(TimeInterval(hour * 3_600))
        return (0..<count).map { i in
            photo("\(prefix)-\(i)", at: start.addingTimeInterval(TimeInterval(i * minutes * 60)),
                  Fixture.jitter(coordinate, seed: i &+ Int(StableHash.fnv1a64(prefix) & 0xFFFF), meters: jitterMeters),
                  country: country, town: town, pointOfInterest: pointOfInterest, timeZone: timeZone, trip: trip, atHome: atHome)
        }
    }

    /// A trip over `facts` as the trip detection stores it: start and end from their dates, the
    /// photos with a location as its GPS members, the others as inferred members.
    static func trip(_ id: AlbumistID, _ facts: [AssetFacts], kind: TripKind = .vacation) -> Trip {
        let dates = facts.compactMap(\.asset.creationDate)
        let located = facts.filter { $0.asset.usableLocation != nil }
        let centroid = GeoMath.centroid(located.compactMap(\.asset.usableLocation)) ?? GeoCoordinate(latitude: 0, longitude: 0)
        return Trip(id: id, start: dates.min() ?? .distantPast, end: dates.max() ?? .distantPast,
                    geotaggedAssetIDs: located.map(\.id), inferredAssetIDs: facts.filter { $0.asset.usableLocation == nil }.map(\.id),
                    centroid: centroid, maxDistanceFromHomeMeters: 0, distinctStops: 1, kind: kind)
    }

    /// `facts` as members of `trip` (their `tripID` set).
    static func members(_ facts: [AssetFacts], of trip: AlbumistID) -> [AssetFacts] {
        facts.map { var f = $0; f.tripID = trip; return f }
    }

    /// Everyday photos at home: `perDay` photos on every `everyNthDay` day from `from` to `to`.
    static func everyday(_ prefix: String, from: String, to: String, at home: GeoCoordinate, country: String, perDay: Int = 2,
                         everyNthDay: Int = 1) -> [AssetFacts] {
        var result: [AssetFacts] = []
        var day = date(from)
        let end = date(to)
        var index = 0
        while day <= end {
            if index % everyNthDay == 0 {
                for p in 0..<perDay {
                    result.append(photo("\(prefix)-\(index)-\(p)", at: day.addingTimeInterval(TimeInterval(12 * 3_600 + p * 1_800)),
                                        Fixture.jitter(home, seed: index * 7 + p, meters: 2_000), country: country, atHome: true))
                }
            }
            day = day.addingTimeInterval(86_400)
            index += 1
        }
        return result
    }
}

/// Small deterministic random numbers for synthetic libraries (as in the core's tests).
struct MapRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}
