import Foundation

/// Which app process the next end of the app is about (`UITestAppEnd.end`): the one the last
/// launch started. Plain Foundation, so SwiftPM also builds it on Linux (target
/// `SortlyUITestLogic`, tests in `UITestLaunchRecordTests`).
///
/// The app writes "@ <pid> <start> <now>" first thing into the file of
/// `-SortlyUITestWatchMainLog` (anew at every launch). The id used to come from the arguments of
/// the `XCUIApplication` being ended, but the first launch of every test ends the app of the
/// test before through a new `XCUIApplication` without arguments: no id, so the Mac fell back to
/// `simctl terminate` by bundle id, whose late end can hit the new launch (945446e) and which
/// hung (device test08, job 135412549414: 114 s). Every launch goes through
/// `UITestAppEnd.launch`, which notes it here; the test runner keeps this record from test to
/// test (a new runner after a crash starts without one).
final class UITestLaunchRecord: @unchecked Sendable {
    static let shared = UITestLaunchRecord()

    private let lock = NSLock()
    /// The watch file of the last launch; nil before the first one of this test runner.
    private var file: String?
    /// The id read from that file (kept when `UITestStalls.report` removes the file).
    private var pid: Int32?

    /// The file named by `-SortlyUITestWatchMainLog` in launch arguments.
    static func watchFile(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "-SortlyUITestWatchMainLog"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    /// The process id in the text of a watch file: its last "@ <pid> <start> <now>" line.
    static func processID(inText text: String) -> Int32? {
        let line = text.split(separator: "\n").last { $0.hasPrefix("@ ") }
        let parts = line?.split(separator: " ") ?? []
        return parts.count >= 2 ? Int32(parts[1]) : nil
    }

    /// A launch with these arguments starts now: its app is the one the next end is about.
    func launching(_ arguments: [String]) {
        lock.lock()
        file = Self.watchFile(in: arguments)
        pid = nil
        lock.unlock()
    }

    /// A watch file was read (`UITestStalls.report`, before it removes the file): the id of the
    /// last launch's app stays known.
    func read(_ text: String, of path: String) {
        guard let id = Self.processID(inText: text) else { return }
        lock.lock()
        if path == file { pid = id }
        lock.unlock()
    }

    /// The process id of the app the last launch started: read from its watch file, else the id
    /// read from it before (the file was removed). Without a known launch (a new test runner)
    /// the file `fallback` is read: the arguments of the app to end, or the default stall file.
    func processID(fallback: String?, read: (String) -> String?) -> Int32? {
        lock.lock()
        let known = file
        let kept = pid
        lock.unlock()
        guard let source = known ?? fallback else { return nil }
        if let text = read(source), let id = Self.processID(inText: text) {
            if known != nil { self.read(text, of: source) }
            return id
        }
        return known != nil ? kept : nil
    }
}
