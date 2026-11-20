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
/// background and the note on town names are one tap away in "Details".
///
/// Nothing the owner decided to show leaves the card: the finish time (point 1), Pause and
/// "Fortsetzen", the waiting reasons (heat, battery, Photos), the countdown of the overnight
/// refinement's wait for Apple, "Schon fertig … Ansehen" (point 3). The VoiceOver value keeps the
/// step ("Schritt 4 von 6"): the UI tests read it there.
///
/// The App does not build on Linux, so this reads its code (`AppSource`): comments never count,
/// texts only where a test asks for one.
@Suite("Analysis card at a glance")
struct AnalysisCardGlanceTests {
    static let file = "App/Sortly/Views/AnalysisProgressCard.swift"

    /// The code of a declaration path in the card's file, comments blanked; `keepStrings` keeps
    /// the texts.
    static func code(_ path: [String], keepStrings: Bool = false) throws -> String {
        let source = AppSource.code(try AppSource.read(file), keepStrings: keepStrings)
        return try #require(AppSource.body(of: path, in: source), "\(file): no \(path.joined(separator: " › ")) (moved?)")
    }

    /// The statements of a view builder (`{ … }`) on its own level, each with what belongs to it
    /// (its block, the modifiers on the lines after it), e.g. "header", "progress",
    /// "if !isPaused { Divider() }". Read from code with comments and strings blanked.
    static func parts(of block: String) -> [String] {
        let inner = block.drop { $0 != "{" }.dropFirst().dropLast()
        var parts: [String] = []
        var current = ""
        var depth = 0
        for line in inner.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 0, !trimmed.isEmpty, !trimmed.hasPrefix(".") {
                if !current.isEmpty { parts.append(current) }
                current = trimmed
            } else if !trimmed.isEmpty {
                current += " " + trimmed
            }
            for character in line {
                if "{([".contains(character) { depth += 1 }
                if "})]".contains(character) { depth -= 1 }
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// What the card shows at a glance, top to bottom: the heading with its one button, the
    /// progress (count, the short line, the bar: one element for VoiceOver, B1), "Schon fertig",
    /// a divider and "Details". Nothing else; adding a part means another one goes (the review:
    /// "erst ausdünnen, dann ergänzen").
    @Test func theCardShowsOnlyWhatMattersAtAGlance() throws {
        let card = Self.parts(of: try Self.code(["struct AnalysisProgressCard", "private var full: some View", "VStack("]))
            .filter { !$0.hasPrefix("if !isPaused { Divider() }") }
        #expect(card.count == 4, "the card shows \(card.count) parts: \(card)")
        #expect(card.first == "header", "\(card)")
        #expect(card.dropFirst().first == "progress", "\(card)")
        #expect(card.dropFirst(2).first == "alreadyDone", "\(card)")
        #expect(card.last?.hasPrefix("Button { showDetails = true }") == true, "\(card)")

        // The progress element: the count (while running), the short line, the bar.
        let progress = Self.parts(of: try Self.code(["struct AnalysisProgressCard", "private var progress: some View", "VStack("]))
        #expect(progress.count == 3, "the progress shows \(progress.count) parts: \(progress)")
        #expect(progress.first?.hasPrefix("if let position, position.hasCount") == true, "\(progress)")
        #expect(progress.dropFirst().first == "statusLines", "\(progress)")
        #expect(progress.last?.hasPrefix("AnalysisBar(") == true, "\(progress)")
    }

    /// What left the card is in "Details": the step ("Schritt 4 von 6", "Gleich wieder bei
    /// Schritt 4 von 6"), the photos just looked at (image step only, never a screenshot: B4),
    /// whether it runs in the background (now with the honest "dort aber langsamer", P4-13), and
    /// the note on town names.
    @Test func whatLeftTheCardIsInDetails() throws {
        let card = try Self.code(["struct AnalysisProgressCard"], keepStrings: true)
        let details = try Self.code(["struct AnalysisDetailsSheet"], keepStrings: true)
        let moved = [
            "\"Gerade angesehen\"", "AssetThumbnail(", "model.analysisRecent", "model.analysisBackground",
            "\"Läuft im Hintergrund weiter, dort aber langsamer\"", "\"Läuft, solange Albumist offen ist\"",
            "\"Städtenamen kommen von Apple, das braucht etwas Zeit. Was jetzt nicht fertig wird, holt Albumist nach, wenn dein iPhone das nächste Mal lädt.\"",
            "stepText",
        ]
        for text in moved {
            #expect(details.contains(text), "Details lack \(text)")
        }
        for text in moved.dropLast() + ["\"Läuft auch im Hintergrund\"", "Text(stepLine"] {
            #expect(!card.contains(text), "the card still shows \(text)")
        }
        // The photos just looked at only beside the image step (B4: never a screenshot).
        let recent = try Self.code(["struct AnalysisDetailsSheet", "private func recentPhotos("])
        #expect(recent.contains("step == .content"), "\(recent)")
        // The step stays in the card's VoiceOver value, where the UI tests read it.
        let spoken = try Self.code(["struct AnalysisProgressCard", "private var accessibilityValue: String"])
        #expect(spoken.contains("parts.append(stepLine)"), "\(spoken)")
    }

    /// Everything the owner decided to show stays on the card.
    @Test func nothingTheOwnerDecidedLeavesTheCard() throws {
        let card = try Self.code(["struct AnalysisProgressCard"], keepStrings: true)
        let decided = [
            // Point 1: the finish time; Apple's countdown (overnight refinement); the map pass
            // moves while the places count stands (nothing stands still for more than 10 s).
            "AnalysisText.finish(finish)", "AnalysisText.appleWait(", "AnalysisText.mapChecked(pass)",
            // Pause, and the ways back.
            "model.pauseAnalysis()", "CardTextButton(\"Fortsetzen\")", "CardTextButton(\"Jetzt versuchen\")",
            // Why it is slower or waits (decision of 15.11.: the analysis in the app never ends
            // for the device; table M4 of the progress display).
            "\"Langsamer, weil dein iPhone warm ist\"", "\"Langsamer, weil der Stromsparmodus an ist\"",
            "\"Wartet, bis dein iPhone abkühlt\"", "\"Wartet aufs Laden\"", "\"Fotos antwortet gerade nicht\"",
            "\"Albumist war gerade ausgelastet\"", "\"Geht von selbst weiter. Du musst nichts tun.\"",
            "Geht weiter, sobald dein iPhone lädt.", "\"Macht noch fertig, was gerade läuft.\"",
            "\"Dauert noch einen Moment.\"", "\"Analyse pausiert\"", "Sie macht genau dort weiter.",
            // Point 3, the bar, and the way to the rest.
            "\"Schon fertig: ", "CardTextButton(\"Ansehen\")", "AnalysisBar(", "Text(\"Details\")", "AnalysisDetailsSheet()",
        ]
        for text in decided {
            #expect(card.contains(text), "the card lost \(text)")
        }
    }
}
