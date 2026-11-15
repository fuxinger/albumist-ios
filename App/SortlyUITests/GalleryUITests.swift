import XCTest
import UIKit

/// Screenshot gallery of every screen in every variant (workflow "Screenshot gallery",
/// `.github/workflows/gallery.yml`). Not a check of the app: a screen that cannot be reached
/// is listed as `GALLERY_MISSING` and in the gallery's index, the walk goes on. Only a
/// broken setup (no demo library, analysis never finishes) fails the run.
///
/// One simulator per device size runs all variants in a row, switched by launch arguments:
/// light and dark (`-SortlyUITestDark` plus the simulator appearance), the default text size
/// and the largest accessibility size (`-UIPreferredContentSizeCategoryName`), German and,
/// for light at the default size, English (`-AppleLanguages`).
///
/// Screenshots are XCTest attachments named `<device>_<lang>_<appearance>_<size>_<NN-screen>`;
/// the workflow exports them from the result bundle. The numbers are fixed per screen, so the
/// same screen lines up across variants and devices.
@MainActor
final class GalleryUITests: XCTestCase {
    private struct Variant {
        var lang: String
        var dark: Bool
        var largeText: Bool
        var english: Bool { lang == "en" }
        var tag: String { "\(lang)_\(dark ? "dark" : "light")_\(largeText ? "AX5" : "default")" }
    }

    private var app = XCUIApplication()
    private var variant = Variant(lang: "de", dark: false, largeText: false)
    private var taken: [String] = []
    private var missed: [String] = []

    /// "iPhone 18 Pro Max" → "iPhone18ProMax": the simulator's name, set by the workflow.
    private static let device: String = {
        let raw = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "iPhone"
        return raw.filter { $0.isLetter || $0.isNumber }
    }()

    // MARK: Tests (run in this order on one simulator)

