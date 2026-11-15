import Foundation
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
