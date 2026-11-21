import Foundation
import SortlyCore

/// Photos taken in flight (concept §5, "Flugzeugfotos zählen nicht"): they make no place, no
/// country and no record. Without this, three window photos over France on the way to Lisbon
/// would make France a visited country and a place in the clouds.
///
/// Until the analysis stores altitudes, the photos' places and times decide: nothing on the ground
/// moves faster than `maximumGroundSpeed`, and a plane flies straight on. A photo's two **legs** go
/// to its nearest photo before and its nearest photo after it that are at least `minimumLegMeters`
/// away and at most `maximumLongLegDuration` apart in time; a leg was **flown** when it is faster
/// than `maximumGroundSpeed` and not faster than `maximumFlightSpeed`. A photo counts as taken in
/// flight when
/// 1. the iPhone stored an altitude above `maximumAltitude` for it; or, as long as the location
///    does not **come back** to it (`returnDuration`: no photo one to five minutes before or after
///    it lies within `minimumLegMeters`),
/// 2. **it lies on a run:** both its legs were flown, it lies on the way between them, it shows no
///    stay (`FlightTrack.stays`; while both legs take at most `maximumLegDuration`, only one of at
///    least `stayDuration`), no leg of at most `runEndLongDuration` leads to a photo that stays
///    (`FlightTrack.staysAt`), and the run does not turn back right before or after it (a leg
///    faster than ground transport that leaves the way); or
/// 3. **it is in a burst:** one of `burstPhotos` photos in a row, each at most `burstStepDuration`
///    and at least `burstStepMeters` after the one before, that move steadily (speeds above
///    `burstSpeed`, not faster than a plane, within `burstSpeedRatio` of each other) and straight
///    on (`burstStraightness`); or
/// 4. **it ends a run:** one of its legs leads to a photo of rules 1 to 3, was flown and takes at
///    most `runEndDuration` (or `runEndLongDuration` when faster than `runEndLongSpeed`), the photo
///    lies on the way between its legs, the run goes on in a line beyond that photo, and the photo
///    shows no stay.
///
/// What each part is for, and what keeps the ground on the ground:
/// - Rule 2 finds the window photos in the middle of a flight. Long legs find those of a long-haul
///   flight with a photo every few hours, or a burst over Siberia five hours after the gate photo.
///   A leg faster than `maximumFlightSpeed` is evidence of nothing (two people's photos from Munich
///   and Rome in the same minutes, a wrong location). A **stay**: the photos in a row within
///   `minimumLegMeters` around the photo did not move on along its legs faster than
///   `maximumGroundSpeed` over their time (nor further than their stated accuracy). In a plane such
///   a row lasts well under a minute and moves on at the plane's speed, so a stay is ground (or a
///   location the iPhone failed to update): a layover of three photos over half an hour at Dubai
///   between Munich and Bangkok stays on the ground, so does a quick series of photos there.
///   **A single photo shows no stay:** one photo at a layover between two long-haul legs counts
///   as in flight. That costs no place and no record (both need three photos within 3 km on one
///   day) and no country unless that country's only photos are such single layover photos; but
///   its town is missing from the cities when it has no other photo.
/// - A **short leg to a stay** is no flight leg, for the reason of rule 4 below: a plane needs at
///   least a quarter of an hour from standing on the ground to an average above
///   `maximumGroundSpeed` (and back). It keeps out a location jumping 3 km to one side and 3 km to
///   the other within seconds indoors, between minutes of photos near either end.
/// - The **turn back** check: two people's photos from Munich, Florence and Rome alternating every
///   half hour (an iCloud Shared Library) look like flights Munich → Florence → Rome, but then
///   "fly" straight back to Munich. A real flight goes on, or its next leg is slow.
/// - **Coming back** keeps out a location landing 1 to 3 km off in any direction every few seconds
///   indoors: now and then three of its photos happen to lie in a line at a plane's speed, but
///   within minutes the location is back near each of them. A plane is gone.
/// - Rule 3 finds window photos seconds apart with no photo near enough in time for a leg (a short
///   flight with one series of photos over the Alps). GPS errors make no such series: a location
///   jumping away comes back (not straight on), a first coarse fix closing in on the true place
///   takes ever shorter steps (not steady), a drift indoors is slow. A step shorter than the stated
///   accuracy of its two fixes is no step. (A location sliding steadily at the speed of a plane
///   over four photos without a stated accuracy would count.) `burstSpeed` keeps the fastest trains
///   out with their GPS noise.
/// - Rule 4 finds the first and last window photo of a flight: their other leg goes to the gate
///   photo half an hour before take-off or the arrival photo after landing and is slow. Physical
///   reason it never takes a photo outside the plane: such a photo is taken at least five minutes
///   before the brakes are released for take-off (boarding, doors, taxiing) or after the plane has
///   stopped, and an airliner covers about 30 km in its first five minutes in the air and about
///   80 km (100 with a tailwind) in its first ten. So within `runEndDuration` a photo outside the
///   plane is never 400 km/h × 10 min = 67 km from one in the air, nor within `runEndLongDuration`
///   500 km/h × 15 min = 125 km. (A photo in the plane on the runway may be; it is harmless.)
///   The leg must lead to a confirmed run, because one fast leg proves nothing: a wrong location
///   30 km away a minute after a photo makes one, and "on the way" decides nothing when one leg is
///   ten times the other (3 km back and 30 km on passes `detourFactor` in any direction).
///
/// Window photos it misses (the altitude, once stored, catches them): a flight with fewer than
/// three window photos and no burst, unless its legs to the ground are flown (a short hop with two
/// photos); the first or last window photo more than `runEndDuration` (`runEndLongDuration`)
/// before or after the next one (a long-haul flight with a photo every few hours, unless its leg
/// to the airport is flown), or off the way (a turn after take-off); window photos between photos
/// taken at home by someone else in a shared library (they zig-zag); photos whose location the
/// iPhone did not update in the plane (they look like a stay); a series of two or three photos
/// with no flown leg; a series during the climb or descent slower than `burstSpeed`, unless rule 4
/// takes it; photos of a plane circling back within 3 km in five minutes (a holding pattern).
///
/// Ground photos it can take for window photos: three photos within seconds whose location jumps
/// 3 km and more in a straight line at a plane's speed with no photo near either end and none
/// coming back; four whose location slides like that (rule 3); one photo at a layover between two
/// long-haul legs (or a few seconds of photos there whose location jumps on along the route); one
/// photo half an hour from a place on the line between two others, once (Munich, Florence, Rome);
/// the odd photo of a location scattered further than 3 km within seconds.
public enum AirborneFilter {
    /// Above this a photo was taken in a plane (concept §5: "Fotos über 6.000 m Höhe"). Places
    /// people photograph on the ground stay below it (Kilimanjaro 5,895 m, the Everest base camp
    /// 5,364 m); the few higher summits are left out with the planes.
    public static let maximumAltitude = 6_000.0
    /// Faster than this from one photo to the next is no ground transport (concept §5:
    /// "schneller als ein Flugzeug am Boden"): high-speed trains run at up to 350 km/h in
    /// service, planes cruise at 800 to 900 km/h over the ground. 400 km/h, in metres per second.
    public static let maximumGroundSpeed = 400.0 / 3.6
    /// Faster than this from one photo to the next is no travel at all, not even by plane: the
    /// fastest airliner ground speeds with a strong jet stream reach about 1,300 km/h. Such a
    /// "leg" joins the photos of two people in one library (an iCloud Shared Library, Munich
    /// and Rome in the same minutes) or a wrong location, and is no evidence of a flight; a
    /// trip's route does not zig-zag along it either. 1,500 km/h, in metres per second.
    public static let maximumFlightSpeed = 1_500.0 / 3.6
    /// Shorter legs say nothing about speed: the GPS fixes of photos seconds apart jitter by some
    /// hundred metres, which looks like any speed. A neighbour is the nearest photo at least
    /// this far away (a burst of window photos seconds apart reaches past its own burst).
    public static let minimumLegMeters = 3_000.0
    /// Legs up to this count for any photo that shows no stay of `stayDuration` (rule 2). Longer
    /// ones count, up to `maximumLongLegDuration`, only for a photo that shows no stay at all: a
    /// night in a hotel and then a flight looks slow anyway, but a layover between two flights
    /// looks fast.
    public static let maximumLegDuration: TimeInterval = 2 * 3_600
    /// The longest leg: the longest non-stop flights take some 19 hours from the gate photo to the
    /// arrival photo. It also bounds the search for a photo's neighbours.
    static let maximumLongLegDuration: TimeInterval = 20 * 3_600
    /// A stay this long counts against any leg. The photos of a row lie within `minimumLegMeters`
    /// of the photo, so within 6 km of each other: a plane at `maximumGroundSpeed` or faster leaves
    /// that behind in 54 seconds, so a row lasting a minute and more (with its location updated)
    /// is on the ground. It also bounds the search for a photo's neighbours to a minute of
    /// photos near it, however many photos a day at one place has.
    static let stayDuration: TimeInterval = 60
    /// The location **comes back** when a photo at least `stayDuration` and at most this long
    /// before or after a photo lies closer than `minimumLegMeters` to it. A plane at
    /// `maximumGroundSpeed` and more is 6.7 km on after a minute; to come back within 3 km (with
    /// 500 m of error on either fix) it has to turn through some 230°, which takes it more than 75
    /// seconds even in the tightest turn an airliner flies (30° of bank at 400 km/h, a circle of
    /// 4.4 km): only a plane circling (a holding pattern) comes back, and its photos are missed,
    /// never the ground's. A location jumping around indoors comes back again and again: within
    /// five minutes some of its photos land within 3 km of any one of them.
    static let returnDuration: TimeInterval = 5 * 60

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

