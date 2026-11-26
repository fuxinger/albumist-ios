import Foundation
import AlbumistCore

// The search for a photo's neighbours on a `FlightTrack` (the nearest photo before or after it
// that a leg goes to) and the searches done so far (`Neighbours`), which rules 2 to 4 of
// `AirborneFilter` build on.

extension FlightTrack {
    /// The nearest photo before (`step` -1) or after (`step` 1) the photo at `i` that is at least
    /// `minimumLegMeters` from it, at most `maximumLongLegDuration` apart in time and not **out of
    /// reach** (`AirborneFilter.jumpMeters`), or -1; -1 too once the search would pass `limit` (a
    /// photo index) before it has passed a photo out of reach. With `staying`,
    /// `Neighbours.staying` once it passes a photo closer than `minimumLegMeters` that is
    /// `stayDuration` or more from it (with `byFix`, by `fixTimes`): the photos in a row around it
    /// then make a stay of that length (`stays`).
    ///
    /// A photo out of reach is someone else's (an iCloud Shared Library: someone at home while the
    /// other flies) or a wrong location far off. It says nothing about this photo's way, so the
    /// search passes it, as the trip's route does. Taken as the neighbour, the photos at home hid
    /// the window photos between them: their legs were no flight (faster than a plane, or there
    /// and back), and a series did not head on towards a photo at home behind the plane. `limit`
    /// holds until the search has passed such a photo (see `earliest`); from there on it is lifted.
    ///
    /// Read group by group: the photos of the photo's own group are all closer than a leg; a
    /// group whose first photo is far enough clear of `minimumLegMeters` is passed or taken whole
    /// (each of its photos lies within `groupRadiusMeters` of its first), and so is a group far
    /// enough from it whose photos are all within reach or all out of it; any other group is read
    /// photo by photo (`photoByPhoto`). The time bound ends the search.
    func neighbour(of i: Int, step: Int, limit: Int, staying: Bool, byFix: Bool = false) -> Int {
        let minimum = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration
        let radius = AirborneFilter.groupRadiusMeters, margin = Self.roundingMarginMeters
        let speed = AirborneFilter.maximumFlightSpeed, jump = AirborneFilter.jumpMeters
        let stamps = byFix ? fixTimes : times
        var search = NeighbourSearch(photo: i, step: step, time: times[i], stamp: stamps[i],
                                     stay: staying ? AirborneFilter.stayDuration : .infinity, limit: limit,
                                     unbounded: step < 0 ? 0 : times.count - 1)
        let time = search.time
        if reachesStay(groupOf[i], search, stamps: stamps) { return Neighbours.staying }
        var group = groupOf[i] + step
        while group >= 0 && group < groupStarts.count {
            let first = groupStarts[group], last = groupEnd(group)
            let nearest = step < 0 ? last : first
            if search.isPastLimit(nearest) { return -1 }
            guard (times[nearest] - time).magnitude <= window else { return -1 }
            let anchor = meters(first, i)
            if anchor + radius + margin < minimum {
                if reachesStay(group, search, stamps: stamps) { return Neighbours.staying }
                group += step
                continue
            }
            if anchor - radius - margin >= minimum {
                // All far enough: the nearest in time if surely within reach; passed whole if all
                // its photos within the window are surely out of reach.
                if anchor + radius + margin <= speed * (times[nearest] - time).magnitude + jump { return nearest }
                let farthest = step < 0 ? max(first, windowStart[i]) : min(last, windowEnd[i])
                if anchor - radius - margin > speed * (times[farthest] - time).magnitude + jump {
                    search.liftLimit()
                    group += step
                    continue
                }
            }
            if let found = photoByPhoto(from: first, to: last, stamps: stamps, search: &search) { return found }
            group += step
        }
        return -1
    }

    /// One search of `neighbour(of:step:limit:staying:byFix:)`: the photo and the side it searches,
    /// how long a stay lasts and from when, and the limit it holds to. Plain values only, so a
    /// debug build copies it cheaply.
    private struct NeighbourSearch {
        let photo: Int
        /// -1 before the photo, 1 after it.
        let step: Int
        let time: TimeInterval
        /// The photo's own time in the times a stay is measured by (`fixTimes` with `byFix`, else
        /// `times`).
        let stamp: TimeInterval
        /// `stayDuration` with `staying`, else never.
        let stay: TimeInterval
        /// The photo index the search goes no further than, until it has passed a photo out of
        /// reach; from there on the end of the track on its side (`unbounded`).
        var limit: Int
        let unbounded: Int

