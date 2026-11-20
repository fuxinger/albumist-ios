import Foundation
import Testing
import SortlyTestSupport

/// The analysis card at a glance (review of 18.11.2026, P3-08). It showed nine things at once:
/// heading, Pause, count, bar, "Schritt 4 von 6", "Schon fertig", "Gerade angesehen", "Läuft,
/// solange Albumist offen ist" and "Details", and during the places step a three-line note on
/// town names; too much for a newcomer and for a hurried user with 40,000 photos. Like Apple's
/// own progress displays the card now shows what runs (with its one button), how far (the count
/// and the bar), one short line (the finish time, or why it is slower or waits), what is already
/// done and "Details". The step number, the photos just looked at, whether it runs in the
/// background and the note on town names are one tap away in "Details". Only when iOS refused
/// the background time does the short line say "Läuft, solange Albumist offen ist", in place of
/// the finish time (decision of 20.11.: leaving Albumist would stop the analysis).
///
/// Nothing the owner decided to show leaves the card: the finish time (point 1), Pause and
/// "Fortsetzen", the waiting reasons (heat, battery, Photos), the countdown of the overnight
/// refinement's wait for Apple, "Schon fertig … Ansehen" (point 3). Each is looked for where it
/// is shown, not anywhere in the card: the VoiceOver value repeats the finish time and the map
/// pass (second review). The VoiceOver value keeps the step ("Schritt 4 von 6"): the UI tests
/// read it there.
///
/// The App does not build on Linux, so this reads its code (`AppSource`): comments never count,
/// texts only where a test asks for one, and whitespace never (`plain`).
@Suite("Analysis card at a glance")
struct AnalysisCardGlanceTests {
    static let file = "App/Sortly/Views/AnalysisProgressCard.swift"

    /// The code of a declaration path in the card's file, comments blanked; `keepStrings` keeps
    /// the texts.
    static func code(_ path: [String], keepStrings: Bool = false) throws -> String {
        let source = AppSource.code(try AppSource.read(file), keepStrings: keepStrings)
        return try #require(AppSource.body(of: path, in: source), "\(file): no \(path.joined(separator: " › ")) (moved?)")
    }