    /// Rule 4: the leg from a run's end to the run takes at most this, ...
    static let runEndDuration: TimeInterval = 10 * 60
    /// ... or at most this when faster than `runEndLongSpeed` (window photos 15 minutes apart in
    /// climb or cruise are 650 km/h and more apart). See the type for why no photo outside the plane
    /// passes either.
    static let runEndLongDuration: TimeInterval = 15 * 60
    static let runEndLongSpeed = 500.0 / 3.6

    /// Rule 3: a burst has at least this many photos (three steps; two steps in a line at a steady
    /// speed are too easily a coarse fix closing in) ...
    static let burstPhotos = 4
    /// ... each at most this long after the one before ...
    static let burstStepDuration: TimeInterval = 60
    /// ... and at least this far from it (a plane covers 220 m and more a second; the jitter of a
    /// fix outdoors is tens of metres) ...
    static let burstStepMeters = 200.0
    /// ... faster than this: a plane at cruise flies 800 to 900 km/h, while a train at 350 km/h
    /// covers 194 m in two seconds and would need some 80 m of GPS noise in its direction on every
    /// step in a row to look like this ...
    static let burstSpeed = 500.0 / 3.6
    /// ... at speeds at most this factor apart ...
    static let burstSpeedRatio = 1.5
    /// ... along a path at most this many times the way from the first photo to the last (a turn of
    /// up to about 60° between steps).
    static let burstStraightness = 1.15

