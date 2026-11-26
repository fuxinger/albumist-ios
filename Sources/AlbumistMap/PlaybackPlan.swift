import Foundation
import AlbumistCore

/// "Reise abspielen" (concept §4.4) worked out ahead for one trip: a segment per calendar day, and
/// for any moment of the playback where the bright dot is on the route, where the "drone" camera
/// looks from and which place the day is at. A pure function of the time, so pausing, jumping to
/// a day and continuing after the app was in the background all land on the same picture; the
/// player (`PlaybackPlayer`) only moves the time on.
///
/// The route is the trip's (`TripGeometry.route`): straight legs from one day place to the next,
/// great-circle lines on the ground (concept §4.3, "Ehrliche Linien"), right across the
/// antimeridian. Each leg belongs to the day it arrives on; a day plays its legs one after
/// another, each eased (it starts and ends at rest at a place where photos were taken), and then
/// holds at its last place, where its photos show. A day without a leg of its own holds where the
/// last one ended: briefly when it has no photos either (`emptyDaySeconds`).
///
/// Times (concept §9, heat): a day with legs takes `baseDaySeconds` plus `secondsPerLeg` per leg,
/// between `shortestDaySeconds` and `longestDaySeconds`; a day with photos but no leg the shortest
/// time; and when that adds up to more than `maximumSeconds`, every day is shortened alike, so
/// even a trip of 60 days plays in a minute.
///
/// The camera looks at the dot from behind and above: heading the direction of travel (turns
/// between legs blended over a window around the place, at most about `turnDegreesPerSecond`,
/// the short way round), pitch `farthestPitchDegrees` to `closestPitchDegrees`, distance from the
/// lengths of the legs around (`cameraMetersPerLegMeter`, clamped to `closestCameraMeters` to
/// `farthestCameraMeters`), all continuous in time across legs and days.
public struct PlaybackPlan: Hashable, Sendable {
    // MARK: Timing

    /// The whole playback at most (concept §9: "Abspielen höchstens 60 s").
    public static let maximumSeconds = 60.0
    /// A day with legs at most ...
    public static let longestDaySeconds = 8.0
    /// ... and at least, before a long trip shortens every day alike; also a day with photos but
    /// no leg of its own.
    public static let shortestDaySeconds = 3.0
    /// A day with legs: this much ...
    public static let baseDaySeconds = 2.0
    /// ... and this much per leg.
    public static let secondsPerLeg = 1.5
    /// A day without photos: a short hold at the last place.
    public static let emptyDaySeconds = 1.2
    /// The share of a day with legs held at its last place at the end, where its photos show.
    public static let holdShare = 0.25
    /// The most calendar days a plan has a segment for. A trip spans far fewer; the bound only
    /// keeps a broken date range from making millions of segments (later days are played as the
    /// last one).
    public static let maximumDays = 400

    // MARK: Camera

    public static let closestCameraMeters = 2_000.0
    public static let farthestCameraMeters = 60_000.0
    /// The camera's distance per metre of the leg it flies along (before clamping): the leg fits
    /// on the screen ahead of the dot.
    public static let cameraMetersPerLegMeter = 0.8
    /// The distance for a trip without any leg (one place, or none).
    public static let holdCameraMeters = 6_000.0
    /// Pitch at `closestCameraMeters` and at `farthestCameraMeters` (concept: "schräg von hinten
    /// oben wie eine Drohne"); in between by the logarithm of the distance.
    public static let closestPitchDegrees = 65.0
    public static let farthestPitchDegrees = 55.0
    /// How fast the camera turns between two legs, on average; a turn takes at least
    /// `shortestTurnSeconds` ...
    public static let turnDegreesPerSecond = 90.0
    public static let shortestTurnSeconds = 0.6
    /// ... and takes at most this share of each of the two legs it joins (so the turns of a leg's
    /// two ends never overlap). Short legs turn faster than `turnDegreesPerSecond`.
    public static let turnShareOfLeg = 0.45
    /// At the first and last share of a leg the dot counts as at its place (leaving, arriving):
    /// the photo stack shows there.
    public static let placeShareOfLeg = 0.12

