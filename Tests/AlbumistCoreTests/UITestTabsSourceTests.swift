import Foundation
import Testing
import AlbumistTestSupport

/// The UI tests' helpers for the tabs and the search (design wave 3, H14; review S4, S7 and S10
/// of H14), and the sheet check of flow test 6 (review S6), read as source: they build only on
/// a Mac. One `tabButton` for every class (`UITestScreens.tabButton`), which leaves an active
/// search before it looks for a tab and never taps into the bar; `Search.leave` waits for all
/// three named tabs and looks for the way out beside the field first; what iOS shows is printed
/// (`UI_FACT`), so a run tells what the helpers rest on. They work with both places of
/// `MainTabs.searchField` (the tab view on iOS 26, the page on iOS 27): choosing the search tab
/// brings no keyboard, and leaving the search is choosing another tab, which keeps it (the
/// owner's choice of 25.11.2026, "Runder Knopf, Suche bleibt").
@Suite("UI test helpers for the tabs and the search")
struct UITestTabsSourceTests {
    static let folder = "App/AlbumistUITests"
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

    /// The code of `UITestScreens.swift` and the files beside it (`UITestScreensSource`), as one
    /// text (comments blanked, strings kept).
    static func screensCode() throws -> String {
        AppSource.code(try UITestScreensSource.read(), keepStrings: true)
    }

