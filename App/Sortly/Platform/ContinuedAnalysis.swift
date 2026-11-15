import BackgroundTasks
import Foundation
import os
import SortlyCore
import SortlyEngine
import UIKit
import UserNotifications

/// iOS 26 continued processing: a long analysis keeps running after the user leaves the app,
/// and the system shows its progress on the Lock Screen and in the Dynamic Island. When it
/// ends while Albumist is in the background, a local notification says so.
///
/// Device tests 15.11.:
/// - The bar appeared only for the first analysis of an app session. Every request used the
///   same identifier, and iOS never runs an identifier a second time (Apple DTS); `submit`
///   does not report that. Now every request has its own identifier under the prefix that
///   Info.plist permits (`app.albumist.ios.analysis.*`) and its own handler.
/// - "Vorgang fehlgeschlagen": iOS takes a task whose progress stands still for an
///   unresponsive app and ends it as failed. The progress now moves at least every ten
///   seconds (`ContinuedTaskHeartbeat`), also during a break for heat or battery, and it is
///   reported off the main thread, so a busy main thread cannot stop it either. If iOS still
///   ends the time, the task is not reported as failed (the analysis is not lost) and a
///   notification says that it goes on in the app.
/// The analysis as the task sees it: written on the main actor whenever it changes, read by
/// the task's own loop off the main thread. At file scope, so it is not tied to the main actor.
private struct ContinuedTaskShared: Sendable {
    var running = false
    var fraction = 0.0
    var subtitle = ""
    /// Albumist is on screen (set with every scene change, read when iOS ends the time).
    var onScreen = true
}

/// Completes the system task exactly once (the loop and the expiration may race).
private final class ContinuedTaskBox: @unchecked Sendable {
    let task: BGContinuedProcessingTask
    private let done = OSAllocatedUnfairLock(initialState: false)

    init(task: BGContinuedProcessingTask) { self.task = task }

    func complete(success: Bool) -> Bool {
        let first = done.withLock { isDone -> Bool in
            if isDone { return false }
            isDone = true
            return true
        }
        if first { task.setTaskCompleted(success: success) }
        return first
    }
}

@MainActor
enum ContinuedAnalysis {
    /// The system runs one of our tasks right now (progress is on the Lock Screen).
    private(set) static var isActive = false
    /// The last request, so a refused or pending one is not repeated with every progress step.
    private static var lastRequest: Date?

    /// A new identifier for every request, under the prefix Info.plist permits.
    nonisolated static func makeIdentifier() -> String {
        AppInfo.continuedAnalysisTaskPrefix + "." + UUID().uuidString
    }

    nonisolated static var title: String { String(localized: "Albumist analysiert deine Fotos") }

    nonisolated private static let shared = OSAllocatedUnfairLock(initialState: ContinuedTaskShared())

    /// Called whenever the analysis state changes (`AppModel.analysis`).
    static func publish(_ analysis: AppModel.AnalysisState) {
        // The text only while a task shows it (the state changes several times a second).
        let running = analysis.isRunning, fraction = analysis.shownOverall
        let text = isActive ? subtitle(analysis) : ""
        shared.withLock {
            $0.running = running
            $0.fraction = fraction
            $0.subtitle = text
        }
    }

    /// Called with every scene change (`SortlyApp`).
    static func sceneChanged(onScreen: Bool) {
        shared.withLock { $0.onScreen = onScreen }
    }

    /// Asks for background time for the running analysis. Only while the app is on screen
    /// (iOS starts these tasks from the foreground); repeated calls do nothing while a task
    /// runs or a request was made less than a minute ago.
    static func begin() {
        guard !isActive, UIApplication.shared.applicationState == .active else { return }
        if let lastRequest, Date().timeIntervalSince(lastRequest) < 60 { return }
        lastRequest = Date()
        let identifier = makeIdentifier()
        BackgroundRunLog.update { $0.requested += 1 }
        guard registerHandler(for: identifier) else {
            BackgroundRunLog.update { $0.refused += 1; $0.lastRefusal = "not registered" }
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: String(localized: "Läuft weiter, auch wenn du die App verlässt")
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not supported (simulator, older device) or refused right now: the analysis is
            // held while the app is in the background and goes on when it is opened.
            let code = (error as NSError).code
            BackgroundRunLog.update { $0.refused += 1; $0.lastRefusal = "submit error \(code)" }
        }
    }

