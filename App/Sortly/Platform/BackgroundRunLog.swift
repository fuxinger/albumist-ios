import Foundation
import UIKit
import SortlyCore

/// What happened to the analysis in the background, for the diagnostic report: counts, times
/// and system states only, nothing about the photos. Written because the device test (15.11.)
/// showed "Vorgang fehlgeschlagen" on the Lock Screen and a run that had to be continued by
/// hand, and the report could not tell when and why iOS had ended the background time.
@MainActor
enum BackgroundRunLog {
    struct Entry: Codable, Equatable {
        /// Requests for background time (continued processing) and how many iOS started.
        var requested = 0
        var started = 0
        var refused = 0
        var lastRefusal: String?
        var lastStart: Date?
        /// The analysis progress when iOS started the time: against `lastEndProgress` it shows
        /// whether the analysis moved in the background.
        var lastStartProgress: Double?
        var lastEnd: Date?
        /// "finished" (the analysis ended or paused) or "expired" (iOS ended the time).
        var lastEndReason: String?
        var lastEndProgress: Double?
        /// Heat, Low Power Mode, battery and whether the app was on screen at that moment.
        var lastEndState: String?
        /// How the last analysis run ended: when, why, and whether the app was on screen.
        var lastRunEnd: String?
    }

    private static let key = "diagnostics.backgroundRun"

    static var entry: Entry {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
        return entry
    }

    static func update(_ change: (inout Entry) -> Void) {
        var current = entry
        change(&current)
        if let data = try? JSONEncoder().encode(current) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The end of an analysis run (finished, paused, stopped by an error). `paused`: the
    /// reason as the report writes it (`PauseReason.rawValue`).
    static func runEnded(paused: String?, complete: Bool, analyzerFailing: Bool, stage: Int?) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let outcome = complete ? "complete" : (paused.map { "paused \($0)" } ?? "ended without report")
        let line = "\(stamp) \(outcome), analyzer failing \(analyzerFailing), stage \(stage.map(String.init) ?? "-"), \(deviceState())"
        update { $0.lastRunEnd = line }
    }

    static func deviceState() -> String {
        let info = ProcessInfo.processInfo
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let battery = level < 0 ? "?" : "\(Int((level * 100).rounded())) %"
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let app: String
        switch UIApplication.shared.applicationState {
        case .active: app = "on screen"
        case .inactive: app = "inactive"
        case .background: app = "background"
        @unknown default: app = "unknown"
        }
        return "heat \(thermal), low power \(info.isLowPowerModeEnabled), battery \(battery)\(charging ? " charging" : ""), app \(app)"
    }

    /// Two lines for the diagnostic report.
    static var summary: [String] {
        let iso = ISO8601DateFormatter()
        let e = entry
        let start = e.lastStart.map { iso.string(from: $0) } ?? "-"
        let end = e.lastEnd.map { iso.string(from: $0) } ?? "-"
        let percent = { (value: Double?) in value.map { "\(Int(($0 * 100).rounded())) %" } ?? "-" }
        let progress = percent(e.lastEndProgress)
        return [
            "background time requested \(e.requested), started \(e.started), refused \(e.refused) (\(e.lastRefusal ?? "-")), "
                + "last start \(start) at \(percent(e.lastStartProgress)), last end \(end) \(e.lastEndReason ?? "-") at \(progress), \(e.lastEndState ?? "-")",
            "last analysis run \(e.lastRunEnd ?? "-")",
            "device now \(deviceState()), hottest during the last run \(HeatLog.hottest)",
        ]
    }
}

/// The highest heat level iOS reported while the last run asked about the device (it asks
/// before every photo). Device test 15.11.: "Es wird aber nicht warm. Sind das richtige Werte?"
/// iOS reports the chip's state, not how warm the case feels; the report now shows it.
enum HeatLog {
    private static let level = LockedBox<DeviceState.Thermal?>(nil)

    static func reset() { level.value = nil }

    static func note(_ thermal: DeviceState.Thermal) {
        if level.value.map({ thermal > $0 }) ?? true { level.value = thermal }
    }

    static var hottest: String {
        switch level.value {
        case nil: "-"
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
    }
}
