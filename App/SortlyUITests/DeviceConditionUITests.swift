import XCTest
import UIKit

/// Device conditions on the simulator. The first iPhone test (15.11.) found what no simulator
/// run had shown: a warm phone ended the analysis, Photos ignored a deletion, a full run was
/// lost when iOS took the time away. Each test here starts the real app with a switch from
/// `UITestSwitches.swift` that makes it behave as on a phone under that condition, and checks
/// what the user sees. Every test sets itself up (fast start, demo library), so any group of
/// them runs alone on a fresh simulator, as CI runs them.
/// Log conventions as in SortlyFlowUITests: `UI_STEP_OK` / `UI_STEP_MISSING`, `UI_FACT`,
/// `UI_TIMING`, screenshots as `PREVIEW_JPEG ui-dc-…` chunks.
@MainActor
final class DeviceConditionUITests: XCTestCase {
    private var app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    // MARK: Helpers (copied from SortlyFlowUITests, which stays as it is)

    private func launch(_ extra: [String] = []) {
        UITestStalls.report()
        if !stallsReportedAtEnd {
            stallsReportedAtEnd = true
            addTeardownBlock { UITestStalls.report() }
        }
        app = XCUIApplication()
        let stalls = UITestStalls.arguments(besides: extra)
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-SortlyUITestUnlocked"] + stalls + extra
        launchExtra = extra
        UITestOnboarding.clock("launch")
        app.launch()
    }

    /// The test's own arguments of the last launch: the onboarding helpers open the app again
    /// with them. They opened it as a fast start, and test 10 (empty library, own database) then
    /// ran on the demo library after the photo access had to be given back (UI run 44108052342).
    private var launchExtra: [String] = []

    private var stallsReportedAtEnd = false

