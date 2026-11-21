import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// The fast search is the rule, photo by photo: on random lives of photos that meet every rule and
/// every bound (`wander`), on a realistic library, a dense flight and evenings indoors,
/// `AirborneFilter` finds what the reference finds.
extension AirborneFilterTests {
    /// A random life of photos, mixed so that every rule and every bound of the fast search is met:
    /// stays of many photos, walks and drives, flights with window photos and series, series at a
    /// plane's speed on their own, wrong locations, pauses of hours, long-haul hops, a location
    /// jumping kilometres within seconds, equal times, a photo twice, stated accuracies.
    static func wander(seed: UInt64, count: Int) -> [AssetSnapshot] {
        var life = Wander(seed: seed)
        while life.photos.count < count { life.step() }
        return Array(life.photos.prefix(count))
    }

    /// The life of `wander` so far: its random numbers, where and when it is, and its photos.
    struct Wander {
        let seed: UInt64
        var random: MapRandom
        var position = Places.munich
        var time = MapFixture.date("2023-01-01").timeIntervalSinceReferenceDate
        var photos: [AssetSnapshot] = []

        init(seed: UInt64) {
            self.seed = seed
            random = MapRandom(seed: seed)
        }

        mutating func add(_ coordinate: GeoCoordinate? = nil) {
            let accuracy: Double? = random.int(0..<12) == 0 ? 20 + random.unit() * 600 : nil
            photos.append(shot("r\(seed)-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), coordinate ?? position, accuracy: accuracy))
        }

        mutating func move(_ km: Double, bearing: Double? = nil) {
            let moved = offset(position, km: km, bearing: bearing ?? random.unit() * 360)
            position = MapFixture.at(min(80, max(-80, moved.latitude)), moved.longitude)
        }

        /// One more piece of life, drawn at random.
        mutating func step() {
            switch random.int(0..<16) {
            case 0, 1:
                stay()
            case 2:
                walkOrDrive()
            case 3, 4:
                fly()
            case 5:
                seriesAtAPlanesSpeed()
            case 6:
                time += random.unit() * 600
                add(offset(position, km: 3 + random.unit() * 2_000, bearing: random.unit() * 360))
                time += random.unit() * 600
                add()
            case 7:
                time += (1 + random.unit() * 30) * 3_600
                add()
            case 8:
                time += (3 + random.unit() * 14) * 3_600
                move(2_000 + random.unit() * 9_000)
                add()
            case 9:
                jumpIndoors()
            case 10:
                twoAtOnce()
            default:
                time += random.unit() * 1_200
                move(random.unit() * 6)
                add()
            }
        }

        /// A stay of many photos within 400 m, seconds or minutes apart.
        mutating func stay() {
            let center = position
            for _ in 0..<(2 + random.int(0..<25)) {
                time += random.unit() < 0.5 ? random.unit() * 10 : random.unit() * 300
                add(offset(center, km: random.unit() * 0.4, bearing: random.unit() * 360))
            }
        }

        /// A walk or a drive, a photo every half minute to ten minutes.
        mutating func walkOrDrive() {
            let bearing = random.unit() * 360, kmh = random.unit() < 0.5 ? 5 : 60 + random.unit() * 240
            for _ in 0..<(3 + random.int(0..<10)) {
                let minutes = 0.5 + random.unit() * 10
                time += minutes * 60
                move(kmh * minutes / 60, bearing: bearing + random.unit() * 20 - 10)
                add()
            }
        }

        /// A flight: a photo before it, window photos and series, a photo after it.
        mutating func fly() {
            add()
            time += (20 + random.unit() * 40) * 60
            let bearing = random.unit() * 360, kmh = 450 + random.unit() * 500
            for _ in 0..<(1 + random.int(0..<10)) {
                let minutes = 2 + random.unit() * 13
                time += minutes * 60
                move(kmh * minutes / 60, bearing: bearing)
                if random.int(0..<4) == 0 {
                    for _ in 0..<(2 + random.int(0..<4)) {
                        add()
                        let seconds = 1 + random.unit() * 4
                        time += seconds
                        move(kmh * seconds / 3_600, bearing: bearing)
                    }
                } else {
                    add()
                }
            }
            time += (15 + random.unit() * 40) * 60
            move(random.unit() * 20)
            add()
        }

        /// A series at a plane's speed on its own, seconds apart.
        mutating func seriesAtAPlanesSpeed() {
            let bearing = random.unit() * 360, kmh = 300 + random.unit() * 1_300
            for _ in 0..<(3 + random.int(0..<4)) {
                add()
                let seconds = 1 + random.unit() * 6
                time += seconds
                move(kmh * seconds / 3_600, bearing: bearing + random.unit() * 30 - 15)
            }
        }

        /// A location jumping one to three kilometres off within seconds.
        mutating func jumpIndoors() {
            let center = position
            for _ in 0..<(3 + random.int(0..<30)) {
                time += 2 + random.unit() * 30
                add(offset(center, km: 1 + random.unit() * 2, bearing: random.unit() * 360))
            }
        }

        /// Two photos at one time up to 5 km apart, the second sometimes listed twice.
        mutating func twoAtOnce() {
            add()
            add(offset(position, km: random.unit() * 5, bearing: random.unit() * 360))
            if random.int(0..<2) == 0 { photos.append(photos[photos.count - 1]) }
        }
    }

    @Test func theFastSearchGivesThePhotoByPhotoResult() {
        var byRule = [Int](repeating: 0, count: 4), maybe = 0
        for seed in 1...6 as ClosedRange<UInt64> {
            let photos = Self.wander(seed: seed, count: 2_500)
            let altitudes = Dictionary(photos.enumerated().filter { $0.offset % 97 == 0 }.map { ($0.element.id, Double($0.offset % 3) * 4_000) },
                                       uniquingKeysWith: { a, _ in a })
            let expected = Self.reference(photos, altitudes: altitudes)
            let airborne = AirborneFilter.airborne(photos, altitudes: altitudes)
            #expect(airborne == expected.all, "seed \(seed): extra \(airborne.subtracting(expected.all)), missing \(expected.all.subtracting(airborne))")
            let judgement = AirborneFilter.judge(photos, altitudes: altitudes)
            #expect(judgement.airborne == airborne)
            let extra = judgement.maybeInFlight.subtracting(expected.maybe), missing = expected.maybe.subtracting(judgement.maybeInFlight)
            #expect(judgement.maybeInFlight == expected.maybe, "seed \(seed), maybe: extra \(extra), missing \(missing)")
            for rule in 0..<4 { byRule[rule] += expected.byRule[rule].count }
            maybe += expected.maybe.count
        }
        // Every rule had photos to judge, and some were maybe taken in flight.
        #expect(byRule.allSatisfy { $0 > 0 } && maybe > 0, "\(byRule), maybe \(maybe)")
        // The flights of the realistic library too.
        let library = MapLibrary(count: 6_000, seed: 3).facts.map(\.asset)
        let reference = Self.reference(library)
        #expect(AirborneFilter.airborne(library) == reference.all)
        #expect(AirborneFilter.judge(library).maybeInFlight == reference.maybe)
        // A photo every three seconds for half an hour in flight (the search for a location coming
        // back passes them by the way flown), and evenings of a location jumping around indoors.
        let dense = Self.flight("every-3s", from: Self.munichAirport, to: Self.lisbonAirport, takeoff: MapFixture.date("2024-05-05 08:00"),
                                gate: [40], arrival: [30]) { _ in Array(stride(from: 10.0, to: 40.0, by: 0.05)) }
        #expect(AirborneFilter.airborne(dense.photos) == dense.window)
        #expect(Self.reference(dense.photos).all == dense.window)
        let indoors = Self.jumpingIndoors()
        #expect(AirborneFilter.airborne(indoors) == Self.reference(indoors).all)
    }
}