    /// The photos of `photos` taken in flight.
    /// - Parameters:
    ///   - photos: the whole library, in any order (a photo's neighbours are the photos taken
    ///     before and after it, whatever trip they belong to). Only photos with a usable location
    ///     and a date that are no screenshots are judged; the others are never in the result
    ///     and are nobody's neighbour.
    ///   - altitudes: metres above sea level the iPhone stored, by photo, where known.
    public static func airborne(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> Set<AssetID> {
        let track = FlightTrack(photos)
        let high = track.ids.map { id in !altitudes.isEmpty && (altitudes[id].map { $0 > maximumAltitude } ?? false) }
        let flags = track.inFlight(high: high)
        var result = Set<AssetID>()
        for i in track.ids.indices where flags[i] { result.insert(track.ids[i]) }
        return result
    }
}

/// The judged photos of a library in time order, with the rules of `AirborneFilter` on them. Kept
/// as arrays of plain values: a large library reads them some hundred thousand times.
///
/// The work stays about linear in the number of photos, however dense the library. A search for a
/// photo's neighbour passes only photos closer to it than `minimumLegMeters`, and
/// - stops after a minute of them for rules 2 and 4: they make a stay (`stayDuration`), so the
///   photo is no window photo whatever lies beyond. A day of thousands of photos whose location
///   jumps between spots a kilometre or two apart indoors would otherwise read the whole day for
///   every photo of it;
/// - stops where no photo further on can end a leg faster than ground transport (`earliest`,
///   `latest`), when only such a leg matters; most photos are not searched at all;
/// - passes groups (`AirborneFilter.groupRadiusMeters`) whole, and is kept (`Neighbours`).
///
/// Rule 4 judges only photos within `runEndLongDuration` of a photo of rules 1 to 3.
struct FlightTrack: Sendable {
    /// Time order; equal times by id, then by location (so a library holding one id twice still
    /// has one order, whatever order it came in).
    let ids: [AssetID]
    let times: [TimeInterval]
    let coordinates: [GeoCoordinate]
    /// The stated horizontal accuracy of each location in metres, 0 where unknown.
    let accuracies: [Double]
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
    let earliest: [Int]
    let latest: [Int]
    /// The first photo of each group (`AirborneFilter.groupRadiusMeters`), ascending.
    private let groupStarts: [Int]
    /// The group of each photo.
    private let groupOf: [Int]