    /// A launch on a prepared simulator: the onboarding counts as done.
    private func start(_ extra: [String] = []) {
        launch(["-SortlyUITestFastStart"] + extra)
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A text on screen. Cheaper than `anything` while the analysis keeps the app busy: a query
    /// over every element timed out there (test02, UI run 43795445305).
    private func text(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A tab bar button; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            sleep(1)
            tries += 1
        }
        return button
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
            XCTFail("Missing: \(step)")
            return false
        }
        let bar = app.navigationBars.firstMatch
        var swipes = 0
        while swipes < 8 {
            let underBar = bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
            if underBar { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        UITestOnboarding.clock("tap \(step)")
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "dc-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let small = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = small.jpegData(compressionQuality: 0.55) else { return }
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG ui-dc-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    /// Polls until `condition` held on `stableChecks` checks in a row (2 s apart).
    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        UITestOnboarding.clock("wait start \(what)")
        defer { UITestOnboarding.clock("wait end \(what)") }
        while Date() < deadline {
            let asked = Date()
            let met = condition()
            UITestOnboarding.reportSlowCheck(since: asked)
            streak = met ? streak + 1 : 0
            if streak >= stableChecks { return true }
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    /// The overview says the analysis is done and nothing runs (no "Pause"): "Alle 246 Fotos
    /// analysiert", "Analyse aktuell", or the card's "Analyse fertig" right after a long run.
    /// (No query over every element: one timed out while the app was busy.)
    private var analysisIdle: Bool {
        guard !app.buttons["Pause"].exists else { return false }
        let headline = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@ OR label == %@", "Fotos analysiert", "Analyse aktuell")).firstMatch
        return headline.exists || (progressText()?.hasPrefix("Analyse fertig") ?? false)
    }

    private var analysisRunning: Bool { app.buttons["Pause"].exists }

    /// The card's progress element (one element since rc-1): value "120 von 412 Fotos, fertig
    /// gegen 23:40, Schritt 4 von 6, …", as (step, done, total). Read from one snapshot: the
    /// element can go away between an `exists` and reading it, and that read would fail the
    /// test (test6, run 43743310212).
    private func analysisCount() -> (step: Int, done: Int, total: Int)? {
        guard let text = progressText() else { return nil }
        let digits = text.replacingOccurrences(of: ".", with: "")
        guard let s = digits.firstMatch(of: #/Schritt (\d+) von \d+/#), let step = Int(s.1),
              let m = digits.firstMatch(of: #/(\d+) von (\d+) /#), let done = Int(m.1), let total = Int(m.2) else { return nil }
        return (step, done, total)
    }

    /// Label and value of the card's progress element, from one snapshot.
    private func progressText() -> String? {
        guard let snapshot = try? app.descendants(matching: .any)["analysis.progress"].firstMatch.snapshot() else { return nil }
        return snapshot.label + " " + ((snapshot.value as? String) ?? "")
    }

    /// The overview headline after a run: "Alle 246 Fotos analysiert" or "239 von 246 Fotos
    /// analysiert", as (analysed, total).
    private func analysedPhotos() -> (analysed: Int, total: Int)? {
        let headline = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Fotos analysiert")).firstMatch
        guard let label = try? headline.snapshot().label else { return nil }
        let plain = label.replacingOccurrences(of: ".", with: "")
        if let m = plain.firstMatch(of: #/Alle (\d+) Fotos analysiert/#), let n = Int(m.1) { return (n, n) }
        if let m = plain.firstMatch(of: #/(\d+) von (\d+) Fotos analysiert/#), let a = Int(m.1), let t = Int(m.2) { return (a, t) }
        return nil
    }

    private var everyPhotoAnalysed: Bool {
        guard let counts = analysedPhotos() else { return false }
        return counts.total > 0 && counts.analysed == counts.total
    }

    /// The headline says every photo is analysed, read until it does for up to 15 s: a snapshot
    /// taken while the finished card replaces the running one reads nothing, and device test 03
    /// failed on that although its screenshot a moment later showed "Alle 246 Fotos analysiert"
    /// (UI run 44091312348). A count that stays short still fails, with what was read.
    private func expectEveryPhotoAnalysed(_ context: String) {
        let complete = waitStable("every photo analysed \(context)", timeout: 15, stableChecks: 1) { everyPhotoAnalysed }
        XCTAssertTrue(complete, "Not every photo was analysed \(context): \(analysedPhotos().map { "\($0.analysed) of \($0.total)" } ?? "no count readable")")
    }

    /// Every label inside `element`, read from one snapshot.
    private func allLabels(_ element: XCUIElement) -> String {
        guard let snapshot = try? element.snapshot() else { return "" }
        var labels: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if !s.label.isEmpty && !labels.contains(s.label) { labels.append(s.label) }
            s.children.forEach(walk)
        }
        walk(snapshot)
        return labels.joined(separator: " | ")
    }

    // MARK: Count that never goes back

    private var seen: [(step: Int, done: Int, total: Int)] = []

    /// Prints the progress and fails when it went back since the last record.
    private func record(_ moment: String) {
        guard let count = analysisCount() else {
            print("UI_FACT analysis \(moment): no count (running \(analysisRunning))")
            return
        }
        print("UI_FACT analysis \(moment): step \(count.step) \(count.done)/\(count.total)")
        if let last = seen.last {
            let back = count.step < last.step || (count.step == last.step && count.total == last.total && count.done < last.done)
            print(back ? "UI_STEP_MISSING count never goes back (\(moment))" : "UI_STEP_OK count never goes back (\(moment))")
            XCTAssertFalse(back, "The analysis went back at \(moment): \(last) -> \(count)")
        }
        seen.append(count)
    }

    /// Waits until the image step (4) runs, where most of the time goes.
    @discardableResult
    private func waitForImageStep(_ what: String) -> Bool {
        let reached = waitStable(what, timeout: 300, stableChecks: 1) { (analysisCount()?.step ?? 0) >= 4 }
        XCTAssertTrue(reached, "The analysis did not reach the image step (\(what))")
        return reached
    }

    // MARK: Setup

    /// Each test may be the first on a fresh simulator: the onboarding counts as done, the
    /// demo library is created and analysed. Later tests on the same simulator find it ready.
    private func prepare() {
        let started = Date()
        start()
        onboardIfNeeded()
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 3), !anything("Beispielfotos werden angelegt").exists {
            UITestOnboarding.clock("tap demo library")
            demo.tap()
        }
        let ready = waitStable("demo library analysed", timeout: 900) {
            (analysedPhotos()?.total ?? 0) >= 200 && !analysisRunning && !anything("Beispielfotos werden angelegt").exists
        }
        print(ready ? "UI_STEP_OK prepared" : "UI_STEP_MISSING prepared")
        XCTAssertTrue(ready, "The demo library was not created and analysed")
        print("UI_TIMING prepare \(Int(Date().timeIntervalSince(started))) s")
    }

    private enum PhotoChoice { case full, limited, deny }

    /// "Kein Zugriff auf deine Fotos" (plugin review W4): once the introduction is done, an app
    /// without photo access shows this screen instead of the introduction. "Weiter" when iOS
    /// will ask, "Einstellungen öffnen" when access was denied.
    private var askAgain: XCUIElement { app.buttons["access.continue"] }
    private var toSettings: XCUIElement { app.buttons["access.settings"] }

    /// The introduction (fresh install) or the "Kein Zugriff" screen (access taken away after
    /// it), if one of them shows; afterwards the app has full access. A denied access cannot be
    /// given back inside the app: the workflow gives it back from the Mac (`grantFromHost`).
    private func onboardIfNeeded(attempt: Int = 1) {
        let extra = launchExtra
        let welcome = button("Los geht")
        _ = waitStable("first screen", timeout: 20, stableChecks: 1) {
            welcome.exists || app.tabBars.firstMatch.exists || askAgain.exists || toSettings.exists
        }
        var asked = false
        if welcome.exists {
            if onboarding(.full) { return }
        } else if askAgain.exists {
            asked = grantOnNoAccessScreen(.full)
        }
        // In UI runs 43766407272 and 43795445305 iOS answered for the user after a reset (no
        // question, access denied), and every later test of the group ran without photos.
        if attempt < 3, !app.tabBars.firstMatch.exists, toSettings.waitForExistence(timeout: 3) {
            print("UI_FACT photo access denied: given back from the Mac")
            grantFromHost(relaunchWith: extra)
            onboardIfNeeded(attempt: attempt + 1)
        } else if asked {
            // Opened once more, so the launch runs as with access (the fast start's demo
            // library, if missing), with the test's own arguments.
            launch(extra)
        }
    }

    /// Full photo access given back from outside: the simulator in CI shows no iOS question
    /// after a reset (the answer is "denied" at once), and "Einstellungen öffnen" lands on the
    /// Settings app's first page, not on Albumist's. The test asks with a log line; the
    /// workflow, which follows the log, grants the access with `simctl privacy` and the app is
    /// opened again. (Run in Xcode without the workflow, nobody answers and this returns false.)
    /// `relaunchWith`: the test's own launch arguments (nil: a fast start).
    @discardableResult
    private func grantFromHost(relaunchWith extra: [String]? = nil) -> Bool {
        print("UI_HOST_GRANT_PHOTOS")
        for attempt in 1...12 {
            sleep(5)
            if let extra { launch(extra) } else { start() }
            let shown = waitStable("first screen after the grant", timeout: 30, stableChecks: 1) {
                app.tabBars.firstMatch.exists || askAgain.exists || toSettings.exists || button("Los geht").exists
            }
            // Given back only when the app shows a screen with access (UI run 44022880773 counted
            // a launch that showed none of these screens as given back, and the test then
            // waited for an overview that did not come).
            if shown, !askAgain.exists, !toSettings.exists {
                print("UI_STEP_OK photo access given back from the Mac")
                return true
            }
            if !shown { shot("x-no-screen-after-grant-\(attempt)") }
        }
        print("UI_STEP_MISSING photo access given back from the Mac")
        XCTFail("No screen with photo access after the grant from the Mac")
        return false
    }

    /// "Weiter" on the "Kein Zugriff" screen, then the iOS question answered with `choice`.
    /// Returns false when the screen or the question did not show.
    @discardableResult
    private func grantOnNoAccessScreen(_ choice: PhotoChoice) -> Bool {
        guard tap(askAgain, "no photo access: continue", timeout: 20) else { return false }
        return answerPhotoQuestion(choice)
    }

    /// Walks through the onboarding and answers the system's photo question with `choice`.
    /// Returns true when the overview was reached.
    @discardableResult
    private func onboarding(_ choice: PhotoChoice) -> Bool {
        guard tap(button("Los geht"), "welcome") else { return false }
        sleep(1)
        tap(app.buttons["Weiter"], "areas")
        sleep(1)
        // "Weiter" before the iOS question (plugin review K5; it said "Zugriff erlauben" before).
        var answered = false
        if askAgain.waitForExistence(timeout: 5) {
            askAgain.tap()
            answered = answerPhotoQuestion(choice)
        }
        guard choice != .deny else { return false }
        // With access granted the app moves on by itself; "Weiter" when it had been granted before.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !button("Analyse starten").exists {
            // iOS answered "denied" without asking (CI after an access reset, also one left
            // by an earlier test): the caller gives the access back from the Mac and walks
            // the onboarding again (`onboardIfNeeded`), instead of failing on a missing
            // "Analyse starten" (test 10 in UI run 44108052342). After a question this test
            // answered, the screen is the app's doing and stays a failure below.
            if !answered, toSettings.exists {
                print("UI_FACT onboarding: photo access denied without a question")
                return false
            }
            let next = app.buttons["Weiter"]
            if next.exists && next.isHittable { next.tap() }
            sleep(1)
        }
        guard choice == .full || button("Analyse starten").exists else {
            // The limited picker could not be driven: the caller falls back to the switch.
            print("UI_STEP_MISSING onboarding reached the start (\(choice))")
            return false
        }
        guard tap(button("Analyse starten"), "start analysis", timeout: 5) else { return false }
        answerNotificationQuestion(allow: false)
        return true
    }

    /// The button that gives `choice` in the system's photo question (in the simulator's own
    /// language).
    private func photoAnswer(_ choice: PhotoChoice) -> NSPredicate {
        switch choice {
        case .full:
            return NSPredicate(format: "label CONTAINS[c] 'full access' OR label CONTAINS[c] 'all photos' OR label CONTAINS[c] 'alle Fotos' OR label CONTAINS[c] 'vollen Zugriff' OR label CONTAINS[c] 'Vollzugriff'")
        case .limited:
            return NSPredicate(format: "label CONTAINS[c] 'limit' OR label CONTAINS[c] 'beschränken' OR label CONTAINS[c] 'select photos' OR label CONTAINS[c] 'Fotos auswählen'")
        case .deny:
            return NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "Nicht erlauben"])
        }
    }

    private var photoQuestionAnswered = false

    /// Called by the interruption monitor with the alert iOS shows.
    private func answer(_ alert: XCUIElement, _ choice: PhotoChoice) -> Bool {
        print("UI_FACT photo question: \(allLabels(alert))")
        let answer = alert.buttons.matching(photoAnswer(choice)).firstMatch
        guard answer.exists else { return false }
        answer.tap()
        photoQuestionAnswered = true
        return true
    }

    /// The system's photo question.
    @discardableResult
    private func answerPhotoQuestion(_ choice: PhotoChoice, timeout: TimeInterval = 25) -> Bool {
        let predicate = photoAnswer(choice)
        // In UI run 43763236960 the question was not found among Springboard's buttons, and
        // XCTest's own handler then answered it with "Don't Allow" at the next wait. A monitor
        // sees the alert wherever iOS shows it; a tap on the status bar (scrolls to the top,
        // nothing else) is the interaction that lets XCTest call it.
        photoQuestionAnswered = false
        let monitor = addUIInterruptionMonitor(withDescription: "photo question") { alert in
            MainActor.assumeIsolated { self.answer(alert, choice) }
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !photoQuestionAnswered {
            if let answer = [springboard.buttons.matching(predicate).firstMatch, app.alerts.buttons.matching(predicate).firstMatch].first(where: { $0.exists }) {
                shot("photo-question-\(choice)")
                answer.tap()
                photoQuestionAnswered = true
                break
            }
            if choice == .full && button("Analyse starten").exists { return false } // granted before
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            usleep(500_000)
        }
        guard photoQuestionAnswered else {
            print("UI_STEP_MISSING photo question (\(choice))")
            print("UI_FACT springboard shows: \(allLabels(springboard).prefix(400))")
            shot("x-no-photo-question")
            return false
        }
        print("UI_STEP_OK photo question answered (\(choice))")
        if choice == .limited { finishLimitedPicker() }
        return true
    }

    /// After "Limit Access" iOS shows its picker; it is closed as it is (limited to what was
    /// picked, possibly nothing).
    private func finishLimitedPicker() {
        let done = NSPredicate(format: "label IN %@", ["Done", "Fertig", "Continue", "Fortfahren"])
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for source in [app, springboard] {
                if let close = source.buttons.matching(done).allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                    shot("limited-picker")
                    print("UI_FACT limited picker closed with '\(close.label)'")
                    close.tap()
                    return
                }
            }
            usleep(500_000)
        }
        shot("x-limited-picker")
        print("UI_STEP_MISSING limited picker closed")
    }

    /// The notification question after "Analyse starten" (A10: always "Nicht erlauben" here).
    private func answerNotificationQuestion(allow: Bool) {
        let labels = allow ? ["Erlauben", "Allow"] : ["Nicht erlauben", "Don’t Allow", "Don't Allow"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            for label in labels where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
                print("UI_STEP_OK notification question answered (\(allow ? "allow" : "don't allow"))")
                return
            }
            usleep(500_000)
        }
        print("UI_FACT no notification question")
    }

    /// iOS asks before an app deletes albums. Returns true when it asked and was answered;
    /// stops waiting once `done` holds.
    private func answerDeleteQuestion(allow: Bool, timeout: TimeInterval, done: () -> Bool = { false }) -> Bool {
        let labels = allow ? ["Delete", "Löschen"] : ["Don’t Allow", "Don't Allow", "Nicht erlauben", "Cancel", "Abbrechen"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                let answer = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                guard answer.exists else { continue }
                shot(allow ? "delete-question" : "delete-question-deny")
                print("UI_FACT delete question: \(allLabels(alert))")
                answer.tap()
                print("UI_STEP_OK delete question answered (\(allow ? "delete" : "don't allow"))")
                return true
            }
            if done() { return false }
            usleep(500_000)
        }
        return false
    }

    /// Taps the button of an open dialog (another button with the same label can sit behind it).
    @discardableResult
    private func confirm(_ label: String, _ step: String) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            if let hit = candidates.last(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                print("UI_STEP_OK \(step)")
                return true
            }
            usleep(500_000)
        }
        print("UI_STEP_MISSING \(step)")
        shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
        XCTFail("Missing: \(step)")
        return false
    }

    /// Closes the app's notices ("Hinweis") and returns their texts.
    @discardableResult
    private func dismissNotices() -> [String] {
        var texts: [String] = []
        for _ in 0..<6 {
            let alert = app.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1) else { break }
            let text = allLabels(alert)
            print("UI_FACT notice: \(text)")
            texts.append(text)
            let ok = alert.buttons["OK"]
            if ok.exists { ok.tap() } else if alert.buttons.firstMatch.exists { alert.buttons.firstMatch.tap() }
            sleep(1)
        }
        return texts
    }

    /// "Analyse neu aufbauen" in the settings: a full run from scratch.
    @discardableResult
    private func rebuildAnalysis() -> Bool {
        guard tap(app.buttons["Einstellungen"], "settings for rebuild", timeout: 20) else { return false }
        let list = app.collectionViews.firstMatch
        let rebuild = app.buttons["Analyse neu aufbauen"]
        var swipes = 0
        while !(rebuild.exists && rebuild.isHittable) && swipes < 12 { (list.exists ? list : app).swipeUp(); swipes += 1 }
        guard tap(rebuild, "rebuild analysis"), tap(app.buttons["Neu aufbauen"], "confirm rebuild") else { return false }
        sleep(1)
        if app.buttons["Fertig"].exists { app.buttons["Fertig"].tap() }
        return true
    }

    /// The photos of the library tab (each one is a button named with its date).
    private var libraryPhotos: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
    }

    /// Two photos from the library into a new album: opens the plan for it ("Umsetzen").
    private func openManualPlan(_ title: String) -> Bool {
        guard tap(tabButton("Mediathek"), "library for \(title)") else { return false }
        sleep(2)
        if !libraryPhotos.firstMatch.waitForExistence(timeout: 5) {
            tap(app.buttons["Alle"], "all photos for \(title)", timeout: 5)
            sleep(2)
        }
        guard tap(app.buttons["Auswählen"], "select photos for \(title)") else { return false }
        sleep(1)
        guard libraryPhotos.count >= 2 else {
            print("UI_STEP_MISSING two photos for \(title)")
            XCTFail("The library shows fewer than two photos")
            return false
        }
        libraryPhotos.element(boundBy: 0).tap()
        libraryPhotos.element(boundBy: 1).tap()
        guard tap(button("Zu Album hinzufügen"), "add to album for \(title)") else { return false }
        var field = app.textFields["Name des neuen Albums"]
        if !field.waitForExistence(timeout: 5) { field = app.textFields.firstMatch }
        guard tap(field, "name for \(title)") else { return false }
        field.typeText(title)
        guard tap(app.buttons["Anlegen"], "create \(title)") else { return false }
        let plan = app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
        print(plan ? "UI_STEP_OK plan for \(title)" : "UI_STEP_MISSING plan for \(title)")
        XCTAssertTrue(plan, "Adding photos to a new album did not open its plan")
        return plan
    }

    /// Applies a new album of two photos and waits for the result card.
    private func applyManualPlan(_ title: String) -> Bool {
        guard openManualPlan(title), tap(app.buttons["plan.apply"], "apply \(title)", timeout: 30) else { return false }
        let done = app.buttons["result.receipt"].waitForExistence(timeout: 180)
        print(done ? "UI_STEP_OK \(title) applied" : "UI_STEP_MISSING \(title) applied")
        XCTAssertTrue(done, "The plan for \(title) did not finish")
        return done
    }

    /// Starts a plan made slow on purpose and closes the app half way, then opens it again.
    /// Fails (instead of passing silently) when the plan was done before the app was closed.
    private func interruptManualPlan(_ title: String) -> Bool {
        start(["-SortlyUITestSlowPlan"])
        guard openManualPlan(title), tap(app.buttons["plan.apply"], "start \(title)", timeout: 30) else { return false }
        // The first change goes through at once, every later one waits 30 s: after 5 s one
        // step is done and the next is not.
        sleep(5)
        print("UI_FACT \(title) running when the app was closed: \(anything("Alben werden angelegt").exists)")
        app.terminate()
        sleep(2)
        start()
        let card = anything("wurde unterbrochen").waitForExistence(timeout: 30)
        print(card ? "UI_STEP_OK interruption card for \(title)" : "UI_STEP_MISSING interruption card for \(title)")
        XCTAssertTrue(card, "No interruption card: the plan for \(title) finished before the app was closed")
        if card { sleep(1); shot("interrupted-\(title.replacingOccurrences(of: " ", with: "-"))") }
        return card
    }

    /// The album is listed in the albums tab ("Von Albumist angelegt oder ergänzt").
    private func albumExists(_ title: String) -> Bool {
        guard tap(tabButton("Alben"), "albums tab for \(title)") else { return false }
        sleep(2)
        let album = anything(title)
        var swipes = 0
        while !album.exists && swipes < 3 { app.swipeUp(); sleep(1); swipes += 1 }
        let exists = album.exists
        print("UI_FACT album \(title) exists: \(exists)")
        tap(tabButton("Übersicht"), "overview after albums")
        return exists
    }

    /// How many photos the album's row in the albums tab names ("Testalbum Vollendet, 2 Fotos"),
    /// nil when the row is not there.
    private func albumPhotoCount(_ title: String) -> Int? {
        guard tap(tabButton("Alben"), "albums tab for the photos of \(title)") else { return nil }
        sleep(2)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        var swipes = 0
        while !row.exists && swipes < 3 { app.swipeUp(); sleep(1); swipes += 1 }
        let label = row.exists ? row.label : ""
        print("UI_FACT album row \(title): \(label)")
        tap(tabButton("Übersicht"), "overview after albums")
        guard let count = label.firstMatch(of: #/([0-9][0-9.]*) Fotos?/#)?.1 else { return nil }
        return Int(count.replacingOccurrences(of: ".", with: ""))
    }

    // MARK: 1–2 Heat, battery, Low Power Mode

    /// A warm iPhone only slows the analysis down, a hot one makes it wait and say so; it is
    /// never ended and goes on by itself when the phone cooled down (first iPhone test 15.11.:
    /// "bricht die Suche ab").
    func test01_WarmAndHotPhoneWaitAndFinish() {
        continueAfterFailure = true
        prepare()
        // 40 checks normal, 40 warm, 10 hot (about 20 s of waiting), then the real device.
        start(["-SortlyUITestPace", "normal:40,gentle:40,hot:10,normal"])
        guard rebuildAnalysis() else { return }
        // The card's title (its accessibility label since rc-1's one-element card).
        let heat = anything("Wartet, bis dein iPhone abkühlt")
        let waited = heat.waitForExistence(timeout: 300)
        print(waited ? "UI_STEP_OK hot iPhone shows waiting" : "UI_STEP_MISSING hot iPhone shows waiting")
        XCTAssertTrue(waited, "A hot iPhone did not show that the analysis waits")
        if waited {
            shot("01-hot-waiting")
            XCTAssertTrue(analysisRunning, "While it waits for a cooler iPhone the analysis must not end")
            XCTAssertFalse(app.buttons["Fortsetzen"].exists, "A hot iPhone ended the analysis")
            let cooled = waitGone(heat, timeout: 120)
            print(cooled ? "UI_STEP_OK goes on after cooling down" : "UI_STEP_MISSING goes on after cooling down")
            XCTAssertTrue(cooled, "The analysis kept waiting after the iPhone cooled down")
        }
        let finished = waitStable("analysis finished after heat", timeout: 900) { analysisIdle }
        XCTAssertTrue(finished, "The analysis did not finish after the heat")
        print("UI_FACT after heat \(String(describing: analysedPhotos()))")
        expectEveryPhotoAnalysed("after the heat")
        XCTAssertFalse(anything("Analyse pausiert").exists, "The analysis stopped for heat")
        shot("02-after-heat")
    }

    /// A nearly empty battery makes the analysis wait with its own words (not "warm"); Low
    /// Power Mode does not stop it (iOS already slows the phone down) and never shows as paused.
    func test02_LowBatteryAndLowPowerModeWording() {
        continueAfterFailure = true
        prepare()
        start(["-SortlyUITestPace", "normal:30,battery:8,lowpower"])
        guard rebuildAnalysis() else { return }
        let battery = anything("Wartet aufs Laden")
        let waited = battery.waitForExistence(timeout: 300)
        print(waited ? "UI_STEP_OK low battery shows waiting" : "UI_STEP_MISSING low battery shows waiting")
        XCTAssertTrue(waited, "A nearly empty battery did not show that the analysis waits")
        if waited {
            shot("03-battery-waiting")
            XCTAssertFalse((progressText() ?? "").contains("abkühlt"), "Low battery was worded as heat")
            XCTAssertTrue(analysisRunning, "Low battery ended the analysis")
        }
        var pausedForLowPower = false
        let finished = waitStable("analysis finished in Low Power Mode", timeout: 900) {
            if text("Pausiert im Stromsparmodus").exists || (progressText() ?? "").contains("pausiert") { pausedForLowPower = true }
            return analysisIdle
        }
        XCTAssertTrue(finished, "The analysis did not finish in Low Power Mode")
        XCTAssertFalse(pausedForLowPower, "Low Power Mode paused the analysis in the app")
        XCTAssertFalse(app.buttons["Fortsetzen"].exists, "The analysis waits for a tap after low battery")
        expectEveryPhotoAnalysed("after low battery")
        shot("04-after-battery")
    }

    // MARK: 3 Background time over, app ended

    /// The worst case of background time: iOS ends the run while the app is away. Coming back
    /// goes on without a tap. Then the app is ended during the analysis (A4) and started again:
    /// it goes on by itself, its count never goes down, and every photo ends up analysed.
    func test03_BackgroundExpiryAndRelaunchContinue() {
        continueAfterFailure = true
        prepare()
        seen = []
        start(["-SortlyUITestSlowAnalysis", "-SortlyUITestExpireInBackground"])
        guard rebuildAnalysis(), waitForImageStep("image step before leaving") else { return }
        record("before leaving")
        XCUIDevice.shared.press(.home)
        sleep(6) // the run ends in the background: iOS took the time away
        app.activate()
        var caughtUp = false
        let goesOn = waitStable("analysis goes on after the background time ran out", timeout: 40, stableChecks: 2) {
            if anything("Gleich wieder bei Schritt").exists || anything("Macht da weiter").exists { caughtUp = true }
            return analysisRunning || analysisIdle
        }
        print("UI_FACT restart after expiry seen on screen: \(caughtUp)")
        XCTAssertTrue(goesOn, "After the background time ran out the analysis neither runs nor is done")
        XCTAssertFalse(app.buttons["Fortsetzen"].exists, "After the background time ran out the analysis waits for a tap")
        shot("05-after-expiry")
        _ = waitStable("count after expiry", timeout: 60, stableChecks: 1) { analysisCount() != nil || analysisIdle }
        record("after expiry")

        // A4: the app is ended during the analysis and opened again.
        if analysisIdle {
            guard rebuildAnalysis(), waitForImageStep("image step before ending the app") else { return }
            seen = []
        }
        record("before ending the app")
        app.terminate()
        sleep(2)
        start(["-SortlyUITestSlowAnalysis", "-SortlyUITestLaunchAnalysis"])
        let restarted = waitStable("analysis runs by itself after relaunch", timeout: 60, stableChecks: 1) { analysisRunning || analysisIdle }
        XCTAssertTrue(restarted, "After the app was opened again the analysis did not go on")
        XCTAssertFalse(app.buttons["Fortsetzen"].exists, "After the app was opened again the analysis waits for a tap")
        shot("06-after-relaunch")
        _ = waitStable("count after relaunch", timeout: 120, stableChecks: 1) { analysisCount() != nil || analysisIdle }
        record("after relaunch")
        var checks = 0
        while !analysisIdle && checks < 200 {
            sleep(3)
            if checks % 4 == 0 { record("after relaunch, running") }
            checks += 1
        }
        let finished = waitStable("analysis finished after relaunch", timeout: 120) { analysisIdle }
        XCTAssertTrue(finished, "The analysis did not finish after the app was opened again")
        expectEveryPhotoAnalysed("after the relaunch")
        shot("07-done-after-relaunch")
    }

    // MARK: 4 Unreadable, iCloud only, offline

    /// Photos without a readable preview yet (still syncing), documents only in iCloud and no
    /// network: the analysis still completes, says how many photos it could not read, places
    /// come from the offline map and the rest waits. No error, no loop. Back online with the
    /// photos readable, "Neu prüfen" reads the rest.
    func test04_UnreadableICloudOfflineComplete() {
        continueAfterFailure = true
        prepare()
        start(["-SortlyUITestUnreadable", "7", "-SortlyUITestICloudOnly", "-SortlyUITestOffline"])
        guard rebuildAnalysis() else { return }
        let finished = waitStable("analysis with unreadable photos finished", timeout: 900) { analysisIdle }
        XCTAssertTrue(finished, "The analysis did not complete with unreadable photos, iCloud documents and no network")
        sleep(2)
        shot("08-unreadable-offline")
        let unreadable = anything("7 Fotos konnten noch nicht gelesen werden").exists
        print(unreadable ? "UI_STEP_OK unreadable photos counted" : "UI_STEP_MISSING unreadable photos counted")
        XCTAssertTrue(unreadable, "The overview does not say that 7 photos could not be read")
        let counts = analysedPhotos()
        print("UI_FACT headline with unreadable photos \(String(describing: counts))")
        if let counts { XCTAssertEqual(counts.total - counts.analysed, 7, "The headline does not leave out exactly the 7 unreadable photos") }
        let icloud = anything("Dokumente liegen nur in iCloud").exists
        print(icloud ? "UI_STEP_OK iCloud documents counted" : "UI_STEP_MISSING iCloud documents counted")
        XCTAssertTrue(icloud, "The overview does not say that documents wait for iCloud")
        let places = anything("Orte werden später genauer bestimmt").exists
        print(places ? "UI_STEP_OK offline places pending" : "UI_STEP_MISSING offline places pending")
        XCTAssertTrue(places, "The overview does not say that places wait for the network")
        // No error loop: nothing to dismiss, nothing restarts, and nothing waits for a tap.
        let quiet = waitStable("no error loop offline", timeout: 30, stableChecks: 6) { analysisIdle && !app.alerts.firstMatch.exists }
        XCTAssertTrue(quiet, "Offline the analysis kept restarting or showed errors")
        XCTAssertFalse(app.buttons["Fortsetzen"].exists, "Offline the analysis ended as paused")
        // Countries come from the offline map.
        let teaser = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dein Reise-Atlas")).firstMatch
        if teaser.waitForExistence(timeout: 10), let label = try? teaser.snapshot().label {
            print("UI_FACT atlas offline \(label)")
            let countries = label.firstMatch(of: #/(\d+) Länder/#).flatMap { Int($0.1) } ?? 0
            XCTAssertGreaterThanOrEqual(countries, 8, "Offline the atlas knows too few countries: \(label)")
        } else {
            print("UI_STEP_MISSING atlas offline")
            XCTFail("No travel atlas without network")
        }

        // Online again and every preview readable: "Neu prüfen" runs calmly. A photo that could
        // not be read is tried again only an hour later (ContentAnalysis.retrySpacing, since
        // rc-1), so the note stays and says so; UI run 43795445305 waited 600 s for it in vain.
        start()
        guard tap(app.buttons["Neu prüfen"], "check again online", timeout: 20) else { return }
        let calm = waitStable("check again online finished", timeout: 300) { analysisIdle && !app.alerts.firstMatch.exists }
        XCTAssertTrue(calm, "Online \"Neu prüfen\" did not finish")
        let note = text("Fotos konnten noch nicht gelesen werden")
        print("UI_FACT online after Neu prüfen: \(String(describing: analysedPhotos())), unreadable note: \(note.exists ? note.label : "gone")")
        if note.exists {
            XCTAssertTrue(note.label.contains("später noch einmal"), "The unreadable note does not say that Albumist tries again later")
        }
        shot("09-online-again")
    }

    // MARK: 5 Undo when Photos does not delete

    /// Undo asks iOS before albums are deleted. First the real question is answered with
    /// "Nicht erlauben" (C4); then the two failures of the first iPhone are played by the
    /// switch: declined, and Photos reporting success while deleting nothing. Each time the
    /// receipt says what is left and why, and "Rest rückgängig machen" takes back everything.
    func test05_UndoWhenDeletionIsDeclinedOrIgnored() {
        continueAfterFailure = true
        prepare()
        undo(fault: nil, title: "Testalbum Frage", reason: "Löschen in der Frage von iOS nicht erlaubt")
        undo(fault: "declined", title: "Testalbum Abgelehnt", reason: "Löschen in der Frage von iOS nicht erlaubt")
        undo(fault: "ignored", title: "Testalbum Ignoriert", reason: "Löschen nicht ausgeführt")
    }

    private func undo(fault: String?, title: String, reason: String) {
        start(fault.map { ["-SortlyUITestDeletionFault", $0] } ?? [])
        guard applyManualPlan(title), tap(app.buttons["result.receipt"], "receipt of \(title)") else { return }
        sleep(2)
        let undo = app.buttons["receipt.undo"]
        var swipes = 0
        while !(undo.exists && undo.isHittable) && swipes < 6 { app.swipeUp(); swipes += 1 }
        guard tap(undo, "undo \(title)"), confirm("Rückgängig machen", "confirm undo of \(title)") else { return }
        let partial = anything("Nicht alles ließ sich zurücknehmen")
        let removed = anything("Entfernte Alben und Ordner")
        if fault == nil {
            let asked = answerDeleteQuestion(allow: false, timeout: 30) { partial.exists || removed.exists }
            guard asked else {
                // Some simulator runs never ask (run 43739129373); the switch parts still cover it.
                print("UI_FACT iOS did not ask before deleting \(title); real \"Nicht erlauben\" not tapped in this run")
                let complete = removed.waitForExistence(timeout: 60)
                XCTAssertTrue(complete, "Undo of \(title) did not finish")
                return
            }
        }
        let leftOver = partial.waitForExistence(timeout: 60)
        app.swipeUp(); sleep(1)
        shot("undo-partial-\(fault ?? "real")")
        print(leftOver ? "UI_STEP_OK partial undo shown (\(fault ?? "real question"))" : "UI_STEP_MISSING partial undo shown (\(fault ?? "real question"))")
        XCTAssertTrue(leftOver, "The receipt does not say that not everything was taken back (\(fault ?? "real question"))")
        let because = anything(reason)
        let shownReason = (try? because.snapshot().label) ?? "none"
        print("UI_FACT reason shown: \(shownReason)")
        XCTAssertTrue(because.exists, "The receipt does not say why (\(reason))")
        let rest = app.buttons["receipt.undoRest"]
        swipes = 0
        while !(rest.exists && rest.isHittable) && swipes < 4 { app.swipeUp(); swipes += 1 }
        guard tap(rest, "undo the rest of \(title)"), confirm("Rückgängig machen", "confirm undo of the rest of \(title)") else { return }
        let asked = answerDeleteQuestion(allow: true, timeout: 30) { removed.exists && !partial.exists }
        print("UI_FACT second attempt asked by iOS: \(asked)")
        let complete = waitStable("rest of \(title) taken back", timeout: 60, stableChecks: 2) { removed.exists && !partial.exists }
        app.swipeUp(); sleep(1)
        shot("undo-complete-\(fault ?? "real")")
        print(complete ? "UI_STEP_OK second attempt took back everything (\(fault ?? "real question"))" : "UI_STEP_MISSING second attempt took back everything (\(fault ?? "real question"))")
        XCTAssertTrue(complete, "The second attempt did not take back everything (\(fault ?? "real question"))")
    }

    // MARK: 6 Full disk

    /// A full disk during the analysis and during a plan: a message the user can act on, no
    /// crash, and once there is space again (the user left the app to free some) everything
    /// goes on: the analysis by itself, the plan as an interrupted plan.
    func test06_DiskFullDuringAnalysisAndPlan() {
        continueAfterFailure = true
        prepare()
        start(["-SortlyUITestDiskFull", "analysis"])
        guard rebuildAnalysis() else { return }
        let notice = app.alerts.firstMatch
        let told = notice.waitForExistence(timeout: 300)
        let text = allLabels(notice)
        print("UI_FACT disk full during analysis: \(text)")
        shot("10-disk-full-analysis")
        XCTAssertTrue(told && text.contains("Speicher deines iPhone ist voll"), "A full disk during the analysis was not explained: \(text)")
        dismissNotices()
        XCTAssertEqual(app.state, .runningForeground, "The app ended with a full disk")
        // Space is freed in the Settings app; back in Albumist the analysis goes on by itself.
        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        let finished = waitStable("analysis finished after the disk had space again", timeout: 900) {
            if app.alerts.firstMatch.exists { dismissNotices() }
            return analysisIdle && everyPhotoAnalysed
        }
        XCTAssertTrue(finished, "The analysis did not go on after the disk had space again")
        shot("11-after-disk-full-analysis")

        start(["-SortlyUITestDiskFull", "plan"])
        let title = "Testalbum Speicher"
        guard openManualPlan(title), tap(app.buttons["plan.apply"], "apply \(title)", timeout: 30) else { return }
        let failure = anything("Speicher deines iPhone ist voll")
        let said = failure.waitForExistence(timeout: 120)
        shot("12-disk-full-plan")
        print(said ? "UI_STEP_OK full disk during plan explained" : "UI_STEP_MISSING full disk during plan explained")
        XCTAssertTrue(said, "A full disk during the plan was not explained")
        print("UI_FACT plan failure card shown: \(anything("Nicht alles hat geklappt").exists)")
        dismissNotices()
        XCTAssertEqual(app.state, .runningForeground, "The app ended with a full disk during the plan")
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.terminate()
        sleep(2)
        start()
        let card = anything("wurde unterbrochen")
        let offered = card.waitForExistence(timeout: 30)
        print(offered ? "UI_STEP_OK plan offered after full disk" : "UI_STEP_MISSING plan offered after full disk")
        XCTAssertTrue(offered, "After the full disk the unfinished plan is not offered")
        guard offered, tap(app.buttons["Rest anlegen"], "continue plan after full disk") else { return }
        let resumed = waitGone(card, timeout: 120)
        dismissNotices()
        XCTAssertTrue(resumed, "Continuing the plan after the full disk did not finish it")
        XCTAssertTrue(albumExists(title), "The album of the plan is missing after continuing")
        shot("13-plan-after-disk-full")
    }

    // MARK: 7–8 Interrupted plan, removing an album

    /// A5: the app is closed while a plan runs (made slow, so it always lands half way). Both
    /// ways out: "Rest anlegen" finishes the album, "Alles zurücknehmen" takes back what was done.
    /// The slow plan stops before its add request reaches Photos, so "Rest anlegen" has to fill
    /// the album the plan made (UI run 43949880264 left "Testalbum Vollendet" with 0 photos).
    func test07_InterruptedPlanContinueAndUndo() {
        continueAfterFailure = true
        prepare()
        let card = anything("wurde unterbrochen")
        // Album titles stay clear of the words the tap-through sweep never taps ("Fortsetzen",
        // "Entfernen", …, SortlyFlowUITests.sweepSkip): the albums stay in Photos, and test3
        // runs on the same simulator after these tests (UI run 43930271358: "The sweep reached
        // no screen from Alben", both album rows were skipped by their titles).
        let continued = "Testalbum Vollendet"
        if interruptManualPlan(continued), tap(app.buttons["Rest anlegen"], "continue interrupted plan") {
            let done = waitGone(card, timeout: 120)
            print(done ? "UI_STEP_OK interrupted plan continued" : "UI_STEP_MISSING interrupted plan continued")
            XCTAssertTrue(done, "\"Rest anlegen\" did not finish the interrupted plan")
            // Nothing left over: no "Das hat nicht geklappt" (it would name an unfinished step).
            let leftOver = anything("nicht geklappt").waitForExistence(timeout: 3)
            print("UI_FACT \"Rest anlegen\" left something undone: \(leftOver)")
            XCTAssertFalse(leftOver, "\"Rest anlegen\" reported something left undone")
            dismissNotices()
            let photos = albumPhotoCount(continued)
            XCTAssertNotNil(photos, "After \"Rest anlegen\" the album is missing")
            XCTAssertEqual(photos, 2, "After \"Rest anlegen\" the album does not hold the two photos of the plan")
        }
        let undone = "Testalbum Zurueck"
        if interruptManualPlan(undone), tap(app.buttons["Alles zurücknehmen"].firstMatch, "undo interrupted plan") {
            confirm("Alles zurücknehmen", "confirm undo of interrupted plan")
            let asked = answerDeleteQuestion(allow: true, timeout: 30) { !card.exists }
            print("UI_FACT undo of interrupted plan asked by iOS: \(asked)")
            let done = waitGone(card, timeout: 120)
            print(done ? "UI_STEP_OK interrupted plan taken back" : "UI_STEP_MISSING interrupted plan taken back")
            XCTAssertTrue(done, "\"Alles zurücknehmen\" did not settle the interrupted plan")
            dismissNotices()
            XCTAssertFalse(albumExists(undone), "After \"Alles zurücknehmen\" the album is still there")
        }
    }

    /// C9: an album Albumist made is removed through Albumist (Einstellungen › Alben von
    /// Albumist), and that removal is undone: the album is back.
    func test08_RemoveManagedAlbumAndUndo() {
        continueAfterFailure = true
        prepare()
        let title = "Testalbum Wiederhergestellt" // no sweep-skip word in it (see test07)
        start()
        guard applyManualPlan(title) else { return }
        start()
        guard tap(app.buttons["Einstellungen"], "settings for managed albums", timeout: 20) else { return }
        let managed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alben von Albumist")).firstMatch
        let list = app.collectionViews.firstMatch
        var swipes = 0
        while !(managed.exists && managed.isHittable) && swipes < 10 { (list.exists ? list : app).swipeUp(); swipes += 1 }
        guard tap(managed, "managed albums") else { return }
        sleep(1)
        shot("14-managed-albums")
        guard tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch, "managed album row"),
              confirm("Album entfernen", "remove managed album") else { return }
        guard app.navigationBars["Vorschau"].waitForExistence(timeout: 20), tap(app.buttons["plan.apply"], "apply removal", timeout: 30) else {
            print("UI_STEP_MISSING removal plan")
            XCTFail("Removing the album did not open its plan")
            return
        }
        let receipt = app.buttons["result.receipt"]
        let asked = answerDeleteQuestion(allow: true, timeout: 40) { receipt.exists }
        print("UI_FACT removal asked by iOS: \(asked)")
        let removed = receipt.waitForExistence(timeout: 120)
        print(removed ? "UI_STEP_OK managed album removed" : "UI_STEP_MISSING managed album removed")
        XCTAssertTrue(removed, "Removing the album did not finish")
        sleep(1)
        shot("15-album-removed")
        guard removed, tap(app.buttons["Rückgängig machen"].firstMatch, "undo removal"),
              confirm("Rückgängig machen", "confirm undo of removal") else { return }
        let undone = app.staticTexts["Rückgängig gemacht"].waitForExistence(timeout: 120)
        sleep(1)
        shot("16-removal-undone")
        print(undone ? "UI_STEP_OK removal undone" : "UI_STEP_MISSING removal undone")
        XCTAssertTrue(undone, "Undoing the removal did not finish")
        XCTAssertFalse(anything("Teilweise rückgängig").exists, "Undoing the removal was only partial")
        start()
        XCTAssertTrue(albumExists(title), "After undoing the removal the album is not back")
    }

    // MARK: 9–10 Photo access, empty library

    /// B3 denied and B2 limited through the real system question, then access taken away while
    /// the analysis runs (iOS ends the app then, as when it is changed in Settings). Ends with
    /// full access again, so later tests on this simulator are not affected.
    func test09_PhotoAccessDeniedLimitedAndRevoked() {
        continueAfterFailure = true
        prepare()

        // Denied. After the introduction an app without access shows "Kein Zugriff auf deine
        // Fotos" (plugin review W4), not the introduction again: "Weiter" leads to the iOS question.
        app.resetAuthorizationStatus(for: .photos)
        start()
        let screen = askAgain.waitForExistence(timeout: 20)
        print(screen ? "UI_STEP_OK no-access screen after access reset" : "UI_STEP_MISSING no-access screen after access reset")
        XCTAssertTrue(screen, "Resetting photo access did not bring the \"Kein Zugriff\" screen")
        XCTAssertFalse(button("Los geht").exists, "The introduction starts again after access was taken away")
        if screen {
            sleep(1)
            shot("17-no-access")
            grantOnNoAccessScreen(.deny)
            let denied = toSettings.waitForExistence(timeout: 10)
            sleep(1)
            shot("17a-access-denied")
            print(denied ? "UI_STEP_OK denied access explained" : "UI_STEP_MISSING denied access explained")
            XCTAssertTrue(denied, "Denied photo access offers no way to the Settings app")
            XCTAssertTrue(anything("Kein Zugriff auf deine Fotos").exists, "Denied photo access is not explained")
            XCTAssertFalse(app.tabBars.firstMatch.exists, "The app went on without photo access")
            start()
            let still = toSettings.waitForExistence(timeout: 20)
            XCTAssertEqual(app.state, .runningForeground, "The app does not start with denied access")
            print(still ? "UI_STEP_OK relaunch with denied access explained" : "UI_STEP_MISSING relaunch with denied access explained")
            XCTAssertTrue(still, "After a relaunch denied access is not explained")
            shot("17b-relaunch-denied")
        }

        // Limited (the real picker if the simulator lets the test drive it, else the switch)
        app.resetAuthorizationStatus(for: .photos)
        start()
        var limited = false
        if grantOnNoAccessScreen(.limited) {
            limited = anything("Nur ausgewählte Fotos").waitForExistence(timeout: 30)
        }
        print(limited ? "UI_STEP_OK limited access through the system question" : "UI_STEP_MISSING limited access through the system question")
        if !limited {
            restoreFullAccess()
            start(["-SortlyUITestLimitedAccess"])
            limited = anything("Nur ausgewählte Fotos").waitForExistence(timeout: 30)
            print("UI_FACT limited access through the switch: \(limited)")
        }
        sleep(1)
        shot("18-access-limited")
        XCTAssertTrue(limited, "Limited photo access is not explained on the overview")
        XCTAssertEqual(app.state, .runningForeground, "The app ended with limited access")

        // Revoked while the analysis runs
        restoreFullAccess()
        seen = []
        start(["-SortlyUITestSlowAnalysis"])
        guard rebuildAnalysis(), waitForImageStep("image step before access is taken away") else { return }
        record("before access was taken away")
        app.resetAuthorizationStatus(for: .photos)
        sleep(2)
        print("UI_FACT app state after access was taken away: \(app.state.rawValue)")
        start(["-SortlyUITestSlowAnalysis", "-SortlyUITestLaunchAnalysis"])
        let asks = askAgain.waitForExistence(timeout: 20)
        shot("19-access-revoked")
        print(asks ? "UI_STEP_OK asks for access again" : "UI_STEP_MISSING asks for access again")
        XCTAssertTrue(asks, "After access was taken away the app does not ask for it again")
        XCTAssertEqual(app.state, .runningForeground, "The app ended after access was taken away")
        if asks { grantOnNoAccessScreen(.full) }
        // Without the iOS question in CI the answer is "denied": given back from the Mac. When
        // that failed (recorded by `grantFromHost`), nothing after it can pass: the test ends
        // here instead of waiting 17 more minutes for an analysis without access (44108052342).
        if !app.tabBars.firstMatch.waitForExistence(timeout: 10), !grantFromHost() { return }
        let back = app.tabBars.firstMatch.waitForExistence(timeout: 30)
        print(back ? "UI_STEP_OK overview after access came back" : "UI_STEP_MISSING overview after access came back")
        if !back { shot("x-no-overview-after-access") }
        XCTAssertTrue(back, "The app does not go on after access came back")
        // On a phone the analysis goes on by itself once access is back; UI runs start their
        // analyses themselves, so the app is opened once more and starts it as at launch.
        start(["-SortlyUITestSlowAnalysis", "-SortlyUITestLaunchAnalysis"])
        _ = waitStable("count after access came back", timeout: 120, stableChecks: 1) { analysisCount() != nil || analysisIdle }
        record("after access came back")
        let finished = waitStable("analysis finished after access came back", timeout: 900) { analysisIdle }
        XCTAssertTrue(finished, "The analysis did not finish after access came back")
        expectEveryPhotoAnalysed("after access came back")
        shot("20-access-back")
    }

    /// Full photo access again through the onboarding.
    private func restoreFullAccess() {
        grantFromHost()
        onboardIfNeeded()
        let ready = waitStable("full access again", timeout: 60, stableChecks: 1) { app.tabBars.firstMatch.exists && !anything("Nur ausgewählte Fotos").exists }
        print(ready ? "UI_STEP_OK full access again" : "UI_STEP_MISSING full access again")
    }

    /// B5: a phone without photos, through the real onboarding (notifications declined, A10):
    /// a calm empty state, no error, nothing that waits forever.
    func test10_EmptyLibrary() {
        continueAfterFailure = true
        // Its own database; the onboarding shows although an earlier test finished it.
        launch(["-SortlyUITestEmptyLibrary", "-onboarding.done", "NO"])
        onboardIfNeeded()
        let idle = waitStable("empty library analysed", timeout: 120) { analysisIdle }
        sleep(1)
        shot("21-empty-overview")
        XCTAssertTrue(idle, "The analysis of an empty library did not end")
        // Since K6 (EmptyLibraryCard, merged from rc-2) the overview says why there is nothing
        // to sort instead of "0 von 0 sortiert": the card for an empty library, with its title
        // and explanation inside it (the card contains its elements, id overview.libraryHint).
        let hint = app.descendants(matching: .any)["overview.libraryHint"]
        func inHint(_ text: String) -> Bool {
            hint.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        let status = hint.waitForExistence(timeout: 10) && inHint("Noch keine Fotos") && inHint("Deine Mediathek ist leer")
        print(status ? "UI_STEP_OK empty status" : "UI_STEP_MISSING empty status")
        if !status { print("UI_FACT empty overview: \(allLabels(app.scrollViews.firstMatch))") }
        XCTAssertTrue(status, "The overview does not say that there is nothing to sort")
        XCTAssertFalse(anything("0 von 0 sortiert").exists, "An empty library shows the sorted ring instead of saying why")
        XCTAssertTrue(anything("Analyse aktuell").exists, "The analysis card of an empty library is not calm")
        XCTAssertFalse(button("Vorschläge prüfen").exists, "An empty library offers suggestions")
        XCTAssertFalse(app.alerts.firstMatch.exists, "An empty library shows an error")
        XCTAssertFalse(app.buttons["Fortsetzen"].exists, "An empty library waits for a tap")
        if tap(tabButton("Mediathek"), "library of empty library") {
            sleep(2)
            shot("22-empty-library")
            print("UI_FACT empty library screen: \(allLabels(app.scrollViews.firstMatch))")
            XCTAssertTrue(anything("0 Fotos und Videos").exists, "The library does not say it is empty")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: 11 A library of real size

    /// 3,000 more photos (120 trips): created once, then analysed. Prints the times and checks
    /// that lists, the overview, search and the atlas stay quick with a real-sized library.
    func test11_LargeLibrary() {
        continueAfterFailure = true
        prepare()
        let started = Date()
        start(["-SortlyUITestLargeLibrary", "3000"])
        let analysed = waitStable("large library created and analysed", timeout: 1800, stableChecks: 2) {
            guard let counts = analysedPhotos() else { return false }
            return counts.total >= 3200 && counts.analysed == counts.total && !analysisRunning
        }
        print("UI_TIMING large library create and analyse \(Int(Date().timeIntervalSince(started))) s")
        print("UI_FACT large library \(String(describing: analysedPhotos()))")
        XCTAssertTrue(analysed, "The large library was not analysed")
        shot("23-large-overview")

        func timed(_ what: String, limit: TimeInterval, _ action: () -> Void, until: () -> Bool) {
            let begin = Date()
            action()
            var reached = until()
            while !reached && Date().timeIntervalSince(begin) < limit * 2 {
                usleep(250_000)
                reached = until()
            }
            let seconds = Date().timeIntervalSince(begin)
            print("UI_TIMING large \(what) \(String(format: "%.1f", seconds)) s")
            XCTAssertTrue(reached && seconds < limit, "\(what) took \(Int(seconds)) s with a large library (limit \(Int(limit)) s)")
        }
        timed("library tab", limit: 15, { tabButton("Mediathek").tap() }, until: { libraryPhotos.firstMatch.exists })
        timed("all photos", limit: 15, { app.buttons["Alle"].tap() }, until: {
            guard let label = try? anything("Fotos und Videos").snapshot().label else { return false }
            return (Int(label.replacingOccurrences(of: ".", with: "").prefix { $0.isNumber }) ?? 0) >= 3200
        })
        timed("scroll library", limit: 20, { for _ in 0..<6 { app.swipeUp() } }, until: { libraryPhotos.firstMatch.exists })
        shot("24-large-library")
        timed("overview tab", limit: 10, { tabButton("Übersicht").tap() }, until: { anything("Fotos analysiert").exists })
        let atlas = button("Reise-Atlas")
        timed("atlas", limit: 15, { if atlas.waitForExistence(timeout: 5) { atlas.tap() } }, until: { app.navigationBars["Reise-Atlas"].exists })
        sleep(2)
        shot("25-large-atlas")
        if app.navigationBars["Reise-Atlas"].exists { app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap(); sleep(1) }
        let searchTab = ["Suchen", "Suche", "Search"].map { app.tabBars.buttons[$0] }.first(where: \.exists)
            ?? app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
        searchTab.tap()
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            timed("search Paris", limit: 15, { field.typeText("Paris") }, until: { libraryPhotos.count > 5 || anything("Treffer").exists })
            shot("26-large-search")
        }
    }

    // MARK: 12 Stress: 50 000 photos, iCloud-only, offline

    /// Runs only when the runner sets SORTLY_STRESS_PHOTOS (ui-stress.yml, started by hand;
    /// xcodebuild hands TEST_RUNNER_SORTLY_STRESS_PHOTOS on as that); the "device conditions"
    /// group of ui.yml skips it at once. Two phases, so that neither disturbs the other (stress runs
    /// 43795785359 and 43823462215 mixed them):
    /// 1. Creating: launches with `-SortlyUITestCreateOnly` add that many photos and end the
    ///    app when they are done, writing how far they are into a file of the runner's.
    /// 2. Measuring: a fresh launch sets the database aside (-SortlyUITestRebuildDatabase) and
    ///    analyses everything from the start, originals only in iCloud and no network. Printed:
    ///    speed per step, Pause and Fortsetzen reaction, the longest time the progress line
    ///    stood still, the slowest answer of the app (one snapshot). The workflow samples the
    ///    app's memory on the Mac and prints crash reports and why iOS ended the app.
    func test12_StressManyPhotosICloudOnlyOffline() throws {
        guard let count = ProcessInfo.processInfo.environment["SORTLY_STRESS_PHOTOS"].flatMap({ Int($0) }), count > 0 else {
            throw XCTSkip("Stress run only (SORTLY_STRESS_PHOTOS)")
        }
        continueAfterFailure = true
        prepare()
        func elapsed(_ since: Date) -> Int { Int(Date().timeIntervalSince(since)) }

        // 1. Creating. The app writes how far it is into a file of ours, then `done`, and ends
        // itself; a launch that ended early (iOS ended it) is followed by another one that adds
        // the rest. Stress run 43833158673 waited 3 h on `app.state` for an app that had ended
        // after about 33 min, so the file comes first.
        let marker = NSTemporaryDirectory() + "stress-create.txt"
        let began = Date()
        var rounds = 0
        var complete = false
        while !complete && rounds < 4 && Date().timeIntervalSince(began) < 90 * 60 {
            rounds += 1
            let round = Date()
            try? FileManager.default.removeItem(atPath: marker)
            start(["-SortlyUITestLargeLibrary", "\(count)", "-SortlyUITestCreateOnly", "-SortlyUITestCreateMarker", marker])
            print("UI_STRESS_PHASE create round \(rounds)")
            var said = ""
            var reachable = true
            while Date().timeIntervalSince(round) < 90 * 60 {
                let line = ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if line != said {
                    print("UI_TIMING stress create round \(rounds) at \(elapsed(round)) s: \(line)")
                    said = line
                }
                if line.hasPrefix("done") { complete = true; break }
                if line.hasPrefix("stopped") { break }
                if reachable, line.isEmpty, elapsed(round) > 120 {
                    reachable = false
                    print("UI_FACT stress create: no word from the app in our file after 120 s, watching the app state only")
                }
                if app.state == .notRunning { break }
                sleep(5)
            }
            print("UI_TIMING stress create round \(rounds): \(elapsed(round)) s, last word '\(said)'")
            if app.state != .notRunning, !app.wait(for: .notRunning, timeout: 30) { app.terminate() }
        }
        print("UI_TIMING stress create \(elapsed(began)) s in \(rounds) launches (done: \(complete))")
        XCTAssertTrue(complete, "Creating \(count) photos did not finish")
        XCTAssertEqual(rounds, 1, "Creating the photos needed \(rounds) launches (the app ended before it was done)")

        // 2. Measuring
        try? FileManager.default.removeItem(atPath: mainStalls)
        print("UI_STRESS_PHASE measure")
        // The image step runs at about 1.7 photos/s in the simulator (stress run 43833158673):
        // 50,000 photos would take 8 h. The run measures for SORTLY_STRESS_MINUTES (45) and
        // reports how far it got; the simulator's speed is not a device's.
        let minutes = ProcessInfo.processInfo.environment["SORTLY_STRESS_MINUTES"].flatMap { Int($0) } ?? 45
        let arguments = ["-SortlyUITestICloudOnly", "-SortlyUITestOffline", "-SortlyUITestWatchMain",
                         "-SortlyUITestWatchMainLog", mainStalls]
        start(arguments + ["-SortlyUITestRebuildDatabase"])
        let analysisBegan = Date()
        var lastLine = ""
        var lastChange = Date()
        var longestStill: (seconds: Double, line: String) = (0, "")
        var slowestAnswer = 0.0
        var stepCounts: [Int: (first: Int, last: Int, firstAt: Date, lastAt: Date)] = [:]
        var paused = false
        var ended = 0
        var lastReport = Date()
        let finished = waitStable("stress analysis finished", timeout: TimeInterval(minutes * 60), stableChecks: 3) {
            if app.state != .runningForeground {
                ended += 1
                print("UI_FACT stress app ended during the analysis (\(ended)) after \(elapsed(analysisBegan)) s, last line '\(lastLine)'")
                start(arguments + ["-SortlyUITestLaunchAnalysis"])
            }
            let asked = Date()
            let line = progressText() ?? ""
            let answer = Date().timeIntervalSince(asked)
            slowestAnswer = max(slowestAnswer, answer)
            if answer > 10 { print("UI_FACT stress app answered after \(Int(answer)) s at '\(line)'") }
            let now = Date()
            if line != lastLine {
                let still = now.timeIntervalSince(lastChange)
                if !lastLine.isEmpty && still > longestStill.seconds { longestStill = (still, lastLine) }
                if !lastLine.isEmpty && still > 10 { print("UI_FACT stress line stood still \(Int(still)) s: '\(lastLine)'") }
                lastLine = line
                lastChange = now
            }
            if now.timeIntervalSince(lastReport) >= 300 {
                lastReport = now
                print("UI_FACT stress at \(elapsed(analysisBegan)) s: '\(line)'")
            }
            if let progress = analysisCount() {
                if stepCounts[progress.step] == nil {
                    print("UI_TIMING stress step \(progress.step) begins at \(elapsed(analysisBegan)) s (\(progress.done) von \(progress.total))")
                }
                let known = stepCounts[progress.step]
                stepCounts[progress.step] = (known?.first ?? progress.done, progress.done, known?.firstAt ?? now, now)
                // Pause once, a tenth into the image step; then Fortsetzen.
                if !paused, progress.step == 4, progress.total > 0, progress.done >= progress.total / 10 {
                    paused = true
                    measurePauseAndResume()
                    lastChange = Date()
                }
            }
            return analysisIdle
        }
        print("UI_TIMING stress analysis \(elapsed(analysisBegan)) s, app ended \(ended) times")
        for (step, c) in stepCounts.sorted(by: { $0.key < $1.key }) {
            let seconds = c.lastAt.timeIntervalSince(c.firstAt)
            let rate = seconds > 0 ? Double(c.last - c.first) / seconds : 0
            print("UI_TIMING stress step \(step): \(c.last - c.first) in \(Int(seconds)) s (\(String(format: "%.1f", rate))/s)")
        }
        print("UI_TIMING stress longest still line \(Int(longestStill.seconds)) s: '\(longestStill.line)'")
        print("UI_TIMING stress slowest answer \(String(format: "%.1f", slowestAnswer)) s")
        print("UI_FACT stress result \(String(describing: analysedPhotos()))")
        shot("26-stress-done")
        if !finished { print("UI_FACT stress measured \(minutes) min; the analysis was not finished then (simulator speed)") }
        XCTAssertEqual(ended, 0, "The app ended during the analysis")
        XCTAssertLessThanOrEqual(longestStill.seconds, 10, "The progress line stood still \(Int(longestStill.seconds)) s at '\(longestStill.line)'")
        XCTAssertLessThan(slowestAnswer, 10, "The app took \(Int(slowestAnswer)) s to answer")
        let opened = Date()
        tabButton("Mediathek").tap()
        let listed = libraryPhotos.firstMatch.waitForExistence(timeout: 60)
        print("UI_TIMING stress library tab \(String(format: "%.1f", Date().timeIntervalSince(opened))) s (\(listed))")
        shot("27-stress-library")
    }

    /// The app's main-thread stalls over 0.5 s ("<end, s since 1970> <ms>"), written by the
    /// app (-SortlyUITestWatchMainLog) into this file of ours.
    private var mainStalls: String { NSTemporaryDirectory() + "stress-main-stalls.txt" }

    /// Stalls of the main thread that overlap `from…to`: nil when the app's file cannot be read.
    private func mainStallsOverlapping(_ from: Date, _ to: Date) -> [(end: Date, ms: Int)]? {
        guard let text = try? String(contentsOfFile: mainStalls, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { line -> (end: Date, ms: Int)? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let end = Double(parts[0]), let ms = Int(parts[1]) else { return nil }
            let stall = (end: Date(timeIntervalSince1970: end), ms: ms)
            let start = stall.end.addingTimeInterval(-Double(ms) / 1000)
            return start <= to && stall.end >= from ? stall : nil
        }
    }

    /// Pause during the image step. The card must react to the tap at once ("Wird angehalten"
    /// or "Analyse pausiert" in the first look after the tap: XCTest's tap returns once the app
    /// took the touch, and Pause changes the card in that same call). Then the photos in work
    /// are finished (one per lane) and Fortsetzen appears, within the 10 s after which the card
    /// says "Dauert noch einen Moment". Stress run 43833158673 looked for a button labelled
    /// "Fortsetzen", but its label is "Analyse fortsetzen": found by its identifier now.
    private func measurePauseAndResume() {
        let pause = app.buttons["analysis.pause"]
        guard pause.waitForExistence(timeout: 5) else { print("UI_STEP_MISSING stress pause"); return }
        let before = analysisCount()?.done ?? 0
        let tapStarted = Date()
        pause.tap()
        let tapped = Date()
        let resume = app.buttons["analysis.resume"]
        var firstLook: (line: String, took: Double)?
        var reacted: Double?
        var resumeShown: Double?
        var last = before
        var lastMove = tapped
        while Date().timeIntervalSince(tapped) < 60 {
            let looked = Date()
            let line = progressText() ?? ""
            if firstLook == nil { firstLook = (line, Date().timeIntervalSince(looked)) }
            if reacted == nil, line.hasPrefix("Wird angehalten") || line.hasPrefix("Analyse pausiert") {
                reacted = looked.timeIntervalSince(tapped)
            }
            if resumeShown == nil, resume.exists { resumeShown = Date().timeIntervalSince(tapped) }
            let now = analysisCount()?.done ?? last
            if now != last { last = now; lastMove = Date() }
            if resumeShown != nil && Date().timeIntervalSince(lastMove) > 5 { break }
            usleep(100_000)
        }
        let stopped = max(0, lastMove.timeIntervalSince(tapped))
        func s(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "never" }
        print("UI_TIMING stress pause: tap \(s(tapped.timeIntervalSince(tapStarted))) s, first look '\(firstLook?.line ?? "")' (took \(s(firstLook?.took)) s), reacted \(s(reacted)) s, Fortsetzen \(s(resumeShown)) s, counting stopped \(s(stopped)) s (\(last - before) more photos)")
        let firstShows = firstLook.map { $0.line.hasPrefix("Wird angehalten") || $0.line.hasPrefix("Analyse pausiert") } ?? false
        XCTAssertTrue(firstShows, "The first look after Pause still read '\(firstLook?.line ?? "")'")
        // Pause under 1 s: the app's main thread (which changes the card in the tap's own call)
        // was not held for 1 s or more from the start of the tap until 1 s after it. XCTest's
        // tap itself also waits for the app to settle (7.15 s in stress run 43833158673); only
        // when the app's stall file cannot be read is that time the measure.
        if let stalls = mainStallsOverlapping(tapStarted, tapped.addingTimeInterval(1)) {
            print("UI_TIMING stress pause: main-thread stalls around the tap \(stalls.map { "\($0.ms) ms" })")
            XCTAssertTrue(stalls.allSatisfy { $0.ms < 1000 }, "The main thread was held \(stalls.map(\.ms).max() ?? 0) ms around the Pause tap")
        } else {
            print("UI_FACT stress pause: the app's stall file cannot be read; the tap's own time is the measure")
            XCTAssertLessThan(tapped.timeIntervalSince(tapStarted), 1, "The Pause tap took \(s(tapped.timeIntervalSince(tapStarted))) s")
        }
        XCTAssertLessThan(resumeShown ?? 99, 10, "Fortsetzen came \(s(resumeShown)) s after Pause")
        XCTAssertLessThanOrEqual(stopped, (resumeShown ?? 0) + 0.5, "The count went on after the analysis showed it was paused")
        shot("26a-stress-paused")
        guard resumeShown != nil else { print("UI_STEP_MISSING stress continue"); return }
        let resumed = Date()
        resume.tap()
        let moves = waitStable("stress count moves after Fortsetzen", timeout: 120, stableChecks: 1) { (analysisCount()?.done ?? last) != last }
        print("UI_TIMING stress continue moves \(String(format: "%.1f", Date().timeIntervalSince(resumed))) s (\(moves))")
        XCTAssertTrue(moves, "The analysis did not go on after Fortsetzen")
    }
}
