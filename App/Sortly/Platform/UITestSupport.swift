import Foundation
import os
import SortlyCore
import UIKit

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

    /// Handed on: without the preview prefetch every photo of a slowed run came back
    /// unreadable (UI run 43753915509, "246 Fotos konnten noch nicht gelesen werden").
    func willAnalyze(_ upcoming: [AssetSnapshot]) async {
        await base.willAnalyze(upcoming)
    }
}

// MARK: Main-thread watch

/// UI runs only (`-SortlyUITestUnlocked`): writes a fault to the system log when the main
/// thread did not answer, and when the whole process got no time (the watch's own 0.2 s sleep
/// took seconds). The UI workflow prints the app's fault lines (`UI_RUNTIME_WARNING`, the 40
/// most frequent distinct lines), so a run whose UI queries time out ("Failed to get matching
/// snapshots: Timed out while evaluating UI query", runs 43893790053 and 43918684247) says
/// whether Albumist blocked its main thread or the simulator stood still.
///
/// Lines (kept few, so the 40 printed lines hold them):
/// - `UI_MAIN_STALL 12.3 s from 18:31:05.2 UTC in <section>`: every stall of 2 s or more, with
///   its start (the test prints `UI_FACT clock` lines on the same clock) and the marked section the
///   main thread was in while it did not answer (`unmarked`: SwiftUI, UIKit or XCTest's own
///   work, such as an accessibility audit, which runs on the app's main thread)
/// - `UI_MAIN_STALL 1-2 s in <section>`: shorter stalls, counted per section
/// - `UI_MAIN_SLOW <section> 250 ms to 1 s` / `UI_MAIN_SLOW <section> 3.4 s`: a marked section
///   that took that long (`section(_:_:)`), shorter ones counted per section
/// - `UI_MAIN_STALL the main thread has not answered for 10.0 s ...`: a hang, again at 20, 40,
///   80 s ..., with the section it hangs in and how long that section has been running
/// Stall lines end in `(app not active)` when the app was in the background or behind a
/// system alert during the stall: the system may hold back a main thread then.
final class MainThreadWatch: @unchecked Sendable {
    static let shared = MainThreadWatch()
    private let logger = Logger(subsystem: "app.albumist.ios", category: "uitest")
    private let lock = NSLock()
    /// Uptime (ns) and wall clock (s since 1970) of the ping the main thread has not answered yet.
    private var askedAt: UInt64?
    private var askedWall: Double = 0
    /// The hang report of the current ping is written again once the wait reaches this (s).
    private var nextStuckReport: Double = 10
    private var started = false
    /// Marked sections the main thread is in now, outermost first, with their start (uptime
    /// ns); changed on the main thread.
    private var sections: [(name: String, began: UInt64)] = []
    /// The sections seen while the current ping was not answered.
    private var seenInStall: [String] = []
    /// The app is foreground-active (changed on the main thread by the app's notifications).
    private var active = true
    /// The app was not active at some point while the current ping waited.
    private var inactiveInStall = false
    /// `-SortlyUITestWatchMain` (stress runs, `watchForStress`): `UITEST_MAIN_BLOCKED` lines,
    /// and every stall over half a second in the test runner's file.
    private var stressLines = false
    private var stressFile: FileHandle?
    private var longestStall: Double = 0

