import Foundation
import XCTest

/// The owner's measurable quality limits (16.11.), in one place for the UI tests. What is
/// measured where (so nothing is measured twice in two ways):
///
/// | Limit | Home | Fails |
/// |---|---|---|
/// | Main thread blocked ≥ 250 ms | the app (`HangWatch.limit`, App/Sortly/Platform/UITestHangWatch.swift), with the stack | the running UI test (`HangGate`) and the group (ui_tests.py) |
/// | Pause reacts < 1 s | `LimitsUITests.test2` (card changes in the tap's own call; no hang); stress test12 | the test |
/// | No display still > 10 s while working | Linux model (FullRunDisplayTests invariant 8, QualityLimitPropertyTests); app: `CardLimits` in LimitsUITests.test2 and stress test12 | the test |
/// | No number backwards, no false "fertig" | Linux model (FullRunDisplayTests invariant 3, QualityLimitPropertyTests); app: `CardLimits` | the test |
/// | 50,000 photos without a crash | ui-stress.yml + DeviceConditionUITests.test12 | the stress run |
/// | Cold start < 1 s | the app measures it (process start to first usable screen); `LimitsUITests.test1` asserts | the test |
/// | Memory | measured by ui-stress.yml (`STRESS_MEMORY_MAX`), no limit yet: `memoryLimitMB` | nothing until a number is set |
///
/// `XCTApplicationLaunchMetric` and the other XCTMetrics in `PerformanceUITests` only report
/// (with baselines in Xcode), they never gate: the shared Macs vary too much.
enum QualityLimits {
    /// Pause: the card reacts (shows "Wird angehalten") within this.
    static let pauseReaction: TimeInterval = 1
    /// Pause: the analysis really stops within this on the owner's iPhone, where a photo in work
    /// takes about `devicePhotoSeconds`. The pipeline finishes the photo each lane has in work
    /// (it does not cancel Vision), so on the CI simulator, whose Vision takes several seconds
    /// per photo, the budget is that photo's measured time plus the rest of the device budget
    /// (`pauseStopLimit`). Never less than the owner's 1 s.
    static let pauseStop: TimeInterval = 1
    static let devicePhotoSeconds: TimeInterval = 0.4
    static func pauseStopLimit(photoSeconds: TimeInterval) -> TimeInterval {
        max(pauseStop, photoSeconds + (pauseStop - devicePhotoSeconds))
    }
    /// No progress display stands still longer than this while the analysis works.
    static let displayStill: TimeInterval = 10
    /// Cold start: process start until the first usable screen (measured by the app).
    static let coldStart: TimeInterval = 1
    /// Memory of the app in the 50,000-photo stress run. TODO(memory-limit): no limit until it
    /// is measured; ui-stress.yml prints STRESS_MEMORY_MAX per phase and checks
    /// `STRESS_MEMORY_LIMIT_MB` (empty for now) once the owner sets a number from those runs.
    static let memoryLimitMB: Int? = nil
}

/// The app's measurements (App/Sortly/Platform/UITestHangWatch.swift writes them; same path
/// rule as there and in .github/scripts/ui_tests.py).
enum UITestReports {
    static let fileName = "albumist-uitest-reports.jsonl"

