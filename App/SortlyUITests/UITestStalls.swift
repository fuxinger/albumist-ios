import Foundation

/// The app's main-thread stalls, printed by the test that launched it: the job log keeps at
/// most 40 of the app's own lines, and the stalls of a later test were cut off there (test02,
/// UI run 44002652481, a snapshot timeout with no stall line to compare). The app writes each
/// stall over half a second into `path` (-SortlyUITestWatchMainLog, anew at every launch), and
/// during a long stall the main thread's stack (`MainThreadWatch.reportStack`).
/// Nonisolated: also called from teardown blocks.
enum UITestStalls {
    static var path: String { NSTemporaryDirectory() + "uitest-main-stalls.txt" }

    /// Launch arguments that make the app write the file (none when `extra` names one already).
    static func arguments(besides extra: [String]) -> [String] {
        extra.contains("-SortlyUITestWatchMainLog") ? [] : ["-SortlyUITestWatchMainLog", path]
    }

    /// The stalls of 2 s or more since the last launch, as `UI_FACT main stall 3.2 s from
    /// 18:31:05.2 UTC` (the clock of `UI_MAIN_STALL` and of `UI_FACT slow query`), and each stack
    /// as `UI_FACT main stack after 5.0 s of the stall from …: frame | frame | …`.
    static func report() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# ") {
                print("UI_FACT main stack \(line.dropFirst(2))")
                continue
            }
            let parts = line.split(separator: " ")
            guard parts.count == 2, let end = Double(parts[0]), let ms = Int(parts[1]), ms >= 2000 else { continue }
            let from = end - Double(ms) / 1000
            let day = from.truncatingRemainder(dividingBy: 86_400)
            let clock = String(format: "%02d:%02d:%04.1f", Int(day / 3600), Int(day.truncatingRemainder(dividingBy: 3600) / 60),
                               day.truncatingRemainder(dividingBy: 60))
            print("UI_FACT main stall \(String(format: "%.1f", Double(ms) / 1000)) s from \(clock) UTC")
        }
    }
}