    @MainActor
    func start() {
        guard UITestSupport.isRunning else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [self] _ in setActive(true) }
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [self] _ in setActive(false) }
        let thread = Thread { [self] in watch() }
        thread.name = "Albumist main-thread watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// `-SortlyUITestWatchMain` (DeviceConditionUITests test12, ui-stress.yml): besides the lines
    /// above, `UITEST_MAIN_BLOCKED <ms> ms (longest <ms> ms)` for every stall over a second, and
    /// with `-SortlyUITestWatchMainLog <path>` every stall over half a second as
    /// "<end as seconds since 1970> <ms>" in that file of the test runner's.
    @MainActor
    func watchForStress(log path: String?) {
        let file = path.flatMap { path -> FileHandle? in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        lock.lock()
        stressLines = true
        stressFile = file
        lock.unlock()
        start()
    }

    private func setActive(_ value: Bool) {
        lock.lock()
        active = value
        if !value { inactiveInStall = true }
        lock.unlock()
    }

    /// Marks main-thread work, so a stall line names it. Costs nothing outside UI runs.
    @discardableResult
    func section<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard UITestSupport.isRunning, Thread.isMainThread else { return try body() }
        let begin = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        sections.append((name, begin))
        lock.unlock()
        defer {
            lock.lock()
            if !sections.isEmpty { sections.removeLast() }
            lock.unlock()
            let took = Self.seconds(DispatchTime.now().uptimeNanoseconds - begin)
            if took >= 1 {
                note("UI_MAIN_SLOW \(name) \(Self.text(took)) s")
            } else if took >= 0.25 {
                note("UI_MAIN_SLOW \(name) 250 ms to 1 s")
            }
        }
        return try body()
    }

    private func watch() {
        while true {
            let before = DispatchTime.now().uptimeNanoseconds
            Thread.sleep(forTimeInterval: 0.2)
            let now = DispatchTime.now().uptimeNanoseconds
            let slept = Self.seconds(now - before)
            if slept >= 1.5 {
                note("UI_PROCESS_STALL the watch slept \(Self.text(slept)) s instead of 0.2 s from \(Self.clock(Date().timeIntervalSince1970 - slept)) UTC (the whole process got no time)")
            }
            lock.lock()
            let pending = askedAt
            if pending == nil {
                askedAt = now
                askedWall = Date().timeIntervalSince1970
                seenInStall = []
                nextStuckReport = 10
                inactiveInStall = !active
            }
            let waited = pending.map { Self.seconds(now - $0) } ?? 0
            if waited >= 0.5 {
                let path = sections.isEmpty ? "unmarked" : sections.map { $0.name }.joined(separator: ">")
                if !seenInStall.contains(path) && seenInStall.count < 4 { seenInStall.append(path) }
            }
            let stuck = pending != nil && waited >= nextStuckReport
            if stuck { nextStuckReport *= 2 }
            let since = askedWall
            let names = seenInStall.joined(separator: ", ")
            let current = sections.last.map { "\($0.name) running for \(Self.text(Self.seconds(now - $0.began))) s" } ?? "no marked section"
            let inactive = inactiveInStall
            lock.unlock()
            if stuck {
                note("UI_MAIN_STALL the main thread has not answered for \(Self.text(waited)) s, since \(Self.clock(since)) UTC, in \(names) (now \(current))\(Self.tag(inactive))")
            }
            if pending == nil {
                DispatchQueue.main.async { [self] in answered() }
            }
        }
    }

    private func answered() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let asked = askedAt
        let since = askedWall
        let names = seenInStall.isEmpty ? "unmarked" : seenInStall.joined(separator: ", ")
        let inactive = inactiveInStall
        askedAt = nil
        let waited = asked.map { Self.seconds(now - $0) } ?? 0
        let stress = stressLines, file = stressFile
        if stress, waited > 1 { longestStall = max(longestStall, waited) }
        let longest = longestStall
        lock.unlock()
        guard asked != nil else { return }
        // Written only here, on the main thread.
        if waited > 0.5, let file {
            file.write(Data(String(format: "%.3f %ld\n", Date().timeIntervalSince1970, Int(waited * 1000)).utf8))
        }
        if stress, waited > 1 {
            NSLog("UITEST_MAIN_BLOCKED %ld ms (longest %ld ms)", Int(waited * 1000), Int(longest * 1000))
        }
        if waited >= 2 {
            note("UI_MAIN_STALL \(Self.text(waited)) s from \(Self.clock(since)) UTC in \(names)\(Self.tag(inactive))")
        } else if waited >= 1 {
            note("UI_MAIN_STALL 1-2 s in \(names)\(Self.tag(inactive))")
        }
    }

    private static func tag(_ inactive: Bool) -> String { inactive ? " (app not active)" : "" }

    private func note(_ text: String) {
        logger.fault("\(text, privacy: .public)")
    }

    private static func seconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000_000 }
    private static func text(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    /// Time of day in UTC with tenths ("18:31:05.2"), as the UI tests print it (`UI_FACT clock`).
    static func clock(_ since1970: Double) -> String {
        let day = since1970.truncatingRemainder(dividingBy: 86_400)
        let hours = Int(day / 3600), minutes = Int(day.truncatingRemainder(dividingBy: 3600) / 60)
        let rest = day.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%04.1f", hours, minutes, rest)
    }
}
