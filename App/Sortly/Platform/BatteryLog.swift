import Foundation
import UIKit
import SortlyCore
import SortlyEngine

/// How much battery the analysis uses, for the diagnostic report: "Akku: 1,8 % pro 1.000 Fotos
/// (Vordergrund 2,1 %, Hintergrund 1,2 %; 4.200 Fotos gemessen)" (owner, 19.11.2026: "Sollte
/// auch noch Batterie verbraucht analysieren").
///
/// Reads the device with every change of the analysis and every scene change
/// (`ContinuedAnalysis.publish`, `ContinuedAnalysis.sceneChanged`) and keeps the stretches in
/// `UserDefaults`: levels, counts, heat, Low Power Mode, nothing about the photos. The rules
/// (what a stretch is, what counts, when there is a number) are in `BatteryStretchTracker` and
/// `BatteryUse` (SortlyEngine, tested on Linux).
@MainActor
enum BatteryLog {
    private static let recordKey = "diagnostics.batteryRecord"
    private static let trackerKey = "diagnostics.batteryTracker"
    /// Stretches kept in detail (weeks of use); those that leave the list stay in the totals
    /// (`BatteryRecord`), so the figure never loses what counted.
    static let kept = 200
    /// The stretch in progress is written at most this often, so one that ends because iOS
    /// quits the app in the background still counts up to that reading.
    private static let saveEvery: TimeInterval = 30

    private static var tracker: BatteryStretchTracker = load(trackerKey) ?? BatteryStretchTracker()
    private static var lastSaved = Date.distantPast
    /// Progress alone is read at most every two seconds (it changes several times a second);
    /// a start, an end, a new step or a scene change always (the tracker settles a count only on
    /// a second reading of the same step, so a new step must never be skipped).
    private static var lastObserved = Date.distantPast
    private static var observedState: (analysing: Bool, onScreen: Bool, stage: AnalysisPipeline.Stage?)?
    private static var monitoring = false
    /// The analysis as last published, for scene changes.
    private static var analysing = false
    private static var stage: AnalysisPipeline.Stage?
    private static var completed = 0
    /// From the last scene change; before the first one (iOS launched the app in the background
    /// for the overnight refinement) from the app's state.
    private static var sceneOnScreen: Bool?
    private static var onScreen: Bool { sceneOnScreen ?? (UIApplication.shared.applicationState == .active) }

    /// Every change of the analysis.
    static func analysisChanged(_ analysis: AppModel.AnalysisState) {
        analysing = BatteryStretchTracker.isAnalysing(running: analysis.isRunning, waitingForDevice: analysis.waiting != nil,
                                                      waitingForApple: analysis.appleWaitLeft != nil)
        stage = analysis.stage
        completed = analysis.completed
        observe()
    }

    static func sceneChanged(onScreen: Bool) {
        // Early (the first scene change comes at launch): right after it is turned on, UIDevice
        // may still say -1, and a stretch starting then would not count.
        enableMonitoring()
        sceneOnScreen = onScreen
        observe()
    }

    /// iOS ended the background time: the stretch ends at its last reading.
    static func backgroundTimeEnded() {
        if let ended = tracker.close() { append([ended]) }
        save(tracker, trackerKey)
    }

    /// Two lines for the diagnostic report: the number in the user's language, the details for
    /// support in English.
    static var summary: [String] {
        let use = BatteryUse(record)
        return [line(use, locale: .current), use.detail]
    }

    static func line(_ use: BatteryUse, locale: Locale) -> String {
        func value(_ estimate: BatteryUse.Estimate) -> String {
            switch estimate {
            case .perThousand(let points): String(localized: "\(BatteryUse.number(points, locale: locale)) %")
            case .aboutAtMost(let points): String(localized: "etwa höchstens \(BatteryUse.number(points, locale: locale)) %")
            case .tooLittle: String(localized: "noch zu wenig gemessen")
            }
        }
        let photos = BatteryUse.count(use.all.photos, locale: locale)
        guard use.all.estimate != .tooLittle else {
            let used = BatteryUse.number(use.all.drop, locale: locale)
            return String(localized: "Akku: noch zu wenig gemessen (Fotos: \(photos), verbraucht: \(used) %)")
        }
        let places = String(localized: "Vordergrund \(value(use.foreground.estimate)), Hintergrund \(value(use.background.estimate))")
        return String(localized: "Akku: \(value(use.all.estimate)) pro 1.000 Fotos (\(places); \(photos) Fotos gemessen)")
    }

    private static func observe() {
        // Most calls: no analysis works and no stretch is open, nothing to read.
        guard analysing || tracker.open != nil else { return }
        let now = Date()
        let state = (analysing: analysing, onScreen: onScreen, stage: stage)
        if let observedState, observedState == state, now.timeIntervalSince(lastObserved) < 2 { return }
        observedState = state
        lastObserved = now
        let ended = tracker.observe(.init(now: now, analysing: analysing, onScreen: onScreen, stage: stage,
                                          completed: completed, device: device()))
        if !ended.isEmpty { append(ended) }
        if !ended.isEmpty || tracker.open == nil || now.timeIntervalSince(lastSaved) >= saveEvery {
            save(tracker, trackerKey)
            lastSaved = now
        }
    }

    private static func enableMonitoring() {
        guard !monitoring else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        monitoring = true
    }

    private static func device() -> DeviceState {
        enableMonitoring()
        let level = UIDevice.current.batteryLevel
        let battery = UIDevice.current.batteryState
        let info = ProcessInfo.processInfo
        return DeviceState(
            thermal: DeviceState.Thermal(rawValue: info.thermalState.rawValue) ?? .critical,
            batteryLevel: level >= 0 ? Double(level) : nil,
            isCharging: battery == .charging || battery == .full,
            isLowPowerMode: info.isLowPowerModeEnabled
        )
    }

    private static var record: BatteryRecord { load(recordKey) ?? BatteryRecord() }

    private static func append(_ ended: [BatteryStretch]) {
        var updated = record
        updated.append(ended, keeping: kept)
        save(updated, recordKey)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
