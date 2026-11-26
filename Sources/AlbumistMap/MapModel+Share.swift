import Foundation
import AlbumistCore

// Part of the map's model (`MapModel.swift`): the data of the share images, which has no field
// for home at all.

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
    /// "unterwegs" against the Earth ("2,2-mal um die Erde"), never in kilometres: the kilometres
    /// of one trip are about twice its distance from home, which no share image tells (concept
    /// §8). The comparison's steps are a quarter of the Earth and then 4,000 km, far coarser than
    /// any home.
    public var earth: EarthComparison
    public var continents: Int
    public var worldShare: Double
    /// None when the home country is unknown or smaller than
    /// `CountryGeometry.smallCountrySquareKilometers`.
    public var arcs: [ShareArc]
    /// Trip destinations at least `MapShare.nearHomeMeters` from every home the summary knows.
    public var destinations: [GeoCoordinate]

    public init(countries: [String], states: Int, tripCount: Int, sinceYear: Int?, earth: EarthComparison, continents: Int, worldShare: Double,
                arcs: [ShareArc], destinations: [GeoCoordinate]) {
        self.countries = countries
        self.states = states
        self.tripCount = tripCount
        self.sinceYear = sinceYear
        self.earth = earth
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
    /// "unterwegs" in the year against the Earth, the motif's sentence ("Halb um die Erde."):
    /// never in kilometres, which for a year with one trip would tell its distance from home
    /// (concept §8).
    public var earth: EarthComparison
    public var tripCount: Int
    public var daysAway: Int
    public var photoCount: Int
    /// Best first; the app takes the first three it has sharp on the iPhone.
    public var photos: [SharePhoto]

    public init(year: Int, newCountries: [String], earth: EarthComparison, tripCount: Int, daysAway: Int, photoCount: Int,
                photos: [SharePhoto]) {
        self.year = year
        self.newCountries = newCountries
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
