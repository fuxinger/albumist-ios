import XCTest

/// The analysis and the trial year as the UI tests reach them (`UITestScreens`; a file of its
/// own for SwiftLint's file length).
extension UITestScreens {
    // MARK: Analysis

    @MainActor
    enum Analysis {
        /// The start page's line once nothing runs (`analysis.summary`: "Alle N Fotos analysiert",
        /// "Analyse aktuell", "58 von 246 Fotos analysiert" or "Analyse fertig"), or right after
        /// a long run ("Analyse fertig", "N Vorschläge warten auf dich.", `analysis.finished`).
        /// Each opens the sheet "Analyse".
        static func line(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier IN %@", ["analysis.summary", "analysis.finished"])).firstMatch
        }

        /// Nothing runs and nothing waits: no "Pause", and the start page shows its line (a run
        /// that waits for the device or for Photos shows its card instead). The Pause button
        /// first: one query while the analysis runs.
        static func isIdle(_ app: XCUIApplication) -> Bool {
            !app.buttons["Pause"].exists && line(app).exists
        }

        /// Opens the sheet "Analyse" from the start page's line; true once its headline shows.
        @discardableResult
        static func openSheet(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
            if app.buttons["analysis.summary.done"].exists { return headline(app).waitForExistence(timeout: timeout) }
            let row = line(app)
            guard row.waitForExistence(timeout: timeout) else {
                print("UI_FACT no analysis line (analysis.summary, analysis.finished) to open the sheet \"Analyse\"")
                return false
            }
            Cards.reach(row, in: app)
            row.tap()
            return headline(app).waitForExistence(timeout: timeout)
        }

        /// Closes the sheet "Analyse" if it is open.
        static func closeSheet(_ app: XCUIApplication) {
            let done = app.buttons["analysis.summary.done"]
            guard done.exists else { return }
            done.tap()
            _ = UITestWait.holds(timeout: 5) { !done.exists }
        }

        /// The sheet's headline: "Alle N Fotos analysiert", "N von M Fotos analysiert" or
        /// "Analyse aktuell" (the line on the page is a button, never a text).
        static func headline(_ app: XCUIApplication) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@ OR label == %@", "Fotos analysiert", "Analyse aktuell")).firstMatch
        }

        /// A snapshot of `element`, tried three times half a second apart: the count changes
        /// while the analysis runs, and reading `label` of an element that has just changed is a
        /// hard test failure ("No matches found", flow test 5 in UI run 44038288087, right after
        /// "checking again"). `gone`: the element went away between the tries.
        private static func snapshot(of element: XCUIElement) -> (shot: (any XCUIElementSnapshot)?, gone: Bool) {
            var taken: (any XCUIElementSnapshot)?
            var gone = false
            var tries = 0
            // Three tries end it; the 30 s cap only keeps the wait finite and visible to the
            // time-limit rule (second review of P5-05).
            _ = UITestWait.holds(timeout: 30) {
                tries += 1
                if let snapshot = try? element.snapshot() { taken = snapshot; return true }
                gone = !element.exists
                return gone || tries >= 3
            }
            return (taken, gone)
        }

        private static func number(_ text: Substring) -> Int { Int(text.filter(\.isNumber)) ?? 0 }

