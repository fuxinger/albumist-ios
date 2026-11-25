import Foundation
import AlbumistCore

/// The judged photos of a library in time order, with the rules of `AirborneFilter` on them. Kept
/// as arrays of plain values: a large library reads them some hundred thousand times.
///
/// The work stays about linear in the number of photos, however dense the library. A search for a
/// photo's neighbour passes only photos closer to it than `minimumLegMeters`, and
/// - stops after a minute of them for rules 2 to 4: they make a stay (`stayDuration`), so the
///   photo is no window photo whatever lies beyond. A day of thousands of photos whose location
///   jumps between spots a kilometre or two apart indoors would otherwise read the whole day for
///   every photo of it;
/// - stops where no photo further on can end a leg faster than ground transport (`earliest`,
///   `latest`), when only such a leg matters; most photos are not searched at all;
/// - passes groups (`AirborneFilter.groupRadiusMeters`) whole, and is kept (`Neighbours`).
///
/// Rule 4 judges only photos within `runEndLongDuration` of a photo of rules 1 to 3.
///
/// Here the track and its distances and legs; the search for a photo's neighbours in
/// `FlightTrack+Neighbours.swift`, the rules in `FlightTrack+Judging.swift`, rule 3's bursts in
/// `FlightTrack+Bursts.swift`.
struct FlightTrack: Sendable {
    /// Time order; equal times by id, then by location (so a library holding one id twice still
    /// has one order, whatever order it came in).
    let ids: [AssetID]
    let times: [TimeInterval]
    let coordinates: [GeoCoordinate]
    /// The stated horizontal accuracy of each location in metres, 0 where unknown.
    let accuracies: [Double]
    /// When each photo's fix was taken, as far as the photos tell: a photo on exactly the fix of
    /// the photo before it **repeats** that fix (the iPhone did not update the location between
    /// them), and its fix is as old as the first photo of the row that carries it. A fix frozen
    /// in the cabin shows where the plane was then, not where it is: it makes no stay of a burst
    /// and no return (`headsOn`, `comesBack`).
    let fixTimes: [TimeInterval]
    /// `steps[k]`: the distance from photo `k - 1` to photo `k` (0 for the first).
    let steps: [Double]
    /// `pathMeters[k]`: the steps up to photo `k` added up. No two photos lie further apart than
    /// the way between them, so a search for a photo near one can pass the photos the way
    /// cannot bring near enough (`comesBack`).
    let pathMeters: [Double]
    /// The first and last photo at most `maximumLongLegDuration` before and after each photo.
    let windowStart: [Int]
    let windowEnd: [Int]
    /// Where a search for a leg faster than ground transport can stop: no photo before
    /// `earliest[i]` (after `latest[i]`) can end one at `i`; `i` itself when no photo can.
    ///
    /// The search for the neighbour before `i` passes only photos closer to `i` than
    /// `minimumLegMeters`, so the neighbour `j` it finds is at most that plus the step from `j` to
    /// the photo after it. The leg is fast only if that step exceeds `maximumGroundSpeed` times the
    /// time from `j` to `i`, less `minimumLegMeters`: `earliest[i]` is the first photo in the window
    /// with such a step. On the ground, steps fall behind by minutes; only flights, fast trains,
    /// wrong locations and photos seconds apart make one. Once a photo's step falls short for `i`,
    /// it falls short for every later photo, so one pointer moving forward finds them all (and for
    /// the leg after, one moving back).
    ///
    /// The search passes photos out of reach as well (`AirborneFilter.jumpMeters`), and the bound
    /// holds until it has passed one: the first such photo `k` it meets lies further from `i` than
    /// `maximumFlightSpeed` covers in their time, the photo after `k` closer than
    /// `minimumLegMeters`, so `k`'s step is long enough not to lie before `earliest[i]`. Past it
    /// the search goes on unbounded.
    let earliest: [Int]
    let latest: [Int]
    /// As `earliest` and `latest`, for a leg faster than `AirborneFilter.turnBackSpeed` (the turn
    /// back of rule 2).
    let turnEarliest: [Int]
    let turnLatest: [Int]
    /// The first photo of each group (`AirborneFilter.groupRadiusMeters`), ascending. Only for the
    /// search for a photo's neighbours (`neighbour`).
    let groupStarts: [Int]
    /// The group of each photo.
    let groupOf: [Int]

    /// Any distance computed may be off by far less than this from the true one. A group is only
    /// passed or taken whole when this far clear of `minimumLegMeters` (else its photos are read
    /// one by one), so the shortcut gives exactly the photo-by-photo result.
    static let roundingMarginMeters = 1.0
    /// `earliest` and `latest` add a step to a leg's length: they only rule a photo out when this
    /// far clear, so rounding never rules out one the rules would take.
    static let boundMarginMeters = 100.0

