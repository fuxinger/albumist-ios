import Foundation
import Testing
import AlbumistTestSupport

/// The button of the plan preview is in reach without scrolling (review 18.11.2026, P3-05 =
/// G3-05): "Alben jetzt anlegen" was the last thing of the plan, below the album list, and so
/// were the promises "Kein Original wird gelöscht"; the preview opened with a list and no next
/// step. Now the button stands at the bottom of the screen, above the tab bar, with the promise
/// in one line above it, while the plan is on screen and can run. When something stops the plan
/// (only selected photos shared, an interrupted plan, more albums than are free), that stands at
/// the top of the plan instead, and there is no button.
///
/// Second review (20.11.): what explains the button stays next to it at every size, why it
/// waits and that iOS asks before albums are deleted (P3-07); where room is short (the
/// accessibility text sizes, landscape on an iPhone) only the promise and the free albums left
/// move to the end of the plan. The tests read the code, not its exact spelling.
///
/// The App does not build on Linux, so these tests read `PlanReviewView.swift` (`AppSource`). On
/// a Mac the UI tests tap the button as the preview opens, without scrolling, clear of the tab bar
/// (`AlbumistFlowUITests.test1_FullFlow`, the walks of `AccessibilityUITests`, `AlbumistLockedUITests`).
@Suite("The preview's button in reach")
struct PlanPreviewButtonTests {
    static let view = "App/Albumist/Views/PlanReviewView.swift"

    /// The file without comments, strings kept.
    static func code() throws -> String {
        AppSource.code(try AppSource.read(view), keepStrings: true)
    }

