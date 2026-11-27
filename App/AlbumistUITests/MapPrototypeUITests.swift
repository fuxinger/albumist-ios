import XCTest
import UIKit

/// The hidden map prototype page (concept 2.0 §13, wave 0) on the analysed demo library: the
/// atlas shows its entry in UI runs that ask for it (`-AlbumistUITestMapPrototype`), the page
/// opens with its HUD, and each of its three views draws, measures and runs its test (10 s
/// instead of 60 s in UI runs, so the test sees a test end and its result).
///
/// Only the page's own elements fail the test: its bar, tabs, HUD, buttons and notes. Apple's
/// maps need map tiles from the network, which a CI simulator may not get, and the globe, the
/// maps and the playback come from other parts of the prototype: their frames, the handover and
/// the playback's own buttons are reported as `UI_STEP_OK` / `UI_STEP_MISSING` lines only. The
/// HUD's numbers are printed as `UI_FACT`, screenshots as `PREVIEW_JPEG ui-p…` chunks.
@MainActor
final class MapPrototypeUITests: XCTestCase {
    private var app = XCUIApplication()
    private var stallsReportedAtEnd = false
    /// The fast start (onboarding done, the demo library created and analysed) and the entry.
    private let extra = ["-AlbumistUITestFastStart", "-AlbumistUITestMapPrototype"]

    // MARK: Helpers (as in SearchUITests)

    private func launch() {
        // The app's stalls since the last launch; the app itself is ended in UITestAppEnd.launch.
        UITestStalls.report()
        if !stallsReportedAtEnd {
            stallsReportedAtEnd = true
            addTeardownBlock { UITestStalls.report() }
        }
        app = XCUIApplication()
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked"]
            + UITestStalls.arguments(besides: extra) + extra
        UITestAppEnd.launch(app)
    }

    func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// One of the page's own elements, by its accessibility identifier ("proto.…").
    func page(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A segment of the page's choice of the view.
    private func segment(_ title: String) -> XCUIElement {
        app.segmentedControls.buttons[title]
    }

    /// A tab bar button: the one shared helper brings a bar that scrolled away back.
    private func tabButton(_ name: String) -> XCUIElement {
        UITestScreens.tabButton(app, name)
    }

    @discardableResult
    func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
            XCTFail("Missing: \(step)")
            return false
        }
        // Into view first (as in AlbumistFlowUITests): content under the navigation bar counts
        // as hittable, but a tap there lands on the bar; content below the screen is scrolled up.
        let bar = app.navigationBars.firstMatch
        var swipes = 0
        while swipes < 8 {
            if UITestWait.underNavigationBar(element, bar) { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        UITestOnboarding.clock("tap \(step)")
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
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
            print("PREVIEW_JPEG ui-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        // Taps the alert's button when it is there; the trial step means it was not needed.
        _ = UITestWait.holds(timeout: 25) {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    return true
                }
            }
            return button("Analyse starten").exists
        }
    }

    // MARK: Reading the page

    /// The HUD's lines (its accessibility value), from one snapshot: they change twice a second.
    private func hud() -> String {
        guard let snapshot = try? page("proto.hud").snapshot() else { return "" }
        return (snapshot.value as? String) ?? ""
    }

    /// The frames the HUD counts for the view shown ("· 1.234 Bilder"); 0 when it counts none.
    private func framesInHUD() -> Int {
        let value = hud()
        guard let range = value.range(of: "[0-9.]+ Bilder", options: .regularExpression) else { return 0 }
        return Int(value[range].filter(\.isNumber)) ?? 0
    }

    /// The label of one of the page's texts, from one snapshot ("" when it is not there).
    private func text(_ identifier: String) -> String {
        (try? page(identifier).snapshot())?.label ?? ""
    }

    private func reportHUD(_ step: String) {
        print("UI_FACT map prototype \(step): \(hud())")
    }

    /// Waits for what the page shows but another part of the prototype makes (a globe's frames,
    /// Apple's map, the playback's buttons): reported either way, never a failure.
    @discardableResult
    private func soft(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let start = Date()
        let met = UITestWait.holds(timeout: timeout, condition)
        let took = String(format: "%.1f", Date().timeIntervalSince(start))
        print(met ? "UI_STEP_OK \(what) (\(took) s)" : "UI_STEP_MISSING \(what) (not within \(Int(timeout)) s; reported only)")
        return met
    }

    // MARK: Setup

    /// The analysed demo library. The fast start creates and analyses it by itself; a simulator
    /// without photo access gets it granted first, and `UITestOnboarding.completeIfNeeded` does
    /// the onboarding on a fresh one, a demo library still offered or an analysis cut off.
    private func prepareLibrary() {
        launch()
        _ = UITestWait.holds(timeout: 15) {
            app.tabBars.firstMatch.exists || app.buttons["access.continue"].exists || button("Los geht").exists
        }
        if app.buttons["access.continue"].exists {
            // Photo access is not granted (the CI grant did not hold): granted, then opened once
            // more so the fast start runs as with access (as `prepare` in AlbumistFlowUITests).
            app.buttons["access.continue"].tap()
            allowPhotosIfAsked()
            launch()
            _ = UITestWait.holds(timeout: 15) { app.tabBars.firstMatch.exists || button("Los geht").exists }
        }
        if !button("Los geht").exists {
            if app.tabBars.buttons[UITestScreens.Tabs.german.suggestions].exists { tabButton(UITestScreens.Tabs.german.suggestions).tap() }
            analysisSettled()
        }
        UITestOnboarding.completeIfNeeded(app, in: "map prototype")
    }