    init(_ photos: [AssetSnapshot]) {
        let judged = Self.judged(photos)
        ids = judged.ids
        times = judged.times
        coordinates = judged.coordinates
        accuracies = judged.accuracies
        let sorted = judged.times, located = judged.coordinates
        var fixTimes = sorted
        for k in fixTimes.indices.dropFirst() where located[k] == located[k - 1] { fixTimes[k] = fixTimes[k - 1] }
        self.fixTimes = fixTimes

        let path = Self.path(along: located)
        steps = path.steps
        pathMeters = path.meters
        let groups = Self.groups(of: located)
        groupStarts = groups.starts
        groupOf = groups.ofPhoto

        let before = Self.boundsBefore(times: sorted, steps: path.steps)
        let after = Self.boundsAfter(times: sorted, steps: path.steps)
        windowStart = before.window
        earliest = before.run
        turnEarliest = before.turn
        windowEnd = after.window
        latest = after.run
        turnLatest = after.turn
    }

    // MARK: Building the track

    /// The judged photos' values, one array each, in time order (`ids`).
    private struct JudgedPhotos {
        var ids: [AssetID]
        var times: [TimeInterval]
        var coordinates: [GeoCoordinate]
        var accuracies: [Double]
    }

    /// The photos of `photos` the filter judges (a usable location, a date, no screenshot), in
    /// time order.
    private static func judged(_ photos: [AssetSnapshot]) -> JudgedPhotos {
        var ids: [AssetID] = [], times: [TimeInterval] = [], coordinates: [GeoCoordinate] = [], accuracies: [Double] = []
        ids.reserveCapacity(photos.count)
        times.reserveCapacity(photos.count)
        coordinates.reserveCapacity(photos.count)
        accuracies.reserveCapacity(photos.count)
        for photo in photos {
            guard let coordinate = photo.usableLocation, let date = photo.creationDate, !photo.isScreenshotLike else { continue }
            ids.append(photo.id)
            times.append(date.timeIntervalSinceReferenceDate)
            coordinates.append(coordinate)
            accuracies.append(photo.locationAccuracy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0)
        }
        // By time; the rest of the key only for equal times, which are rare.
        let order = times.indices.sorted { a, b in
            if times[a] != times[b] { return times[a] < times[b] }
            if ids[a] != ids[b] { return ids[a] < ids[b] }
            if coordinates[a].latitude != coordinates[b].latitude { return coordinates[a].latitude < coordinates[b].latitude }
            return coordinates[a].longitude < coordinates[b].longitude
        }
        return JudgedPhotos(ids: order.map { ids[$0] }, times: order.map { times[$0] }, coordinates: order.map { coordinates[$0] },
                            accuracies: order.map { accuracies[$0] })
    }

    /// `steps` and `pathMeters` of the photos at `located`, in time order.
    private static func path(along located: [GeoCoordinate]) -> (steps: [Double], meters: [Double]) {
        var steps = [Double](repeating: 0, count: located.count), pathMeters = steps
        for i in located.indices.dropFirst() {
            steps[i] = GeoMath.distance(located[i - 1], located[i])
            pathMeters[i] = pathMeters[i - 1] + steps[i]
        }
        return (steps, pathMeters)
    }

    /// `groupStarts` and `groupOf` of the photos at `located`, in time order: a photo within
    /// `AirborneFilter.groupRadiusMeters` of the first photo of the last group joins it, any other
    /// starts a group.
    private static func groups(of located: [GeoCoordinate]) -> (starts: [Int], ofPhoto: [Int]) {
        var groupStarts: [Int] = [], groupOf = [Int](repeating: 0, count: located.count)
        for i in located.indices {
            if let start = groupStarts.last, GeoMath.distance(located[start], located[i]) <= AirborneFilter.groupRadiusMeters {
                groupOf[i] = groupStarts.count - 1
            } else {
                groupStarts.append(i)
                groupOf[i] = groupStarts.count - 1
            }
        }
        return (groupStarts, groupOf)
    }

    /// Where the searches on one side of each photo end: its window (`windowStart` or
    /// `windowEnd`), and where a search for a leg faster than ground transport (`earliest` or
    /// `latest`) and for a turn back (`turnEarliest` or `turnLatest`) can stop.
    private struct SearchBounds {
        var window: [Int]
        var run: [Int]
        var turn: [Int]
    }

