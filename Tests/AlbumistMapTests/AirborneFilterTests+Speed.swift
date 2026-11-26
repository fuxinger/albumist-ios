import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Speed: a library of 50,000 photos and a dense one (weddings, evenings whose location jumps
/// between spots or lands kilometres off) are judged quickly.
extension AirborneFilterTests {
    // MARK: Speed

    @Test func fiftyThousandPhotosAreJudgedQuickly() {
        let photos = MapLibrary(count: 50_000).facts.map(\.asset)
        let clock = ThreadCPUClock()
        var result = FlightJudgement()
        // As the summary judges them: with the photos maybe taken in flight.
        let elapsed = clock.measure { result = AirborneFilter.judge(photos) }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "AIRBORNE_PERF photos %d: %.1f ms, %d in flight, %d maybe", photos.count, ms, result.airborne.count,
                     result.maybeInFlight.count))
        #expect(result.airborne.count > 1_000)
        // A debug build on a shared machine is several times slower than the app; the bound only
        // catches a search that reads every photo of a burst for every photo of it.
        #expect(ms < 2_000)
    }

    /// Thousands of day trips, weddings of 3,000 photos in an afternoon, evenings of 2,500 photos
    /// whose location jumps between three spots 1.6 to 2.4 km apart every few seconds, one of them
    /// right after a photo on the far side of the world (a leg of the length of a long-haul flight,
    /// so no photo of the evening can rule out a fast leg by the steps alone), and evenings of
    /// 2,000 photos whose location lands 1 to 3 km off in any direction.
    static func denseLibrary(count: Int) -> [AssetSnapshot] {
        var random = MapRandom(seed: 99)
        var photos: [AssetSnapshot] = []
        let home = Places.regensburg
        var day = MapFixture.date("2016-01-01").timeIntervalSinceReferenceDate
        func add(_ time: Double, _ coordinate: GeoCoordinate) {
            photos.append(shot("dense-\(photos.count)", Date(timeIntervalSinceReferenceDate: time), coordinate))
        }
        var n = 0
        while photos.count < count {
            n += 1
            add(day + 7 * 3_600, Fixture.jitter(home, seed: n, meters: 200))
            if n % 30 == 0 {
                var time = day + 14 * 3_600
                for k in 0..<3_000 {
                    time += 2 + random.unit() * 5
                    add(time, Fixture.jitter(Self.offset(home, km: 12, bearing: 30), seed: k, meters: 300))
                }
            } else if n % 20 == 0 {
                let hall = Self.offset(home, km: 25, bearing: 160)
                var time = day + 18 * 3_600
                for _ in 0..<2_000 {
                    time += 2 + random.unit() * 28
                    add(time, Self.offset(hall, km: 1 + random.unit() * 2, bearing: random.unit() * 360))
                }
            } else if n % 15 == 0 {
                if n % 45 == 0 { add(day + 1 * 3_600, Places.tokyo) }
                let hall = Self.offset(home, km: 20, bearing: 80)
                let spots = [hall, Self.offset(hall, km: 2.4, bearing: 0), Self.offset(hall, km: 1.6, bearing: 120)]
                var time = day + 9 * 3_600
                for k in 0..<2_500 {
                    time += 3 + random.unit() * 12
                    add(time, Fixture.jitter(spots[random.int(0..<3)], seed: k, meters: 300))
                }
            } else {
                let spot = Self.offset(home, km: 30 + random.unit() * 120, bearing: random.unit() * 360)
                for k in 0..<15 { add(day + 10 * 3_600 + Double(k) * 600, Fixture.jitter(spot, seed: k + n, meters: 1_500)) }
            }
            add(day + 21 * 3_600, Fixture.jitter(home, seed: n + 1, meters: 200))
            day += 86_400
        }
        return photos
    }

    @Test func aDenseLibraryIsJudgedQuickly() {
        let photos = Self.denseLibrary(count: 50_000)
        let clock = ThreadCPUClock()
        var result = FlightJudgement()
        let elapsed = clock.measure { result = AirborneFilter.judge(photos) }
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "AIRBORNE_PERF dense photos %d: %.1f ms, %d in flight, %d maybe %@", photos.count, ms, result.airborne.count,
                     result.maybeInFlight.count, result.maybeInFlight.sorted().prefix(5).map(\.rawValue).joined(separator: " ")))
        // All on the ground (the photo on the far side of the world is a wrong location: one leg,
        // faster than a plane), and they all count.
        #expect(result == FlightJudgement())
        // Before the search stopped after a minute of photos near the photo, the evening after the
        // far photo took about ten seconds here.
        #expect(ms < 2_000)
    }
}