    /// Any distance computed may be off by far less than this from the true one. A group is only
    /// passed or taken whole when this far clear of `minimumLegMeters` (else its photos are read
    /// one by one), so the shortcut gives exactly the photo-by-photo result.
    static let roundingMarginMeters = 1.0
    /// `earliest` and `latest` add a step to a leg's length: they only rule a photo out when this
    /// far clear, so rounding never rules out one the rules would take.
    static let boundMarginMeters = 100.0

    init(_ photos: [AssetSnapshot]) {
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
        self.ids = order.map { ids[$0] }
        self.times = order.map { times[$0] }
        self.coordinates = order.map { coordinates[$0] }
        self.accuracies = order.map { accuracies[$0] }
        let count = order.count, sorted = self.times, located = self.coordinates

        var groupStarts: [Int] = [], groupOf = [Int](repeating: 0, count: count)
        var steps = [Double](repeating: 0, count: count), pathMeters = steps
        for i in 0..<count {
            if i > 0 {
                steps[i] = GeoMath.distance(located[i - 1], located[i])
                pathMeters[i] = pathMeters[i - 1] + steps[i]
            }
            if let start = groupStarts.last, GeoMath.distance(located[start], located[i]) <= AirborneFilter.groupRadiusMeters {
                groupOf[i] = groupStarts.count - 1
            } else {
                groupStarts.append(i)
                groupOf[i] = groupStarts.count - 1
            }
        }
        self.groupStarts = groupStarts
        self.groupOf = groupOf
        self.steps = steps
        self.pathMeters = pathMeters

        let speed = AirborneFilter.maximumGroundSpeed, window = AirborneFilter.maximumLongLegDuration
        let reach = AirborneFilter.minimumLegMeters + Self.boundMarginMeters
        var windowStart = [Int](repeating: 0, count: count), earliest = [Int](repeating: 0, count: count)
        var start = 0, first = 0
        for i in 0..<count {
            while sorted[i] - sorted[start] > window { start += 1 }
            windowStart[i] = start
            first = max(first, start)
            while first < i && steps[first + 1] <= speed * (sorted[i] - sorted[first]) - reach { first += 1 }
            earliest[i] = first
        }
        var windowEnd = [Int](repeating: 0, count: count), latest = [Int](repeating: 0, count: count)
        var end = count - 1, last = count - 1
        for i in stride(from: count - 1, through: 0, by: -1) {
            while sorted[end] - sorted[i] > window { end -= 1 }
            windowEnd[i] = end
            last = min(last, end)
            while last > i && steps[last] <= speed * (sorted[last] - sorted[i]) - reach { last -= 1 }
            latest[i] = last
        }
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.earliest = earliest
        self.latest = latest
    }

    // MARK: Distances and legs

