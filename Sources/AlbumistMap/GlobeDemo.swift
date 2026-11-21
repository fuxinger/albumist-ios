import Foundation
import AlbumistCore

/// The prototype's load (concept §13, wave 0: "unser Globus mit 150 Bögen und 60 Stecknadeln"):
/// a made-up traveller who lived in Hamburg until 2015 and near Regensburg since, with trips to 75
/// places round the world from each home. No real person's data; the same scene every time, so
/// measurements on different iPhones and builds compare.
extension GlobeScene {
    /// `arcCount` arcs (at most 150: the 75 places from each of the two homes, the newer home
    /// first), trip pins at the first `pinCount` places (at most 75), with the country and world
    /// region pins above them, the visited countries for the tint and today's rounded home.
    public static func demo(arcCount: Int = 150, pinCount: Int = 60) -> GlobeScene {
        let places = DemoPlace.all
        let homes = [
            (home: MapHome.rounded(GeoCoordinate(latitude: 49.0134, longitude: 12.1016)), years: Array(2016...2026), key: "regensburg"),
            (home: MapHome.rounded(GeoCoordinate(latitude: 53.5511, longitude: 9.9937)), years: Array(2008...2015), key: "hamburg"),
        ]
        var arcs: [MapArc] = []
        for (h, home) in homes.enumerated() {
            for (i, place) in places.enumerated() where arcs.count < max(0, arcCount) {
                let year = home.years[(i * 7 + h * 3) % home.years.count]
                let trip = AlbumistID("demo-\(home.key)-\(i)")
                arcs.append(MapArc(id: "arc:\(trip.rawValue)", from: home.home, to: place.coordinate, tripIDs: [trip], years: [year]))
            }
        }

        var pins: [MapPin] = []
        var tripsByCountry: [String: [AlbumistID]] = [:]
        var firstYear: [String: Int] = [:]
        for (i, place) in places.prefix(max(0, pinCount)).enumerated() {
            let trip = AlbumistID("demo-regensburg-\(i)")
            let year = homes[0].years[(i * 7) % homes[0].years.count]
            pins.append(MapPin(id: "trip:\(trip.rawValue)", level: .trip, coordinate: place.coordinate, title: place.name,
                               countryKey: place.code, region: WorldRegion.of(countryCode: place.code), tripID: trip,
                               count: 20 + (i * 37) % 380, years: [year]))
            tripsByCountry[place.code, default: []].append(trip)
            firstYear[place.code] = min(firstYear[place.code] ?? year, year)
        }
        // A country's and a region's pin stand at the place of its first trip in the table, as
        // real ones stand at a real photo location (`MapPin`).
        var regionCountries: [WorldRegion: [String]] = [:]
        var regionAnchor: [WorldRegion: GeoCoordinate] = [:]
        for place in places.prefix(max(0, pinCount)) where pins.contains(where: { $0.id == "country:\(place.code)" }) == false {
            let trips = tripsByCountry[place.code] ?? []
            let region = WorldRegion.of(countryCode: place.code)
            pins.append(MapPin(id: "country:\(place.code)", level: .country, coordinate: place.coordinate, countryKey: place.code,
                               region: region, count: trips.count, years: firstYear[place.code].map { [$0] } ?? []))
            if let region {
                regionCountries[region, default: []].append(place.code)
                if regionAnchor[region] == nil { regionAnchor[region] = place.coordinate }
            }
        }
        for region in WorldRegion.allCases {
            guard let countries = regionCountries[region], let anchor = regionAnchor[region] else { continue }
            pins.append(MapPin(id: "region:\(region.rawValue)", level: .worldRegion, coordinate: anchor, region: region, count: countries.count))
        }

        let countries = demoCountries(tripsByCountry: tripsByCountry, firstYear: firstYear)
        return GlobeScene(arcs: arcs, pins: pins, countries: countries, trips: [],
                          home: RoundedHome(coordinate: homes[0].home, countryCode: "DE"), focus: nil)
    }

    /// The demo's visited countries for the tint, from the trips to each country and the year of
    /// its first one: 40 photos a trip, first visited that many years after 1 January 2016.
    private static func demoCountries(tripsByCountry: [String: [AlbumistID]], firstYear: [String: Int]) -> [MapCountry] {
        let start = Date(timeIntervalSince1970: 1_451_606_400)  // 1 January 2016, UTC
        return tripsByCountry.keys.sorted().map { code -> MapCountry in
            let year = firstYear[code] ?? 2016
            let firstVisit = start.addingTimeInterval(Double(year - 2016) * 365.25 * 86_400)
            return MapCountry(code: code, firstVisit: firstVisit, firstVisitYear: year, photoCount: 40 * (tripsByCountry[code]?.count ?? 1),
                              tripIDs: tripsByCountry[code] ?? [], isState: WorldStates.isState(code),
                              continent: Continent.forCountryCode(code), region: WorldRegion.of(countryCode: code))
        }
    }
}

/// The demo's places: big and well-known travel destinations on every continent.
struct DemoPlace {
    var name: String
    var code: String
    var coordinate: GeoCoordinate

