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

        // The legs, and their headings: a leg of no length looks on as the one before it (or,
        // at the start, as the first one with a direction).
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

        // Each stop's camera distance: from the legs on either side (their geometric mean).
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

        // The days: how long each takes, then shortened alike to the playback's limit.
        var legsPerDay = [Int](repeating: 0, count: dayCount)
        for leg in legs { legsPerDay[leg.dayIndex] += 1 }
        var stopsPerDay = [[Int]](repeating: [], count: dayCount)
        for (k, stop) in stops.enumerated() { stopsPerDay[stop.dayIndex].append(k) }
        var photosPerDay = [Int](repeating: 0, count: dayCount)
        for entry in geometry.dayCounts {
            let index = first.days(to: entry.day)
            if index >= 0 && index < dayCount { photosPerDay[index] += max(0, entry.photoCount) }
        }
        let wanted: [Double] = (0..<dayCount).map { i in
            if legsPerDay[i] > 0 {
                return min(max(Self.baseDaySeconds + Self.secondsPerLeg * Double(legsPerDay[i]), Self.shortestDaySeconds), Self.longestDaySeconds)
            }
            return photosPerDay[i] > 0 || !stopsPerDay[i].isEmpty ? Self.shortestDaySeconds : Self.emptyDaySeconds
        }
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
            let count = legsPerDay[i]
            let travel = count > 0 ? (dayEnd - start) * (1 - Self.holdShare) : 0
            for j in 0..<count {
                legs[firstLeg + j].start = start + travel * Double(j) / Double(count)
                legs[firstLeg + j].end = j == count - 1 ? start + travel : start + travel * Double(j + 1) / Double(count)
            }
            nextLeg += count
            if let todays = stopsPerDay[i].last { lastStop = todays }
            let placeIndex = lastStop.map { stops[$0].placeIndex }
            days.append(PlaybackDay(index: i, day: LocalDay(dayNumber: first.dayNumber + i), start: start, end: dayEnd,
                                    photoCount: photosPerDay[i], placeIndices: stopsPerDay[i].map { stops[$0].placeIndex },
                                    legs: firstLeg..<(firstLeg + count), stops: stopsPerDay[i], lastStop: lastStop,
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

    // MARK: Looking up times and days

    /// The day playing at `time` (seconds from the start): the last day starting at or before it.
    /// A time before the start is the first day's, after the end (or not a number) the last
    /// one's or the first one's.
    public func dayIndex(at time: Double) -> Int {
        guard !time.isNaN else { return 0 }
        var low = 0, high = days.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if days[middle].start <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// When day `index` starts (clamped to the plan's days): where "jump to day n" lands.
    public func startTime(ofDay index: Int) -> Double {
        days[min(max(index, 0), days.count - 1)].start
    }

    /// The day at `fraction` (0 to 1) of the progress bar, which shows the days by their time:
    /// where a tap or a drag on it jumps to. Out of range: the first or last day.
    public func dayIndex(atFraction fraction: Double) -> Int {
        guard !fraction.isNaN else { return 0 }
        return dayIndex(at: min(max(fraction, 0), 1) * duration)
    }

    /// The fraction of the progress bar at `time` (0 to 1).
    public func fraction(at time: Double) -> Double {
        guard duration > 0, !time.isNaN else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    // MARK: The picture at a time

    /// Where everything is at `time` (clamped to the plan; not a number: the start).
    public func frame(at time: Double) -> PlaybackFrame {
        let t = time.isNaN ? 0 : min(max(time, 0), duration)
        let index = dayIndex(at: t)
        let day = days[index]
        let progress = day.duration > 0 ? min(max((t - day.start) / day.duration, 0), 1) : 1
        guard !stops.isEmpty else {
            let camera = PlaybackCamera(center: fallbackCenter, distanceMeters: Self.holdCameraMeters,
                                        pitchDegrees: Self.pitch(forDistance: Self.holdCameraMeters), headingDegrees: 0)
            return PlaybackFrame(time: t, dayIndex: index, dayProgress: progress, position: fallbackCenter, camera: camera, legIndex: nil,
                                 reachedStops: 0, placeIndex: nil, titlePlaceIndex: nil)
        }
        let heading = self.heading(at: t)
        if let l = legIndex(at: t) {
            let leg = legs[l]
            let from = stops[leg.from], to = stops[leg.to]
            let u = leg.end > leg.start ? min(max((t - leg.start) / (leg.end - leg.start), 0), 1) : 1
            let eased = Self.ease(u)
            let position = PlaybackGeometry.interpolate(from.coordinate, to.coordinate, eased)
            let distance = exp(log(from.cameraMeters) * (1 - eased) + log(to.cameraMeters) * eased)
            let camera = PlaybackCamera(center: position, distanceMeters: distance, pitchDegrees: Self.pitch(forDistance: distance),
                                        headingDegrees: heading)
            let leaving = u < Self.placeShareOfLeg, arriving = u > 1 - Self.placeShareOfLeg
            let at: Int? = leaving ? from.placeIndex : (arriving ? to.placeIndex : nil)
            return PlaybackFrame(time: t, dayIndex: index, dayProgress: progress, position: position, camera: camera, legIndex: l,
                                 reachedStops: leg.from + 1, placeIndex: at, titlePlaceIndex: leaving ? from.placeIndex : to.placeIndex)
        }
        let k = stopIndex(holdingAt: t)
        let stop = stops[k]
        let camera = PlaybackCamera(center: stop.coordinate, distanceMeters: stop.cameraMeters,
                                    pitchDegrees: Self.pitch(forDistance: stop.cameraMeters), headingDegrees: heading)
        return PlaybackFrame(time: t, dayIndex: index, dayProgress: progress, position: stop.coordinate, camera: camera, legIndex: nil,
                             reachedStops: k + 1, placeIndex: stop.placeIndex, titlePlaceIndex: stop.placeIndex)
    }

    /// The route as drawn at `frame` (concept §4.4): the part travelled (the stops reached, as a
    /// solid line) and the way on to the next stop (dashed). Changes only when a stop is reached,
    /// so the app replaces its lines a few times a day, not every frame.
    public func route(for frame: PlaybackFrame) -> PlaybackRoute {
        let reached = min(max(frame.reachedStops, 0), stops.count)
        let travelled = stops.prefix(reached).map(\.coordinate)
        let ahead = reached > 0 && reached < stops.count ? [stops[reached - 1].coordinate, stops[reached].coordinate] : []
        return PlaybackRoute(travelled: travelled, ahead: ahead)
    }

    /// The leg the dot is on at `t` (its start at or before `t`, its end after), if any.
    func legIndex(at t: Double) -> Int? {
        guard !legs.isEmpty else { return nil }
        var low = 0, high = legs.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if legs[middle].start <= t { low = middle } else { high = middle - 1 }
        }
        let leg = legs[low]
        return leg.start <= t && t < leg.end ? low : nil
    }

    /// The stop the dot rests at at `t` when it is on no leg: where the last leg ended by then,
    /// else the first stop (the days before the route's first point wait there).
    func stopIndex(holdingAt t: Double) -> Int {
        var low = -1, high = legs.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if legs[middle].end <= t { low = middle } else { high = middle - 1 }
        }
        return low >= 0 ? legs[low].to : 0
    }

    /// Ease in and out (smoothstep): at rest at both ends of a leg, fastest in its middle.
    static func ease(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// The camera's pitch for a distance: `closestPitchDegrees` close, `farthestPitchDegrees` far.
    static func pitch(forDistance meters: Double) -> Double {
        let span = log(farthestCameraMeters / closestCameraMeters)
        let share = meters > 0 && meters.isFinite ? min(max(log(meters / closestCameraMeters) / span, 0), 1) : 1
        return closestPitchDegrees + (farthestPitchDegrees - closestPitchDegrees) * share
    }

    // MARK: Heading

    /// A change of heading from one leg to the next over a window of time.
    struct Turn: Hashable, Sendable {
        var start: Double
        var end: Double
        /// The heading before, in [0, 360).
        var from: Double
        /// The signed change the short way round, in (−180, 180].
        var change: Double

        var to: Double { PlaybackGeometry.normalizedDegrees(from + change) }
    }

    /// The turns between consecutive legs: around the place between them (the middle of any hold
    /// there), as long as the change takes at `turnDegreesPerSecond` (at least
    /// `shortestTurnSeconds`), within the hold and at most `turnShareOfLeg` of either leg; what one
    /// side cannot give, the other gives if it can.
    static func turns(between legs: [PlaybackLeg]) -> [Turn] {
        var turns: [Turn] = []
        for (a, b) in zip(legs, legs.dropFirst()) {
            let change = PlaybackGeometry.signedDifference(from: a.bearing, to: b.bearing)
            guard abs(change) > 1e-9 else { continue }
            let middle = (a.end + b.start) / 2
            let wanted = max(abs(change) / turnDegreesPerSecond, shortestTurnSeconds)
            let roomBefore = (middle - a.end) + turnShareOfLeg * (a.end - a.start)
            let roomAfter = (b.start - middle) + turnShareOfLeg * (b.end - b.start)
            var before = min(wanted / 2, roomBefore), after = min(wanted / 2, roomAfter)
            if before < wanted / 2 { after = min(wanted - before, roomAfter) }
            if after < wanted / 2 { before = min(wanted - after, roomBefore) }
            turns.append(Turn(start: middle - before, end: middle + after, from: PlaybackGeometry.normalizedDegrees(a.bearing), change: change))
        }
        return turns
    }

    /// The camera's heading at `t` in [0, 360): the first leg's before any turn, each turn's
    /// heading after it, blended (smoothstep, the short way round) within a turn.
    func heading(at t: Double) -> Double {
        guard let firstLeg = legs.first else { return 0 }
        guard !turns.isEmpty else { return PlaybackGeometry.normalizedDegrees(firstLeg.bearing) }
        // The last turn starting before `t`.
        var low = -1, high = turns.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if turns[middle].start < t { low = middle } else { high = middle - 1 }
        }
        guard low >= 0 else { return turns[0].from }
        let turn = turns[low]
        guard t < turn.end, turn.end > turn.start else { return turn.to }
        let share = Self.ease((t - turn.start) / (turn.end - turn.start))
        return PlaybackGeometry.normalizedDegrees(turn.from + turn.change * share)
    }
}

/// One calendar day of the playback.
public struct PlaybackDay: Hashable, Sendable {
    /// From 0; "Tag 3 von 9" is index 2.
    public var index: Int
    /// The local calendar day (`TripGeometry.firstDay` plus `index`).
    public var day: LocalDay
    /// Seconds from the playback's start.
    public var start: Double
    public var end: Double
    /// The trip's photos on the map that day (`TripGeometry.dayCounts`).
    public var photoCount: Int
    /// The places of the day's stops, in route order (empty for a day without a stop of its own).
    public var placeIndices: [Int]
    /// The legs arriving this day, into `PlaybackPlan.legs`.
    public var legs: Range<Int>
    /// The day's own stops, into `PlaybackPlan.stops`.
    public var stops: [Int]
    /// Where the day ends: its last stop, or where it holds (the last stop of an earlier day; the
    /// first stop before the route begins). `nil` only for a trip without stops.
    public var lastStop: Int?
    /// When its legs are done and it holds at `lastStop` (its start for a day without legs).
    public var holdStart: Double
    /// The place the day is about at its end ("Tag 3 von 9 · Vík"): `lastStop`'s.
    public var placeIndex: Int?

    public init(index: Int, day: LocalDay, start: Double, end: Double, photoCount: Int, placeIndices: [Int], legs: Range<Int>, stops: [Int],
                lastStop: Int?, holdStart: Double, placeIndex: Int?) {
        self.index = index
        self.day = day
        self.start = start
        self.end = end
        self.photoCount = photoCount
        self.placeIndices = placeIndices
        self.legs = legs
        self.stops = stops
        self.lastStop = lastStop
        self.holdStart = holdStart
        self.placeIndex = placeIndex
    }

    public var duration: Double { end - start }
    /// Whether the day has photos on the map or a stop of its own.
    public var hasPhotos: Bool { photoCount > 0 || !stops.isEmpty }
}

/// A point of the route the dot passes: a visit to a place of the trip.
public struct PlaybackStop: Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// Into `TripGeometry.places`.
    public var placeIndex: Int
    /// The day the dot arrives there.
    public var dayIndex: Int
    /// The camera's distance while the dot rests there.
    public var cameraMeters: Double

    public init(coordinate: GeoCoordinate, placeIndex: Int, dayIndex: Int, cameraMeters: Double) {
        self.coordinate = coordinate
        self.placeIndex = placeIndex
        self.dayIndex = dayIndex
        self.cameraMeters = cameraMeters
    }
}