    /// The overview is idle on three checks in a row, 2 s apart: the demo library is created and
    /// analysed. "Beispiel-Mediathek anlegen" is tapped when the overview still offers it in the
    /// first seconds (as `prepare` in AlbumistFlowUITests).
    private func analysisSettled() {
        let demo = button("Beispiel-Mediathek anlegen")
        let seeding = anything("Beispielfotos werden angelegt")
        let offerUntil = Date().addingTimeInterval(3)
        var offered = false
        var streak = 0
        let settled = UITestWait.holds(timeout: 900, interval: 2) {
            if !offered, Date() < offerUntil, demo.exists, !seeding.exists {
                offered = true
                demo.tap()
                return false
            }
            let idle = UITestOnboarding.analysisIdle(app) && !seeding.exists && !demo.exists
            streak = idle ? streak + 1 : 0
            return streak >= 3
        }
        print(settled ? "UI_STEP_OK map prototype demo library analysed" : "UI_STEP_MISSING map prototype demo library analysed (timeout 900 s)")
        XCTAssertTrue(settled, "The demo library was not created and analysed")
    }

    // MARK: Test

    func testMapPrototypePage() {
        continueAfterFailure = true
        prepareLibrary()

        // The atlas shows the entry: debug and TestFlight builds, UI runs only when they ask.
        if app.tabBars.buttons[UITestScreens.Tabs.german.suggestions].exists { tabButton(UITestScreens.Tabs.german.suggestions).tap() }
        guard tap(button("Reise-Atlas"), "open atlas", timeout: 30) else { return }
        UITestWait.appears(app.navigationBars["Reise-Atlas"], "atlas screen", timeout: 30)
        guard tap(page("atlas.map"), "open map") else { return }
        guard UITestWait.appears(page("worldmap.all"), "map for laypeople", timeout: 30) else { return }
        worldMap()
        guard tap(page("worldmap.more"), "map menu") else { return }
        guard tap(page("worldmap.measure"), "open measuring page") else { return }
        guard UITestWait.appears(page("proto.hud"), "map prototype page with its HUD", timeout: 20) else { return }

        ownGlobe()
        appleGlobe()
        playback()
        cameraProbe()
        tools()
        ownTrips()

        tap(page("proto.close"), "close map prototype")
        UITestWait.disappears(page("proto.hud"), "map prototype closed", timeout: 15)
        UITestWait.appears(page("worldmap.all"), "back on the map", timeout: 15)
        tap(page("worldmap.close"), "close map")
        UITestWait.appears(app.navigationBars["Reise-Atlas"], "back on the atlas", timeout: 15)
    }

    /// 1. Our globe with the demo load (150 arcs, 60 pins), then the flight through the handover.
    private func ownGlobe() {
        UITestWait.until("HUD shows Unser Globus", timeout: 10) { hud().hasPrefix("Unser Globus") }
        // About 1.5 to 3 s of drawing (120 or 60 frames a second) before the picture.
        soft("own globe draws 180 frames", timeout: 15) { framesInHUD() >= 180 }
        reportHUD("own globe")
        shot("p1-own-globe")
        // 6,000 to 2,500 km over Iceland in 3 s: Apple's map takes over, shown once it has
        // rendered, at the latest 5 s after the handover.
        tap(page("proto.handover"), "fly through the handover")
        let handedOver = soft("Apple's map after the handover", timeout: 15) { hud().hasPrefix("Apples Karte") }
        reportHUD("handover")
        if handedOver { shot("p1b-handover") }
    }

    /// 2. Apple's satellite globe: the HUD follows the view; a test starts and is cancelled.
    private func appleGlobe() {
        tap(segment("Apples Globus"), "tab Apples Globus")
        UITestWait.until("HUD shows Apples Globus", timeout: 10) { hud().hasPrefix("Apples Globus") }
        soft("Apple's globe counts 120 frames", timeout: 15) { framesInHUD() >= 120 }
        reportHUD("apple globe")
        shot("p2-apple-globe")
        tap(page("proto.test"), "start test on Apple's globe")
        UITestWait.appears(page("proto.testCancel"), "test countdown", timeout: 10)
        print("UI_FACT map prototype countdown: \(text("proto.testCancel"))")
        tap(page("proto.testCancel"), "cancel test")
        UITestWait.appears(page("proto.test"), "test button after cancelling", timeout: 10)
    }

