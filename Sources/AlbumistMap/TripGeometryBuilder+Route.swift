import Foundation
import AlbumistCore

// The route of `TripGeometryBuilder`: the visits to the trip places in time order, the legs
// nobody went (photos taken at the same time in two places), the cut to at most
// `TripGeometry.maxRoutePoints` points and the legs between them.

extension TripGeometryBuilder {
    // MARK: Route

    /// The route (`RoutePoint`) and its legs.
    ///
    /// The visits: the photos on the map in time order, each at the trip place of its day place
    /// (photos in no place are skipped), consecutive photos at one place one visit. A → B → A in
    /// one day are three visits.
    ///
    /// Some legs from one visit to the next nobody went (`travelledLegs`): the two visits were
    /// taken at the same time in two places, by a second camera in the library (an iCloud Shared
    /// Library) or with a wrong location. The order of a run of visits joined by such legs is no
    /// way anyone went, so the route passes each of the run's places once, at its first visit in
    /// the run: photos taken in turn in two places add no point and no kilometre, whichever of
    /// them came last. A leg someone went starts a new run, from where the last photos before it
    /// were taken: when the run's last visit was left out (its place once), the route goes back
    /// to that place first, so the leg on does not start where nobody was any more (review: an
    /// afternoon in turn in Reykjavík and at Þingvellir, then the evening in Reykjavík and on to
    /// Vík; with the afternoon's last photos in Reykjavík the route went from Þingvellir to Vík).
    /// A visit to the route's last point's own place adds no point but lengthens it to the
    /// visit's last photo.
    ///
    /// The legs are those between all the visits (`legs`). More than `TripGeometry.maxRoutePoints`
    /// visits are then cut (`simplified`), each leg of the cut route carrying the legs it stands
    /// for (`cutLegs`): "vor Ort" counts every leg, the cut changes only what is drawn.
    static func route(placeOfPhoto: [Int], photos: [Photo], coordinates: [GeoCoordinate]) -> (visits: [Visit], legs: [RouteLeg]) {
        var all: [Visit] = []
        for (i, place) in placeOfPhoto.enumerated() where place >= 0 {
            if let last = all.last, last.place == place {
                all[all.count - 1].last = i
            } else {
                all.append(Visit(place: place, first: i, last: i))
            }
        }
        let travelled = travelledLegs(all, photos: photos)
        // The visits kept; the runs of visits joined by legs nobody went, numbered, and per place
        // the last run it was kept in.
        var visits: [Visit] = []
        var run = 0
        var keptInRun = [Int](repeating: -1, count: coordinates.count)
        for (k, visit) in all.enumerated() {
            if k == 0 {
                visits.append(visit)
            } else if travelled[k - 1] {
                // A new run, from where the last photos were taken: the run's last visit first
                // when its place is not the route's last point. Then the visit, at that point
                // when it is here already.
                run += 1
                let left = all[k - 1]
                if visits[visits.count - 1].place != left.place { visits.append(left) }
                if visits[visits.count - 1].place == visit.place {
                    visits[visits.count - 1].last = visit.last
                } else {
                    visits.append(visit)
                }
            } else if keptInRun[visit.place] != run {
                // In the run of the visit before: its place once.
                visits.append(visit)
            }
            keptInRun[visit.place] = run
        }

        let legs = legs(visits, photos: photos, coordinates: coordinates)
        guard visits.count > TripGeometry.maxRoutePoints else { return (visits, legs) }
        let cut = simplified(visits, coordinates: coordinates, limit: TripGeometry.maxRoutePoints)
        return (cut.visits, cutLegs(legs, startingAt: cut.starts))
    }

