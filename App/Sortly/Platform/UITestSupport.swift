import Foundation
import os
import SortlyCore

/// Debug builds started by the UI tests (`-SortlyUITestUnlocked`): no purchase sheet and no
/// system rating prompt, which would cover the screen the test is about to tap.
/// Always false in release builds.
enum UITestSupport {
    static let isRunning: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-SortlyUITestUnlocked")
        #else
        false
        #endif
    }()

    /// `-SortlyUITestDark`: dark mode for the large-text screenshots (the simulator's own
    /// appearance switch does not reach the app reliably on the CI machines).
    static let forcesDarkMode: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-SortlyUITestDark")

    /// The copy of the decisions for the device backup is written and restored as in the
    /// shipped app. UI runs leave it alone unless `-SortlyUITestBackup` asks for it, so one
    /// run does not bring decisions into the next.
    static let allowsSafetyBackup: Bool = !isRunning || ProcessInfo.processInfo.arguments.contains("-SortlyUITestBackup")

    /// `-SortlyUITestRebuildDatabase`: the database is set aside at launch, exactly like
    /// "Neu aufbauen" after a start error, to test that the decisions come back.
    static let rebuildsDatabase: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-SortlyUITestRebuildDatabase")

    /// `-SortlyUITestSlowAnalysis`: every photo takes a little longer, so a UI test can leave
    /// the app and switch tabs while the analysis is still busy (first device test 15.11.).
    static let slowsAnalysis: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-SortlyUITestSlowAnalysis")
}

// MARK: Locked purchase (free-album limit and unlock card)

extension UITestSupport {
    /// `-SortlyUITestLocked`: the purchase is not skipped; free albums count as in the shipped
    /// app and the unlock card appears, so the locked path is tested end to end.
    static let locksPurchase: Bool = isRunning && ProcessInfo.processInfo.arguments.contains("-SortlyUITestLocked")

    /// `-SortlyUITestFreeAlbumsLeft N` (with `-SortlyUITestLocked`): the run starts with N free
    /// albums left.
    static let freeAlbumsLeft: Int? = {
        guard locksPurchase else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SortlyUITestFreeAlbumsLeft"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }()

    private static let lockedPurchaseSuite = "app.albumist.uitest.purchases"

    /// The free-album count of a locked UI run: its own domain, emptied at every launch, so
    /// the count of one run never reaches the next one or the normal runs.
    static func lockedPurchaseDefaults() -> UserDefaults? {
        guard locksPurchase, let defaults = UserDefaults(suiteName: lockedPurchaseSuite) else { return nil }
        defaults.removePersistentDomain(forName: lockedPurchaseSuite)
        return defaults
    }
}

/// The real analyzer with a pause per photo (UI tests only, see `slowsAnalysis`).
struct SlowedAnalyzer: ContentAnalyzing {
    var base: any ContentAnalyzing

    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        try await Task.sleep(for: .milliseconds(150))
        return try await base.analyzeContent(asset, request: request)
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        try await base.recognizeText(asset, allowNetwork: allowNetwork)
    }
}

// MARK: Main-thread watch

/// UI runs only (`-SortlyUITestUnlocked`): writes a fault to the system log when the main
/// thread did not answer for a second or more, and when the whole process got no time (the
/// watch's own 0.2 s sleep took seconds). The UI workflow prints the app's fault lines
/// (`UI_RUNTIME_WARNING`), so a run whose UI queries time out ("Failed to get matching
/// snapshots: Timed out while evaluating UI query", runs 43893790053 and 43918684247) says
/// whether Albumist blocked its main thread or the simulator stood still.
final class MainThreadWatch: @unchecked Sendable {
    static let shared = MainThreadWatch()
    private let logger = Logger(subsystem: "app.albumist.ios", category: "uitest")
    private let lock = NSLock()
    /// Uptime (ns) of the ping the main thread has not answered yet.
    private var askedAt: UInt64?
    private var reportedStuck = false
    private var started = false

    func start() {
        guard UITestSupport.isRunning else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in watch() }
        thread.name = "Albumist main-thread watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func watch() {
        while true {
            let before = DispatchTime.now().uptimeNanoseconds
            Thread.sleep(forTimeInterval: 0.2)
            let now = DispatchTime.now().uptimeNanoseconds
            let slept = Self.seconds(now - before)
            if slept >= 1.5 {
                note("UI_PROCESS_STALL the watch slept \(Self.text(slept)) s instead of 0.2 s (the whole process got no time)")
            }
            lock.lock()
            let pending = askedAt
            if pending == nil { askedAt = now }
            let waited = pending.map { Self.seconds(now - $0) } ?? 0
            let stuck = pending != nil && waited >= 10 && !reportedStuck
            if stuck { reportedStuck = true }
            lock.unlock()
            if stuck { note("UI_MAIN_STALL the main thread has not answered for \(Self.text(waited)) s") }
            if pending == nil {
                DispatchQueue.main.async { [self] in answered() }
            }
        }
    }

    private func answered() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let asked = askedAt
        askedAt = nil
        reportedStuck = false
        lock.unlock()
        guard let asked else { return }
        let waited = Self.seconds(now - asked)
        if waited >= 1 { note("UI_MAIN_STALL the main thread was blocked for \(Self.text(waited)) s") }
    }

    private func note(_ text: String) {
        logger.fault("\(text, privacy: .public)")
    }

    private static func seconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000_000 }
    private static func text(_ seconds: Double) -> String { String(format: "%.1f", seconds) }
}
