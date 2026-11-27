import XCTest

/// The tabs "Unsortiert" and "Alben" as the UI tests reach them (`UITestScreens`; a file of its
/// own for SwiftLint's file length).
extension UITestScreens {
    // MARK: Unsorted

    @MainActor
    enum Unsorted {
        /// The tab's three filters (`LibraryBuckets.unsortedTabFilters`), "Unsortiert" first.
        static let filters = ["unorganized", "uncertain", "ignored"]

        /// One filter's chip, at the standard text sizes.
        static func filter(_ app: XCUIApplication, _ area: String) -> XCUIElement {
            app.buttons["library.filter.\(area)"]
        }

        /// "Anlegen …" next to "Name des neuen Albums" in the sheet "Zu Album hinzufügen"
        /// (`addToAlbum.create`; the "…" since wave 1: the preview opens first). By its name
        /// too, for a build without the identifier.
        static func createAlbum(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "addToAlbum.create", "Anlegen …")).firstMatch
        }

        /// A plan of one new album with the tab's first two photos, made as a user makes one by
        /// hand: "Auswählen", two photos, "Zu Album hinzufügen", its name `title`, "Anlegen …".
        /// The caller has the tab open; where it has no photos left (everything sorted), the
        /// uncertain ones. True once the preview ("Vorschau") shows; else false with a
        /// `UI_STEP_MISSING` line for the step that did not come, which the caller judges.
        @discardableResult
        static func planNewAlbum(_ app: XCUIApplication, titled title: String, _ what: String) -> Bool {
            func tap(_ element: XCUIElement, _ step: String) -> Bool {
                guard element.waitForExistence(timeout: 15) else {
                    print("UI_STEP_MISSING \(what): \(step)")
                    return false
                }
                // Into view where it is not (the bars' buttons always are).
                var swipes = 0
                while !element.isHittable && swipes < 3 {
                    app.swipeUp()
                    swipes += 1
                }
                element.tap()
                print("UI_STEP_OK \(what): \(step)")
                return true
            }
            // A photo's name holds its date ("Foto, 12. Oktober 2024"); the first pass over the
            // library comes before the photos (`library.preparing`).
            let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
            if !photos.firstMatch.waitForExistence(timeout: 7) {
                show(app, "uncertain", named: "Unsicher", "\(what): uncertain photos")
                // Not asserted: the count below is.
                _ = UITestWait.holds(timeout: 5) { photos.count >= 2 }
            }
            guard tap(app.buttons["Auswählen"], "select photos"), UITestWait.holds(timeout: 5, { photos.count >= 2 }) else {
                print("UI_STEP_MISSING \(what): two photos to pick (\(photos.count))")
                return false
            }
            photos.element(boundBy: 0).tap()
            photos.element(boundBy: 1).tap()
            guard tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Zu Album hinzufügen")).firstMatch, "add to album") else {
                return false
            }
            var field = app.textFields["Name des neuen Albums"]
            if !field.waitForExistence(timeout: 5) { field = app.textFields.firstMatch }
            guard tap(field, "name of the new album") else { return false }
            field.typeText(title)
            guard tap(createAlbum(app), "create \(title)") else { return false }
            let preview = app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
            print(preview ? "UI_STEP_OK \(what): preview of \(title)" : "UI_STEP_MISSING \(what): preview of \(title)")
            return preview
        }

        /// Shows the filter: its chip at the standard text sizes; at the accessibility sizes
        /// the menu (`library.filter`), then the choice by its name.
        @discardableResult
        static func show(_ app: XCUIApplication, _ area: String, named name: String, _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let chip = filter(app, area)
            if chip.waitForExistence(timeout: 5) {
                chip.tap()
                print("UI_STEP_OK \(what)")
                return true
            }
            let menu = app.buttons["library.filter"]
            guard menu.waitForExistence(timeout: 3) else {
                print("UI_STEP_MISSING \(what): neither the chip nor the menu")
                XCTFail("\(what): no filter \(area) in the tab \"Unsortiert\"", file: file, line: line)
                return false
            }
            menu.tap()
            let choice = app.buttons[name]
            guard choice.waitForExistence(timeout: 5) else {
                print("UI_STEP_MISSING \(what): no \"\(name)\" in the menu")
                XCTFail("\(what): no \"\(name)\" in the menu of the tab \"Unsortiert\"", file: file, line: line)
                return false
            }
            choice.tap()
            print("UI_STEP_OK \(what) (menu)")
            return true
        }
    }

    // MARK: Albums

    /// Where `find` saw an album: its first tile, its body's label when it was seen ("Title,
    /// 2 Fotos"; the element itself is read again at each use), how many tiles of that name
    /// stand there, and the place ("shelf", "Alle N", "Deine Alben").
    struct AlbumFound {
        let tile: XCUIElement
        let label: String
        let count: Int
        let place: String
    }

    @MainActor
    enum Albums {
        /// "Verlauf und Rückgängig" in the tab "Alben" (`albums.history`): the only way to the
        /// history since 5C (it left the settings).
        static func historyRow(_ app: XCUIApplication) -> XCUIElement {
            app.buttons["albums.history"]
        }

        /// Opens the history from the tab "Alben" (the caller has the tab open). True once its
        /// screen shows.
        @discardableResult
        static func openHistory(_ app: XCUIApplication, title: String = "Verlauf und Rückgängig", _ what: String,
                                timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let row = historyRow(app)
            var swipes = 0
            while !row.exists && swipes < 6 {
                app.swipeUp()
                swipes += 1
                _ = row.waitForExistence(timeout: 1)
            }
            guard row.waitForExistence(timeout: timeout) else {
                print("UI_STEP_MISSING \(what): no albums.history in the tab \"Alben\"")
                XCTFail("\(what): no \"Verlauf und Rückgängig\" (albums.history) in the tab \"Alben\"", file: file, line: line)
                return false
            }
            Cards.reach(row, in: app)
            row.tap()
            print("UI_STEP_OK \(what)")
            return app.navigationBars[title].waitForExistence(timeout: timeout)
        }

        /// Takes back the newest plans in "Verlauf und Rückgängig" (at most `limit`), so their
        /// suggestions are open again: after the flows before them most suggestions are made
        /// (the locked tests, `testRemovePhotoFromSuggestion`). iOS asks once before an app
        /// deletes albums: answered "Löschen". Returns how many were taken back; the start page
        /// shows again afterwards. `label` names the caller in the log ("locked").
        @discardableResult
        static func takeBackNewestPlans(_ app: XCUIApplication, limit: Int, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) -> Int {
            func back() {
                let bar = app.navigationBars.firstMatch
                if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
            }
            let albumsTab = app.tabBars.buttons["Alben"]
            guard albumsTab.waitForExistence(timeout: 15) else {
                print("UI_STEP_MISSING albums tab (\(label))")
                XCTFail("Missing: albums tab (\(label))", file: file, line: line)
                return 0
            }
            albumsTab.tap()
            print("UI_STEP_OK albums tab (\(label))")
            let history = app.navigationBars["Verlauf und Rückgängig"]
            guard openHistory(app, "history screen (\(label))", file: file, line: line) else { return 0 }
            // Its rows (not asserted: an empty history has none, and then nothing is taken back).
            _ = app.buttons.matching(identifier: "history.row").firstMatch.waitForExistence(timeout: 5)
            var undone = 0
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for index in 0..<(limit + 4) where undone < limit {
                let rows = app.buttons.matching(identifier: "history.row")
                guard index < rows.count else { break }
                rows.element(boundBy: index).tap()
                // A history row opens its change receipt (PlanReceiptView).
                UITestWait.appears(app.navigationBars["Änderungen"], "receipt of history row \(index + 1) (\(label))", timeout: 10,
                                   file: file, line: line)
                let undo = app.buttons["receipt.undo"]
                var more = 0
                // Up to 10: the receipt's album rows are taller since design wave 3 (DS-15 covers).
                while !undo.exists && more < 10 { app.swipeUp(); more += 1 }
                if undo.exists && undo.isEnabled {
                    undo.tap()
                    if confirmUndo(app, springboard: springboard) { undone += 1 }
                }
                // A receipt whose plan was taken back may go back to the history by itself (UI run
                // 45717521559: the back tap then left the history too).
                if !UITestWait.holds(timeout: 2, { history.exists }) { back() }
                UITestWait.appears(history, "back on the history (\(label))", timeout: 10, file: file, line: line)
            }
            print("UI_FACT \(label): plans taken back to have suggestions again: \(undone)")
            back()
            UITestWait.disappears(history, "history closed (\(label))", timeout: 10, file: file, line: line)
            let startTab = app.tabBars.buttons["Vorschläge"]
            if startTab.waitForExistence(timeout: 15) {
                startTab.tap()
                print("UI_STEP_OK start page after taking back (\(label))")
            } else {
                print("UI_STEP_MISSING start page after taking back (\(label))")
                XCTFail("Missing: start page after taking back (\(label))", file: file, line: line)
            }
            return undone
        }

        /// `takeBackNewestPlans`, once "Rückgängig machen" of a receipt is tapped: confirms it,
        /// answers iOS's question before an app deletes albums ("Löschen") and waits for
        /// "Rückgängig gemacht". False when there was nothing to confirm or it did not come.
        private static func confirmUndo(_ app: XCUIApplication, springboard: XCUIApplication) -> Bool {
            guard let confirm = app.buttons.matching(identifier: "Rückgängig machen").allElementsBoundByIndex
                .first(where: \.isHittable) else { return false }
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
            return app.staticTexts["Rückgängig gemacht"].waitForExistence(timeout: 30)
        }

        /// The tiles of the album named `title` (`album.tile`, its body says "Title, 2 Fotos") in
        /// the tab "Alben" the caller has open: on the shelf "Von Albumist" (newest first; it builds
        /// only the tiles on screen), else behind the shelf's "Alle N" (`albums.managed`, which
        /// stays open when the album is there), else further down under "Deine Alben". Nil when
        /// it shows in none of them. The one way the UI tests look for an album by its name
        /// (`test_ui_album_lookup.py`): looking only at the screen missed albums far along the
        /// shelf twice on 27.11. (PR 31's test08 in the night, PR 28's test08 in run 45971115191).
        static func find(_ app: XCUIApplication, titled title: String) -> AlbumFound? {
            // The tile is a container without words of its own; its body (`photoCard.body`) says
            // "Title, 2 Fotos" (second review of 27.11.: a match on the tile's own label found none).
            let tiles = app.descendants(matching: .any).matching(identifier: "album.tile")
                .containing(NSPredicate(format: "label BEGINSWITH %@", "\(title), "))
            let tile = tiles.firstMatch
            func found(_ place: String) -> AlbumFound {
                let body = tile.descendants(matching: .any).matching(identifier: "photoCard.body").firstMatch
                let found = AlbumFound(tile: tile, label: body.exists ? body.label : "", count: tiles.count, place: place)
                print("UI_FACT album \(title): \(found.count) tile(s), \(place), '\(found.label)'")
                return found
            }
            if tile.waitForExistence(timeout: 10) { return found("shelf") }
            let all = app.buttons["albums.managed"]
            if all.exists {
                Cards.reach(all, in: app)
                all.tap()
                if tile.waitForExistence(timeout: 10) { return found("Alle N") }
                // Not one of Albumist's: back to the tab for "Deine Alben".
                let bar = app.navigationBars.firstMatch
                if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
                _ = UITestWait.holds(timeout: 10) { !all.exists || all.isHittable }
            }
            var swipes = 0
            while !tile.exists && swipes < 4 {
                app.swipeUp()
                swipes += 1
                _ = tile.waitForExistence(timeout: 1)
            }
            if tile.exists { return found("Deine Alben") }
            print("UI_FACT album \(title): no tile on the shelf, behind \"Alle N\" or under \"Deine Alben\"")
            return nil
        }

        /// A plan of one new album with one photo of the first album on the shelf, made as a user
        /// makes one: the photo's long press, "Zu Album hinzufügen …", its name `title`,
        /// "Anlegen …" (creating the album and adding the photo: two changes in Photos). For when
        /// "Unsortiert" and "Unsicher" have nothing left: since the wave-1 tab has no "Alle", the
        /// photos of albums are the only ones left after the full flow sorted the demo library
        /// (UI run 46063808963, flow-full: flow test5 after test1, 1b and 4 found 0 to pick).
        /// True once the preview ("Vorschau") shows; else false with a `UI_STEP_MISSING` line.
        static func planNewAlbumFromAnAlbum(_ app: XCUIApplication, titled title: String, _ what: String) -> Bool {
            func missing(_ step: String) -> Bool {
                print("UI_STEP_MISSING \(what): \(step)")
                return false
            }
            let tab = UITestScreens.tabButton(app, UITestScreens.Tabs.german.albums)
            guard tab.waitForExistence(timeout: 10) else { return missing("tab Alben") }
            tab.tap()
            let tile = app.descendants(matching: .any).matching(identifier: "album.tile").firstMatch
            guard tile.waitForExistence(timeout: 10) else { return missing("an album on the shelf") }
            let body = tile.descendants(matching: .any).matching(identifier: "photoCard.body").firstMatch
            print("UI_FACT \(what): a photo of the album '\(body.exists ? body.label : "?")'")
            (body.exists ? body : tile).tap()
            let photo = app.descendants(matching: .any).matching(identifier: "album.photo").firstMatch
            guard photo.waitForExistence(timeout: 10) else { return missing("a photo in the album") }
            photo.press(forDuration: 1.0)
            // The menu passes its identifiers on (UI_FACT photo menu in the flow runs).
            let add = app.buttons["photoMenu.addToAlbum"]
            guard add.waitForExistence(timeout: 5) else { return missing("\"Zu Album hinzufügen …\" in the photo's menu") }
            add.tap()
            // The sheet's one text field: the new album's name.
            let field = app.textFields.firstMatch
            guard field.waitForExistence(timeout: 5) else { return missing("name of the new album") }
            field.tap()
            field.typeText(title)
            let create = Unsorted.createAlbum(app)
            guard create.waitForExistence(timeout: 5) else { return missing("create \(title)") }
            create.tap()
            // The preview: its own bar with "Jetzt anlegen" (`plan.apply`).
            let preview = app.buttons["plan.apply"].waitForExistence(timeout: 20)
            print(preview ? "UI_STEP_OK \(what): preview of \(title)" : "UI_STEP_MISSING \(what): preview of \(title)")
            return preview
        }

        /// "…" in an album of Albumist's with something to undo (`album.more`); by its name where
        /// the bar does not pass the identifier on.
        static func more(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "album.more", "Weitere Aktionen")).firstMatch
        }

        /// "Rückgängig machen" in that menu or in the long press on the tile (`album.undo`); its
        /// second line may be part of its name.
        static func undo(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "album.undo", "Rückgängig machen")).firstMatch
        }
    }
}