    // MARK: The plan

    /// One per calendar day from the trip's first to its last local day, in order.
    public private(set) var days: [PlaybackDay]
    /// The route's points the dot passes, in order.
    public private(set) var stops: [PlaybackStop]
    /// From each stop to the next (`stops.count - 1`), in time order.
    public private(set) var legs: [PlaybackLeg]
    /// Seconds from the first day's start to the last day's end.
    public private(set) var duration: Double
    /// Where the camera holds when the trip has no stop at all: its destination, if it is a
    /// usable coordinate, else 0, 0.
    public private(set) var fallbackCenter: GeoCoordinate
    /// The heading changes between legs, in time order, none overlapping.
    private(set) var turns: [Turn]

    public init(trip: MapTrip) {
        self.init(geometry: trip.geometry)
    }

    public init(geometry: TripGeometry) {
        let first = geometry.firstDay
        let span = first.days(to: geometry.lastDay)
        let dayCount = min(max(span, 0), Self.maximumDays - 1) + 1

        // The stops: the route's points with a usable place, each on a day no earlier than the
        // stop before (local days can step back across the date line; the playback cannot).
        let route = Self.stops(of: geometry, dayCount: dayCount)
        var stops = route.stops
        // The legs, and their headings: a leg of no length looks on as the one before it (or,
        // at the start, as the first one with a direction).
        var legs = Self.legs(between: stops, routeIndices: route.routeIndices, geometry: geometry)
        // Each stop's camera distance: from the legs on either side (their geometric mean).
        Self.setCameraDistances(of: &stops, legs: legs)

        // The days: how long each takes, then shortened alike to the playback's limit.
        let perDay = DayContents(geometry: geometry, stops: stops, legs: legs, dayCount: dayCount)
        let wanted = (0..<dayCount).map { perDay.wantedSeconds(ofDay: $0) }
        let total = wanted.reduce(0, +)
        let scale = total > Self.maximumSeconds ? Self.maximumSeconds / total : 1

        var days: [PlaybackDay] = []
        var clock = 0.0
        var nextLeg = 0
        var lastStop: Int? = stops.isEmpty ? nil : 0
        for i in 0..<dayCount {
            let start = clock
            var dayEnd = start + wanted[i] * scale
            // A shortened trip ends at the limit exactly, not a rounding error past it.
            if i == dayCount - 1 && scale < 1 { dayEnd = max(start, Self.maximumSeconds) }
            let firstLeg = nextLeg
            let count = perDay.legs[i]
            let travel = count > 0 ? (dayEnd - start) * (1 - Self.holdShare) : 0
            for j in 0..<count {
                legs[firstLeg + j].start = start + travel * Double(j) / Double(count)
                legs[firstLeg + j].end = j == count - 1 ? start + travel : start + travel * Double(j + 1) / Double(count)
            }
            nextLeg += count
            if let todays = perDay.stops[i].last { lastStop = todays }
            let placeIndex = lastStop.map { stops[$0].placeIndex }
            days.append(PlaybackDay(index: i, day: LocalDay(dayNumber: first.dayNumber + i), start: start, end: dayEnd,
                                    photoCount: perDay.photos[i], placeIndices: perDay.stops[i].map { stops[$0].placeIndex },
                                    legs: firstLeg..<(firstLeg + count), stops: perDay.stops[i], lastStop: lastStop,
                                    holdStart: start + travel, placeIndex: placeIndex))
            clock = dayEnd
        }

        self.days = days
        self.stops = stops
        self.legs = legs
        self.duration = clock
        let destination = geometry.destination
        self.fallbackCenter = destination.latitude.isFinite && destination.longitude.isFinite
            ? PlaybackGeometry.normalized(destination) : GeoCoordinate(latitude: 0, longitude: 0)
        self.turns = Self.turns(between: legs)
    }

    // MARK: Building the plan