        /// Whether the photo at `index` lies beyond the limit on the search's side.
        func isPastLimit(_ index: Int) -> Bool { step < 0 ? index < limit : index > limit }

        /// The search has passed a photo out of reach: the limit holds no more.
        mutating func liftLimit() { limit = unbounded }
    }

    /// The last photo of a group.
    private func groupEnd(_ group: Int) -> Int { group + 1 < groupStarts.count ? groupStarts[group + 1] - 1 : times.count - 1 }

    /// Whether a group's photos on the search's side within the window reach the search's `stay`
    /// from the photo, by `stamps` (which rise with the index, as `times` do).
    private func reachesStay(_ group: Int, _ search: NeighbourSearch, stamps: [TimeInterval]) -> Bool {
        let i = search.photo
        let edge = search.step < 0 ? max(groupStarts[group], windowStart[i]) : min(groupEnd(group), windowEnd[i])
        return (stamps[edge] - search.stamp).magnitude >= search.stay
    }

    /// The photos of the group from `first` to `last` one by one, nearest in time first: the
    /// first at least `minimumLegMeters` from the photo and within reach is the neighbour; one
    /// closer than that and `stay` or more from it by `stamps` makes a stay; one out of reach lifts
    /// the limit. -1 past the limit or the time bound; nil when the group decides nothing.
    private func photoByPhoto(from first: Int, to last: Int, stamps: [TimeInterval], search: inout NeighbourSearch) -> Int? {
        let minimum = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration
        let speed = AirborneFilter.maximumFlightSpeed, jump = AirborneFilter.jumpMeters
        let i = search.photo, step = search.step, time = search.time, stamp = search.stamp, stay = search.stay
        var j = step < 0 ? last : first
        while j >= first && j <= last {
            if search.isPastLimit(j) { return -1 }
            let seconds = (times[j] - time).magnitude
            guard seconds <= window else { return -1 }
            let meters = meters(j, i)
            if meters >= minimum {
                if meters <= speed * seconds + jump { return j }
                search.liftLimit()
            } else if (stamps[j] - stamp).magnitude >= stay {
                return Neighbours.staying
            }
            j += step
        }
        return nil
    }

    /// The searches done so far, so no photo is searched twice (`unknown`: not yet).
    struct Neighbours {
        static let unknown = -2
        static let staying = -3

        /// For rules 2 and 4: the neighbour, if a leg to it can be faster than ground transport
        /// (else -1), or `staying`.
        private var runEarlier: [Int]
        private var runLater: [Int]
        /// For the turn back: the neighbour, if the leg to it is faster than
        /// `AirborneFilter.turnBackSpeed` (else -1).
        private var turnEarlier: [Int]
        private var turnLater: [Int]

        init(count: Int) {
            runEarlier = [Int](repeating: Self.unknown, count: count)
            runLater = runEarlier
            turnEarlier = runEarlier
            turnLater = runEarlier
        }

        mutating func runBefore(_ i: Int, in track: FlightTrack) -> Int {
            if runEarlier[i] == Self.unknown { runEarlier[i] = track.neighbour(of: i, step: -1, limit: track.earliest[i], staying: true) }
            return runEarlier[i]
        }

        mutating func runAfter(_ i: Int, in track: FlightTrack) -> Int {
            if runLater[i] == Self.unknown { runLater[i] = track.neighbour(of: i, step: 1, limit: track.latest[i], staying: true) }
            return runLater[i]
        }

        /// The search for a run's neighbour is bounded for legs faster than ground transport, so
        /// only a neighbour it found is the turn back's too.
        mutating func turnBefore(_ i: Int, in track: FlightTrack) -> Int {
            if turnEarlier[i] == Self.unknown {
                var j = runEarlier[i]
                if j < 0 { j = track.neighbour(of: i, step: -1, limit: track.turnEarliest[i], staying: false) }
                turnEarlier[i] = j >= 0 && track.fasterThanTurnBack(j, i) ? j : -1
            }
            return turnEarlier[i]
        }

        mutating func turnAfter(_ i: Int, in track: FlightTrack) -> Int {
            if turnLater[i] == Self.unknown {
                var j = runLater[i]
                if j < 0 { j = track.neighbour(of: i, step: 1, limit: track.turnLatest[i], staying: false) }
                turnLater[i] = j >= 0 && track.fasterThanTurnBack(i, j) ? j : -1
            }
            return turnLater[i]
        }
    }
}
