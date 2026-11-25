import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The globe's state (`GlobeMotion`): the handover to Apple's map happens once until a jump
/// brings the globe back, a flight below the handover width hands over, the spin turns westwards
/// ten degrees a second, a two-finger tap zooms out round the centre, a touch halts flights and
/// coasting but not the spin, and a jump ends every motion.
extension GlobeMotionTests {
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

    @Test func aTwoFingerTapZoomsOutRoundTheCentre() {
        var motion = motion(camera(48, 11, 4_000_000))
        motion.zoomOut()
        #expect(motion.isFlying)
        for _ in 0..<21 { motion.advance(by: 1.0 / 60) }
        #expect(!motion.isFlying && motion.camera == camera(48, 11, 8_000_000))
        // Never beyond the farthest view.
        motion.jump(to: camera(48, 11, GlobeCamera.maximumWidthMeters * 0.8))
        motion.zoomOut()
        for _ in 0..<21 { motion.advance(by: 1.0 / 60) }
        #expect(motion.camera.widthMeters == GlobeCamera.maximumWidthMeters)
    }

    @Test func aTouchHaltsFlightsAndCoastingButNotTheSpin() {
        var motion = motion(GlobeCamera.wholeEarth)
        motion.fly(to: camera(0, 100, 5_000_000), duration: 3)
        motion.advance(by: 1)
        let halted = motion.camera
        motion.halt()
        motion.advance(by: 1)
        #expect(!motion.isFlying && motion.camera == halted)

        motion.beginDrag(atX: 195, y: 422)
        motion.moveDrag(toX: 255, y: 422)
        motion.endDrag(velocityX: 900, velocityY: 0)
        #expect(motion.isCoasting)
        motion.halt()
        let still = motion.camera
        motion.advance(by: 0.1)
        #expect(!motion.isCoasting && motion.camera == still)

        motion.isAutoRotating = true
        motion.halt()
        motion.advance(by: 0.2)
        #expect(motion.isMoving && abs(MapHome.normalizedLongitude(still.center.longitude - motion.camera.center.longitude) - 2) < 1e-9)
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
