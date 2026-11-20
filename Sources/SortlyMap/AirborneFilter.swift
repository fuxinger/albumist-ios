import Foundation
import SortlyCore

/// Photos taken in flight (concept §5, "Flugzeugfotos zählen nicht"): they make no place, no
/// country and no record. Without this, three window photos over France on the way to Lisbon
/// would make France a visited country and a place in the clouds.
///
/// A photo counts as taken in flight when
/// - the iPhone stored an altitude above `maximumAltitude` for it, or
/// - it lies on a fast, straight run: its nearest photo before and its nearest photo after it
///   that are at least `minimumLegMeters` away and at most `maximumLegDuration` apart in time
///   were both reached faster than any ground transport (`maximumGroundSpeed`), and it lies on
///   the way between them.
///
/// "On the way" keeps zig-zags on the ground: in an iCloud Shared Library two people's photos
/// from Munich and Rome interleave in time, and a single photo with a wrong location jumps away
/// and back. Both look fast, but neither lies between its neighbours. (A single wrong photo
/// makes no place anyway: a place needs three photos.) The price: window photos interleaved
/// with photos someone takes at home zig-zag too and stay in; their altitude, where stored,
/// still catches them.
public enum AirborneFilter {
    /// Above this a photo was taken in a plane (concept §5: "Fotos über 6.000 m Höhe"). Places
    /// people photograph on the ground stay below it (Kilimanjaro 5,895 m, the Everest base camp
    /// 5,364 m); the few higher summits are left out with the planes.
    public static let maximumAltitude = 6_000.0
    /// Faster than this from one photo to the next is no ground transport (concept §5:
    /// "schneller als ein Flugzeug am Boden"): high-speed trains run at up to 350 km/h in
    /// service, planes cruise at 800 to 900 km/h over the ground. 400 km/h, in metres per second.
    public static let maximumGroundSpeed = 400.0 / 3.6
    /// Shorter legs say nothing about speed: the GPS fixes of photos seconds apart jitter by some
    /// hundred metres, which looks like any speed. A neighbour is the nearest photo at least
    /// this far away (a burst of window photos seconds apart reaches past its own burst).
    public static let minimumLegMeters = 3_000.0
    /// A longer gap between two photos says nothing about the speed in between (a night in a
    /// hotel, then a flight, looks slow). It also bounds the search for a photo's neighbours to
    /// the photos of two hours around it.
    public static let maximumLegDuration: TimeInterval = 2 * 3_600

    /// "On the way": both legs together at most this many times the direct way from the photo
    /// before to the photo after (brief: about 1.3). A plane's track bends far less between two
    /// photos (two equal legs pass up to a turn of 79°); a zig-zag goes there and back, twice
    /// the way over a direct way of almost nothing.
    static let detourFactor = 1.3
    /// ... plus this. On the shortest legs (3 km each) GPS errors alone can lengthen the two legs
    /// of a straight flight past 1.3 times the direct way; 2 km covers errors of about 600 m on
    /// each of the three photos there. A zig-zag has at least two legs of 3 km, 6 km over a direct
    /// way near nothing, and stays out.
    static let detourAllowanceMeters = 2_000.0
    /// Photos one after another within this of the first of them form a group, which the search
    /// for a photo's neighbours passes or takes with one distance instead of one per photo, so a
    /// long burst at one place costs no more than a single photo. A third of a leg: two photos
    /// of one group are at most 2 km apart, so no group holds a leg.
    static let groupRadiusMeters = minimumLegMeters / 3

    /// The photos of `photos` taken in flight.
    /// - Parameters:
    ///   - photos: the whole library, in any order (a photo's neighbours are the photos taken
    ///     before and after it, whatever trip they belong to). Only photos with a usable location
    ///     and a date that are no screenshots are judged; the others are never in the result
    ///     and are nobody's neighbour.
    ///   - altitudes: metres above sea level the iPhone stored, by photo, where known.
    public static func airborne(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> Set<AssetID> {
        let track = FlightTrack(photos)
        var result = Set<AssetID>()
        for i in track.ids.indices {
            if !altitudes.isEmpty, let altitude = altitudes[track.ids[i]], altitude > maximumAltitude {
                result.insert(track.ids[i])
            } else if track.isOnFastStraightRun(i) {
                result.insert(track.ids[i])
            }
        }
        return result
    }
}

/// The judged photos of a library in time order, with the search for a photo's neighbours
/// (`AirborneFilter`). Kept as arrays of plain values: a large library reads them some hundred
/// thousand times.
struct FlightTrack: Sendable {
    /// Time order; equal times by id, then by location (so a library holding one id twice still
    /// has one order, whatever order it came in).
    let ids: [AssetID]
    let times: [TimeInterval]
    let coordinates: [GeoCoordinate]
    /// The first photo of each group (`AirborneFilter.groupRadiusMeters`), ascending.
    private let groupStarts: [Int]
    /// The group of each photo.
    private let groupOf: [Int]
    /// Per photo, the latest photo at or before it reached by a step that may be fast (from the
    /// photo just before it), or -1.
    private let lastFastStep: [Int]
    /// Per photo, the earliest photo after it reached by a step that may be fast, or -1.
    private let nextFastStep: [Int]

    /// Any distance computed may be off by far less than this from the true one. A group is only
    /// passed or taken whole when this far clear of `minimumLegMeters` (else its photos are read
    /// one by one), and a step only counts as surely slow when this far below the speed limit:
    /// so the shortcuts give exactly the photo-by-photo result.
    private static let roundingMarginMeters = 1.0

