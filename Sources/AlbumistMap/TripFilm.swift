import Foundation
import AlbumistCore

/// "Reise abspielen" for laypeople (Fuchs, 26.11.2026, approved with the clickable draft
/// "Karte für alle"): the trip as a few stations seen from high enough to show the region or the
/// country, never a single town.
///
/// Rules (only for playing a trip; the map itself keeps every place as its own pin, with
/// `TripGeometry.placeRadiusMeters`):
/// - Places visited one after another that lie closer than `stationRadiusMeters` to the station
///   so far (the middle of its places) are ONE station with all their photos.
/// - The film plays only for trips with at least `minimumFilmStations` different stations
///   (stations that lie at least `stationRadiusMeters` from every earlier one). Two stations: the
///   map flies there and shows the photos. One station: a photo story without a flight.
/// - The camera stays still over the whole trip; the view is at least `minimumViewMeters` wide.
public struct TripFilm: Hashable, Sendable {
    public static let stationRadiusMeters = 25_000.0
    public static let minimumFilmStations = 3
    /// The narrowest view the film and a trip on the map show: a region, not a town.
    public static let minimumViewMeters = 180_000.0
    /// The view is this much wider than the stations' spread, so the outer stations have room.
    public static let viewMargin = 1.3

    // Timing (seconds). The camera flies in, then for each station the line is drawn to it and
    // its photos show; a long trip is shortened alike to `maximumSeconds`.
    public static let flyInSeconds = 1.8
    public static let shortestLegSeconds = 1.2
    public static let longestLegSeconds = 2.4
    /// Seconds of drawing per metre of leg, before clamping.
    public static let legSecondsPerMeter = 1.2 / 100_000
    public static let holdSeconds = 2.9
    public static let maximumSeconds = 60.0

    /// What the trip's main button does.
    public enum Kind: Hashable, Sendable {
        /// At least three stations: "Reise abspielen".
        case film
        /// Two stations: the map flies there and shows the photos.
        case flyTo
        /// One station (or none): the photos as a story, no flight.
        case photoStory
    }

    public var stations: [TripFilmStation]
    public var kind: Kind
    /// Where the still camera looks and how wide its view is.
    public var center: GeoCoordinate
    public var viewWidthMeters: Double
    /// One per station, in order: when the line starts to that station (the first: when the
    /// camera has arrived), when the dot arrives, and when its photos are done.
    public var timeline: [StationTimes]
    public var duration: Double

    public struct StationTimes: Hashable, Sendable {
        public var legStart: Double
        public var arrival: Double
        public var end: Double
    }

    public init(geometry: TripGeometry) {
        let stations = Self.stations(of: geometry)
        self.stations = stations
        kind = Self.kind(of: stations)
        let coordinates = stations.map(\.coordinate)
        let center = GeoMath.centroid(coordinates) ?? geometry.destination
        self.center = center
        let spread = coordinates.reduce(0) { max($0, GeoMath.distance(center, $1)) }
        viewWidthMeters = max(Self.minimumViewMeters, 2 * spread * Self.viewMargin)
        (timeline, duration) = Self.timeline(of: stations)
    }

    // MARK: Stations

    /// The trip's places in the order they were visited (`TripGeometry.route`; places the route
    /// leaves out follow in their order), grouped into stations.
    static func stations(of geometry: TripGeometry) -> [TripFilmStation] {
        var order: [Int] = []
        for point in geometry.route where order.last != point.placeIndex && geometry.places.indices.contains(point.placeIndex) {
            order.append(point.placeIndex)
        }
        let routed = Set(order)
        order += geometry.places.indices.filter { !routed.contains($0) }

        var groups: [[Int]] = []
        for index in order {
            let place = geometry.places[index]
            guard place.coordinate.isPlausible else { continue }
            if let last = groups.last,
               let middle = GeoMath.centroid(last.map { geometry.places[$0].coordinate }),
               GeoMath.distance(middle, place.coordinate) < stationRadiusMeters {
                if !last.contains(index) { groups[groups.count - 1].append(index) }
            } else {
                groups.append([index])
            }
        }
        return groups.map { indices in
            let places = indices.map { geometry.places[$0] }
            // Named after its place with the most photos (the first among equals).
            let main = indices.enumerated().max { a, b in
                let (pa, pb) = (geometry.places[a.element].photoCount, geometry.places[b.element].photoCount)
                return pa != pb ? pa < pb : a.offset > b.offset
            }!.element
            return TripFilmStation(coordinate: GeoMath.centroid(places.map(\.coordinate)) ?? places[0].coordinate,
                                   placeIndices: indices, mainPlaceIndex: main, photoCount: places.reduce(0) { $0 + $1.photoCount })
        }
    }