    /// The distance between two photos, always measured from the earlier one.
    func meters(_ a: Int, _ b: Int) -> Double {
        a <= b ? GeoMath.distance(coordinates[a], coordinates[b]) : GeoMath.distance(coordinates[b], coordinates[a])
    }

    func seconds(_ a: Int, _ b: Int) -> TimeInterval { (times[b] - times[a]).magnitude }

    /// Faster than any ground transport (equal times included, at any distance above zero).
    func fasterThanGround(_ a: Int, _ b: Int) -> Bool { meters(a, b) > AirborneFilter.maximumGroundSpeed * seconds(a, b) }

    /// Flown: faster than ground transport, not faster than a plane.
    func flown(_ a: Int, _ b: Int) -> Bool {
        let meters = meters(a, b), seconds = seconds(a, b)
        return meters > AirborneFilter.maximumGroundSpeed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
    }

    /// `middle` on the way from `from` to `to` (`AirborneFilter.detourFactor`).
    func onTheWay(_ from: Int, _ middle: Int, _ to: Int) -> Bool {
        meters(from, middle) + meters(middle, to) <= AirborneFilter.detourFactor * meters(from, to) + AirborneFilter.detourAllowanceMeters
    }

    // MARK: Judging

    /// Per photo, whether it was taken in flight: `high` (rule 1, by altitude) or rules 2 to 4.
    func inFlight(high: [Bool]) -> [Bool] {
        // Plain local arrays in the loops: a debug build reads a property far slower.
        let times = self.times, earliest = self.earliest, latest = self.latest, count = times.count
        guard count > 0 else { return [] }
        var neighbours = Neighbours(count: count)

        var onRun = [Bool](repeating: false, count: count)
        for i in 0..<count where earliest[i] < i && latest[i] > i {
            onRun[i] = isOnRun(i, neighbours: &neighbours)
        }
        let bursts = Bursts(self), member = bursts.member
        var flags = [Bool](repeating: false, count: count)
        for i in 0..<count where high[i] || onRun[i] || member[i] {
            flags[i] = high[i] || onRun[i] || !comesBack(i)
        }
        let confirmed = flags

        // Rule 4 only within `runEndLongDuration` of a confirmed photo.
        let reach = AirborneFilter.runEndLongDuration
        var near = [Bool](repeating: false, count: count)
        var previous = -1, next = -1
        for i in 0..<count {
            if confirmed[i] { previous = i }
            near[i] = previous >= 0 && times[i] - times[previous] <= reach
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            if confirmed[i] { next = i }
            if next >= 0 && times[next] - times[i] <= reach { near[i] = true }
        }
        for i in 0..<count where !confirmed[i] && near[i] {
            flags[i] = endsRun(i, neighbours: &neighbours, confirmed: confirmed, onRun: onRun, bursts: bursts)
        }
        return flags
    }

    /// Rule 2: both legs flown, on the way, no stay, no turn back.
    func isOnRun(_ i: Int, neighbours: inout Neighbours) -> Bool {
        let before = neighbours.runBefore(i, in: self)
        guard before >= 0, flown(before, i) else { return false }
        let after = neighbours.runAfter(i, in: self)
        guard after >= 0, flown(i, after), onTheWay(before, i, after) else { return false }
        let long = times[i] - times[before] > AirborneFilter.maximumLegDuration || times[after] - times[i] > AirborneFilter.maximumLegDuration
        if stays(i, before: before, after: after, any: long) { return false }
        // A short leg from or to a stay.
        let short = AirborneFilter.runEndLongDuration
        if times[i] - times[before] <= short, staysAt(before, step: -1) { return false }
        if times[after] - times[i] <= short, staysAt(after, step: 1) { return false }
        // Turning back: the leg into the photo before (or out of the photo after) is faster than
        // ground transport and leaves the way.
        let previous = neighbours.fastBefore(before, in: self)
        if previous >= 0, !onTheWay(previous, before, i) { return false }
        let next = neighbours.fastAfter(after, in: self)
        if next >= 0, !onTheWay(i, after, next) { return false }
        return !comesBack(i)
    }

