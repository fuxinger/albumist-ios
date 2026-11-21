import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// The rules as `AirborneFilter` states them, photo by photo (`reference`): every neighbour by a
/// plain search, no groups, no bounds, no kept results; what it finds, rule by rule.
extension AirborneFilterTests {
    // MARK: The fast search is the rule, photo by photo

    /// What the reference found, rule by rule, and the photos maybe taken in flight
    /// (`FlightJudgement`).
    struct Judged {
        var all = Set<AssetID>()
        var byRule = [Set<AssetID>](repeating: [], count: 4)
        var maybe = Set<AssetID>()
    }

    /// The rules as `AirborneFilter` states them, photo by photo: every neighbour by a plain search,
    /// no groups, no bounds, no kept results.
    static func reference(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> Judged {
        Reference(photos, altitudes: altitudes).judge()
    }

    /// Steady moments in a row of `Reference` (rule 3), chained where they share a moment: the
    /// first and the last moment, and whether four of them in a row move steadily.
    struct MomentChain {
        var first: Int
        var last: Int
        var four: Bool
    }

    /// The bursts `Reference` found (rule 3): whether each photo is in one, and that burst's first
    /// and last photo (-1 when none).
    struct Bursts {
        var burst: [Bool]
        var first: [Int]
        var last: [Int]
    }

    /// The photos `reference` judges, in time order, with their times, fixes and stated accuracies
    /// (0 when none), and the rules over them, photo by photo.
    struct Reference {
        let judged: [AssetSnapshot]
        let n: Int
        let t: [Double], c: [GeoCoordinate], accuracy: [Double]
        let leg = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration, stay = AirborneFilter.stayDuration
        let ground = AirborneFilter.maximumGroundSpeed, plane = AirborneFilter.maximumFlightSpeed
        /// When each photo's fix was taken: its own time, or that of the first photo on its fix.
        let fixTime: [Double]
        /// Above `maximumAltitude` (rule 1), and above `aloftAltitude`, where rule 3 takes faster steps.
        let high: [Bool], aloft: [Bool]
        /// The first photo of each moment of rule 3.
        var moments: [Int] = []

        init(_ photos: [AssetSnapshot], altitudes: [AssetID: Double]) {
            judged = photos.filter { $0.usableLocation != nil && $0.creationDate != nil && !$0.isScreenshotLike }.sorted { a, b in
                (a.creationDate!, a.id.rawValue, a.location!.latitude, a.location!.longitude)
                    < (b.creationDate!, b.id.rawValue, b.location!.latitude, b.location!.longitude)
            }
            n = judged.count
            t = judged.map { $0.creationDate!.timeIntervalSinceReferenceDate }
            c = judged.map { $0.location! }
            accuracy = judged.map { $0.locationAccuracy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
            // A photo on exactly the fix of the photo before repeats it: the fix is as old as the first
            // photo of the row.
            var fixTime = t
            for k in 0..<n where k > 0 && c[k] == c[k - 1] { fixTime[k] = fixTime[k - 1] }
            self.fixTime = fixTime
            high = judged.map { photo in altitudes[photo.id].map { $0 > AirborneFilter.maximumAltitude } ?? false }
            aloft = judged.map { photo in altitudes[photo.id].map { $0 > AirborneFilter.aloftAltitude } ?? false }
            moments = momentStarts()
        }

        func meters(_ a: Int, _ b: Int) -> Double { a <= b ? GeoMath.distance(c[a], c[b]) : GeoMath.distance(c[b], c[a]) }
        func fast(_ a: Int, _ b: Int) -> Bool { meters(a, b) > ground * abs(t[b] - t[a]) }
        func turning(_ a: Int, _ b: Int) -> Bool { meters(a, b) > AirborneFilter.turnBackSpeed * abs(t[b] - t[a]) }
        func flown(_ a: Int, _ b: Int) -> Bool { fast(a, b) && meters(a, b) <= plane * abs(t[b] - t[a]) }
        func onTheWay(_ a: Int, _ m: Int, _ b: Int) -> Bool {
            meters(a, m) + meters(m, b) <= AirborneFilter.detourFactor * meters(a, b) + AirborneFilter.detourAllowanceMeters
        }
        // A photo out of reach is someone else's: passed.
        func reachable(_ a: Int, _ b: Int) -> Bool { meters(a, b) <= plane * abs(t[b] - t[a]) + AirborneFilter.jumpMeters }
        func neighbour(_ i: Int, _ step: Int) -> Int? {
            var j = i + step
            while j >= 0 && j < n && abs(t[j] - t[i]) <= window {
                if meters(j, i) >= leg && reachable(j, i) { return j }
                j += step
            }
            return nil
        }
        func edge(_ i: Int, _ step: Int) -> Int {
            var j = i
            while j + step >= 0 && j + step < n && abs(t[j + step] - t[i]) <= window { j += step }
            return j
        }
        func landable(_ a: Int, _ b: Int) -> Bool {
            !fast(a, b) || meters(a, b) <= plane * (t[b] - t[a] - AirborneFilter.landingDuration)
        }
        func stays(_ i: Int, _ before: Int?, _ after: Int?, moving: Double = AirborneFilter.maximumGroundSpeed, landing: Bool = false) -> Bool {
            var first = before.map { $0 + 1 } ?? edge(i, -1), last = after.map { $0 - 1 } ?? edge(i, 1)
            while first < i && meters(first, i) >= leg { first += 1 }
            while last > i && meters(i, last) >= leg { last -= 1 }
            guard first < last else { return false }
            let span = t[last] - t[first]
            guard span >= AirborneFilter.shortestStay else { return false }
            if landing && c[first] == c[last] && t[i] - t[first] < stay && t[last] - t[i] < stay {
                if let before, !landable(before, first) { return false }
                if let after, !landable(last, after) { return false }
            }
            var progress = Double.infinity
            if let before { progress = min(progress, meters(before, last) - meters(before, first)) }
            if let after { progress = min(progress, meters(first, after) - meters(last, after)) }
            if before == nil && after == nil { progress = meters(first, last) }
            return progress < max(moving * span, accuracy[first] + accuracy[last]) + 1
        }
        // With `byFix`, a minute of fixes: a repeated fix is as old as the first photo on it.
        func staysAt(_ p: Int, _ step: Int, byFix: Bool = false) -> Bool {
            let s = byFix ? fixTime : t
            var j = p + step
            while j >= 0 && j < n && abs(t[j] - t[p]) <= window {
                if meters(j, p) >= leg {
                    if reachable(j, p) { return false }
                } else if abs(s[j] - s[p]) >= stay {
                    return true
                }
                j += step
            }
            return false
        }
        // By the times of the fixes.
        func comesBack(_ i: Int) -> Bool {
            for step in [-1, 1] {
                var k = i + step
                while k >= 0 && k < n && abs(fixTime[k] - fixTime[i]) <= AirborneFilter.returnDuration {
                    if abs(fixTime[k] - fixTime[i]) >= stay && meters(i, k) < leg { return true }
                    k += step
                }
            }
            return false
        }

        /// Rule 2: photo `i` lies on the way between two flown legs, with no stay, no turn back right
        /// before or after them, and no location coming back to it.
        func isRun(_ i: Int) -> Bool {
            guard let b = neighbour(i, -1), let a = neighbour(i, 1), flown(b, i), flown(i, a), onTheWay(b, i, a) else { return false }
            if stays(i, b, a, landing: true) { return false }
            if t[i] - t[b] <= AirborneFilter.runEndLongDuration && staysAt(b, -1) { return false }
            if t[a] - t[i] <= AirborneFilter.runEndLongDuration && staysAt(a, 1) { return false }
            if let p = neighbour(b, -1), turning(p, b), !onTheWay(p, b, i) { return false }
            if let q = neighbour(a, 1), turning(a, q), !onTheWay(i, a, q) { return false }
            return !comesBack(i)
        }

        /// The first photo of each moment of rule 3.
        func momentStarts() -> [Int] {
            var moments: [Int] = []
            for k in 0..<n {
                if let m = moments.last {
                    let d = meters(m, k), s = t[k] - t[m]
                    let step = d >= max(AirborneFilter.burstStepMeters, accuracy[m] + accuracy[k]) && d <= plane * s
                    if c[k] == c[k - 1] || (s <= AirborneFilter.sampleDuration && !step) { continue }
                }
                moments.append(k)
            }
            return moments
        }

        func momentEnd(_ m: Int) -> Int { m + 1 < moments.count ? moments[m + 1] - 1 : n - 1 }
        func steady(_ from: Int, _ to: Int) -> Bool {
            var slowest = Double.infinity, fastest = 0.0, path = 0.0
            for m in from..<to {
                let x = moments[m], y = moments[m + 1]
                let d = meters(x, y), s = t[y] - t[x]
                let speed = aloft[x] && aloft[y] ? AirborneFilter.aloftBurstSpeed : AirborneFilter.burstSpeed
                guard s > 0, s <= AirborneFilter.burstStepDuration, d >= max(AirborneFilter.burstStepMeters, accuracy[x] + accuracy[y]),
                      d > speed * s, d <= plane * s else { return false }
                slowest = min(slowest, d / s)
                fastest = max(fastest, d / s)
                path += d
            }
            return fastest <= AirborneFilter.burstSpeedRatio * slowest
                && path <= AirborneFilter.burstStraightness * meters(moments[from], moments[to])
        }

        /// Every four and every three moments in a row that move steadily and straight on (rule 3),
        /// chained where they share a moment.
        func chains() -> [MomentChain] {
            var chains: [MomentChain] = []
            for k in moments.indices {
                let four = k >= 3 && steady(k - 3, k)
                guard four || (k >= 2 && steady(k - 2, k)) else { continue }
                let from = four ? k - 3 : k - 2
                if let chain = chains.last, from <= chain.last {
                    chains[chains.count - 1] = MomentChain(first: chain.first, last: k, four: chain.four || four)
                } else {
                    chains.append(MomentChain(first: from, last: k, four: four))
                }
            }
            return chains
        }

        // From a burst's first photo to its last; a minute of fixes near either end is a stay.
        func headsOn(_ from: Int, _ to: Int) -> Bool {
            guard !staysAt(from, -1, byFix: true), !staysAt(to, 1, byFix: true) else { return false }
            let before = neighbour(from, -1), after = neighbour(to, 1)
            guard before != nil || after != nil else { return false }
            let way = AirborneFilter.burstHeading * meters(from, to)
            if let before, meters(before, to) - meters(before, from) < way { return false }
            if let after, meters(from, after) - meters(to, after) < way { return false }
            return true
        }

        /// The bursts of `chains`: a chain without four steady moments in a row must head on.
        func bursts(of chains: [MomentChain]) -> Bursts {
            var burst = [Bool](repeating: false, count: n), first = [Int](repeating: -1, count: n), last = first
            for chain in chains {
                let from = moments[chain.first], to = momentEnd(chain.last)
                guard chain.four || headsOn(from, to) else { continue }
                for p in from...to { (burst[p], first[p], last[p]) = (true, from, to) }
            }
            return Bursts(burst: burst, first: first, last: last)
        }

        /// Rule 4: photo `i`, in flight by none of the other rules, at an end of a run or a burst.
        func isRunEnd(_ i: Int, run: [Bool], confirmed: [Bool], bursts: Bursts) -> Bool {
            guard !confirmed[i] else { return false }
            // A minute of photos near it is a stay; next to the flown leg to the run, a shorter
            // row is one when it moved on slower than `stayMovingSpeed`.
            let b = neighbour(i, -1), a = neighbour(i, 1)
            guard !staysAt(i, -1), !staysAt(i, 1), !stays(i, b, a, moving: AirborneFilter.stayMovingSpeed), !comesBack(i) else { return false }
            for (r, other, later) in [(a, b, true), (b, a, false)] {
                guard let r, confirmed[r], flown(i, r) else { continue }
                let seconds = abs(t[r] - t[i])
                guard seconds <= AirborneFilter.runEndLongDuration,
                      seconds <= AirborneFilter.runEndDuration || meters(i, r) > AirborneFilter.runEndLongSpeed * seconds else { continue }
                if let other, !(later ? onTheWay(other, i, r) : onTheWay(r, i, other)) { continue }
                let far = run[r] ? neighbour(r, later ? 1 : -1) : bursts.burst[r] ? (later ? bursts.last[r] : bursts.first[r]) : nil
                if let far, far != r, !(later ? onTheWay(i, r, far) : onTheWay(far, r, i)) { continue }
                return true
            }
            return false
        }

        /// Maybe in flight: exactly one flown leg (no short one to a stay), and rule 2's conditions
        /// with it, a stay moving on slower than `stayMovingSpeed`.
        func isMaybe(_ i: Int) -> Bool {
            guard !staysAt(i, -1), !staysAt(i, 1) else { return false }
            let b = neighbour(i, -1), a = neighbour(i, 1)
            let short = AirborneFilter.runEndLongDuration
            let flownBefore = b.map { flown($0, i) && !(t[i] - t[$0] <= short && staysAt($0, -1)) } ?? false
            let flownAfter = a.map { flown(i, $0) && !(t[$0] - t[i] <= short && staysAt($0, 1)) } ?? false
            guard flownBefore != flownAfter else { return false }
            if let b, let a, !onTheWay(b, i, a) { return false }
            if stays(i, b, a, moving: AirborneFilter.stayMovingSpeed) { return false }
            if let b, let p = neighbour(b, -1), turning(p, b), !onTheWay(p, b, i) { return false }
            if let a, let q = neighbour(a, 1), turning(a, q), !onTheWay(i, a, q) { return false }
            return !comesBack(i)
        }

        /// The photos in flight by each rule, and those maybe in flight.
        func judge() -> Judged {
            // Rule 1 and rule 2.
            let run = (0..<n).map { isRun($0) }
            // Rule 3: every four and every three moments in a row that move steadily and straight on,
            // chained where they share a moment; a chain without four of them must head on. A photo is
            // of the moment before it on the fix of the photo before, or within `sampleDuration` of
            // the moment's first photo with no step of its own from it.
            let bursts = self.bursts(of: chains())
            // A burst's photos that the location comes back to are none.
            let inBurst = (0..<n).map { bursts.burst[$0] && !comesBack($0) }
            // Rule 4.
            let confirmed = (0..<n).map { high[$0] || run[$0] || inBurst[$0] }
            let end = (0..<n).map { isRunEnd($0, run: run, confirmed: confirmed, bursts: bursts) }
            var result = Judged()
            for (rule, flags) in [high, run, inBurst, end].enumerated() {
                for i in 0..<n where flags[i] {
                    result.all.insert(judged[i].id)
                    result.byRule[rule].insert(judged[i].id)
                }
            }
            // Maybe in flight (`isMaybe`).
            for i in 0..<n where !result.all.contains(judged[i].id) && isMaybe(i) {
                result.maybe.insert(judged[i].id)
            }
            result.maybe.subtract(result.all)
            return result
        }
    }
}
