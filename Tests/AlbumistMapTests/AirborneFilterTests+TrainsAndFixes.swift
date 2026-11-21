import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Trains, cars and jumping fixes stay on the ground: fast trains and a car on the Autobahn, a
/// location jumping kilometres indoors, GPS errors, a fix closing in, zig-zags and a photo off
/// the way.
extension AirborneFilterTests {
    /// Photos on a train from Paris to Lyon at `kmh`, one every 1 to 10 minutes and two series of
    /// six photos one and two seconds apart, each within 25 m of the train.
    static func train(_ kmh: Double) -> [AssetSnapshot] {
        let meters = GeoMath.distance(parisGareDeLyon, lyonPartDieu), seconds = meters / (kmh / 3.6)
        let start = MapFixture.date("2023-07-01 08:00")
        var times: [Double] = []
        var t = 0.0, k = 0
        while t <= seconds {
            times.append(t)
            k += 1
            t += Double(1 + k * 7 % 10) * 60
        }
        for s in 0..<6 {
            times.append(600 + Double(s))
            times.append(1_500 + Double(s) * 2)
        }
        return times.enumerated().map { i, t in
            shot("tgv\(Int(kmh))-\(i)", start.addingTimeInterval(t), Fixture.jitter(along(parisGareDeLyon, lyonPartDieu, t / seconds), seed: i, meters: 50))
        }
    }

    @Test func fastTrainsStayOnTheGround() {
        for kmh in [300.0, 320, 350] {
            let photos = Self.train(kmh)
            #expect(photos.count >= 24)
            #expect(AirborneFilter.airborne(photos).isEmpty, "\(kmh)")
            // Nor maybe in flight: they all count.
            #expect(AirborneFilter.judge(photos) == FlightJudgement(), "\(kmh)")
        }
    }

    @Test func aCarOnTheAutobahnStaysOnTheGround() {
        // Munich → Nuremberg at 200 km/h, a photo every 1 to 5 minutes and a series of five.
        let meters = GeoMath.distance(Places.munich, Self.nuremberg), seconds = meters / (200 / 3.6)
        let start = MapFixture.date("2023-07-02 10:00")
        let times = Array(stride(from: 0.0, through: seconds, by: 75)) + (0..<5).map { 1_000 + Double($0) }
        let photos = times.enumerated().map { i, t in
            Self.shot("car-\(i)", start.addingTimeInterval(t), Fixture.jitter(Self.along(Places.munich, Self.nuremberg, t / seconds), seed: i, meters: 60))
        }
        #expect(AirborneFilter.judge(photos) == FlightJudgement())
    }

    @Test func aLocationJumpingKilometresIndoorsStaysOnTheGround() {
        #expect(AirborneFilter.airborne(Self.jumpingIndoors()).isEmpty)

        // A minute of photos near one spot, a jump 3 km on and another 3 km on in a straight line
        // within seconds, a minute of photos near the far end: two legs at a plane's speed, but
        // from and to a stay.
        let a = MapFixture.at(48.2000, 11.6000), c = Self.offset(a, km: 3.1, bearing: 90), e = Self.offset(c, km: 3.1, bearing: 90)
        let t0 = MapFixture.date("2024-02-03 10:00")
        var line = (0..<8).map {
            Self.shot("a-\($0)", t0.addingTimeInterval(Double($0) * 10), Fixture.jitter(Self.offset(a, km: 1.2, bearing: 270), seed: $0, meters: 300))
        }
        line += [Self.shot("a", t0.addingTimeInterval(80), a), Self.shot("c", t0.addingTimeInterval(90), c), Self.shot("e", t0.addingTimeInterval(100), e)]
        line += (0..<8).map {
            Self.shot("e-\($0)", t0.addingTimeInterval(110 + Double($0) * 10), Fixture.jitter(Self.offset(e, km: 1.2, bearing: 90), seed: $0, meters: 300))
        }
        #expect(AirborneFilter.airborne(line).isEmpty)
        // Documented: the same three photos alone, without a photo near either end, are just what
        // three window photos ten seconds apart look like.
        #expect(AirborneFilter.airborne(Array(line[8..<11])) == ["a", "c", "e"])
    }

