import Foundation
import AlbumistCore

// The rules of `AirborneFilter` on a `FlightTrack`: which photos were taken in flight (rules 1 to
// 4) and which maybe were, and the stays, bursts heading on and returns they look for. Apart from
// the track itself, so each part of the filter can be read on its own.

extension FlightTrack {
    // MARK: Judging

    /// Per photo, whether it was taken in flight: `high` (rule 1, by altitude) or rules 2 to 4;
    /// `aloft`: whether its stored altitude is above `AirborneFilter.aloftAltitude` (rule 3).
    func inFlight(high: [Bool], aloft: [Bool]) -> [Bool] {
        judge(high: high, aloft: aloft, maybe: false).inFlight
    }

    /// As `inFlight`, and with `maybe`, per photo not taken in flight whether it maybe was
    /// (`FlightJudgement`; empty without).
    func judge(high: [Bool], aloft: [Bool], maybe withMaybe: Bool) -> (inFlight: [Bool], maybe: [Bool]) {
        // Plain local arrays in the loops: a debug build reads a property far slower.
        let earliest = self.earliest, latest = self.latest, count = times.count
        guard count > 0 else { return ([], []) }
        var neighbours = Neighbours(count: count)

        var onRun = [Bool](repeating: false, count: count)
        for i in 0..<count where earliest[i] < i && latest[i] > i {
            onRun[i] = isOnRun(i, neighbours: &neighbours)
        }
        let bursts = headingBursts(aloft: aloft)
        let member = bursts.member
        var flags = [Bool](repeating: false, count: count)
        for i in 0..<count where high[i] || onRun[i] || member[i] {
            flags[i] = high[i] || onRun[i] || !comesBack(i)
        }
        let confirmed = flags

        // Rule 4 only within `runEndLongDuration` of a confirmed photo.
        let near = nearConfirmed(confirmed)
        for i in 0..<count where !confirmed[i] && near[i] {
            flags[i] = endsRun(i, neighbours: &neighbours, confirmed: confirmed, onRun: onRun, bursts: bursts)
        }
        guard withMaybe else { return (flags, []) }

        // Maybe in flight: a photo with a leg faster than ground transport on one side at least.
        var maybe = [Bool](repeating: false, count: count)
        for i in 0..<count where !flags[i] && (earliest[i] < i || latest[i] > i) {
            maybe[i] = mayBeInFlight(i, neighbours: &neighbours)
        }
        return (flags, maybe)
    }

    /// Rule 3's bursts (`Bursts`), less those that neither hold four moments moving steadily and
    /// straight on nor head on (`headsOn`).
    private func headingBursts(aloft: [Bool]) -> Bursts {
        let count = times.count
        var bursts = Bursts(self, aloft: aloft)
        var start = 0
        while start < count {
            let end = bursts.last[start]
            guard end >= 0 else {
                start += 1
                continue
            }
            if !bursts.holdsFour[start] && !headsOn(start, end) { bursts.drop(start, end) }
            start = end + 1
        }
        return bursts
    }

    /// Per photo, whether it lies within `AirborneFilter.runEndLongDuration` of a confirmed photo,
    /// before or after it (rule 4 judges only those).
    private func nearConfirmed(_ confirmed: [Bool]) -> [Bool] {
        // Plain local arrays in the loops: a debug build reads a property far slower.
        let times = self.times, count = times.count
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
        return near
    }

    /// Rule 2: both legs flown, on the way, no stay, no turn back.
    func isOnRun(_ i: Int, neighbours: inout Neighbours) -> Bool {
        let before = neighbours.runBefore(i, in: self)
        guard before >= 0, flown(before, i) else { return false }
        let after = neighbours.runAfter(i, in: self)
        guard after >= 0, flown(i, after), onTheWay(before, i, after) else { return false }
        if stays(i, before: before, after: after, landing: true) { return false }
        // A short leg from or to a stay.
        let short = AirborneFilter.runEndLongDuration
        if times[i] - times[before] <= short, staysAt(before, step: -1) { return false }
        if times[after] - times[i] <= short, staysAt(after, step: 1) { return false }
        // Turning back: the leg into the photo before (or out of the photo after) is faster than
        // `turnBackSpeed` and leaves the way.
        if turnsBack(i, before: before, after: after, neighbours: &neighbours) { return false }
        return !comesBack(i)
    }

