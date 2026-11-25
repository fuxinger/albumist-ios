import Foundation
import Testing
import AlbumistTestSupport

/// The UI tests' helpers for the tabs and the search (design wave 3, H14; review S4, S7 and S10
/// of H14), and the sheet check of flow test 6 (review S6), read as source: they build only on
/// a Mac. One `tabButton` for every class (`UITestScreens.tabButton`), which leaves an active
/// search before it looks for a tab and never taps into the bar; `Search.leave` waits for all
/// three named tabs and looks for the way out beside the field first; what iOS shows is printed
/// (`UI_FACT`), so the first run on iOS 27.2 tells what the helpers rest on. They work with
/// every `MainTabs.searchField`: by default choosing the search tab brings no keyboard, and
/// leaving the search is choosing another tab.
@Suite("UI test helpers for the tabs and the search")
struct UITestTabsSourceTests {
    static let folder = "App/AlbumistUITests"
    static let screens = "App/AlbumistUITests/UITestScreens.swift"
    /// Their own copies stay while their own threads of work change these files; neither
    /// searches.
    static let ownCopies: Set<String> = ["App/AlbumistUITests/PhotoGridUITests.swift",
                                         "App/AlbumistUITests/ShowAndHandwritingUITests.swift"]

    /// The code of `path` (comments blanked, strings kept).
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The body of `path` (declarations inside each other) in `UITestScreens.swift`, squeezed.
    static func screensBody(_ path: [String]) throws -> String {
        squeezed(try #require(AppSource.body(of: path, in: try code(screens)), "\(path) is not in UITestScreens.swift"))
    }

    /// Every class asks `UITestScreens.tabButton`: its own `tabButton` only hands the name on
    /// (review S7 of H14: only one of six copies left the search).
    @Test func everyClassTakesTheOneTabButton() throws {
        var classes: [String] = []
        for path in AppSource.swiftFiles(under: Self.folder) where path != Self.screens && !Self.ownCopies.contains(path) {
            guard let body = AppSource.body(of: ["func tabButton(_ name: String) -> XCUIElement"], in: try Self.code(path)) else { continue }
            #expect(Self.squeezed(body) == "{UITestScreens.tabButton(app,name)}", "\(path): \(body)")
            classes.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        #expect(classes.sorted() == ["AccessibilityUITests.swift", "AlbumistFlowUITests.swift", "DeviceConditionUITests.swift",
                                     "FrameUITests.swift", "SearchUITests.swift"], "\(classes.sorted())")
    }

    /// The one `tabButton` leaves the search when its tab is missing or cannot be tapped while a
    /// search field shows (a folded bar, or the keyboard over it; review S4 of H14), then brings
    /// a bar that scrolled away back, and taps nothing itself.
    @Test func theTabButtonLeavesTheSearchFirst() throws {
        let body = try Self.screensBody(["static func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement"])
        let ready = try #require(body.range(of: "funcready()->Bool{button.exists&&button.isHittable}"), "\(body)")
        let leaves = try #require(body.range(of: "if!ready(),app.searchFields.firstMatch.exists{Search.leave(app,"), "\(body)")
        let expands = try #require(body.range(of: "expandTabBar(app){ready()}"), "\(body)")
        #expect(ready.upperBound <= leaves.lowerBound && leaves.upperBound <= expands.lowerBound, "\(body)")
        #expect(!body.contains(".tap()"), "\(body)")
    }

    /// No tap into the tab bar: on an open bar its middle is another tab ("Unsortiert"), and in
    /// UI runs the bar never shrinks (review S10 of H14). A bar that scrolled away comes back
    /// with swipes, and the search button is found without a class's tab button.
    @Test func nothingTapsIntoTheTabBar() throws {
        for path in AppSource.swiftFiles(under: Self.folder) where !Self.ownCopies.contains(path) {
            let code = try Self.code(path)
            #expect(!Self.squeezed(code).contains("tabBars.firstMatch.tap()"), "\(path) taps into the tab bar")
            #expect(!code.contains("tabButton: tabButton"), "\(path) hands its own tab button to the search")
        }
        let expand = try Self.screensBody(["static func expandTabBar(_ app: XCUIApplication, until done: () -> Bool)"])
        #expect(expand.contains("app.swipeDown()") && !expand.contains(".tap()"), "\(expand)")
        let button = try Self.screensBody(["enum Search", "static func button(_ app: XCUIApplication) -> XCUIElement"])
        #expect(button.contains("UITestScreens.expandTabBar(app){found()?.isHittable==true}"), "\(button)")
        #expect(!button.contains(".tap()"), "\(button)")
    }