    /// An evening indoors whose location jumps between three spots 1.5 to 2.5 km apart, then one
    /// whose location lands 1 to 3 km off in any direction, every few seconds.
    static func jumpingIndoors() -> [AssetSnapshot] {
        var random = MapRandom(seed: 11)
        let hall = MapFixture.at(48.1500, 11.5500)
        // Three spots 1.5 to 2.5 km apart, a photo every 2 to 20 seconds for two hours.
        let spots = [hall, Self.offset(hall, km: 2.4, bearing: 0), Self.offset(hall, km: 1.6, bearing: 120)]
        var time = MapFixture.date("2024-02-02 18:00").timeIntervalSinceReferenceDate
        var photos: [AssetSnapshot] = []
        while photos.count < 900 {
            time += 2 + random.unit() * 18
            photos.append(Self.shot("spots-\(photos.count)", Date(timeIntervalSinceReferenceDate: time),
                                    Fixture.jitter(spots[random.int(0..<3)], seed: photos.count, meters: 200)))
        }
        // Evenings whose location lands 1 to 3 km off in any direction, a photo every 2 to 30
        // (on the last evening 2 to 60) seconds, with photos before and after at home 15 km away.
        // Without `returnDuration` one photo in some 400 of these looked like a flight.
        for evening in 0..<6 {
            let home = Self.offset(hall, km: 15, bearing: 250)
            time += 20 * 3_600
            photos.append(Self.shot("home-before-\(evening)", Date(timeIntervalSinceReferenceDate: time), home))
            time += 3_600
            for k in 0..<1_000 {
                time += 2 + random.unit() * (evening == 5 ? 58 : 28)
                photos.append(Self.shot("jitter-\(evening)-\(k)", Date(timeIntervalSinceReferenceDate: time),
                                        Self.offset(hall, km: 1 + random.unit() * 2, bearing: random.unit() * 360)))
            }
            time += 3_600
            photos.append(Self.shot("home-after-\(evening)", Date(timeIntervalSinceReferenceDate: time), home))
        }
        return photos
    }

    /// A step of a fix in `gpsErrorsMakeNoSeries`: seconds after the photo before, and how far the
    /// fix moves on (kilometres) and which way (degrees clockwise from north).
    struct FixStep {
        var seconds: Double
        var km: Double
        var bearing: Double

        init(_ seconds: Double, _ km: Double, _ bearing: Double) {
            self.seconds = seconds
            self.km = km
            self.bearing = bearing
        }
    }

    /// Rule 3 against GPS errors: a fix jumping away and back, a coarse fix closing in on the true
    /// place, a slow drift indoors, and a steady slide with its stated accuracy.
    @Test func gpsErrorsMakeNoSeries() {
        let t0 = MapFixture.date("2024-03-03 12:00"), here = MapFixture.at(48.3000, 11.4000)
        func series(_ name: String, _ steps: [FixStep], accuracy: Double? = nil) -> [AssetSnapshot] {
            var position = here, time = t0
            var photos = [Self.shot("\(name)-0", time, position, accuracy: accuracy)]
            for (k, step) in steps.enumerated() {
                position = Self.offset(position, km: step.km, bearing: step.bearing)
                time = time.addingTimeInterval(step.seconds)
                photos.append(Self.shot("\(name)-\(k + 1)", time, position, accuracy: accuracy))
            }
            return photos
        }
        // Away 700 m and back, every 2 seconds (1,260 km/h each step).
        let jumping = series("jump", (0..<7).map { FixStep(2, 0.7, $0 % 2 == 0 ? 60 : 240) })
        // Closing in: 800, 520, 340, 220 and 140 m, 2 seconds apart, in one direction.
        let closing = series("close", [FixStep(2, 0.8, 10), FixStep(2, 0.52, 10), FixStep(2, 0.34, 10), FixStep(2, 0.22, 10), FixStep(2, 0.14, 10)])
        // Drifting at 5 m/s.
        let drift = series("drift", (0..<8).map { _ in FixStep(3, 0.015, 200) })
        // Sliding 400 m every 2 seconds (720 km/h) in a straight line, each fix stating 250 m.
        let stated = series("stated", (0..<4).map { _ in FixStep(2, 0.4, 135) }, accuracy: 250)
        #expect(AirborneFilter.airborne(jumping + closing + drift + stated).isEmpty)
        // Documented: the same slide without a stated accuracy is what a series out of the window
        // at 720 km/h looks like.
        let slide = series("slide", (0..<4).map { _ in FixStep(2, 0.4, 135) })
        #expect(AirborneFilter.airborne(slide) == Set(slide.map(\.id)))
    }