    /// Faster than this, as the crow flies from the last photo at one place to the first at the
    /// next, nobody goes door to door on the ground between the places of a trip, except by
    /// high-speed train between stations a hundred kilometres and more apart (Beijing to Tianjin,
    /// 108 km in half an hour): a car averages well under it even on a motorway, the Shanghai
    /// airport maglev comes to some 180 km/h (24 km in eight minutes). Planes reach it in the air
    /// and, gate to gate, from some 150 km on (Honolulu to Maui in 40 minutes). 200 km/h, in
    /// metres per second.
    static let turnBackSpeed = 200.0 / 3.6
    /// At most this long at each place on the way of a quick return (`travelledLegs`), from its
    /// first photo there to its last, is turning back right away: an hour. Whoever gets
    /// somewhere that fast mostly stays for hours (a day out by high-speed train, an island by
    /// plane); two cameras taking photos in turn mostly stay minutes at each turn.
    static let turnBackStay: TimeInterval = 3_600

    /// For each leg from one visit to the next (`visits[k]` to `visits[k + 1]`, from the last
    /// photo of the one to the first of the other), whether someone went it, as far as the photos
    /// tell. Nobody went it
    /// - when nothing could have gone it in the time, not even a plane (`isNoTravel`); or
    /// - when it lies on a **quick return** that shares a visit with another one: two returns in
    ///   a row (A → B → A → B, or A → B → A → C → A with the visit between them as long as it may
    ///   be, or three places in turn, A → B → C → A → B). A quick return goes from a visit back
    ///   to the next visit at its place through visits of at most `turnBackStay` each, its legs
    ///   together faster than `turnBackSpeed` as the crow flies. Once is a way people go: a
    ///   scenic flight circling a glacier and back to the airfield, a high-speed train out and
    ///   straight back, once round by helicopter. Twice in a row is not: the photos were taken in
    ///   two or three places at the same time, by several cameras or with a location jumping to
    ///   and fro (review: Reykjavík and Þingvellir, 41 km apart, in turn every ten minutes made
    ///   18 route points and 700 km "vor Ort"). The legs together, not each one: two cameras take
    ///   their photos at minutes of their own, so the way from one to the other may take a minute
    ///   and the way back the rest of the round, and the round is what nobody goes (third review:
    ///   with the photos at the same minutes it was 18 route points again; three people in three
    ///   places, 36 route points and 1,704 km).
    ///
    /// So photos taken in turn in several places still zig-zag when going round is slower than
    /// `turnBackSpeed` (two cameras 41 km apart in turn every half hour, or 5 to 20 km apart every
    /// 5 to 20 minutes, as a car on a motorway can go), when the route returns quickly once only
    /// (A → B → A, then on to C), and when a visit on the way lasts longer than `turnBackStay`.
    /// Real ways round this fast with no more than `turnBackStay` at each turn, twice in a row
    /// (shuttle flights with a crew's short turnarounds, photos at two spots of a race track lap
    /// after lap), count as no way anyone went. The camera of each photo, stored by the analysis,
    /// would part several cameras' photos at any speed; it is not stored yet.
    static func travelledLegs(_ visits: [Visit], photos: [Photo]) -> [Bool] {
        guard visits.count > 1 else { return [] }
        let count = visits.count
        var travelled: [Bool] = []
        travelled.reserveCapacity(count - 1)
        // Running totals: `meters[k]` and `seconds[k]` of the legs before visit `k`, `long[k]` the
        // visits before it that last longer than `turnBackStay`.
        var meters = [0.0], seconds = [0.0], long = [0]
        meters.reserveCapacity(count)
        seconds.reserveCapacity(count)
        long.reserveCapacity(count + 1)
        for (from, to) in zip(visits, visits.dropFirst()) {
            let a = photos[from.last], b = photos[to.first]
            travelled.append(!isNoTravel(from: a, to: b))
            meters.append(meters[meters.count - 1] + GeoMath.distance(a.coordinate, b.coordinate))
            seconds.append(seconds[seconds.count - 1] + b.date.timeIntervalSince(a.date))
        }
        for visit in visits {
            let stay = photos[visit.last].date.timeIntervalSince(photos[visit.first].date)
            long.append(long[long.count - 1] + (stay > turnBackStay ? 1 : 0))
        }
        // The quick returns, from visit `from` back to its place at visit `to`.
        var returns: [(from: Int, to: Int)] = []
        var lastVisit: [Int: Int] = [:]
        for (k, visit) in visits.enumerated() {
            if let j = lastVisit[visit.place], long[k] == long[j + 1],
               meters[k] - meters[j] > turnBackSpeed * (seconds[k] - seconds[j]) {
                returns.append((j, k))
            }
            lastVisit[visit.place] = k
        }
        // Those sharing a visit with another: their legs. `shared[k]`: the visits before `k` on
        // two returns or more.
        var starts = [Int](repeating: 0, count: count + 1)
        for r in returns {
            starts[r.from] += 1
            starts[r.to + 1] -= 1
        }
        var shared = [0], depth = 0
        shared.reserveCapacity(count + 1)
        for k in 0..<count {
            depth += starts[k]
            shared.append(shared[k] + (depth >= 2 ? 1 : 0))
        }
        for r in returns where shared[r.to + 1] > shared[r.from] {
            for leg in r.from..<r.to { travelled[leg] = false }
        }
        return travelled
    }

