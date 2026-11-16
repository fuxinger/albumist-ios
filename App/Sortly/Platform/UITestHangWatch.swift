#if DEBUG
import Darwin
import Foundation
import os
import UIKit

// UI runs only (`-SortlyUITestUnlocked`, debug builds; this file does not exist in a release
// build). Measures three of the owner's limits inside the app, where they can be measured
// exactly, and writes them as JSON lines into a file both the UI tests and the Mac read
// (`UITestReports`):
//
// - Hangs: the main thread did not answer for `HangWatch.limit` (250 ms) or longer. Each one
//   carries the main thread's stack, taken while it was blocked (at 250 ms, 1 s, 4 s, 16 s),
//   symbolicated in the app (dladdr, Swift names demangled), so a red run says WHERE.
//   The UI tests fail the running test on a hang (`HangGate` in SortlyUITests), and
//   ui_tests.py fails the group and prints every stack (`UI_HANG` lines, job summary).
// - Cold start: from the process start (the kernel's start time of this process) until the
//   first usable screen: the app is active, the model has left `.loading`, and the main thread
//   answered once after that (the frame with the screen is on its way). Checked against 1 s by
//   `LimitsUITests.test1_ColdStartUnderOneSecond`.
// - Pause: from the moment the model shows "Wird angehalten" until the analysis no longer
//   runs (it finishes the photos in work, one per lane). Checked by
//   `LimitsUITests.test2_PauseAndDisplayLimits`.
//
// Not a hang of the app, written with `"gate": false` and the reason (never counted silently):
// - `launch`: before the app was active for the first time. The launch is measured as a whole
//   by the cold-start limit (1 s), which is where a slow launch fails.
// - `app not active`: the app was in the background or behind a system alert at some point of
//   the block; the user could not touch it then, and iOS may hold a background main thread.
// - `process stall`: this watch's own thread got no time for longer than the limit either: the
//   whole process (or the simulator) stood still, not the app's main-thread code.
// - `XCTest`: every stack taken shows XCTest's automation code on the main thread (a snapshot
//   of the screen or an accessibility audit the UI test asked for): the test's own work.
//
// The ping is every 50 ms, so a block is measured up to 50 ms short; it is never measured
// long. Other UI-run watches (`MainThreadWatch`) stay as they are; this one only adds.

/// Where the app's measurements for the UI tests go. On the simulator every process of the
/// device (the app, the UI test runner) sees the device's data folder, and the Mac sees it at
/// ~/Library/Developer/CoreSimulator/Devices/<UDID>/data. The same rule is in
/// SortlyUITests/QualityLimits.swift (`UITestReports`) and in .github/scripts/ui_tests.py.
enum UITestReports {
    static let fileName = "albumist-uitest-reports.jsonl"

    static var directory: String? {
        let environment = ProcessInfo.processInfo.environment
        if let shared = environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"], !shared.isEmpty {
            return shared + "/tmp"
        }
        if let home = environment["HOME"], let range = home.range(of: "/data/Containers/") {
            return String(home[..<range.lowerBound]) + "/data/tmp"
        }
        return nil
    }

    static var path: String? { directory.map { $0 + "/" + fileName } }
}

final class HangWatch: @unchecked Sendable {
    /// The main thread blocked this long or longer is a hang (the owner's limit; Apple's
    /// definition of a hang). The one place of this number: the UI tests and ui_tests.py
    /// take the app's `"gate"` decision as it is.
    static let limit: TimeInterval = 0.25
    /// How often the main thread is asked; also how much a block can be measured short.
    static let pingInterval: TimeInterval = 0.05
    /// When a block's stack is taken (seconds blocked); a long block shows where it moved.
    static let stackMoments: [TimeInterval] = [limit, 1, 4, 16]
    /// A block this long is written once while it lasts, so a block that never ends (or ends
    /// with the app being killed) is reported too.
    static let ongoingAfter: TimeInterval = 5
    static let maxFrames = 64
    /// Full reports (with stacks) per stack signature; after that a hang is written without
    /// its stacks (`"repeat"`), so a stall in a loop does not flood the file.
    static let fullReportsPerSignature = 3

    static let shared = HangWatch()

    private let logger = Logger(subsystem: "app.albumist.ios", category: "uitest-limits")
    private let lock = NSLock()
    private var started = false
    /// The main thread's Mach port and stack bounds (set once, on the main thread).
    private var mainPort: mach_port_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    /// Written only by the watch thread while the main thread is suspended (no allocation then).
    private let frameBuffer = UnsafeMutablePointer<UInt>.allocate(capacity: HangWatch.maxFrames)
    /// Set on the main thread, read by the watch thread (under `lock`).
    private var answeredPing = 0
    private var answeredAt: UInt64 = 0
    private var appActive = false
    private var everActive = false
    private var inactiveSincePing = false
    /// Main thread only.
    private var launchMeasured = false
    private var launchPending = false
    private var pauseSeenAt: Date?
    /// Watch thread only.
    private var reportsPerSignature: [String: Int] = [:]
    private var file: FileHandle?
    private let processStart = HangWatch.processStartTime()

