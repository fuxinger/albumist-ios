import Foundation
import AlbumistCore

// Part of the map's model (`MapModel.swift`): the pins and arcs on the globe, the view they are
// grouped for, and the summary that holds everything the map shows.

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
    public var tripID: AlbumistID?
    /// Into the trip's `places`, for a place pin.
    public var placeIndex: Int?
    /// Region: visited countries; country: trips there; trip and place: photos.
    public var count: Int
    /// The photo on the pin (`TripPlace.coverCandidates`), if any.
    public var cover: AssetID?
    /// The years it has trips in, oldest first (time travel).
    public var years: [Int]

    public init(id: String, level: MapPinLevel, coordinate: GeoCoordinate, title: String? = nil, countryKey: String? = nil, region: WorldRegion? = nil,
                tripID: AlbumistID? = nil, placeIndex: Int? = nil, count: Int, cover: AssetID? = nil, years: [Int] = []) {
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
    public var tripIDs: [AlbumistID]
    /// The years of the trips, oldest first.
    public var years: [Int]

    public init(id: String, from: GeoCoordinate, to: GeoCoordinate, tripIDs: [AlbumistID], years: [Int]) {
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

    public var id: AlbumistID { geometry.id }
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

    public func trip(_ id: AlbumistID) -> MapTrip? { trips.first { $0.id == id } }
}
