import XCTest
import UIKit

/// The shared photo grid of design wave 3 (DS-21 "Unsortiert" by day, DS-06b drag to select and
/// pinch to zoom): while "Auswählen" is on, a finger drawn sideways ticks every photo from the
/// first it touched to the one under it, across rows and days, and a drag that starts on a
/// ticked photo takes the ticks away; a vertical swipe scrolls and ticks nothing. Two fingers
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

    /// "N ausgewählt" in the bottom bar.
    private func selectedCount(_ count: Int) -> XCUIElement {
        app.staticTexts["\(count) ausgewählt"]
    }

    // MARK: 1 Drag to select

    /// While "Auswählen" is on, a finger drawn sideways from the first photo on screen to a photo
    /// of a later row, two or more to the right, ticks every photo between them in the grid's
    /// order (across rows and days), the first and the last too. A second drag along the row of
    /// that last photo, from its first photo two to the right, starts on a ticked photo and so
    /// takes those three ticks away. A vertical swipe scrolls and changes nothing.
    func test1_DragTicksARangeAcrossRowsAndDays() {
        continueAfterFailure = true
        let test = "PhotoGridUITests.test1"
        prepare(test)
        guard openUnsorted(test) != nil else { return }
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
        let fromPoint = CGPoint(x: start.minX + start.width * 0.2, y: start.midY)
        func toPoint(_ index: Int) -> CGPoint { CGPoint(x: all[index].minX + all[index].width * 0.8, y: all[index].midY) }
        guard let last = candidates.first(where: { abs(toPoint($0).y - fromPoint.y) < 0.8 * abs(toPoint($0).x - fromPoint.x) }) else {
            shot("x-no-range")
            XCTFail("\(test): no photo of a later row two places to the right on screen: \(all.prefix(24).map { "\(Int($0.minX)),\(Int($0.minY))" })")
            return
        }
        let ticked = last - first + 1
        print("UI_FACT \(test): drag from photo \(first) to photo \(last) (\(ticked) photos)")
        drag(from: fromPoint, to: toPoint(last))
        let counted = UITestWait.until("\(test): \(ticked) ausgewählt after the drag", timeout: 5) { selectedCount(ticked).exists }
        if !counted {
            let shown = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " ausgewählt")).firstMatch
            print("UI_FACT \(test): the bar says '\(shown.exists ? shown.label : "nothing")'")
        }
        // Ticked as the bar says: the range and nothing else on screen (the drag held still at
        // its end, away from the edges, so the page did not scroll).
        let afterDrag = photos("library.photo")
        if afterDrag.count == all.count {
            let wrong = all.indices.filter { onScreen(all[$0]) && afterDrag[$0].selected != (first...last).contains($0) }
            XCTAssertTrue(wrong.isEmpty, "\(test): photos ticked other than \(first) to \(last): \(wrong)")
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
        drag(from: CGPoint(x: all[rowStart].minX + all[rowStart].width * 0.2, y: all[rowStart].midY),
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
}
