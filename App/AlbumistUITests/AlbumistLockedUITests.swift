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
    var app = XCUIApplication()

    func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
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
    func shot(_ name: String) {
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
        UITestScreens.Albums.takeBackNewestPlans(app, limit: limit, "locked")
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
        let expected = "noch \(left - used) von 10 kostenlosen Alben"
        let rest = anything(expected).exists
        print(rest ? "UI_STEP_OK free albums left after this plan (\(expected))" : "UI_STEP_MISSING free albums left after this plan (\(expected))")
        XCTAssertTrue(rest, "The plan does not say \"\(expected)\" (\(left) free, the plan uses \(used))")
        guard tap(start, "apply plan (locked)") else { return }
        let done = button("Rückgängig machen").waitForExistence(timeout: 300)
        print(done ? "UI_STEP_OK locked plan finished" : "UI_STEP_MISSING locked plan finished")
        XCTAssertTrue(done, "The plan within the free albums did not finish")
    }

    /// The card after `skipped` others whose action is "Anlegen": on the start page
    /// (`suggestion.card.create`), else in an area's list (`suggestion.row` whose button says
    /// „Name“ anlegen; once open, the next tries stay in it, as in `FrameUITests`). Nil when
    /// neither has one.
    private func cardThatCreates(skipping skipped: Int) -> XCUIElement? {
        let inList = UITestScreens.SuggestionList.cards(app).containing(UITestScreens.Cards.saying("anlegen"))
        if !UITestScreens.SuggestionList.cards(app).firstMatch.exists {
            let onPage = UITestScreens.Cards.cards(app, action: "create")
            if onPage.firstMatch.waitForExistence(timeout: 5)
                || UITestScreens.Cards.first(app, action: "create", swipes: 4, timeout: 1) != nil {
                let card = onPage.element(boundBy: skipped)
                if card.exists { return card }
            }
            guard UITestScreens.StartPage.openList(app, "a list for a card with Anlegen (locked)", timeout: 5) else { return nil }
        }
        var swipes = 0
        while !inList.element(boundBy: skipped).waitForExistence(timeout: 2) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        let card = inList.element(boundBy: skipped)
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

        takeBackPlansWithoutACardThatCreates()
        // "Anlegen" makes at once only what needs no look first: a suggestion whose plan has
        // something to point out opens its page before the free albums are counted
        // (`AppModel.createNow`; UI run 44878163259 tapped „København V, Mai 2023“, whose page
        // opened, as in UI run 44862187776). Then the next card, at most three, as
        // `FrameUITests.test3` does.
        let sheet = UITestScreens.Purchase.sheet(app)
        let preview = app.navigationBars["Vorschau"]
        var tapped: TappedCard?
        var cardsFound = 0
        for attempt in 0..<3 {
            guard let card = cardThatCreates(skipping: attempt) else { break }
            cardsFound += 1
            let identifier = card.identifier
            let name = card.buttons["photoCard.body"].label
            // The album's name as its button says it; the card is found by it afterwards.
            let title = UITestScreens.Cards.albumName(of: card) ?? name
            print("UI_FACT locked: card '\(name)' (\(identifier))")
            shot(attempt == 0 ? "76-locked-card" : "76-locked-card-\(attempt + 1)")
            guard UITestScreens.Cards.tapAction(of: card, in: app, "Anlegen without free albums (locked)") else { return }
            _ = UITestWait.holds(timeout: 15) {
                sheet.exists || UITestScreens.SuggestionPage.isShown(app) || preview.exists || app.alerts.firstMatch.exists
            }
            if sheet.exists {
                tapped = TappedCard(identifier: identifier, name: name, title: title)
                break
            }
            if preview.exists || UITestScreens.SuggestionPage.isShown(app) {
                print("UI_FACT locked: '\(name)' opened \(preview.exists ? "its preview" : "its page") instead (it is looked at first)")
                back()
                _ = UITestWait.holds(timeout: 5) { !preview.exists && !UITestScreens.SuggestionPage.isShown(app) }
                continue
            }
            // What came instead (UI run 44862187776 left no picture of it): a message, or the
            // start page as it was.
            let alert = app.alerts.firstMatch
            let came = alert.exists ? "the message '\(alert.label)'" : "no message"
            print("UI_FACT locked: after Anlegen \(came), screen '\(app.navigationBars.firstMatch.identifier)'")
            break
        }
        guard cardsFound > 0 else {
            print("UI_STEP_MISSING a card with Anlegen (locked)")
            XCTFail("No card with \"Anlegen\" on the start page or in a list, not even after taking plans back")
            return
        }
        // The sheet instead of the album, saying why and that the suggestion stays.
        guard let tapped else {
            print("UI_STEP_MISSING purchase sheet after Anlegen (locked)")
            shot("x-no-purchase-sheet-after-anlegen")
            XCTFail("No card's \"Anlegen\" opened the purchase sheet without free albums (\(cardsFound) tried)")
            return
        }
        print("UI_STEP_OK purchase sheet after Anlegen (locked)")
        expectTheSheetSaysWhyAndNothingIsMade(tapped)
    }

    /// `test8`: after a complete flow most suggestions are made, so without a card that offers
    /// "Anlegen" the newest plans are taken back and the app starts again.
    private func takeBackPlansWithoutACardThatCreates() {
        if cardThatCreates(skipping: 0) == nil {
            print("UI_FACT locked: no card with \"Anlegen\", taking back the newest plans")
            if takeBackNewestPlans(limit: 2) > 0 {
                _ = UITestWait.holds(timeout: 120) {
                    offersSeveral() || UITestScreens.Cards.cards(app, action: "create").firstMatch.exists
                }
                relaunch()
            }
        }
    }

    /// The card `test8` tapped: its identifier, its name and the album's name its button says.
    private struct TappedCard {
        let identifier: String
        let name: String
        let title: String
    }

    /// `test8`, after the purchase sheet came for `tapped`: the sheet says why and that the
    /// suggestion stays; closed, nothing was made and the card still offers "Anlegen".
    private func expectTheSheetSaysWhyAndNothingIsMade(_ tapped: TappedCard) {
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
        let again = UITestScreens.Cards.card(app, identifier: tapped.identifier, titled: tapped.title)
        let stayed = again.waitForExistence(timeout: 10)
        print(stayed ? "UI_STEP_OK the suggestion stayed open (locked)" : "UI_STEP_MISSING the suggestion stayed open (locked)")
        XCTAssertTrue(stayed, "The suggestion '\(tapped.name)' is gone after the purchase sheet was closed")
        if stayed {
            let cardButton = UITestScreens.Cards.action(of: again)
            XCTAssertTrue(UITestScreens.Cards.button(cardButton, says: "anlegen"),
                          "The suggestion '\(tapped.name)' no longer offers \"Anlegen\" after the purchase sheet was closed ('\(cardButton.label)')")
        }
        shot("78-locked-card-after-sheet")
    }
}