    /// Rule 4: the photo next to a confirmed run, on a short flown leg to it.
    func endsRun(_ i: Int, neighbours: inout Neighbours, confirmed: [Bool], onRun: [Bool], bursts: Bursts) -> Bool {
        for later in [true, false] {
            // The run's side first: its leg is fast, so the bounded search finds it.
            let run = later ? neighbours.runAfter(i, in: self) : neighbours.runBefore(i, in: self)
            if run == Neighbours.staying { return false }
            guard run >= 0, confirmed[run], flown(i, run) else { continue }
            let duration = seconds(i, run)
            guard duration <= AirborneFilter.runEndLongDuration,
                  duration <= AirborneFilter.runEndDuration || meters(i, run) > AirborneFilter.runEndLongSpeed * duration else { continue }
            let other = neighbour(of: i, step: later ? -1 : 1, limit: later ? 0 : times.count - 1, staying: true)
            if other == Neighbours.staying { return false }
            if other >= 0, !(later ? onTheWay(other, i, run) : onTheWay(run, i, other)) { continue }
            // The run goes on in a line beyond that photo: to its own other neighbour, or to the
            // far end of its burst. (A photo confirmed by its altitude alone needs no line.)
            let far = onRun[run] ? (later ? neighbours.runAfter(run, in: self) : neighbours.runBefore(run, in: self))
                : bursts.member[run] ? (later ? bursts.last[run] : bursts.first[run]) : -1
            if far >= 0, far != run, !(later ? onTheWay(i, run, far) : onTheWay(far, run, i)) { continue }
            return !stays(i, before: later ? other : run, after: later ? run : other, any: true) && !comesBack(i)
        }
        return false
    }

    /// Whether the photo at `i` shows a stay: the photos in a row around it closer than
    /// `minimumLegMeters` (between its neighbours `before` and `after`, or as far as
    /// `maximumLongLegDuration` where it has none), when at least two and (unless `any`) lasting at
    /// least `stayDuration`, did not move on along its legs (away from the photo before, towards the
    /// photo after; without either, apart) faster than `maximumGroundSpeed` over their time, nor
    /// further than the stated accuracy of the first and last of them. In a plane such photos lie
    /// under a minute apart and move on at its speed; on the ground they stay within the 6 km the
    /// row can span, however long it lasts. A single photo shows nothing.
    func stays(_ i: Int, before: Int, after: Int, any: Bool) -> Bool {
        let first = before >= 0 ? before + 1 : windowStart[i], last = after >= 0 ? after - 1 : windowEnd[i]
        guard first < last else { return false }
        let span = times[last] - times[first]
        guard any || span >= AirborneFilter.stayDuration else { return false }
        var progress = Double.infinity
        if before >= 0 { progress = min(progress, meters(before, last) - meters(before, first)) }
        if after >= 0 { progress = min(progress, meters(first, after) - meters(last, after)) }
        if before < 0 && after < 0 { progress = meters(first, last) }
        let movedOn = max(AirborneFilter.maximumGroundSpeed * span, accuracies[first] + accuracies[last])
        return progress < movedOn + Self.roundingMarginMeters
    }

    /// Whether the photo at `p` stays on its side `step` (-1 before, 1 after): the photos there
    /// closer than `minimumLegMeters`, up to its neighbour on that side (or as far as
    /// `maximumLongLegDuration` where it has none), reach `stayDuration` from it. A minute and more
    /// of photos within 3 km is a stop, not a plane: one at 400 km/h leaves 3 km behind in 27 s.
    func staysAt(_ p: Int, step: Int) -> Bool {
        neighbour(of: p, step: step, limit: step < 0 ? 0 : times.count - 1, staying: true) == Neighbours.staying
    }

