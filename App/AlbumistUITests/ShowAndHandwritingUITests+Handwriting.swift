import XCTest
import UIKit

/// The "Handschrift" half of `ShowAndHandwritingUITests` (DS-11): a suggestion's page in its
/// cover's calm colour, light and dark, and the app's icon with its name in Settings › "Über".
/// An extension of the same class, so its tests run in the same UI group, in the same order.
@MainActor
extension ShowAndHandwritingUITests {
    // MARK: The page's own colour (DS-11)

    /// iOS's grouped background (`Theme.background`), the page's ground without a tint, in sRGB:
    /// #F2F2F7 in light mode, black in dark mode.
    private static func neutralGround(dark: Bool) -> [Int] {
        dark ? [0, 0, 0] : [242, 242, 247]
    }

    /// The page's colour as the core makes it (verification review V9): pale in light mode, each
    /// channel at least 215, and deep in dark mode, each at most 80 (every tint keeps well inside,
    /// about 228 and 27 at the extremes: `PhotoTintTests.everyTintIsPaleInLightAndDeepInDark`).
    /// The pale tint shown in dark mode is not.
    private static func isCalmGround(_ colour: [Int], dark: Bool) -> Bool {
        dark ? colour.allSatisfy { $0 <= 80 } : colour.allSatisfy { $0 >= 215 }
    }

    /// The colour of the screen at `point` (in points), in sRGB 0–255, the mean of 3 × 3 pixels
    /// of a new screenshot. Nil when it cannot be read.
    private func pixel(at point: CGPoint) -> [Int]? {
        let width = app.frame.width
        guard width > 0, let image = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let scale = CGFloat(image.width) / width
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 1, y >= 1, x + 2 <= image.width, y + 2 <= image.height,
              let crop = image.cropping(to: CGRect(x: x - 1, y: y - 1, width: 3, height: 3)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 3 * 3 * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            return true
        }
        guard drawn else { return nil }
        return (0..<3).map { channel in stride(from: channel, to: bytes.count, by: 4).map { Int(bytes[$0]) }.reduce(0, +) / 9 }
    }

    /// The open suggestion page's ground beside its facts line ("16 Fotos · 12. bis 16.
    /// Oktober"), 5 pt from the left edge: left of the header's 16-pt margin, below the cover,
    /// where only the page's ground is. Nil without the line or a picture.
    private func pageGround() -> [Int]? {
        let facts = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos? · .*")).firstMatch
        guard let frame = (try? facts.snapshot())?.frame, !frame.isEmpty else { return nil }
        return pixel(at: CGPoint(x: 5, y: frame.midY))
    }