    /// 3. "Reise abspielen": the test plays the demo trip from its start, the playback pauses,
    /// and the test ends by itself with its result.
    private func playback() {
        tap(segment("Reise abspielen"), "tab Reise abspielen")
        UITestWait.until("HUD shows Reise abspielen", timeout: 10) { hud().hasPrefix("Reise abspielen") }
        tap(page("proto.test"), "start test on the playback")
        let countdown = page("proto.testCancel")
        UITestWait.appears(countdown, "playback test countdown", timeout: 10)
        let pause = app.buttons["Pause"]
        soft("playback plays (its Pause button)", timeout: 15) { pause.exists }
        reportHUD("playback")
        shot("p3-playback")
        if pause.exists {
            pause.tap()
            let paused = soft("playback paused (its Weiter button)", timeout: 10) { app.buttons["Weiter"].exists }
            reportHUD("playback paused")
            if paused { shot("p4-after-pause") }
        }
        let result = page("proto.testResult")
        UITestWait.until("playback test result", timeout: 40) { !countdown.exists && result.exists }
        print("UI_FACT map prototype playback result: \(text("proto.testResult"))")
    }

    /// 4. The measurements to the clipboard, and the photos' altitudes (counts only).
    private func tools() {
        tap(page("proto.copy"), "copy measurements")
        UITestWait.until("measurements copied", timeout: 10) { text("proto.toolNote").hasPrefix("Messwerte kopiert") }
        print("UI_FACT map prototype copy: \(text("proto.toolNote"))")
        tap(page("proto.altitudes"), "check altitudes")
        UITestWait.until("altitudes checked", timeout: 60) {
            let note = text("proto.toolNote")
            return note.hasPrefix("Höhen:") || note.hasPrefix("Ohne Zugriff")
        }
        print("UI_FACT map prototype altitudes: \(text("proto.toolNote"))")
    }

    /// 5. The user's own trips (the demo library's): summarised and drawn on our globe.
    private func ownTrips() {
        tap(segment("Unser Globus"), "tab Unser Globus")
        UITestWait.until("HUD shows Unser Globus again", timeout: 10) { hud().hasPrefix("Unser Globus") }
        tap(app.buttons["Deine Reisen"], "data: own trips")
        // "12 Reisen, 12 Bögen, 30 Stecknadeln · Zusammenfassung in 85 ms", or the calm note
        // that keeps the demo when the analysis stored no trip.
        UITestWait.until("own trips summarised", timeout: 60) { text("proto.dataNote").contains("Reisen") }
        print("UI_FACT map prototype own trips: \(text("proto.dataNote"))")
        let before = framesInHUD()
        soft("own globe draws the own trips (60 more frames)", timeout: 15) { framesInHUD() >= before + 60 }
        reportHUD("own trips")
        shot("p5-own-trips")
    }
}

// The camera probe's step, here and not in the class body, which keeps within SwiftLint's
// type_body_length; an extension in the same file sees the class's private helpers.
extension MapPrototypeUITests {
    /// 3b. The camera probe over Apple's map: its flight in real time and what it measured, then
    /// its seventeen steps, five of the still cameras with what MapKit made of them and when the
    /// map was ready, each with a screenshot. Map tiles may not come to a CI simulator, so the
    /// map's readiness and the flight's numbers are reported only; the probe's own plate and
    /// buttons must be there.
    private func cameraProbe() {
        guard tap(page("proto.cameraProbe"), "open camera probe") else { return }
        guard UITestWait.appears(page("probe.title"), "camera probe plate", timeout: 15) else { return }
        let count = 17
        // 1: the flight, in real time (10.4 s) once its first map stands or the wait is over.
        UITestWait.until("camera probe shows the flight", timeout: 10) { text("probe.title").hasPrefix("1 von \(count)") }
        soft("camera probe flight: flying", timeout: 20) { text("probe.got").hasPrefix("Flug:") || page("probe.fly").exists }
        shot("p3b-probe-flight")
        soft("camera probe flight: landed and measured", timeout: 45) { page("probe.fly").exists }
        probeFacts(1)
        // The still cameras: a low hold, the middle of the flight, the highest, the steepest tilt
        // at 160 km and Rome from 300 m are waited for and shown; the others are passed.
        for number in 2...count {
            tap(page("probe.next"), "camera probe next")
            UITestWait.until("camera probe shows camera \(number)", timeout: 10) { text("probe.title").hasPrefix("\(number) von \(count)") }
            guard [2, 7, 10, 15, 16].contains(number) else { continue }
            soft("camera probe \(number): map rendered or the wait over", timeout: 20) { !text("probe.state").hasPrefix("Karte lädt") }
            probeFacts(number)
        }
        tap(page("probe.copy"), "copy camera probe")
        UITestWait.until("camera probe copied", timeout: 10) { page("probe.copy").label == "Kopiert" }
        tap(page("probe.close"), "close camera probe")
        UITestWait.disappears(page("probe.title"), "camera probe closed", timeout: 15)
        UITestWait.appears(page("proto.cameraProbe"), "playback tab after the probe", timeout: 15)
    }

    /// The probe's plate as a `UI_FACT` line, and a screenshot.
    private func probeFacts(_ number: Int) {
        let facts = [text("probe.title"), text("probe.asked"), text("probe.got"), text("probe.state")]
        print("UI_FACT map prototype camera probe \(number): " + facts.joined(separator: " | "))
        shot("p3b-probe-\(number)")
    }
}