    init(_ photos: [AssetSnapshot]) {
        var ids: [AssetID] = [], times: [TimeInterval] = [], coordinates: [GeoCoordinate] = []
        ids.reserveCapacity(photos.count)
        times.reserveCapacity(photos.count)
        coordinates.reserveCapacity(photos.count)
        for photo in photos {
            guard let coordinate = photo.usableLocation, let date = photo.creationDate, !photo.isScreenshotLike else { continue }
            ids.append(photo.id)
            times.append(date.timeIntervalSinceReferenceDate)
            coordinates.append(coordinate)
        }
        // By time; the rest of the key only for equal times, which are rare.
        let order = times.indices.sorted { a, b in
            if times[a] != times[b] { return times[a] < times[b] }
            if ids[a] != ids[b] { return ids[a] < ids[b] }
            if coordinates[a].latitude != coordinates[b].latitude { return coordinates[a].latitude < coordinates[b].latitude }
            return coordinates[a].longitude < coordinates[b].longitude
        }
        self.ids = order.map { ids[$0] }
        self.times = order.map { times[$0] }
        self.coordinates = order.map { coordinates[$0] }

        let count = order.count
        var groupStarts: [Int] = []
        var groupOf = [Int](repeating: 0, count: count)
        var lastFastStep = [Int](repeating: -1, count: count)
        var latest = -1
        for i in 0..<count {
            let coordinate = self.coordinates[i]
            if let start = groupStarts.last, GeoMath.distance(self.coordinates[start], coordinate) <= AirborneFilter.groupRadiusMeters {
                groupOf[i] = groupStarts.count - 1
            } else {
                groupStarts.append(i)
                groupOf[i] = groupStarts.count - 1
            }
            if i > 0, GeoMath.distance(self.coordinates[i - 1], coordinate)
                > AirborneFilter.maximumGroundSpeed * (self.times[i] - self.times[i - 1]) - Self.roundingMarginMeters {
                latest = i
            }
            lastFastStep[i] = latest
        }
        var nextFastStep = [Int](repeating: -1, count: count)
        var earliest = -1
        var i = count - 1
        while i >= 0 {
            nextFastStep[i] = earliest
            if lastFastStep[i] == i { earliest = i }
            i -= 1
        }
        self.groupStarts = groupStarts
        self.groupOf = groupOf
        self.lastFastStep = lastFastStep
        self.nextFastStep = nextFastStep
    }

    /// Whether the photo at `i` was taken on a fast, straight run (`AirborneFilter`, rule b).
    ///
    /// A leg is never longer than the steps from photo to photo along it, so a leg can only be
    /// fast if one of its steps is. Most photos have no such step within `maximumLegDuration`
    /// before or after them, and need no search at all; the photo after is only looked for
    /// when the leg from the photo before was fast.
    func isOnFastStraightRun(_ i: Int) -> Bool {
        let window = AirborneFilter.maximumLegDuration
        let stepBefore = lastFastStep[i], stepAfter = nextFastStep[i]
        guard stepBefore > 0, times[i] - times[stepBefore - 1] <= window, stepAfter > i, times[stepAfter] - times[i] <= window else { return false }
        let speed = AirborneFilter.maximumGroundSpeed
        // Equal times (a second person's photo in the same second) are infinitely fast and left
        // to the detour test.
        guard let before = neighbour(of: i, step: -1), before.meters > speed * (times[i] - times[before.index]),
              let after = neighbour(of: i, step: 1), after.meters > speed * (times[after.index] - times[i]) else { return false }
        let direct = GeoMath.distance(coordinates[before.index], coordinates[after.index])
        return before.meters + after.meters <= AirborneFilter.detourFactor * direct + AirborneFilter.detourAllowanceMeters
    }

    /// The nearest photo before (`step` -1) or after (`step` 1) the photo at `i` that is at least
    /// `minimumLegMeters` from it and at most `maximumLegDuration` apart in time, with its distance.
    ///
    /// Read group by group: the photos of the photo's own group are all closer than a leg; a
    /// group whose first photo is far enough clear of `minimumLegMeters` is passed or taken whole
    /// (each of its photos lies within `groupRadiusMeters` of its first); only a group straddling
    /// the leg length is read photo by photo. The time bound ends the search.
    func neighbour(of i: Int, step: Int) -> (index: Int, meters: Double)? {
        let time = times[i], here = coordinates[i]
        let minimum = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLegDuration
        let radius = AirborneFilter.groupRadiusMeters, margin = Self.roundingMarginMeters
        var group = groupOf[i] + step
        while group >= 0 && group < groupStarts.count {
            let first = groupStarts[group]
            let last = group + 1 < groupStarts.count ? groupStarts[group + 1] - 1 : times.count - 1
            let nearest = step < 0 ? last : first
            guard (times[nearest] - time).magnitude <= window else { return nil }
            let anchor = GeoMath.distance(coordinates[first], here)
            if anchor + radius + margin < minimum {
                group += step
                continue
            }
            if anchor - radius - margin >= minimum {
                return (nearest, nearest == first ? anchor : GeoMath.distance(coordinates[nearest], here))
            }
            // Straddling: its photos one by one, nearest in time first.
            var j = nearest
            while j >= first && j <= last {
                guard (times[j] - time).magnitude <= window else { return nil }
                let meters = j == first ? anchor : GeoMath.distance(coordinates[j], here)
                if meters >= minimum { return (j, meters) }
                j += step
            }
            group += step
        }
        return nil
    }
}
