import Testing
@testable import SortlyCore

/// Every combination of heat, battery, charging and Low Power Mode (review after the first
/// device test 15.11.): runs in the app slow down or wait, the overnight refinement stops.
@Suite("Device rules")
struct DeviceStateTests {
    static let thermals: [DeviceState.Thermal] = [.nominal, .fair, .serious, .critical]
    static let levels: [Double?] = [nil, 0.05, 0.1, 0.15, 0.2, 0.5, 1.0]

    static var all: [DeviceState] {
        thermals.flatMap { thermal in
            levels.flatMap { level in
                [false, true].flatMap { charging in
                    [false, true].map { lowPower in
                        DeviceState(thermal: thermal, batteryLevel: level, isCharging: charging, isLowPowerMode: lowPower)
                    }
                }
            }
        }
    }

    /// The rules written out once more, independently, for the whole table.
    static func expectedPace(_ s: DeviceState) -> AnalysisPace {
        let empty = !s.isCharging && (s.batteryLevel ?? 1) < 0.1
        if s.thermal == .critical { return .wait(.thermal) }
        if empty { return .wait(.batteryLow) }
        if s.thermal == .serious { return .gentle }
        return .normal
    }

    static func expectedRefinement(_ s: DeviceState) -> PauseReason? {
        if s.thermal == .serious || s.thermal == .critical { return .thermal }
        if s.isLowPowerMode && !s.isCharging { return .lowPower }
        if !s.isCharging, let level = s.batteryLevel, level < 0.2 { return .batteryLow }
        return nil
    }

    @Test func everyCombination() {
        #expect(Self.all.count == 4 * 7 * 2 * 2)
        for state in Self.all {
            #expect(state.appPace == Self.expectedPace(state), "\(state)")
            #expect(state.refinementPauseReason == Self.expectedRefinement(state), "\(state)")
        }
    }

    @Test func appRunsNeverEndBecauseOfTheDevice() {
        for state in Self.all {
            if case .stop = state.appPace { Issue.record("a run in the app was ended: \(state)") }
        }
    }

    @Test func namedCases() {
        // Warm: slower, not stopped. Low Power Mode alone changes nothing in the app.
        #expect(DeviceState(thermal: .serious, batteryLevel: 0.8).appPace == .gentle)
        #expect(DeviceState(thermal: .fair, batteryLevel: 0.8, isLowPowerMode: true).appPace == .normal)
        #expect(DeviceState(thermal: .fair, batteryLevel: 0.8, isLowPowerMode: true).refinementPauseReason == .lowPower)
        // Nearly empty: waits, unless it is charging.
        #expect(DeviceState(batteryLevel: 0.05).appPace == .wait(.batteryLow))
        #expect(DeviceState(batteryLevel: 0.05, isCharging: true).appPace == .normal)
        // Exactly at the floor is not below it.
        #expect(DeviceState(batteryLevel: 0.1).appPace == .normal)
        #expect(DeviceState(batteryLevel: 0.2).refinementPauseReason == nil)
        // Unknown battery (simulator): never a reason.
        #expect(DeviceState(batteryLevel: nil).appPace == .normal)
        #expect(DeviceState(batteryLevel: nil).refinementPauseReason == nil)
        // Too hot wins over everything, also while charging.
        #expect(DeviceState(thermal: .critical, batteryLevel: 0.05, isCharging: true).appPace == .wait(.thermal))
        #expect(DeviceState(thermal: .serious, isCharging: true).refinementPauseReason == .thermal)
    }

    /// The card's "Langsamer, weil …" line (progress display T13, P5–P7): only while the run
    /// does not wait; warm before Low Power Mode; over the whole table.
    @Test func slowerReasonForEveryCombination() {
        for s in Self.all {
            let expected: SlowReason?
            if case .wait = Self.expectedPace(s) {
                expected = nil
            } else if s.thermal == .serious {
                expected = .warm
            } else if s.isLowPowerMode {
                expected = .lowPower
            } else {
                expected = nil
            }
            #expect(s.slowerReason == expected, "\(s)")
        }
        #expect(DeviceState(thermal: .critical, isLowPowerMode: true).slowerReason == nil)
        #expect(DeviceState(batteryLevel: 0.05, isLowPowerMode: true).slowerReason == nil)
    }
}
