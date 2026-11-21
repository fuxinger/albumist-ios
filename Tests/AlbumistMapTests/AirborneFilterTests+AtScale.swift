import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Window photos as people take them, at scale: lonely series of window photos on flights between
/// Europe's airports are found, at the pace people tap too, and window photos seconds apart are
/// found while quick series at layovers are not.
extension AirborneFilterTests {
    // MARK: Window photos as people take them, at scale

    /// Airports for the flights below: Munich, Frankfurt, Lisbon, Rome, London Heathrow, Madrid,
    /// Athens, Vienna, Istanbul, Stockholm Arlanda, Amsterdam, Berlin.
    static let europe = [munichAirport, frankfurtAirport, lisbonAirport, romeAirport, MapFixture.at(51.4700, -0.4543),
                         MapFixture.at(40.4983, -3.5676), MapFixture.at(37.9364, 23.9445), MapFixture.at(48.1103, 16.5697),
                         MapFixture.at(41.2753, 28.7519), MapFixture.at(59.6519, 17.9186), MapFixture.at(52.3105, 4.7683),
                         MapFixture.at(52.3667, 13.5033)]

    /// Where a photo taken `seconds` after take-off finds itself: the fix the iPhone last updated,
    /// up to a second before (it updates the location about once a second), off by GPS noise of
    /// 10 m.
    static func fix(_ path: Flight, seconds: TimeInterval, _ random: inout MapRandom) -> GeoCoordinate {
        noisy(path.position(minutes: max(0, seconds - random.unit()) / 60), &random)
    }

    /// `truth` off by GPS noise of 10 m.
    static func noisy(_ truth: GeoCoordinate, _ random: inout MapRandom) -> GeoCoordinate {
        let noise = 10 * (-2 * log(max(1e-12, random.unit()))).squareRoot()
        return offset(truth, km: noise / 1_000, bearing: random.unit() * 360)
    }

