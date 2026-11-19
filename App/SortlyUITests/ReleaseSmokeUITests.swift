import XCTest

/// The build that is uploaded, started once before every upload (review P5-03). Every other UI
/// test runs a Debug build, where `UITestSupport.isRunning` and the `#if DEBUG` code of the app
/// (test switches, the UI-test analyzer wrapper, the console moved to a file) change what runs;
/// the Release build of the archive was never started before the upload. testflight.yml (job
/// "release-smoke") builds this target with `-configuration Release` and runs only this test,
/// beside the UI flow and the stress pass; the upload needs it green.
///
/// It does what a new user does, with no `-SortlyUITest…` switch (a Release build ignores
/// them): onboarding, the demo library and its analysis, the recommended suggestions, a plan
/// within the free albums, applied in Photos. It skips itself unless the runner sets
/// SORTLY_RELEASE_SMOKE=1 (testflight.yml hands TEST_RUNNER_SORTLY_RELEASE_SMOKE on), so in
/// ui.yml's group "flow-other" (everything else) it is a skip of a second. In testflight.yml a
/// skip is no pass: its "Run UI tests" step fails unless the log says this test passed.
///
/// Unverified until a Mac run: written without a run on a Release build.
@MainActor
final class ReleaseSmokeUITests: XCTestCase {
    private let app = XCUIApplication()

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Waits for `element`, scrolls it into reach and taps it; false (and the test fails) when
    /// it does not appear within `timeout`.
    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval) -> Bool {
        guard UITestWait.appears(element, step, timeout: timeout) else { return false }
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        element.tap()
        return true
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    func test1_ReleaseBuildOnboardsAnalysesAndApplies() throws {
        guard ProcessInfo.processInfo.environment["SORTLY_RELEASE_SMOKE"] == "1" else {
            throw XCTSkip("Release smoke test only (SORTLY_RELEASE_SMOKE, testflight.yml)")
        }
        continueAfterFailure = false
        // German, as the other UI tests read the German texts. UITestAppEnd.launch adds the
        // stall file argument, which a Release build ignores (UITestSwitches.prepareLaunch).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        UITestAppEnd.launch(app)
        UITestOnboarding.clock("release smoke launched")

        // Onboarding, the demo library and its whole analysis (asserted inside).
        let onboarded = UITestOnboarding.completeIfNeeded(app, in: "release smoke")
        print("UI_FACT release smoke: onboarding and demo library done here: \(onboarded)")
        guard UITestWait.until("release smoke analysis finished", timeout: 1200, { UITestOnboarding.analysisIdle(app) }) else { return }

        // The recommended suggestions, as a plan.
        let review = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9.]+ Vorschl(ag|äge) prüfen.*")).firstMatch
        guard tap(review, "release smoke suggestions offered", timeout: 60) else { return }
        guard tap(button("empfohlene auswählen"), "release smoke recommended ones", timeout: 20) else { return }
        // The list takes the choice before going back (the flow tests give it a second too).
        UITestWait.atLeast(1, since: Date())
        back()
        guard tap(button("ausgewählte Alben anlegen"), "release smoke open the plan", timeout: 20),
              UITestWait.appears(app.navigationBars["Vorschau"], "release smoke plan screen", timeout: 30) else { return }

        // A new install has free albums; a plan with more of them shows the unlock card, and
        // "Die ersten N jetzt kostenlos anlegen" keeps the plan within them (no purchase here:
        // no App Store account on the CI simulator).
        let start = app.buttons["plan.apply"]
        let freeOnly = button("jetzt kostenlos anlegen")
        guard UITestWait.until("release smoke plan can start or offers the free albums", timeout: 30, { start.exists || freeOnly.exists })
        else { return }
        if !start.exists {
            print("UI_FACT release smoke: the plan needs more than the free albums, keeping the free ones")
            guard tap(freeOnly, "release smoke keep the free albums", timeout: 5) else { return }
        }
        guard tap(start, "release smoke apply the plan", timeout: 23) else { return }
        let applied = Date()
        guard UITestWait.appears(button("Rückgängig machen"), "release smoke plan finished", timeout: 900) else { return }
        print("UI_TIMING release smoke apply \(Int(Date().timeIntervalSince(applied))) s")
        XCTAssertEqual(app.state, .runningForeground, "The Release build is no longer in the foreground after its plan")
    }
}