    /// `code` without any whitespace, so a check does not depend on how the code is spaced or
    /// broken into lines ("Text( stepLine )" is "Text(stepLine)").
    static func plain(_ code: String) -> String {
        code.replacing(#/\s+/#, with: "")
    }

    /// The statements of a view builder (`{ … }`) on its own level, each with what belongs to it
    /// (its block, the modifiers after it, the lines a condition goes on in), without whitespace:
    /// e.g. "header", "progress", "if!isPaused{Divider()}". Read from code with comments and
    /// strings blanked.
    static func parts(of block: String) -> [String] {
        let inner = block.drop { $0 != "{" }.dropFirst().dropLast()
        var parts: [String] = []
        var current = ""
        var depth = 0
        var lineBefore = ""
        for line in inner.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // A line goes on the statement before it inside that statement's brackets, as a
            // modifier (".font"), as its body ("{" on a line of its own), after an operator or
            // "else" at its start, and after a comma or an operator at the end of the line
            // before ("if let a,\n b {").
            let goesOn = depth > 0
                || trimmed.prefixMatch(of: #/\.|\{|&&|\|\||\?|:|else\b/#) != nil
                || lineBefore.firstMatch(of: #/(,|&&|\|\||=|\?|:)$/#) != nil
            if goesOn {
                current += trimmed
            } else {
                if !current.isEmpty { parts.append(current) }
                current = trimmed
            }
            for character in line {
                if "{([".contains(character) { depth += 1 }
                if "})]".contains(character) { depth -= 1 }
            }
            lineBefore = trimmed
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map(plain)
    }

    @Test func thePartsDoNotDependOnSpacingOrLineBreaks() {
        let spaced = """
        VStack {
            header
            if let position,
               position.hasCount
            {
                count(position)
            }
            Text( stepLine )
                .font(.footnote)
            if a
                && b { Divider() }
        }
        """
        #expect(Self.parts(of: spaced) == [
            "header", "ifletposition,position.hasCount{count(position)}", "Text(stepLine).font(.footnote)", "ifa&&b{Divider()}",
        ])
    }

    /// What the card shows at a glance, top to bottom: the heading with its one button, the
    /// progress (count, the short line, the bar: one element for VoiceOver, B1), "Schon fertig",
    /// a divider and "Details". Nothing else; adding a part means another one goes (the review:
    /// "erst ausdünnen, dann ergänzen").
    @Test func theCardShowsOnlyWhatMattersAtAGlance() throws {
        let card = Self.parts(of: try Self.code(["struct AnalysisProgressCard", "private var full: some View", "VStack("]))
            .filter { !$0.hasPrefix(Self.plain("if !isPaused { Divider() }")) }
        #expect(card.count == 4, "the card shows \(card.count) parts: \(card)")
        #expect(card.first == "header", "\(card)")
        #expect(card.dropFirst().first == "progress", "\(card)")
        #expect(card.dropFirst(2).first == "alreadyDone", "\(card)")
        #expect(card.last?.hasPrefix(Self.plain("Button { showDetails = true }")) == true, "\(card)")

        // The progress element: the count (while running), the short line, the bar.
        let progress = Self.parts(of: try Self.code(["struct AnalysisProgressCard", "private var progress: some View", "VStack("]))
        #expect(progress.count == 3, "the progress shows \(progress.count) parts: \(progress)")
        #expect(progress.first?.hasPrefix(Self.plain("if let position, position.hasCount")) == true, "\(progress)")
        #expect(progress.dropFirst().first == "statusLines", "\(progress)")
        #expect(progress.last?.hasPrefix("AnalysisBar(") == true, "\(progress)")
    }

    /// What left the card is in "Details": the step ("Schritt 4 von 6", "Gleich wieder bei
    /// Schritt 4 von 6"), the photos just looked at (image step only, never a screenshot: B4),
    /// whether it runs in the background (now with the honest "dort aber langsamer", P4-13), and
    /// the note on town names.
    @Test func whatLeftTheCardIsInDetails() throws {
        let cardWithTexts = try Self.code(["struct AnalysisProgressCard"], keepStrings: true)
        let card = Self.plain(cardWithTexts)
        let details = Self.plain(try Self.code(["struct AnalysisDetailsSheet"], keepStrings: true))
        let moved = [
            "\"Gerade angesehen\"", "AssetThumbnail(", "model.analysisRecent",
            "\"Läuft im Hintergrund weiter, dort aber langsamer\"",
            "\"Städtenamen kommen von Apple, das braucht etwas Zeit. Was jetzt nicht fertig wird, holt Albumist nach, wenn dein iPhone das nächste Mal lädt.\"",
        ]
        for text in moved + ["model.analysisBackground", "\"Läuft, solange Albumist offen ist\"", "stepText"] {
            #expect(details.contains(Self.plain(text)), "Details lack \(text)")
        }
        for text in moved + ["Text(stepLine"] {
            #expect(!card.contains(Self.plain(text)), "the card still shows \(text)")
        }
        // No word on the background on the card: only "Läuft, solange Albumist offen ist" when
        // iOS refused it (`aRefusedBackgroundIsSaidInPlaceOfTheFinishTime`).
        let background = cardWithTexts.matches(of: #/"[^"\n]*Hintergrund[^"\n]*"/#).map { String($0.output) }
        #expect(background.isEmpty, "the card says \(background)")
        // The photos just looked at only beside the image step (B4: never a screenshot).
        let recent = Self.plain(try Self.code(["struct AnalysisDetailsSheet", "private func recentPhotos("]))
        #expect(recent.contains("step==.content"), "\(recent)")
        // The step stays in the card's VoiceOver value, where the UI tests read it.
        let spoken = Self.plain(try Self.code(["struct AnalysisProgressCard", "private var accessibilityValue: String"]))
        #expect(spoken.contains("parts.append(stepLine)"), "\(spoken)")
    }

    /// When iOS refused the background time, the analysis goes on only while Albumist is open:
    /// then the card's short line says "Läuft, solange Albumist offen ist" in place of the
    /// finish time (which stays in Details), while it runs and not during Apple's countdown
    /// (that says why it waits); VoiceOver says it too, in the same place. The card reads the
    /// background nowhere else: every other word on it stays in Details (decision of 20.11.:
    /// the card keeps five parts).
    @Test func aRefusedBackgroundIsSaidInPlaceOfTheFinishTime() throws {
        let rule = try Self.code(["struct AnalysisProgressCard", "private var runsOnlyWhileOpen: Bool"])
        #expect(rule.contains(#/case\s+\.running\(\s*_\s*,\s*_\s*,\s*let\s+appleWait\s*,\s*_\s*\)\s*=\s*state/#), "\(rule)")
        #expect(rule.contains(#/!\s*appleWait/#), "\(rule)")
        #expect(rule.contains(#/model\.analysisBackground\s*==\s*\.refused/#), "\(rule)")

        // The short line: Apple's countdown, else the refused background, else the finish time.
        let lines = try Self.code(["struct AnalysisProgressCard", "private var statusLines: some View"], keepStrings: true)
        let chain = #/(?s)if\s+appleWait\s*\{.*?\}\s*else\s+if\s+runsOnlyWhileOpen\s*\{\s*Text\(\s*"Läuft, solange Albumist offen ist"\s*\).*?\}\s*else\s+if\s+let\s+finish\s*=\s*model\.analysisFinish\s*\{\s*Text\(\s*AnalysisText\.finish\(\s*finish\s*\)\s*\)/#
        #expect(lines.contains(chain), "\(lines)")

        // VoiceOver: the same words in place of the finish time.
        let spoken = try Self.code(["struct AnalysisProgressCard", "private var accessibilityValue: String"], keepStrings: true)
        let spokenChain = #/(?s)if\s+runsOnlyWhileOpen\s*\{\s*parts\.append\(\s*String\(\s*localized:\s*"Läuft, solange Albumist offen ist"\s*\)\s*\)\s*\}\s*else\s+if\s+case\s+\.running\s*=\s*state\s*,\s*let\s+finish\s*=\s*model\.analysisFinish/#
        #expect(spoken.contains(spokenChain), "\(spoken)")

        // Said nowhere else on the card, and the background read nowhere else.
        let card = try Self.code(["struct AnalysisProgressCard"], keepStrings: true)
        #expect(card.ranges(of: "\"Läuft, solange Albumist offen ist\"").count == 2, "the line and VoiceOver only")
        #expect(try Self.code(["struct AnalysisProgressCard"]).ranges(of: "model.analysisBackground").count == 1, "runsOnlyWhileOpen only")
    }

    /// Everything the owner decided to show stays on the card, each where it is seen: a text
    /// that is only left in the VoiceOver value (the finish time, the map pass) is no longer on
    /// screen (second review: both lines were deleted from the short line and the test before
    /// this one still passed).
    @Test func nothingTheOwnerDecidedLeavesTheCard() throws {
        func part(_ declaration: String) throws -> String {
            Self.plain(try Self.code(["struct AnalysisProgressCard", declaration], keepStrings: true))
        }
        func expectShown(_ texts: [String], in declaration: String, _ what: String) throws {
            let code = try part(declaration)
            for text in texts {
                #expect(code.contains(Self.plain(text)), "\(what) lost \(text)")
            }
        }
        // The short line under the count. Point 1: the finish time; Apple's countdown (overnight
        // refinement); the map pass moves while the places count stands (nothing stands still
        // for more than 10 s). Why it is slower or waits (decision of 15.11.: the analysis in
        // the app never ends for the device; table M4 of the progress display), and the pause.
        try expectShown([
            "AnalysisText.finish(finish)", "AnalysisText.appleWait(", "AnalysisText.mapChecked(pass)",
            "\"Langsamer, weil dein iPhone warm ist\"", "\"Langsamer, weil der Stromsparmodus an ist\"",
            "\"Geht von selbst weiter. Du musst nichts tun.\"", "Geht weiter, sobald dein iPhone lädt.",
            "\"Macht noch fertig, was gerade läuft.\"", "\"Dauert noch einen Moment.\"", "Sie macht genau dort weiter.",
        ], in: "private var statusLines: some View", "the short line")
        // The headings of the waiting states and the pause, shown by the heading.
        try expectShown([
            "\"Wartet, bis dein iPhone abkühlt\"", "\"Wartet aufs Laden\"", "\"Fotos antwortet gerade nicht\"",
            "\"Albumist war gerade ausgelastet\"", "\"Analyse pausiert\"",
        ], in: "private var title: String", "the heading")
        try expectShown(["Text(title)"], in: "private var heading: some View", "the heading")
        try expectShown(["heading", "control"], in: "private var header: some View", "the header")
        // Pause, and the ways back.
        try expectShown([
            "model.pauseAnalysis()", "CardTextButton(\"Fortsetzen\")", "CardTextButton(\"Jetzt versuchen\")",
        ], in: "private var control: some View", "the button")
        // Point 3, the bar, and the way to the rest.
        try expectShown(["\"Schon fertig: ", "CardTextButton(\"Ansehen\")"], in: "private var alreadyDone: some View", "Schon fertig")
        try expectShown(["AnalysisBar(", "statusLines"], in: "private var progress: some View", "the progress")
        try expectShown(["header", "progress", "alreadyDone", "Text(\"Details\")"], in: "private var full: some View", "the card")
        try expectShown(["AnalysisDetailsSheet()"], in: "var body: some View", "the card")
    }
}