    /// Flights between `europe`'s airports three days apart whose only window photos are one
    /// series of `size` photos `spacing` seconds apart, anywhere from 8 minutes after take-off to
    /// 8 minutes before landing (`fix`; with `clock`, the iPhone updates the fix once a second, at
    /// a moment of each flight's own, and every photo until the next update carries it); four
    /// times in five a gate photo 30 minutes to 3 hours before take-off, four times in five an
    /// arrival photo 20 minutes to 3 hours after landing.
    static func seriesFlights(seed: UInt64, flights: Int, size: Int, spacing: ClosedRange<Double> = 1...10,
                              clock: Bool = false) -> (photos: [AssetSnapshot], series: [[AssetID]]) {
        var random = MapRandom(seed: seed)
        func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * random.unit() }
        var photos: [AssetSnapshot] = [], series: [[AssetID]] = []
        var day = MapFixture.date("2021-01-01")
        while series.count < flights {
            let a = europe[random.int(0..<europe.count)], b = europe[random.int(0..<europe.count)]
            guard GeoMath.distance(a, b) >= 450_000 else { continue }
            let n = series.count, takeoff = day.addingTimeInterval(uniform(6, 12) * 3_600)
            let path = Flight(from: a, to: b, takeoff: takeoff, cruiseKmh: uniform(780, 900))
            if random.int(0..<5) > 0 {
                photos.append(shot("gate-\(n)", minutes(takeoff, -uniform(30, 180)), Fixture.jitter(a, seed: n, meters: 600)))
            }
            if random.int(0..<5) > 0 {
                photos.append(shot("arr-\(n)", minutes(path.landing, uniform(20, 180)), Fixture.jitter(b, seed: n, meters: 600)))
            }
            var seconds = uniform(8, path.minutes - 8 - Double(size) / 6) * 60
            let phase = clock ? random.unit() : 0
            var ids: [AssetID] = [], updates: [Double: GeoCoordinate] = [:]
            for k in 0..<size {
                if k > 0 { seconds += uniform(spacing.lowerBound, spacing.upperBound) }
                ids.append(AssetID("s-\(n)-\(k)"))
                let location: GeoCoordinate
                if clock {
                    let update = (seconds - phase).rounded(.down) + phase
                    location = updates[update] ?? noisy(path.position(minutes: update / 60), &random)
                    updates[update] = location
                } else {
                    location = fix(path, seconds: seconds, &random)
                }
                photos.append(shot(ids[k].rawValue, takeoff.addingTimeInterval(seconds), location))
            }
            series.append(ids)
            day = day.addingTimeInterval(3 * 86_400)
        }
        return (photos, series)
    }

    /// Finding 1 of the second review, at scale: 500 flights whose only window photos are one
    /// series of three (or four). Three were found only where their legs to the airports were
    /// flown (9 of 500); now seven in eight are, as are four. Missed by design: a series of three
    /// with no photo within `maximumLongLegDuration` (some one flight in 20 here; four need none),
    /// steps made uneven by the age of their fixes (a fix a second old on a step of one or two
    /// seconds), a series in the climb or descent slower than `burstSpeed`. No gate or arrival
    /// photo is taken.
    @Test func lonelySeriesOfWindowPhotosAreFound() {
        for size in [3, 4] {
            let (photos, series) = Self.seriesFlights(seed: 21, flights: 500, size: size)
            let airborne = AirborneFilter.airborne(photos)
            let found = series.filter { $0.allSatisfy(airborne.contains) }.count
            #expect(found >= 425, "\(size): \(found) of \(series.count) found")
            #expect(airborne.allSatisfy { $0.rawValue.hasPrefix("s-") }, "\(size)")
        }
    }

    /// A pace of `lonelySeriesAtThePacePeopleTapAreFound`: the seconds between the photos of a
    /// series, whether the iPhone updates the fix once a second, and how many series of three and of
    /// four are found whole at least.
    struct Pace {
        var spacing: ClosedRange<Double>
        var clock: Bool
        var three: Int
        var four: Int

        init(_ spacing: ClosedRange<Double>, _ clock: Bool, _ three: Int, _ four: Int) {
            self.spacing = spacing
            self.clock = clock
            self.three = three
            self.four = four
        }
    }

    /// Finding 2.2 of the third review at scale: the same flights, the photos of a series 1 to 3
    /// seconds apart as people tap, or 0.3 to 2 seconds, with the tests' fixes (`fix`) and with a
    /// fix updated once a second. Found whole, of 500 (tests' fixes, one-second clock):
    /// - 1 to 3 s: series of three 311 and 295, of four 234 and 230 (unchanged);
    /// - 0.3 to 2 s: three 117 and 137 (unchanged), four 188 and 186, where they were 50 and 81:
    ///   a photo within a second of the one before with no step of its own from it (on its fix,
    ///   shorter than `burstStepMeters`, or faster than a plane) broke the series; it is of that
    ///   photo's moment now (`AirborneFilter.sampleDuration`).
    ///
    /// Documented limit, measured: the review asked for 425 of 500 at 1 to 3 s. Steady steps need
    /// fixes about as old as each other, and at this pace they seldom are: a fix up to a second old
    /// lengthens or shortens a step of one to three seconds by up to a second's flight. Accepting a
    /// series when one speed fits all its steps within a second of fix age finds 415 and 436 series
    /// of three (399 and 437 of four), but takes a fast train with noisy fixes for a plane: of
    /// `ground`'s photos it takes 3,276 instead of 420 (1,109 instead of 8 with stated accuracies;
    /// trains 662 and 636 instead of 3 and 0). Of the series of three missed at 1 to 3 s, 129 and
    /// 143 count on the map: no leg of theirs was flown. The time of each fix (the location's own
    /// timestamp, which the analysis does not store yet) would make their steps exact.
    @Test(arguments: [3, 4])
    func lonelySeriesAtThePacePeopleTapAreFound(size: Int) {
        let floors = [
            Pace(1...3, false, 300, 225), Pace(1...3, true, 285, 220), Pace(0.3...2, false, 110, 180), Pace(0.3...2, true, 130, 180),
        ]
        for pace in floors {
            let (spacing, clock, three, four) = (pace.spacing, pace.clock, pace.three, pace.four)
            let (photos, series) = Self.seriesFlights(seed: 21, flights: 500, size: size, spacing: spacing, clock: clock)
            let airborne = AirborneFilter.airborne(photos)
            let found = series.filter { $0.allSatisfy(airborne.contains) }.count
            let fix = clock ? "a fix updated once a second" : "the tests' fixes"
            #expect(found >= (size == 3 ? three : four), "\(spacing) s, \(fix): \(found) of \(series.count) series of \(size) found whole")
            #expect(airborne.allSatisfy { $0.rawValue.hasPrefix("s-") }, "\(spacing) s, \(fix)")
        }
    }

    /// The photos of `flightsAndLayovers`, and which of them are window photos and which are taken
    /// at a layover.
    struct FlightsAndLayovers {
        var photos: [AssetSnapshot]
        var window: Set<AssetID>
        var layover: Set<AssetID>
    }

    /// Flights between `europe`'s airports with window photos as people take them, every 5 to 15
    /// minutes from 8 to 14 minutes after take-off to 8 minutes before landing (`fix`): one photo
    /// seven times in ten, else two or three a fraction of a second apart, or three to five 2 to 5
    /// seconds apart; a gate photo 30 to 60 minutes before take-off, an arrival photo 20 to 40
    /// minutes after landing. And as many short-haul layovers: a photo at Berlin airport, two to
    /// four at Vienna airport within 5 to 40 seconds 65 to 80 minutes later, one at Athens airport
    /// 1.5 to 2 hours after them.
    static func flightsAndLayovers(seed: UInt64, flights: Int) -> FlightsAndLayovers {
        var random = MapRandom(seed: seed)
        func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * random.unit() }
        var photos: [AssetSnapshot] = [], window = Set<AssetID>(), layover = Set<AssetID>()
        var day = MapFixture.date("2022-01-01")
        var n = 0
        while n < flights {
            let a = europe[random.int(0..<europe.count)], b = europe[random.int(0..<europe.count)]
            guard GeoMath.distance(a, b) >= 450_000 else { continue }
            n += 1
            let takeoff = day.addingTimeInterval(uniform(6, 12) * 3_600)
            let path = Flight(from: a, to: b, takeoff: takeoff, cruiseKmh: uniform(780, 900))
            photos.append(shot("gate-\(n)", minutes(takeoff, -uniform(30, 60)), Fixture.jitter(a, seed: n, meters: 600)))
            var at = uniform(8, 14)
            while at < path.minutes - 8 {
                var shots: [Double] = [0]
                let draw = random.int(0..<20)
                if draw >= 14 {
                    let rapid = draw < 17, step = rapid ? uniform(0.2, 0.5) : uniform(2, 5)
                    shots = (0..<(rapid ? 2 + random.int(0..<2) : 3 + random.int(0..<3))).map { Double($0) * step }
                }
                for s in shots {
                    let id = AssetID("w-\(n)-\(window.count)")
                    photos.append(shot(id.rawValue, takeoff.addingTimeInterval(at * 60 + s), fix(path, seconds: at * 60 + s, &random)))
                    window.insert(id)
                }
                at += uniform(5, 15)
            }
            photos.append(shot("arr-\(n)", minutes(path.landing, uniform(20, 40)), Fixture.jitter(b, seed: n, meters: 600)))
            day = day.addingTimeInterval(3 * 86_400)
        }
        let berlin = MapFixture.at(52.3667, 13.5033), vienna = MapFixture.at(48.1103, 16.5697), athens = MapFixture.at(37.9364, 23.9445)
        for h in 0..<flights {
            let t0 = day.addingTimeInterval(Double(h) * 2 * 86_400)
            photos.append(shot("ber-\(h)", t0, Fixture.jitter(berlin, seed: h, meters: 300)))
            let start = uniform(3_900, 4_800), count = 2 + random.int(0..<3), span = uniform(5, 40)
            for k in 0..<count {
                let id = AssetID("vie-\(h)-\(k)")
                let at = t0.addingTimeInterval(start + span * Double(k) / Double(count - 1))
                photos.append(shot(id.rawValue, at, Fixture.jitter(vienna, seed: h * 5 + k, meters: 60)))
                layover.insert(id)
            }
            let arrival = t0.addingTimeInterval(start + span + uniform(5_400, 7_200))
            photos.append(shot("ath-\(h)", arrival, Fixture.jitter(athens, seed: h, meters: 300)))
        }
        return FlightsAndLayovers(photos: photos, window: window, layover: layover)
    }

    /// Finding 9 of the second review, at scale: 300 flights with window photos as people take
    /// them and 300 short-haul layovers with a quick series at Vienna. Every window photo is found
    /// and no ground photo is taken. Before, most quick series at Vienna counted as in flight, and
    /// two or three photos a fraction of a second apart as a flight's first or last window photos
    /// (rule 4) could show a stay: their fixes, up to a second old, had barely moved on.
    @Test func windowPhotosSecondsApartAreFoundAndQuickSeriesAtLayoversAreNot() {
        let library = Self.flightsAndLayovers(seed: 31, flights: 300)
        let (photos, window, layover) = (library.photos, library.window, library.layover)
        let airborne = AirborneFilter.airborne(photos)
        #expect(window.count > 5_000 && layover.count > 800)
        #expect(window.isSubset(of: airborne), "missed \(window.subtracting(airborne).count) of \(window.count)")
        #expect(airborne.isSubset(of: window), "\(layover.intersection(airborne).count) of \(layover.count) at Vienna taken")
    }
}
