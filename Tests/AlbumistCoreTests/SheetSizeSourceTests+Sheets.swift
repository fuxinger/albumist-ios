import Foundation
import AlbumistTestSupport

/// How the guard reads a sheet (`SheetSizeSourceTests`): the sizes it brings itself (a sheet
/// opened inside its content is its own) and the ways it can be shown, each of which brings its
/// own size (review T9 of H14's round 2). A file of its own for SwiftLint's file length.
extension SheetSizeSourceTests {
    /// The sizes this sheet's content brings itself: `sheetSize(` of a sheet opened inside it
    /// belongs to that sheet, which the scan reads on its own (review T9 of H14's round 2).
    static func sizes(in content: String) -> [String] {
        AppSource.calls(of: "sheetSize(", in: withoutNestedSheets(content))
    }

    /// `content` with the content of every sheet opened inside it blanked (each character a
    /// space, so positions stay).
    static func withoutNestedSheets(_ content: String) -> String {
        var scalars = Array(content.unicodeScalars)
        for nested in sheetContents(in: content) {
            guard let range = content.range(of: nested) else { continue }
            let from = content.unicodeScalars.distance(from: content.startIndex, to: range.lowerBound)
            let to = content.unicodeScalars.distance(from: content.startIndex, to: range.upperBound)
            for index in from..<min(to, scalars.count) where scalars[index] != "\n" { scalars[index] = " " }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The ways `content` can show its sheet, each of which brings its own size: the blocks of an
    /// `if`/`else if`/`else` and the parts of a `switch`'s cases at the content's own top level
    /// (branching inside a view of the content, `Group { if … }`, is one way), else the content.
    static func branches(of content: String) -> [String] {
        let body = insideBraces(of: content)
        let masked = Array(AppSource.code(body).unicodeScalars)
        if keyword("if", at: 0, in: masked) != nil {
            let blocks = topLevelBlocks(in: body, masked: masked)
            if !blocks.isEmpty { return blocks.flatMap { branches(of: $0) } }
        }
        if keyword("switch", at: 0, in: masked) != nil, let block = topLevelBlocks(in: body, masked: masked).first {
            let cases = caseParts(of: block)
            if !cases.isEmpty { return cases }
        }
        return [body]
    }

    /// What stands between the outermost braces of `text`, or `text` when it has none.
    private static func insideBraces(of text: String) -> String {
        let masked = Array(AppSource.code(text).unicodeScalars)
        guard let open = masked.firstIndex(of: "{"), let close = masked.lastIndex(of: "}"), open < close else { return text }
        let scalars = Array(text.unicodeScalars)
        return String(String.UnicodeScalarView(scalars[(open + 1)..<close]))
    }

    /// Where `word` stands as a word of its own at depth `depth` of `masked`, or nil.
    private static func keyword(_ word: String, at depth: Int, in masked: [Unicode.Scalar]) -> Int? {
        let wanted = Array(word.unicodeScalars)
        var open = 0
        var index = 0
        while index < masked.count {
            if "([{".unicodeScalars.contains(masked[index]) { open += 1 }
            if ")]}".unicodeScalars.contains(masked[index]) { open -= 1 }
            if open == depth, index + wanted.count <= masked.count, Array(masked[index..<(index + wanted.count)]) == wanted,
               !isPartOfAWord(index > 0 ? masked[index - 1] : " "),
               index + wanted.count == masked.count || !isPartOfAWord(masked[index + wanted.count]) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The `{…}` blocks at depth 0 of `body`, as written.
    private static func topLevelBlocks(in body: String, masked: [Unicode.Scalar]) -> [String] {
        let scalars = Array(body.unicodeScalars)
        var blocks: [String] = []
        var depth = 0
        var start: Int?
        for index in masked.indices {
            if masked[index] == "{" {
                if depth == 0 { start = index }
                depth += 1
            }
            if masked[index] == "}" {
                depth -= 1
                if depth == 0, let from = start {
                    blocks.append(String(String.UnicodeScalarView(scalars[from...index])))
                    start = nil
                }
            }
        }
        return blocks
    }

    /// The parts of a `switch`'s block: what follows each `case …:` or `default:` up to the next
    /// one, as written.
    private static func caseParts(of block: String) -> [String] {
        let body = insideBraces(of: block)
        let masked = Array(AppSource.code(body).unicodeScalars)
        let scalars = Array(body.unicodeScalars)
        var starts: [Int] = []
        var depth = 0
        var index = 0
        while index < masked.count {
            if "([{".unicodeScalars.contains(masked[index]) { depth += 1 }
            if ")]}".unicodeScalars.contains(masked[index]) { depth -= 1 }
            if depth == 0, masked[index] == ":", let label = labelBefore(index, in: masked) { starts.append(label) }
            index += 1
        }
        guard !starts.isEmpty else { return [] }
        return starts.indices.map { at in
            let from = starts[at]
            let to = at + 1 < starts.count ? starts[at + 1] : masked.count
            return String(String.UnicodeScalarView(scalars[from..<to]))
        }
    }

    /// The end of a `case …:` or `default:` label whose ":" stands at `colon`: where what follows
    /// it begins, or nil when the ":" belongs to something else (an argument, a dictionary).
    private static func labelBefore(_ colon: Int, in masked: [Unicode.Scalar]) -> Int? {
        var start = colon
        while start > 0, masked[start - 1] != "\n", masked[start - 1] != ";" { start -= 1 }
        let line = String(String.UnicodeScalarView(masked[start..<colon])).trimmingCharacters(in: .whitespaces)
        guard line == "default" || line.hasPrefix("case ") else { return nil }
        return colon + 1
    }

    /// `scalar` can stand inside an identifier, so a keyword beside it is part of a longer name.
    private static func isPartOfAWord(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
