import Foundation
import Testing
import AlbumistTestSupport

/// The UI tests' own helpers, read as source: they build only on a Mac. Each test here comes
/// from a UI run whose failures came from the helpers, not from the app.
@Suite("UI test helpers")
struct UITestHelperSourceTests {
    /// A tap that opens another screen takes the tapped element out of the tree: reading it
    /// afterwards ("UI_STEP_OK … \(all.identifier)") fails the test with "Failed to get matching
    /// snapshot" once the push has ended. UI run 44852630315: flow-other's test1c, test1d, test3,
    /// test4 and test5 failed so right after `openList` had opened the list; flow-full's test1
    /// passed only because its print came before the push ended. What a step reports of the
    /// element is read before the tap.
    @Test func noStepReadsTheElementItJustTapped() throws {
        var found: [String] = []
        for path in AppSource.swiftFiles(under: "App/AlbumistUITests") {
            let lines = try AppSource.read(path).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                // `x.tap()` and the tests' own `tap(x, "step")`. Reads that check the same
                // screen (a selection, a field's value) stay allowed: they read neither the
                // identifier nor the label, which only name the element in a report.
                var names = Set(line.matches(of: /\b(\w+)\.tap\(\)/).map { String($0.1) })
                names.formUnion(line.matches(of: /\btap\((\w+)\s*,/).map { String($0.1) })
                for name in names.subtracting(["app", "self"]) {
                    for later in lines[(index + 1)..<min(lines.count, index + 9)] {
                        if later.contains(" \(name) = ") { break }
                        if later.contains("\(name).identifier") || later.contains("\(name).label") {
                            found.append("\(path):\(index + 1): \(later.trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }
        #expect(found.isEmpty, "\(found)")
    }

    /// The overview's trial-year note has "Alle Jahre" beside its line where that fits and
    /// "Ganze Mediathek dazunehmen" under it where it does not (`ViewThatFits`); the card for an
    /// empty trial year says the latter too. Design wave 1's ring card is narrower: on the
    /// iPhone 18 Pro the note shows the long words, test6 looked for "Alle Jahre" only and left
    /// the trial year on, and every later test of flow-other found "Keine Fotos aus 2026" and
    /// nothing to sort (UI run 44852630315, six failures from one). The UI tests know every
    /// wording, and every test starts with the whole library (`prepare`).
    @Test func theUITestsKnowEveryWordingOfTakingInAllYears() throws {
        let overview = try AppSource.read("App/Albumist/Views/OverviewView.swift")
        let note = try #require(AppSource.body(of: "private func trialNote(", in: overview))
        var words = note.matches(of: /changeScope\(\.all\)\s*\}\s*label:\s*\{\s*TapTarget\("([^"]+)"\)/).map { String($0.1) }
        let empty = try AppSource.read("App/Albumist/Views/EmptyLibraryCard.swift")
        words += empty.matches(of: /Button\("([^"]+)"\)\s*\{\s*model\.changeScope\(\.all\)/).map { String($0.1) }
        #expect(Set(words) == ["Alle Jahre", "Ganze Mediathek dazunehmen"], "the app's wordings changed: \(words)")

        let screens = try AppSource.read("App/AlbumistUITests/UITestScreens.swift")
        let trialYear = try #require(AppSource.body(of: "enum TrialYear", in: screens))
        let list = try #require(trialYear.firstMatch(of: /static let allYearsWords\s*=\s*\[([^\]]*)\]/))
        let known = Set(list.1.matches(of: /"([^"]+)"/).map { String($0.1) })
        for word in words {
            #expect(known.contains(word), "the UI tests do not know \"\(word)\"")
        }

        let flow = try AppSource.read("App/AlbumistUITests/AlbumistFlowUITests.swift")
        #expect(!flow.contains("button(\"Alle Jahre\")"), "a step still looks for \"Alle Jahre\" only")
        let test6 = try #require(AppSource.body(of: "func test6_AnalysisKeepsGoingThroughBackgroundAndTabs(", in: flow))
        #expect(test6.contains("UITestScreens.TrialYear.allYearsButton(app)"), "test6 does not take in all years by every wording")
        let prepare = try #require(AppSource.body(of: "private func prepare(", in: flow))
        #expect(prepare.contains("UITestScreens.TrialYear.allYearsButton(app)"), "prepare leaves a trial year on")
        // Since prepare repairs it for the tests after, test6 itself must fail when the year stays.
        #expect(test6.contains(/XCTAssertTrue\(gone,/), "test6 only prints whether the trial year went")
    }

    /// The shelves of design wave 1 show two cards and the edge of the third, so the third
    /// card's text runs off the side of the screen by design: UI run 44852630315 failed the
    /// accessibility test at "landscape albums" on the third album of "Von Albumist" ("Neu",
    /// its name and count off the side, and the audit's contrast on the few points of "Neu" on
    /// screen). The tree check and the audit let text pass only in a card that peeks in from a
    /// shelf (`SideShelfCheck`, tested in `SideShelfCheckTests`); any other text that runs off
    /// the side fails as before.
    @Test func theAccessibilityTestLetsOnlyPeekingCardsRunOffTheSide() throws {
        let walk = try AppSource.read("App/AlbumistUITests/AccessibilityUITests.swift")
        let tree = try #require(AppSource.body(of: "private func inspectTree(", in: walk))
        #expect(tree.contains("SideShelfCheck.peekingCard(of:"), "the tree check does not know the shelves")
        #expect(tree.contains("fail(\"text runs off the side of the screen\""), "text running off the side no longer fails")
        #expect(tree.contains("peekingCards = []"), "the cards of the last screen stay noted")
        #expect(tree.contains("SideShelfCheck.isShelfCard("), "the tree check finds no card beside its text")
        #expect(tree.contains("A11Y_DETAIL"), "a text that fails does not say what lies above it")
        let record = try #require(AppSource.body(of: "private func record(", in: walk))
        // Only what the audit measures on the part on screen: contrast and clipped text. A small
        // target or a missing label on a peeking card fails as anywhere else.
        let exemption = try #require(record.split(separator: "\n").first { $0.contains("SideShelfCheck.inPeekingCard(") })
        #expect(exemption.contains("type == .contrast || type == .textClipped"), "\(exemption)")
        // The second contrast audit must not confirm a finding on screen by a peeking card's
        // text of the same label ("Neu" on every new album).
        let confirm = try #require(AppSource.body(of: "private func confirmContrast(", in: walk))
        #expect(confirm.contains("SideShelfCheck.inPeekingCard("), "the confirmation counts the peeking card")
        let package = try AppSource.read("Package.swift")
        #expect(package.contains("\"SideShelfCheck.swift\""), "Linux does not build the side check")
    }

    /// SwiftPM builds three files of the UI tests for tests of their own (target
    /// `AlbumistUITestLogic`), on Linux and in CI's macOS job. On Apple platforms `CGRect` is
    /// Equatable only through CoreGraphics' own Swift module, which Foundation alone does not
    /// make visible to that build: CI 44862185266 failed to compile `SideShelfCheck.Ancestor:
    /// Equatable` on the Mac, while Linux (whose Foundation has a CGRect of its own) and the
    /// Xcode UI test target (which imports XCTest) built it. Every file of the target and of its
    /// tests that names a CoreGraphics type imports CoreGraphics where it can.
    @Test func theSwiftPMFilesOfTheUITestsImportCoreGraphicsWhereTheyUseIt() throws {
        let package = AppSource.code(try AppSource.read("Package.swift"), keepStrings: true)
        let target = try #require(package.range(of: #"name: "AlbumistUITestLogic""#), "no target AlbumistUITestLogic")
        let sources = try #require(package[target.upperBound...].firstMatch(of: /sources:\s*\[([^\]]*)\]/), "the target lists no sources")
        let files = sources.1.matches(of: /"([^"]+\.swift)"/).map { "App/AlbumistUITests/" + String($0.1) }
        #expect(files.contains("App/AlbumistUITests/SideShelfCheck.swift"), "\(files)")
        var missing: [String] = []
        for path in files + AppSource.swiftFiles(under: "Tests/AlbumistUITestLogicTests") {
            let code = AppSource.code(try AppSource.read(path))
            guard code.contains(/\bCG(Rect|Point|Size|Float|Vector)\b/) else { continue }
            let imports = code.contains(/#if canImport\(CoreGraphics\)\s*import CoreGraphics\s*#endif/)
            if !imports { missing.append(path) }
        }
        #expect(missing.isEmpty, "these files use CoreGraphics types without importing CoreGraphics: \(missing)")
    }

    /// At the largest text size of UI run 44852630315 a swipe left the suggestion's page and the
    /// preview where they were: their "lower" shots equal the first ones and so do their trees,
    /// so their lower parts were never checked. Both have a tall bar of their own at the bottom.
    /// The lower checks scroll by `scrollUp(_:swipes:)`: when the swipes moved nothing on the
    /// screen, it drags inside the part of the page that shows (between the navigation bar and
    /// the page's own bar or the tab bar) and says so.
    @Test func theLowerChecksSeeTheLowerPart() throws {
        let walk = try AppSource.read("App/AlbumistUITests/AccessibilityUITests.swift")
        let code = AppSource.code(walk, keepStrings: true)
        for screen in ["start page", "suggestion detail", "plan", "atlas"] {
            let check = "check(\"\\(tag) \(screen) lower\""
            let at = try #require(code.range(of: check), "no lower check of the \(screen)")
            let before = code[..<at.lowerBound].suffix(160)
            #expect(before.contains("scrollUp(\"\\(tag) \(screen) lower\""), "the \(screen)'s lower check follows a bare swipe")
        }
        let scroll = try #require(AppSource.body(of: "private func scrollUp(", in: walk))
        #expect(scroll.contains("XCUIScreen.main.screenshot()"), "the walk does not see whether the swipes moved the page")
        #expect(scroll.contains("press(forDuration:"), "no drag where the swipes moved nothing")
        #expect(scroll.contains("\"plan.bar\"") && scroll.contains("\"proposal.bar\""), "the drag does not keep clear of the page's own bar")
        #expect(scroll.contains("UI_FACT"), "a page the swipes did not move is not reported")
    }

    /// "Anlegen" makes at once only what needs no look first (`AppModel.createNow`: a plan with
    /// something to point out opens the suggestion's page before the free albums are counted).
    /// UI run 44878163259: locked test8 tapped „København V, Mai 2023“, whose page opened instead
    /// of the purchase sheet (an earlier test had left an album of that name in its folder), as
    /// in UI run 44862187776; `FrameUITests.test3` went on to the next card in the same run and
    /// passed. test8 tries the next card too, at most three, and fails only when none opens the
    /// sheet.
    @Test func theLockedCardTestTriesTheNextCardWhenOneIsLookedAtFirst() throws {
        let locked = try AppSource.read("App/AlbumistUITests/AlbumistLockedUITests.swift")
        let test8 = try #require(AppSource.body(of: "func test8_CardWithoutFreeAlbumsOpensThePurchaseSheet(", in: locked))
        #expect(test8.contains(/for attempt in 0\.\.<3/), "test8 taps one card only")
        #expect(test8.contains("cardThatCreates(skipping: attempt)"), "test8 does not go on to the next card")
        #expect(test8.contains("UITestScreens.SuggestionPage.isShown(app)"), "test8 does not see that the card opened its page")
        let finder = try #require(AppSource.body(of: "private func cardThatCreates(", in: locked))
        #expect(finder.contains("element(boundBy: skipped)"), "the cards after the first are never found")
    }

    /// testRemovePhotoFromSuggestion runs last of its group in flow-other: the flows before it
    /// made nearly every suggestion, no area had two open any more and so no "Alle N", and the
    /// test failed on its first step in every UI run of design waves 1 to 3 (the last
    /// 44878163259; test7 before it found its personal place alone on the page). It takes back
    /// the newest plans then, as the locked tests do, through the same helper, which lives in
    /// `UITestScreens` once.
    @Test func theRemovePhotoTestTakesBackPlansWhenNoListIsLeft() throws {
        let flow = try AppSource.read("App/AlbumistUITests/AlbumistFlowUITests.swift")
        let test = try #require(AppSource.body(of: "func testRemovePhotoFromSuggestion(", in: flow))
        #expect(test.contains("UITestScreens.Albums.takeBackNewestPlans(app,"), "no list, and nothing taken back")
        #expect(test.matches(of: /StartPage\.openList\(/).count >= 2, "the list is not looked for again after taking back")
        #expect(test.contains("shot(\"x-"), "a missing list leaves no picture")

        let screens = try AppSource.read("App/AlbumistUITests/UITestScreens.swift")
        let shared = try #require(AppSource.body(of: "static func takeBackNewestPlans(", in: screens))
        #expect(shared.contains("\"receipt.undo\""), "the shared helper takes nothing back")
        #expect(shared.contains("springboard"), "the shared helper does not answer iOS's question before albums are deleted")
        let locked = try AppSource.read("App/AlbumistUITests/AlbumistLockedUITests.swift")
        let own = try #require(AppSource.body(of: "private func takeBackNewestPlans(", in: locked))
        #expect(own.contains("UITestScreens.Albums.takeBackNewestPlans(app,"), "the locked tests keep a copy of their own")
        #expect(!own.contains("receipt.undo"), "the locked tests keep a copy of their own")

        // A list that is not found says what the page showed instead.
        let start = try #require(AppSource.body(of: "static func openList(", in: screens))
        #expect(start.contains("facts(app)"), "a missing \"Alle N\" does not say what the page showed")
    }
}
