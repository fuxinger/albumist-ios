import XCTest
import UIKit

/// The locked path of the one-time purchase, end to end (on the demo library, created first
/// when the test runs alone). The app starts with `-AlbumistUITestLocked`.
///
/// - test7, one free album left: a plan with more albums shows the unlock card instead of
///   "Jetzt anlegen", its "Freischalten …" opens the purchase sheet, "Die ersten 1 jetzt
///   kostenlos anlegen" shrinks the plan to the free album, it runs, and afterwards no free
///   album is left.
/// - test8, no free album left: "Anlegen" on a card opens the purchase sheet instead of making
///   the album (design E6 "Freie Alben verbraucht"); closed, the suggestion is still open.
///
/// The sheet is opened and closed, nothing is bought (no App Store account on the CI
/// simulator); buying, restoring, Ask to Buy, failures and refunds are tested with StoreKit in
/// PurchaseStoreKitTests.
@MainActor
final class AlbumistLockedUITests: XCTestCase {
    private var app = XCUIApplication()

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            XCTFail("Missing: \(step)")
            return false
        }
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    /// What is on screen, as base64 chunks in the log (artifacts are not reachable everywhere).
    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot().image
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

    /// `element` is in sight as the plan opens, without scrolling and clear of the tab bar
    /// (review P3-05 = G3-05: the button and the unlock card stood at the end of the plan, below
    /// the fold). Content under the tab bar counts as hittable for XCUITest, so the frame is read.
    @discardableResult
    private func expectInReach(_ element: XCUIElement, _ what: String) -> Bool {
        let tabs = app.tabBars.firstMatch
        let reached = UITestWait.until("\(what) in reach without scrolling", timeout: 10) {
            element.exists && element.isHittable && app.frame.contains(element.frame)
                && (!tabs.exists || element.frame.maxY <= tabs.frame.minY + 1)
        }
        if !reached {
            print("UI_FACT \(what): \(element.exists ? "\(element.frame)" : "missing"), tab bar \(tabs.exists ? "\(tabs.frame)" : "missing")")
        }
        return reached
    }

    /// The start page offers a preview of several suggestions: "Dein Startpaket" (while nothing
    /// is made and enough free albums are left) or "Alle N" of an area, whose list ticks.
    private func offersSeveral() -> Bool {
        UITestScreens.StartPage.starterSet(app).exists
            || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startPage.all.")).firstMatch.exists
    }

    /// Starts the locked app with `free` free albums left.
    private func launchLocked(freeAlbumsLeft free: Int) {
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked",
                               "-AlbumistUITestLocked", "-AlbumistUITestFreeAlbumsLeft", "\(free)"] + UITestStalls.arguments(besides: [])
        UITestAppEnd.launch(app)
    }

    /// Takes back the newest plans in "Verlauf und Rückgängig" (in the tab "Alben" since 5C, at
    /// most `limit`), so their suggestions are open again. Returns how many were taken back; the
    /// start page shows again afterwards.
    private func takeBackNewestPlans(limit: Int) -> Int {
        guard tap(app.tabBars.buttons["Alben"], "albums tab (locked)") else { return 0 }
        let history = app.navigationBars["Verlauf und Rückgängig"]
        guard UITestScreens.Albums.openHistory(app, "history screen (locked)") else { return 0 }
        // Its rows (not asserted: an empty history has none, and then nothing is taken back).
        _ = app.buttons.matching(identifier: "history.row").firstMatch.waitForExistence(timeout: 5)
        var undone = 0
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for index in 0..<(limit + 4) where undone < limit {
            let rows = app.buttons.matching(identifier: "history.row")
            guard index < rows.count else { break }
            rows.element(boundBy: index).tap()
            // A history row opens its change receipt (PlanReceiptView).
            UITestWait.appears(app.navigationBars["Änderungen"], "receipt of history row \(index + 1) (locked)", timeout: 10)
            let undo = app.buttons["receipt.undo"]
            var more = 0
            // Up to 10: the receipt's album rows are taller since design wave 3 (DS-15 covers).
            while !undo.exists && more < 10 { app.swipeUp(); more += 1 }
            if undo.exists && undo.isEnabled {
                undo.tap()
                if let confirm = app.buttons.matching(identifier: "Rückgängig machen").allElementsBoundByIndex.first(where: \.isHittable) {
                    confirm.tap()
                    // iOS asks once before an app deletes albums.
                    let end = Date().addingTimeInterval(40)
                    while Date() < end && !app.staticTexts["Rückgängig gemacht"].exists {
                        let alert = springboard.alerts.firstMatch
                        if alert.waitForExistence(timeout: 3) {
                            let delete = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Löschen"])).firstMatch
                            if delete.exists {
                                delete.tap()
                                // The alert has gone (it may ask again: the loop looks once more).
                                _ = UITestWait.holds(timeout: 5) { !alert.exists }
                            } else { break }
                        }
                    }
                    if app.staticTexts["Rückgängig gemacht"].waitForExistence(timeout: 30) { undone += 1 }
                }
            }
            back()
            UITestWait.appears(history, "back on the history (locked)", timeout: 10)
        }
        print("UI_FACT locked: plans taken back to have suggestions again: \(undone)")
        back()
        UITestWait.disappears(history, "history closed (locked)", timeout: 10)
        tap(app.tabBars.buttons["Vorschläge"], "start page after taking back (locked)")
        return undone
    }

    /// Ends the app and starts it again with the same arguments, then waits for the start page.
    private func relaunch() {
        UITestAppEnd.launch(app)  // ends it first
        waitForIdleStartPage("locked start page after relaunch")
    }

    /// The start page with nothing running (its line about the analysis, no "Pause").
    @discardableResult
    private func waitForIdleStartPage(_ step: String) -> Bool {
        let idle = UITestWait.holds(timeout: 120) { UITestScreens.Analysis.isIdle(app) }
        print(idle ? "UI_STEP_OK \(step)" : "UI_STEP_MISSING \(step)")
        return idle
    }

    /// The number of a row made of a title and a number, maybe with a word after it: the plan's
    /// summary (PlanReviewView.row, combined into one element: "Neue Alben, 3") or Settings'
    /// "Noch kostenlos" (LabeledContent: "1 Alben" as the element's value, or combined). Should
    /// the two come as elements of their own, the number is the text on the title's line. nil
    /// when no such row is there within `timeout`.
    private func rowCount(_ title: String, timeout: TimeInterval) -> Int? {
        func number(_ text: some StringProtocol) -> Int? {
            let plain = text.replacingOccurrences(of: ".", with: "")
            guard let m = plain.wholeMatch(of: #/[,:\s]*(\d+)(?:\s+\p{L}+)?\s*/#) else { return nil }
            return Int(m.1)
        }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title))
        if timeout > 0 { _ = rows.firstMatch.waitForExistence(timeout: timeout) }
        var titleFrame: CGRect?
        for row in rows.allElementsBoundByIndex {
            guard let snapshot = try? row.snapshot() else { continue }
            if let n = number(snapshot.label.dropFirst(title.count)) { return n }
            if snapshot.label == title {
                if let value = snapshot.value as? String, let n = number(value) { return n }
                titleFrame = snapshot.frame
            }
        }
        guard let line = titleFrame else { return nil }
        for text in app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+( \\p{L}+)?")).allElementsBoundByIndex {
            guard let snapshot = try? text.snapshot(), snapshot.frame.midY >= line.minY, snapshot.frame.midY <= line.maxY,
                  snapshot.frame.minX > line.maxX, let n = number(snapshot.label) else { continue }
            return n
        }
        return nil
    }

    /// "Noch kostenlos: N Alben" in Settings (SettingsView, section "Vollversion"), opened from
    /// the start page and closed again. nil when it cannot be read.
    private func freeAlbumsLeftInSettings() -> Int? {
        guard tap(app.buttons["Einstellungen"], "settings for the free albums (locked)") else { return nil }
        UITestWait.appears(app.navigationBars["Einstellungen"], "settings open for the free albums (locked)", timeout: 10)
        let row = anything("Noch kostenlos")
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        let left = rowCount("Noch kostenlos", timeout: 5)
        print("UI_FACT locked: Settings says \(left.map { "\($0)" } ?? "?") free albums left")
        shot("72-locked-free-albums")
        tap(button("Fertig"), "close settings after the free albums (locked)")
        UITestWait.disappears(app.navigationBars["Einstellungen"], "settings closed after the free albums (locked)", timeout: 20)
        return left
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    /// CI runs groups of UI tests on separate simulators: when this test runs without the flow
    /// before it, the demo library is created and analysed first (fast start, no onboarding).
    private func prepareLibrary() {
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked", "-AlbumistUITestFastStart"]
            + UITestStalls.arguments(besides: [])
        // Through the helper: the app of the test before is ended by its process id first.
        UITestAppEnd.launch(app)
        let deadline = Date().addingTimeInterval(900)
        var streak = 0
        while Date() < deadline && streak < 3 {
            let ready = UITestScreens.Analysis.isIdle(app)
                && !anything("Beispielfotos werden angelegt").exists && !button("Beispiel-Mediathek anlegen").exists
            streak = ready ? streak + 1 : 0
            // pacing: the poll's interval, kept: "three checks in a row" means the library stayed
            // ready for about four seconds (not only between two batches of the analysis).
            sleep(2)
        }
        print(streak >= 3 ? "UI_STEP_OK prepared (locked)" : "UI_STEP_MISSING prepared (locked)")
        // The next launch (UITestAppEnd.launch) ends this app first.
        app = XCUIApplication()
    }

    func test7_LockedPlanOffersTheFreeAlbumsLeft() {
        continueAfterFailure = true
        prepareLibrary()
        launchLocked(freeAlbumsLeft: 1)
        // A cut-off test 1 left the app at its welcome screen (run 43816787321).
        if !UITestOnboarding.fullFlowReachedItsEnd { UITestOnboarding.completeIfNeeded(app, in: "test7") }
        // The start page is idle (the earlier runs analysed the demo library).
        waitForIdleStartPage("locked start page")

        // Something to apply: several suggestions as one preview ("Dein Startpaket", or the
        // ticks of an area's list; the basket of before is gone). After a complete flow nearly
        // every suggestion is created (run 43796844064: one suggestion open, nothing
        // recommendable), so the test takes back the newest plans and creates from those
        // suggestions instead of skipping the locked path.
        if !UITestWait.holds(timeout: 5, { offersSeveral() }) {
            print("UI_FACT locked: no preview of several suggestions on the start page, taking back the newest plans")
            // Four: the newest plans need not come from suggestions (flow test 5 cuts off a
            // new album of two photos when nothing recommended is left, and keeps and retries
            // it: two plans whose undo brings no suggestion back, UI run 43949880264).
            if takeBackNewestPlans(limit: 4) > 0 {
                // The suggestions of the plans taken back return once the undo is stored and
                // matched again; the start page says when (run 43804947107 went on at once and
                // found the one suggestion that was there before). Not asserted here: the
                // relaunch below and the preview after it decide.
                let back = UITestWait.holds(timeout: 120) { offersSeveral() }
                print("UI_FACT locked: several suggestions offered after taking back: \(back)")
                shot("70-locked-start-after-takeback")
                // Every undo gave its albums back to the free count (AppModel.finalize:
                // returnUsage, also for plans of earlier runs: FreeAlbumLedger.giveBack lowers
                // the old total), so more would be free now and the plan would rarely need the
                // card. A new launch starts the count at 1 again: the locked run's purchase
                // defaults are emptied at every launch (UITestSupport.lockedPurchaseDefaults) and
                // set to -AlbumistUITestFreeAlbumsLeft 1; the suggestions are in the database.
                // Since the album ledger (bundle j) a set start (FreeAlbumLedger(startingWithUsed:))
                // is never given back, so one free album should be left; not taken for granted
                // all the same: the count is read in Settings below.
                relaunch()
            }
        }
        // Read, not assumed (see the relaunch above).
        let free = freeAlbumsLeftInSettings()
        XCTAssertNotNil(free, "Settings shows no readable \"Noch kostenlos\"")
        let left = free ?? 1
        // One free album: no "Dein Startpaket" (it needs three), so an area's list with "Alle
        // auswählen" and "N Alben anlegen".
        let ready = UITestScreens.StartPage.openPlan(app, "open plan (locked)")
        print(ready ? "UI_STEP_OK something to create (locked)" : "UI_STEP_MISSING something to create (locked)")
        XCTAssertTrue(ready, "The locked run found nothing to create, not even after taking plans back")
        guard ready else { return }
        shot("71-locked-preview")

        // The unlock card comes exactly when the plan needs more albums than are free
        // (PlanReviewView: !purchases.allows(albums: facts.freeAlbumUse)). freeAlbumUse of a
        // plan from suggestions is its new plus its extended albums (pinned by
        // PurchaseRulesTests.previewSummaryCountsWhatTheFreeAlbumsCount), which the summary
        // above the card shows ("Neue Alben", "Ergänzte Alben" only when > 0).
        let newAlbums = rowCount("Neue Alben", timeout: 30)
        let extended = rowCount("Ergänzte Alben", timeout: 0) ?? 0
        print("UI_FACT locked: the plan has \(newAlbums.map { "\($0)" } ?? "?") new and \(extended) extended albums, \(left) free albums left")
        XCTAssertNotNil(newAlbums, "The plan's summary shows no readable \"Neue Alben\" row")
        let planned = (newAlbums ?? 0) + extended
        let unlock = app.staticTexts["Albumist freischalten"]
        let cardShown = unlock.waitForExistence(timeout: planned > left ? 10 : 3)
        if newAlbums != nil && free != nil {
            XCTAssertEqual(cardShown, planned > left, planned > left
                           ? "A plan with \(planned) albums and \(left) free albums left shows no unlock card"
                           : "A plan with \(planned) albums shows the unlock card although \(left) free albums are left")
        }
        if cardShown {
            print("UI_STEP_OK unlock card")
            // At the top of the plan, where "Jetzt anlegen" would be in reach otherwise.
            expectInReach(unlock, "unlock card (locked)")
            shot("74-locked-plan-unlock")
            XCTAssertFalse(app.buttons["plan.apply"].exists, "A plan over the free albums offered \"Jetzt anlegen\"")
            // "Freischalten …" opens the purchase sheet (design E6): the price (or "Preis wird
            // geladen …" until StoreKit has it, W7), "Kauf wiederherstellen", "Code einlösen",
            // and "Schließen" back to the plan.
            let open = app.buttons["unlock.open"]
            XCTAssertTrue(open.exists, "The unlock card has no \"Freischalten …\" (unlock.open)")
            if tap(open, "open the purchase sheet from the plan (locked)", timeout: 5) {
                shot("74b-locked-purchase-sheet")
                UITestScreens.Purchase.expectOffersAndClose(app, "purchase sheet of the plan (locked)")
                XCTAssertTrue(unlock.waitForExistence(timeout: 5), "The plan lost its unlock card after the purchase sheet was closed")
            }
            guard tap(button("jetzt kostenlos anlegen"), "keep the free albums only") else { return }
        } else {
            print("UI_FACT locked: the plan has \(planned) albums, they fit the \(left) free ones")
        }
        let start = app.buttons["plan.apply"]
        // Waited for (also after "jetzt kostenlos anlegen", which had a fixed 3 s before).
        UITestWait.appears(start, "the plan within the free albums can be applied (locked)", timeout: 23)
        expectInReach(start, "\"Jetzt anlegen\" (locked)")
        shot("75-locked-plan-free")
        // What is free afterwards: the free albums less what this plan uses ("Die ersten N"
        // made the plan anew, so its summary is read again).
        let used = cardShown ? (rowCount("Neue Alben", timeout: 10) ?? 0) + (rowCount("Ergänzte Alben", timeout: 0) ?? 0) : planned
        let expected = "noch \(left - used) von 10 Gratis-Alben"
        let rest = anything(expected).exists
        print(rest ? "UI_STEP_OK free albums left after this plan (\(expected))" : "UI_STEP_MISSING free albums left after this plan (\(expected))")
        XCTAssertTrue(rest, "The plan does not say \"\(expected)\" (\(left) free, the plan uses \(used))")
        guard tap(start, "apply plan (locked)") else { return }
        let done = button("Rückgängig machen").waitForExistence(timeout: 300)
        print(done ? "UI_STEP_OK locked plan finished" : "UI_STEP_MISSING locked plan finished")
        XCTAssertTrue(done, "The plan within the free albums did not finish")
    }

    /// A card whose action is "Anlegen": on the start page (`suggestion.card.create`), else in an
    /// area's list (`suggestion.row` whose button says „Name“ anlegen).
    private func cardThatCreates() -> XCUIElement? {
        if let card = UITestScreens.Cards.first(app, action: "create", swipes: 4, timeout: 5) { return card }
        guard UITestScreens.StartPage.openList(app, "a list for a card with Anlegen (locked)", timeout: 5) else { return nil }
        let card = UITestScreens.SuggestionList.cards(app).containing(UITestScreens.Cards.saying("anlegen")).firstMatch
        var swipes = 0
        while !card.waitForExistence(timeout: 2) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        return card.exists ? card : nil
    }

    /// No free album left: "Anlegen" on a card opens the purchase sheet instead of making the
    /// album (design E6 "Freie Alben verbraucht": its own sheet, also when "Anlegen" reaches the
    /// limit), and the sheet says that the suggestion stays open. Closed with "Schließen",
    /// nothing was made: no banner, and the card still offers "Anlegen".
    func test8_CardWithoutFreeAlbumsOpensThePurchaseSheet() {
        continueAfterFailure = true
        prepareLibrary()
        launchLocked(freeAlbumsLeft: 0)
        if !UITestOnboarding.fullFlowReachedItsEnd { UITestOnboarding.completeIfNeeded(app, in: "test8") }
        waitForIdleStartPage("locked start page without free albums")

        // After a complete flow most suggestions are made: the newest plans are taken back then.
        var found = cardThatCreates()
        if found == nil {
            print("UI_FACT locked: no card with \"Anlegen\", taking back the newest plans")
            if takeBackNewestPlans(limit: 2) > 0 {
                _ = UITestWait.holds(timeout: 120) {
                    offersSeveral() || UITestScreens.Cards.cards(app, action: "create").firstMatch.exists
                }
                relaunch()
                found = cardThatCreates()
            }
        }
        guard let card = found else {
            print("UI_STEP_MISSING a card with Anlegen (locked)")
            XCTFail("No card with \"Anlegen\" on the start page or in a list, not even after taking plans back")
            return
        }
        let identifier = card.identifier
        let name = card.buttons["photoCard.body"].label
        // The album's name as its button says it; the card is found by it afterwards.
        let title = UITestScreens.Cards.albumName(of: card) ?? name
        print("UI_FACT locked: card '\(name)' (\(identifier))")
        shot("76-locked-card")
        guard UITestScreens.Cards.tapAction(of: card, in: app, "Anlegen without free albums (locked)") else { return }

        // The sheet instead of the album, saying why and that the suggestion stays.
        guard UITestWait.appears(UITestScreens.Purchase.sheet(app), "purchase sheet after Anlegen (locked)", timeout: 15) else {
            // What came instead (UI run 44862187776 left no picture of it): a message, the
            // suggestion's page, or the start page as it was.
            let alert = app.alerts.firstMatch
            print("UI_FACT locked: after Anlegen \(alert.exists ? "the message '\(alert.label)'" : "no message"), screen '\(app.navigationBars.firstMatch.identifier)'")
            shot("x-no-purchase-sheet-after-anlegen")
            return
        }
        shot("77-locked-card-purchase-sheet")
        let why = anything("kostenlosen Alben sind angelegt").waitForExistence(timeout: 3)
        print(why ? "UI_STEP_OK the sheet says the free albums are used up" : "UI_STEP_MISSING the sheet says the free albums are used up")
        XCTAssertTrue(why, "The purchase sheet after \"Anlegen\" does not say that the free albums are used up")
        let stays = anything("Der Vorschlag bleibt offen").exists
        print(stays ? "UI_STEP_OK the sheet says the suggestion stays open" : "UI_STEP_MISSING the sheet says the suggestion stays open")
        XCTAssertTrue(stays, "The purchase sheet after \"Anlegen\" does not say \"Der Vorschlag bleibt offen und läuft dir nicht weg.\"")
        guard UITestScreens.Purchase.expectOffersAndClose(app, "purchase sheet after Anlegen (locked)") else { return }

        // Nothing was made: no banner "angelegt", and the suggestion still offers "Anlegen".
        UITestWait.never("an album is made without free albums (banner)", for: 3) { UITestScreens.QuickCreate.banner(app).exists }
        let again = UITestScreens.Cards.card(app, identifier: identifier, titled: title)
        let stayed = again.waitForExistence(timeout: 10)
        print(stayed ? "UI_STEP_OK the suggestion stayed open (locked)" : "UI_STEP_MISSING the suggestion stayed open (locked)")
        XCTAssertTrue(stayed, "The suggestion '\(name)' is gone after the purchase sheet was closed")
        if stayed {
            let cardButton = UITestScreens.Cards.action(of: again)
            XCTAssertTrue(UITestScreens.Cards.button(cardButton, says: "anlegen"),
                          "The suggestion '\(name)' no longer offers \"Anlegen\" after the purchase sheet was closed ('\(cardButton.label)')")
        }
        shot("78-locked-card-after-sheet")
    }
}
