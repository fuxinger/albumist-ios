import BackgroundTasks
import Foundation
import SortlyEngine
import UIKit
import UserNotifications

/// iOS 26 continued processing: a long analysis keeps running after the user leaves the app,
/// and the system shows its progress on the Lock Screen and in the Dynamic Island. When it
/// ends while Albumist is in the background, a local notification says so.
///
/// First device test 15.11. ("nur einmal und dann einen Fehler"): the request was made only
/// for the very first run, and when iOS ended the background time the analysis was paused
/// for good. Now every long run asks (again after each return to the app), and when iOS ends
/// the time the analysis is only held by iOS and goes on when the app is opened.
@MainActor
enum ContinuedAnalysis {
    nonisolated static let taskID = AppInfo.continuedAnalysisTaskPrefix + ".continued"
    private static var registered = false
    /// The system runs our task right now (progress is on the Lock Screen).
    private(set) static var isActive = false
    /// The last request, so a refused or pending one is not repeated with every progress step.
    private static var lastRequest: Date?
    private struct TaskBox: @unchecked Sendable { let task: BGContinuedProcessingTask }

    /// Asks for background time for the running analysis. Only while the app is on screen
    /// (iOS starts these tasks from the foreground); repeated calls do nothing while a task
    /// runs or a request was made less than a minute ago.
    static func begin() {
        guard !isActive, UIApplication.shared.applicationState == .active else { return }
        if let lastRequest, Date().timeIntervalSince(lastRequest) < 60 { return }
        lastRequest = Date()
        registerIfNeeded()
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskID,
            title: String(localized: "Albumist analysiert deine Fotos"),
            subtitle: String(localized: "Läuft weiter, auch wenn du die App verlässt")
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not supported (simulator, older device) or refused right now: the analysis is
            // held while the app is in the background and goes on when it is opened.
        }
    }

    private static func registerIfNeeded() {
        guard !registered else { return }
        registered = register()
    }

    private static func started() {
        isActive = true
        lastRequest = nil
    }

    private static func ended() {
        isActive = false
        lastRequest = nil
    }

    /// Nonisolated: the system calls the handler on a background queue.
    nonisolated private static func register() -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(task: continued)
            let monitor = Task { @MainActor in
                started()
                let model = AppModel.shared
                let units: Int64 = 10_000
                box.task.progress.totalUnitCount = units
                var reported: Int64 = 0
                var lastStep = Date()
                var idleChecks = 0
                while !Task.isCancelled {
                    if model.analysis.isRunning {
                        idleChecks = 0
                        // One bar over all stages that only moves forward. iOS ends tasks that
                        // seem stuck, so while one slow photo or place lookup takes long the bar
                        // still moves a tiny step every 10 seconds (not while waiting for heat).
                        let real = Int64(model.analysis.shownOverall * Double(units))
                        if real > reported {
                            reported = min(real, units - 1)
                            lastStep = Date()
                        } else if model.analysis.waiting == nil, Date().timeIntervalSince(lastStep) >= 10, reported < units - 1 {
                            reported += 1
                            lastStep = Date()
                        }
                        box.task.progress.completedUnitCount = reported
                        box.task.updateTitle(String(localized: "Albumist analysiert deine Fotos"), subtitle: subtitle(model.analysis))
                    } else {
                        idleChecks += 1
                        if idleChecks > 3 { break }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                ended()
                if Task.isCancelled {
                    box.task.setTaskCompleted(success: false)
                } else {
                    box.task.progress.completedUnitCount = units
                    box.task.setTaskCompleted(success: true)
                }
            }
            // iOS ended the background time: only the task ends. The analysis is not paused;
            // iOS holds the app, and the run goes on where it was when Albumist is opened.
            continued.expirationHandler = {
                monitor.cancel()
            }
        }
    }

    private static func subtitle(_ analysis: AppModel.AnalysisState) -> String {
        if let waiting = analysis.waiting {
            return waiting == .batteryLow
                ? String(localized: "Wartet, bis der Akku lädt")
                : String(localized: "Kurze Pause, das iPhone kühlt ab")
        }
        guard let stage = analysis.stage, !analysis.isCatchingUp else {
            return String(localized: "Macht da weiter, wo sie aufgehört hat")
        }
        let steps = AnalysisPipeline.Stage.allCases.count
        guard analysis.total > 0 else { return String(localized: "Schritt \(stage.number) von \(steps)") }
        return String(localized: "Schritt \(stage.number) von \(steps) · \(analysis.completed.formatted()) von \(analysis.total.formatted())")
    }

    // MARK: Notification

    /// Asked once, when the user starts the first analysis.
    static func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Only when the app is not on screen; inside the app the overview shows the result.
    static func notifyFinished(openSuggestions: Int) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Analyse fertig")
        content.body = openSuggestions > 0
            ? String(localized: "\(openSuggestions) Vorschläge warten auf dich.")
            : String(localized: "Deine Fotos sind analysiert.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "analysis.finished", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
