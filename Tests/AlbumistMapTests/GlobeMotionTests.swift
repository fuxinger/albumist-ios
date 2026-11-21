import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The gestures and motions of our own globe (`GlobeDrag`, `GlobeInertia`, `GlobeFlight`,
/// `GlobeMotion`): the grabbed point stays under the finger, pinch and double tap zoom as Apple's
/// maps do, a flick coasts out the same at any frame rate, flights land exactly, and the handover
/// to Apple's map happens once until a jump brings the globe back.
@Suite("Globe motion")
struct GlobeMotionTests {
    static let width = 390.0, height = 844.0

    func camera(_ latitude: Double, _ longitude: Double, _ meters: Double) -> GlobeCamera {
        GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: longitude), widthMeters: meters)
    }

    func optics(_ camera: GlobeCamera) -> GlobeOptics {
        GlobeOptics(camera: camera, widthPoints: Self.width, heightPoints: Self.height)
    }

    func degrees(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        GlobeVector(a).angle(to: GlobeVector(b)) * 180 / .pi
    }

    func motion(_ camera: GlobeCamera) -> GlobeMotion {
        var motion = GlobeMotion(camera: camera)
        motion.widthPoints = Self.width
        motion.heightPoints = Self.height
        return motion
    }

    // MARK: Drag

    @Test(arguments: [(30.0, 10.0, GlobeCamera.wholeEarth.widthMeters), (50, 10, 5_000_000), (78, -40, 6_000_000), (-20, 179.9, 4_000_000),
                      (0, -179.99, 3_100_000), (-70, 60, 9_000_000)])
    func theGrabbedPointStaysUnderTheFinger(latitude: Double, longitude: Double, meters: Double) throws {
        let start = optics(camera(latitude, longitude, meters))
        let path: [(Double, Double)] = [(195, 422), (160, 380), (240, 470), (215, 360), (120, 520), (200, 430)]
        var drag = GlobeDrag(atX: path[0].0, y: path[0].1, optics: start)
        let grabbed = try #require(drag.grabbed)
        var current = start
        var held = 0
        for (x, y) in path.dropFirst() {
            // Where north up can bring the point under the finger, it is there; else the globe
            // turns in proportion and holds a new point.
            let possible = current.cameraPlacing(grabbed, atX: x, y: y, minimumHorizonMargin: GlobeDrag.minimumHorizonMargin)
            let camera = drag.move(toX: x, y: y, optics: current)
            current = optics(camera)
            #expect(camera.widthMeters == start.camera.widthMeters)
            guard let possible else { break }
            #expect(camera == possible && drag.grabbed == grabbed)
            guard abs(camera.center.latitude) < GlobeOptics.latitudeLimit else { continue }
            let under = try #require(current.unproject(x: x, y: y))
            #expect(degrees(under, grabbed) < 1e-6, "\(x), \(y)")
            held += 1
        }
        #expect(held >= 2)
    }

    /// Near a pole the drag never flips the globe over it: between two moves of a few points the
    /// centre moves a few degrees, not round the pole.
    @Test func dragsNearAPoleNeverFlipTheGlobe() {
        for start in [camera(80, -40, 6_000_000), camera(-82, 100, 9_000_000), camera(84.9, 0, GlobeCamera.wholeEarth.widthMeters)] {
            var current = optics(start)
            var drag = GlobeDrag(atX: 195, y: 422, optics: current)
            var x = 195.0, y = 422.0
            for step in 0..<200 {
                let angle = Double(step) * 0.13
                x += 6 * cos(angle)
                y += 6 * sin(angle * 0.7)
                let before = current.camera.center
                current = optics(drag.move(toX: x, y: y, optics: current))
                #expect(degrees(before, current.camera.center) < 8, "\(step)")
                #expect(abs(current.camera.center.latitude) <= GlobeOptics.latitudeLimit)
            }
        }
    }

    @Test func offTheDiscTheGlobeTurnsInProportion() {
        let start = optics(GlobeCamera.wholeEarth)
        // Top left corner: space, not the Earth.
        var drag = GlobeDrag(atX: 10, y: 100, optics: start)
        #expect(drag.grabbed == nil)
        let turned = drag.move(toX: 40, y: 100, optics: start)
        let rate = start.radiansPerPoint * 180 / .pi
        let expected = start.camera.center.longitude - 30 * rate / cos(start.camera.center.latitude * .pi / 180)
        #expect(abs(turned.center.longitude - expected) < 1e-9 && turned.center.latitude == start.camera.center.latitude)
        // Down shows the north.
        var down = GlobeDrag(atX: 10, y: 100, optics: start)
        #expect(down.move(toX: 10, y: 120, optics: start).center.latitude > start.camera.center.latitude)
    }

    @Test func nearTheHorizonTheFingerHoldsNoPoint() {
        let start = optics(GlobeCamera.wholeEarth)
        // On the centre line just inside the disc's edge (80 % of the width).
        let edge = Self.width / 2 + 0.795 * Self.width / 2
        #expect(start.unproject(x: edge, y: Self.height / 2) != nil)
        let drag = GlobeDrag(atX: edge, y: Self.height / 2, optics: start)
        #expect(drag.grabbed == nil)
        // Dragging the centre to the edge of the disc lets go of the point and turns on in proportion.
        var centre = GlobeDrag(atX: Self.width / 2, y: Self.height / 2, optics: start)
        var current = start
        for x in stride(from: Self.width / 2, through: Self.width, by: 5) {
            current = optics(centre.move(toX: x, y: Self.height / 2, optics: current))
            #expect(current.camera.center.longitude.isFinite)
        }
        #expect(centre.grabbed == nil || current.project(centre.grabbed!).horizonMargin >= GlobeDrag.minimumHorizonMargin - 1e-9)
    }

    @Test func dragsCrossTheDateLineAndStopAtThePoles() {
        // Dragging left shows what lies east: across the date line.
        var current = optics(camera(10, 179, 5_000_000))
        var drag = GlobeDrag(atX: 195, y: 422, optics: current)
        for x in stride(from: 195.0, through: 0, by: -10) {
            current = optics(drag.move(toX: x, y: 422, optics: current))
        }
        #expect(current.camera.center.longitude < -150 && current.camera.center.longitude > -180)
        // Dragging down far enough reaches the latitude limit and stays there, never further.
        var north = optics(camera(60, 0, 8_000_000))
        var up = GlobeDrag(atX: 195, y: 200, optics: north)
        for y in stride(from: 200.0, through: 3_000, by: 25) {
            north = optics(up.move(toX: 195, y: y, optics: north))
            #expect(north.camera.center.latitude <= GlobeOptics.latitudeLimit && north.camera.center.latitude.isFinite)
        }
        #expect(north.camera.center.latitude == GlobeOptics.latitudeLimit)
        var broken = GlobeDrag(atX: .nan, y: 3, optics: north)
        #expect(broken.move(toX: .infinity, y: 2, optics: north) == north.camera)
    }

    // MARK: Pinch and double tap

    @Test func pinchingDividesTheWidth() throws {
        let start = optics(camera(45, 10, 8_000_000))
        #expect(start.pinched(startWidth: 8_000_000, scale: 2, grabbed: nil, atX: 195, y: 422).widthMeters == 4_000_000)
        #expect(start.pinched(startWidth: 8_000_000, scale: 0.5, grabbed: nil, atX: 195, y: 422).widthMeters == 16_000_000)
        for broken in [0.0, -2, .nan, .infinity] {
            #expect(start.pinched(startWidth: 8_000_000, scale: broken, grabbed: nil, atX: 195, y: 422).widthMeters == 8_000_000)
        }
        #expect(start.pinched(startWidth: 8_000_000, scale: 1e-9, grabbed: nil, atX: 195, y: 422).widthMeters == GlobeCamera.maximumWidthMeters)
        #expect(start.pinched(startWidth: 8_000_000, scale: 1e9, grabbed: nil, atX: 195, y: 422).widthMeters == GlobeCamera.minimumWidthMeters)
        // The point under the fingers' centre stays there.
        let grabbed = try #require(start.unproject(x: 250, y: 300))
        let pinched = optics(start.pinched(startWidth: 8_000_000, scale: 1.6, grabbed: grabbed, atX: 250, y: 300))
        #expect(pinched.camera.widthMeters == 5_000_000)
        #expect(degrees(try #require(pinched.unproject(x: 250, y: 300)), grabbed) < 1e-6)
        // Moving the fingers while pinching drags the point along.
        let moved = optics(start.pinched(startWidth: 8_000_000, scale: 1.2, grabbed: grabbed, atX: 220, y: 340))
        #expect(degrees(try #require(moved.unproject(x: 220, y: 340)), grabbed) < 1e-6)
    }

    @Test func aDoubleTapHalvesTheWidthAtTheTappedPoint() throws {
        let start = optics(camera(50, 10, 6_000_000))
        let tapped = try #require(start.unproject(x: 120, y: 360))
        let target = start.doubleTapTarget(atX: 120, y: 360)
        #expect(target.widthMeters == 3_000_000)
        #expect(degrees(try #require(optics(target).unproject(x: 120, y: 360)), tapped) < 1e-6)
        // Off the disc: in on the centre.
        let whole = optics(GlobeCamera.wholeEarth)
        let space = whole.doubleTapTarget(atX: 5, y: 30)
        #expect(space.center == whole.camera.center && space.widthMeters == whole.camera.widthMeters / 2)
    }

    // MARK: Inertia

    @Test func coastingDecaysAndStopsAlikeAtAnyFrameRate() {
        let start = optics(camera(20, 0, GlobeCamera.wholeEarth.widthMeters))
        func coast(frames perSecond: Double) -> (camera: GlobeCamera, seconds: Double) {
            var inertia = GlobeInertia(latitudeSpeed: 0, longitudeSpeed: -120)
            var current = start
            var seconds = 0.0, lastSpeed = Double.infinity
            while seconds < 20 {
                let step = inertia.advance(current, by: 1 / perSecond)
                current = optics(step.camera)
                seconds += 1 / perSecond
                let speed = abs(inertia.longitudeSpeed)
                #expect(speed < lastSpeed)
                lastSpeed = speed
                if step.isFinished { break }
            }
            return (current.camera, seconds)
        }
        let at60 = coast(frames: 60), at120 = coast(frames: 120)
        #expect(at60.seconds < 5 && at120.seconds < 5)
        // The whole way is close to speed × time constant (−54°) and the same at both rates.
        let travelled60 = MapHome.normalizedLongitude(at60.camera.center.longitude)
        let travelled120 = MapHome.normalizedLongitude(at120.camera.center.longitude)
        #expect(abs(travelled60 + 54) < 3 && abs(travelled120 + 54) < 3)
        #expect(abs(travelled60 - travelled120) < 0.6)
        #expect(at60.camera.center.latitude == 20)
        // Broken speeds do not move anything.
        var broken = GlobeInertia(latitudeSpeed: .nan, longitudeSpeed: .infinity)
        let step = broken.advance(start, by: 1.0 / 60)
        #expect(step.camera == start.camera && step.isFinished)
        var zero = GlobeInertia(latitudeSpeed: 30, longitudeSpeed: 0)
        #expect(zero.advance(start, by: .nan).camera == start.camera)
        // Coasting north stops at the latitude limit.
        var north = GlobeInertia(latitudeSpeed: 400, longitudeSpeed: 0)
        let far = north.advance(optics(camera(80, 0, 9_000_000)), by: 0.5)
        #expect(far.camera.center.latitude == GlobeOptics.latitudeLimit && north.latitudeSpeed == 0)
    }

    @Test func lettingGoCoastsOnAtTheDragsSpeed() throws {
        var motion = motion(GlobeCamera.wholeEarth)
        motion.beginDrag(atX: 195, y: 422)
        motion.moveDrag(toX: 215, y: 422)
        let before = motion.camera
        motion.endDrag(velocityX: 600, velocityY: 0)
        #expect(motion.isCoasting && motion.isMoving)
        motion.advance(by: 1.0 / 60)
        // Flicked right: the globe keeps turning the same way, showing what lies west.
        #expect(motion.camera.center.longitude < before.center.longitude)
        // The first frame moves about as far as the finger would have moved the grabbed point.
        let drag = GlobeDrag(atX: 215, y: 422, optics: optics(before))
        var probe = drag
        let expected = probe.move(toX: 225, y: 422, optics: optics(before))
        let moved = before.center.longitude - motion.camera.center.longitude
        let wanted = before.center.longitude - expected.center.longitude
        #expect(abs(moved - wanted) / wanted < 0.1)
        for _ in 0..<1_000 where motion.isCoasting { motion.advance(by: 1.0 / 120) }
        #expect(!motion.isCoasting && !motion.isMoving)
        // A finger that stopped before letting go starts no coasting.
        motion.beginDrag(atX: 195, y: 422)
        motion.moveDrag(toX: 200, y: 422)
        motion.endDrag(velocityX: 10, velocityY: 5)
        #expect(!motion.isCoasting)
        motion.beginDrag(atX: 195, y: 422)
        motion.endDrag(velocityX: .nan, velocityY: 3)
        #expect(!motion.isCoasting)
    }

    // MARK: Flight

    @Test func flightsLandExactlyAlongTheGreatCircle() {
        let from = camera(49, 12, 9_000_000), to = camera(64, -19, 4_000_000)
        let flight = GlobeFlight(from: from, to: to, duration: 2)
        #expect(flight.camera(at: 0) == from && flight.camera(at: -1) == from)
        #expect(flight.camera(at: 2) == to && flight.camera(at: 5) == to && flight.camera(at: .nan) == to)
        #expect(!flight.isFinished(at: 1.9) && flight.isFinished(at: 2))
        // Half way the centre is the great circle's middle, the width (a short flight) the geometric mean.
        let middle = flight.camera(at: 1)
        let wanted = GlobeArcGeometry.slerp(GlobeVector(from.center), GlobeVector(to.center), 0.5).coordinate
        #expect(degrees(middle.center, wanted) < 1e-9)
        #expect(abs(middle.widthMeters - (9_000_000.0 * 4_000_000).squareRoot()) < 1)
        // Every step lies on the great circle between the two.
        let whole = GlobeVector(from.center).angle(to: GlobeVector(to.center))
        for i in 1..<20 {
            let c = flight.camera(at: Double(i) / 10).center
            let along = GlobeVector(from.center).angle(to: GlobeVector(c)) + GlobeVector(c).angle(to: GlobeVector(to.center))
            #expect(abs(along - whole) < 1e-9)
        }
    }

    @Test func longFlightsRiseInTheMiddle() {
        let flight = GlobeFlight(from: camera(49, 12, 3_500_000), to: camera(-33.9, 151.2, 3_500_000), duration: 3)
        let middle = flight.camera(at: 1.5)
        #expect(middle.widthMeters > 3 * 3_500_000)
        #expect(middle.widthMeters <= GlobeCamera.wholeEarth.widthMeters * (1 + 1e-12))
        #expect(abs(flight.middleWidthMeters - middle.widthMeters) < 1)
        // The width rises and falls smoothly: no jump between frames.
        var last = flight.camera(at: 0).widthMeters
        for i in 1...300 {
            let width = flight.camera(at: 3 * Double(i) / 300).widthMeters
            #expect(abs(log(width) - log(last)) < 0.05)
            last = width
        }
        // Across the date line the short way round.
        let dateLine = GlobeFlight(from: camera(-17, 170, 5_000_000), to: camera(-17, -170, 5_000_000), duration: 1)
        #expect(abs(abs(dateLine.camera(at: 0.5).center.longitude) - 180) < 0.01)
        // From one side of the Earth to the other: a defined path, never a number that is none.
        let opposite = GlobeFlight(from: camera(0, 0, 5_000_000), to: camera(0, 180, 5_000_000), duration: 1)
        for i in 0...10 {
            let c = opposite.camera(at: Double(i) / 10)
            #expect(c.center.latitude.isFinite && c.center.longitude.isFinite && c.widthMeters.isFinite)
        }
        // No duration, or a broken one: there at once.
        for duration in [0.0, -1, .nan, .infinity] {
            let instant = GlobeFlight(from: camera(0, 0, 5_000_000), to: camera(10, 10, 4_000_000), duration: duration)
            #expect(instant.duration == 0 && instant.camera(at: 0) == instant.to)
        }
        // The easing starts and lands softly.
        #expect(GlobeFlight.ease(0) == 0 && GlobeFlight.ease(1) == 1 && GlobeFlight.ease(0.5) == 0.5)
        var previous = 0.0
        for i in 1...100 {
            let e = GlobeFlight.ease(Double(i) / 100)
            #expect(e >= previous)
            previous = e
        }
        #expect(GlobeFlight.ease(0.01) < 0.001 && GlobeFlight.ease(-3) == 0 && GlobeFlight.ease(.nan) == 1)
    }

    // MARK: The globe's state

    @Test func theHandoverHappensOnceUntilAJumpBringsTheGlobeBack() throws {
        var motion = motion(camera(64, -19, 4_000_000))
        #expect(motion.takeHandover() == nil)
        motion.beginPinch(atX: 195, y: 422)
        motion.movePinch(scale: 1.2, atX: 195, y: 422)
        let early = motion.takeHandover()
        #expect(!motion.isHandedOver && early == nil)
        motion.movePinch(scale: 2, atX: 195, y: 422)
        let taken = motion.takeHandover()
        let handover = try #require(taken)
        #expect(handover.widthMeters == 2_000_000 && motion.isHandedOver)
        let again = motion.takeHandover()
        #expect(again == nil)
        // Nothing moves the globe now.
        motion.movePinch(scale: 3, atX: 195, y: 422)
        motion.isAutoRotating = true
        motion.advance(by: 0.1)
        motion.beginDrag(atX: 100, y: 100)
        motion.moveDrag(toX: 200, y: 300)
        motion.fly(to: GlobeCamera.wholeEarth, duration: 1)
        motion.doubleTap(atX: 195, y: 422)
        let none = motion.takeHandover()
        #expect(motion.camera == handover && !motion.isMoving && none == nil)
        // Back from Apple's map: armed again.
        motion.isAutoRotating = false
        motion.jump(to: camera(64, -19, 3_300_000))
        let afterJump = motion.takeHandover()
        #expect(!motion.isHandedOver && afterJump == nil)
        motion.beginPinch(atX: 195, y: 422)
        motion.movePinch(scale: 1.25, atX: 195, y: 422)
        let second = motion.takeHandover()
        #expect(second?.widthMeters == 2_640_000)
        // A jump below the handover width hands over at once.
        motion.jump(to: camera(64, -19, 1_000_000))
        let third = motion.takeHandover()
        #expect(motion.isHandedOver && third?.widthMeters == 1_000_000)
        // So does a first camera below it.
        var close = GlobeMotion(camera: camera(64, -19, 500_000))
        let first = close.takeHandover()
        #expect(first?.widthMeters == 500_000)
    }

    @Test func aFlightBelowTheHandoverWidthHandsOver() throws {
        var motion = motion(GlobeCamera.wholeEarth)
        motion.fly(to: camera(64, -19, 1_000_000), duration: 2)
        #expect(motion.isFlying && motion.isMoving)
        var frames = 0
        while !motion.isHandedOver, frames < 1_000 {
            motion.advance(by: 1.0 / 120)
            frames += 1
        }
        let taken = motion.takeHandover()
        let handover = try #require(taken)
        #expect(handover.widthMeters < GlobeCamera.handoverWidthMeters && handover.widthMeters > 2_500_000)
        #expect(!motion.isFlying && frames < 240)
        // A double tap is a short flight to half the width.
        var tap = self.motion(camera(48, 11, 8_000_000))
        tap.doubleTap(atX: 195, y: 422)
        #expect(tap.isFlying)
        for _ in 0..<60 { tap.advance(by: 1.0 / 60) }
        #expect(!tap.isFlying && abs(tap.camera.widthMeters - 4_000_000) < 1e-6)
        // A flight of no length lands at once.
        tap.fly(to: camera(10, 10, 9_000_000), duration: 0)
        #expect(!tap.isFlying && tap.camera == camera(10, 10, 9_000_000))
    }

    @Test func theSpinTurnsWestwardsTenDegreesASecond() {
        var motion = motion(camera(30, 10, GlobeCamera.wholeEarth.widthMeters))
        #expect(!motion.isMoving)
        motion.isAutoRotating = true
        #expect(motion.isMoving)
        for _ in 0..<120 { motion.advance(by: 1.0 / 120) }
        #expect(abs(motion.camera.center.longitude - 0) < 1e-9 && motion.camera.center.latitude == 30)
        // Round the date line and on.
        for _ in 0..<(120 * 19) { motion.advance(by: 1.0 / 120) }
        #expect(abs(motion.camera.center.longitude - 170) < 1e-6)
        // A finger on the globe holds it still.
        motion.beginDrag(atX: 195, y: 422)
        let held = motion.camera
        motion.advance(by: 0.1)
        #expect(motion.camera == held)
        motion.endDrag(velocityX: 0, velocityY: 0)
        motion.advance(by: 0.1)
        #expect(motion.camera.center.longitude < held.center.longitude)
        // A long or broken frame moves at most a quarter second.
        let before = motion.camera.center.longitude
        motion.advance(by: 30)
        #expect(abs(before - motion.camera.center.longitude - 2.5) < 1e-9)
        let still = motion.camera
        for broken in [Double.nan, -1, .infinity] { motion.advance(by: broken) }
        #expect(motion.camera == still)
    }

    @Test func aJumpEndsEveryMotion() {
        var motion = motion(GlobeCamera.wholeEarth)
        motion.fly(to: camera(0, 100, 5_000_000), duration: 3)
        motion.advance(by: 0.5)
        motion.jump(to: camera(-10, -60, 7_000_000))
        #expect(!motion.isFlying && !motion.isMoving && motion.camera == camera(-10, -60, 7_000_000))
        motion.jump(to: GlobeCamera(center: GeoCoordinate(latitude: .nan, longitude: 0), widthMeters: .infinity))
        #expect(motion.camera == GlobeCamera.wholeEarth)
    }
}
