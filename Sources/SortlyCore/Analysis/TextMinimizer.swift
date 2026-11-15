import Foundation

/// Data minimization for recognized text before it is stored (search index and analysis
/// results). Analysis itself still sees the full text; only what is kept on disk shrinks:
/// - ID documents and medical papers: no text is stored at all (only the classification).
/// - IBANs and valid card numbers are masked in every other text.
public enum TextMinimizer {
    public static func sensitivity(of rawText: String) -> DocumentSensitivity {
        let text = rawText.lowercased()
        var level = DocumentSensitivity.normal
        for (candidate, words) in DocumentAnalyzer.sensitivityKeywords where words.contains(where: { text.contains($0) }) {
            level = max(level, candidate)
        }
        return level
    }

    /// The text that may be stored for `rawText`.
    public static func storable(_ rawText: String) -> String {
        switch sensitivity(of: rawText) {
        case .identity, .medical:
            return ""
        case .normal, .financial:
            return maskCardNumbers(maskIBANs(rawText))
        }
    }

    // MARK: Masks

    /// Raised when the masks change, so texts stored by an older version are masked again
    /// (see `AnalysisPipeline`). 2: numbers split over lines or by unusual spaces (audit 2, 6.1).
    public static let maskVersion = 2

    /// IBAN shape in any letter case. Between groups: up to two spaces of any kind, a line
    /// break (OCR splits long lines) or nothing.
    private static let ibanPattern = try! NSRegularExpression(
        pattern: #"\b[A-Za-z]{2}[0-9]{2}(?:\s{0,2}[A-Za-z0-9]{4}){2,7}(?:\s{0,2}[A-Za-z0-9]{1,3})?\b"#)
    /// A group of digits; card numbers are printed as one group or several (4-4-4-4, 4-6-5).
    private static let digitGroupPattern = try! NSRegularExpression(pattern: #"[0-9]+"#)

    /// Upper-case IBAN shapes are always masked (as printed on statements). Shapes with lower-case
    /// letters (OCR, handwriting, chat screenshots) are masked when the IBAN checksum holds, so
    /// ordinary words that happen to look similar stay searchable.
    static func maskIBANs(_ text: String) -> String {
        var result = text
        let matches = ibanPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            let compact = candidate.uppercased().filter { $0.isLetter || $0.isNumber }
            let isUpper = candidate == candidate.uppercased()
            let valid = stride(from: min(compact.count, 34), through: 15, by: -1)
                .contains { DocumentAnalyzer.isValidIBAN(String(compact.prefix($0))) }
            if isUpper || valid { result.replaceSubrange(range, with: "IBAN ••••") }
        }
        return result
    }

    /// Card numbers: consecutive digit groups with 13 to 19 digits in all that pass the Luhn
    /// check. Groups may be separated by spaces of any kind, hyphens or a line break (OCR often
    /// splits "4111 1111 / 1111 1111" over two lines). Every passing run of whole groups is
    /// masked, so a date or amount right after the number does not hide it.
    static func maskCardNumbers(_ text: String) -> String {
        let ns = text as NSString
        let groups = digitGroupPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !groups.isEmpty else { return text }
        func separated(_ a: NSRange, _ b: NSRange) -> Bool {
            let gap = ns.substring(with: NSRange(location: a.location + a.length, length: b.location - a.location - a.length))
            return gap.count <= 3 && gap.unicodeScalars.allSatisfy { $0 == "-" || CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        func digits(_ r: NSRange) -> [Int] { ns.substring(with: r).compactMap(\.wholeNumberValue) }
        var masked: [NSRange] = []
        for first in groups.indices {
            var run: [Int] = []
            var last = first
            while last < groups.count {
                if last > first, !separated(groups[last - 1], groups[last]) { break }
                run += digits(groups[last])
                if run.count > 19 { break }
                if run.count >= 13, luhnValid(run) {
                    let start = groups[first].location
                    masked.append(NSRange(location: start, length: groups[last].location + groups[last].length - start))
                }
                last += 1
            }
        }
        guard !masked.isEmpty else { return text }
        // Overlapping runs become one masked stretch.
        var merged: [NSRange] = []
        for r in masked.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, r.location <= previous.location + previous.length {
                let end = max(previous.location + previous.length, r.location + r.length)
                merged[merged.count - 1] = NSRange(location: previous.location, length: end - previous.location)
            } else {
                merged.append(r)
            }
        }
        let result = NSMutableString(string: text)
        for r in merged.reversed() { result.replaceCharacters(in: r, with: "•••• ••••") }
        return result as String
    }

    static func luhnValid(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
