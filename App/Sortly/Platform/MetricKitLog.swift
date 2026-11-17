import Foundation
import SortlyCore
#if canImport(MetricKit)
@preconcurrency import MetricKit
#endif

/// Hang and crash reports iOS writes about Albumist (MetricKit), kept on the device for the
/// diagnostic report the user can share himself. Device test 15.11.: hangs on the iPhone could
/// not be traced without them. Nothing is sent anywhere; MetricKit only hands over what iOS
/// recorded about the app's own code (stacks as binary + offset, versions, device model), and
/// `MetricKitArchive` removes free texts that could name a file before anything is stored.
///
/// Not isolated: iOS calls the subscriber on a background queue, and registering happens off
/// the main thread so it never slows down the launch.
final class MetricKitLog: NSObject, Sendable {
    static let shared = MetricKitLog()

    /// Application Support/Albumist Diagnostics: encrypted until the first unlock after a
    /// restart, not in the backup.
    static let archive = MetricKitArchive(directory: folder)

    private static var folder: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("\(AppInfo.supportFolderName) Diagnostics", isDirectory: true)
    }

    private override init() { super.init() }

    /// At launch (SortlyApp.init). Returns at once; the work runs in the background.
    static func start() {
        Task.detached(priority: .utility) {
            MetricKitLog.prepareFolder()
            #if canImport(MetricKit)
            let manager = MXMetricManager.shared
            manager.add(MetricKitLog.shared)
            // Reports iOS kept from before this version subscribed (stored once each).
            MetricKitLog.shared.store(manager.pastDiagnosticPayloads)
            MetricKitLog.shared.store(manager.pastPayloads)
            #endif
        }
    }

    /// The MetricKit lines of the diagnostic report, read and formatted off the main thread.
    static func reportLines() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            MetricKitReport.lines(MetricKitLog.archive.payloads())
        }.value
    }

    private static func prepareFolder() {
        let url = folder
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: protection)
        try? FileManager.default.setAttributes(protection, ofItemAtPath: url.path)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }
}

#if canImport(MetricKit)
extension MetricKitLog: MXMetricManagerSubscriber {
    /// Hangs, crashes, CPU and disk-write exceptions, slow launches (iOS hands them over at
    /// the next launch after they happened).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        store(payloads)
    }

    /// The daily figures (launch times, hang time, exits).
    func didReceive(_ payloads: [MXMetricPayload]) {
        store(payloads)
    }

    private func store(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Self.archive.save(payload.jsonRepresentation(), kind: .diagnostic, date: payload.timeStampEnd)
        }
    }

    private func store(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Self.archive.save(payload.jsonRepresentation(), kind: .metric, date: payload.timeStampEnd)
        }
    }
}
#endif
