import Foundation
import AlbumistCore

// Part of the map's model (`MapModel.swift`): the countries and regions of the world, and the
// numbers of "Deine Welt in Zahlen" with their records and years.

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
    /// The Gregorian year of `firstVisit` on the clock where that photo was taken
    /// (`MapCountries.compute`): the year the time travel, the numbers and the passport stamp all
    /// give it, so they never disagree in the hours around New Year.
    public var firstVisitYear: Int
    public var photoCount: Int
    /// Trips with photos there, oldest first.
    public var tripIDs: [AlbumistID]
    /// One of the 195 states (193 UN members, Vatican, Palestine); `false` for a territory such
    /// as Puerto Rico or Greenland, which has its own flag and stamp but is not counted in
    /// "von 195".
    public var isState: Bool
    public var continent: Continent?
    public var region: WorldRegion?

    public var id: String { code }

    /// `firstVisitYear` nil: the year of `firstVisit` in UTC.
    public init(code: String, firstVisit: Date, firstVisitYear: Int? = nil, photoCount: Int, tripIDs: [AlbumistID], isState: Bool,
                continent: Continent?, region: WorldRegion?) {
        self.code = code
        self.firstVisit = firstVisit
        self.firstVisitYear = firstVisitYear ?? LocalDay(firstVisit, timeZone: TimeZone(identifier: "UTC")!).year
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
    public var tripID: AlbumistID
    /// Into the trip's `places`.
    public var placeIndex: Int
    public var placeName: String?
    public var coordinate: GeoCoordinate
    /// A day the place has photos on.
    public var day: LocalDay
    /// farthest: metres from the home of the trip's time; highest: metres above sea level;
    /// northernmost and southernmost: latitude; easternmost and westernmost: longitude.
    public var value: Double

    public init(kind: Kind, tripID: AlbumistID, placeIndex: Int, placeName: String?, coordinate: GeoCoordinate, day: LocalDay, value: Double) {
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
    public var tripID: AlbumistID
    public var day: LocalDay
    public var photoCount: Int
    /// The place of most of that day's photos, if it has a name.
    public var placeName: String?

    public init(tripID: AlbumistID, day: LocalDay, photoCount: Int, placeName: String?) {
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
    public var longestTripID: AlbumistID?
    public var longestTripDays: Int?
    public var mostPhotosInADay: DayRecord?
    public var favoriteCountry: FavoriteCountry?
    /// The Gregorian year of `MapSummary.computedAt` in the device's time zone ("this year").
    public var year: Int
    /// Countries first visited in `year`, first visit order.
    public var newThisYear: [String]
    /// The analysis is still running: the app writes "bisher" beside the numbers, and no number
    /// is shown smaller than before (`holdingHighs`).
    public var isPreliminary: Bool

    public init(countries: Int = 0, states: Int = 0, worldShare: Double = 0, continents: [ContinentTally] = [], cities: Int = 0, trips: Int = 0,
                firstTripYear: Int? = nil, firstCountryYear: Int? = nil, metersTraveled: Double = 0, metersOnSite: Double = 0,
                earth: EarthComparison = .none, records: [MapRecord] = [], longestTripID: AlbumistID? = nil, longestTripDays: Int? = nil,
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
    /// The Gregorian year of the trips' first local day (`TripGeometry.firstDay`).
    public var year: Int
    /// Trips that started in the year, oldest first.
    public var tripIDs: [AlbumistID]
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

    public init(year: Int, tripIDs: [AlbumistID], newCountries: [String], countriesSoFar: Int, tripsSoFar: Int, daysAway: Int, photoCount: Int,
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
    public var tripID: AlbumistID?

    public init(code: String, ordinal: Int, firstVisit: Date, tripID: AlbumistID?) {
        self.code = code
        self.ordinal = ordinal
        self.firstVisit = firstVisit
        self.tripID = tripID
    }
}
