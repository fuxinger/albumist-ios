import Foundation
import SortlyCore

// "Deine Welt" (map concept 2.0, approved by Fuchs on 20.11.2026): the data the globe, the trip
// view, the numbers and the share images are drawn from. Worked out once per analysis state
// (`MapSummary.build`), stored, and shown at once when the map opens: a few hundred map elements
// instead of 50,000 photos.
//
// Privacy by construction (concept §8):
// - Home is only ever kept rounded to `MapHome.gridMeters` (`RoundedHome`).
// - Everyday photos at home never become a pin, a place or a record: every pin, place, route
//   point and record comes from the photos of a trip.
// - The share data (`ShareWorld`, `SharePassport`, `ShareYear`, `SharePostcard`) has no field for
//   home at all; arcs there start in the middle of the home country, never at home.
// - The diagnostics (`MapDiagnostics`) hold counts only, no coordinates.
//
// Honest numbers (concept §5): distances are great-circle ("Luftlinie") between photo places, shown
// rounded with "ca."; a record needs at least 3 photos at one place; photos taken in flight count
// for nothing (`AirborneFilter`).

// MARK: - Days

/// A calendar day as the photo's place saw it: in the local time where it was taken (decision
/// Fuchs 19.11.2026, as Apple Photos), Gregorian.
public struct LocalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day of `date` in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The day of `date` where `place` is, or in `fallback` when the place has no known time zone.
    public init(_ date: Date, place: PlaceComponents?, fallback: TimeZone) {
        let zone = place?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? fallback
        self.init(date, timeZone: zone)
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    /// Days from `self` to `other` (`other` later: positive), counted as whole calendar days.
    public func days(to other: LocalDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let a = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let b = calendar.date(from: DateComponents(year: other.year, month: other.month, day: other.day)) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

// MARK: - Trip geometry (where the photos of one trip were, day by day)

/// How many photos of a trip were taken on one local day ("Meiste Fotos an einem Tag").
public struct TripDay: Hashable, Sendable, Codable {
    public var day: LocalDay
    /// All the trip's photos of that day, with and without a location.
    public var photoCount: Int
    /// The place of most of that day's photos, if one has `TripGeometry.minimumPhotosPerPlace`.
    public var placeIndex: Int?

    public init(day: LocalDay, photoCount: Int, placeIndex: Int?) {
        self.day = day
        self.photoCount = photoCount
        self.placeIndex = placeIndex
    }
}

/// Where photos of one local day of a trip were taken: at least `TripGeometry.minimumPhotosPerPlace`
/// photos of that day within `TripGeometry.placeRadiusMeters`.
public struct DayPlace: Hashable, Sendable, Codable {
    /// A real photo location (the medoid of the photos), never a computed point that could lie in
    /// the sea.
    public var coordinate: GeoCoordinate
    public var day: LocalDay
    public var firstPhoto: Date
    public var lastPhoto: Date
    public var photoCount: Int
    /// The distinct place of the trip it belongs to (`TripGeometry.places`).
    public var placeIndex: Int

    public init(coordinate: GeoCoordinate, day: LocalDay, firstPhoto: Date, lastPhoto: Date, photoCount: Int, placeIndex: Int) {
        self.coordinate = coordinate
        self.day = day
        self.firstPhoto = firstPhoto
        self.lastPhoto = lastPhoto
        self.photoCount = photoCount
        self.placeIndex = placeIndex
    }
}

/// A distinct place of a trip: its day places within `TripGeometry.placeRadiusMeters` of each
/// other merged across days ("17 Orte").
public struct TripPlace: Hashable, Sendable, Codable {
    /// A real photo location (the medoid of the place's photos).
    public var coordinate: GeoCoordinate
    /// What the place is called, from the place names the analysis already stored: the point of
    /// interest when one names at least half of its photos ("Skógafoss"), otherwise the most
    /// common town, then district, region, country. `nil` when no name is known.
    public var name: String?
    /// ISO country code of most of its photos, or "disputed-<id>" in a disputed area.
    public var countryKey: String?
    public var photoCount: Int
    /// The local days it has photos on, oldest first.
    public var days: [LocalDay]
    /// Photos for its pin and for the stack when the trip is played: ordinary photos the image
    /// analysis has looked at (`PreviewRank.photo`), favourites first, then the largest, at most
    /// `TripGeometry.coverCandidateLimit`. The app shows only those it has sharp on the iPhone
    /// and never loads one from iCloud.
    public var coverCandidates: [AssetID]
    /// Metres above sea level, when at least `TripGeometry.minimumPhotosPerPlace` of its photos
    /// carry an altitude, all below `AirborneFilter.maximumAltitude` and agreeing within
    /// `TripGeometry.altitudeSpreadMeters`: their mean. `nil` otherwise (no "Höchstes Foto" from it).
    public var altitude: Double?

    public init(coordinate: GeoCoordinate, name: String?, countryKey: String?, photoCount: Int, days: [LocalDay], coverCandidates: [AssetID],
                altitude: Double? = nil) {
        self.coordinate = coordinate
        self.name = name
        self.countryKey = countryKey
        self.photoCount = photoCount
        self.days = days
        self.coverCandidates = coverCandidates
        self.altitude = altitude
    }
}

/// One stop of the route: a visit to a place of the trip, in time order. A place visited twice
/// (back to the hotel) appears twice, never twice in a row.
public struct RoutePoint: Hashable, Sendable, Codable {
    public var placeIndex: Int
    /// First and last photo of this visit.
    public var arrival: Date
    public var departure: Date
    /// The local day of `arrival`.
    public var day: LocalDay

    public init(placeIndex: Int, arrival: Date, departure: Date, day: LocalDay) {
        self.placeIndex = placeIndex
        self.arrival = arrival
        self.departure = departure
        self.day = day
    }
}

/// The straight line from one route point to the next: we know where photos were taken, not
/// which roads were driven (concept §4.3, "Ehrliche Linien").
public struct RouteLeg: Hashable, Sendable, Codable {
    /// Great-circle length.
    public var meters: Double
    /// Longer than `TripGeometry.gapMeters` with no photo for over `TripGeometry.gapDuration`:
    /// drawn grey and dotted with the label "ohne Fotos", so it does not read as a part of the trip.
    public var withoutPhotos: Bool

    public init(meters: Double, withoutPhotos: Bool) {
        self.meters = meters
        self.withoutPhotos = withoutPhotos
    }
}

/// Where one trip went: its day places, its distinct places, the route between them and the
/// place its arc points to. Built from the trip's own photos only (`TripGeometry.build`).
public struct TripGeometry: Hashable, Sendable, Codable, Identifiable {
    /// A place needs this many photos of one day (concept §5: also the rule for records, so a
    /// single wrong or received photo makes no place, no record and no country).
    public static let minimumPhotosPerPlace = 3
    /// Photos of one day this close count as one place; places of different days this close are
    /// one place of the trip.
    public static let placeRadiusMeters = 3_000.0
    /// A leg is "ohne Fotos" when it is longer than this ...
    public static let gapMeters = 100_000.0
    /// ... and no photo was taken for longer than this along it.
    public static let gapDuration: TimeInterval = 3 * 3_600
    /// At most this many route points per trip (concept §9).
    public static let maxRoutePoints = 200
    /// At most this many photos per place for its pin and stack.
    public static let coverCandidateLimit = 6
    /// A place's photos must agree on their altitude within this to give it one (`TripPlace.altitude`).
    public static let altitudeSpreadMeters = 150.0

    public var id: SortlyID
    /// First and last photo of the trip.
    public var start: Date
    public var end: Date
    /// The time zone most of the trip's photos were taken in (from their places), if known.
    public var timeZoneIdentifier: String?
    /// First and last local day, in `timeZoneIdentifier` (else the device's time zone).
    public var firstDay: LocalDay
    public var lastDay: LocalDay
    /// All photos of the trip (with and without location), as its album shows them.
    public var photoCount: Int
    /// Every local day with photos, oldest first. A photo without a place counts in the time zone
    /// of the trip (`timeZoneIdentifier`).
    public var dayCounts: [TripDay]
    /// Oldest first.
    public var dayPlaces: [DayPlace]
    public var places: [TripPlace]
    /// At most `maxRoutePoints`, in time order.
    public var route: [RoutePoint]
    /// `route.count - 1` legs (none for fewer than two points).
    public var legs: [RouteLeg]
    /// The place with the most photos: where the trip's arc ends and its pin stands. `nil` when no
    /// place has `minimumPhotosPerPlace` photos of one day; `destination` is then the medoid of
    /// the trip's photos (a real photo location, but no place: no record comes from it).
    public var destinationIndex: Int?
    public var destination: GeoCoordinate
    /// Photos with a location per country key (ISO code or "disputed-<id>"), photos in flight left out.
    public var countryPhotos: [String: Int]
    /// The country key with the most photos (ties: the smaller key).
    public var mainCountryKey: String?
    /// Photos of the trip left out as taken in flight (`AirborneFilter`).
    public var airborneCount: Int

    public init(id: SortlyID, start: Date, end: Date, timeZoneIdentifier: String?, firstDay: LocalDay, lastDay: LocalDay, photoCount: Int,
                dayCounts: [TripDay] = [], dayPlaces: [DayPlace], places: [TripPlace], route: [RoutePoint], legs: [RouteLeg], destinationIndex: Int?,
                destination: GeoCoordinate, countryPhotos: [String: Int], mainCountryKey: String?, airborneCount: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.photoCount = photoCount
        self.dayCounts = dayCounts
        self.dayPlaces = dayPlaces
        self.places = places
        self.route = route
        self.legs = legs
        self.destinationIndex = destinationIndex
        self.destination = destination
        self.countryPhotos = countryPhotos
        self.mainCountryKey = mainCountryKey
        self.airborneCount = airborneCount
    }

    /// Calendar days from the first to the last local day, both included.
    public var days: Int { firstDay.days(to: lastDay) + 1 }

    /// "vor Ort": the legs between the places, in time order (not between all photo points, or
    /// GPS jitter would make the number grow).
    public var metersOnSite: Double { legs.reduce(0) { $0 + $1.meters } }

    /// The route's coordinates, in time order.
    public var routeCoordinates: [GeoCoordinate] { route.map { places[$0.placeIndex].coordinate } }

    /// The name of the destination place, if it has one.
    public var destinationName: String? { destinationIndex.flatMap { places[$0].name } }
}

// MARK: - Home (rounded, never exact)

/// Where the user lived at a time, rounded to `MapHome.gridMeters`. The only form in which the map
/// keeps home. Shown in the app only (the house at 300 to 3,000 km view width, arcs starting
/// there), never on a share image.
public struct RoundedHome: Hashable, Sendable, Codable {
    /// The centre of the `MapHome.gridMeters` grid cell home lies in.
    public var coordinate: GeoCoordinate
    /// The ISO code of the country home lies in, if known.
    public var countryCode: String?

    public init(coordinate: GeoCoordinate, countryCode: String?) {
        self.coordinate = coordinate
        self.countryCode = countryCode
    }
}

// MARK: - World

/// Countries' sizes and middles, for the share images: arcs start in the middle of the home
/// country, and not at all when the home country is smaller than `smallCountrySquareKilometers`
/// (its middle would be almost the user's home). Built from the offline world map (`init(map:)`).
public struct CountryGeometry: Hashable, Sendable, Codable {
    public static let smallCountrySquareKilometers = 30_000.0

    /// Land area per ISO code.
    public var squareKilometers: [String: Double]
    /// A point well inside each country (its main land, not the sea between its islands).
    public var centers: [String: GeoCoordinate]

    public init(squareKilometers: [String: Double] = [:], centers: [String: GeoCoordinate] = [:]) {
        self.squareKilometers = squareKilometers
        self.centers = centers
    }
}

/// The world regions of the far-away globe ("Südeuropa · 5 Länder"): the UN geoscheme's
/// subregions, each inside exactly one `Continent` of the app (transcontinental countries follow
/// `Continent`, so Turkey and Cyprus are in Southern Europe here).
public enum WorldRegion: String, CaseIterable, Hashable, Sendable, Codable {
    case northernEurope, westernEurope, southernEurope, easternEurope
    case northernAfrica, westernAfrica, middleAfrica, easternAfrica, southernAfrica
    case northernAmerica, centralAmerica, caribbean, southAmerica
    case centralAsia, easternAsia, southEasternAsia, southernAsia, westernAsia
    case australiaAndNewZealand, melanesia, micronesia, polynesia
    case antarctica
}

/// One continent's share: "Europa 12 von 46".
public struct ContinentTally: Hashable, Sendable, Codable {
    public var continent: Continent
    /// Visited states of the 195 on this continent.
    public var visited: Int
    /// States of the 195 on this continent.
    public var total: Int

    public init(continent: Continent, visited: Int, total: Int) {
        self.continent = continent
        self.visited = visited
        self.total = total
    }
}

/// A visited country (at least `MapSummary.minimumPhotosPerCountry` photos there, photos in
/// flight left out; disputed areas are no country, decision 18.11.2026).
public struct MapCountry: Hashable, Sendable, Codable, Identifiable {
    /// ISO 3166-1 alpha-2.
    public var code: String
    /// The first photo there.
    public var firstVisit: Date
    public var photoCount: Int
    /// Trips with photos there, oldest first.
    public var tripIDs: [SortlyID]
    /// One of the 195 states (193 UN members, Vatican, Palestine); `false` for a territory such
    /// as Puerto Rico or Greenland, which has its own flag and stamp but is not counted in
    /// "von 195".
    public var isState: Bool
    public var continent: Continent?
    public var region: WorldRegion?

    public var id: String { code }

    public init(code: String, firstVisit: Date, photoCount: Int, tripIDs: [SortlyID], isState: Bool, continent: Continent?, region: WorldRegion?) {
        self.code = code
        self.firstVisit = firstVisit
        self.photoCount = photoCount
        self.tripIDs = tripIDs
        self.isState = isState
        self.continent = continent
        self.region = region
    }
}

// MARK: - Numbers

/// How far the trips went, told against the Earth and the Moon (concept §5).
public enum EarthComparison: Hashable, Sendable, Codable {
    /// Less than a quarter of the way round the Earth: no comparison is shown.
    case none
    case quarter
    case half
    /// Once round the Earth or more, e.g. 2.2 ("2,2-mal um die Erde"), one decimal, rounded down.
    case aroundTheEarth(times: Double)
    /// The distance to the Moon or more, e.g. 1.0 ("bis zum Mond"), one decimal, rounded down.
    case toTheMoon(times: Double)
}

/// The numbers of one trip.
public struct TripStats: Hashable, Sendable, Codable {
    /// "vor Ort": between the trip's places.
    public var metersOnSite: Double
    /// "unterwegs": `metersOnSite` plus the way from the home of its time to the first place and
    /// from the last place back. Without a known home: `metersOnSite`.
    public var metersTraveled: Double
    /// "von zu Hause": the farthest place from the home of its time; `nil` without a known home.
    public var metersFromHome: Double?

    public init(metersOnSite: Double, metersTraveled: Double, metersFromHome: Double?) {
        self.metersOnSite = metersOnSite
        self.metersTraveled = metersTraveled
        self.metersFromHome = metersFromHome
    }
}

/// A record ("Weitester Ort", "Nördlichster Ort", ...): always a place of a trip with at least
/// `TripGeometry.minimumPhotosPerPlace` photos of one day, never from everyday photos at home,
/// never from photos in flight.
public struct MapRecord: Hashable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Hashable, Sendable, Codable {
        case farthest, northernmost, southernmost, easternmost, westernmost, highest
    }

    public var kind: Kind
    public var tripID: SortlyID
    /// Into the trip's `places`.
    public var placeIndex: Int
    public var placeName: String?
    public var coordinate: GeoCoordinate
    /// A day the place has photos on.
    public var day: LocalDay
    /// farthest: metres from the home of the trip's time; highest: metres above sea level;
    /// northernmost and southernmost: latitude; easternmost and westernmost: longitude.
    public var value: Double

    public init(kind: Kind, tripID: SortlyID, placeIndex: Int, placeName: String?, coordinate: GeoCoordinate, day: LocalDay, value: Double) {
        self.kind = kind
        self.tripID = tripID
        self.placeIndex = placeIndex
        self.placeName = placeName
        self.coordinate = coordinate
        self.day = day
        self.value = value
    }
}

/// "Meiste Fotos an einem Tag": the trip day (local time) with the most photos.
public struct DayRecord: Hashable, Sendable, Codable {
    public var tripID: SortlyID
    public var day: LocalDay
    public var photoCount: Int
    /// The place of most of that day's photos, if it has a name.
    public var placeName: String?

    public init(tripID: SortlyID, day: LocalDay, photoCount: Int, placeName: String?) {
        self.tripID = tripID
        self.day = day
        self.photoCount = photoCount
        self.placeName = placeName
    }
}

/// "Lieblingsland": the country with the most trips abroad (the home country of the trip's time
/// does not count, or it would almost always win); a tie goes to more photos there.
public struct FavoriteCountry: Hashable, Sendable, Codable {
    public var code: String
    public var tripCount: Int
    public var photoCount: Int

    public init(code: String, tripCount: Int, photoCount: Int) {
        self.code = code
        self.tripCount = tripCount
        self.photoCount = photoCount
    }
}

/// "Deine Welt in Zahlen" (concept §5): every number of the map, worked out in the core.
public struct WorldNumbers: Hashable, Sendable, Codable {
    /// Countries and territories (each `MapCountry`), as the atlas counts them today.
    public var countries: Int
    /// Of those, states of the 195 ("14 von 195 Ländern").
    public var states: Int
    /// `states / 195`.
    public var worldShare: Double
    /// The six inhabited continents, in `Continent` order without Antarctica.
    public var continents: [ContinentTally]
    /// Distinct towns (per country), as the atlas counts them today.
    public var cities: Int
    public var trips: Int
    /// The year of the first trip ("48 Reisen seit 2011").
    public var firstTripYear: Int?
    /// The year of the first visit of the first country ("gesammelt seit 2011").
    public var firstCountryYear: Int?
    /// All trips, "unterwegs" (`TripStats.metersTraveled`).
    public var metersTraveled: Double
    /// All trips, "vor Ort".
    public var metersOnSite: Double
    public var earth: EarthComparison
    /// At most one per kind; a kind without a qualifying place is missing.
    public var records: [MapRecord]
    /// The longest trip by days (a tie: the more recent one).
    public var longestTripID: SortlyID?
    public var longestTripDays: Int?
    public var mostPhotosInADay: DayRecord?
    public var favoriteCountry: FavoriteCountry?
    /// The calendar year of `MapSummary.computedAt` in the device's calendar.
    public var year: Int
    /// Countries first visited in `year`, first visit order.
    public var newThisYear: [String]
    /// The analysis is still running: the app writes "bisher" beside the numbers, and no number
    /// is shown smaller than before (`holdingHighs`).
    public var isPreliminary: Bool

    public init(countries: Int = 0, states: Int = 0, worldShare: Double = 0, continents: [ContinentTally] = [], cities: Int = 0, trips: Int = 0,
                firstTripYear: Int? = nil, firstCountryYear: Int? = nil, metersTraveled: Double = 0, metersOnSite: Double = 0,
                earth: EarthComparison = .none, records: [MapRecord] = [], longestTripID: SortlyID? = nil, longestTripDays: Int? = nil,
                mostPhotosInADay: DayRecord? = nil, favoriteCountry: FavoriteCountry? = nil, year: Int = 1970, newThisYear: [String] = [],
                isPreliminary: Bool = false) {
        self.countries = countries
        self.states = states
        self.worldShare = worldShare
        self.continents = continents
        self.cities = cities
        self.trips = trips
        self.firstTripYear = firstTripYear
        self.firstCountryYear = firstCountryYear
        self.metersTraveled = metersTraveled
        self.metersOnSite = metersOnSite
        self.earth = earth
        self.records = records
        self.longestTripID = longestTripID
        self.longestTripDays = longestTripDays
        self.mostPhotosInADay = mostPhotosInADay
        self.favoriteCountry = favoriteCountry
        self.year = year
        self.newThisYear = newThisYear
        self.isPreliminary = isPreliminary
    }

    public func record(_ kind: MapRecord.Kind) -> MapRecord? { records.first { $0.kind == kind } }
}

/// One year of the time travel and of the first look's waves ("2022 · 10 Länder · Neu: Portugal").
public struct MapYear: Hashable, Sendable, Codable {
    /// Calendar year of the trips' start, in the device's calendar.
    public var year: Int
    /// Trips that started in the year, oldest first.
    public var tripIDs: [SortlyID]
    /// Countries first visited in the year, first visit order.
    public var newCountries: [String]
    /// Countries visited up to the end of the year ("Bis hierher: 9 Länder").
    public var countriesSoFar: Int
    /// Trips up to the end of the year ("· 21 Reisen").
    public var tripsSoFar: Int
    /// Days of the year's trips, added up.
    public var daysAway: Int
    /// Photos of the year's trips.
    public var photoCount: Int
    /// "unterwegs" of the year's trips.
    public var metersTraveled: Double

    public init(year: Int, tripIDs: [SortlyID], newCountries: [String], countriesSoFar: Int, tripsSoFar: Int, daysAway: Int, photoCount: Int,
                metersTraveled: Double) {
        self.year = year
        self.tripIDs = tripIDs
        self.newCountries = newCountries
        self.countriesSoFar = countriesSoFar
        self.tripsSoFar = tripsSoFar
        self.daysAway = daysAway
        self.photoCount = photoCount
        self.metersTraveled = metersTraveled
    }
}

/// "Neues Land! Großbritannien ist dein 14. Land." (moment 7).
public struct NewCountryEvent: Hashable, Sendable, Codable {
    public var code: String
    /// Its place in the order of first visits, from 1.
    public var ordinal: Int
    public var firstVisit: Date
    /// The trip of the first visit, if it was on a trip.
    public var tripID: SortlyID?

    public init(code: String, ordinal: Int, firstVisit: Date, tripID: SortlyID?) {
        self.code = code
        self.ordinal = ordinal
        self.firstVisit = firstVisit
        self.tripID = tripID
    }
}

// MARK: - Pins and arcs

/// What one pin stands for. The farther away the view, the coarser (concept §4.2).
public enum MapPinLevel: Int, CaseIterable, Comparable, Hashable, Sendable, Codable {
    /// A world region, with the number of its visited countries as badge.
    case worldRegion
    /// A country, with the number of trips there.
    case country
    case trip
    /// A place of a trip.
    case place

    public static func < (a: MapPinLevel, b: MapPinLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A pin on the globe or the map. It always stands at a real photo location of a trip: a region's
/// and a country's pin at the destination of their trip with the most photos there, never at a
/// computed middle that could lie in the sea, and never at home.
public struct MapPin: Hashable, Sendable, Codable, Identifiable {
    /// Stable across analyses as long as what it stands for stays ("trip:<id>", "country:IT", ...).
    public var id: String
    public var level: MapPinLevel
    public var coordinate: GeoCoordinate
    /// The place or trip name; `nil` for regions and countries (the app names them).
    public var title: String?
    public var countryKey: String?
    public var region: WorldRegion?
    public var tripID: SortlyID?
    /// Into the trip's `places`, for a place pin.
    public var placeIndex: Int?
    /// Region: visited countries; country: trips there; trip and place: photos.
    public var count: Int
    /// The photo on the pin (`TripPlace.coverCandidates`), if any.
    public var cover: AssetID?
    /// The years it has trips in, oldest first (time travel).
    public var years: [Int]

    public init(id: String, level: MapPinLevel, coordinate: GeoCoordinate, title: String? = nil, countryKey: String? = nil, region: WorldRegion? = nil,
                tripID: SortlyID? = nil, placeIndex: Int? = nil, count: Int, cover: AssetID? = nil, years: [Int] = []) {
        self.id = id
        self.level = level
        self.coordinate = coordinate
        self.title = title
        self.countryKey = countryKey
        self.region = region
        self.tripID = tripID
        self.placeIndex = placeIndex
        self.count = count
        self.cover = cover
        self.years = years
    }
}

/// An arc from the home of the trips' time to their destination. Trips to the same destination
/// from the same home share one arc, a little stronger the more trips it carries.
public struct MapArc: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    /// The rounded home of the trips' time (`RoundedHome.coordinate`).
    public var from: GeoCoordinate
    /// The destination of the trip with the most photos among them.
    public var to: GeoCoordinate
    /// Oldest first.
    public var tripIDs: [SortlyID]
    /// The years of the trips, oldest first.
    public var years: [Int]

    public init(id: String, from: GeoCoordinate, to: GeoCoordinate, tripIDs: [SortlyID], years: [Int]) {
        self.id = id
        self.from = from
        self.to = to
        self.tripIDs = tripIDs
        self.years = years
    }

    public var weight: Int { tripIDs.count }
}

/// The part of the Earth on screen, for choosing the pin level and grouping pins.
public struct MapViewport: Hashable, Sendable {
    public var center: GeoCoordinate
    /// How wide the view is on the ground, in metres.
    public var widthMeters: Double
    /// The view's size on screen, in points.
    public var widthPoints: Double
    public var heightPoints: Double

    public init(center: GeoCoordinate, widthMeters: Double, widthPoints: Double, heightPoints: Double) {
        self.center = center
        self.widthMeters = widthMeters
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }
}

/// Pins close together on screen shown as one (`MapPins.visible`).
public struct MapPinGroup: Hashable, Sendable, Identifiable {
    /// The pin shown: the one with the highest `count` (ties: the smaller id).
    public var pin: MapPin
    /// Ids of all pins in the group, the shown one included.
    public var memberIDs: [String]

    public init(pin: MapPin, memberIDs: [String]) {
        self.pin = pin
        self.memberIDs = memberIDs
    }

    public var id: String { pin.id }
}

/// The part of the Earth holding all trips' destinations, for the first camera ("Kleiner
/// Anfang": with three trips the globe moves close to the visited countries).
public struct MapFocus: Hashable, Sendable, Codable {
    public var center: GeoCoordinate
    /// Great-circle radius around `center` that holds every destination.
    public var radiusMeters: Double

    public init(center: GeoCoordinate, radiusMeters: Double) {
        self.center = center
        self.radiusMeters = radiusMeters
    }
}

// MARK: - Summary

/// One trip as the map shows it.
public struct MapTrip: Hashable, Sendable, Codable, Identifiable {
    public var geometry: TripGeometry
    /// The trip's name as its suggestion shows it, else its destination's name, else its main
    /// country's code.
    public var title: String
    public var stats: TripStats
    /// The home of the trip's time, rounded (`MapHome.homes`): where its arc starts; its country
    /// tells "abroad" for the favourite country. `nil` when none is known or "Kein Zuhause".
    /// Never goes into share data.
    public var home: RoundedHome?

    public init(geometry: TripGeometry, title: String, stats: TripStats, home: RoundedHome?) {
        self.geometry = geometry
        self.title = title
        self.stats = stats
        self.home = home
    }

    public var id: SortlyID { geometry.id }
}

/// Everything the map shows, worked out once per analysis state and stored (concept §9).
public struct MapSummary: Hashable, Sendable, Codable {
    /// Stored with the value: a summary of another version is worked out again, never read.
    public static let formatVersion = 1
    /// A country needs this many photos (as the atlas counts today).
    public static let minimumPhotosPerCountry = 3
    /// At most this many arcs at once (concept §9); the strongest and newest are kept.
    public static let maxArcs = 150
    /// At most this many pins on screen at once (concept §9).
    public static let maxVisiblePins = 60

    public var formatVersion: Int
    public var computedAt: Date
    /// Today's home, rounded: the house in the app. `nil` when none is known or the user said
    /// they have none. Former homes appear only as the start of their arcs.
    public var home: RoundedHome?
    /// Oldest first.
    public var trips: [MapTrip]
    /// First visit order.
    public var countries: [MapCountry]
    public var arcs: [MapArc]
    /// All levels; the app picks the level by the view's width (`MapPins.level(forWidth:)`).
    public var pins: [MapPin]
    public var numbers: WorldNumbers
    /// Oldest first, every year from the first trip to `numbers.year` (years without a trip too).
    public var years: [MapYear]
    public var focus: MapFocus?

    public init(formatVersion: Int = MapSummary.formatVersion, computedAt: Date, home: RoundedHome?, trips: [MapTrip], countries: [MapCountry],
                arcs: [MapArc], pins: [MapPin], numbers: WorldNumbers, years: [MapYear], focus: MapFocus?) {
        self.formatVersion = formatVersion
        self.computedAt = computedAt
        self.home = home
        self.trips = trips
        self.countries = countries
        self.arcs = arcs
        self.pins = pins
        self.numbers = numbers
        self.years = years
        self.focus = focus
    }

    public func trip(_ id: SortlyID) -> MapTrip? { trips.first { $0.id == id } }
}

// MARK: - Share data (no field for home: privacy by construction)

/// An arc on a share image: from the middle of the home country, never from home.
public struct ShareArc: Hashable, Sendable, Codable {
    public var from: GeoCoordinate
    public var to: GeoCoordinate
    public var weight: Int

    public init(from: GeoCoordinate, to: GeoCoordinate, weight: Int) {
        self.from = from
        self.to = to
        self.weight = weight
    }
}

/// A photo for a share image, with the name of its place for the label on a firm background.
public struct SharePhoto: Hashable, Sendable, Codable {
    public var asset: AssetID
    public var placeName: String?

    public init(asset: AssetID, placeName: String?) {
        self.asset = asset
        self.placeName = placeName
    }
}

/// Motif A, "Weltkarte": the Earth at night, golden arcs, the big numbers.
public struct ShareWorld: Hashable, Sendable, Codable {
    /// Country codes, first visit order (the flags).
    public var countries: [String]
    public var states: Int
    public var tripCount: Int
    public var sinceYear: Int?
    /// "unterwegs", whole kilometres rounded to 100.
    public var kilometers: Int
    public var continents: Int
    public var worldShare: Double
    /// None when the home country is unknown or smaller than
    /// `CountryGeometry.smallCountrySquareKilometers`.
    public var arcs: [ShareArc]
    /// Trip destinations at least `MapShare.nearHomeMeters` from home.
    public var destinations: [GeoCoordinate]

    public init(countries: [String], states: Int, tripCount: Int, sinceYear: Int?, kilometers: Int, continents: Int, worldShare: Double,
                arcs: [ShareArc], destinations: [GeoCoordinate]) {
        self.countries = countries
        self.states = states
        self.tripCount = tripCount
        self.sinceYear = sinceYear
        self.kilometers = kilometers
        self.continents = continents
        self.worldShare = worldShare
        self.arcs = arcs
        self.destinations = destinations
    }
}

/// Motif B, "Reisepass": a stamp per country with the year of the first visit.
public struct SharePassport: Hashable, Sendable, Codable {
    public struct Stamp: Hashable, Sendable, Codable {
        public var countryCode: String
        public var year: Int
        /// Freshly added (moment "Neues Land"): drawn as the newest stamp.
        public var isNew: Bool

        public init(countryCode: String, year: Int, isNew: Bool) {
            self.countryCode = countryCode
            self.year = year
            self.isNew = isNew
        }
    }

    /// First visit order.
    public var stamps: [Stamp]
    public var sinceYear: Int?
    public var tripCount: Int

    public init(stamps: [Stamp], sinceYear: Int?, tripCount: Int) {
        self.stamps = stamps
        self.sinceYear = sinceYear
        self.tripCount = tripCount
    }
}

/// Motif C, "Mein Reisejahr".
public struct ShareYear: Hashable, Sendable, Codable {
    public var year: Int
    public var newCountries: [String]
    /// "unterwegs" in the year, whole kilometres rounded to 100.
    public var kilometers: Int
    public var earth: EarthComparison
    public var tripCount: Int
    public var daysAway: Int
    public var photoCount: Int
    /// Best first; the app takes the first three it has sharp on the iPhone.
    public var photos: [SharePhoto]

    public init(year: Int, newCountries: [String], kilometers: Int, earth: EarthComparison, tripCount: Int, daysAway: Int, photoCount: Int,
                photos: [SharePhoto]) {
        self.year = year
        self.newCountries = newCountries
        self.kilometers = kilometers
        self.earth = earth
        self.tripCount = tripCount
        self.daysAway = daysAway
        self.photoCount = photoCount
        self.photos = photos
    }
}

/// Motif D, "Reise-Postkarte".
public struct SharePostcard: Hashable, Sendable, Codable {
    public var title: String
    public var countryCode: String?
    /// Year and month of the first day ("Juni 2023").
    public var year: Int
    public var month: Int
    public var days: Int
    public var photoCount: Int
    public var placeCount: Int
    /// "vor Ort", whole kilometres rounded to 100 ("rund 1.000 km").
    public var kilometers: Int
    /// The route's points at least `MapShare.nearHomeMeters` from home; empty when fewer than two
    /// are left (a trip close to home gets no route).
    public var route: [GeoCoordinate]
    /// Best first; the stamp's photo is the first one the app has sharp on the iPhone.
    public var photos: [SharePhoto]

    public init(title: String, countryCode: String?, year: Int, month: Int, days: Int, photoCount: Int, placeCount: Int, kilometers: Int,
                route: [GeoCoordinate], photos: [SharePhoto]) {
        self.title = title
        self.countryCode = countryCode
        self.year = year
        self.month = month
        self.days = days
        self.photoCount = photoCount
        self.placeCount = placeCount
        self.kilometers = kilometers
        self.route = route
        self.photos = photos
    }
}
