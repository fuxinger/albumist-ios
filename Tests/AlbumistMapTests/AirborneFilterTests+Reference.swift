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
        let judged = photos.filter { $0.usableLocation != nil && $0.creationDate != nil && !$0.isScreenshotLike }.sorted { a, b in
            (a.creationDate!, a.id.rawValue, a.location!.latitude, a.location!.longitude)
                < (b.creationDate!, b.id.rawValue, b.location!.latitude, b.location!.longitude)
        }
        let n = judged.count
        let t = judged.map { $0.creationDate!.timeIntervalSinceReferenceDate }, c = judged.map { $0.location! }
        let accuracy = judged.map { $0.locationAccuracy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
        let leg = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration, stay = AirborneFilter.stayDuration
        let ground = AirborneFilter.maximumGroundSpeed, plane = AirborneFilter.maximumFlightSpeed
        // A photo on exactly the fix of the photo before repeats it: the fix is as old as the first
        // photo of the row.
        var fixTime = t
        for k in 0..<n where k > 0 && c[k] == c[k - 1] { fixTime[k] = fixTime[k - 1] }
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

        // Rule 1 and rule 2.
        let high = judged.map { photo in altitudes[photo.id].map { $0 > AirborneFilter.maximumAltitude } ?? false }
        let run = (0..<n).map { i -> Bool in
            guard let b = neighbour(i, -1), let a = neighbour(i, 1), flown(b, i), flown(i, a), onTheWay(b, i, a) else { return false }
            if stays(i, b, a, landing: true) { return false }
            if t[i] - t[b] <= AirborneFilter.runEndLongDuration && staysAt(b, -1) { return false }
            if t[a] - t[i] <= AirborneFilter.runEndLongDuration && staysAt(a, 1) { return false }
            if let p = neighbour(b, -1), turning(p, b), !onTheWay(p, b, i) { return false }
            if let q = neighbour(a, 1), turning(a, q), !onTheWay(i, a, q) { return false }
            return !comesBack(i)
        }
        // Rule 3: every four and every three moments in a row that move steadily and straight on,
        // chained where they share a moment; a chain without four of them must head on. A photo is
        // of the moment before it on the fix of the photo before, or within `sampleDuration` of
        // the moment's first photo with no step of its own from it.
        let aloft = judged.map { photo in altitudes[photo.id].map { $0 > AirborneFilter.aloftAltitude } ?? false }
        var moments: [Int] = []
        for k in 0..<n {
            if let m = moments.last {
                let d = meters(m, k), s = t[k] - t[m]
                let step = d >= max(AirborneFilter.burstStepMeters, accuracy[m] + accuracy[k]) && d <= plane * s
                if c[k] == c[k - 1] || (s <= AirborneFilter.sampleDuration && !step) { continue }
            }
            moments.append(k)
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
        var chains: [(first: Int, last: Int, four: Bool)] = []
        for k in moments.indices {
            let four = k >= 3 && steady(k - 3, k)
            guard four || (k >= 2 && steady(k - 2, k)) else { continue }
            let from = four ? k - 3 : k - 2
            if let chain = chains.last, from <= chain.last {
                chains[chains.count - 1] = (chain.first, k, chain.four || four)
            } else {
                chains.append((from, k, four))
            }
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
        var burst = [Bool](repeating: false, count: n), first = [Int](repeating: -1, count: n), last = first
        for chain in chains {
            let from = moments[chain.first], to = momentEnd(chain.last)
            guard chain.four || headsOn(from, to) else { continue }
            for p in from...to { (burst[p], first[p], last[p]) = (true, from, to) }
        }
        // A burst's photos that the location comes back to are none.
        let inBurst = (0..<n).map { burst[$0] && !comesBack($0) }
        // Rule 4.
        let confirmed = (0..<n).map { high[$0] || run[$0] || inBurst[$0] }
        let end = (0..<n).map { i -> Bool in
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
                let far = run[r] ? neighbour(r, later ? 1 : -1) : burst[r] ? (later ? last[r] : first[r]) : nil
                if let far, far != r, !(later ? onTheWay(i, r, far) : onTheWay(far, r, i)) { continue }
                return true
            }
            return false
        }
        var result = Judged()
        for (rule, flags) in [high, run, inBurst, end].enumerated() {
            for i in 0..<n where flags[i] {
                result.all.insert(judged[i].id)
                result.byRule[rule].insert(judged[i].id)
            }
        }
        // Maybe in flight: exactly one flown leg (no short one to a stay), and rule 2's conditions
        // with it, a stay moving on slower than `stayMovingSpeed`.
        for i in 0..<n where !result.all.contains(judged[i].id) {
            guard !staysAt(i, -1), !staysAt(i, 1) else { continue }
            let b = neighbour(i, -1), a = neighbour(i, 1)
            let short = AirborneFilter.runEndLongDuration
            let flownBefore = b.map { flown($0, i) && !(t[i] - t[$0] <= short && staysAt($0, -1)) } ?? false
            let flownAfter = a.map { flown(i, $0) && !(t[$0] - t[i] <= short && staysAt($0, 1)) } ?? false
            guard flownBefore != flownAfter else { continue }
            if let b, let a, !onTheWay(b, i, a) { continue }
            if stays(i, b, a, moving: AirborneFilter.stayMovingSpeed) { continue }
            if let b, let p = neighbour(b, -1), turning(p, b), !onTheWay(p, b, i) { continue }
            if let a, let q = neighbour(a, 1), turning(a, q), !onTheWay(i, a, q) { continue }
            if !comesBack(i) { result.maybe.insert(judged[i].id) }
        }
        result.maybe.subtract(result.all)
        return result
    }
}
