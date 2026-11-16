import Foundation

/// Hang and crash reports iOS hands the app through MetricKit, kept in a small folder on the
/// device for the diagnostic report a user can share (device test 15.11.: hangs on the iPhone
/// could not be traced without them). Bounded: the newest reports of each kind and a total
/// size, oldest dropped first. Nothing leaves the device unless the user shares the report.
///
/// What is stored is MetricKit's own JSON about the app's code (stacks as binary + offset,
/// app and iOS version, device model), cleaned first: texts that could carry data of the
/// app's content are removed (`removedKeys`).
public final class MetricKitArchive: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// `MXDiagnosticPayload`: hangs, crashes, CPU and disk-write exceptions, slow launches.
        case diagnostic
        /// `MXMetricPayload`: daily figures (launch times, hang time, exits).
        case metric
    }

    public struct Limits: Sendable, Equatable {
        public var diagnostics: Int
        public var metrics: Int
        /// All files together.
        public var totalBytes: Int
        /// One payload after cleaning; a larger crash report keeps only its crashed thread.
        public var payloadBytes: Int

        public init(diagnostics: Int = 20, metrics: Int = 10, totalBytes: Int = 3_000_000, payloadBytes: Int = 600_000) {
            self.diagnostics = diagnostics
            self.metrics = metrics
            self.totalBytes = totalBytes
            self.payloadBytes = payloadBytes
        }
    }

    public struct Payload: Sendable, Equatable {
        public var kind: Kind
        /// When the payload's period ended (`timeStampEnd`); for a hang or crash about when it happened.
        public var date: Date
        public var json: Data

        public init(kind: Kind, date: Date, json: Data) {
            self.kind = kind
            self.date = date
            self.json = json
        }
    }

    public enum SaveResult: Sendable, Equatable {
        case saved
        /// The same payload is already there (iOS can hand past payloads again).
        case duplicate
        /// Not a JSON object, or too large even after trimming.
        case rejected
    }

    /// Free texts MetricKit can fill from the app's memory: the message of an Objective-C
    /// exception with its arguments (could contain a file name) and the memory map around a
    /// bad access (can name mapped files). The exception's name, class and format string stay.
    public static let removedKeys: Set<String> = ["composedMessage", "arguments", "virtualMemoryRegionInfo"]

    public let directory: URL
    public let limits: Limits
    private let lock = NSLock()

    public init(directory: URL, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
    }

    // MARK: Writing

    /// Cleans and stores one payload, then drops the oldest beyond the limits.
    @discardableResult
    public func save(_ json: Data, kind: Kind, date: Date) -> SaveResult {
        guard var object = Self.object(json) else { return .rejected }
        object = (Self.sanitized(object) as? [String: Any]) ?? object
        guard var data = Self.serialized(object) else { return .rejected }
        if data.count > limits.payloadBytes {
            guard let smaller = Self.keepingAttributedThreads(object) as? [String: Any],
                  let trimmed = Self.serialized(smaller), trimmed.count <= limits.payloadBytes else {
                return .rejected
            }
            data = trimmed
        }
        let hash = Self.fingerprint(data)
        return lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if files().contains(where: { $0.hash == hash }) { return .duplicate }
            let name = Self.fileName(kind: kind, date: date, hash: hash)
            do {
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            } catch {
                return .rejected
            }
            prune()
            return .saved
        }
    }

    /// Everything stored, newest first.
    public func payloads() -> [Payload] {
        lock.withLock {
            files().compactMap { file in
                guard let data = try? Data(contentsOf: file.url) else { return nil }
                return Payload(kind: file.kind, date: file.date, json: data)
            }
        }
    }

    public func removeAll() {
        lock.withLock {
            for file in files() { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    // MARK: Files

    struct File {
        var url: URL
        var kind: Kind
        var date: Date
        var hash: String
        var name: String
    }

    /// `diagnostic-<milliseconds since 1970, 15 digits>-<fingerprint>.json`: kind and date
    /// come from the name, no file dates are read.
    static func fileName(kind: Kind, date: Date, hash: String) -> String {
        let millis = max(0, Int64((date.timeIntervalSince1970 * 1000).rounded()))
        let padded = String(repeating: "0", count: max(0, 15 - String(millis).count)) + String(millis)
        return "\(kind.rawValue)-\(padded)-\(hash).json"
    }

    static func parse(_ name: String) -> (kind: Kind, date: Date, hash: String)? {
        guard name.hasSuffix(".json") else { return nil }
        let parts = name.dropLast(".json".count).split(separator: "-")
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])), let millis = Int64(parts[1]) else { return nil }
        return (kind, Date(timeIntervalSince1970: Double(millis) / 1000), String(parts[2]))
    }

    /// Newest first; equal dates by name, so the order is stable.
    private func files() -> [File] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            Self.parse(name).map { File(url: directory.appendingPathComponent(name), kind: $0.kind, date: $0.date, hash: $0.hash, name: name) }
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name > $1.name }
    }

    private func prune() {
        var kept: [File] = []
        var counts: [Kind: Int] = [:]
        for file in files() {
            counts[file.kind, default: 0] += 1
            let limit = file.kind == .diagnostic ? limits.diagnostics : limits.metrics
            if counts[file.kind, default: 0] > limit {
                try? FileManager.default.removeItem(at: file.url)
            } else {
                kept.append(file)
            }
        }
        var total = 0
        for file in kept {
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            if total > limits.totalBytes { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    // MARK: JSON

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func serialized(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The JSON without `removedKeys`, at any depth.
    public static func sanitized(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var clean: [String: Any] = [:]
            for (key, inner) in dictionary where !removedKeys.contains(key) { clean[key] = sanitized(inner) }
            return clean
        }
        if let array = value as? [Any] { return array.map(sanitized) }
        return value
    }

    /// For an oversized crash report: each call-stack tree keeps only the thread(s) MetricKit
    /// marked as the one that crashed or hung.
    static func keepingAttributedThreads(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if let stacks = dictionary["callStacks"] as? [[String: Any]] {
                let attributed = stacks.filter { ($0["threadAttributed"] as? Bool) == true }
                dictionary["callStacks"] = attributed.isEmpty ? Array(stacks.prefix(1)) : attributed
                return dictionary
            }
            for (key, inner) in dictionary { dictionary[key] = keepingAttributedThreads(inner) }
            return dictionary
        }
        if let array = value as? [Any] { return array.map(keepingAttributedThreads) }
        return value
    }

    /// FNV-1a, 64 bit, as 16 hex digits: names the file and finds a payload stored before.
    static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
