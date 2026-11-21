import Foundation
import AlbumistCore

/// The prototype's trip to play (concept §13, wave 0: "ein Stück Reise abspielen"): a made-up road
/// trip of 9 days round Iceland in June 2023, the Ring Road from Reykjavík east along the south
/// coast, north through the east, west along the north and back south to near Reykjavík, with a
/// burst of photos at each of its 17 places (real coordinates, 412 photos in all). No real
/// person's data: the photo ids are made up (the app shows quiet tiles instead of photos), the home
/// is the demo traveller's rounded one near Regensburg (`GlobeScene.demo`). Built from synthetic
/// photo facts through `Trip.make`, `TripGeometry.build` and `TripStats.compute` like a real trip,
/// and the same every time, so measurements on different iPhones and builds compare.
public enum DemoTrip {
    public static let id = AlbumistID("demo-iceland-2023")
    public static let title = "Island, Ringstraße"
    /// Iceland keeps UTC all year (no summer time).
    public static let timeZoneIdentifier = "Atlantic/Reykjavik"

    /// The trip as the map shows it, title "Island, Ringstraße".
    public static func iceland() -> MapTrip {
        let zone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        let facts = photos(timeZone: zone)
        let home = RoundedHome(coordinate: MapHome.rounded(GeoCoordinate(latitude: 49.0134, longitude: 12.1016)), countryCode: "DE")
        let coordinates = facts.compactMap(\.asset.location)
        let dates = facts.compactMap(\.asset.creationDate)
        let start = dates.min() ?? Date(timeIntervalSince1970: 0)
        let farthest = coordinates.reduce(0) { max($0, GeoMath.distance(home.coordinate, $1)) }
        let trip = Trip.make(id: id, start: start, end: dates.max() ?? start, geotaggedAssetIDs: facts.map(\.id),
                             centroid: GeoMath.centroid(coordinates) ?? stops[0].coordinate, maxDistanceFromHomeMeters: farthest,
                             distinctStops: 8, kind: .roadTrip)
        let geometry = TripGeometry.build(trip: trip, facts: facts, airborne: [], timeZone: zone)
        return MapTrip(geometry: geometry, title: title, stats: TripStats.compute(geometry, home: home), home: home)
    }

    /// One place of the trip: where, what its photos' places are called, on which day of the trip
    /// (1 to 9) the burst starts at which local time, and how many photos it has (one every two
    /// minutes).
    struct Stop {
        var key: String
        /// The point of interest, when the place is one ("Skógafoss").
        var pointOfInterest: String?
        var town: String
        var coordinate: GeoCoordinate
        var day: Int
        var hour: Int
        var minute: Int
        var photos: Int

        init(_ key: String, poi: String?, town: String, _ latitude: Double, _ longitude: Double, day: Int, at hour: Int, _ minute: Int, photos: Int) {
            self.key = key
            pointOfInterest = poi
            self.town = town
            coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
            self.day = day
            self.hour = hour
            self.minute = minute
            self.photos = photos
        }
    }

