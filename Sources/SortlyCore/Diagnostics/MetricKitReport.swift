import Foundation

/// The MetricKit part of the diagnostic report: each hang, crash, CPU or disk-write exception
/// and slow launch in a few readable lines (when, app version and build, duration or
/// exception and signal, the top of the call stack), the daily figures in one line each, and
/// the stored JSON at the end for tools.
///
/// The stacks are not symbolicated (MetricKit never is): each frame is a binary and an offset
/// into its text segment, and the binaries are listed with their UUID, so the frames can be
/// symbolicated later with the dSYM of exactly that build.
public enum MetricKitReport {
    public struct Options: Sendable, Equatable {
        /// Frames shown per stack; the JSON at the end has all of them.
        public var frames: Int
        /// Bytes of JSON at the end of the report, newest payloads first.
        public var jsonBytes: Int

        public init(frames: Int = 30, jsonBytes: Int = 120_000) {
            self.frames = frames
            self.jsonBytes = jsonBytes
        }
    }

    public static func lines(_ payloads: [MetricKitArchive.Payload], options: Options = Options()) -> [String] {
        let sorted = payloads.sorted { $0.date > $1.date }
        let diagnostics = sorted.filter { $0.kind == .diagnostic }
        let metrics = sorted.filter { $0.kind == .metric }
        var lines = ["MetricKit (reports from iOS about this app, kept on this device): \(diagnostics.count) diagnostic, \(metrics.count) daily"]
        guard !sorted.isEmpty else {
            lines.append("  none yet: iOS hands them over at the next launch after a hang or crash, daily figures once a day")
            return lines
        }
        lines.append("  stacks unsymbolicated: frame = binary +offset into its __TEXT segment; symbolicate with the dSYM of that build,")
        lines.append("  e.g. atos -arch arm64 -o <dSYM>/Contents/Resources/DWARF/<binary> -l 0x100000000 <0x100000000 + offset>")
        for payload in diagnostics {
            guard let object = MetricKitArchive.object(payload.json) else {
                lines.append("diagnostic \(stamp(payload.date)): unreadable")
                continue
            }
            lines += diagnosticLines(object, date: payload.date, options: options)
        }
        for payload in metrics {
            guard let object = MetricKitArchive.object(payload.json) else {
                lines.append("daily \(stamp(payload.date)): unreadable")
                continue
            }
            lines.append(metricLine(object, date: payload.date))
        }
        lines += jsonLines(sorted, budget: options.jsonBytes)
        return lines
    }

    // MARK: Diagnostics

    /// The kinds in the order the report shows them, with their JSON key.
    static let kinds: [(key: String, title: String)] = [
        ("crashDiagnostics", "crash"),
        ("hangDiagnostics", "hang"),
        ("appLaunchDiagnostics", "slow launch"),
        ("cpuExceptionDiagnostics", "cpu exception"),
        ("diskWriteExceptionDiagnostics", "disk-write exception"),
    ]

    static func diagnosticLines(_ payload: [String: Any], date: Date, options: Options) -> [String] {
        var lines: [String] = []
        for (key, title) in kinds {
            for diagnostic in payload[key] as? [[String: Any]] ?? [] {
                let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
                var parts = ["\(title) \(stamp(date))", context(meta, top: diagnostic)]
                parts += details(key: key, meta)
                lines.append(parts.filter { !$0.isEmpty }.joined(separator: ", "))
                if let tree = diagnostic["callStackTree"] as? [String: Any] {
                    lines += stackLines(tree, frames: options.frames)
                }
            }
        }
        if lines.isEmpty { lines.append("diagnostic \(stamp(date)): no hang or crash in it") }
        return lines
    }

    /// App version and build, iOS version, device model.
    static func context(_ meta: [String: Any], top: [String: Any] = [:]) -> String {
        let version = text(meta["appVersion"]) ?? text(top["appVersion"]) ?? "?"
        let build = text(meta["appBuildVersion"]) ?? "?"
        var parts = ["app \(version) (\(build))"]
        if let os = text(meta["osVersion"]) { parts.append(os) }
        if let device = text(meta["deviceType"]) { parts.append(device) }
        return parts.joined(separator: ", ")
    }

