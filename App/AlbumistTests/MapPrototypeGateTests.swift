import Foundation
import Testing
import AlbumistMap
@testable import Albumist

/// The map prototype stays out of the App Store build (concept 2.0 §13, wave 0). Second check of
/// 25.11.2026: builds before then kept StoreKit's "TestFlight" answer in the user defaults, so a
/// tester who moved to the App Store build kept seeing the entry, and an offline launch kept the
/// old answer. And the Info.plist made every animation of the app run at 120 Hz for the prototype.
@Suite("Map prototype gate and camera probe")
@MainActor
struct MapPrototypeGateTests {
    @Test func aStoredAnswerFromAnOlderTestFlightBuildDoesNotShowTheEntry() {
        let key = "mapPrototype.isTestFlight"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(MapPrototypeGate.releaseAnswer(nil) == false)
    }

    @Test func onlyStoreKitsAnswerOfThisLaunchCounts() {
        #expect(MapPrototypeGate.releaseAnswer(true))
        #expect(MapPrototypeGate.releaseAnswer(false) == false)
    }

    @Test func theAppDoesNotUnlockProMotionForEveryAnimation() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") == nil)
    }

    @Test func aFlightGivenUpWhenTheAppLeftIsNotRestartedByANewSize() {
        #expect(CameraProbeModel.reshowsFlightOnLayout(phase: nil, abandoned: true) == false)
        #expect(CameraProbeModel.reshowsFlightOnLayout(phase: nil, abandoned: false))
        #expect(CameraProbeModel.reshowsFlightOnLayout(phase: .starting, abandoned: false))
        #expect(CameraProbeModel.reshowsFlightOnLayout(phase: .flying, abandoned: false) == false)
    }
}