    /// The closure the screen shows at its bottom edge (`safeAreaInset(edge: .bottom`).
    static func bar(in code: String) throws -> String {
        let body = try #require(AppSource.body(of: ["struct PlanReviewView", "var body: some View"], in: code))
        return try #require(AppSource.body(of: ".safeAreaInset(edge: .bottom", in: body),
                            "nothing at the bottom of the preview: the button is only reached by scrolling")
    }

    /// Whether `text` holds `marker`, itself or in a function of the file it calls (`name(`),
    /// a few calls deep.
    static func reaches(_ marker: String, from text: String, in code: String, depth: Int = 3) -> Bool {
        if text.contains(marker) { return true }
        guard depth > 0 else { return false }
        let names = Set(text.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\(/).map { String($0.output.1) })
        return names.contains { name in
            guard let body = AppSource.body(of: "func \(name)(", in: code) else { return false }
            return reaches(marker, from: body, in: code, depth: depth - 1)
        }
    }

    /// The `if` and `else` blocks of `text`, in order, as code (comments and strings left out):
    /// each with its condition ("else" for an `else` block) and the positions of its braces, in
    /// Unicode scalars of `code`.
    static func blocks(in text: String) -> (code: [Unicode.Scalar], blocks: [(condition: String, open: Int, close: Int)]) {
        let code = Array(AppSource.code(text).unicodeScalars)
        func isName(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(scalar) || scalar == "_" }
        func isWord(_ word: String, at i: Int) -> Bool {
            let letters = Array(word.unicodeScalars)
            guard i + letters.count <= code.count, Array(code[i..<(i + letters.count)]) == letters else { return false }
            return (i == 0 || !isName(code[i - 1])) && (i + letters.count == code.count || !isName(code[i + letters.count]))
        }
        var found: [(condition: String, open: Int, close: Int)] = []
        for i in code.indices {
            guard let keyword = isWord("if", at: i) ? "if" : isWord("else", at: i) ? "else" : nil else { continue }
            // The block: the first `{` outside parentheses, up to its matching `}`.
            var open = i + keyword.unicodeScalars.count
            var parens = 0
            while open < code.count, !(code[open] == "{" && parens == 0) {
                if code[open] == "(" { parens += 1 }
                if code[open] == ")" { parens -= 1 }
                open += 1
            }
            var close = open
            var depth = 0
            while close < code.count {
                if code[close] == "{" { depth += 1 }
                if code[close] == "}" { depth -= 1; if depth == 0 { break } }
                close += 1
            }
            let condition = keyword == "if" ? String(String.UnicodeScalarView(code[(i + 2)..<min(open, code.count)])) : "else"
            found.append((condition.trimmingCharacters(in: .whitespacesAndNewlines), open, close))
        }
        return (code, found)
    }

    /// The conditions of the `if` and `else` blocks around the first `target` in `text`,
    /// outermost first (`blocks`); nil when `target` is not there.
    static func conditions(around target: String, in text: String) -> [String]? {
        let (code, blocks) = Self.blocks(in: text)
        guard let at = index(of: Array(target.unicodeScalars), in: code) else { return nil }
        return blocks.filter { $0.open < at && at < $0.close }.map(\.condition)
    }

    /// The conditions of every `if` in `text` (`blocks`).
    static func ifConditions(in text: String) -> [String] {
        blocks(in: text).blocks.map(\.condition).filter { $0 != "else" }
    }

    static func index(of wanted: [Unicode.Scalar], in scalars: [Unicode.Scalar]) -> Int? {
        guard !wanted.isEmpty, scalars.count >= wanted.count else { return nil }
        return (0...(scalars.count - wanted.count)).first { Array(scalars[$0..<($0 + wanted.count)]) == wanted }
    }

    /// The helper reads `if`, `else if` and `else` blocks, and leaves out what is only written
    /// in a string or a comment.
    @Test func theConditionsAroundACallAreRead() {
        let sample = """
        VStack {
            top() // if hidden { top() }
            if !compactBar { promise(summary) }
            if let previewed,
               previewed.obstacle == nil {
                Text("if wrong { notes() }")
                if a { first() } else if b { second() } else { third() }
            }
        }
        """
        #expect(Self.conditions(around: "top(", in: sample) == [])
        #expect(Self.conditions(around: "promise(", in: sample) == ["!compactBar"])
        #expect(Self.conditions(around: "notes(", in: sample) == nil)
        #expect(Self.conditions(around: "first(", in: sample) == ["let previewed,\n       previewed.obstacle == nil", "a"])
        #expect(Self.conditions(around: "second(", in: sample)?.last == "b")
        #expect(Self.conditions(around: "third(", in: sample)?.last == "else")
    }

    /// The button stands in the bar at the bottom, not at the end of the plan that scrolls. The
    /// bar is in the safe area, so above the tab bar, never behind it (unlike a `.bottomBar`
    /// toolbar under a tab bar, review P3-01), and on the screen's own background, so the plan
    /// scrolling under it never shows through its words.
    @Test func theButtonStandsAtTheBottomNotAtTheEndOfThePlan() throws {
        let code = try Self.code()
        let bar = try Self.bar(in: code)
        #expect(Self.reaches("\"plan.apply\"", from: bar, in: code), "the bar at the bottom does not hold \"Alben jetzt anlegen\"")
        let plan = try #require(AppSource.body(of: "func planContent(", in: code))
        #expect(!Self.reaches("\"plan.apply\"", from: plan, in: code), "the button still stands at the end of the plan")
        #expect(Self.reaches(".background(Theme.background)", from: bar, in: code), "the plan shows through the bar")
        #expect(!Self.reaches("ignoresSafeArea", from: bar, in: code), "the bar leaves the safe area (the tab bar is there)")
        #expect(!code.contains(".bottomBar"))
    }

    /// The bar is there only while the plan is on screen and can run: one value decides both the
    /// plan the screen shows and the bar under it, and it is nil during the sorting show, the run,
    /// over a result and while the plan is made. So "Alben jetzt anlegen" never stands over the
    /// sorting show or the result, and never where something stops the plan.
    @Test func theBarIsThereOnlyWhileThePlanIsOnScreenAndCanRun() throws {
        let code = try Self.code()
        let bar = try Self.bar(in: code)
        let guards = try #require(Self.conditions(around: "applyBar(", in: bar), "\(bar)")
        #expect(guards.contains { $0.contains(/\blet\s+previewed\b/) && $0.contains(/previewed\.obstacle\s*==\s*nil/) },
                "the bar stands when \(guards)")
        let body = try #require(AppSource.body(of: ["struct PlanReviewView", "var body: some View"], in: code))
        #expect(body.contains(/\}\s*else\s+if\s+let\s+previewed\s*\{\s*planContent\(\s*previewed\.plan\s*,\s*previewed\.facts\s*,\s*obstacle:\s*previewed\.obstacle\s*\)/),
                "the plan on screen goes by another value than the bar")
        let previewed = try #require(AppSource.body(of: "private var previewed:", in: code))
        let conditions: [(String, Regex<Substring>)] = [
            ("no sorting show", /\bshow\s*==\s*nil/),
            ("not running", /!\s*model\.execution\.isRunning\b/),
            ("no result", /model\.execution\.finished\s*==\s*nil/),
            ("not loading", /!\s*loading\b/),
            ("facts of this plan", /factsKey\.samePlan\(\s*as:\s*factsMadeFor\s*\)/),
            ("what stops it", /obstacle\(\s*for:\s*plan\s*,\s*facts\s*\)/),
        ]
        for (name, condition) in conditions {
            #expect(previewed.contains(condition), "the bar can stand without \(name)")
        }
    }

    /// What stops the plan is the first thing of the plan, seen as the preview opens (it stood
    /// at the end, where the button stood), in the order the preview has always asked: full
    /// access, then the interrupted plan, then the free albums.
    @Test func whatStopsThePlanStandsAtItsTopInsteadOfTheButton() throws {
        let code = try Self.code()
        let plan = try #require(AppSource.body(of: "func planContent(", in: code))
        let card = try #require(plan.firstRange(of: /if\s+let\s+obstacle\s*\{\s*obstacleCard\(\s*obstacle\s*,\s*facts\s*\)\s*\}/))
        let title = try #require(plan.range(of: "\"Das ändert sich in Fotos\""))
        #expect(card.lowerBound < title.lowerBound, "what stops the plan comes after the plan")
        let cards = try #require(AppSource.body(of: "func obstacleCard(", in: code))
        #expect(cards.contains(/FullAccessCard\(\s*\)/), "\(cards)")
        #expect(cards.contains("\"Erst das unterbrochene Anlegen abschließen\""), "\(cards)")
        #expect(cards.contains(/UnlockCard\(\s*albumsInPlan:\s*facts\.freeAlbumUse\b/), "\(cards)")
        let decision = try #require(AppSource.body(of: "func obstacle(for", in: code))
        let order = [/model\.access\s*==\s*\.limited/, /PlanGate\.refusal\(\s*for:\s*plan\b/, /purchases\.allows\(\s*albums:\s*facts\.freeAlbumUse\s*\)/]
            .map { decision.firstRange(of: $0)?.lowerBound }
        #expect(!order.contains(nil), "\(decision)")
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "\(decision)")
    }

    /// The two promises in one line, right above the button, in German and English.
    @Test func thePromiseStandsInOneLineAboveTheButton() throws {
        let code = try Self.code()
        let bar = try #require(AppSource.body(of: "func applyBar(", in: code))
        let promise = try #require(bar.firstRange(of: /\bpromise\(\s*facts\.summary\s*\)/))
        let button = try #require(bar.firstRange(of: /\bapplyButton\(/))
        #expect(promise.lowerBound < button.lowerBound, "the promise is not above the button")
        let words = try #require(AppSource.body(of: "func promise(", in: code))
        #expect(words.contains(/Text\(\s*"Kein Original wird gelöscht oder kopiert\."\s*\)/), "\(words)")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: AppSource.root.appendingPathComponent("App/Albumist/Resources/Localizable.xcstrings"))) as? [String: Any]
        let entry = (catalog?["strings"] as? [String: Any])?["Kein Original wird gelöscht oder kopiert."] as? [String: Any]
        let english = ((entry?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(english?["value"] as? String == "No originals are deleted or copied.")
    }

    /// The button waits while the plan has points to clear first, has nothing to do, or a change
    /// in "Dein Zuhause" makes the suggestions again (the plan would not start).
    @Test func theButtonWaitsWhileThePlanCannotStart() throws {
        let code = try Self.code()
        let button = try #require(AppSource.body(of: "func applyButton(", in: code))
        #expect(button.contains(/\.disabled\(\s*facts\.isBlocking\s*\|\|\s*facts\.hasNoSteps\s*\|\|\s*model\.homeChangeRunning\s*\)/), "\(button)")
        #expect(button.contains(/\.accessibilityIdentifier\(\s*"plan\.apply"\s*\)/), "\(button)")
    }

    /// Second review: next to the button at every text size and in landscape, why it waits and
    /// that iOS asks before albums are deleted (P3-07). At the accessibility sizes both stood at
    /// the end of the plan, so "Änderungen jetzt ausführen" of a removal could be tapped without
    /// the iOS question announced, and a greyed button stood there without a reason.
    @Test func whyTheButtonWaitsAndTheIOSQuestionStayInTheBarAtEverySize() throws {
        let code = try Self.code()
        let bar = try #require(AppSource.body(of: "func applyBar(", in: code))
        let button = try #require(Self.conditions(around: "applyButton(", in: bar), "no button in the bar")
        #expect(button.isEmpty, "the button stands in the bar only if \(button)")
        let notes = try #require(Self.conditions(around: "applyNotes(", in: bar),
                                 "the bar does not say why the button waits or that iOS asks")
        #expect(notes.isEmpty, "why the button waits and the iOS question stand in the bar only if \(notes)")
        let said = try #require(AppSource.body(of: "func applyNotes(", in: code))
        let question = try #require(Self.conditions(around: "DeleteQuestionNote.text", in: said), "the notes do not announce the iOS question")
        #expect(question.contains { $0.contains("deletedContainers") }, "\(question)")
        let waits = try #require(Self.conditions(around: "Text(", in: said), "the notes do not say why the button waits")
        #expect(waits.contains { $0.contains("isBlocking") }, "\(waits)")
        let plan = try #require(AppSource.body(of: "func planContent(", in: code))
        #expect(!Self.reaches("applyNotes(", from: plan, in: code), "the notes of the button stand at the end of the plan")
        #expect(!Self.reaches("DeleteQuestionNote", from: plan, in: code), "the iOS question stands at the end of the plan")
    }

    /// Second review: where room is short (the accessibility text sizes, landscape on an iPhone,
    /// where the full bar could fill most of the room between navigation and tab bar) the bar
    /// holds the button and what explains it; the promise and the free albums left move to the
    /// end of the plan, and only they.
    @Test func whereRoomIsShortOnlyThePromiseAndTheFreeAlbumsMoveToTheEnd() throws {
        let code = try Self.code()
        let compact = try #require(AppSource.body(of: "private var compactBar", in: code))
        #expect(compact.contains(/typeSize\.isAccessibilitySize/), "\(compact)")
        #expect(compact.contains(/verticalSizeClass\s*==\s*\.compact/), "\(compact)")
        let bar = try #require(AppSource.body(of: "func applyBar(", in: code))
        let plan = try #require(AppSource.body(of: "func planContent(", in: code))
        for moved in ["promise(", "freeAlbumNote("] {
            let inBar = try #require(Self.conditions(around: moved, in: bar), "\(moved) not in the bar")
            #expect(inBar.contains { $0.contains(/!\s*compactBar\b/) }, "\(moved) in the bar when \(inBar)")
            let atEnd = try #require(Self.conditions(around: moved, in: plan), "\(moved) not at the end of the plan")
            #expect(atEnd.contains { $0.contains("compactBar") && !$0.contains(/!\s*compactBar\b/) && $0.contains(/obstacle\s*==\s*nil/) },
                    "\(moved) at the end of the plan when \(atEnd)")
        }
        let notes = try #require(AppSource.body(of: "func applyNotes(", in: code))
        #expect(!notes.contains("Gratis-Alben"), "the free albums left stay in the bar where room is short")
    }

    /// Rows passing under the opaque bar are cut by design, as under the tab bar: the accessibility
    /// test knows the bar by its identifier. The bar is a container of its own, so the button
    /// inside keeps "plan.apply" (an identifier on a plain container is handed down to every
    /// element inside, `EmptyLibraryCard`).
    @Test func theAccessibilityTestKnowsTheBar() throws {
        let code = try Self.code()
        let bar = try #require(AppSource.body(of: "func applyBar(", in: code))
        #expect(bar.contains(/\.accessibilityElement\(\s*children:\s*\.contain\s*\)\s*\.accessibilityIdentifier\(\s*"plan\.bar"\s*\)/), "\(bar)")
        let walk = AppSource.code(try AppSource.read("App/AlbumistUITests/AccessibilityUITests.swift"), keepStrings: true)
        let chrome = try #require(AppSource.body(of: "func chromeFrames(", in: walk))
        #expect(chrome.contains("\"plan.bar\""), "the accessibility test does not count the bar")
    }

    /// Only what passes under the bar counts as under a bar in the accessibility test. The bar's
    /// own promise, button and notes ("Alben jetzt anlegen", the screen's main action) are
    /// audited like any content, a finding on them fails the test as before the bar was known:
    /// `chromeFrames` notes the elements inside "plan.bar", and neither the tree checks nor the
    /// audit let them pass as under a bar.
    @Test func theBarsOwnTextAndButtonAreStillAuditedAsErrors() throws {
        let walk = AppSource.code(try AppSource.read("App/AlbumistUITests/AccessibilityUITests.swift"), keepStrings: true)
        let chrome = try #require(AppSource.body(of: "func chromeFrames(", in: walk))
        #expect(chrome.contains(/\bownBarElements\s*(=|\.append\()/), "the elements inside the bar are not noted")
        let tree = try #require(AppSource.body(of: "func inspectTree(", in: walk))
        let inChrome = try #require(tree.split(separator: "\n").first { $0.contains(/\blet\s+inChrome\b/) }.map(String.init))
        #expect(inChrome.contains(/!\s*isOwnBarElement\(/), "the tree checks skip the bar's own elements: \(inChrome)")
        let record = try #require(AppSource.body(of: "func record(", in: walk))
        let exemption = try #require(Self.ifConditions(in: record).first { $0.contains("chrome.contains") },
                                     "no exemption for bars in the audit")
        #expect(exemption.contains(/!\s*isOwnBarElement\(/), "the bar's own elements pass as under a bar: \(exemption)")
    }
}
