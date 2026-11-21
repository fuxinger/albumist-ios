import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// The ground at its worst, at scale: 200,000 ground photos that look most like window photos,
/// with and without stated accuracies, at sea level and high up, are rarely taken for a flight.
extension AirborneFilterTests {
    // MARK: The ground at its worst, at scale

    /// Ground photos that look most like window photos, in sessions 2 to 30 hours apart, for the
    /// rate at which the rules take the ground for a flight. The first word of an id names its
    /// scenario:
    /// - `jump`: indoors, each fix lands 1 to 3 km off the true place in any direction, a photo
    ///   every 1 to 30 seconds; half the sessions 3 to 8 photos, the others 9 to 100;
    /// - `spots`: indoors, the location jumps between two or three spots (the others 1.5 to 2.5 km
    ///   from the first), a photo every 2 to 20 seconds, as many photos;
    /// - `closing`: a coarse first fix 0.3 to 3 km off closes in on the true place (its error
    ///   shrinks by e^(-t/τ), τ 2 to 15 seconds, its direction drifting), 3 to 6 photos 1 to 5
    ///   seconds apart, then none (a third of the time) or 1 to 10 at the true place, 5 to 60
    ///   seconds apart;
    /// - `train` (250 to 350 km/h) and `car` (80 to 200 km/h), 15 to 60 minutes: every 1 to 10
    ///   minutes a photo or a series of 2 to 8 photos 1 to 4 seconds apart, each fix off by GPS
    ///   noise of 5 to 25 m, one in 20 by 100 to 400 m; a quarter of the series (`tunnel`) right
    ///   after a tunnel, the fix 100 to 800 m behind and catching up (τ 2 to 10 seconds);
    /// - `shared`: two people's photos in one library, 3 to 300 km apart, series of 1 to 5 photos in
    ///   turn every 1 to 30 minutes, one of them now and then indoors with a jumping location.
    /// Before and after each session: a photo at home, 1 to 4 hours apart from it (`home`); or a
    /// photo 5 to 50 km from it, 20 minutes to 3 hours apart (`other`); or neither. With
    /// `accuracy` every fix states one, as the iPhone does: its error give or take half (a Wi-Fi
    /// spot 30 to 100 m, however far off it is); without, none does: the worst case. With `aloft`,
    /// the same life high up in the Andes or in Tibet: trains at 160 to 250 km/h, cars at 60 to
    /// 150 km/h.
    static func ground(seed: UInt64, count: Int, accuracy: Bool, aloft: Bool = false) -> [AssetSnapshot] {
        var life = Ground(seed: seed, accuracy: accuracy, aloft: aloft)
        while life.photos.count < count { life.session() }
        return life.photos
    }

    /// The ground photos of `ground` so far, their random numbers and the time.
    struct Ground {
        let accuracy: Bool, aloft: Bool
        // The claims draw from their own numbers: with and without them, the photos are the same.
        var random: MapRandom, claims: MapRandom
        var photos: [AssetSnapshot] = []
        var time = MapFixture.date("2020-01-01").timeIntervalSinceReferenceDate
        let home = Places.regensburg

        init(seed: UInt64, accuracy: Bool, aloft: Bool) {
            self.accuracy = accuracy
            self.aloft = aloft
            random = MapRandom(seed: seed)
            claims = MapRandom(seed: seed &+ 1)
        }

        mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * random.unit() }

        mutating func add(_ scenario: String, _ coordinate: GeoCoordinate, error: Double, spot: Bool = false) {
            let claim = claims.unit(), claimed = spot ? 30 + 70 * claim : max(5, error * (0.5 + claim))
            photos.append(shot("\(scenario)-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), coordinate,
                               accuracy: accuracy ? claimed : nil))
        }

        /// A fix off `c` by GPS noise of `sigma` metres in each direction, and how far off.
        mutating func noisy(_ c: GeoCoordinate, sigma: Double) -> (GeoCoordinate, Double) {
            let r = sigma * (-2 * log(max(1e-12, random.unit()))).squareRoot()
            return (offset(c, km: r / 1_000, bearing: uniform(0, 360)), r)
        }

