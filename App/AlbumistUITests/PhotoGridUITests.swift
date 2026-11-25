import XCTest
import UIKit

/// The shared photo grid of design wave 3 (DS-21 "Unsortiert" by day, DS-06b drag to select and
/// pinch to zoom): while "Auswählen" is on, a finger drawn sideways ticks every photo from the
/// first it touched to the one under it, across rows and days, and a drag that starts on a
/// ticked photo takes the ticks away; a vertical swipe scrolls and ticks nothing; a tap right
/// after a drag ticks; from the left screen edge a suggestion's page goes back. Two fingers
/// show three, five or seven photos in a row, one step per pinch, keep the photo under them
/// also after the page was out of sight, show the same size in a suggestion's photos, and
/// three again after a relaunch (a UI run starts at the standard size, `PhotoGridMemory`).
/// Each test brings the app to an onboarded, analysed demo library with every year taken in by
/// itself; in CI the class runs in the group flow-other (.github/ui-groups.json). Log
/// conventions as in AlbumistFlowUITests: `UI_STEP_OK` / `UI_STEP_MISSING`, `UI_FACT`,
/// screenshots as `PREVIEW_JPEG ui-grid-…` chunks.
@MainActor
final class PhotoGridUITests: XCTestCase {
    var app = XCUIApplication()

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
    func tabButton(_ name: String) -> XCUIElement {
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
    func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
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

    func shot(_ name: String) {
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

    /// A photo of a grid as one snapshot saw it; its label is when it was taken (to the minute).
    struct Seen {
        var frame: CGRect
        var selected: Bool
        var label: String
    }

    /// The photos `identifier` in the grid's order (depth first, as they lie in the grid), from
    /// one snapshot of the app: each property of an element asks the app again. A loop, not a
    /// nested function: the snapshot's attributes belong to the main actor (`UITestWait.frames`).
    func photos(_ identifier: String) -> [Seen] {
        guard let root = try? app.snapshot() else { return [] }
        var found: [Seen] = []
        var stack: [any XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            if node.elementType == .button, node.identifier == identifier {
                found.append(Seen(frame: node.frame, selected: node.isSelected, label: node.label))
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    /// Photos in a row, from the side of one: the grid fills the window's width with 2 pt
    /// between its photos (`PhotoGridZoom.side`).
    func columns(_ side: CGFloat) -> Int {
        guard side > 0 else { return 0 }
        return Int(((app.windows.firstMatch.frame.width + 2) / (side + 2)).rounded())
    }

    /// A finger on the screen from `start` to `end`: a short touch, then a slow straight drag,
    /// held a moment at the end (the page may scroll on near an edge).
    func drag(from start: CGPoint, to end: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x, dy: start.y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// A finger from the left screen edge (x = 0) at height `y`, drawn quickly to the right over
    /// four fifths of the window: the swipe back of a pushed page.
    func swipeFromLeftEdge(at y: CGFloat) {
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
    func calmRow(_ identifier: String) -> [CGRect] {
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
    func openSuggestion(_ test: String) -> Bool {
        guard let card = UITestScreens.Cards.first(app, swipes: 6, timeout: 10),
              UITestScreens.Cards.open(card, in: app, "\(test): a suggestion's page") else { return false }
        return UITestWait.until("\(test): the suggestion's page", timeout: 10) { UITestScreens.SuggestionPage.isShown(app) }
    }

    /// "N ausgewählt" in the bottom bar.
    func selectedCount(_ count: Int) -> XCUIElement {
        app.staticTexts["\(count) ausgewählt"]
    }

    /// Away to the tab "Vorschläge" for a moment and back to "Unsortiert": the page still finds its
    /// photos under the finger after it was out of sight (a tab switch hides it and shows it again
    /// without building its photos anew).
    private func leaveTabAndComeBack(_ test: String, waitingFor photo: XCUIElement) {
        let suggestions = UITestScreens.Tabs.german.suggestions
        let unsorted = UITestScreens.Tabs.german.unsorted
        if tap(tabButton(suggestions), "\(test): tab \(suggestions) for a moment") {
            UITestWait.until("\(test): tab \(suggestions) shown", timeout: 5) { app.tabBars.buttons[suggestions].isSelected }
            tap(tabButton(unsorted), "\(test): back to \(unsorted)")
            UITestWait.appears(photo, "\(test): its photos again", timeout: 10)
        }
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
        // Away and back first (`leaveTabAndComeBack`).
        leaveTabAndComeBack(test, waitingFor: app.buttons.matching(identifier: "library.photo").firstMatch)
        guard tap(app.buttons["Auswählen"], "\(test): Auswählen") else { return }
        UITestWait.appears(app.buttons["Fertig"], "\(test): selecting", timeout: 5)
        UITestWait.appears(selectedCount(0), "\(test): 0 ausgewählt", timeout: 5)
        guard let span = dragRange(test) else { return }
        let ticked = dragOverTheRange(span, test)
        guard untickAlongTheLastRow(span, ticked: ticked, test) else { return }

        // A vertical swipe scrolls; the ticks stay as they are.
        app.swipeUp(velocity: .slow)
        UITestWait.never("\(test): the count stays at \(ticked - 3) after a vertical swipe", for: 1) { !selectedCount(ticked - 3).exists }
        app.swipeDown(velocity: .slow)
        tap(app.buttons["Fertig"], "\(test): Fertig")
    }

    // MARK: 2 Pinch to zoom

    /// Two fingers change how many photos a row shows, one step per pinch: three, then five and
    /// seven when they pinch, five again when they spread. On a page a few screens down that was
    /// out of sight (another tab, and back) the photo under the fingers stays under them, right
    /// after the step and a second later (review W5 of H10: the page finds its photos again, L1,
    /// and the step lands without a jump, L6); a photo among the page's first rows fails the test
    /// (review Y5: at the top the scroll view cannot keep it). A suggestion's photos show the same
    /// size (one for both grids), and a relaunch of a UI run starts at three again.
    func test2_TwoFingersShowThreeFiveOrSevenInARow() {
        continueAfterFailure = true
        let test = "PhotoGridUITests.test2"
        prepare(test)
        guard let photos = openUnsorted(test) else { return }
        guard rowShowsPhotos(3, "at the start", photos, test) else { return }
        // A few screens down, then back by about one, so the page is away from its top and from
        // its end (at either the scroll view cannot keep a photo in place when the rows get
        // smaller, review Y5); then away to another tab and back, which shows the page again
        // without building its photos anew.
        let firstRows = photosAtTheTop(test)
        for _ in 0..<3 { app.swipeUp() }
        for _ in 0..<2 { app.swipeDown(velocity: .slow) }
        UITestWait.screenAtRest(app, "\(test): the page at rest a few screens down")
        print("UI_FACT \(test): the first photo on screen a few screens down: '\(firstPhotoOnScreen())'")
        leaveTabAndComeBack(test, waitingFor: photos.firstMatch)
        let held = pinchNearestPhoto(0.75, "to five", photos, test)
        XCTAssertTrue(rowShowsPhotos(5, "after one pinch", photos, test), "\(test): one pinch does not show five photos in a row")
        if let held, isBelow(firstRows, held, test) { pinchedPhotoKeepsItsPlace(held, "after the page was away", test) }
        shot("pg-02-five")
        _ = pinchNearestPhoto(0.75, "to seven", photos, test)
        XCTAssertTrue(rowShowsPhotos(7, "after a second pinch", photos, test),
                      "\(test): a second pinch does not show seven photos in a row")
        shot("pg-03-seven")
        _ = pinchNearestPhoto(1.4, "back to five", photos, test)
        XCTAssertTrue(rowShowsPhotos(5, "after spreading", photos, test),
                      "\(test): spreading two fingers does not go back to five photos in a row")

        // A suggestion's photos: the same grid, at the same size.
        suggestionShowsFiveInARow(test)

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
        guard let edgeSwipeGoesBack = edgeSwipeControl(test) else { return }

        guard tap(UITestScreens.SuggestionPage.selectPhotos(app), "\(test): Auswählen", timeout: 5),
              UITestWait.appears(UITestScreens.SuggestionPage.endSelection(app), "\(test): selecting", timeout: 5) else { return }
        guard UITestScreens.SuggestionPage.photoInReach(app) != nil else {
            shot("x-no-suggestion-photo")
            XCTFail("\(test): no photo of the suggestion came clear of the bars")
            return
        }
        // A row of photos well away from the bars, dragged over from the middle of its first one.
        guard let start = dragAlongACalmRow(test) else { return }

        // From the left screen edge over the same row: the swipe back, not the drag to select.
        guard edgeSwipeGoesBack else {
            print("UI_FACT \(test): the swipe back while selecting is not tried: the control did not go back")
            return
        }
        swipeBackFromTheEdge(at: start.midY, test)
    }
}