    /// The trip's places in the order they were visited.
    static let stops: [Stop] = [
        Stop("reykjavik", poi: nil, town: "Reykjavík", 64.1466, -21.9426, day: 1, at: 14, 0, photos: 36),
        Stop("thingvellir", poi: "Þingvellir", town: "Bláskógabyggð", 64.2559, -21.1299, day: 2, at: 9, 30, photos: 28),
        Stop("geysir", poi: "Geysir", town: "Haukadalur", 64.3104, -20.3024, day: 2, at: 12, 30, photos: 30),
        Stop("gullfoss", poi: "Gullfoss", town: "Bláskógabyggð", 64.3271, -20.1199, day: 2, at: 15, 0, photos: 26),
        Stop("seljalandsfoss", poi: "Seljalandsfoss", town: "Rangárþing eystra", 63.6156, -19.9886, day: 3, at: 10, 0, photos: 32),
        Stop("skogafoss", poi: "Skógafoss", town: "Skógar", 63.5321, -19.5114, day: 3, at: 13, 0, photos: 49),
        Stop("vik", poi: nil, town: "Vík", 63.4186, -19.0060, day: 3, at: 17, 0, photos: 18),
        Stop("skaftafell", poi: "Skaftafell", town: "Öræfi", 64.0161, -16.9721, day: 4, at: 11, 0, photos: 24),
        Stop("jokulsarlon", poi: "Jökulsárlón", town: "Öræfi", 64.0784, -16.2306, day: 4, at: 15, 30, photos: 42),
        Stop("hofn", poi: nil, town: "Höfn", 64.2539, -15.2082, day: 5, at: 10, 0, photos: 10),
        Stop("egilsstadir", poi: nil, town: "Egilsstaðir", 65.2653, -14.3948, day: 5, at: 17, 0, photos: 8),
        Stop("dettifoss", poi: "Dettifoss", town: "Norðurþing", 65.8147, -16.3846, day: 6, at: 11, 0, photos: 28),
        Stop("myvatn", poi: "Mývatn", town: "Reykjahlíð", 65.6039, -16.9961, day: 6, at: 15, 0, photos: 22),
        Stop("godafoss", poi: "Goðafoss", town: "Þingeyjarsveit", 65.6828, -17.5502, day: 7, at: 10, 30, photos: 20),
        Stop("akureyri", poi: nil, town: "Akureyri", 65.6885, -18.1262, day: 7, at: 14, 0, photos: 16),
        Stop("borgarnes", poi: nil, town: "Borgarnes", 64.5383, -21.9206, day: 8, at: 16, 0, photos: 9),
        Stop("hafnarfjordur", poi: nil, town: "Hafnarfjörður", 64.0671, -21.9377, day: 9, at: 11, 0, photos: 14),
    ]

    /// The first day of the trip: Saturday, 10 June 2023.
    static let firstDay = LocalDay(year: 2023, month: 6, day: 10)

    /// The trip's photos: per place a burst, one photo every two minutes from its start, each a
    /// little apart (at most 120 m north or south and 117 m east or west of the place, in a fixed
    /// pattern, so no two are on one spot and all stay one place), with a GPS place in Iceland,
    /// analysed, ordinary photos.
    static func photos(timeZone: TimeZone) -> [AssetFacts] {
        var facts: [AssetFacts] = []
        for stop in stops {
            let place = PlaceComponents(isoCountryCode: "IS", country: "Island", locality: stop.town, areaOfInterest: stop.pointOfInterest,
                                        timeZoneIdentifier: timeZoneIdentifier)
            // Iceland's clocks show UTC: the local time is the time since the day's UTC midnight.
            let midnight = Double(firstDay.dayNumber + stop.day - 1) * 86_400
            let first = midnight + Double(stop.hour * 3_600 + stop.minute * 60)
            let metersPerDegreeLongitude = GeoMath.metersPerDegreeLatitude * cos(stop.coordinate.latitude * .pi / 180)
            for i in 0..<stop.photos {
                let north = Double((i * 37) % 17 - 8) * 15
                let east = Double((i * 53) % 19 - 9) * 13
                let location = GeoCoordinate(latitude: stop.coordinate.latitude + north / GeoMath.metersPerDegreeLatitude,
                                             longitude: stop.coordinate.longitude + east / metersPerDegreeLongitude)
                let asset = AssetSnapshot(id: AssetID("demo-iceland-\(stop.key)-\(i)"), kind: .image,
                                          creationDate: Date(timeIntervalSince1970: first + Double(i * 120)), location: location,
                                          pixelWidth: 4_032, pixelHeight: 3_024)
                facts.append(AssetFacts(asset: asset, place: place, placeSource: .gpsReverseGeocoded, tripID: id, contentKnown: true,
                                        timeZone: timeZone))
            }
        }
        return facts
    }
}