    static var path: String? {
        let environment = ProcessInfo.processInfo.environment
        if let shared = environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"], !shared.isEmpty {
            return shared + "/tmp/" + fileName
        }
        if let home = environment["HOME"], let range = home.range(of: "/data/Containers/") {
            return String(home[..<range.lowerBound]) + "/data/tmp/" + fileName
        }
        return nil
    }

    /// Size of the file now (records after this offset are new).
    static func size() -> UInt64 {
        guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Records written after `offset` (whole lines only), and the offset after them.
    static func records(after offset: UInt64) -> (records: [[String: Any]], end: UInt64) {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return ([], offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }
        let complete = data[data.startIndex...last]
        let records = complete.split(separator: UInt8(ascii: "\n")).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
        return (records, offset + UInt64(complete.count))
    }

    /// Records of `kind` that began at or after `since`.
    static func records(_ kind: String, since: Date) -> [[String: Any]] {
        records(after: 0).records.filter {
            $0["kind"] as? String == kind && (($0["start"] as? Double) ?? 0) >= since.timeIntervalSince1970 - 0.5
        }
    }

    static func clock(_ since1970: Double) -> String {
        let day = since1970.truncatingRemainder(dividingBy: 86_400)
        return String(format: "%02d:%02d:%04.1f", Int(day / 3600), Int(day.truncatingRemainder(dividingBy: 3600) / 60),
                      day.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: Hang gate

/// Registered for every UI test by the bundle's principal class (project.yml,
/// NSPrincipalClass = AlbumistUITestLimits). While a test runs it reads the app's hang reports
/// every second and fails the running test on every hang the app marked `"gate": true`, with
/// the main thread's stack in the failure. Hangs the app did not gate (launch, app not active,
/// process stall, XCTest's own snapshot) are printed with their reason, never failed. A hang
/// that arrives after the test's last run-loop turn is printed (`UI_HANG gate … after the
/// test`); ui_tests.py fails the group on it from the same file.
@MainActor
final class HangGate: NSObject, @preconcurrency XCTestObservation {
    static let shared = HangGate()

    private var current: XCTestCase?
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var seen = Set<String>()

    func testCaseWillStart(_ testCase: XCTestCase) {
        current = testCase
        offset = UITestReports.size()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { HangGate.shared.check(final: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        check(final: true)
        timer?.invalidate()
        timer = nil
        current = nil
    }

    private func check(final: Bool) {
        guard current != nil else { return }
        let (records, end) = UITestReports.records(after: offset)
        offset = end
        for record in records {
            switch record["kind"] as? String {
            case "hang": hang(record, final: final)
            case "launch": print("UI_LAUNCH \(record["ms"] ?? "?") ms to the first usable screen (pid \(record["pid"] ?? "?"))")
            case "pause": print("UI_PAUSE stopped \(record["stopMs"] ?? "?") ms after \"Wird angehalten\" (stopped: \(record["stopped"] ?? "?"))")
            default: break
            }
        }
    }

    private func hang(_ record: [String: Any], final: Bool) {
        let ms = record["ms"] as? Int ?? 0
        let start = record["start"] as? Double ?? 0
        let key = "\(record["pid"] ?? "")-\(start)"
        let ongoing = record["ongoing"] as? Bool ?? false
        let gate = record["gate"] as? Bool ?? false
        let signature = record["signature"] as? String ?? "no stack"
        let limit = record["limitMs"] as? Int ?? 250
        let stacks = record["stacks"] as? [[String]] ?? []
        let when = UITestReports.clock(start)
        guard gate else {
            print("UI_HANG info (\(record["reason"] ?? "?")) \(ms) ms from \(when) UTC in \(signature)")
            return
        }
        // An ongoing report and the final one of the same block: one failure.
        if seen.contains(key) { return }
        seen.insert(key)
        let frames = stacks.first ?? []
        print("UI_HANG gate \(ms)\(ongoing ? "+" : "") ms (limit \(limit) ms) from \(when) UTC in \(signature)\(final ? " (after the test)" : "")")
        for (index, stack) in stacks.enumerated() {
            for frame in stack.prefix(40) { print("UI_HANG_FRAME \(index + 1) \(frame)") }
        }
        guard !final, let current, current.continueAfterFailure else { return }
        let own = frames.filter { $0.hasPrefix("Sortly") }.prefix(6)
        var issue = XCTIssue(type: .assertionFailure,
                             compactDescription: "The app's main thread was blocked \(ms)\(ongoing ? "+" : "") ms (limit \(limit) ms) from \(when) UTC in \(signature)",
                             detailedDescription: (own.isEmpty ? frames.prefix(12) : own).joined(separator: "\n"))
        issue.add(XCTAttachment(string: stacks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")))
        current.record(issue)
    }
}

/// The UI test bundle's principal class: XCTest makes one when it loads the bundle, before the
/// first test, so every UI test class gets the hang gate without a line in its own file.
@objc(AlbumistUITestLimits)
final class AlbumistUITestLimits: NSObject {
    override init() {
        super.init()
        MainActor.assumeIsolated {
            XCTestObservationCenter.shared.addTestObserver(HangGate.shared)
        }
    }
}

// MARK: The analysis card against the limits

/// Feeds what the analysis card says (its label and value, as VoiceOver reads it: "Bilder
/// werden angeschaut" / "120 von 412 Fotos, fertig gegen 23:40, Schritt 4 von 6, Analyse zu
/// 37 % fertig") into the limits, one look at a time:
/// - the percentage never goes back; only a phase of its own may start again, and only with
///   its new title ("Neue Fotos werden analysiert", …, `ResumedRun.NewWork`);
/// - the count never goes back within a step (same step, same total), the step never back;
/// - never "fertig" while work remains: no "Analyse fertig" title and no 100 % while the
///   analysis runs (Pause shown), and never 100 % next to a count below its total;
/// - while the analysis works (not pausing, paused, waiting or a quick check) the text changes
///   at least every 10 s. Measured as a lower bound: from the first look that saw a text to the
///   last look that still saw it, so a slow look (XCTest's snapshot) never counts as stillness.
struct CardLimits {
    struct Look {
        var title: String
        var value: String
        var running: Bool
        var at: Date
    }

    static let phaseTitles = ["Neue Fotos werden analysiert", "Weitere neue Fotos werden analysiert",
                              "Analyse nach Update", "Analyse nach erneutem Update"]
    /// Titles of a card that is not working, so it may stand still (it says why).
    static let restingTitles = ["Wird angehalten", "Analyse pausiert", "Wartet", "Sucht neue Fotos", "Analyse fertig"]

    private(set) var violations: [String] = []
    private(set) var longestStill: (seconds: TimeInterval, text: String) = (0, "")
    private var lastPercent: Int?
    private var lastTitle = ""
    private var lastCount: (step: Int, done: Int, total: Int)?
    private var text = ""
    private var firstSeen: Date?
    private var lastSeen: Date?

    static func percent(_ value: String) -> Int? {
        value.firstMatch(of: #/Analyse zu (\d+) % fertig/#).flatMap { Int($0.1) }
    }

    static func count(_ value: String) -> (step: Int, done: Int, total: Int)? {
        let digits = value.replacingOccurrences(of: ".", with: "")
        guard let s = digits.firstMatch(of: #/Schritt (\d+) von \d+/#), let step = Int(s.1),
              let m = digits.firstMatch(of: #/(\d+) von (\d+) /#), let done = Int(m.1), let total = Int(m.2) else { return nil }
        return (step, done, total)
    }

    /// A new analysis starts on purpose (the test tapped "Neu prüfen"): numbers may start again.
    mutating func newAnalysis() {
        lastPercent = nil
        lastCount = nil
        lastTitle = ""
    }

    /// No look for a while (the app was relaunched, the test was elsewhere): stillness is not
    /// measured across the gap.
    mutating func gap() {
        firstSeen = nil
        lastSeen = nil
        text = ""
    }

    mutating func observe(_ look: Look) {
        let phaseStart = look.title != lastTitle && Self.phaseTitles.contains { look.title.hasPrefix($0) }
        let percent = Self.percent(look.value)
        let count = Self.count(look.value)
        let resting = Self.restingTitles.contains { look.title.hasPrefix($0) }
        // Numbers never back.
        if let percent, let last = lastPercent, percent < last, !phaseStart {
            violations.append("percentage went back from \(last) % to \(percent) % ('\(lastTitle)' -> '\(look.title)')")
        }
        if let count, let last = lastCount, !phaseStart {
            if count.step < last.step {
                violations.append("step went back from \(last.step) to \(count.step) (\(look.value))")
            } else if count.step == last.step, count.total == last.total, count.done < last.done {
                violations.append("count went back from \(last.done) to \(count.done) von \(count.total) in step \(count.step)")
            }
        }
        // Never "fertig" while work remains.
        if look.running, look.title.hasPrefix("Analyse fertig") {
            violations.append("'Analyse fertig' while the analysis runs (\(look.value))")
        }
        if percent == 100, look.running || (count.map { $0.done < $0.total } ?? false) {
            violations.append("100 % while work remains ('\(look.title)', \(look.value), running \(look.running))")
        }
        if let percent { lastPercent = phaseStart ? percent : max(lastPercent ?? 0, percent) }
        if let count { lastCount = count }
        lastTitle = look.title
        // Stillness while working.
        let shown = look.title + " | " + look.value
        let working = look.running && !resting
        if shown != text || !working {
            text = working ? shown : ""
            firstSeen = working ? look.at : nil
            lastSeen = firstSeen
            return
        }
        lastSeen = look.at
        if let firstSeen, let lastSeen {
            let still = lastSeen.timeIntervalSince(firstSeen)
            if still > longestStill.seconds { longestStill = (still, shown) }
            if still > QualityLimits.displayStill, !violations.contains(where: { $0.hasSuffix("'\(shown)'") }) {
                violations.append("the card stood still \(Int(still)) s while the analysis worked: '\(shown)'")
            }
        }
    }
}