    /// Onboarding, photo access and the demo library with its first analysis, which every
    /// variant below uses.
    func test0_SetupDemoLibrary() {
        continueAfterFailure = true
        variant = Variant(lang: "de", dark: false, largeText: false)
        XCUIDevice.shared.appearance = .light
        launch()
        if button("Los geht").waitForExistence(timeout: 30) {
            tap(button("Los geht"), "welcome")
            tap(button("Weiter"), "areas")
            if app.buttons["access.continue"].waitForExistence(timeout: 5) {
                app.buttons["access.continue"].tap()
                allowPhotosIfAsked()
            }
            if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
            XCTAssertTrue(button("Analyse starten").waitForExistence(timeout: 20), "Onboarding did not reach the start step")
            tap(button("Analyse starten"), "start analysis")
            allowNotificationsIfAsked()
        } else {
            print("GALLERY_NOTE onboarding already done on this simulator")
        }
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            sleep(2)
            shot("00-overview-empty")
            demo.tap()
            let seeded = waitStable("demo library created", timeout: 900) {
                !anything("Beispielfotos werden angelegt").exists && !button("Beispiel-Mediathek anlegen").exists
            }
            XCTAssertTrue(seeded, "Demo library not created")
        }
        XCTAssertTrue(waitStable("analysis finished", timeout: 1500) { analysisIdle }, "Analysis did not finish")
        summary()
    }

    func test1_GermanLightDefault() { walk(Variant(lang: "de", dark: false, largeText: false)) }
    func test2_GermanDarkDefault() { walk(Variant(lang: "de", dark: true, largeText: false)) }
    func test3_GermanLightLargestText() { walk(Variant(lang: "de", dark: false, largeText: true)) }
    func test4_GermanDarkLargestText() { walk(Variant(lang: "de", dark: true, largeText: true)) }
    func test5_EnglishLightDefault() { walk(Variant(lang: "en", dark: false, largeText: false)) }

    // MARK: Walk

    private func walk(_ v: Variant) {
        continueAfterFailure = true
        variant = v
        taken = []
        missed = []
        XCUIDevice.shared.appearance = v.dark ? .dark : .light
        defer {
            XCUIDevice.shared.appearance = .light
            summary()
        }
        onboarding()
        overviewAndSuggestions()
        tripsAndPlan()
        lockedPlan()
        atlas()
        libraryAndAlbums()
        search()
        settingsAndRebuild()
        noPhotoAccess()
    }

    /// 01–04: the introduction, shown again by overriding its stored flag for this launch.
    private func onboarding() {
        launch(["-onboarding.done", "NO"])
        let go = button(t("Los geht", "Let"))
        guard go.waitForExistence(timeout: 30) else {
            miss(["01-onboarding-welcome", "02-onboarding-areas", "03-onboarding-access", "04-onboarding-start"], "introduction did not appear")
            return
        }
        shot("01-onboarding-welcome")
        guard tap(go, "welcome") else { return }
        shot("02-onboarding-areas")
        guard tap(button(t("Weiter", "Continue")), "areas") else { return }
        shot("03-onboarding-access")
        // Access is granted, so "Weiter" goes straight to the last step.
        guard tap(button(t("Weiter", "Continue")), "access") else { return }
        if button(t("Analyse starten", "Start analysis")).waitForExistence(timeout: 10) {
            shot("04-onboarding-start")
        } else {
            miss(["04-onboarding-start"], "start step did not appear")
        }
        app.terminate()
    }

    /// 05–11: overview, suggestions, one suggestion, "Anpassen", its photos and the viewer.
    private func overviewAndSuggestions() {
        startMain()
        shot("05-overview-idle")
        app.swipeUp(); app.swipeUp()
        shot("06-overview-lower")
        app.swipeDown(); app.swipeDown(); app.swipeDown()

        guard tap(button(t("Vorschläge prüfen", "Review")), "open suggestions", timeout: 20) else {
            miss(["07-suggestions", "08-suggestion-detail", "09-suggestion-adjust", "10-suggestion-photos", "11-photo-viewer"], "no suggestions button")
            return
        }
        sleep(1)
        shot("07-suggestions")
        let row = suggestionRow(0)
        scrollTo(row)
        guard tap(row, "open suggestion") else {
            miss(["08-suggestion-detail", "09-suggestion-adjust", "10-suggestion-photos", "11-photo-viewer"], "no suggestion row")
            back()
            return
        }
        _ = app.navigationBars[t("Vorschlag", "Suggestion")].waitForExistence(timeout: 5)
        shot("08-suggestion-detail")
        if tap(app.buttons[t("Anpassen", "Adjust")], "adjust") {
            sleep(1)
            shot("09-suggestion-adjust")
            tap(app.buttons[t("Abbrechen", "Cancel")], "close adjust")
            sleep(1)
        } else {
            miss(["09-suggestion-adjust"], "no adjust button")
        }
        app.swipeDown(); app.swipeDown()
        if tap(button(t("Fotos ansehen", "See ")), "all photos of the suggestion") {
            sleep(2)
            shot("10-suggestion-photos")
            let tile = app.scrollViews.firstMatch.buttons.firstMatch
            if tap(tile, "open photo viewer") {
                sleep(2)
                shot("11-photo-viewer")
                tap(app.buttons["viewer.close"], "close viewer")
                sleep(1)
            } else {
                miss(["11-photo-viewer"], "no photo tile")
            }
            back(); sleep(1)
        } else {
            miss(["10-suggestion-photos", "11-photo-viewer"], "no photos link")
        }
        back(); sleep(1)
        back(); sleep(1)
    }

    /// 12–19: the trips, the trip workshop with a split preview (not applied), one trip as a
    /// plan, the sorting show, the result and the change receipt. One album is created per
    /// variant; the demo library has a dozen trips.
    private func tripsAndPlan() {
        startMain()
        guard openTrips() else {
            miss(["12-trips", "13-trip-workshop", "14-trip-split-preview", "15-plan", "16-plan-lower", "17-sorting-show", "18-plan-result", "19-receipt"], "no trips area")
            return
        }
        shot("12-trips")

        let iceland = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Island", "Iceland")).element(boundBy: 0)
        scrollTo(iceland)
        if tap(iceland, "open Iceland trip"), tap(app.buttons["proposal.reshapeTrip"], "open trip workshop", timeout: 8) {
            sleep(2)
            shot("13-trip-workshop")
            let days = app.buttons.matching(identifier: "workshop.day")
            let day = days.element(boundBy: max(0, min(4, days.count - 1)))
            if tap(day, "choose split day", timeout: 5) {
                sleep(1)
                shot("14-trip-split-preview")
            } else {
                miss(["14-trip-split-preview"], "no day to split at")
            }
            tap(app.buttons[t("Schließen", "Close")].firstMatch, "close workshop")
            sleep(2)
            if !app.navigationBars[t("Reisen", "Trips")].exists { back(); sleep(1) }
        } else {
            miss(["13-trip-workshop", "14-trip-split-preview"], "workshop not reached")
            if !app.navigationBars[t("Reisen", "Trips")].exists { back(); sleep(1) }
        }

        guard openPlanFromTrips() else {
            miss(["15-plan", "16-plan-lower", "17-sorting-show", "18-plan-result", "19-receipt"], "no trip with \"Album anlegen\"")
            return
        }
        sleep(2)
        shot("15-plan")
        app.swipeUp(); app.swipeUp()
        shot("16-plan-lower")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        guard tap(button(t("Jetzt umsetzen", "Apply now")), "apply plan", timeout: 30) else {
            miss(["17-sorting-show", "18-plan-result", "19-receipt"], "no apply button")
            return
        }
        // One album: the show lasts about 2 s.
        usleep(500_000)
        shot("17-sorting-show", settle: false)
        guard button(t("Rückgängig machen", "Undo")).waitForExistence(timeout: 300) else {
            miss(["18-plan-result", "19-receipt"], "plan did not finish")
            return
        }
        sleep(1)
        shot("18-plan-result")
        let receipt = app.buttons["result.receipt"]
        if tap(receipt, "open receipt") {
            sleep(2)
            shot("19-receipt")
        } else {
            miss(["19-receipt"], "no receipt button")
        }
    }

    /// 20: the plan with no free album left: the unlock card instead of "Jetzt umsetzen".
    private func lockedPlan() {
        startMain(["-SortlyUITestLocked", "-SortlyUITestFreeAlbumsLeft", "0"])
        guard openTrips(), openPlanFromTrips() else {
            miss(["20-plan-locked"], "no plan in the locked run")
            return
        }
        let unlock = app.staticTexts[t("Albumist freischalten", "Unlock Albumist")]
        if !unlock.waitForExistence(timeout: 15) { print("GALLERY_NOTE \(name("20-plan-locked")) without unlock card") }
        sleep(1)
        shot("20-plan-locked")
    }

    /// 21–24: the travel atlas, its lower half, one country and the share image.
    private func atlas() {
        startMain()
        guard tap(button(t("Reise-Atlas", "Travel Atlas")), "open atlas", timeout: 20) else {
            miss(["21-atlas", "22-atlas-lower", "23-country-photos", "24-atlas-share"], "no atlas teaser")
            return
        }
        sleep(6)
        shot("21-atlas")
        app.swipeUp(); app.swipeUp()
        shot("22-atlas-lower")
        let country = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", t("Italien", "Italy"))).firstMatch
        if tap(country, "open country") {
            sleep(2)
            shot("23-country-photos")
            back(); sleep(1)
        } else {
            miss(["23-country-photos"], "no country row")
        }
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        if tap(app.buttons[t("Reise-Atlas teilen", "Share Travel Atlas")], "share atlas") {
            sleep(3)
            shot("24-atlas-share")
            tap(button(t("Fertig", "Done")), "close share image")
            sleep(2)
        } else {
            miss(["24-atlas-share"], "no share button")
        }
    }

    /// 25–28: library (inbox) with one photo's details, albums with one album.
    private func libraryAndAlbums() {
        startMain()
        if tap(tabButton(t("Mediathek", "Library")), "library tab") {
            sleep(2)
            shot("25-library")
            let photo = yearButton()
            if !photo.waitForExistence(timeout: 3) { tap(button(t("Sortiert", "Sorted")), "sorted photos"); sleep(2) }
            if tap(photo, "open photo") {
                sleep(2)
                shot("26-library-photo")
                tap(button(t("Fertig", "Done")), "close photo")
                sleep(1)
            } else {
                miss(["26-library-photo"], "no photo in the library")
            }
        } else {
            miss(["25-library", "26-library-photo"], "no library tab")
        }
        if tap(tabButton(t("Alben", "Albums")), "albums tab") {
            sleep(2)
            shot("27-albums")
            let album = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", t("Fotos", "hoto"))).element(boundBy: 0)
            scrollTo(album)
            if tap(album, "open album") {
                sleep(2)
                shot("28-album-detail")
                back(); sleep(1)
            } else {
                miss(["28-album-detail"], "no album row")
            }
        } else {
            miss(["27-albums", "28-album-detail"], "no albums tab")
        }
    }

    /// 29–31: search before typing, with results, without results.
    private func search() {
        guard tap(searchTabButton(), "search tab") else {
            miss(["29-search-empty", "30-search-results", "31-search-no-results"], "no search tab")
            return
        }
        sleep(2)
        shot("29-search-empty")
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 5) else {
            miss(["30-search-results", "31-search-no-results"], "no search field")
            return
        }
        field.tap()
        field.typeText(t("Rom", "Rome") + "\n")
        sleep(3)
        shot("30-search-results")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "Qwxyzv\n")
        sleep(3)
        shot("31-search-no-results")
    }

    /// 32–38: settings, albums made by Albumist, history, privacy, the diagnostic share sheet,
    /// then "Analyse neu aufbauen" for the overview while the analysis runs and once it is done.
    private func settingsAndRebuild() {
        startMain()
        guard openSettings() else {
            miss(["32-settings", "33-managed-albums", "34-settings-history", "35-privacy", "36-diagnostics-share", "37-overview-running", "38-overview-finished"], "no settings button")
            return
        }
        shot("32-settings")
        let managed = button(t("Von Albumist angelegt", "Created by Albumist"))
        if tap(managed, "managed albums") {
            sleep(2)
            shot("33-managed-albums")
            back(); sleep(1)
        } else {
            miss(["33-managed-albums"], "no managed albums row")
        }
        let history = app.buttons["history.row"].firstMatch
        scrollList(to: history)
        if history.exists {
            shot("34-settings-history")
        } else {
            miss(["34-settings-history"], "no history row")
        }
        let privacy = app.buttons[t("Datenschutz", "Privacy")]
        scrollList(to: privacy)
        if tap(privacy, "privacy") {
            sleep(1)
            shot("35-privacy")
            back(); sleep(1)
        } else {
            miss(["35-privacy"], "no privacy row")
        }
        let diagnostics = app.descendants(matching: .any)["diagnostics.share"]
        scrollList(to: diagnostics)
        if tap(diagnostics, "share diagnostics") {
            sleep(4)
            shot("36-diagnostics-share")
            closeShareSheet()
        } else {
            miss(["36-diagnostics-share"], "no diagnostics row")
        }

        let rebuild = app.buttons[t("Analyse neu aufbauen", "Rebuild analysis")]
        if !rebuild.exists && !app.navigationBars[t("Einstellungen", "Settings")].exists { _ = openSettings() }
        scrollList(to: rebuild)
        guard tap(rebuild, "rebuild analysis") else {
            miss(["37-overview-running", "38-overview-finished"], "no rebuild button")
            return
        }
        sleep(1)
        let confirm = app.buttons.matching(identifier: t("Neu aufbauen", "Rebuild")).allElementsBoundByIndex.first(where: \.isHittable)
        guard let confirm else {
            miss(["37-overview-running", "38-overview-finished"], "no rebuild confirmation")
            return
        }
        confirm.tap()
        sleep(1)
        if app.buttons[t("Fertig", "Done")].exists { app.buttons[t("Fertig", "Done")].tap() }
        if app.descendants(matching: .any)["analysis.progress"].waitForExistence(timeout: 60) {
            sleep(3)
            shot("37-overview-running")
        } else {
            miss(["37-overview-running"], "analysis progress did not appear")
        }
        if waitStable("analysis finished after rebuild", timeout: 900) { analysisIdle } {
            sleep(1)
            shot("38-overview-finished")
        } else {
            miss(["38-overview-finished"], "analysis did not finish after rebuild")
        }
    }

    /// 39: photo access taken away (reset for this app), then given back through the iOS question.
    private func noPhotoAccess() {
        app.resetAuthorizationStatus(for: .photos)
        launch()
        let next = app.buttons["access.continue"]
        if next.waitForExistence(timeout: 30) {
            sleep(1)
            shot("39-no-photo-access")
            next.tap()
            allowPhotosIfAsked()
        } else {
            miss(["39-no-photo-access"], "no-access screen did not appear")
        }
        let granted = app.tabBars.firstMatch.waitForExistence(timeout: 30)
        print(granted ? "GALLERY_NOTE access granted again" : "GALLERY_NOTE access NOT granted again")
    }

    // MARK: Navigation helpers

    private func t(_ german: String, _ english: String) -> String { variant.english ? english : german }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        var arguments = ["-SortlyUITestUnlocked"]
        arguments += variant.english ? ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] : ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if variant.largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if variant.dark { arguments.append("-SortlyUITestDark") }
        app.launchArguments = arguments + extra
        app.launch()
    }

    /// Launches into the tabs (giving photo access back if a reset left it open) and waits
    /// until the analysis is idle.
    private func startMain(_ extra: [String] = []) {
        launch(extra)
        let tabs = app.tabBars.firstMatch
        if !tabs.waitForExistence(timeout: 30), app.buttons["access.continue"].exists {
            app.buttons["access.continue"].tap()
            allowPhotosIfAsked()
            _ = tabs.waitForExistence(timeout: 30)
        }
        _ = waitStable("analysis idle (\(variant.tag))", timeout: 600) { analysisIdle }
        sleep(1)
    }

    private func openTrips() -> Bool {
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", t("Reisen", "Trips"))).firstMatch
        guard tap(travel, "open trips", timeout: 15) else { return false }
        sleep(2)
        return true
    }

    /// Opens the first trip that makes a new album and taps "Album anlegen": the plan preview.
    private func openPlanFromTrips() -> Bool {
        app.swipeDown(); app.swipeDown()
        for index in 0..<5 {
            let row = suggestionRow(index)
            scrollTo(row)
            guard tap(row, "open trip \(index)", timeout: 8) else { return false }
            sleep(1)
            let create = app.buttons[t("Album anlegen", "Create album")]
            if create.waitForExistence(timeout: 3), tap(create, "create album") {
                return app.navigationBars[t("Umsetzen", "Apply")].waitForExistence(timeout: 20)
            }
            back(); sleep(1)
        }
        return false
    }

    private func openSettings() -> Bool {
        let overview = tabButton(t("Übersicht", "Overview"))
        if overview.waitForExistence(timeout: 5) { overview.tap() }
        guard tap(app.buttons[t("Einstellungen", "Settings")], "settings") else { return false }
        sleep(2)
        return true
    }

    /// The share sheet's close button, or a swipe down on the sheet.
    private func closeShareSheet() {
        for label in [t("Schließen", "Close"), "Close", "Schließen"] {
            let close = app.buttons[label]
            if close.exists && close.isHittable { close.tap(); sleep(2); return }
        }
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        sleep(2)
    }

    private func suggestionRow(_ index: Int) -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", t("Aufnahmen", "item"))).element(boundBy: index)
    }

    private func yearButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func searchTabButton() -> XCUIElement {
        for label in ["Suchen", "Suche", "Search"] where app.tabBars.buttons[label].exists {
            return tabButton(label)
        }
        return app.tabBars.buttons.element(boundBy: max(0, app.tabBars.buttons.count - 1))
    }

    private func tabButton(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    /// Rows of a List exist only once they are on screen: swipe until the element appears.
    private func scrollTo(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
    }

    private func scrollList(to element: XCUIElement) {
        let list = app.collectionViews.firstMatch
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 14 {
            (list.exists ? list : app).swipeUp()
            swipes += 1
        }
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("GALLERY_STEP_MISSING \(variant.tag) \(step)")
            return false
        }
        // Content under the navigation bar counts as hittable but a tap there lands on the bar.
        let bar = app.navigationBars.firstMatch
        var swipes = 0
        while swipes < 10 {
            let underBar = bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
            if underBar { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        guard element.isHittable else {
            print("GALLERY_STEP_MISSING \(variant.tag) \(step) (not hittable)")
            return false
        }
        element.tap()
        return true
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    private var analysisIdle: Bool {
        let done = anything(t("Fotos analysiert", "photos analyzed")).exists || anything(t("Analyse aktuell", "Analysis up to date")).exists
        return done && !app.buttons["Pause"].exists
    }

    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            streak = condition() ? streak + 1 : 0
            if streak >= stableChecks { return true }
            sleep(2)
        }
        print("GALLERY_STEP_MISSING \(variant.tag) \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow Full Access", "Zugriff auf alle Fotos erlauben", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben", "Vollen Zugriff erlauben"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    return
                }
            }
            if app.tabBars.firstMatch.exists || button("Analyse starten").exists { return }
            usleep(500_000)
        }
        print("GALLERY_STEP_MISSING \(variant.tag) system photo alert")
    }

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Erlauben"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 4) { allow.tap(); return }
        }
    }

    // MARK: Screenshots

    private func name(_ screen: String) -> String { "\(Self.device)_\(variant.tag)_\(screen)" }

    private func shot(_ screen: String, settle: Bool = true) {
        if settle { usleep(800_000) }
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name(screen) + ".png",
                                       payload: screenshot.pngRepresentation, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
        taken.append(screen)
        print("GALLERY_SHOT \(name(screen))")
    }

    private func miss(_ screens: [String], _ reason: String) {
        for screen in screens {
            missed.append(screen)
            print("GALLERY_MISSING \(name(screen)) | \(reason)")
        }
    }

    private func summary() {
        print("GALLERY_SUMMARY \(Self.device) \(variant.tag) shots \(taken.count) missing \(missed.count) \(missed.joined(separator: ","))")
    }
}