    /// Leaving the search waits for all three named tabs, hittable, not for "Vorschläge" alone,
    /// which a folded button may be named after (review S4 of H14). The way out is a button
    /// beside the field first (its own "Schließen"), then one elsewhere (a photo opened from the
    /// results), then the one button left in the tab bar (the folded tabs, which choose a tab).
    @Test func leavingWaitsForAllThreeTabsAndLooksBesideTheFieldFirst() throws {
        let back = try Self.screensBody(["enum Search", "static func tabsBack(_ app: XCUIApplication) -> Bool"])
        #expect(back.contains("[Tabs.german,Tabs.english].contains"), "\(back)")
        #expect(back.contains("[tabs.suggestions,tabs.unsorted,tabs.albums].allSatisfy"), "\(back)")
        #expect(back.contains("tab.exists&&tab.isHittable"), "\(back)")
        let leave = try Self.screensBody(["enum Search", "static func leave(_ app: XCUIApplication, _ what: String) -> Bool"])
        #expect(leave.contains("guardapp.searchFields.firstMatch.exists,!tabsBack(app)else{returntrue}"), "\(leave)")
        #expect(leave.contains("guardletway=wayOut(app,what)else{returnfalse}way.tap()ifUITestWait.holds(timeout:5,{tabsBack(app)})"),
                "\(leave)")
        let way = try Self.screensBody(["enum Search", "private static func wayOut(_ app: XCUIApplication, _ what: String) -> XCUIElement?"])
        let steps = ["letbeside=named.first(where:{row.intersects($0.frame)})",
                     "letelsewhere=named.first",
                     "letleft=app.tabBars.buttons.allElementsBoundByIndex.filter{$0.isHittable&&!labels.contains($0.label)}",
                     "ifleft.count==1,letfolded=left.first"]
        let found = steps.map { way.range(of: $0) }
        #expect(!found.contains(nil), "\(way)")
        let order = found.compactMap { $0?.lowerBound }
        #expect(order == order.sorted(), "the way out is not looked for beside the field first: \(way)")
    }

    /// What iOS shows is printed as the search is left, and when no way out or no tab is found:
    /// the tab bar's buttons, whether the tabs are folded, the field, the keyboard and the
    /// buttons beside the field.
    @Test func theHelpersSayWhatIOSShows() throws {
        let screens = try Self.code(Self.screens)
        let facts = try #require(AppSource.body(of: ["enum Search", "static func facts(_ app: XCUIApplication) -> String"], in: screens))
        for said in ["tab bar", "folded", "search field", "keyboard", "beside the field"] {
            #expect(facts.contains(said), "the facts do not say \(said): \(facts)")
        }
        let leave = try Self.screensBody(["enum Search", "static func leave(_ app: XCUIApplication, _ what: String) -> Bool"])
        let way = try Self.screensBody(["enum Search", "private static func wayOut(_ app: XCUIApplication, _ what: String) -> XCUIElement?"])
        let tab = try Self.screensBody(["static func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement"])
        for (name, body) in [("leave", leave), ("wayOut", way)] {
            #expect(body.contains("UI_FACT") && body.contains("facts(app)"), "\(name): \(body)")
        }
        #expect(tab.contains("UI_FACT") && tab.contains("Search.barFacts(app)"), "\(tab)")
    }

    /// Flow test 6 measures the sheet "Analyse" as soon as it is open, whatever its line says,
    /// and fails without its "Fertig" (review S6 of H14: inside `if said` the check was skipped
    /// without a word when the line came late), then checks that it opened half high.
    @Test func flowTest6MeasuresTheSheetWhateverItsLineSays() throws {
        let flow = try Self.code("App/AlbumistUITests/AlbumistFlowUITests.swift")
        let test6 = try #require(AppSource.body(of: ["func test6_AnalysisKeepsGoingThroughBackgroundAndTabs("], in: flow))
        let opened = try #require(test6.range(of: "let opened = idle && UITestScreens.Analysis.openSheet(app)"), "\(test6)")
        let there = try #require(test6.range(of: "XCTAssertTrue(sheetDone.exists,"), "a missing Fertig is not a failure")
        let high = try #require(test6.range(of: "XCTAssertGreaterThan(top, app.frame.height * 0.4,"))
        let line = try #require(test6.range(of: "anything(\"keine neuen Fotos\")"))
        #expect(opened.upperBound < there.lowerBound && there.upperBound < high.lowerBound, "\(test6)")
        #expect(high.upperBound < line.lowerBound, "the sheet is measured only after its line")
        #expect(!test6.contains("if said"), "the measure still waits for the line")
    }
}