/// The straight line (great circle) from one stop to the next, and when the dot goes along it.
public struct PlaybackLeg: Hashable, Sendable {
    /// Into `PlaybackPlan.stops`.
    public var from: Int
    public var to: Int
    /// The day it belongs to: the day of its arrival.
    public var dayIndex: Int
    public var start: Double
    public var end: Double
    /// Great-circle length.
    public var meters: Double
    /// The direction of travel, degrees clockwise from north (at the leg's middle).
    public var bearing: Double
    /// The trip's leg "ohne Fotos" (`RouteLeg.withoutPhotos`).
    public var withoutPhotos: Bool

    public init(from: Int, to: Int, dayIndex: Int, start: Double, end: Double, meters: Double, bearing: Double, withoutPhotos: Bool) {
        self.from = from
        self.to = to
        self.dayIndex = dayIndex
        self.start = start
        self.end = end
        self.meters = meters
        self.bearing = bearing
        self.withoutPhotos = withoutPhotos
    }
}

/// Where the camera is, as `MKMapCamera(lookingAtCenter:fromDistance:pitch:heading:)` takes it.
public struct PlaybackCamera: Hashable, Sendable {
    /// The point looked at: the dot.
    public var center: GeoCoordinate
    /// Metres from the camera to `center`.
    public var distanceMeters: Double
    /// Degrees from looking straight down.
    public var pitchDegrees: Double
    /// Degrees clockwise from north the camera faces: the direction of travel, so it looks from
    /// behind.
    public var headingDegrees: Double

