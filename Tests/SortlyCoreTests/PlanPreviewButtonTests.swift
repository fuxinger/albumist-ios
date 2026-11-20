import Foundation
import Testing
import SortlyTestSupport

/// The button of the plan preview is in reach without scrolling (review 18.11.2026, P3-05 =
/// G3-05): "Alben jetzt anlegen" was the last thing of the plan, below the album list, and so
/// were the promises "Kein Original wird gelöscht"; the preview opened with a list and no next
/// step. Now the button stands at the bottom of the screen, above the tab bar, with the promise
/// in one line above it, while the plan is on screen and can run. When something stops the plan
/// (only selected photos shared, an interrupted plan, more albums than are free), that stands at
/// the top of the plan instead, and there is no button.
///
/// The App does not build on Linux, so these tests read `PlanReviewView.swift` (`AppSource`). On
/// a Mac the UI tests tap the button as the preview opens, without scrolling, clear of the tab bar
/// (`SortlyFlowUITests.test1_FullFlow`, the walks of `AccessibilityUITests`, `SortlyLockedUITests`).
@Suite("The preview's button in reach")
struct PlanPreviewButtonTests {
    static let view = "App/Sortly/Views/PlanReviewView.swift"

    /// The file without comments, strings kept.
    static func code() throws -> String {
        AppSource.code(try AppSource.read(view), keepStrings: true)
    }

    /// The closure the screen shows at its bottom edge (`safeAreaInset(edge: .bottom`).
    static func bar(in code: String) throws -> String {
        let body = try #require(AppSource.body(of: ["struct PlanReviewView", "var body: some View"], in: code))
        return try #require(AppSource.body(of: ".safeAreaInset(edge: .bottom", in: body),
                            "nothing at the bottom of the preview: the button is only reached by scrolling")
    }

    /// Whether `text` holds `marker`, itself or in a function of the file it calls (`name(`),
    /// a few calls deep.
    static func reaches(_ marker: String, from text: String, in code: String, depth: Int = 3) -> Bool {
        if text.contains(marker) { return true }
        guard depth > 0 else { return false }
        let names = Set(text.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\(/).map { String($0.output.1) })
        return names.contains { name in
            guard let body = AppSource.body(of: "func \(name)(", in: code) else { return false }
            return reaches(marker, from: body, in: code, depth: depth - 1)
        }
    }

    /// The button stands in the bar at the bottom, not at the end of the plan that scrolls. The
    /// bar is in the safe area, so above the tab bar, never behind it (unlike a `.bottomBar`
    /// toolbar under a tab bar, review P3-01), and on the screen's own background, so the plan
    /// scrolling under it never shows through its words.
    @Test func theButtonStandsAtTheBottomNotAtTheEndOfThePlan() throws {
        let code = try Self.code()
        let bar = try Self.bar(in: code)
        #expect(Self.reaches("accessibilityIdentifier(\"plan.apply\")", from: bar, in: code),
                "the bar at the bottom does not hold \"Alben jetzt anlegen\"")
        let plan = try #require(AppSource.body(of: "func planContent(", in: code))
        #expect(!Self.reaches("\"plan.apply\"", from: plan, in: code), "the button still stands at the end of the plan")
        #expect(Self.reaches(".background(Theme.background)", from: bar, in: code), "the plan shows through the bar")
        #expect(!Self.reaches("ignoresSafeArea", from: bar, in: code), "the bar leaves the safe area (the tab bar is there)")
        #expect(!code.contains(".bottomBar"))
    }

    /// The bar is there only while the plan is on screen and can run: one value decides both the
    /// plan the screen shows and the bar under it, and it is nil during the sorting show, the run,
    /// over a result and while the plan is made. So "Alben jetzt anlegen" never stands over the
    /// sorting show or the result, and never where something stops the plan.
    @Test func theBarIsThereOnlyWhileThePlanIsOnScreenAndCanRun() throws {
        let code = try Self.code()
        let bar = try Self.bar(in: code)
        #expect(bar.contains("if let previewed, previewed.obstacle == nil {"), "\(bar)")
        let body = try #require(AppSource.body(of: ["struct PlanReviewView", "var body: some View"], in: code))
        #expect(body.contains(/\}\s*else if let previewed \{\s*planContent\(previewed\.plan, previewed\.facts, obstacle: previewed\.obstacle\)/),
                "the plan on screen goes by another value than the bar")
        let previewed = try #require(AppSource.body(of: "private var previewed:", in: code))
        for condition in ["show == nil", "!model.execution.isRunning", "model.execution.finished == nil", "!loading",
                          "factsKey.samePlan(as: factsMadeFor)"] {
            #expect(previewed.contains(condition), "the bar can stand while not \(condition)")
        }
        #expect(previewed.contains("obstacle(for: plan, facts)"))
    }

    /// What stops the plan is the first thing of the plan, seen as the preview opens (it stood
    /// at the end, where the button stood), in the order the preview has always asked: full
    /// access, then the interrupted plan, then the free albums.
    @Test func whatStopsThePlanStandsAtItsTopInsteadOfTheButton() throws {
        let code = try Self.code()
        let plan = try #require(AppSource.body(of: "func planContent(", in: code))
        let card = try #require(plan.range(of: "if let obstacle { obstacleCard(obstacle, facts) }"))
        let title = try #require(plan.range(of: "Text(\"Das ändert sich in Fotos\")"))
        #expect(card.lowerBound < title.lowerBound, "what stops the plan comes after the plan")
        let cards = try #require(AppSource.body(of: "func obstacleCard(", in: code))
        for shown in ["FullAccessCard()", "Erst das unterbrochene Anlegen abschließen", "UnlockCard(albumsInPlan: facts.freeAlbumUse"] {
            #expect(cards.contains(shown), "\(shown)")
        }
        let decision = try #require(AppSource.body(of: "func obstacle(for", in: code))
        let order = ["model.access == .limited", "PlanGate.refusal(for: plan", "purchases.allows(albums: facts.freeAlbumUse)"]
            .map { decision.range(of: $0)?.lowerBound }
        #expect(!order.contains(nil), "\(decision)")
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "\(decision)")
    }

    /// The two promises in one line, right above the button, in German and English.
    @Test func thePromiseStandsInOneLineAboveTheButton() throws {
        let code = try Self.code()
        let bar = try #require(AppSource.body(of: "func applyBar(", in: code))
        let promise = try #require(bar.range(of: "promise(facts.summary)"))
        let button = try #require(bar.range(of: "applyButton(plan, facts"))
        #expect(promise.lowerBound < button.lowerBound, "the promise is not above the button")
        let words = try #require(AppSource.body(of: "func promise(", in: code))
        #expect(words.contains("Text(\"Kein Original wird gelöscht oder kopiert.\")"), "\(words)")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: AppSource.root.appendingPathComponent("App/Sortly/Resources/Localizable.xcstrings"))) as? [String: Any]
        let entry = (catalog?["strings"] as? [String: Any])?["Kein Original wird gelöscht oder kopiert."] as? [String: Any]
        let english = ((entry?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(english?["value"] as? String == "No originals are deleted or copied.")
    }
}
