import Testing
import SortlyTestSupport

/// The rows of the albums tab between the shelf and "Deine Alben" ("Ordner „Reisen“", "Verlauf
/// und Rückgängig", "Ähnliche Alben"). Their number shared the line with the title, which took
/// all the width it could: from the text size xxLarge "Unterbrochen" broke inside the word beside
/// "Verlauf und Rückgängig", from AX1 "Rückgängig" did too (review A of design wave 1, finding 5).
/// Now the number stands beside the title only while both fit on one line, else under it, as in
/// the value rows of Settings; at the accessibility sizes the symbol and the chevron stand above
/// the words, which get the whole width (as "Alle Vorschläge" on the start page).
@Suite("Albums tab: the rows keep their words whole")
struct AlbumTabRowsTextTests {
    static let view = "App/Sortly/Views/AlbumsView.swift"
    static let card = "private struct AlbumRowsCard"

    static func code(of declaration: String) throws -> String {
        let source = try AppSource.read(view)
        return AppSource.code(try #require(AppSource.body(of: [card, declaration], in: source),
                                           "\(declaration) in AlbumRowsCard"), keepStrings: true)
    }

    @Test func theNumberStandsBesideTheTitleOnlyWhileBothFitOnOneLine() throws {
        let line = try Self.code(of: "private func line(symbol: String, title: Text, value: Text?)")
        let fits = try #require(line.range(of: "ViewThatFits(in: .horizontal)"),
                                "side by side or one under the other, as the value rows of Settings")
        let candidates = String(line[fits.upperBound...])
        // First everything on one line, then the words one under the other.
        let beside = try #require(candidates.range(of: "if let value"))
        let under = try #require(candidates.range(of: "words(title, value)"))
        #expect(beside.lowerBound < under.lowerBound)
        #expect(candidates.contains(".fixedSize()"), "the number keeps its width beside the title")
    }

    @Test func atTheAccessibilitySizesTheWordsGetTheWholeWidth() throws {
        let line = try Self.code(of: "private func line(symbol: String, title: Text, value: Text?)")
        let large = try #require(line.range(of: "if typeSize.isAccessibilitySize"))
        let other = try #require(line.range(of: "} else {", range: large.upperBound..<line.endIndex))
        let column = String(line[large.upperBound..<other.lowerBound])
        #expect(column.contains("VStack(alignment: .leading"))
        // The symbol and the chevron on top, then the words across the row.
        let top = try #require(column.range(of: "icon(symbol)"))
        let chevron = try #require(column.range(of: "chevron"))
        let words = try #require(column.range(of: "words(title, value)"))
        #expect(top.lowerBound < words.lowerBound && chevron.lowerBound < words.lowerBound)
        // The symbol keeps its column beside the words only.
        let icon = try Self.code(of: "private func icon(_ symbol: String)")
        #expect(icon.contains("typeSize.isAccessibilitySize"))
        #expect(icon.contains(".frame(width: symbolWidth)"))
    }

    @Test func theWordsWrapAndTheNumberStandsUnderTheTitle() throws {
        let words = try Self.code(of: "private func words(_ title: Text, _ value: Text?)")
        #expect(words.contains("VStack(alignment: .leading"))
        let title = try #require(words.range(of: "title"))
        let value = try #require(words.range(of: "if let value"))
        #expect(title.lowerBound < value.lowerBound)
        #expect(words.components(separatedBy: ".fixedSize(horizontal: false, vertical: true)").count == 3,
                "title and number wrap between words instead of being cut")
    }

    @Test func theDividerStartsWhereTheWordsStart() throws {
        let body = try Self.code(of: "var body: some View")
        #expect(body.contains("typeSize.isAccessibilitySize ? Theme.Spacing.l : Theme.Spacing.l + symbolWidth + Theme.Spacing.m"))
    }
}