    /// Whether nothing could have gone from where `a` was taken to where `b` was in the time
    /// between them (`b` not before `a`), not even a plane (`AirborneFilter.maximumFlightSpeed`,
    /// as the crow flies): they were taken at the same time in two places.
    static func isNoTravel(from a: Photo, to b: Photo) -> Bool {
        GeoMath.distance(a.coordinate, b.coordinate) > AirborneFilter.maximumFlightSpeed * b.date.timeIntervalSince(a.date)
    }

    /// At most `limit` visits of `visits` (concept §9), the first and last always among them,
    /// and where each of them starts in `visits` (`cutLegs`).
    ///
    /// Douglas–Peucker on the sphere: the visits that stand out most from the line through their
    /// neighbours stay. Unlike dropping the visits that change the outline least (Visvalingam),
    /// it keeps an excursion there and back (hotel → far waterfall → hotel), which has no area.
    /// Measured on the sphere (`angleToArc`), so the antimeridian and the poles need no
    /// projection. The tolerance is raised just as far as needed in one step: each visit carries
    /// the largest tolerance at which DP would keep it (`significance`), and the `limit - 2`
    /// inner visits that keep up longest stay (a tie at the cut drops all tied, so never more).
    /// Visits of one place that come next to each other then become one visit, from the first's
    /// arrival to the last's departure.
    static func simplified(_ visits: [Visit], coordinates: [GeoCoordinate], limit: Int) -> (visits: [Visit], starts: [Int]) {
        guard visits.count > limit, limit >= 2 else { return (visits, Array(visits.indices)) }
        let points = visits.map { UnitVector(coordinates[$0.place]) }
        let keep = significance(points, depthLimit: limit - 1)
        let cut = keep[1..<(visits.count - 1)].sorted(by: >)[limit - 2]
        var result: [Visit] = []
        var starts: [Int] = []
        for (i, visit) in visits.enumerated() where i == 0 || i == visits.count - 1 || keep[i] > cut {
            if let last = result.last, last.place == visit.place {
                result[result.count - 1].last = visit.last
            } else {
                result.append(visit)
                starts.append(i)
            }
        }
        return (result, starts)
    }

    /// The legs of a cut route from the legs between all its visits (`legs[i]` from visit `i` to
    /// `i + 1`) and the visit each point of the cut route starts at (`simplified`).
    ///
    /// A point's leg stands for the legs from its first visit up to the next point's: the way
    /// over the visits the cut left out, and an excursion from the point back to it (a hotel
    /// left for the day). The last point's own excursions go with the last leg. So the cut route
    /// keeps the metres of every leg ("vor Ort"), each in the leg drawn in its place. A leg is
    /// "ohne Fotos" when more than half of its metres were.
    static func cutLegs(_ legs: [RouteLeg], startingAt starts: [Int]) -> [RouteLeg] {
        guard starts.count >= 2 else { return [] }
        return (0..<(starts.count - 1)).map { j in
            let upTo = j + 2 < starts.count ? starts[j + 1] : legs.count
            var meters = 0.0, withoutPhotos = 0.0
            for leg in legs[starts[j]..<upTo] {
                meters += leg.meters
                if leg.withoutPhotos { withoutPhotos += leg.meters }
            }
            return RouteLeg(meters: meters, withoutPhotos: withoutPhotos > meters / 2)
        }
    }