    /// The stops (`stops`, their camera distances not yet set), with the index of each one's
    /// route point: the route's points with a usable place, each on a day no earlier than the
    /// stop before, and no place twice in a row.
    private static func stops(of geometry: TripGeometry, dayCount: Int) -> (stops: [PlaybackStop], routeIndices: [Int]) {
        let first = geometry.firstDay
        var stops: [PlaybackStop] = []
        var routeIndices: [Int] = []
        for (r, point) in geometry.route.enumerated() {
            guard geometry.places.indices.contains(point.placeIndex) else { continue }
            let place = geometry.places[point.placeIndex].coordinate
            guard place.latitude.isFinite, place.longitude.isFinite else { continue }
            if let last = stops.last, last.placeIndex == point.placeIndex { continue }
            let earliest = stops.last?.dayIndex ?? 0
            let day = min(max(first.days(to: point.day), earliest), dayCount - 1)
            stops.append(PlaybackStop(coordinate: PlaybackGeometry.normalized(place), placeIndex: point.placeIndex, dayIndex: day, cameraMeters: 0))
            routeIndices.append(r)
        }
        return (stops, routeIndices)
    }

    /// The legs from each stop to the next, not yet timed, with their headings: a leg of no
    /// length looks on as the one before it (or, at the start, as the first one with a direction).
    private static func legs(between stops: [PlaybackStop], routeIndices: [Int], geometry: TripGeometry) -> [PlaybackLeg] {
        var legs: [PlaybackLeg] = []
        var bearings: [Double?] = []
        for k in stops.indices.dropFirst() {
            let a = stops[k - 1].coordinate, b = stops[k].coordinate
            let meters = GeoMath.distance(a, b)
            let consecutive = routeIndices[k] == routeIndices[k - 1] + 1 && geometry.legs.indices.contains(routeIndices[k - 1])
            legs.append(PlaybackLeg(from: k - 1, to: k, dayIndex: stops[k].dayIndex, start: 0, end: 0, meters: meters.isFinite ? meters : 0,
                                    bearing: 0, withoutPhotos: consecutive && geometry.legs[routeIndices[k - 1]].withoutPhotos))
            bearings.append(PlaybackGeometry.bearing(from: a, to: b))
        }
        var lastBearing = bearings.compactMap { $0 }.first ?? 0
        for l in legs.indices {
            if let bearing = bearings[l] { lastBearing = bearing }
            legs[l].bearing = lastBearing
        }
        return legs
    }

    /// Sets each stop's camera distance from the legs on either side (their geometric mean); a
    /// stop without a leg holds at `holdCameraMeters`.
    private static func setCameraDistances(of stops: inout [PlaybackStop], legs: [PlaybackLeg]) {
        let legCamera = legs.map { min(max($0.meters * Self.cameraMetersPerLegMeter, Self.closestCameraMeters), Self.farthestCameraMeters) }
        for k in stops.indices {
            let before = k > 0 ? legCamera[k - 1] : nil
            let after = k < legCamera.count ? legCamera[k] : nil
            switch (before, after) {
            case let (b?, a?): stops[k].cameraMeters = (b * a).squareRoot()
            case let (b?, nil): stops[k].cameraMeters = b
            case let (nil, a?): stops[k].cameraMeters = a
            case (nil, nil): stops[k].cameraMeters = Self.holdCameraMeters
            }
        }
    }

    /// Per calendar day of the plan: how many legs arrive on it, which stops it has (indices into
    /// the stops) and how many photos it holds.
    private struct DayContents {
        var legs: [Int]
        var stops: [[Int]]
        var photos: [Int]

        init(geometry: TripGeometry, stops: [PlaybackStop], legs: [PlaybackLeg], dayCount: Int) {
            self.legs = [Int](repeating: 0, count: dayCount)
            for leg in legs { self.legs[leg.dayIndex] += 1 }
            self.stops = [[Int]](repeating: [], count: dayCount)
            for (k, stop) in stops.enumerated() { self.stops[stop.dayIndex].append(k) }
            photos = [Int](repeating: 0, count: dayCount)
            let first = geometry.firstDay
            for entry in geometry.dayCounts {
                let index = first.days(to: entry.day)
                if index >= 0 && index < dayCount { photos[index] += max(0, entry.photoCount) }
            }
        }