    /// Whether the location comes back to the photo at `i` (`AirborneFilter.returnDuration`): a
    /// photo `stayDuration` to `returnDuration` before or after it lies closer than
    /// `minimumLegMeters`. A photo `d` away is followed by none nearer than `d` less the way
    /// from it, so the search passes such photos with a look at `pathMeters` alone: a flight's
    /// photos, ever further away, cost a handful of distances.
    func comesBack(_ i: Int) -> Bool {
        let time = times[i], near = AirborneFilter.minimumLegMeters, margin = Self.roundingMarginMeters
        let stay = AirborneFilter.stayDuration, window = AirborneFilter.returnDuration
        // After it (from a second early on; the time is checked as the rule states it).
        var k = Self.firstIndex(times, atLeast: time + stay - 1, from: i + 1)
        while k < times.count && times[k] - time <= window {
            let d = meters(i, k)
            if d < near && times[k] - time >= stay { return true }
            k = max(k + 1, Self.firstIndex(pathMeters, atLeast: pathMeters[k] + d - near - margin, from: k + 1))
        }
        // Before it.
        k = Self.firstIndex(times, above: time - stay + 1, below: i) - 1
        while k >= 0 && time - times[k] <= window {
            let d = meters(k, i)
            if d < near && time - times[k] >= stay { return true }
            k = min(k - 1, Self.firstIndex(pathMeters, above: pathMeters[k] - (d - near - margin), below: k) - 1)
        }
        return false
    }