    init(_ name: String, _ code: String, _ latitude: Double, _ longitude: Double) {
        self.name = name
        self.code = code
        self.coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    static let all: [DemoPlace] = [
        DemoPlace("Lissabon", "PT", 38.7223, -9.1393), DemoPlace("Porto", "PT", 41.1579, -8.6291),
        DemoPlace("Madrid", "ES", 40.4168, -3.7038), DemoPlace("Barcelona", "ES", 41.3874, 2.1686),
        DemoPlace("Sevilla", "ES", 37.3891, -5.9845), DemoPlace("Paris", "FR", 48.8566, 2.3522),
        DemoPlace("Nizza", "FR", 43.7102, 7.2620), DemoPlace("London", "GB", 51.5072, -0.1276),
        DemoPlace("Edinburgh", "GB", 55.9533, -3.1883), DemoPlace("Dublin", "IE", 53.3498, -6.2603),
        DemoPlace("Amsterdam", "NL", 52.3676, 4.9041), DemoPlace("Kopenhagen", "DK", 55.6761, 12.5683),
        DemoPlace("Stockholm", "SE", 59.3293, 18.0686), DemoPlace("Oslo", "NO", 59.9139, 10.7522),
        DemoPlace("Tromsø", "NO", 69.6492, 18.9553), DemoPlace("Helsinki", "FI", 60.1699, 24.9384),
        DemoPlace("Reykjavík", "IS", 64.1466, -21.9426), DemoPlace("Rom", "IT", 41.9028, 12.4964),
        DemoPlace("Florenz", "IT", 43.7696, 11.2558), DemoPlace("Venedig", "IT", 45.4408, 12.3155),
        DemoPlace("Neapel", "IT", 40.8518, 14.2681), DemoPlace("Athen", "GR", 37.9838, 23.7275),
        DemoPlace("Santorini", "GR", 36.3932, 25.4615), DemoPlace("Dubrovnik", "HR", 42.6507, 18.0944),
        DemoPlace("Wien", "AT", 48.2082, 16.3738), DemoPlace("Prag", "CZ", 50.0755, 14.4378),
        DemoPlace("Budapest", "HU", 47.4979, 19.0402), DemoPlace("Krakau", "PL", 50.0647, 19.9450),
        DemoPlace("Zürich", "CH", 47.3769, 8.5417), DemoPlace("Istanbul", "TR", 41.0082, 28.9784),
        DemoPlace("Marrakesch", "MA", 31.6295, -7.9811), DemoPlace("Kairo", "EG", 30.0444, 31.2357),
        DemoPlace("Kapstadt", "ZA", -33.9249, 18.4241), DemoPlace("Nairobi", "KE", -1.2921, 36.8219),
        DemoPlace("Sansibar", "TZ", -6.1659, 39.2026), DemoPlace("Dubai", "AE", 25.2048, 55.2708),
        DemoPlace("Tel Aviv", "IL", 32.0853, 34.7818), DemoPlace("Port Louis", "MU", -20.1609, 57.5012),
        DemoPlace("Tokio", "JP", 35.6762, 139.6503), DemoPlace("Kyoto", "JP", 35.0116, 135.7681),
        DemoPlace("Seoul", "KR", 37.5665, 126.9780), DemoPlace("Peking", "CN", 39.9042, 116.4074),
        DemoPlace("Shanghai", "CN", 31.2304, 121.4737), DemoPlace("Hongkong", "HK", 22.3193, 114.1694),
        DemoPlace("Bangkok", "TH", 13.7563, 100.5018), DemoPlace("Chiang Mai", "TH", 18.7883, 98.9853),
        DemoPlace("Phuket", "TH", 7.8804, 98.3923), DemoPlace("Singapur", "SG", 1.3521, 103.8198),
        DemoPlace("Denpasar", "ID", -8.6705, 115.2126), DemoPlace("Hanoi", "VN", 21.0278, 105.8342),
        DemoPlace("Ho-Chi-Minh-Stadt", "VN", 10.8231, 106.6297), DemoPlace("Kathmandu", "NP", 27.7172, 85.3240),
        DemoPlace("Delhi", "IN", 28.6139, 77.2090), DemoPlace("Colombo", "LK", 6.9271, 79.8612),
        DemoPlace("Malé", "MV", 4.1755, 73.5093), DemoPlace("New York", "US", 40.7128, -74.0060),
        DemoPlace("San Francisco", "US", 37.7749, -122.4194), DemoPlace("Los Angeles", "US", 34.0522, -118.2437),
        DemoPlace("Miami", "US", 25.7617, -80.1918), DemoPlace("Chicago", "US", 41.8781, -87.6298),
        DemoPlace("Vancouver", "CA", 49.2827, -123.1207), DemoPlace("Montréal", "CA", 45.5019, -73.5674),
        DemoPlace("Mexiko-Stadt", "MX", 19.4326, -99.1332), DemoPlace("Cancún", "MX", 21.1619, -86.8515),
        DemoPlace("Havanna", "CU", 23.1136, -82.3666), DemoPlace("Lima", "PE", -12.0464, -77.0428),
        DemoPlace("Cusco", "PE", -13.5320, -71.9675), DemoPlace("Rio de Janeiro", "BR", -22.9068, -43.1729),
        DemoPlace("Buenos Aires", "AR", -34.6037, -58.3816), DemoPlace("Santiago", "CL", -33.4489, -70.6693),
        DemoPlace("Sydney", "AU", -33.8688, 151.2093), DemoPlace("Melbourne", "AU", -37.8136, 144.9631),
        DemoPlace("Auckland", "NZ", -36.8485, 174.7633), DemoPlace("Queenstown", "NZ", -45.0312, 168.6626),
        DemoPlace("Honolulu", "US", 21.3069, -157.8583),
    ]
}