    /// The open suggestion page's ground took its cover's colour: it differs from the grouped
    /// background (by at least 4 in the three channels together; a pale tint differs by 5 or
    /// more, a picture of the plain background by at most 3) and holds still from one look to
    /// the next (the 0.45 s cross-fade has ended), within 25 s (the reader alone waits up to 6 s
    /// for the cover, and a busy Mac takes longer; verification review V9). Not a failure by
    /// itself: a cover without a colour of its own has no tint. The last colour seen, which the
    /// caller checks for pale or deep (`isCalmGround`).
    private func waitForTint(_ what: String, dark: Bool) -> (tinted: Bool, ground: [Int]?) {
        let neutral = Self.neutralGround(dark: dark)
        var last: [Int]?
        let start = Date()
        let tinted = UITestWait.holds(timeout: 25) {
            guard let now = pageGround() else {
                last = nil
                return false
            }
            defer { last = now }
            let away = zip(now, neutral).map { abs($0 - $1) }.reduce(0, +) >= 4
            let still = last.map { zip($0, now).allSatisfy { abs($0 - $1) <= 1 } } ?? false
            return away && still
        }
        print("UI_TIMING wait \(what): tint \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        return (tinted, last)
    }

    /// Opens a trip's suggestion page whose ground takes its cover's colour (`named`: that trip,
    /// by the album its card names; else the first of the list's first three that does) and
    /// returns its name; nil, with a failure, when none does.
    private func openTintedTrip(_ what: String, dark: Bool, named wanted: String?) -> String? {
        guard UITestScreens.StartPage.openList(app, area: "trips", "\(what): trips") else {
            print("UI_STEP_MISSING \(what): a list of trips")
            XCTFail("\(what): the start page offers no list of suggestions")
            return nil
        }
        let cards = UITestScreens.SuggestionList.cards(app)
        let candidates: [XCUIElement]
        if let wanted, let card = UITestScreens.SuggestionList.card(app, containing: wanted) {
            candidates = [card]
        } else {
            if let wanted { print("UI_FACT \(what): '\(wanted)' is not in the list, another trip instead") }
            candidates = (0..<min(3, cards.count)).map { cards.element(boundBy: $0) }
        }
        var tried: [String] = []
        for card in candidates {
            // Read before the tap: the pushed page takes the list out of the tree.
            let name = UITestScreens.Cards.albumName(of: card) ?? card.buttons["photoCard.body"].label
            guard UITestScreens.Cards.open(card, in: app, "\(what): open '\(name)'") else { continue }
            let page = UITestWait.until("\(what): page of '\(name)' with its facts", timeout: 15) {
                UITestScreens.SuggestionPage.isShown(app) && UITestScreens.SuggestionPage.photoCount(app) != nil
            }
            guard page else { continue }
            let (tinted, ground) = waitForTint(what, dark: dark)
            let colour = ground.map { "rgb(\($0.map(String.init).joined(separator: ", ")))" } ?? "not read"
            if tinted {
                print("UI_STEP_OK \(what): the page of '\(name)' takes its cover's colour, \(colour) (grouped background \(Self.neutralGround(dark: dark)))")
                // Pale in light mode, deep in dark mode: not only away from the plain ground.
                let calm = ground.map { Self.isCalmGround($0, dark: dark) } == true
                let kind = dark ? "deep (each channel at most 80)" : "pale (each channel at least 215)"
                print(calm ? "UI_STEP_OK \(what): \(colour) is \(kind)" : "UI_STEP_MISSING \(what): \(colour) is \(kind)")
                XCTAssertTrue(calm, "\(what): the page of '\(name)' is \(colour), not \(kind)")
                return name
            }
            print("UI_FACT \(what): the page of '\(name)' kept \(colour), no colour of its own")
            tried.append(name)
            back()
            UITestWait.appears(cards.firstMatch, "\(what): back in the list", timeout: 10)
        }
        print("UI_STEP_MISSING \(what): a trip's page in its cover's colour (tried \(tried))")
        shot("x-\(dark ? "dark" : "light")-no-tint")
        XCTFail("\(what): no trip's page took its cover's colour (tried \(tried))")
        return nil
    }

    /// DS-11: a suggestion's page takes its cover's calm colour as its ground, pale in light
    /// mode and deep in dark mode (`PhotoTintGround`), and stays readable: screenshots and the
    /// accessibility audit of the page in both (dark mode as the other tests force it,
    /// `-AlbumistUITestDark`). The colour is read from the screenshot beside the facts line: away
    /// from the grouped background, and pale in light mode (each channel at least 215), deep in
    /// dark mode (each at most 80).
    func test3_SuggestionPageTakesItsCoversCalmColour() {
        continueAfterFailure = true
        prepare("tint light")
        guard let trip = openTintedTrip("tint light", dark: false, named: nil) else { return }
        shot("30x-tint-light")
        audit("suggestion page in its cover's colour, light")

        prepare("tint dark", ["-AlbumistUITestDark"])
        guard openTintedTrip("tint dark", dark: true, named: trip) != nil else { return }
        shot("30y-tint-dark")
        audit("suggestion page in its cover's colour, dark")
    }

    // MARK: Settings › Über

    /// Settings › "Über" starts with the app's icon (the Glass Stack, DS-11: where the app
    /// speaks of itself) and its name, one element for VoiceOver ("Albumist"; the icon is
    /// decorative): the row `settings.about.app`, between the section's title and "Version",
    /// found by its identifier whatever type XCTest gives the combined element, and at least
    /// 48 pt high, the icon's side (verification review V10): without the icon it is a line of
    /// text, lower than that. Only the combined row can carry both the name and the icon's height.
    func test4_SettingsAboutShowsTheAppsIconAndName() {
        continueAfterFailure = true
        prepare("about")
        guard tap(app.buttons["Einstellungen"], "about: settings") else { return }
        UITestWait.appears(app.navigationBars["Einstellungen"], "about: settings open", timeout: 10)
        let version = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Version")).firstMatch
        var swipes = 0
        while !(version.exists && version.isHittable) && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        UITestWait.screenAtRest(app, "about: settings at rest at \"Über\"")
        // One snapshot: the section's title, the app's row and "Version", top to bottom.
        var title: CGRect?, versionRow: CGRect?
        var found: (label: String, frame: CGRect)?
        if let root = try? app.snapshot() {
            var stack: [any XCUIElementSnapshot] = [root]
            while let node = stack.popLast() {
                if node.label.caseInsensitiveCompare("Über") == .orderedSame, title == nil { title = node.frame }
                if node.label == "Version", versionRow == nil { versionRow = node.frame }
                if node.identifier == "settings.about.app", found == nil { found = (node.label, node.frame) }
                stack.append(contentsOf: node.children)
            }
        }
        let titleSeen = title.map { "\($0)" } ?? "missing", versionSeen = versionRow.map { "\($0)" } ?? "missing"
        let rowSeen = found.map { "'\($0.label)' \($0.frame)" } ?? "missing"
        print("UI_FACT about: title \(titleSeen), Version \(versionSeen), the app's row \(rowSeen)")
        shot("80x-settings-about")
        if let row = found {
            let placed = (title.map { row.frame.minY >= $0.maxY - 1 } ?? false) && (versionRow.map { row.frame.maxY <= $0.minY + 1 } ?? false)
            let icon = row.frame.height >= 48
            print(placed && icon && row.label == "Albumist" ? "UI_STEP_OK about: the app's icon and name in \"Über\""
                                                           : "UI_STEP_MISSING about: the app's icon and name in \"Über\"")
            XCTAssertTrue(placed, "The app's row \(row.frame) is not between the title \"Über\" and \"Version\"")
            XCTAssertEqual(row.label, "Albumist", "The app's row says '\(row.label)', not the app's name alone")
            XCTAssertGreaterThanOrEqual(row.frame.height, 48, "The app's row is \(row.frame.height) pt high: no icon of 48 pt beside the name")
        } else {
            print("UI_STEP_MISSING about: the app's row (settings.about.app)")
            XCTFail("Settings › Über has no row settings.about.app")
        }
        tap(app.buttons["Fertig"], "about: close settings", timeout: 5)
    }
}
