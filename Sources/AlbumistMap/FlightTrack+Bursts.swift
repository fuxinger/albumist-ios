import Foundation
import AlbumistCore

// Rule 3 of `AirborneFilter` on a `FlightTrack`: bursts, moments at most a minute apart that move
// on steadily and straight on at a plane's speed. In a file of its own, as it reads the track by
// moments rather than by legs.

extension FlightTrack {
    // MARK: Bursts

    /// Rule 3: the photos in a burst, and for each the first and last photo of its burst (bursts
    /// sharing a moment are one) and whether its burst holds four moments in a row that move
    /// steadily and straight on over all four; -1 and false elsewhere.
    struct Bursts {
        var member: [Bool]
        var first: [Int]
        var last: [Int]
        var holdsFour: [Bool]

        /// `aloft`: per photo, whether its stored altitude is above `AirborneFilter.aloftAltitude`.
        init(_ track: FlightTrack, aloft: [Bool]) {
            let times = track.times, accuracies = track.accuracies, count = times.count
            member = [Bool](repeating: false, count: count)
            first = [Int](repeating: -1, count: count)
            last = [Int](repeating: -1, count: count)
            holdsFour = member
            let moments = Self.moments(of: track)
            func momentEnd(_ m: Int) -> Int { m + 1 < moments.count ? moments[m + 1] - 1 : count - 1 }
            var steps = [Double](repeating: 0, count: moments.count)
            // A chain of moments, from `start` to `end`.
            var chain = (start: -1, end: -1, four: false)
            func close() {
                guard chain.start >= 0 else { return }
                mark(moments[chain.start], momentEnd(chain.end), four: chain.four)
            }
            // `streak`: how many steps in a row up to moment `m` fly (seconds apart, long enough,
            // at the speed of a plane).
            var streak = 0
            for m in 1..<max(1, moments.count) {
                let a = moments[m - 1], b = moments[m]
                let seconds = times[b] - times[a], meters = track.meters(a, b)
                steps[m] = meters
                let speed = aloft[a] && aloft[b] ? AirborneFilter.aloftBurstSpeed : AirborneFilter.burstSpeed
                let flies = seconds > 0 && seconds <= AirborneFilter.burstStepDuration
                    && meters >= max(AirborneFilter.burstStepMeters, accuracies[a] + accuracies[b])
                    && meters > speed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
                streak = flies ? streak + 1 : 0
                guard streak >= AirborneFilter.burstPhotos - 1 else { continue }
                // The four moments up to `m`, else the three.
                let four = streak >= 3 && Self.steady(m - 3, m, moments: moments, steps: steps, track: track)
                let start = four ? m - 3 : m - AirborneFilter.burstPhotos + 1
                guard four || Self.steady(start, m, moments: moments, steps: steps, track: track) else { continue }
                if chain.start >= 0 && start <= chain.end {
                    chain.end = m
                    chain.four = chain.four || four
                } else {
                    close()
                    chain = (start, m, four)
                }
            }
            close()
        }

        /// The moments (`AirborneFilter.sampleDuration`), by their first photos; a step goes from
        /// one moment's first photo to the next one's.
        private static func moments(of track: FlightTrack) -> [Int] {
            let times = track.times, coordinates = track.coordinates, accuracies = track.accuracies
            var moments: [Int] = []
            for k in 0..<times.count {
                if let m = moments.last {
                    if coordinates[k] == coordinates[k - 1] { continue }
                    let seconds = times[k] - times[m], meters = track.meters(m, k)
                    let step = meters >= max(AirborneFilter.burstStepMeters, accuracies[m] + accuracies[k])
                        && meters <= AirborneFilter.maximumFlightSpeed * seconds
                    if seconds <= AirborneFilter.sampleDuration && !step { continue }
                }
                moments.append(k)
            }
            return moments
        }

        /// Whether the steps from moment `start` to moment `end` are steady and straight on:
        /// `steps[m]` goes from moment `m - 1` to moment `m`.
        private static func steady(_ start: Int, _ end: Int, moments: [Int], steps: [Double], track: FlightTrack) -> Bool {
            let times = track.times
            var slowest = Double.infinity, fastest = 0.0, path = 0.0
            for m in (start + 1)...end {
                let speed = steps[m] / (times[moments[m]] - times[moments[m - 1]])
                slowest = min(slowest, speed)
                fastest = max(fastest, speed)
                path += steps[m]
            }
            return fastest <= AirborneFilter.burstSpeedRatio * slowest
                && path <= AirborneFilter.burstStraightness * track.meters(moments[start], moments[end])
        }

        /// Puts the photos from `from` to `to` in one burst.
        private mutating func mark(_ from: Int, _ to: Int, four: Bool) {
            for p in from...to {
                member[p] = true
                first[p] = from
                last[p] = to
                holdsFour[p] = four
            }
        }

        /// Takes the burst from `start` to `end` out.
        mutating func drop(_ start: Int, _ end: Int) {
            for p in start...end {
                member[p] = false
                first[p] = -1
                last[p] = -1
                holdsFour[p] = false
            }
        }
    }
}