    public init(center: GeoCoordinate, distanceMeters: Double, pitchDegrees: Double, headingDegrees: Double) {
        self.center = center
        self.distanceMeters = distanceMeters
        self.pitchDegrees = pitchDegrees
        self.headingDegrees = headingDegrees
    }
}

/// Everything at one moment of the playback (`PlaybackPlan.frame(at:)`).
public struct PlaybackFrame: Hashable, Sendable {
    public var time: Double
    public var dayIndex: Int
    /// How far into its day, 0 to 1.
    public var dayProgress: Double
    /// The dot.
    public var position: GeoCoordinate
    public var camera: PlaybackCamera
    /// The leg the dot moves along; `nil` while it rests at a stop.
    public var legIndex: Int?
    /// The stops reached (the dot passed them or rests at the last of them); at least 1 when the
    /// trip has stops.
    public var reachedStops: Int
    /// The place the dot is at (resting, or just leaving or arriving): its photos show beside it.
    /// `nil` on the way.
    public var placeIndex: Int?
    /// The place the day's title names now: the one the dot is at or heads to.
    public var titlePlaceIndex: Int?

    public init(time: Double, dayIndex: Int, dayProgress: Double, position: GeoCoordinate, camera: PlaybackCamera, legIndex: Int?,
                reachedStops: Int, placeIndex: Int?, titlePlaceIndex: Int?) {
        self.time = time
        self.dayIndex = dayIndex
        self.dayProgress = dayProgress
        self.position = position
        self.camera = camera
        self.legIndex = legIndex
        self.reachedStops = reachedStops
        self.placeIndex = placeIndex
        self.titlePlaceIndex = titlePlaceIndex
    }
}

/// The route's lines at a moment (`PlaybackPlan.route(for:)`).
public struct PlaybackRoute: Hashable, Sendable {
    /// The stops reached, in order: drawn solid white with a dark border (fewer than 2: none).
    public var travelled: [GeoCoordinate]
    /// From the last stop reached to the next one: drawn dashed (empty at the end).
    public var ahead: [GeoCoordinate]

    public init(travelled: [GeoCoordinate], ahead: [GeoCoordinate]) {
        self.travelled = travelled
        self.ahead = ahead
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

    /// The unit vector of a coordinate.
    static func vector(_ c: GeoCoordinate) -> (x: Double, y: Double, z: Double) {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    static func coordinate(_ v: (x: Double, y: Double, z: Double)) -> GeoCoordinate {
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
        return coordinate((p.x * wa + q.x * wb, p.y * wa + q.y * wb, p.z * wa + q.z * wb))
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
