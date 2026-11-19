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
    /// What the Lock Screen says once the run has ended: iOS keeps showing the task's last
    /// title after it is completed, and "analysiert deine Fotos" stayed there although the
    /// analysis had stopped (device test 15.11. 22:57).
    var endTitle = ""
    var endSubtitle = ""
    var endedComplete = false
    /// Albumist is on screen (set with every scene change, read when iOS ends the time).
    var onScreen = true
    /// Where the run stands, for "Öffne Albumist, dann geht es bei 2.431 von 5.683 Fotos
    /// weiter." (M4, T10) when iOS ends the time.
    var waitBody = ""
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
    /// Whether iOS lets the analysis go on in the background, for the card's chip (S8):
    /// "Läuft auch im Hintergrund" only while the task really runs (a successful `submit` is
    /// not enough: with `strategy = .fail` iOS can still refuse it), "Läuft, solange Albumist
    /// offen ist" after iOS refused.
    enum Status: Equatable { case idle, running, refused }

    /// Mirrored into `AppModel.analysisBackground` by the card's tick (this is not observable).
    private(set) static var status: Status = .idle

    /// The system runs one of our tasks right now (progress is on the Lock Screen).
    static var isActive: Bool { status == .running }
    /// The last request, so a refused or pending one is not repeated with every progress step.
    private static var lastRequest: Date?

    /// A new identifier for every request, under the prefix Info.plist permits.
    nonisolated static func makeIdentifier() -> String {
        AppInfo.continuedAnalysisTaskPrefix + "." + UUID().uuidString
    }

    nonisolated static var title: String { String(localized: "Albumist analysiert deine Fotos") }

    nonisolated private static let shared = OSAllocatedUnfairLock(initialState: ContinuedTaskShared())

    /// Called whenever the analysis state or its finish time changes (`AppModel`).
    static func publish(_ analysis: AppModel.AnalysisState, finish: FinishEstimate?) {
        // Every run counts for the battery use, the overnight refinement too.
        BatteryLog.analysisChanged(analysis)
        // The overnight refinement seen in the app is not the run a task shows: a task of a run
        // in the app that has not seen its end yet must not take over its bar (review of d744b74).
        guard !analysis.refining else { return }
        // The text only while a task shows it (the state changes several times a second).
        let running = analysis.isRunning, fraction = analysis.shownOverall
        let text = isActive && running ? subtitle(analysis, finish: finish) : ""
        let ending = running ? nil : ending(analysis)
        let waitBody = running ? Self.waitBody(analysis.position) : ""
        shared.withLock {
            if running { $0.waitBody = waitBody }
            $0.running = running
            // The bar keeps where the run got to (a run that ended has no stage, so 0).
            if running { $0.fraction = fraction }
            if !text.isEmpty { $0.subtitle = text }
            if let ending {
                $0.endTitle = ending.title
                $0.endSubtitle = ending.subtitle
                $0.endedComplete = ending.complete
            }
        }
    }

    /// Called with every scene change (`SortlyApp`).
    static func sceneChanged(onScreen: Bool) {
        shared.withLock { $0.onScreen = onScreen }
        BatteryLog.sceneChanged(onScreen: onScreen)
    }

    /// Asks for background time for the running analysis. Only while the app is on screen
    /// (iOS starts these tasks from the foreground); repeated calls do nothing while a task
    /// runs or a request was made less than a minute ago.
    static func begin() {
        MainThreadWatch.shared.section("background time request") { beginNow() }
    }

    private static func beginNow() {
        guard !isActive, UIApplication.shared.applicationState == .active else { return }
        if let lastRequest, Date().timeIntervalSince(lastRequest) < 60 { return }
        lastRequest = Date()
        // A new request: what iOS said to an earlier one no longer holds for the chip.
        if status == .refused { status = .idle }
        let identifier = makeIdentifier()
        BackgroundRunLog.update { $0.requested += 1 }
        guard registerHandler(for: identifier) else {
            BackgroundRunLog.update { $0.refused += 1; $0.lastRefusal = "not registered" }
            status = .refused
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
            status = .refused
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
        status = .running
        lastRequest = nil
        let analysis = AppModel.shared.analysis
        BackgroundRunLog.update {
            $0.started += 1
            $0.lastStart = Date()
            $0.lastStartProgress = analysis.shownOverall
        }
        publish(analysis, finish: AppModel.shared.analysisFinish)
    }

    /// `fraction`: the real progress of the analysis at that moment (not the bar's heartbeat).
    private static func ended(_ how: String, fraction: Double) {
        status = .idle
        lastRequest = nil
        // iOS may hold the app right after: the battery stretch ends at its last reading.
        if how == "expired" { BatteryLog.backgroundTimeEnded() }
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
                    // Finished, paused by the user, or stopped: done, no failure. The text says
                    // which, and only a finished analysis shows a full circle.
                    if !state.endTitle.isEmpty {
                        box.task.updateTitle(state.endTitle, subtitle: state.endSubtitle)
                    }
                    if state.endedComplete {
                        box.task.progress.completedUnitCount = ContinuedTaskHeartbeat.units
                    }
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
            if state.running, !state.onScreen { postPausedNotification(body: state.waitBody) }
            if box.complete(success: true) {
                Task { @MainActor in ended("expired", fraction: state.fraction) }
            }
        }
    }

    /// The Lock Screen text once a run has ended, by how it ended.
    static func ending(_ analysis: AppModel.AnalysisState) -> (title: String, subtitle: String, complete: Bool) {
        let report = analysis.lastReport
        if !analysis.needsResume, let report, report.isComplete {
            // Point 5: "Analyse fertig" / "216 Vorschläge" (the suggestions of this run).
            let subtitle = report.proposals > 0
                ? String(localized: "\(report.proposals) Vorschläge")
                : String(localized: "Öffne Albumist, um die Vorschläge zu prüfen.")
            return (String(localized: "Analyse fertig"), subtitle, true)
        }
        if !analysis.needsResume, report?.pausedBecause == .userPaused {
            return (String(localized: "Analyse pausiert"), String(localized: "Öffne Albumist, um sie fortzusetzen."), false)
        }
        return (String(localized: "Analyse wartet auf dich"), waitBody(analysis.stoppedAt), false)
    }

    /// "Öffne Albumist, dann geht es bei 2.431 von 5.683 Fotos weiter." (M4); without a count
    /// "… genau dort weiter."
    static func waitBody(_ position: AnalysisCardState.Position?) -> String {
        guard let position, position.hasCount else { return String(localized: "Öffne Albumist, dann geht es genau dort weiter.") }
        return String(localized: "Öffne Albumist, dann geht es bei \(AnalysisText.count(position)) weiter.")
    }

    /// Point 5: "2.431 von 5.683 Fotos · fertig gegen 23:40", number first (iOS cuts long
    /// subtitles at the end); without a time to trust only the count.
    static func subtitle(_ analysis: AppModel.AnalysisState, finish: FinishEstimate?) -> String {
        if let waiting = analysis.waiting {
            return waiting == .batteryLow
                ? String(localized: "Wartet aufs Laden")
                : String(localized: "Wartet, bis dein iPhone abkühlt")
        }
        let steps = AnalysisStep.count
        // Still reading the library (no step reported yet): only a run that goes on from an
        // earlier one says so; a first run is at step 1.
        guard let position = analysis.position else {
            return analysis.resumeFrom != nil
                ? String(localized: "Macht da weiter, wo sie aufgehört hat")
                : String(localized: "Schritt \(1) von \(steps)")
        }
        if analysis.isCatchingUp { return String(localized: "Macht da weiter, wo sie aufgehört hat") }
        guard position.hasCount else { return String(localized: "Schritt \(position.step.number) von \(steps)") }
        return AnalysisText.lockScreen(position, finish: analysis.waiting == nil ? finish : nil)
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
    nonisolated private static func postPausedNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Analyse wartet auf dich")
        content.body = body.isEmpty ? String(localized: "Öffne Albumist, dann geht es genau dort weiter.") : body
        let request = UNNotificationRequest(identifier: "analysis.paused", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Only when the app is not on screen; inside the app the overview shows the result.
    /// With suggestions it carries the button "Vorschläge prüfen" (point 4), which opens them
    /// directly, like a tap on the notification itself (`NotificationRouter`).
    static func notifyFinished(openSuggestions: Int) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Analyse fertig")
        content.body = openSuggestions > 0
            ? String(localized: "\(openSuggestions) Vorschläge warten auf dich.")
            : String(localized: "Deine Fotos sind analysiert.")
        content.sound = .default
        if openSuggestions > 0 { content.categoryIdentifier = NotificationRouter.finishedCategory }
        let request = UNNotificationRequest(identifier: NotificationRouter.finishedIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Answers taps on Albumist's notifications. Set as the notification center's delegate at
/// launch (`SortlyApp.init`), before iOS hands over the tap that opened the app.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()
    static let finishedIdentifier = "analysis.finished"
    static let finishedCategory = "analysis.finished"
    static let reviewAction = "analysis.review"

    /// The category with "Vorschläge prüfen"; opens the app (foreground).
    static func register() {
        let center = UNUserNotificationCenter.current()
        let review = UNNotificationAction(identifier: reviewAction, title: String(localized: "Vorschläge prüfen"), options: [.foreground])
        let finished = UNNotificationCategory(identifier: finishedCategory, actions: [review], intentIdentifiers: [], options: [])
        center.setNotificationCategories([finished])
        center.delegate = shared
    }

    /// The button and a tap on the notification itself both open the suggestions.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        guard category == Self.finishedCategory,
              action == Self.reviewAction || action == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { AppModel.shared.route = .proposals }
    }

    /// While Albumist is open nothing is shown (the card says it); `notifyFinished` posts only
    /// outside the app anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