    /// Whether a run turns back at the photo at `i` between its neighbours `before` and `after`
    /// (either -1 where it has none, and then not on that side): the leg into the photo before (or
    /// out of the photo after) is faster than `AirborneFilter.turnBackSpeed` and leaves the way.
    /// Rule 2 and the maybe share it.
    private func turnsBack(_ i: Int, before: Int, after: Int, neighbours: inout Neighbours) -> Bool {
        if before >= 0 {
            let previous = neighbours.turnBefore(before, in: self)
            if previous >= 0, !onTheWay(previous, before, i) { return true }
        }
        if after >= 0 {
            let next = neighbours.turnAfter(after, in: self)
            if next >= 0, !onTheWay(i, after, next) { return true }
        }
        return false
    }

    /// Whether the photo at `i`, not taken in flight, maybe was (`FlightJudgement`): exactly one
    /// of its legs was flown, no short one to a stay, and rule 2's conditions hold with that leg:
    /// on the way, no stay (one moving on slower than `AirborneFilter.stayMovingSpeed`), no turn
    /// back, no coming back.
    func mayBeInFlight(_ i: Int, neighbours: inout Neighbours) -> Bool {
        var before = neighbours.runBefore(i, in: self), after = neighbours.runAfter(i, in: self)
        if before == Neighbours.staying || after == Neighbours.staying { return false }
        let short = AirborneFilter.runEndLongDuration
        let flownBefore = before >= 0 && flown(before, i) && !(times[i] - times[before] <= short && staysAt(before, step: -1))
        let flownAfter = after >= 0 && flown(i, after) && !(times[after] - times[i] <= short && staysAt(after, step: 1))
        // Both legs flown: rule 2 has judged it.
        guard flownBefore != flownAfter else { return false }
        // The other leg's neighbour wherever it is (the bounded search stops where no leg to one
        // can be faster than ground transport).
        if before < 0 { before = neighbour(of: i, step: -1, limit: 0, staying: true) }
        if after < 0 { after = neighbour(of: i, step: 1, limit: times.count - 1, staying: true) }
        if before == Neighbours.staying || after == Neighbours.staying { return false }
        if before >= 0, after >= 0, !onTheWay(before, i, after) { return false }
        if stays(i, before: before, after: after, movingSpeed: AirborneFilter.stayMovingSpeed) { return false }
        if turnsBack(i, before: before, after: after, neighbours: &neighbours) { return false }
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
            // The flown leg to the run vouches for the plane: a row shows a stay only when it
            // moved on slower than `stayMovingSpeed` (final approach, right after take-off).
            return !stays(i, before: later ? other : run, after: later ? run : other, movingSpeed: AirborneFilter.stayMovingSpeed)
                && !comesBack(i)
        }
        return false
    }

    /// Whether the photo at `i` shows a stay: the photos in a row around it closer than
    /// `minimumLegMeters` (between its neighbours `before` and `after`, or as far as
    /// `maximumLongLegDuration` where it has none; photos out of reach between them, which the
    /// neighbours' search passes, are someone else's and left out), when they last at least
    /// `AirborneFilter.shortestStay`, did not move on along its legs (away from the photo before,
    /// towards the photo after; without either, apart) faster than `movingSpeed` over their time
    /// (`maximumGroundSpeed`; `AirborneFilter.stayMovingSpeed` next to a single flown leg), nor
    /// further than the stated accuracy of the first and last of them. In a plane such photos lie
    /// under a minute apart and move on at its speed; on the ground they stay within the 6 km the
    /// row can span, however long it lasts. A single photo shows nothing, nor do photos within
    /// `AirborneFilter.shortestStay`, whose fixes may lag a second's flight behind them. With
    /// `landing` (rule 2), a row on one fix lasting under `stayDuration` on either side of the
    /// photo shows none either where a plane could not have landed after the leg before it, or
    /// taken off before the leg after it (`AirborneFilter.landingDuration`).
    func stays(_ i: Int, before: Int, after: Int, movingSpeed: Double = AirborneFilter.maximumGroundSpeed, landing: Bool = false) -> Bool {
        var first = before >= 0 ? before + 1 : windowStart[i], last = after >= 0 ? after - 1 : windowEnd[i]
        while first < i && meters(first, i) >= AirborneFilter.minimumLegMeters { first += 1 }
        while last > i && meters(i, last) >= AirborneFilter.minimumLegMeters { last -= 1 }
        guard first < last else { return false }
        let span = times[last] - times[first]
        guard span >= AirborneFilter.shortestStay else { return false }
        if landing && coordinates[first] == coordinates[last]
            && times[i] - times[first] < AirborneFilter.stayDuration && times[last] - times[i] < AirborneFilter.stayDuration
            && ((before >= 0 && !leavesTimeToLand(before, first)) || (after >= 0 && !leavesTimeToLand(last, after))) { return false }
        var progress = Double.infinity
        if before >= 0 { progress = min(progress, meters(before, last) - meters(before, first)) }
        if after >= 0 { progress = min(progress, meters(first, after) - meters(last, after)) }
        if before < 0 && after < 0 { progress = meters(first, last) }
        let movedOn = max(movingSpeed * span, accuracies[first] + accuracies[last])
        return progress < movedOn + Self.roundingMarginMeters
    }

    /// Whether the photo at `p` stays on its side `step` (-1 before, 1 after): the photos there
    /// closer than `minimumLegMeters`, up to its neighbour on that side (or as far as
    /// `maximumLongLegDuration` where it has none), reach `stayDuration` from it. A minute and more
    /// of photos within 3 km is a stop, not a plane: one at 400 km/h leaves 3 km behind in 27 s.
    func staysAt(_ p: Int, step: Int) -> Bool {
        neighbour(of: p, step: step, limit: step < 0 ? 0 : times.count - 1, staying: true) == Neighbours.staying
    }

    /// Rule 3: whether the burst from `start` to `end` heads on. Its legs go to the nearest photo
    /// before its first photo and the nearest after its last that are at least `minimumLegMeters`
    /// from them and at most `maximumLongLegDuration` apart: it needs one, and its way away from
    /// the photo before and towards the photo after must each be at least
    /// `AirborneFilter.burstHeading` of its length. A minute of fixes near its first photo before
    /// it, or near its last after it (`Neighbours.staying`, by `fixTimes`), is a stay, never a
    /// plane's; a photo a minute later on its last fix is none (a fix frozen in the cabin).
    func headsOn(_ start: Int, _ end: Int) -> Bool {
        let before = neighbour(of: start, step: -1, limit: 0, staying: true, byFix: true)
        guard before != Neighbours.staying else { return false }
        let after = neighbour(of: end, step: 1, limit: times.count - 1, staying: true, byFix: true)
        guard after != Neighbours.staying, before >= 0 || after >= 0 else { return false }
        let way = AirborneFilter.burstHeading * meters(start, end)
        if before >= 0 && meters(before, end) - meters(before, start) < way { return false }
        if after >= 0 && meters(start, after) - meters(end, after) < way { return false }
        return true
    }

    /// Whether the location comes back to the photo at `i` (`AirborneFilter.returnDuration`): a
    /// photo whose fix was taken `stayDuration` to `returnDuration` before or after the photo's
    /// own (`fixTimes`) lies closer than `minimumLegMeters`. A photo that repeats a fix taken
    /// within a minute of the photo's is no return: the iPhone did not update the location. A
    /// photo `d` away is followed by none nearer than `d` less the way from it, so the search
    /// passes such photos with a look at `pathMeters` alone: a flight's photos, ever further away,
    /// cost a handful of distances.
    func comesBack(_ i: Int) -> Bool {
        let fixTimes = self.fixTimes, time = fixTimes[i], near = AirborneFilter.minimumLegMeters, margin = Self.roundingMarginMeters
        let stay = AirborneFilter.stayDuration, window = AirborneFilter.returnDuration
        // After it (from a second early on; the time is checked as the rule states it).
        var k = Self.firstIndex(fixTimes, atLeast: time + stay - 1, from: i + 1)
        while k < fixTimes.count && fixTimes[k] - time <= window {
            let d = meters(i, k)
            if d < near && fixTimes[k] - time >= stay { return true }
            k = max(k + 1, Self.firstIndex(pathMeters, atLeast: pathMeters[k] + d - near - margin, from: k + 1))
        }
        // Before it.
        k = Self.firstIndex(fixTimes, above: time - stay + 1, below: i) - 1
        while k >= 0 && time - fixTimes[k] <= window {
            let d = meters(k, i)
            if d < near && time - fixTimes[k] >= stay { return true }
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
}