    /// The bounds before each photo, from the photos' times in time order and their `steps`.
    private static func boundsBefore(times sorted: [TimeInterval], steps: [Double]) -> SearchBounds {
        let count = sorted.count
        let speed = AirborneFilter.maximumGroundSpeed, turn = AirborneFilter.turnBackSpeed
        let window = AirborneFilter.maximumLongLegDuration, reach = AirborneFilter.minimumLegMeters + Self.boundMarginMeters
        var windowStart = [Int](repeating: 0, count: count), earliest = windowStart, turnEarliest = windowStart
        var start = 0, first = 0, turnFirst = 0
        for i in 0..<count {
            while sorted[i] - sorted[start] > window { start += 1 }
            windowStart[i] = start
            first = max(first, start)
            while first < i && steps[first + 1] <= speed * (sorted[i] - sorted[first]) - reach { first += 1 }
            earliest[i] = first
            turnFirst = max(turnFirst, start)
            while turnFirst < i && steps[turnFirst + 1] <= turn * (sorted[i] - sorted[turnFirst]) - reach { turnFirst += 1 }
            turnEarliest[i] = turnFirst
        }
        return SearchBounds(window: windowStart, run: earliest, turn: turnEarliest)
    }

    /// The bounds after each photo, as `boundsBefore` on the other side.
    private static func boundsAfter(times sorted: [TimeInterval], steps: [Double]) -> SearchBounds {
        let count = sorted.count
        let speed = AirborneFilter.maximumGroundSpeed, turn = AirborneFilter.turnBackSpeed
        let window = AirborneFilter.maximumLongLegDuration, reach = AirborneFilter.minimumLegMeters + Self.boundMarginMeters
        var windowEnd = [Int](repeating: 0, count: count), latest = windowEnd, turnLatest = windowEnd
        var end = count - 1, last = count - 1, turnLast = count - 1
        for i in stride(from: count - 1, through: 0, by: -1) {
            while sorted[end] - sorted[i] > window { end -= 1 }
            windowEnd[i] = end
            last = min(last, end)
            while last > i && steps[last] <= speed * (sorted[last] - sorted[i]) - reach { last -= 1 }
            latest[i] = last
            turnLast = min(turnLast, end)
            while turnLast > i && steps[turnLast] <= turn * (sorted[turnLast] - sorted[i]) - reach { turnLast -= 1 }
            turnLatest[i] = turnLast
        }
        return SearchBounds(window: windowEnd, run: latest, turn: turnLatest)
    }

    // MARK: Distances and legs

    /// The ids of the photos whose flag is set.
    func ids(where flags: [Bool]) -> Set<AssetID> {
        var result = Set<AssetID>()
        for i in flags.indices where flags[i] { result.insert(ids[i]) }
        return result
    }

    /// The distance between two photos, always measured from the earlier one.
    func meters(_ a: Int, _ b: Int) -> Double {
        a <= b ? GeoMath.distance(coordinates[a], coordinates[b]) : GeoMath.distance(coordinates[b], coordinates[a])
    }

    func seconds(_ a: Int, _ b: Int) -> TimeInterval { (times[b] - times[a]).magnitude }

    /// Faster than `AirborneFilter.turnBackSpeed` (equal times included, at any distance above
    /// zero): a leg on which a run turns back when it leaves the way.
    func fasterThanTurnBack(_ a: Int, _ b: Int) -> Bool { meters(a, b) > AirborneFilter.turnBackSpeed * seconds(a, b) }

    /// Flown: faster than ground transport, not faster than a plane.
    func flown(_ a: Int, _ b: Int) -> Bool {
        let meters = meters(a, b), seconds = seconds(a, b)
        return meters > AirborneFilter.maximumGroundSpeed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
    }

    /// Whether the way from `a` to the later `b` leaves time to land or take off on it
    /// (`AirborneFilter.landingDuration`): it was no faster than ground transport, or a plane at
    /// `maximumFlightSpeed` covers it in its time less `landingDuration`.
    func leavesTimeToLand(_ a: Int, _ b: Int) -> Bool {
        let meters = meters(a, b), seconds = seconds(a, b)
        return meters <= AirborneFilter.maximumGroundSpeed * seconds
            || meters <= AirborneFilter.maximumFlightSpeed * (seconds - AirborneFilter.landingDuration)
    }

    /// `middle` on the way from `from` to `to` (`AirborneFilter.detourFactor`).
    func onTheWay(_ from: Int, _ middle: Int, _ to: Int) -> Bool {
        meters(from, middle) + meters(middle, to) <= AirborneFilter.detourFactor * meters(from, to) + AirborneFilter.detourAllowanceMeters
    }
}