        /// How long day `i` takes before a long trip shortens every day alike: a day with legs by
        /// their number, a day with photos or a stop but no leg the shortest time, any other a
        /// short hold.
        func wantedSeconds(ofDay i: Int) -> Double {
            if legs[i] > 0 {
                return min(max(PlaybackPlan.baseDaySeconds + PlaybackPlan.secondsPerLeg * Double(legs[i]), PlaybackPlan.shortestDaySeconds),
                           PlaybackPlan.longestDaySeconds)
            }
            return photos[i] > 0 || !stops[i].isEmpty ? PlaybackPlan.shortestDaySeconds : PlaybackPlan.emptyDaySeconds
        }
    }
}

/// Points and directions on the sphere for the playback: right across the antimeridian and
/// near the poles, as `GeoMath` measures (a sphere of `GeoMath.earthRadiusMeters`).
enum PlaybackGeometry {
    /// Latitude within ±90°, longitude in [−180, 180).
    static func normalized(_ c: GeoCoordinate) -> GeoCoordinate {
        GeoCoordinate(latitude: min(max(c.latitude, -90), 90), longitude: MapHome.normalizedLongitude(c.longitude))
    }

    /// Degrees in [0, 360).
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        return positive >= 360 ? 0 : positive
    }

    /// The signed change from heading `a` to heading `b` the short way round, in (−180, 180]:
    /// from 359° to 1° is +2°, never −358°.
    static func signedDifference(from a: Double, to b: Double) -> Double {
        let d = normalizedDegrees(b - a)
        return d > 180 ? d - 360 : d
    }

    /// A point in space: +z through the North Pole, +x through 0° N 0° E.
    struct Vector {
        var x: Double
        var y: Double
        var z: Double
    }

    /// The unit vector of a coordinate.
    static func vector(_ c: GeoCoordinate) -> Vector {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return Vector(x: cos(lat) * cos(lon), y: cos(lat) * sin(lon), z: sin(lat))
    }

    static func coordinate(_ v: Vector) -> GeoCoordinate {
        let horizontal = (v.x * v.x + v.y * v.y).squareRoot()
        let latitude = atan2(v.z, horizontal) * 180 / .pi
        let longitude = horizontal > 1e-15 ? atan2(v.y, v.x) * 180 / .pi : 0
        return GeoCoordinate(latitude: latitude, longitude: MapHome.normalizedLongitude(longitude))
    }

    /// The point `fraction` (0 to 1) of the way from `a` to `b` along the great circle. Two points
    /// at the same place give that place; opposite points (no single great circle) the nearer end.
    static func interpolate(_ a: GeoCoordinate, _ b: GeoCoordinate, _ fraction: Double) -> GeoCoordinate {
        let f = min(max(fraction, 0), 1)
        if f == 0 { return normalized(a) }
        if f == 1 { return normalized(b) }
        let p = vector(a), q = vector(b)
        let dot = p.x * q.x + p.y * q.y + p.z * q.z
        let cx = p.y * q.z - p.z * q.y, cy = p.z * q.x - p.x * q.z, cz = p.x * q.y - p.y * q.x
        let angle = atan2((cx * cx + cy * cy + cz * cz).squareRoot(), dot)
        guard angle > 1e-12 else { return normalized(a) }
        let s = sin(angle)
        guard s > 1e-9 else { return normalized(f < 0.5 ? a : b) }
        let wa = sin((1 - f) * angle) / s, wb = sin(f * angle) / s
        return coordinate(Vector(x: p.x * wa + q.x * wb, y: p.y * wa + q.y * wb, z: p.z * wa + q.z * wb))
    }

    /// The direction of travel from `a` to `b`, degrees clockwise from north in [0, 360), taken at
    /// the middle of the great circle between them (half way between the directions at either
    /// end). `nil` when they are at the same place (no direction).
    static func bearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double? {
        guard GeoMath.distance(a, b) > 0.5 else { return nil }
        let middle = interpolate(a, b, 0.5)
        let from = GeoMath.distance(middle, b) > 0.25 ? middle : a
        let lat1 = from.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        guard abs(x) > 1e-15 || abs(y) > 1e-15 else { return nil }
        return normalizedDegrees(atan2(y, x) * 180 / .pi)
    }
}