    /// A deviation smaller than this (radians, 1 m on the Earth) keeps no visit: it is no turn
    /// worth a route point, and a run of visits back and forth between two places (all on the
    /// line between them) costs no recursion.
    static let minimumDeviation = 1 / GeoMath.earthRadiusMeters

    /// A run of points that `significance` has yet to split: from `first` to `last`, the
    /// largest tolerance the splits above it allow (`ceiling`), and its depth (1 for all the
    /// points, one more for each split above it).
    private struct Segment {
        var first: Int
        var last: Int
        var ceiling: Double
        var depth: Int
    }

    /// For each point, the largest tolerance (an angle) at which Douglas–Peucker keeps it: its
    /// distance from the arc it split, capped by that of every split above it (DP stops at a
    /// segment whose farthest point is within the tolerance, whatever lies below). 0: never kept;
    /// first and last are kept anyway. The farthest point of a segment, ties to the first.
    ///
    /// Splits deeper than `depthLimit` are not worked out: a point there has at least
    /// `depthLimit` splits above it keeping up as long as it does, so it is never among the
    /// `depthLimit - 1` inner points kept. That bounds the cost at `depthLimit` passes over the
    /// points, however unevenly they split.
    static func significance(_ points: [UnitVector], depthLimit: Int) -> [Double] {
        var result = [Double](repeating: 0, count: points.count)
        guard points.count > 2 else { return result }
        var segments = [Segment(first: 0, last: points.count - 1, ceiling: .infinity, depth: 1)]
        while let segment = segments.popLast() {
            guard segment.last - segment.first > 1, segment.depth <= depthLimit else { continue }
            var farthest = segment.first + 1
            var deviation = -1.0
            for k in (segment.first + 1)..<segment.last {
                let d = angleToArc(points[k], points[segment.first], points[segment.last])
                if d > deviation { (farthest, deviation) = (k, d) }
            }
            guard deviation >= minimumDeviation else { continue }
            let kept = min(deviation, segment.ceiling)
            result[farthest] = kept
            segments.append(Segment(first: segment.first, last: farthest, ceiling: kept, depth: segment.depth + 1))
            segments.append(Segment(first: farthest, last: segment.last, ceiling: kept, depth: segment.depth + 1))
        }
        return result
    }

    /// The angle from `p` to the shorter great-circle arc from `a` to `b`: to the arc itself where
    /// `p`'s foot on the great circle lies between them, else to the nearer end.
    static func angleToArc(_ p: UnitVector, _ a: UnitVector, _ b: UnitVector) -> Double {
        let toEnds = min(p.angle(to: a), p.angle(to: b))
        let normal = a.cross(b)
        let length = normal.length
        guard length > 1e-15 else { return toEnds }
        let n = normal.scaled(1 / length)
        let sine = p.dot(n)
        let foot = p + n.scaled(-sine)
        guard a.cross(foot).dot(n) >= 0, foot.cross(b).dot(n) >= 0 else { return toEnds }
        return min(asin(min(1, abs(sine))), toEnds)
    }

    /// One leg per pair of route points, as the crow flies (`GeoMath.distance`, right across the
    /// antimeridian). "ohne Fotos" (concept §4.3): longer than `TripGeometry.gapMeters` and no
    /// photo on the map for longer than `TripGeometry.gapDuration` between the departure from
    /// the one and the arrival at the other; a single photo on the way, in no place, counts.
    static func legs(_ visits: [Visit], photos: [Photo], coordinates: [GeoCoordinate]) -> [RouteLeg] {
        zip(visits, visits.dropFirst()).map { from, to in
            let meters = GeoMath.distance(coordinates[from.place], coordinates[to.place])
            var longest: TimeInterval = 0
            if meters > TripGeometry.gapMeters {
                for k in from.last..<to.first { longest = max(longest, photos[k + 1].date.timeIntervalSince(photos[k].date)) }
            }
            return RouteLeg(meters: meters, withoutPhotos: meters > TripGeometry.gapMeters && longest > TripGeometry.gapDuration)
        }
    }
}