        /// Before or after a session: a photo at home, or one 5 to 50 km from the session, or neither.
        mutating func context(_ center: GeoCoordinate, after: Bool) {
            let draw = random.int(0..<10)
            let gap = draw < 5 ? uniform(1, 4) * 3_600 : uniform(0.3, 3) * 3_600
            if after { time += gap }
            if draw < 5 {
                let (c, e) = noisy(home, sigma: 20)
                add("home", c, error: e)
            } else if draw < 8 {
                let (c, e) = noisy(offset(center, km: uniform(5, 50), bearing: uniform(0, 360)), sigma: 20)
                add("other", c, error: e)
            }
            if !after { time += gap }
        }

        mutating func length() -> Int { random.int(0..<2) == 0 ? 3 + random.int(0..<6) : 9 + random.int(0..<92) }

        /// A session of one scenario, 2 to 30 hours after the one before, with what comes before
        /// and after it.
        mutating func session() {
            time += uniform(2, 30) * 3_600
            let center = offset(home, km: uniform(5, 200), bearing: uniform(0, 360))
            context(center, after: false)
            let scenario = random.int(0..<6)
            switch scenario {
            case 0:
                jumpIndoors(center)
            case 1:
                spotsIndoors(center)
            case 2:
                closeIn(center)
            case 3, 4:
                ride(center, isTrain: scenario == 3)
            default:
                twoPeople(center)
            }
            context(center, after: true)
        }

        /// `jump`: indoors, each fix 1 to 3 km off the true place in any direction.
        mutating func jumpIndoors(_ center: GeoCoordinate) {
            for k in 0..<length() {
                if k > 0 { time += uniform(1, 30) }
                let error = uniform(1_000, 3_000)
                add("jump", offset(center, km: error / 1_000, bearing: uniform(0, 360)), error: error)
            }
        }

        /// `spots`: indoors, the location jumping between two or three spots.
        mutating func spotsIndoors(_ center: GeoCoordinate) {
            let bearing = uniform(0, 360)
            let spots = [center, offset(center, km: uniform(1.5, 2.5), bearing: bearing),
                         offset(center, km: uniform(1.5, 2.5), bearing: bearing + uniform(50, 130))]
            let used = 2 + random.int(0..<2)
            for k in 0..<length() {
                if k > 0 { time += uniform(2, 20) }
                let (c, _) = noisy(spots[random.int(0..<used)], sigma: 100)
                add("spots", c, error: GeoMath.distance(c, center), spot: true)
            }
        }

        /// `closing`: a coarse first fix closing in on the true place, then none or a few photos there.
        mutating func closeIn(_ center: GeoCoordinate) {
            var error = uniform(300, 3_000), bearing = uniform(0, 360)
            let tau = uniform(2, 15)
            for k in 0..<(3 + random.int(0..<4)) {
                if k > 0 {
                    let seconds = uniform(1, 5)
                    time += seconds
                    error *= exp(-seconds / tau)
                    bearing += uniform(-15, 15)
                }
                add("closing", offset(center, km: error / 1_000, bearing: bearing), error: error)
            }
            if random.int(0..<3) > 0 {
                for _ in 0..<(1 + random.int(0..<10)) {
                    time += uniform(5, 60)
                    let (c, e) = noisy(center, sigma: 15)
                    add("closing", c, error: e)
                }
            }
        }