    /// The body of `path` (declarations inside each other) in `UITestScreens`' files, squeezed.
    static func screensBody(_ path: [String]) throws -> String {
        squeezed(try #require(AppSource.body(of: path, in: try screensCode()), "\(path) is not in UITestScreens' files"))
    }

    /// Every file of the screens is read by the guards: the list comes from the folder, so a new
    /// `UITestScreens+….swift` is read by itself (review T9 of H14's round 2: five paths by hand
    /// left a sixth file unread by every guard), and these five are there.
    @Test func everyFileOfTheScreensIsRead() throws {
        let read = UITestScreensSource.paths
        #expect(read == ["App/AlbumistUITests/UITestScreens.swift",
                         "App/AlbumistUITests/UITestScreens+Analysis.swift",
                         "App/AlbumistUITests/UITestScreens+Search.swift",
                         "App/AlbumistUITests/UITestScreens+StartPage.swift",
                         "App/AlbumistUITests/UITestScreens+UnsortedAndAlbums.swift"], "\(read)")
        let folder = AppSource.swiftFiles(under: Self.folder)
            .filter { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("UITestScreens") }
        #expect(Set(read) == Set(folder), "these files of the screens are read by no guard: \(Set(folder).subtracting(read))")
        #expect(try Self.screensCode().contains("enum Search"), "the files are not read as one text")
    }

    /// Every class asks `UITestScreens.tabButton`: its own `tabButton` only hands the name on
    /// (review S7 of H14: only one of six copies left the search).
    @Test func everyClassTakesTheOneTabButton() throws {
        var classes: [String] = []
        for path in AppSource.swiftFiles(under: Self.folder)
        where !UITestScreensSource.paths.contains(path) && !Self.ownCopies.contains(path) {
            guard let body = AppSource.body(of: ["func tabButton(_ name: String) -> XCUIElement"], in: try Self.code(path)) else { continue }
            #expect(Self.squeezed(body) == "{UITestScreens.tabButton(app,name)}", "\(path): \(body)")
            classes.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        #expect(classes.sorted() == ["AccessibilityUITests.swift", "AlbumistFlowUITests.swift", "DeviceConditionUITests.swift",
                                     "FrameUITests.swift", "PerformanceUITests.swift", "SearchUITests.swift"], "\(classes.sorted())")
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
        // Only getting out matters here: the field's own way out first (review T4 of H14).
        #expect(body.contains(#"Search.leave(app,"tab\(name)")}"#), "\(body)")
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
    /// Where the search is to stay (`keepingSearch`), the folded tabs come first and the field's
    /// own way out is never taken (review T4 of H14), and before any tap the tabs get up to 3 s
    /// to come back by themselves as the keyboard goes (second check of the search, 25.11.2026:
    /// a "Schließen" tapped a moment too early ended the search the test kept). The ways tapped
    /// are given back.
    @Test func leavingWaitsForAllThreeTabsAndLooksBesideTheFieldFirst() throws {
        let back = try Self.screensBody(["enum Search", "static func tabsBack(_ app: XCUIApplication) -> Bool"])
        #expect(back.contains("[Tabs.german,Tabs.english].contains"), "\(back)")
        #expect(back.contains("[tabs.suggestions,tabs.unsorted,tabs.albums].allSatisfy"), "\(back)")
        #expect(back.contains("tab.exists&&tab.isHittable"), "\(back)")
        let plain = try Self.screensBody(["enum Search", "static func leave(_ app: XCUIApplication, _ what: String) -> Bool"])
        #expect(plain == "{leave(app,what,keepingSearch:false).back}", "\(plain)")
        let leave = try Self.screensBody(["enum Search", Self.leaveWithWays])
        let gone = try #require(leave.range(of: "guardapp.searchFields.firstMatch.exists,!tabsBack(app)else{return(true,ways)}"), "\(leave)")
        let comes = try #require(leave.range(of: "ifkeepingSearch||!app.keyboards.firstMatch.exists,UITestWait.holds(timeout:3,{tabsBack(app)}){"
                                             + "return(true,ways)}"), "the tabs get no moment to come back by themselves: \(leave)")
        let tapped = try #require(leave.range(of: "way.button.tap()"), "\(leave)")
        #expect(gone.upperBound <= comes.lowerBound && comes.upperBound <= tapped.lowerBound, "\(leave)")
        #expect(leave.contains("guardletway=wayOut(app,what,keepingSearch:keepingSearch)else{return(false,ways)}"
                               + "ways.append(way.said)way.button.tap()ifUITestWait.holds(timeout:5,{tabsBack(app)}){return(true,ways)}"),
                "\(leave)")
        let way = try Self.screensBody(["enum Search", Self.wayOut])
        let steps = ["if!keepingSearch,letbeside=named.first(where:{row.intersects($0.frame)})",
                     "ifletelsewhere=named.first(where:{closeLabels.contains($0.label)&&!row.intersects($0.frame)})",
                     "letleft=app.tabBars.buttons.allElementsBoundByIndex.filter{$0.isHittable&&!labels.contains($0.label)}",
                     "ifleft.count==1,letfolded=left.first"]
        let found = steps.map { way.range(of: $0) }
        #expect(!found.contains(nil), "\(way)")
        let order = found.compactMap { $0?.lowerBound }
        #expect(order == order.sorted(), "the way out is not looked for beside the field first: \(way)")
        #expect(way.contains("ifkeepingSearch{ways.insert(way,at:0)}else{ways.append(way)}"), "\(way)")
    }

    /// The declaration of `leave` that says the ways it took, and of `wayOut`.
    static let leaveWithWays = "static func leave(_ app: XCUIApplication, _ what: String, keepingSearch: Bool) -> (back: Bool, ways: [String])"
    static let wayOut = "private static func wayOut(_ app: XCUIApplication, _ what: String, keepingSearch: Bool)"

    /// The search button is the tab bar's, or one in the tab bar's row (iOS may draw the search
    /// tab as a round button of its own beside the bar) while neither the keyboard nor a dialog
    /// is up: never a "Suchen" of the page or of a dialog. A dialog's buttons are never a way out
    /// of the search, and elsewhere than beside the field only "Schließen" is (a photo opened from
    /// the results), never "Abbrechen" (the rest of review S10 of H14).
    @Test func theSearchHelpersTakeNothingOfThePageOrADialog() throws {
        let button = try Self.screensBody(["enum Search", "static func button(_ app: XCUIApplication) -> XCUIElement"])
        #expect(button.contains("guard!app.keyboards.firstMatch.exists,!app.alerts.firstMatch.exists,!app.sheets.firstMatch.existselse{returnnil}"
                                + "returnapp.buttons.matching(NSPredicate(format:\"labelIN%@\",labels)).allElementsBoundByIndex"
                                + ".first(where:{inTabBarRow($0,app)})"), "\(button)")
        let row = try Self.screensBody(["enum Search", "private static func inTabBarRow(_ element: XCUIElement, _ app: XCUIApplication) -> Bool"])
        #expect(row == "{letbar=app.tabBars.firstMatchguardbar.exists,element.existselse{returnfalse}"
                + "letmid=element.frame.midYreturnmid>=bar.frame.minY&&mid<=bar.frame.maxY}", "\(row)")
        let named = try Self.screensBody(["enum Search", "private static func leaveButtons(_ app: XCUIApplication) -> [XCUIElement]"])
        #expect(named == "{letdialogs=(app.alerts.allElementsBoundByIndex+app.sheets.allElementsBoundByIndex).map(\\.frame)"
                + "returnapp.buttons.matching(NSPredicate(format:\"labelIN%@\",leaveLabels)).allElementsBoundByIndex"
                + ".filter{buttoninbutton.isHittable&&!dialogs.contains{$0.intersects(button.frame)}}}", "\(named)")
        let way = try Self.screensBody(["enum Search", Self.wayOut])
        #expect(way.contains("letnamed=leaveButtons(app)"), "\(way)")
        let search = try Self.screensBody(["enum Search"])
        #expect(search.contains(#"staticletcloseLabels=["Schließen","Close"]"#), "\(search)")
        #expect(search.contains(#"staticletleaveLabels=["Schließen","Abbrechen","Close","Cancel"]"#), "\(search)")
    }

    /// What the field kept is seen after leaving the search as a user looks at another tab
    /// (review T4 and T5 of H14): `SearchUITests` waits up to 5 s for the keyboard to go after the
    /// return key, leaves keeping the search (the folded tabs of iOS 26, never "Schließen", which
    /// ends the search and empties the field), and says the ways it took in the same `UI_FACT`
    /// line as the text. Since the owner's choice of 25.11.2026 it asserts what the search kept:
    /// the query, its answer, and no keyboard, as it asserts no keyboard when the tab is first
    /// chosen, and on iOS 27 the field at the top of the page. The sweep and `tabButton` keep the
    /// field's own way out first, where only getting out matters.
    @Test func theSearchTestLeavesByTheFoldedTabsAndSaysSo() throws {
        let code = try Self.code("App/AlbumistUITests/SearchUITests.swift")
        let test = Self.squeezed(try #require(AppSource.body(of: ["func testSearchUnderstandsRealQueries()"], in: code)))
        let gone = try #require(test.range(of: #"field.typeText("\n")_=UITestWait.holds(timeout:5){!app.keyboards.firstMatch.exists}"#), "\(test)")
        let leaves = try #require(test.range(of: #"letleft=UITestScreens.Search.leave(app,"search",keepingSearch:true)"#), "\(test)")
        #expect(gone.upperBound <= leaves.lowerBound, "\(test)")
        #expect(test.contains("XCTAssertTrue(left.back,"), "\(test)")
        let said = try #require(test.range(of: #"print("UI_FACTsearchchosenagain:field\(shown),text\"\(query)\",leftby\(left.ways),"#), "\(test)")
        let kept = String(test[said.upperBound...])
        for check in [#"XCTAssertTrue(shown,"#, #"XCTAssertEqual(query,"xyzzy","#, #"XCTAssertTrue(kept,"#,
                      #"UITestWait.never("nokeyboardwhenthesearchischosenagain",for:2){app.keyboards.firstMatch.exists}"#] {
            #expect(kept.contains(check), "the search chosen again does not assert \(check): \(kept)")
        }
        let chosen = try #require(test.range(of: #"tap(searchTabButton(),"searchtab")"#), "\(test)")
        let first = try #require(test.range(of: #"UITestWait.never("nokeyboardbeforethesearchfieldistapped",for:2){app.keyboards.firstMatch.exists}"#),
                                 "choosing the tab is not checked for no keyboard: \(test)")
        let typed = try #require(test.range(of: "field.tap()"), "\(test)")
        #expect(chosen.upperBound <= first.lowerBound && first.upperBound <= typed.lowerBound, "\(test)")
        let flow = try Self.code("App/AlbumistUITests/AlbumistFlowUITests.swift")
        #expect(flow.contains(#"UITestScreens.Search.leave(app, "sweep")"#), "the sweep does not leave the search")
        #expect(flow.contains(#"UITestScreens.Search.leave(app, "sweep, back to the start page")"#), "the sweep does not leave the search")
        #expect(!flow.contains("keepingSearch"), "the sweep leaves keeping the search")
        // iOS 27: the field on the page, at its top (`MainTabs.searchField`).
        #expect(test.contains("if#available(iOS27,*){letplace=field.frame")
                && test.contains(#"XCTAssertLessThan(place.midY,app.frame.midY,"Thesearchfieldisnotatthetopofthesearchpage")"#),
                "the search test does not check the field's place on iOS 27: \(test)")
    }

    /// The search tab never brings the keyboard (the owner's choice of 25.11.2026): the
    /// accessibility walk and flow test 1 watch a second for it and fail when it comes, not five
    /// seconds once per walk and language (review T6 of H14); the frame test asserts the round
    /// button apart from the tabs, where it only said its shape before the choice.
    @Test func theWalkWaitsASecondForAKeyboardTheDefaultNeverBrings() throws {
        let walk = Self.squeezed(try Self.code("App/AlbumistUITests/AccessibilityUITests.swift"))
        let tab = try #require(walk.range(of: #"tap(searchTabButton(),"\(tag)searchtab")"#), "no search step in the walk")
        let check = try #require(walk.range(of: #"check("\(tag)search",english:english)"#, range: tab.upperBound..<walk.endIndex))
        let wait = String(walk[tab.upperBound..<check.lowerBound])
        #expect(wait.contains(#"UITestWait.never("\(tag)nokeyboardbeforethesearchfieldistapped",for:1){app.keyboards.firstMatch.exists}"#),
                "\(wait)")
        #expect(!wait.contains("waitForExistence(timeout:5)") && !wait.contains("UITestWait.holds("), "\(wait)")
        let flow = Self.squeezed(try Self.code("App/AlbumistUITests/AlbumistFlowUITests.swift"))
        #expect(flow.contains(#"UITestWait.never("nokeyboardbeforethesearchfieldistapped",for:1){app.keyboards.firstMatch.exists}"#),
                "flow test 1 does not watch for the keyboard the search tab never brings")
        let frame = Self.squeezed(try Self.code("App/AlbumistUITests/FrameUITests.swift"))
        for check in ["letround=abs(frame.width-frame.height)<8", #"XCTAssertTrue(round,"#, #"XCTAssertGreaterThanOrEqual(gap,0,"#] {
            #expect(frame.contains(check), "the frame test does not assert the round button apart from the tabs: \(check)")
        }
        let comment = try AppSource.read("App/AlbumistUITests/FrameUITests.swift")
        #expect(!comment.contains("placements"), "the frame test still waits for a choice among placements")
    }

    /// What iOS shows is printed as the search is left, and when no way out or no tab is found:
    /// the tab bar's buttons, whether the tabs are folded, the field, the keyboard and the
    /// buttons beside the field.
    @Test func theHelpersSayWhatIOSShows() throws {
        let screens = try Self.screensCode()
        let facts = try #require(AppSource.body(of: ["enum Search", "static func facts(_ app: XCUIApplication) -> String"], in: screens))
        for said in ["tab bar", "folded", "search field", "keyboard", "beside the field"] {
            #expect(facts.contains(said), "the facts do not say \(said): \(facts)")
        }
        let leave = try Self.screensBody(["enum Search", Self.leaveWithWays])
        let way = try Self.screensBody(["enum Search", Self.wayOut])
        let tab = try Self.screensBody(["static func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement"])
        for (name, body) in [("leave", leave), ("wayOut", way)] {
            #expect(body.contains("UI_FACT") && body.contains("facts(app)"), "\(name): \(body)")
        }
        #expect(tab.contains("UI_FACT") && tab.contains("Search.barFacts(app)"), "\(tab)")
    }

    /// Flow test 6 measures the sheet "Analyse" as soon as it is open, whatever its line says,
    /// and fails without its "Fertig" (review S6 of H14: inside `if said` the check was skipped
    /// without a word when the line came late), then checks that it opened half high, once the
    /// sheet stands still: two equal reads of its "Fertig" half a second apart (review T8 of
    /// round 2: read at once, a sheet still sliding up could pass). A check that did not finish
    /// fails as such, not as a sheet that is not open.
    @Test func flowTest6MeasuresTheSheetWhateverItsLineSays() throws {
        let flow = try Self.code("App/AlbumistUITests/AlbumistFlowUITests.swift")
        let test6 = Self.squeezed(try #require(AppSource.body(of: ["func test6_AnalysisKeepsGoingThroughBackgroundAndTabs("], in: flow)))
        let steps = [#"XCTAssertTrue(idle,"Thecheckdidnotfinish"#,
                     "letopened=idle&&UITestScreens.Analysis.openSheet(app)",
                     "ifidle{XCTAssertTrue(sheetDone.exists,",
                     "ifsheetDone.exists{varlast:CGFloat?letstill=UITestWait.holds(timeout:5){letnow=sheetDone.frame.minY"
                         + "defer{last=now}returnnow==last}lettop=last??sheetDone.frame.minY",
                     "XCTAssertTrue(still,",
                     "XCTAssertGreaterThan(top,app.frame.height*0.4,",
                     #"anything("keineneuenFotos")"#]
        let found = steps.map { test6.range(of: $0) }
        #expect(!found.contains(nil), "\(zip(steps, found).filter { $0.1 == nil }.map(\.0)): \(test6)")
        let order = found.compactMap { $0?.lowerBound }
        #expect(order == order.sorted(), "flow test 6 does not finish the check, open, measure the sheet still and then read its line in turn")
        #expect(!test6.contains("ifsaid"), "the measure still waits for the line")
    }
}
