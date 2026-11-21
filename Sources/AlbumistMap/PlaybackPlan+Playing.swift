import Foundation
import AlbumistCore

// `PlaybackPlan` while it plays: the day at a time, the picture at a time (the dot, the camera,
// the route travelled) and the camera's heading through the turns between legs.

extension PlaybackPlan {
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