    static func details(key: String, _ meta: [String: Any]) -> [String] {
        switch key {
        case "hangDiagnostics":
            return ["duration \(text(meta["hangDuration"]) ?? "?")"]
        case "crashDiagnostics":
            var parts: [String] = []
            let exception = number(meta["exceptionType"]).map(machException)
            let signal = number(meta["signal"]).map(signalName)
            switch (exception, signal) {
            case let (e?, s?): parts.append("\(e) (\(s))")
            case let (e?, nil): parts.append(e)
            case let (nil, s?): parts.append(s)
            case (nil, nil): parts.append("no exception type")
            }
            if let code = number(meta["exceptionCode"]) { parts.append("code \(code)") }
            if let reason = text(meta["terminationReason"]) { parts.append("termination \(oneLine(reason, limit: 300))") }
            if let objc = meta["exceptionReason"] as? [String: Any] {
                let name = text(objc["exceptionName"]) ?? text(objc["exceptionType"]) ?? "exception"
                let format = text(objc["formatString"]).map { ": \(oneLine($0, limit: 200))" } ?? ""
                let className = text(objc["className"]).map { " [\($0)]" } ?? ""
                parts.append("\(name)\(className)\(format)")
            }
            return parts
        case "cpuExceptionDiagnostics":
            return ["cpu \(text(meta["totalCPUTime"]) ?? "?") in \(text(meta["totalSampledTime"]) ?? "?") sampled"]
        case "diskWriteExceptionDiagnostics":
            return ["written \(text(meta["writesCaused"]) ?? text(meta["totalWritesCaused"]) ?? "?")"]
        case "appLaunchDiagnostics":
            return ["launch \(text(meta["launchDuration"]) ?? "?")"]
        default:
            return []
        }
    }

    // MARK: Stacks

    /// One stack per thread (crash, hang): the attributed thread, top frame first. A sampled
    /// tree (CPU, disk writes): the whole tree, indented where it branches.
    static func stackLines(_ tree: [String: Any], frames limit: Int) -> [String] {
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        guard !stacks.isEmpty else { return ["  no call stack"] }
        let perThread = (tree["callStackPerThread"] as? Bool) ?? true
        var lines: [String] = []
        var binaries: [(name: String, uuid: String)] = []
        var printed = 0
        var total = 0
        func walk(_ frame: [String: Any], indent: Int, sampled: Bool) {
            total += 1
            if printed < limit {
                printed += 1
                lines.append(frameLine(frame, index: total - 1, indent: indent, sampled: sampled))
                let name = text(frame["binaryName"]) ?? "?"
                let uuid = text(frame["binaryUUID"]) ?? "?"
                if !binaries.contains(where: { $0.name == name && $0.uuid == uuid }) { binaries.append((name, uuid)) }
            }
            let children = frame["subFrames"] as? [[String: Any]] ?? []
            for child in children { walk(child, indent: children.count > 1 ? indent + 1 : indent, sampled: sampled) }
        }
        if perThread {
            let attributed = stacks.firstIndex { ($0["threadAttributed"] as? Bool) == true }
            let shown = stacks[attributed ?? 0]
            if let attributed {
                lines.append("  thread \(attributed) of \(stacks.count), the one it happened on:")
            } else {
                lines.append("  thread 0 of \(stacks.count) (none marked):")
            }
            for root in shown["callStackRootFrames"] as? [[String: Any]] ?? [] { walk(root, indent: 0, sampled: false) }
        } else {
            lines.append("  sampled stacks (frame ×samples):")
            for stack in stacks {
                for root in stack["callStackRootFrames"] as? [[String: Any]] ?? [] { walk(root, indent: 0, sampled: true) }
            }
        }
        if total > printed { lines.append("    … \(total - printed) more frames in the JSON below") }
        if !binaries.isEmpty {
            lines.append("  binaries: " + binaries.map { "\($0.name) \($0.uuid)" }.joined(separator: "; "))
        }
        return lines
    }

    static func frameLine(_ frame: [String: Any], index: Int, indent: Int, sampled: Bool) -> String {
        let name = text(frame["binaryName"]) ?? "?"
        let offset = number(frame["offsetIntoBinaryTextSegment"]).map { "+0x" + String($0, radix: 16) } ?? "+?"
        let samples = sampled ? number(frame["sampleCount"]).map { " ×\($0)" } ?? "" : ""
        let number = String(index)
        let padded = String(repeating: " ", count: max(0, 3 - number.count)) + number
        return "  " + String(repeating: "  ", count: min(indent, 10)) + "\(padded) \(name) \(offset)\(samples)"
    }

    // MARK: Daily figures

