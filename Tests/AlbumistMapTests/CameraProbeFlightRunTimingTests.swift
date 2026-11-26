import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// Edge cases of a probe flight's timing (`CameraProbeFlightRun`), found by the second check of
/// 25.11.2026: a camera set while MapKit was still rendering, a flight whose last rendering was
/// not whole, and a flight the app left in the middle.
@Suite("Camera probe flight timing")
struct CameraProbeFlightRunTimingTests {
    @Test func aRenderingAlreadyRunningWhenTheCameraIsSetStillCountsForTheStart() {
        // MapKit sends no second "will start" for a camera set mid-rendering: its next whole
        // finish is the start map, not a 12-s wait.
        var run = CameraProbeFlightRun(shownAt: 10, renderingInProgress: true)
        run.renderingFinished(at: 11.5, fully: true)
        #expect(run.readyToTakeOff)
        #expect(run.startReadySeconds == 1.5)
    }

    @Test func withoutARenderingRunningTheStartWaitsForANewOne() {
        var run = CameraProbeFlightRun(shownAt: 10)
        run.renderingFinished(at: 11, fully: true)
        #expect(run.readyToTakeOff == false)
    }

    @Test func aFlightWhoseLastRenderingWasNotWholeIsNotReadyAfterTheLanding() {
        var run = CameraProbeFlightRun(shownAt: 0)
        run.renderingStarted(at: 0.1)
        run.renderingFinished(at: 1, fully: true)
        run.takeOff(at: 1)
        run.renderingStarted(at: 5)
        run.renderingFinished(at: 9, fully: false)
        run.land(at: 11.4)
        run.settle(at: 12)
        #expect(run.phase == .done)
        #expect(run.landedReadySeconds == nil)
    }

    @Test func aFlightWhoseLastRenderingWasWholeIsReadyAtTheLanding() {
        var run = CameraProbeFlightRun(shownAt: 0)
        run.renderingStarted(at: 0.1)
        run.renderingFinished(at: 1, fully: true)
        run.takeOff(at: 1)
        run.renderingStarted(at: 5)
        run.renderingFinished(at: 9, fully: true)
        run.land(at: 11.4)
        run.settle(at: 12)
        #expect(run.landedReadySeconds == 0)
    }

    @Test func aFlightTheAppLeftGivesNoMeasurement() {
        var run = CameraProbeFlightRun(shownAt: 0)
        run.renderingStarted(at: 0.1)
        run.renderingFinished(at: 1, fully: true)
        run.takeOff(at: 1)
        run.frame(at: 1.1, expected: 1.0 / 60)
        run.abandon()
        #expect(run.phase == .abandoned)
        run.land(at: 300)
        run.settle(at: 301)
        #expect(run.result(network: nil, heat: MapMeasurements.Thermal(level: 0)) == nil)
    }
}
