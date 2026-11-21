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
                guard let tap = line.firstMatch(of: /\b(\w+)\.tap\(\)/) else { continue }
                let name = String(tap.1)
                guard name != "app" else { continue }
                for later in lines[(index + 1)..<min(lines.count, index + 4)]
                where later.contains("print(") && later.contains("\\(\(name).") {
                    found.append("\(path):\(index + 1): \(later.trimmingCharacters(in: .whitespaces))")
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
        let record = try #require(AppSource.body(of: "private func record(", in: walk))
        #expect(record.contains("SideShelfCheck.inPeekingCard("), "the audit does not know the shelves")
        let package = try AppSource.read("Package.swift")
        #expect(package.contains("\"SideShelfCheck.swift\""), "Linux does not build the side check")
    }
}