    static func metricLine(_ payload: [String: Any], date: Date) -> String {
        let meta = payload["metaData"] as? [String: Any] ?? [:]
        var parts = ["daily \(period(payload, date: date))", context(meta, top: payload)]
        let launch = payload["applicationLaunchMetrics"] as? [String: Any] ?? [:]
        if let first = histogram(launch["histogrammedTimeToFirstDrawKey"]) { parts.append("launch to first draw \(first)") }
        if let resume = histogram(launch["histogrammedResumeTime"]) { parts.append("resume \(resume)") }
        let responsiveness = payload["applicationResponsivenessMetrics"] as? [String: Any] ?? [:]
        if let hangs = histogram(responsiveness["histogrammedAppHangTime"]) { parts.append("hangs \(hangs)") }
        let exits = payload["applicationExitMetrics"] as? [String: Any] ?? [:]
        for (key, title) in [("foregroundExitData", "exits on screen"), ("backgroundExitData", "exits in background")] {
            let counts = (exits[key] as? [String: Any] ?? [:]).compactMap { name, value -> (String, Int)? in
                guard let count = number(value), count > 0 else { return nil }
                return (exitName(name), count)
            }
            .sorted { $0.0 < $1.0 }
            if !counts.isEmpty { parts.append("\(title): " + counts.map { "\($0.0) \($0.1)" }.joined(separator: ", ")) }
        }
        if let peak = text((payload["memoryMetrics"] as? [String: Any])?["peakMemoryUsage"]) { parts.append("peak memory \(peak)") }
        if let cpu = text((payload["cpuMetrics"] as? [String: Any])?["cumulativeCPUTime"]) { parts.append("cpu \(cpu)") }
        if let writes = text((payload["diskIOMetrics"] as? [String: Any])?["cumulativeLogicalWrites"]) { parts.append("disk writes \(writes)") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func period(_ payload: [String: Any], date: Date) -> String {
        guard let begin = text(payload["timeStampBegin"]), let end = text(payload["timeStampEnd"]) else { return stamp(date) }
        return "\(begin) – \(end)"
    }

    /// "12 (median 400 ms–410 ms, slowest 2,000 ms–2,010 ms)" from a MetricKit histogram.
    static func histogram(_ value: Any?) -> String? {
        guard let histogram = value as? [String: Any], let buckets = histogram["histogramValue"] as? [String: Any] else { return nil }
        let ordered = buckets.compactMap { key, value -> (Int, [String: Any])? in
            guard let index = Int(key), let bucket = value as? [String: Any] else { return nil }
            return (index, bucket)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
        let counts = ordered.map { number($0["bucketCount"]) ?? 0 }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        func range(_ bucket: [String: Any]) -> String { "\(text(bucket["bucketStart"]) ?? "?")–\(text(bucket["bucketEnd"]) ?? "?")" }
        var running = 0
        var median = ordered[0]
        for (bucket, count) in zip(ordered, counts) {
            running += count
            if running * 2 >= total { median = bucket; break }
        }
        let slowest = Array(zip(ordered, counts)).last { $0.1 > 0 }?.0 ?? median
        return "\(total) (median \(range(median)), slowest \(range(slowest)))"
    }

    /// "cumulativeAppWatchdogExitCount" → "app watchdog".
    static func exitName(_ key: String) -> String {
        var name = key
        if name.hasPrefix("cumulative") { name.removeFirst("cumulative".count) }
        if name.hasSuffix("ExitCount") { name.removeLast("ExitCount".count) }
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(Character(character.lowercased()))
        }
        return words.isEmpty ? key : words
    }

    // MARK: JSON for tools

    /// The stored JSON, one payload per line, newest first, until the budget is used up.
    static func jsonLines(_ payloads: [MetricKitArchive.Payload], budget: Int) -> [String] {
        var lines = ["", "MetricKit JSON (cleaned, one payload per line, newest first)"]
        var used = 0
        var left = 0
        for payload in payloads {
            guard let json = String(data: payload.json, encoding: .utf8) else { continue }
            if used + json.utf8.count > budget { left += 1; continue }
            used += json.utf8.count
            lines.append("\(payload.kind.rawValue) \(stamp(payload.date)) \(json)")
        }
        if left > 0 { lines.append("(\(left) older payloads left out for size; they stay on the device)") }
        return lines
    }

    // MARK: Values

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func number(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Mach exception types (`<mach/exception_types.h>`).
    static func machException(_ type: Int) -> String {
        let names = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
                     5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
                     9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY"]
        return names[type] ?? "exception \(type)"
    }

    /// Darwin signal numbers (`<sys/signal.h>`).
    static func signalName(_ signal: Int) -> String {
        let names = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
                     8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE",
                     14: "SIGALRM", 15: "SIGTERM"]
        return names[signal] ?? "signal \(signal)"
    }
}