    /// Stations that lie at least `stationRadiusMeters` from every earlier station: a trip there
    /// and back counts its turning point once.
    static func differentStations(_ stations: [TripFilmStation]) -> Int {
        var seen: [GeoCoordinate] = []
        for station in stations where !seen.contains(where: { GeoMath.distance($0, station.coordinate) < stationRadiusMeters }) {
            seen.append(station.coordinate)
        }
        return seen.count
    }

    static func kind(of stations: [TripFilmStation]) -> Kind {
        switch differentStations(stations) {
        case minimumFilmStations...: return .film
        case 2: return .flyTo
        default: return .photoStory
        }
    }

    // MARK: Time

    static func timeline(of stations: [TripFilmStation]) -> ([StationTimes], Double) {
        var wanted: [(leg: Double, hold: Double)] = []
        for (i, station) in stations.enumerated() {
            var leg = 0.0
            if i > 0 {
                let meters = GeoMath.distance(stations[i - 1].coordinate, station.coordinate)
                leg = min(longestLegSeconds, max(shortestLegSeconds, meters * legSecondsPerMeter))
            }
            wanted.append((leg, holdSeconds))
        }
        let total = flyInSeconds + wanted.reduce(0) { $0 + $1.leg + $1.hold }
        let scale = total > maximumSeconds ? (maximumSeconds - flyInSeconds) / (total - flyInSeconds) : 1
        var clock = flyInSeconds
        var times: [StationTimes] = []
        for part in wanted {
            let legStart = clock
            clock += part.leg * scale
            let arrival = clock
            clock += part.hold * scale
            times.append(StationTimes(legStart: legStart, arrival: arrival, end: clock))
        }
        return (times, stations.isEmpty ? 0 : clock)
    }

    /// What shows at `time` (clamped to the film).
    public func frame(at time: Double) -> TripFilmFrame {
        let t = min(max(time, 0), duration)
        guard !timeline.isEmpty else { return TripFilmFrame(phase: .finished, reachedStations: 0) }
        if t < Self.flyInSeconds { return TripFilmFrame(phase: .flyingIn(progress: t / Self.flyInSeconds), reachedStations: 0) }
        for (i, times) in timeline.enumerated() {
            if t < times.arrival {
                let length = times.arrival - times.legStart
                return TripFilmFrame(phase: .travelling(toStation: i, progress: length > 0 ? (t - times.legStart) / length : 1), reachedStations: i)
            }
            if t < times.end {
                let length = times.end - times.arrival
                return TripFilmFrame(phase: .atStation(i, progress: length > 0 ? (t - times.arrival) / length : 1), reachedStations: i + 1)
            }
        }
        return TripFilmFrame(phase: .finished, reachedStations: timeline.count)
    }
}

/// One stop of the film: places close together, with all their photos.
public struct TripFilmStation: Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// Into `TripGeometry.places`, in visiting order.
    public var placeIndices: [Int]
    /// The place it is named after.
    public var mainPlaceIndex: Int
    public var photoCount: Int
}

public struct TripFilmFrame: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case flyingIn(progress: Double)
        /// The line grows from the station before to this one.
        case travelling(toStation: Int, progress: Double)
        /// The dot is at the station; its photos show.
        case atStation(Int, progress: Double)
        /// The end card.
        case finished
    }

    public var phase: Phase
    /// Stations the dot has reached (their dots and lines are drawn in full).
    public var reachedStations: Int
}