        /// `train` or `car`, and `tunnel` for a series right after a tunnel.
        mutating func ride(_ center: GeoCoordinate, isTrain: Bool) {
            let name = isTrain ? "train" : "car"
            let speed = (isTrain ? (aloft ? uniform(160, 250) : uniform(250, 350)) : (aloft ? uniform(60, 150) : uniform(80, 200))) / 3.6
            let bearing = uniform(0, 360), sigma = uniform(5, 25)
            let duration = uniform(15, 60) * 60
            var t = 0.0
            while t < duration {
                let series = random.int(0..<3) == 0 ? 2 + random.int(0..<7) : 1
                let lag = series > 1 && random.int(0..<4) == 0 ? uniform(100, 800) : 0, tau = uniform(2, 10)
                var since = 0.0
                for k in 0..<series {
                    if k > 0 {
                        let seconds = uniform(1, 4)
                        since += seconds
                        t += seconds
                        time += seconds
                    }
                    let behind = lag * exp(-since / tau)
                    let truth = offset(center, km: (speed * t - behind) / 1_000, bearing: bearing)
                    var (c, e) = noisy(truth, sigma: sigma)
                    if random.int(0..<20) == 0 {
                        let off = uniform(100, 400)
                        c = offset(c, km: off / 1_000, bearing: uniform(0, 360))
                        e += off
                    }
                    add(lag > 0 ? "tunnel" : name, c, error: e + behind)
                }
                let gap = uniform(1, 10) * 60
                t += gap
                time += gap
            }
        }

        /// `shared`: two people's photos in one library, in turn.
        mutating func twoPeople(_ center: GeoCoordinate) {
            let other = offset(center, km: uniform(3, 300), bearing: uniform(0, 360))
            let indoors = random.int(0..<3) == 0
            for round in 0..<(4 + random.int(0..<12)) {
                let here = round % 2 == 0 ? center : other
                for k in 0..<(1 + random.int(0..<5)) {
                    if k > 0 { time += uniform(1, 5) }
                    if indoors && round % 2 == 0 {
                        let error = uniform(1_000, 3_000)
                        add("shared", offset(here, km: error / 1_000, bearing: uniform(0, 360)), error: error)
                    } else {
                        let (c, e) = noisy(here, sigma: uniform(10, 100))
                        add("shared", c, error: e)
                    }
                }
                time += uniform(1, 30) * 60
            }
        }
    }

    /// How many ground photos of each scenario of `ground` the rules take for window photos, and
    /// how many there are.
    static func groundTaken(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> (taken: [String: Int], all: [String: Int]) {
        let airborne = AirborneFilter.airborne(photos, altitudes: altitudes)
        var taken: [String: Int] = [:], all: [String: Int] = [:]
        for photo in photos {
            let scenario = String(photo.id.rawValue.prefix { $0 != "-" })
            all[scenario, default: 0] += 1
            if airborne.contains(photo.id) { taken[scenario, default: 0] += 1 }
        }
        return (taken, all)
    }

    /// 200,000 photos of `ground` at a time, without stated accuracies (the worst case) and with
    /// them, at sea level and with an altitude above `aloftAltitude` stored for every photo.
    /// Without accuracies some two in a thousand are taken (five up there, where rule 3 takes steps
    /// from `aloftBurstSpeed` on): mostly fixes closing in, or catching up after a tunnel, along the
    /// way from the photos before them to those after them, the documented price of finding three
    /// window photos seconds apart. With accuracies, as the iPhone states them, five in 100,000
    /// (two in 10,000 up there). Photos at home, 5 to 50 km away and in cars never.
    @Test func theGroundAtItsWorstIsRarelyTakenForAFlight() {
        for (accuracy, aloft, bound) in [(false, false, 500), (true, false, 20), (false, true, 1_200), (true, true, 60)] {
            let photos = Self.ground(seed: 5, count: 200_000, accuracy: accuracy, aloft: aloft)
            let altitudes = aloft ? Dictionary(uniqueKeysWithValues: photos.map { ($0.id, 3_600.0) }) : [:]
            let (taken, all) = Self.groundTaken(photos, altitudes: altitudes)
            let total = taken.values.reduce(0, +)
            let line = all.keys.sorted().map { "\($0) \(taken[$0] ?? 0)/\(all[$0]!)" }.joined(separator: ", ")
            print("AIRBORNE_GROUND accuracy \(accuracy) aloft \(aloft): \(total) of \(photos.count) taken | \(line)")
            #expect(total <= bound, "accuracy \(accuracy), aloft \(aloft): \(line)")
            #expect(["home", "other", "car"].allSatisfy { taken[$0] == nil }, "accuracy \(accuracy), aloft \(aloft): \(line)")
        }
    }
}