    @MainActor
    func start() {
        guard UITestSupport.isRunning else { return }
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        mainPort = mach_thread_self()
        let main = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))
        appActive = UIApplication.shared.applicationState == .active
        everActive = appActive
        if let directory = UITestReports.directory, let path = UITestReports.path {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            file = FileHandle(forWritingAtPath: path)
            logger.error("UITEST_REPORTS \(path, privacy: .public)")
        }
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [self] _ in setActive(true) }
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [self] _ in setActive(false) }
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [self] _ in setActive(false) }
        let thread = Thread { [self] in watch() }
        thread.name = "Albumist hang watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func setActive(_ value: Bool) {
        lock.lock()
        appActive = value
        if value { everActive = true } else { inactiveSincePing = true }
        lock.unlock()
    }

    // MARK: Watch thread

    private func watch() {
        var ping = 0
        while true {
            ping += 1
            let id = ping
            let pinged = Self.now()
            let pingedWall = Date().timeIntervalSince1970
            lock.lock()
            let launching = !everActive
            inactiveSincePing = !appActive
            lock.unlock()
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { answer(id) }
            }
            var stacks: [[UInt]] = []
            var moment = 0
            var processStall = false
            var ongoingWritten = false
            var last = pinged
            var answered: UInt64?
            while answered == nil {
                Thread.sleep(forTimeInterval: Self.pingInterval)
                let now = Self.now()
                // This thread slept far longer than asked: the whole process got no time.
                if Self.seconds(now - last) >= Self.limit + Self.pingInterval { processStall = true }
                last = now
                lock.lock()
                if answeredPing == id { answered = answeredAt }
                lock.unlock()
                if answered != nil { break }
                let waited = Self.seconds(now - pinged)
                if moment < Self.stackMoments.count, waited >= Self.stackMoments[moment] {
                    if let stack = captureMainStack() { stacks.append(stack) }
                    moment += 1
                }
                if !ongoingWritten, waited >= Self.ongoingAfter {
                    ongoingWritten = true
                    lock.lock()
                    let inactive = inactiveSincePing
                    lock.unlock()
                    report(ms: Int(waited * 1000), from: pingedWall, stacks: stacks, launching: launching,
                           inactive: inactive, processStall: processStall, ongoing: true)
                }
            }
            let blocked = Self.seconds((answered ?? pinged) - pinged)
            if blocked >= Self.limit {
                lock.lock()
                let inactive = inactiveSincePing
                lock.unlock()
                report(ms: Int(blocked * 1000), from: pingedWall, stacks: stacks, launching: launching,
                       inactive: inactive, processStall: processStall, ongoing: false)
            }
            Thread.sleep(forTimeInterval: Self.pingInterval)
        }
    }

    /// The main thread's return addresses, read while it is suspended. Nothing is allocated
    /// between suspend and resume (the main thread may hold the allocator's lock): the frame
    /// records are read into a buffer made once, within the main thread's stack bounds only.
    private func captureMainStack() -> [UInt]? {
        guard mainPort != 0, thread_suspend(mainPort) == KERN_SUCCESS else { return nil }
        var count = 0
        var pc: UInt = 0
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
            pc = UInt(state.__pc)
            fp = UInt(state.__fp)
            frameBuffer[0] = Self.strip(pc)
            count = 1
            // The leaf may not have stored its frame yet: the link register is the caller.
            if count < Self.maxFrames {
                frameBuffer[count] = Self.strip(UInt(state.__lr))
                count += 1
            }
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
            pc = UInt(state.__rip)
            fp = UInt(state.__rbp)
            frameBuffer[0] = pc
            count = 1
        }
        #endif
        // Frame records: [previous frame pointer, return address], each one higher on the stack.
        while count < Self.maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
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
        _ = pc
        return count > 0 ? Array(UnsafeBufferPointer(start: frameBuffer, count: count)) : nil
    }

    /// Pointer-authentication bits off a code address (none on the arm64 simulator; harmless).
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    // MARK: Reports

    private func report(ms: Int, from wall: Double, stacks: [[UInt]], launching: Bool, inactive: Bool,
                        processStall: Bool, ongoing: Bool) {
        let symbolicated = stacks.map { stack in stack.enumerated().map { Self.symbol($0.element, isReturnAddress: $0.offset > 0) } }
        let xctestOnly = !symbolicated.isEmpty && symbolicated.allSatisfy { $0.contains(where: Self.isXCTestFrame) }
        let reason: String? = if launching { "launch" }
            else if inactive { "app not active" }
            else if processStall { "process stall" }
            else if xctestOnly { "XCTest" }
            else { nil }
        let signature = symbolicated.first.map { Self.signature($0) } ?? "no stack"
        var record: [String: Any] = [
            "kind": "hang", "pid": Int(getpid()), "start": wall, "ms": ms, "limitMs": Int(Self.limit * 1000),
            "gate": reason == nil, "signature": signature, "ongoing": ongoing,
        ]
        if let reason { record["reason"] = reason }
        let seen = reportsPerSignature[signature, default: 0]
        if !ongoing { reportsPerSignature[signature] = seen + 1 }
        if seen < Self.fullReportsPerSignature {
            record["stacks"] = symbolicated
        } else {
            record["repeat"] = seen + 1
        }
        write(record)
        let kind = reason ?? "gate"
        logger.error("UI_HANG \(ms, privacy: .public) ms \(kind, privacy: .public) \(signature, privacy: .public)")
    }

    private func write(_ record: [String: Any]) {
        guard let file, let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        lock.lock()
        defer { lock.unlock() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data + Data("\n".utf8))
    }

    /// "Sortly.debug.dylib AppModel.tick() + 120", Swift names demangled.
    private static func symbol(_ address: UInt, isReturnAddress: Bool) -> String {
        // A return address points after the call; the call itself is one byte before.
        let lookup = isReturnAddress && address > 0 ? address - 1 : address
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 else {
            return String(format: "?? 0x%lx", address)
        }
        let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "??"
        guard let name = info.dli_sname, let start = info.dli_saddr else {
            let base = UInt(bitPattern: info.dli_fbase)
            return "\(image) +0x\(String(address - base, radix: 16))"
        }
        let offset = address - UInt(bitPattern: start)
        return "\(image) \(demangle(String(cString: name))) + \(offset)"
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    nonisolated(unsafe) private static let swiftDemangle: Demangle? = {
        guard let handle = dlopen(nil, RTLD_NOW), let found = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(found, to: Demangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") || name.hasPrefix("_T"),
              let swiftDemangle else { return name }
        return name.withCString { pointer in
            guard let result = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }

    /// XCTest's automation code in the app (snapshots, accessibility audits, synthesized events).
    static func isXCTestFrame(_ frame: String) -> Bool {
        ["XCTAutomationSupport", "XCTestCore", "XCTest ", "libXCTestBundleInject", "XCUIAutomation"].contains { frame.contains($0) }
    }

    /// The first frames of the app's own code (Sortly), else the first frames: the same hang
    /// at the same place gives the same signature.
    static func signature(_ frames: [String]) -> String {
        let own = frames.filter { $0.hasPrefix("Sortly") }
        let chosen = (own.isEmpty ? frames : own).prefix(3).map { frame in
            frame.split(separator: " ").dropFirst().joined(separator: " ").components(separatedBy: " + ").first ?? frame
        }
        return chosen.joined(separator: " < ")
    }

    // MARK: Main thread

    @MainActor
    private func answer(_ id: Int) {
        let now = Self.now()
        let active = UIApplication.shared.applicationState == .active
        lock.lock()
        answeredPing = id
        answeredAt = now
        if !active { inactiveSincePing = true }
        appActive = active
        if active { everActive = true }
        lock.unlock()
        observeLaunch(active: active)
        observePause()
    }

    /// First usable screen: active, past `.loading`, and one more turn of the main thread
    /// (the frame that shows the screen is committed in the turn the state changed).
    @MainActor
    private func observeLaunch(active: Bool) {
        guard !launchMeasured, !launchPending, active, AppModel.shared.phase != .loading else { return }
        launchPending = true
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                launchMeasured = true
                guard let processStart else { return }
                let ms = Int(Date().timeIntervalSince(processStart) * 1000)
                write(["kind": "launch", "pid": Int(getpid()), "start": processStart.timeIntervalSince1970,
                       "ms": ms, "phase": "\(AppModel.shared.phase)"])
                logger.error("UI_LAUNCH \(ms, privacy: .public) ms to the first usable screen")
            }
        }
    }

    /// "Wird angehalten" (the model's `pausing`) until the analysis no longer runs.
    @MainActor
    private func observePause() {
        let analysis = AppModel.shared.analysis
        if analysis.isRunning, analysis.pausing {
            if pauseSeenAt == nil { pauseSeenAt = Date() }
        } else if let seen = pauseSeenAt {
            pauseSeenAt = nil
            let stopped = !analysis.isRunning
            write(["kind": "pause", "pid": Int(getpid()), "start": seen.timeIntervalSince1970,
                   "stopMs": Int(Date().timeIntervalSince(seen) * 1000), "stopped": stopped])
        }
    }

    // MARK: Time

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000_000 }

    /// The kernel's start time of this process (wall clock).
    private static func processStartTime() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
#endif
