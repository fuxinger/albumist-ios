import Foundation
import Testing
@testable import AlbumistUITestLogic

/// The app's lifecycle lines in the watch file (`UITestLifecycle`): written by the app, printed by
/// the UI test next to its Home press, so a lost first press shows whether it reached the app.
@Suite("UI test lifecycle lines")
struct UITestLifecycleTests {
    // 2026-11-21 03:43:07.4 UTC
    let seconds = 1_795_232_587.4

    @Test func aWrittenLineIsReadBack() throws {
        for event in UITestLifecycle.events.sorted() {
            let line = UITestLifecycle.line(event, at: seconds)
            #expect(line.hasSuffix("\n"))
            let fact = try #require(UITestLifecycle.fact(Substring(line.dropLast())))
            #expect(fact == "UI_FACT app lifecycle \(event) at 03:43:07.4 UTC")
        }
    }

    @Test func otherLinesOfTheFileAreNotLifecycleLines() {
        // A stall, the process line, a stack, the marked work, an unknown event, a broken time.
        for line in ["1795232587.400 2200", "@ 27835 1795232544.5 1795232551.4", "# after 2.0 s of the stall: a | b",
                     "% in the stall of 2.2 s from 03:43:07.4 UTC: atlas map paths 1x", "^ 1795232587.4 suspended",
                     "^ soon background", "^ 1795232587.4", ""] {
            #expect(UITestLifecycle.fact(Substring(line)) == nil, "\(line)")
        }
    }

    @Test func theClockIsTheOneOfTheTestsClockLines() {
        #expect(UITestLifecycle.clock(seconds) == "03:43:07.4")
        #expect(UITestLifecycle.clock(86_400 * 3 + 5) == "00:00:05.0")
    }
}
