import Foundation
import Testing
import SortlyTestSupport

/// What the Lock Screen says when the analysis goes on in the background (review of 18.11.2026,
/// P3-08 and P4-13): iOS gives work in the background less computing power, and "Läuft weiter,
/// auch wenn du die App verlässt" did not say so. It now says "Läuft im Hintergrund weiter, dort
/// aber langsamer", in the same words as the analysis card's Details. The App does not build on
/// Linux, so this reads its code (`AppSource`): comments never count.
@Suite("Lock Screen text of the continued analysis")
struct ContinuedAnalysisTextTests {
    static let file = "App/Sortly/Platform/ContinuedAnalysis.swift"

    @Test func theLockScreenSaysItGoesOnMoreSlowlyInTheBackground() throws {
        let source = AppSource.code(try AppSource.read(Self.file), keepStrings: true)
        let request = try #require(
            source.firstMatch(of: #/BGContinuedProcessingTaskRequest\([\s\S]*?subtitle:\s*String\(\s*localized:\s*"([^"]*)"\s*\)/#),
            "\(Self.file): no subtitle in the request (moved?)")
        let subtitle = String(request.1)
        #expect(subtitle == "Läuft im Hintergrund weiter, dort aber langsamer")
        #expect(!source.contains("Läuft weiter, auch wenn du die App verlässt"))

        // The card's Details say the same while the task runs.
        let card = AppSource.code(try AppSource.read(AnalysisCardGlanceTests.file), keepStrings: true)
        let details = try #require(AppSource.body(of: ["struct AnalysisDetailsSheet", "private var background:"], in: card))
        let running = try #require(details.firstMatch(of: #/case\s+\.running\s*:\s*return\s*\(\s*"([^"]*)"/#), "\(details)")
        #expect(String(running.1) == subtitle, "Details say \(running.1)")
    }
}
