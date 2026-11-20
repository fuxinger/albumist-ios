import Foundation
import Testing
import SortlyEngine
import SortlyTestSupport

/// Under the analysis card: „Zuletzt geprüft vor 5 Minuten“; right after a check the relative
/// date said „Zuletzt geprüft jetzt“ (review P3-18, `ui-63-analysis-done.jpg`). Within the
/// first minute it says „Gerade eben geprüft“, "Checked just now" (`LastCheck`).
@Suite("Last check text")
struct LastCheckTextTests {
    static let checked = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func withinTheFirstMinuteItIsJustNow() {
        for seconds: TimeInterval in [0, 1, 30, 59.9] {
            #expect(LastCheck(Self.checked, now: Self.checked.addingTimeInterval(seconds)) == .justNow, "\(seconds) s")
        }
    }

    @Test func fromAMinuteOnItNamesTheTime() {
        for seconds: TimeInterval in [60, 61, 3_600, 259_200] {
            #expect(LastCheck(Self.checked, now: Self.checked.addingTimeInterval(seconds)) == .earlier(Self.checked), "\(seconds) s")
        }
    }

    /// A check stamped a little after "now" (the clock was set back) is no check in the future.
    @Test func aCheckAfterNowIsJustNow() {
        #expect(LastCheck(Self.checked, now: Self.checked.addingTimeInterval(-5)) == .justNow)
    }

    /// The overview shows it, refreshed every minute, and never the relative date of "now".
    @Test func theOverviewSaysJustNow() throws {
        let overview = AppSource.code(try AppSource.read("App/Sortly/Views/OverviewView.swift"), keepStrings: true)
        #expect(overview.contains("LastCheck(date, now: context.date)"), "the overview does not decide with LastCheck")
        #expect(overview.contains("TimelineView(.everyMinute)"), "the text does not follow the clock")
        #expect(overview.contains("Text(\"Gerade eben geprüft\")"))
        let catalog = try String(contentsOf: AppSource.root.appendingPathComponent("App/Sortly/Resources/Localizable.xcstrings"), encoding: .utf8)
        let data = try #require(catalog.data(using: .utf8))
        let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        let english = (((strings["Gerade eben geprüft"] as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any])
            .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        #expect(english == "Checked just now")
    }
}
