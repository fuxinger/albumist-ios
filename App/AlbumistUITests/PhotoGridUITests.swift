import XCTest
import UIKit

/// The shared photo grid of design wave 3 (DS-21 "Unsortiert" by day, DS-06b drag to select and
/// pinch to zoom): while "Auswählen" is on, a finger drawn sideways ticks every photo from the
/// first it touched to the one under it, across rows and days, and a drag that starts on a
/// ticked photo takes the ticks away; a vertical swipe scrolls and ticks nothing; a tap right
/// after a drag ticks; from the left screen edge a suggestion's page goes back. Two fingers
/// show three, five or seven photos in a row, one step per pinch, the same size in a
/// suggestion's photos, and three again after a relaunch (a UI run starts at the standard
/// size, `PhotoGridMemory`). Each test brings the app to an onboarded, analysed demo library
/// with every year taken in by itself; in CI the class runs in the group flow-other
/// (.github/ui-groups.json). Log conventions as in AlbumistFlowUITests: `UI_STEP_OK` /
/// `UI_STEP_MISSING`, `UI_FACT`, screenshots as `PREVIEW_JPEG ui-grid-…` chunks.
@MainActor
final class PhotoGridUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers

    private func launch() {
        // UITestAppEnd.launch ends the app of the last launch first.
        app = XCUIApplication()
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked"]
            + UITestStalls.arguments(besides: [])
        UITestAppEnd.launch(app)
    }

    /// An onboarded demo library whose analysis is done (made here when no test before made
    /// it), with every year taken in: a trial year left on by a test before shows nothing in
    /// "Unsortiert" ("Alles sortiert", the demo library has no photos of this year).
    private func prepare(_ test: String) {
        launch()
        UITestOnboarding.completeIfNeeded(app, in: test)
        let idle = UITestWait.holds(timeout: 120) { UITestScreens.Analysis.isIdle(app) }
        print(idle ? "UI_STEP_OK \(test): start page at rest" : "UI_STEP_MISSING \(test): start page at rest")
        XCTAssertTrue(idle, "\(test): the start page does not come to rest (the analysis still runs or waits)")
        let trialYear = UITestScreens.TrialYear.shown(app)
        if trialYear.exists, tap(UITestScreens.TrialYear.allYearsButton(app), "\(test): take in all years", timeout: 5) {
            print("UI_FACT \(test): a trial year was still on: all years taken in")
            UITestWait.disappears(trialYear, "\(test): trial year gone", timeout: 20)
            UITestWait.until("\(test): analysis at rest after all years", timeout: 300) { UITestScreens.Analysis.isIdle(app) }
        }
    }

    /// A tab bar button; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            // The bar expands after the swipe: on as soon as the button can be tapped.
            _ = UITestWait.holds(timeout: 1) { button.exists && button.isHittable }
            tries += 1
        }
        return button
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: ""))
            XCTFail("Missing: \(step)")
            return false
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "grid-" + name
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
            print("PREVIEW_JPEG ui-grid-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    /// The tab "Unsortiert" with its photos (`library.photo`) once its days are made: the
    /// filter "Unsortiert", or "Unsicher" when everything is sorted. Nil when neither shows a
    /// photo.
    private func openUnsorted(_ test: String) -> XCUIElementQuery? {
        let title = UITestScreens.Tabs.german.unsorted
        guard tap(tabButton(title), "\(test): tab \(title)") else { return nil }
        let preparing = app.descendants(matching: .any).matching(identifier: "library.preparing").firstMatch
        UITestWait.disappears(preparing, "\(test): the days of \(title) made", timeout: 60)
        let photos = app.buttons.matching(identifier: "library.photo")
        if !photos.firstMatch.waitForExistence(timeout: 10) {
            print("UI_FACT \(test): nothing in the filter \(title): the uncertain photos instead")
            UITestScreens.Unsorted.show(app, "uncertain", named: "Unsicher", "\(test): uncertain photos")
            UITestWait.disappears(preparing, "\(test): the days of Unsicher made", timeout: 60)
        }
        guard UITestWait.appears(photos.firstMatch, "\(test): photos in \(title)", timeout: 15) else {
            shot("x-no-photos")
            return nil
        }
        return photos
    }

    /// A photo of a grid as one snapshot saw it.
    private struct Seen {
        var frame: CGRect
        var selected: Bool
    }

    /// The photos `identifier` in the grid's order (depth first, as they lie in the grid), from
    /// one snapshot of the app: each property of an element asks the app again. A loop, not a
    /// nested function: the snapshot's attributes belong to the main actor (`UITestWait.frames`).
    private func photos(_ identifier: String) -> [Seen] {
        guard let root = try? app.snapshot() else { return [] }
        var found: [Seen] = []
        var stack: [any XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            if node.elementType == .button, node.identifier == identifier {
                found.append(Seen(frame: node.frame, selected: node.isSelected))
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    /// Photos in a row, from the side of one: the grid fills the window's width with 2 pt
    /// between its photos (`PhotoGridZoom.side`).
    private func columns(_ side: CGFloat) -> Int {
        guard side > 0 else { return 0 }
        return Int(((app.windows.firstMatch.frame.width + 2) / (side + 2)).rounded())
    }

    /// A finger on the screen from `start` to `end`: a short touch, then a slow straight drag,
    /// held a moment at the end (the page may scroll on near an edge).
    private func drag(from start: CGPoint, to end: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x, dy: start.y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// A finger from the left screen edge (x = 0) at height `y`, drawn quickly to the right over
    /// four fifths of the window: the swipe back of a pushed page.
    private func swipeFromLeftEdge(at y: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let width = app.windows.firstMatch.frame.width
        origin.withOffset(CGVector(dx: 0, dy: y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: width * 0.8, dy: y)),
                   withVelocity: .default, thenHoldForDuration: 0)
    }

    /// A row of two or more photos `identifier` well away from the bars, from the left, as one
    /// snapshot saw it; up to three slow swipes up to find one. Within 72 pt of the bars the
    /// page scrolls on by itself under a held finger, which would tick more. Below, the lowest
    /// of a bottom bar and a suggestion's own bar counts. Empty when there is none.
    private func calmRow(_ identifier: String) -> [CGRect] {
        let calm = 90.0
        let window = app.windows.firstMatch.frame
        var row: [CGRect] = []
        for swipe in 0...3 {
            if swipe > 0 { app.swipeUp(velocity: .slow) }
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
            let bars = [app.toolbars.firstMatch, UITestScreens.SuggestionPage.bar(app)]
                .filter { $0.exists && $0.frame.minY > window.midY }.map(\.frame.minY)
            let bottom = bars.min() ?? window.maxY - 90
            let all = photos(identifier).map(\.frame)
            if let first = all.first(where: { $0.midY >= top + calm && $0.midY <= bottom - calm }) {
                row = all.filter { abs($0.minY - first.minY) < 1 }.sorted { $0.minX < $1.minX }
            }
            if row.count >= 2 { break }
        }
        return row.count >= 2 ? row : []
    }

    /// The first suggestion's page, from the list of the tab "Vorschläge" shown.
    private func openSuggestion(_ test: String) -> Bool {
        guard let card = UITestScreens.Cards.first(app, swipes: 6, timeout: 10),
              UITestScreens.Cards.open(card, in: app, "\(test): a suggestion's page") else { return false }
        return UITestWait.until("\(test): the suggestion's page", timeout: 10) { UITestScreens.SuggestionPage.isShown(app) }
    }

    /// "N ausgewählt" in the bottom bar.
    private func selectedCount(_ count: Int) -> XCUIElement {
        app.staticTexts["\(count) ausgewählt"]
    }

    // MARK: 1 Drag to select

    /// After the tab was left and shown again, and while "Auswählen" is on, a finger drawn
    /// sideways from the first photo on screen to a photo of a later row, two or more to the
    /// right, ticks every photo between them in the grid's order (across rows and days), the
    /// first and the last too. A second drag along the row of
    /// that last photo, from its first photo two to the right, starts on a ticked photo and so
    /// takes those three ticks away. A vertical swipe scrolls and changes nothing.
    func test1_DragTicksARangeAcrossRowsAndDays() {
        continueAfterFailure = true
        let test = "PhotoGridUITests.test1"
        prepare(test)
        guard openUnsorted(test) != nil else { return }
        // Away and back first: the page still finds its photos under the finger after it was out
        // of sight (a tab switch hides it and shows it again without building its photos anew).
        let suggestions = UITestScreens.Tabs.german.suggestions
        let unsorted = UITestScreens.Tabs.german.unsorted
        if tap(tabButton(suggestions), "\(test): tab \(suggestions) for a moment") {
            UITestWait.until("\(test): tab \(suggestions) shown", timeout: 5) { app.tabBars.buttons[suggestions].isSelected }
            tap(tabButton(unsorted), "\(test): back to \(unsorted)")
            UITestWait.appears(app.buttons.matching(identifier: "library.photo").firstMatch, "\(test): its photos again", timeout: 10)
        }
        guard tap(app.buttons["Auswählen"], "\(test): Auswählen") else { return }
        UITestWait.appears(app.buttons["Fertig"], "\(test): selecting", timeout: 5)
        UITestWait.appears(selectedCount(0), "\(test): 0 ausgewählt", timeout: 5)

        // What is on screen: below the navigation bar, above the bottom bar.
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
        let window = app.windows.firstMatch.frame
        let bar = app.toolbars.firstMatch
        let bottom = bar.exists && bar.frame.minY > window.midY ? bar.frame.minY : window.maxY - 90
        let all = photos("library.photo").map(\.frame)
        print("UI_FACT \(test): \(all.count) photos built, first \(all.first.map { "\($0)" } ?? "none")")
        func onScreen(_ frame: CGRect) -> Bool { frame.minY >= top + 4 && frame.maxY <= bottom - 4 }
        // The finger starts and ends well away from the bars: within 72 pt of them the page
        // scrolls on by itself (`PhotoGridAutoScroll`), which would tick more.
        let calm = 90.0
        let leading = all.map(\.minX).min() ?? 0
        guard let first = all.indices.first(where: {
            onScreen(all[$0]) && abs(all[$0].minX - leading) < 1 && all[$0].midY >= top + calm
        }) else {
            shot("x-no-photo-on-screen")
            XCTFail("\(test): no first photo of a row of \"Unsortiert\" on screen (bars at \(top) and \(bottom))")
            return
        }
        let start = all[first]
        // A photo of a later row two or more places to the right, close enough below that the
        // line to it is mostly sideways (the drag only selects when it starts sideways).
        let candidates = all.indices.filter { index in
            let frame = all[index]
            return index > first && onScreen(frame) && frame.midY <= bottom - calm
                && frame.minY >= start.maxY && frame.minX >= start.minX + 1.5 * start.width
        }
        // In the middle of the first photo, well away from the screen's left edge (review W6).
        let fromPoint = CGPoint(x: start.minX + start.width * 0.5, y: start.midY)
        func toPoint(_ index: Int) -> CGPoint { CGPoint(x: all[index].minX + all[index].width * 0.8, y: all[index].midY) }
        guard let last = candidates.first(where: { abs(toPoint($0).y - fromPoint.y) < 0.8 * abs(toPoint($0).x - fromPoint.x) }) else {
            shot("x-no-range")
            XCTFail("\(test): no photo of a later row two places to the right on screen: \(all.prefix(24).map { "\(Int($0.minX)),\(Int($0.minY))" })")
            return
        }
        let range = last - first + 1
        print("UI_FACT \(test): drag from photo \(first) to photo \(last) (\(range) photos)")
        // The photo after the range, tapped as soon as the finger is up: a tap right after a drag
        // ticks (review L8 of H10: a time window after the drag swallowed it). Its point is worked
        // out before the drag, so the tap follows without asking the app again.
        let next = last + 1 < all.count && onScreen(all[last + 1]) ? last + 1 : nil
        let origin = app.coordinate(withNormalizedOffset: .zero)
        drag(from: fromPoint, to: toPoint(last))
        if let next {
            origin.withOffset(CGVector(dx: all[next].midX, dy: all[next].midY)).tap()
            print("UI_STEP_OK \(test): tap photo \(next) right after the drag")
        } else {
            print("UI_FACT \(test): no photo after the range on screen: no tap right after the drag")
        }
        let ticked = range + (next == nil ? 0 : 1)
        let counted = UITestWait.until("\(test): \(ticked) ausgewählt after the drag", timeout: 5) { selectedCount(ticked).exists }
        if !counted {
            let shown = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " ausgewählt")).firstMatch
            print("UI_FACT \(test): the bar says '\(shown.exists ? shown.label : "nothing")'")
        }
        // Ticked as the bar says: the range and nothing else on screen (the drag held still at
        // its end, away from the edges, so the page did not scroll).
        let afterDrag = photos("library.photo")
        if afterDrag.count == all.count {
            let wrong = all.indices.filter {
                onScreen(all[$0]) && afterDrag[$0].selected != ((first...last).contains($0) || $0 == next)
            }
            XCTAssertTrue(wrong.isEmpty, "\(test): photos ticked other than \(first) to \(last)\(next.map { " and \($0)" } ?? ""): \(wrong)")
        } else {
            print("UI_FACT \(test): \(afterDrag.count) photos built after the drag, \(all.count) before: ticks not compared")
        }
        shot("pg-01-drag")

        // Along the last photo's row, from its first photo two to the right: all three ticked,
        // so the drag takes their ticks away.
        guard let rowStart = all.indices.first(where: { $0 >= first && abs(all[$0].minY - all[last].minY) < 1 }),
              rowStart + 2 <= last else {
            XCTFail("\(test): the row of photo \(last) has no first photo in the range")
            return
        }
        let rowEnd = rowStart + 2
        drag(from: CGPoint(x: all[rowStart].minX + all[rowStart].width * 0.5, y: all[rowStart].midY),
             to: CGPoint(x: all[rowEnd].minX + all[rowEnd].width * 0.8, y: all[rowEnd].midY))
        UITestWait.until("\(test): \(ticked - 3) ausgewählt after dragging back over three", timeout: 5) { selectedCount(ticked - 3).exists }
        let afterUntick = photos("library.photo")
        if afterUntick.count > rowEnd {
            XCTAssertFalse((rowStart...rowEnd).contains { afterUntick[$0].selected }, "\(test): a photo of the second drag is still ticked")
        }
        shot("pg-01b-untick")

        // A vertical swipe scrolls; the ticks stay as they are.
        app.swipeUp(velocity: .slow)
        UITestWait.never("\(test): the count changes after a vertical swipe", for: 1) { !selectedCount(ticked - 3).exists }
        app.swipeDown(velocity: .slow)
        tap(app.buttons["Fertig"], "\(test): Fertig")
    }

    // MARK: 2 Pinch to zoom

    /// Two fingers change how many photos a row shows, one step per pinch: three, then five and
    /// seven when they pinch, five again when they spread. A suggestion's photos show the same
    /// size (one for both grids), and a relaunch of a UI run starts at three again.
    func test2_TwoFingersShowThreeFiveOrSevenInARow() {
        continueAfterFailure = true
        let test = "PhotoGridUITests.test2"
        prepare(test)
        guard let photos = openUnsorted(test) else { return }
        func shown(_ wanted: Int, _ what: String) -> Bool {
            let met = UITestWait.until("\(test): \(wanted) in a row \(what)", timeout: 8) {
                photos.firstMatch.exists && columns(photos.firstMatch.frame.width) == wanted
            }
            if !met { print("UI_FACT \(test): \(what): a photo is \(photos.firstMatch.frame.width) pt wide") }
            return met
        }
        guard shown(3, "at the start") else { return }
        // Two fingers on the photo nearest the middle of the screen (the grid, not its bars). The
        // element is the one the snapshot saw there: checked by its frame, else the first photo
        // of the query that lies in the middle third of the screen.
        func pinch(_ scale: CGFloat, _ what: String) {
            let window = app.windows.firstMatch.frame
            let all = self.photos("library.photo").map(\.frame)
            guard let nearest = all.indices.min(by: { abs(all[$0].midY - window.midY) < abs(all[$1].midY - window.midY) }) else {
                XCTFail("\(test): no photo to pinch (\(what))")
                return
            }
            var target = photos.element(boundBy: nearest)
            if target.frame != all[nearest],
               let middle = (0..<min(photos.count, 40)).lazy.map({ photos.element(boundBy: $0) }).first(where: {
                   abs($0.frame.midY - window.midY) < window.height / 6
               }) {
                target = middle
            }
            print("UI_STEP_OK \(test): pinch \(scale) on the photo at \(Int(target.frame.minX)),\(Int(target.frame.minY)) (\(what))")
            target.pinch(withScale: scale, velocity: scale < 1 ? -1 : 1)
        }
        pinch(0.75, "to five")
        XCTAssertTrue(shown(5, "after one pinch"), "\(test): one pinch does not show five photos in a row")
        shot("pg-02-five")
        pinch(0.75, "to seven")
        XCTAssertTrue(shown(7, "after a second pinch"), "\(test): a second pinch does not show seven photos in a row")
        shot("pg-03-seven")
        pinch(1.4, "back to five")
        XCTAssertTrue(shown(5, "after spreading"), "\(test): spreading two fingers does not go back to five photos in a row")

        // A suggestion's photos: the same grid, at the same size.
        if tap(tabButton(UITestScreens.Tabs.german.suggestions), "\(test): tab Vorschläge"),
           let card = UITestScreens.Cards.first(app, swipes: 6, timeout: 10),
           UITestScreens.Cards.open(card, in: app, "\(test): a suggestion's page"),
           UITestWait.until("\(test): the suggestion's page", timeout: 10, { UITestScreens.SuggestionPage.isShown(app) }) {
            if let photo = UITestScreens.SuggestionPage.photoInReach(app) {
                let inRow = columns(photo.frame.width)
                print("UI_FACT \(test): a suggestion's photos: \(inRow) in a row (\(photo.frame.width) pt)")
                XCTAssertEqual(inRow, 5, "\(test): a suggestion's photos do not show the size chosen in \"Unsortiert\"")
                shot("pg-04-suggestion-five")
            } else {
                XCTFail("\(test): no photo of the suggestion's page in reach")
            }
        }

        // A UI run starts at the standard size again.
        launch()
        guard let again = openUnsorted(test + " after a relaunch") else { return }
        let restarted = UITestWait.until("\(test): 3 in a row after a relaunch", timeout: 8) {
            again.firstMatch.exists && columns(again.firstMatch.frame.width) == 3
        }
        XCTAssertTrue(restarted, "\(test): a relaunch of a UI run does not start at three photos in a row")
    }

    // MARK: 3 Back from the left edge while selecting

    /// On a suggestion's page while "Auswählen" is on, a finger drawn sideways along a row of
    /// photos ticks them and the page stays; a finger from the left screen edge, at the height of
    /// that row, goes back to the suggestions (review L7 of H10: the drag to select took the swipe
    /// back away from the edge). First the control (review of H10's round 2): the same finger
    /// before "Auswählen" goes back too, else the simulator's touch at the edge is no edge swipe
    /// and the test says so, instead of a red result that could be either; then the page is
    /// opened again.
    func test3_FromTheLeftEdgeASuggestionsPageGoesBackWhileSelecting() {
        continueAfterFailure = true
        let test = "PhotoGridUITests.test3"
        prepare(test)
        let suggestions = UITestScreens.Tabs.german.suggestions
        guard tap(tabButton(suggestions), "\(test): tab \(suggestions)"), openSuggestion(test) else {
            shot("x-no-suggestion-page")
            XCTFail("\(test): no suggestion's page to select on")
            return
        }

        // The control: the same finger from the left edge, over a row of photos, before "Auswählen".
        let controlY = calmRow("proposalPhotos.photo").first?.midY ?? app.windows.firstMatch.frame.midY
        swipeFromLeftEdge(at: controlY)
        print("UI_STEP_OK \(test): finger from the left edge at y \(Int(controlY)) before Auswählen (the control)")
        let edgeSwipeGoesBack = UITestWait.holds(timeout: 5) { !UITestScreens.SuggestionPage.isShown(app) }
        if edgeSwipeGoesBack {
            print("UI_STEP_OK \(test): the control went back to the suggestions")
            guard openSuggestion(test + " again") else {
                shot("x-no-suggestion-page-again")
                XCTFail("\(test): the suggestion's page does not open again after the control")
                return
            }
        } else {
            print("UI_FACT \(test): the control stayed on the suggestion's page: the simulator's swipe from x = 0 was no edge swipe")
            shot("x-control-stayed")
            XCTFail("\(test): the simulator's swipe from the left edge was no edge swipe: the page stayed before "
                    + "Auswählen too, so the swipe while selecting is not tried and says nothing about the app")
        }

        guard tap(UITestScreens.SuggestionPage.selectPhotos(app), "\(test): Auswählen", timeout: 5),
              UITestWait.appears(UITestScreens.SuggestionPage.endSelection(app), "\(test): selecting", timeout: 5) else { return }
        guard UITestScreens.SuggestionPage.photoInReach(app) != nil else {
            shot("x-no-suggestion-photo")
            XCTFail("\(test): no photo of the suggestion came clear of the bars")
            return
        }

        // A row of photos well away from the bars, dragged over from the middle of its first one.
        let row = calmRow("proposalPhotos.photo")
        guard let start = row.first, let end = row.last else {
            shot("x-no-row-to-drag")
            XCTFail("\(test): no row of two or more photos of the suggestion away from the bars")
            return
        }
        print("UI_FACT \(test): a row of \(row.count) photos at y \(Int(start.midY))")
        drag(from: CGPoint(x: start.minX + start.width * 0.5, y: start.midY),
             to: CGPoint(x: end.minX + end.width * 0.8, y: end.midY))
        let remove = app.buttons["proposalPhotos.remove"]
        let ticked = UITestWait.until("\(test): \(row.count) photos ticked by the sideways drag", timeout: 5) {
            remove.exists && remove.label.hasPrefix("\(row.count) ")
        }
        if !ticked { print("UI_FACT \(test): the bottom bar says '\(remove.exists ? remove.label : "nothing")'") }
        XCTAssertTrue(UITestScreens.SuggestionPage.isShown(app), "\(test): a sideways drag over the photos left the suggestion's page")
        shot("pg-05-suggestion-drag")

        // From the left screen edge over the same row: the swipe back, not the drag to select.
        guard edgeSwipeGoesBack else {
            print("UI_FACT \(test): the swipe back while selecting is not tried: the control did not go back")
            return
        }
        swipeFromLeftEdge(at: start.midY)
        print("UI_STEP_OK \(test): finger from the left edge at y \(Int(start.midY))")
        let back = UITestWait.until("\(test): back from the suggestion's page", timeout: 5) {
            !UITestScreens.SuggestionPage.isShown(app)
        }
        if !back {
            print("UI_FACT \(test): the page stayed; the bottom bar says '\(remove.exists ? remove.label : "nothing")'")
            shot("x-edge-swipe-stayed")
            return
        }
        let listed = UITestWait.holds(timeout: 5) {
            UITestScreens.Cards.cards(app).firstMatch.exists || app.tabBars.buttons[suggestions].isSelected
        }
        print("UI_FACT \(test): after the swipe back the suggestions show: \(listed)")
        XCTAssertTrue(listed, "\(test): the swipe back from the edge did not lead to the suggestions")
        shot("pg-06-edge-back")
    }
}