        /// The counts once nothing runs, or nil when the page shows no line within `wait` (or it
        /// went while it was read: a run started). "Alle N Fotos analysiert" and "Analyse
        /// aktuell" are read from the line (nothing follows later then); "58 von 246 Fotos
        /// analysiert" and "Analyse fertig" (something follows later, or a run that just
        /// finished) from the sheet "Analyse", which also says how many photos could not be
        /// read; it is opened and closed again. A line or a sheet that cannot be read is
        /// `readFailed`, never complete (it was, while `try?` gave nil).
        static func counts(_ app: XCUIApplication, wait: TimeInterval = 3) -> Counts? {
            let row = line(app)
            guard row.waitForExistence(timeout: wait) else { return nil }
            let read = snapshot(of: row)
            if read.gone { return nil }
            guard let shot = read.shot else {
                print("UI_FACT analysis: the line is on screen but could not be read three times")
                return Counts(label: "(not readable)", analyzed: 0, photos: 0, unreadable: 0, loads: "", readFailed: true)
            }
            let lineLabel = shot.label
            let lineLoads = (shot.value as? String) ?? ""
            if let m = lineLabel.firstMatch(of: #/^Alle ([0-9.]+) Fotos analysiert/#) {
                let photos = number(m.1)
                return Counts(label: lineLabel, analyzed: photos, photos: photos, unreadable: 0, loads: lineLoads)
            }
            if lineLabel.hasPrefix("Analyse aktuell") {
                return Counts(label: lineLabel, analyzed: 0, photos: 0, unreadable: 0, loads: lineLoads)
            }
            // "58 von 246 Fotos analysiert" or "Analyse fertig": the sheet says how far, and what
            // could not be read.
            guard openSheet(app) else {
                closeSheet(app)
                print("UI_FACT analysis: '\(lineLabel)' and the sheet \"Analyse\" did not open")
                return Counts(label: lineLabel, analyzed: 0, photos: 0, unreadable: 0, loads: lineLoads, readFailed: true)
            }
            defer { closeSheet(app) }
            guard let sheet = snapshot(of: headline(app)).shot else {
                print("UI_FACT analysis: the sheet's count could not be read three times")
                return Counts(label: lineLabel, analyzed: 0, photos: 0, unreadable: 0, loads: lineLoads, readFailed: true)
            }
            let label = sheet.label
            let sheetLoads = (sheet.value as? String) ?? ""
            let loads = sheetLoads.isEmpty ? lineLoads : sheetLoads
            var analyzed = 0, photos = 0
            if let m = label.firstMatch(of: #/([0-9.]+) von ([0-9.]+) Fotos analysiert/#) {
                analyzed = number(m.1)
                photos = number(m.2)
            } else if let m = label.firstMatch(of: #/Alle ([0-9.]+) Fotos analysiert/#) {
                analyzed = number(m.1)
                photos = analyzed
            } else if label != "Analyse aktuell" {
                print("UI_FACT analysis: the sheet says '\(label)'")
                return Counts(label: label, analyzed: 0, photos: 0, unreadable: 0, loads: loads, readFailed: true)
            }
            let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "konnten noch nicht gelesen")).firstMatch
            let noteLabel = note.exists ? (try? note.snapshot())?.label : nil
            let unreadable = noteLabel.map { $0.split(separator: " ").first.map(number) ?? 0 } ?? 0
            return Counts(label: label, analyzed: analyzed, photos: photos, unreadable: unreadable, loads: loads)
        }

        /// "Neu prüfen" in the sheet "Analyse" (it closes the sheet as the check starts).
        @discardableResult
        static func checkAgain(_ app: XCUIApplication, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
            let again = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Neu prüfen"))
            guard openSheet(app), again.firstMatch.waitForExistence(timeout: 5) else {
                closeSheet(app)
                print("UI_STEP_MISSING \(what): no \"Neu prüfen\" in the sheet \"Analyse\"")
                XCTFail("\(what): no \"Neu prüfen\" in the sheet \"Analyse\"", file: file, line: line)
                return false
            }
            reachable(again).tap()
            print("UI_STEP_OK \(what)")
            _ = UITestWait.holds(timeout: 5) { !app.buttons["analysis.summary.done"].exists }
            return true
        }
    }

    // MARK: Trial year

    /// The trial year chosen in the settings ("Albumist arbeitet nur mit Fotos aus 2026") and
    /// the way back to the whole library.
    @MainActor
    enum TrialYear {
        /// The words of the button that takes in every year: "Alle Jahre" beside the overview's
        /// note where that fits in one line, "Ganze Mediathek dazunehmen" under it where it does
        /// not (`trialNote`, a `ViewThatFits`), and on the card for an empty trial year
        /// (`EmptyLibraryCard`). Design wave 1's ring card is narrower: on the iPhone 18 Pro the
        /// note shows the long words (UI run 44852630315). `UITestHelperSourceTests` keeps the
        /// list in step with the app.
        static let allYearsWords = ["Alle Jahre", "Ganze Mediathek dazunehmen"]

        /// The button that takes in every year, in whichever words the screen shows it.
        static func allYearsButton(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label IN %@", allYearsWords)).firstMatch
        }

        /// A trial year is on: the overview's note (`analysis.trial`), or the card of a trial year
        /// without photos ("Keine Fotos aus 2026"), which says it and offers the whole library
        /// itself while the note stays away (`EmptyLibraryState.offersAllYears`). The demo library
        /// has no photos of the current year, so test6 sees the card.
        static func shown(_ app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "analysis.trial", "Keine Fotos aus "))
                .firstMatch
        }
    }
}

/// Beside `Analysis` rather than in it (SwiftLint's nesting).
extension UITestScreens.Analysis {
    /// What the start page and the sheet "Analyse" say about the photos.
    struct Counts {
        /// What was read: the line ("Alle 246 Fotos analysiert, …") or the sheet's headline
        /// ("58 von 246 Fotos analysiert").
        let label: String
        let analyzed: Int
        let photos: Int
        /// "12 Fotos konnten noch nicht gelesen werden", 0 without the note.
        let unreadable: Int
        /// How the image requests ended (the line's or the headline's value in UI runs).
        let loads: String
        /// The line or the sheet was there but could not be read: never taken as complete.
        var readFailed = false

        /// Photos the analysis never came to; unreadable ones it tried and keeps for later.
        var cutOff: Bool { readFailed || analyzed + unreadable < photos }
        /// Every photo analysed, none left unreadable.
        var complete: Bool { !readFailed && analyzed >= photos && unreadable == 0 }

        var unreadableText: String {
            "\(unreadable) of \(photos) photos could not be read ('\(label)', \(loads))"
        }
    }
}