    /// The first index from `low` on (the array's end if none) whose value is at least `value`,
    /// in an ascending array.
    static func firstIndex(_ values: [Double], atLeast value: Double, from low: Int) -> Int {
        var low = low, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The first index below `end` (`end` if none) whose value is above `value`, in an ascending
    /// array.
    static func firstIndex(_ values: [Double], above value: Double, below end: Int) -> Int {
        var low = 0, high = end
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Neighbours

    /// The nearest photo before (`step` -1) or after (`step` 1) the photo at `i` that is at least
    /// `minimumLegMeters` from it and at most `maximumLongLegDuration` apart in time, or -1; -1 too
    /// once the search would pass `limit` (a photo index). With `staying`, `Neighbours.staying`
    /// once it passes a photo closer than `minimumLegMeters` that is `stayDuration` or more from
    /// it: the photos in a row around it then make a stay of that length (`stays`).
    ///
    /// Read group by group: the photos of the photo's own group are all closer than a leg; a
    /// group whose first photo is far enough clear of `minimumLegMeters` is passed or taken whole
    /// (each of its photos lies within `groupRadiusMeters` of its first); only a group straddling
    /// the leg length is read photo by photo. The time bound ends the search.
    func neighbour(of i: Int, step: Int, limit: Int, staying: Bool) -> Int {
        let time = times[i]
        let minimum = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration
        let radius = AirborneFilter.groupRadiusMeters, margin = Self.roundingMarginMeters
        let stay = staying ? AirborneFilter.stayDuration : .infinity
        func groupEnd(_ group: Int) -> Int { group + 1 < groupStarts.count ? groupStarts[group + 1] - 1 : times.count - 1 }
        // Whether a group's photos on this side within the window reach `stay` from the photo.
        func reachesStay(_ group: Int) -> Bool {
            let edge = step < 0 ? max(groupStarts[group], windowStart[i]) : min(groupEnd(group), windowEnd[i])
            return (times[edge] - time).magnitude >= stay
        }
        if reachesStay(groupOf[i]) { return Neighbours.staying }
        var group = groupOf[i] + step
        while group >= 0 && group < groupStarts.count {
            let first = groupStarts[group], last = groupEnd(group)
            let nearest = step < 0 ? last : first
            if step < 0 ? nearest < limit : nearest > limit { return -1 }
            guard (times[nearest] - time).magnitude <= window else { return -1 }
            let anchor = meters(first, i)
            if anchor + radius + margin < minimum {
                if reachesStay(group) { return Neighbours.staying }
                group += step
                continue
            }
            if anchor - radius - margin >= minimum { return nearest }
            // Straddling: its photos one by one, nearest in time first.
            var j = nearest
            while j >= first && j <= last {
                if step < 0 ? j < limit : j > limit { return -1 }
                guard (times[j] - time).magnitude <= window else { return -1 }
                if meters(j, i) >= minimum { return j }
                if (times[j] - time).magnitude >= stay { return Neighbours.staying }
                j += step
            }
            group += step
        }
        return -1
    }

    /// The searches done so far, so no photo is searched twice (`unknown`: not yet).
    struct Neighbours {
        static let unknown = -2
        static let staying = -3

        /// For rules 2 and 4: the neighbour, if a leg to it can be faster than ground transport
        /// (else -1), or `staying`.
        private var runEarlier: [Int]
        private var runLater: [Int]
        /// For the turn back: the neighbour, if the leg to it is faster than ground transport
        /// (else -1).
        private var fastEarlier: [Int]
        private var fastLater: [Int]

        init(count: Int) {
            runEarlier = [Int](repeating: Self.unknown, count: count)
            runLater = runEarlier
            fastEarlier = runEarlier
            fastLater = runEarlier
        }

        mutating func runBefore(_ i: Int, in track: FlightTrack) -> Int {
            if runEarlier[i] == Self.unknown { runEarlier[i] = track.neighbour(of: i, step: -1, limit: track.earliest[i], staying: true) }
            return runEarlier[i]
        }

        mutating func runAfter(_ i: Int, in track: FlightTrack) -> Int {
            if runLater[i] == Self.unknown { runLater[i] = track.neighbour(of: i, step: 1, limit: track.latest[i], staying: true) }
            return runLater[i]
        }

        mutating func fastBefore(_ i: Int, in track: FlightTrack) -> Int {
            if fastEarlier[i] == Self.unknown {
                var j = runEarlier[i]
                if j == Self.unknown || j == Self.staying { j = track.neighbour(of: i, step: -1, limit: track.earliest[i], staying: false) }
                fastEarlier[i] = j >= 0 && track.fasterThanGround(j, i) ? j : -1
            }
            return fastEarlier[i]
        }

        mutating func fastAfter(_ i: Int, in track: FlightTrack) -> Int {
            if fastLater[i] == Self.unknown {
                var j = runLater[i]
                if j == Self.unknown || j == Self.staying { j = track.neighbour(of: i, step: 1, limit: track.latest[i], staying: false) }
                fastLater[i] = j >= 0 && track.fasterThanGround(i, j) ? j : -1
            }
            return fastLater[i]
        }
    }

    // MARK: Bursts

    /// Rule 3: the photos in a burst, and for each the first and last photo of its burst (bursts
    /// sharing a photo are one), -1 elsewhere.
    struct Bursts {
        var member: [Bool]
        var first: [Int]
        var last: [Int]

        init(_ track: FlightTrack) {
            let times = track.times, steps = track.steps, accuracies = track.accuracies, count = times.count
            member = [Bool](repeating: false, count: count)
            first = [Int](repeating: -1, count: count)
            last = [Int](repeating: -1, count: count)
            let size = AirborneFilter.burstPhotos - 1
            var chain = (start: -1, end: -1)
            func close() {
                guard chain.start >= 0 else { return }
                for p in chain.start...chain.end {
                    member[p] = true
                    first[p] = chain.start
                    last[p] = chain.end
                }
            }
            // `streak`: how many steps in a row up to photo `k` fly (seconds apart, long enough, at
            // the speed of a plane).
            var streak = 0
            for k in 1..<max(1, count) {
                let seconds = times[k] - times[k - 1], meters = steps[k]
                let flies = seconds > 0 && seconds <= AirborneFilter.burstStepDuration
                    && meters >= max(AirborneFilter.burstStepMeters, accuracies[k - 1] + accuracies[k])
                    && meters > AirborneFilter.burstSpeed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
                streak = flies ? streak + 1 : 0
                guard streak >= size else { continue }
                let start = k - size
                var slowest = Double.infinity, fastest = 0.0, path = 0.0
                for m in (start + 1)...k {
                    let speed = steps[m] / (times[m] - times[m - 1])
                    slowest = min(slowest, speed)
                    fastest = max(fastest, speed)
                    path += steps[m]
                }
                guard fastest <= AirborneFilter.burstSpeedRatio * slowest,
                      path <= AirborneFilter.burstStraightness * track.meters(start, k) else { continue }
                if chain.start >= 0 && start <= chain.end {
                    chain.end = k
                } else {
                    close()
                    chain = (start, k)
                }
            }
            close()
        }
    }
}
