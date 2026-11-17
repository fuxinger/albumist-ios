import Darwin
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
    /// Serializes the writes into `stressFile` (the main thread's stall lines, the watch
    /// thread's stack lines).
    private let fileLock = NSLock()

    // Main-thread stacks: taken by the watch thread while a ping waits (at 2 s and 5 s, then at
    // every doubling), so a long stall says where the main thread was, not only how long.
    /// The main thread's port and stack bounds, set in `start()` before the watch thread runs.
    private var mainPort: mach_port_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private static let maxFrames = 48
    /// Filled while the main thread is suspended: nothing may be allocated then (the main thread
    /// may hold the allocator's lock), so the buffer is made once.
    private let frameBuffer = UnsafeMutablePointer<UInt>.allocate(capacity: MainThreadWatch.maxFrames)
    /// Watch thread only: when the current ping's next stack is taken (seconds waited).
    private var nextStackAt: Double = 2

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
        mainPort = mach_thread_self()
        let main = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))
        let thread = Thread { [self] in watch() }
        thread.name = "Albumist main-thread watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// `-SortlyUITestWatchMain` (DeviceConditionUITests test12, ui-stress.yml): besides the lines
    /// above, `UITEST_MAIN_BLOCKED <ms> ms (longest <ms> ms)` for every stall over a second, and
    /// with `-SortlyUITestWatchMainLog <path>` every stall over half a second as
    /// "<end as seconds since 1970> <ms>" in that file of the test runner's.
    /// `lines: false` (only `-SortlyUITestWatchMainLog`, every DeviceConditionUITests launch):
    /// the file without the `UITEST_MAIN_BLOCKED` lines.
    @MainActor
    func watchForStress(log path: String?, lines: Bool = true) {
        let file = path.flatMap { path -> FileHandle? in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        lock.lock()
        stressLines = lines
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
            let took = Self.seconds(from: begin, to: DispatchTime.now().uptimeNanoseconds)
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
            let slept = Self.seconds(from: before, to: now)
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
                nextStackAt = 2
                inactiveInStall = !active
            }
            let waited = pending.map { Self.seconds(from: $0, to: now) } ?? 0
            if waited >= 0.5 {
                let path = sections.isEmpty ? "unmarked" : sections.map { $0.name }.joined(separator: ">")
                if !seenInStall.contains(path) && seenInStall.count < 4 { seenInStall.append(path) }
            }
            let stuck = pending != nil && waited >= nextStuckReport
            if stuck { nextStuckReport *= 2 }
            let since = askedWall
            let names = seenInStall.joined(separator: ", ")
            let current = sections.last.map { "\($0.name) running for \(Self.text(Self.seconds(from: $0.began, to: now))) s" } ?? "no marked section"
            let inactive = inactiveInStall
            lock.unlock()
            if pending != nil, waited >= nextStackAt {
                nextStackAt = nextStackAt < 5 ? 5 : nextStackAt * 2
                reportStack(waited: waited, since: since)
            }
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
        let waited = asked.map { Self.seconds(from: $0, to: now) } ?? 0
        let stress = stressLines, file = stressFile
        if stress, waited > 1 { longestStall = max(longestStall, waited) }
        let longest = longestStall
        lock.unlock()
        guard asked != nil else { return }
        // Written only here, on the main thread.
        if waited > 0.5, let file {
            fileLock.lock()
            file.write(Data(String(format: "%.3f %ld\n", Date().timeIntervalSince1970, Int(waited * 1000)).utf8))
            fileLock.unlock()
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

    // MARK: Main-thread stacks

    /// `UI_MAIN_STACK after 5.0 s of the stall from 18:31:05.2 UTC: <frames>` in the log (the
    /// app's own frames only, so the line stays short), and the whole stack as a `#` line in
    /// the runner's file when there is one (`-SortlyUITestWatchMainLog`; the device tests print
    /// it as `UI_FACT main stack`, which the job log never cuts off).
    private func reportStack(waited: Double, since: Double) {
        guard let stack = captureMainStack() else { return }
        let frames = stack.enumerated().map { Self.symbol($0.element, isReturnAddress: $0.offset > 0) }
        let head = "after \(Self.text(waited)) s of the stall from \(Self.clock(since)) UTC"
        let own = frames.filter { $0.hasPrefix("Sortly") }.prefix(8)
        // In the log from 5 s on only: it keeps 40 of the app's lines, and the stall lines
        // must not be pushed out by stacks.
        if waited >= 5 { note("UI_MAIN_STACK \(head): \(own.isEmpty ? frames.prefix(6).joined(separator: " | ") : own.joined(separator: " | "))") }
        lock.lock()
        let file = stressFile
        lock.unlock()
        guard let file else { return }
        fileLock.lock()
        file.write(Data("# \(head): \(frames.joined(separator: " | "))\n".utf8))
        fileLock.unlock()
    }

    /// The main thread's return addresses, read while it is suspended (frame records:
    /// [previous frame pointer, return address], each one higher on the stack).
    private func captureMainStack() -> [UInt]? {
        guard mainPort != 0, thread_suspend(mainPort) == KERN_SUCCESS else { return nil }
        var count = 0
        var fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainPort, thread_state_flavor_t(6) /* ARM_THREAD_STATE64 */, $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            frameBuffer[0] = Self.strip(UInt(state.__pc))
            // The leaf may not have stored its frame yet: the link register is its caller.
            frameBuffer[1] = Self.strip(UInt(state.__lr))
            count = 2
            fp = UInt(state.__fp)
        }
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainPort, thread_state_flavor_t(4) /* x86_THREAD_STATE64 */, $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            frameBuffer[0] = UInt(state.__rip)
            count = 1
            fp = UInt(state.__rbp)
        }
        #endif
        while count > 0, count < Self.maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
            guard let record = UnsafePointer<UInt>(bitPattern: fp) else { break }
            let next = record[0]
            let returnAddress = Self.strip(record[1])
            if returnAddress == 0 { break }
            frameBuffer[count] = returnAddress
            count += 1
            if next <= fp { break }
            fp = next
        }
        thread_resume(mainPort)
        return count > 0 ? Array(UnsafeBufferPointer(start: frameBuffer, count: count)) : nil
    }

    /// Pointer-authentication bits off a code address (none on the simulator; harmless).
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// "Sortly.debug.dylib AppModel.tick(run:) + 120", Swift names demangled.
    private static func symbol(_ address: UInt, isReturnAddress: Bool) -> String {
        // A return address points after the call; the call is one byte before.
        let lookup = isReturnAddress && address > 0 ? address - 1 : address
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 else {
            return String(format: "?? 0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "??"
        guard let name = info.dli_sname, let start = info.dli_saddr else {
            return "\(image) +0x\(String(address - UInt(bitPattern: info.dli_fbase), radix: 16))"
        }
        let symbol = demangle(String(cString: name))
        let short = symbol.count > 140 ? String(symbol.prefix(140)) + "…" : symbol
        return "\(image) \(short) + \(address - UInt(bitPattern: start))"
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    nonisolated(unsafe) private static let swiftDemangle: Demangle? = {
        guard let handle = dlopen(nil, RTLD_NOW), let found = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(found, to: Demangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return name }
        return name.withCString { pointer in
            guard let result = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }

    /// A line of another part of the app for the same log (UI runs only).
    func report(_ text: String) {
        guard UITestSupport.isRunning else { return }
        note(text)
    }

    private func note(_ text: String) {
        logger.fault("\(text, privacy: .public)")
    }

    /// Never below zero: a time read before the lock can be older than a section the main
    /// thread began meanwhile (an unsigned `now - began` trapped and ended the app in UI run
    /// 43988095437).
    private static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
    private static func text(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    /// Time of day in UTC with tenths ("18:31:05.2"), as the UI tests print it (`UI_FACT clock`).
    static func clock(_ since1970: Double) -> String {
        let day = since1970.truncatingRemainder(dividingBy: 86_400)
        let hours = Int(day / 3600), minutes = Int(day.truncatingRemainder(dividingBy: 3600) / 60)
        let rest = day.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%04.1f", hours, minutes, rest)
    }
}
