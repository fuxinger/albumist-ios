import Foundation
import MetricKit
import os
import SortlyEngine

/// MetricKit for the diagnostic report (owner, 19.11.2026: "Sollte auch noch Batterie
/// verbraucht analysieren"): iOS sends Albumist's CPU and GPU time, time on screen and in the
/// background, hangs and the reasons it ended the app in the background, at most once a day,
/// and hang and CPU exception reports. Only their numbers are kept (`EnergyMetricsLog`,
/// SortlyEngine, the last week, `UserDefaults`); no call stacks, nothing about the photos, and
/// nothing leaves the phone unless the user shares the report.
///
/// Added at launch (`SortlyApp.init`), so iOS can hand over what it collected.
final class EnergyMetricsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = EnergyMetricsSubscriber()
    private static let key = "diagnostics.metricKit"
    /// MetricKit calls on a queue of its own: one change of the stored log at a time.
    private static let log = OSAllocatedUnfairLock(initialState: stored())

    @MainActor
    static func start() {
        let manager = MXMetricManager.shared
        manager.add(shared)
        // What iOS delivered before this launch and is not kept yet (each is kept once).
        let days = manager.pastPayloads.map(Self.day)
        let reports = manager.pastDiagnosticPayloads.map(Self.diagnostics)
        if !days.isEmpty || !reports.isEmpty { store(days: days, reports: reports) }
    }

    /// Lines for the diagnostic report.
    static var summary: [String] { log.withLock { $0 }.reportLines }

    func didReceive(_ payloads: [MXMetricPayload]) {
        Self.store(days: payloads.map(Self.day), reports: [])
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.store(days: [], reports: payloads.map(Self.diagnostics))
    }

    // MARK: Numbers only

    private static func seconds(_ value: Measurement<UnitDuration>) -> Double {
        value.converted(to: .seconds).value
    }

    static func day(_ payload: MXMetricPayload) -> EnergyMetricsLog.Day {
        var day = EnergyMetricsLog.Day(begin: payload.timeStampBegin, end: payload.timeStampEnd)
        day.build = payload.metaData?.applicationBuildVersion
        day.cpuSeconds = payload.cpuMetrics.map { seconds($0.cumulativeCPUTime) }
        day.gpuSeconds = payload.gpuMetrics.map { seconds($0.cumulativeGPUTime) }
        day.foregroundSeconds = payload.applicationTimeMetrics.map { seconds($0.cumulativeForegroundTime) }
        day.backgroundSeconds = payload.applicationTimeMetrics.map { seconds($0.cumulativeBackgroundTime) }
        day.hangCount = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime.totalBucketCount
        if let exits = payload.applicationExitMetrics?.backgroundExitData {
            day.backgroundExits = [
                "task timeout": exits.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                "cpu limit": exits.cumulativeCPUResourceLimitExitCount,
                "watchdog": exits.cumulativeAppWatchdogExitCount,
                "memory limit": exits.cumulativeMemoryResourceLimitExitCount,
                "memory pressure": exits.cumulativeMemoryPressureExitCount,
            ].filter { $0.value > 0 }
        }
        return day
    }

    static func diagnostics(_ payload: MXDiagnosticPayload) -> EnergyMetricsLog.Diagnostics {
        EnergyMetricsLog.Diagnostics(
            begin: payload.timeStampBegin,
            end: payload.timeStampEnd,
            hangSeconds: (payload.hangDiagnostics ?? []).map { seconds($0.hangDuration) },
            cpuExceptionSeconds: (payload.cpuExceptionDiagnostics ?? []).map { seconds($0.totalCPUTime) },
            crashes: payload.crashDiagnostics?.count ?? 0,
            diskWriteExceptions: payload.diskWriteExceptionDiagnostics?.count ?? 0
        )
    }

    // MARK: Storage

    private static func store(days: [EnergyMetricsLog.Day], reports: [EnergyMetricsLog.Diagnostics]) {
        log.withLock { log in
            for day in days { log.add(day) }
            for report in reports { log.add(report) }
            if let data = try? JSONEncoder().encode(log) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    private static func stored() -> EnergyMetricsLog {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(EnergyMetricsLog.self, from: $0) }
            ?? EnergyMetricsLog()
    }
}