    /// Rule 3 against a coarse fix closing in on the true place: three photos two seconds apart,
    /// 1,500, 900 and 450 m off in one direction (1,080 and 810 km/h, steady and straight on), so
    /// a burst of three, which must head on. Documented: between a photo 40 km behind them and one
    /// 40 km ahead, on their line, they look like three window photos. But not with more photos
    /// at the true place a minute or more after them (here ten minutes, too late for the location
    /// to come back): a stay. Nor between two photos at home: they cannot head away from home and
    /// towards it at once. Nor with the accuracy the iPhone states for such fixes: their steps are
    /// no steps.
    @Test func aFixClosingInOverThreePhotosStaysOnTheGround() {
        let here = MapFixture.at(48.3000, 11.4000), t0 = MapFixture.date("2024-03-04 12:00")
        func closing(_ name: String, accuracy: Bool = false) -> [AssetSnapshot] {
            [1_500.0, 900, 450].enumerated().map { k, off in
                Self.shot("\(name)-\(k)", t0.addingTimeInterval(Double(k) * 2), Self.offset(here, km: off / 1_000, bearing: 30),
                          accuracy: accuracy ? off : nil)
            }
        }
        let line = [Self.shot("behind", t0.addingTimeInterval(-3_600), Self.offset(here, km: 41.5, bearing: 30)),
                    Self.shot("ahead", t0.addingTimeInterval(3_600), Self.offset(here, km: 40, bearing: 210))]
        let slide = closing("slide")
        #expect(AirborneFilter.airborne(line + slide) == Set(slide.map(\.id)))
        let later = (0..<2).map { k in
            Self.shot("later-\(k)", t0.addingTimeInterval(600 + Double(k) * 30), Fixture.jitter(here, seed: k, meters: 30))
        }
        #expect(AirborneFilter.airborne(line + closing("stay") + later).isEmpty)
        let home = Self.offset(here, km: 15, bearing: 250)
        let outing = [Self.shot("home-before", t0.addingTimeInterval(-3 * 3_600), home)] + closing("outing")
            + [Self.shot("home-after", t0.addingTimeInterval(3 * 3_600), home)]
        #expect(AirborneFilter.airborne(outing).isEmpty)
        #expect(AirborneFilter.airborne(line + closing("stated", accuracy: true)).isEmpty)
    }

    @Test func zigZagsOnTheGroundAreNotFlights() {
        // Munich and Rome alternating (fast legs both ways, but no photo lies between its neighbours).
        #expect(AirborneFilter.airborne(Self.alternating(start: "2023-06-15 09:00", count: 40, a: Places.munich, b: Places.rome, minutes: 10)).isEmpty)
        // The same with both photos of a pair in the same second.
        let pairs = (0..<40).map { i in
            Self.shot("pair-\(i)", MapFixture.date("2023-06-16 09:00").addingTimeInterval(Double(i / 2) * 600),
                      Fixture.jitter(i % 2 == 0 ? Places.munich : Places.rome, seed: i, meters: 400))
        }
        #expect(AirborneFilter.airborne(pairs).isEmpty)
        // Two cities close together (Munich and Augsburg, 55 km) alternating every minute.
        let augsburg = MapFixture.at(48.3705, 10.8978)
        let close = (0..<30).map { i in
            Self.shot("close-\(i)", MapFixture.date("2023-06-17 10:00").addingTimeInterval(Double(i) * 60), i % 2 == 0 ? Places.munich : augsburg)
        }
        #expect(AirborneFilter.airborne(close).isEmpty)
    }

    @Test func aPhotoOffTheWayIsNoFlight() {
        // Fast legs Munich → Zurich → Vienna: Zurich is no stop on the way from Munich to Vienna.
        let zurich = MapFixture.at(47.3769, 8.5417), vienna = MapFixture.at(48.2082, 16.3738), linz = MapFixture.at(48.3069, 14.2858)
        let t0 = MapFixture.date("2023-06-20 10:00")
        let detour = [Self.shot("d-0", t0, Places.munich), Self.shot("d-1", t0.addingTimeInterval(1_200), zurich),
                      Self.shot("d-2", t0.addingTimeInterval(2_400), vienna)]
        #expect(AirborneFilter.airborne(detour).isEmpty)
        // Linz lies on the way: the same times make it a photo in flight.
        let straight = [Self.shot("s-0", t0, Places.munich), Self.shot("s-1", t0.addingTimeInterval(1_200), linz),
                        Self.shot("s-2", t0.addingTimeInterval(2_400), vienna)]
        #expect(AirborneFilter.airborne(straight) == ["s-1"])
        // Linz on the way to Tokyo: a leg of 19 hours counts for a single photo, one of more than
        // 20 hours says nothing.
        for (hours, expected) in [(19.0, ["l-1"] as Set<AssetID>), (20.1, [])] {
            let long = [Self.shot("l-0", t0, Places.munich), Self.shot("l-1", t0.addingTimeInterval(1_200), linz),
                        Self.shot("l-2", t0.addingTimeInterval(1_200 + hours * 3_600), Places.tokyo)]
            #expect(AirborneFilter.airborne(long) == expected, "\(hours)")
        }
    }
}