    /// One handler per identifier, registered right before the request (a handler can be
    /// registered only once per identifier, and only a registered one is started).
    /// Nonisolated on purpose: iOS calls the handler on a background queue, and a closure
    /// made on the main actor would be checked for the main thread there and stop the app.
    nonisolated private static func registerHandler(for identifier: String) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            run(task)
        }
    }

    private static func started() {
        isActive = true
        lastRequest = nil
        let analysis = AppModel.shared.analysis
        BackgroundRunLog.update {
            $0.started += 1
            $0.lastStart = Date()
            $0.lastStartProgress = analysis.shownOverall
        }
        publish(analysis)
    }

    /// `fraction`: the real progress of the analysis at that moment (not the bar's heartbeat).
    private static func ended(_ how: String, fraction: Double) {
        isActive = false
        lastRequest = nil
        let state = BackgroundRunLog.deviceState()
        BackgroundRunLog.update {
            $0.lastEnd = Date()
            $0.lastEndReason = how
            $0.lastEndProgress = fraction
            $0.lastEndState = state
        }
    }

    /// Nonisolated: the system calls the handler on a background queue.
    nonisolated private static func run(_ task: BGTask) {
        guard let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        let box = ContinuedTaskBox(task: continued)
        Task { @MainActor in started() }
        let monitor = Task.detached(priority: .userInitiated) {
            box.task.progress.totalUnitCount = ContinuedTaskHeartbeat.units
            var heartbeat = ContinuedTaskHeartbeat(start: Date())
            var shownSubtitle = ""
            while !Task.isCancelled {
                let state = shared.withLock { $0 }
                switch heartbeat.step(now: Date(), running: state.running, fraction: state.fraction) {
                case .report(let units):
                    box.task.progress.completedUnitCount = units
                    if !state.subtitle.isEmpty, state.subtitle != shownSubtitle {
                        shownSubtitle = state.subtitle
                        box.task.updateTitle(title, subtitle: state.subtitle)
                    }
                case .finish:
                    // Finished, paused by the user, or stopped: done, no failure.
                    box.task.progress.completedUnitCount = ContinuedTaskHeartbeat.units
                    if box.complete(success: true) {
                        let fraction = state.fraction
                        await MainActor.run { ended("finished", fraction: fraction) }
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // iOS ended the background time anyway (heavy load, very hot, the user stopped it).
        // `success` tells iOS what to do with the task, not whether the work succeeded
        // (Apple DTS): the analysis is not lost, so no failure is asked for. iOS holds the app,
        // and the run goes on where it was when Albumist is opened; a notification says so.
        continued.expirationHandler = {
            monitor.cancel()
            // Posted here, before the task is handed back: right after it, iOS may hold the
            // app, and work queued for the main thread would wait until Albumist is opened.
            let state = shared.withLock { $0 }
            if state.running, !state.onScreen { postPausedNotification() }
            if box.complete(success: true) {
                Task { @MainActor in ended("expired", fraction: state.fraction) }
            }
        }
    }

    private static func subtitle(_ analysis: AppModel.AnalysisState) -> String {
        if let waiting = analysis.waiting {
            return waiting == .batteryLow
                ? String(localized: "Wartet, bis der Akku lädt")
                : String(localized: "Kurze Pause, das iPhone kühlt ab")
        }
        let steps = AnalysisPipeline.Stage.allCases.count
        // Still reading the library (no step reported yet): only a run that goes on from an
        // earlier one says so; a first run is at step 1.
        guard let stage = analysis.stage else {
            return analysis.resumeFrom != nil
                ? String(localized: "Macht da weiter, wo sie aufgehört hat")
                : String(localized: "Schritt \(1) von \(steps)")
        }
        if analysis.isCatchingUp { return String(localized: "Macht da weiter, wo sie aufgehört hat") }
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

    /// iOS ended the background time while the analysis was busy and Albumist was not on
    /// screen: says that nothing is lost and how it goes on.
    nonisolated private static func postPausedNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Analyse macht Pause")
        content.body = String(localized: "Öffne Albumist, dann geht sie genau dort weiter, wo sie war.")
        let request = UNNotificationRequest(identifier: "analysis.paused", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
